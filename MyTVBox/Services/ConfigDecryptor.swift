import Foundation
import CommonCrypto

/// TVBox `$#` 加密配置解密
///
/// 部分接口（如小虎斑）返回的不是 JSON，而是形如 `24236c696e746563682324....` 的十六进制串。
/// 这是 `$#`（0x24 0x23）标记的加密配置，安卓端由 `com.github.tvbox.osc.util.AES` 处理：
///
/// 1. 整串按 hex 还原成字节，再当文本处理，前部形如 `$#lintech#$<密文>`
/// 2. `$#` 与 `#$` 之间的内容取前 16 位（不足补 `0`）作为 AES key
/// 3. 文本末尾 13 个字符补 `0` 到 16 位作为 IV
/// 4. 原文中 `2324` 之后、末尾 26 个字符之前的部分是密文，AES-128-CBC / PKCS7 解密
enum ConfigDecryptor {

    /// 判断是否为 `$#` 加密配置
    static func isEncrypted(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("2423") && t.count > 64 && t.count % 2 == 0
    }

    /// 解密 `$#` 加密配置；失败返回 nil
    static func decrypt(_ raw: String) -> Data? {
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEncrypted(hex) else { return nil }
        guard let midData = dataFromHex(hex) else { return nil }

        // 容错解码：非法字节替换为 U+FFFD，与 Java 的 new String(bytes) 行为一致
        let mid = String(decoding: midData, as: UTF8.self)
        let chars = Array(mid)
        guard chars.count > 16 else { return nil }

        // 定位 key：$# 与 #$ 之间
        guard let keyRange = rangeBetween(chars, open: ["$", "#"], close: ["#", "$"]) else { return nil }
        let key = pad16(String(chars[keyRange]))
        // IV：末尾 13 个字符
        let iv = pad16(String(chars[(chars.count - 13)...]))

        // 密文：hex 串中 2324 之后、去掉末尾 26 个字符
        guard let marker = hex.range(of: "2324") else { return nil }
        let start = hex.distance(from: hex.startIndex, to: marker.upperBound)
        let end = hex.count - 0x1a
        guard end > start else { return nil }
        let hexChars = Array(hex)
        guard let cipher = dataFromHex(String(hexChars[start..<end])) else { return nil }

        return aesDecrypt(cipher, key: key, iv: iv)
    }

    // MARK: - 内部工具

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return Data(bytes)
    }

    private static func pad16(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 16 { return String(t.prefix(16)) }
        return t + String(repeating: "0", count: 16 - t.count)
    }

    private static func rangeBetween(_ chars: [Character], open: [Character], close: [Character])
        -> Range<Int>? {
        var start: Int?
        var i = 0
        while i + 1 < chars.count {
            if start == nil, chars[i] == open[0], chars[i + 1] == open[1] {
                start = i + 2
                i += 2
                continue
            }
            if let s = start, chars[i] == close[0], chars[i + 1] == close[1], i > s {
                return s..<i
            }
            i += 1
        }
        return nil
    }

    private static func aesDecrypt(_ data: Data, key: String, iv: String) -> Data? {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == 16, ivBytes.count == 16, !data.isEmpty else { return nil }

        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        var status: CCCryptorStatus = CCCryptorStatus(kCCSuccess)

        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                ivBytes.withUnsafeBytes { ivPtr in
                    keyBytes.withUnsafeBytes { keyPtr in
                        status = CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyBytes.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, out.count,
                            &outLen
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess, outLen > 0 else { return nil }
        return Data(out.prefix(outLen))
    }
}
