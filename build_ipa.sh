#!/bin/bash
# build_ipa.sh - Build unsigned IPA for MyTVBox
# Usage: ./build_ipa.sh
set -e

PROJECT_NAME="MyTVBox"
SCHEME="MyTVBox"
CONFIGURATION="Release"
BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
IPA_DIR="${BUILD_DIR}/ipa"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"

echo "==> Generating Xcode project via xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

# 1.7.0：端上 Node 运行时是动态库，必须存在才能生成工程。
if [ ! -d "NodeMobile.xcframework" ]; then
  echo "!! NodeMobile.xcframework 不在仓库根目录。"
  echo "   请先下载："
  echo "   curl -L -o /tmp/nm.zip https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.20.4/nodejs-mobile-v18.20.4-ios.zip"
  echo "   unzip -q /tmp/nm.zip -d ."
  exit 1
fi

xcodegen generate

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving (unsigned)..."
xcodebuild \
  -project "${PROJECT_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  -archivePath "${ARCHIVE_PATH}" \
  archive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM=""

# ------------------------------------------------------------------
# 1.7.0 关键步骤：给嵌入的 NodeMobile.framework 做 ad-hoc 签名
#
# 主 App 是免签名 IPA，但 iOS 加载动态库时仍会校验签名（越狱 / TrollStore
# 环境有 amfi 绕过，但不同系统版本行为不一致）。做一次 ad-hoc 签名能让它
# 在更多环境下稳定加载，代价只是 IPA 里多几百字节。
# ------------------------------------------------------------------
echo "==> Ad-hoc signing embedded frameworks..."
if [ -d "${APP_PATH}/Frameworks" ]; then
  find "${APP_PATH}/Frameworks" -maxdepth 1 -name "*.framework" -print0 2>/dev/null \
  | while IFS= read -r -d '' fw; do
      name="$(basename "$fw")"
      if codesign -f -s - --timestamp=none "$fw" >/dev/null 2>&1; then
        echo "    signed ${name}"
      else
        echo "    WARN: ${name} 签名失败（继续，TrollStore 环境通常仍可加载）"
      fi
    done
else
  echo "    WARN: 没找到 Frameworks 目录 —— NodeMobile 可能没被嵌入"
fi

# 校验 framework 确实进了包
if [ -f "${APP_PATH}/Frameworks/NodeMobile.framework/NodeMobile" ]; then
  FSZ=$(stat -f%z "${APP_PATH}/Frameworks/NodeMobile.framework/NodeMobile" 2>/dev/null || echo 0)
  echo "    NodeMobile.framework 已嵌入 (${FSZ} bytes)"
else
  echo "!! 错误：NodeMobile.framework 未嵌入 App，端上 Node 无法启动"
  exit 1
fi

echo "==> Packaging IPA..."
mkdir -p "${IPA_DIR}/Payload"
cp -R "${APP_PATH}" "${IPA_DIR}/Payload/"
cd "${IPA_DIR}"
zip -qr "${PROJECT_NAME}.ipa" Payload
cd -

echo "==> Done. IPA at: ${IPA_DIR}/${PROJECT_NAME}.ipa"
ls -la "${IPA_DIR}/${PROJECT_NAME}.ipa"
