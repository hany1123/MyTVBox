//
//  NodeRuntime.swift
//  MyTVBox
//
//  1.7.0：App 内置 Node 运行时。
//
//  设计要点（都是实测结论，不是猜的）：
//  1. 猫爪源是 Node 服务端程序（fastify），JavaScriptCore 跑不了 —— 它要
//     http/net/crypto/fastify，所以必须用真正的 Node 运行时（NodeMobile.framework）。
//  2. 这个 bundle 用了 structuredClone / fetch / AbortSignal.timeout，需要 Node 18+，
//     所以用 nodejs-mobile v18.20.4 的官方 iOS 构建。
//  3. Node 会往 CWD 写文件，iOS 的 App bundle 只读，因此启动前把 main.js / index.js
//     拷到 Documents/nodejs-project，再 chdir 过去。
//  4. 源在端口被占用时会自动 +1，所以端口不能假定 —— main.js 探明真实端口写 ready.txt，
//     这里轮询读取。
//

import Foundation

final class NodeRuntime {

    static let shared = NodeRuntime()

    /// 起始端口。选一个不常用的大端口，避开系统服务和常见软件。
    static let defaultPort = 18923
    /// 源最多往后找 12 个端口，探测范围要一致。
    static let portSpan = 12

    private(set) var port: UInt16 = UInt16(NodeRuntime.defaultPort)
    private(set) var isReady = false

    /// App 内部访问 Node 服务的基址。
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private var booted = false
    private let lock = NSLock()

    private init() {}

    // MARK: - 路径

    private var workDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("nodejs-project", isDirectory: true)
    }

    private var readyFile: URL { workDir.appendingPathComponent("ready.txt") }
    /// 1.7.6：main.js 启动时写入「实际加载了哪份内核」
    private var kernelLogFile: URL { workDir.appendingPathComponent("kernel.txt") }
    private var logFile: URL { workDir.appendingPathComponent("node.log") }

    // MARK: - 安装资源

    /// 把打包在 App 里的 main.js / index.js 拷到可写目录。
    private func installProjectIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        for name in ["main.js", "index.js"] {
            guard let src = locateResource(name) else {
                throw NSError(domain: "NodeRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "bundle 里找不到 \(name)"
                ])
            }
            let dst = workDir.appendingPathComponent(name)

            // index.js 有 6.6 MB，用大小比对避免每次启动都重复拷贝。
            var needCopy = true
            if fm.fileExists(atPath: dst.path) {
                let srcSize = (try? fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.intValue ?? -1
                let dstSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.intValue ?? -2
                needCopy = (srcSize != dstSize)
            }
            if needCopy {
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
        }

        // 清掉上一次运行的就绪标记，避免读到旧端口。
        try? fm.removeItem(at: readyFile)
        // 内核记录也要清：不然「当前运行的内核」会显示上一次的旧值
        try? fm.removeItem(at: kernelLogFile)
    }

    /// 资源可能在根目录，也可能在 NodeProject 子目录（取决于打包方式）。
    private func locateResource(_ name: String) -> URL? {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        if let u = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
            return u
        }
        if let u = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext,
                                  subdirectory: "NodeProject") {
            return u
        }
        if let u = Bundle.main.url(forResource: name, withExtension: nil) {
            return u
        }
        return nil
    }

    // MARK: - 启动

    /// 启动 Node（幂等）。真正的阻塞发生在后台线程，调用方不会被卡住。
    func startIfNeeded() {
        lock.lock()
        if booted { lock.unlock(); return }
        booted = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.installProjectIfNeeded()
            } catch {
                NSLog("[NodeRuntime] 安装资源失败: \(error.localizedDescription)")
                self.appendLog("FATAL install: \(error.localizedDescription)")
                return
            }

            let mainPath = self.workDir.appendingPathComponent("main.js").path
            guard FileManager.default.fileExists(atPath: mainPath) else {
                self.appendLog("FATAL: main.js 不存在 \(mainPath)")
                return
            }

            // 环境变量交给 bundle 读
            setenv("PORT", "\(NodeRuntime.defaultPort)", 1)
            setenv("HOST", "127.0.0.1", 1)
            setenv("NODE_ENV", "production", 1)
            setenv("HOME", self.workDir.path, 1)

            // 1.7.1 内存防护：端上 Node + V8 堆 + AVPlayer 同时在场时很容易吃满，
            // 被系统 Jetsam 杀掉的表现就是「播放返回后闪退」。把老生代上限压到
            // 128 MB，宁可 GC 勤一点、稍微慢一点，也不要被杀进程。
            setenv("NODE_OPTIONS", "--max-old-space-size=128", 1)

            // C 的 argv 必须以 NULL 结尾，argc 不含这个 NULL。
            // 少写这个 nil 会导致 node_start 读越界，表现为启动即崩或卡死。
            var args: [UnsafeMutablePointer<CChar>?] = [
                strdup("node"),
                strdup(mainPath),
                nil
            ]
            defer { args.forEach { if let p = $0 { free(p) } } }

            NSLog("[NodeRuntime] node_start -> \(mainPath)")
            let rc = node_start(Int32(args.count - 1), &args)
            NSLog("[NodeRuntime] node_start 退出 rc=\(rc)")
            self.appendLog("node_start exited rc=\(rc)")
        }
    }

    // MARK: - 等待就绪

    /// 轮询 ready.txt，直到 Node 起好或超时。
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = currentReadyPort() {
                port = p
                isReady = true
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        isReady = false
        return false
    }

    /// 已就绪则直接返回，否则等。用于从后台回前台的重连场景。
    @discardableResult
    func ensureReady(timeout: TimeInterval = 90) async -> Bool {
        if isReady, currentReadyPort() != nil { return true }
        startIfNeeded()
        return await waitUntilReady(timeout: timeout)
    }

    private func currentReadyPort() -> UInt16? {
        guard let s = try? String(contentsOf: readyFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt16(t)
    }

    // MARK: - 远程 bundle（1.7.2）
    //
    // 猫爪源的官方分发方式是「索引 + 内容」：
    //   GET https://host/cat/index.js.md5  -> 32 字节 md5
    //   GET https://host/cat/index.js      -> 6.6 MB bundle（md5 与之对应）
    // 支持它之后，源更新时只要换个地址，App 自己拉新 bundle，不用重打包 IPA。

    /// UserDefaults key：用户填的 bundle 索引地址（形如 .../index.js.md5）
    static let remoteIndexKey = "MyTVBox.remoteSpiderIndexURL"

    /// 1.7.6：内置的默认内核源。用户没填地址时，「检查更新」就用它 ——
    /// 这样源更新了，点一下就行，不用记地址。
    static let defaultIndexURL = "https://9280.kstore.vip/cat/index.js.md5"

    var remoteIndexURL: String? {
        get { UserDefaults.standard.string(forKey: Self.remoteIndexKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: Self.remoteIndexKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.remoteIndexKey)
            }
        }
    }

    /// 判断是不是猫爪源的 bundle 索引地址。只认 `.js.md5` 后缀，避免误伤普通订阅。
    static func isBundleIndexURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return lower.hasSuffix(".js.md5")
    }

    private var remoteBundleFile: URL { workDir.appendingPathComponent("remote.js") }
    private var remoteMD5File: URL { workDir.appendingPathComponent("remote.md5") }

    /// 拉索引 → 和本地比对 → 需要时下载 bundle。
    /// - Returns: `true` 表示 bundle 内容变了（调用方需要重启 Node 才生效）
    @discardableResult
    func syncRemoteBundle() async -> Bool {
        guard let indexRaw = remoteIndexURL, Self.isBundleIndexURL(indexRaw),
              let indexURL = URL(string: indexRaw) else {
            return false
        }

        // workDir 可能还没建（sync 早于 installProjectIfNeeded 执行）
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1) 拉远端 md5
        let remoteMD5: String
        do {
            remoteMD5 = try await fetchText(indexURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } catch {
            appendLog("remote: 拉 md5 失败 \(error.localizedDescription)")
            return false
        }
        guard remoteMD5.count == 32, remoteMD5.allSatisfy({ $0.isHexDigit }) else {
            appendLog("remote: md5 不是 32 位 hex: \(remoteMD5.prefix(60))")
            return false
        }

        // 2) 和本地已下载的比
        let localMD5 = (try? String(contentsOf: remoteMD5File, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if localMD5 == remoteMD5, FileManager.default.fileExists(atPath: remoteBundleFile.path) {
            appendLog("remote: bundle 已是最新 (\(remoteMD5))")
            return false
        }

        // 3) 下载 bundle：{base}/index.js
        // indexRaw = https://host/cat/index.js.md5 → base = https://host/cat/
        var base = indexRaw
        if let r = base.range(of: "index.js.md5", options: [.backwards, .caseInsensitive]) {
            base = String(base[base.startIndex..<r.lowerBound])
        }
        if !base.hasSuffix("/") { base += "/" }
        guard let bundleURL = URL(string: base + "index.js") else { return false }

        do {
            let data = try await fetchData(bundleURL)
            guard data.count > 1_000_000 else {
                appendLog("remote: bundle 太小 (\(data.count) bytes)，放弃")
                return false
            }
            // 校验：远端声明的 md5 必须和实际内容一致，否则可能是半截/被串改
            let actual = Self.md5Hex(data)
            guard actual == remoteMD5 else {
                appendLog("remote: md5 不匹配 期望=\(remoteMD5) 实际=\(actual)")
                return false
            }
            try data.write(to: remoteBundleFile, options: .atomic)
            try? remoteMD5.write(to: remoteMD5File, atomically: true, encoding: .utf8)
            appendLog("remote: 已更新 bundle \(data.count) bytes md5=\(remoteMD5)")
            return true
        } catch {
            appendLog("remote: 下载 bundle 失败 \(error.localizedDescription)")
            return false
        }
    }

    /// 清掉远程 bundle，回退到 App 内置的 index.js。
    func clearRemoteBundle() {
        try? FileManager.default.removeItem(at: remoteBundleFile)
        try? FileManager.default.removeItem(at: remoteMD5File)
        remoteIndexURL = nil
    }

    /// 远程内核的当前状态，供设置页展示。
    struct RemoteBundleStatus {
        /// 用户填的索引地址（形如 .../index.js.md5），没配则为 nil
        let indexURL: String?
        /// 已下载 bundle 的字节数，0 表示没有
        let byteSize: Int
        /// 已下载 bundle 的 md5
        let md5: String
        /// 是否真的有可用 bundle
        var isInstalled: Bool { byteSize > 1_000_000 }
    }

    var remoteBundleStatus: RemoteBundleStatus {
        let attrs = try? FileManager.default.attributesOfItem(atPath: remoteBundleFile.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let md5 = ((try? String(contentsOf: remoteMD5File, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteBundleStatus(indexURL: remoteIndexURL, byteSize: size, md5: md5)
    }

    /// 当前进程真正在跑的那份内核（由 main.js 写入 kernel.txt）
    struct ActiveKernel {
        let source: String   // "remote.js" 或 "index.js"
        let bytes: Int
        let md5: String
        var isRemote: Bool { source == "remote.js" }
    }

    var activeKernel: ActiveKernel? {
        guard let data = try? Data(contentsOf: kernelLogFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let src = obj["source"] as? String else { return nil }
        return ActiveKernel(source: src,
                            bytes: (obj["bytes"] as? NSNumber)?.intValue ?? 0,
                            md5: (obj["md5"] as? String) ?? "")
    }

    /// 已经下载好、但还没被这次进程加载的内核（需要冷启动才生效）
    var pendingKernelMD5: String? {
        let downloaded = remoteBundleStatus.md5
        guard remoteBundleStatus.isInstalled, !downloaded.isEmpty else { return nil }
        // 只有确认了「本次真正加载的是哪份」才敢说需要冷启动。
        // 内核还没起来时 kernel.txt 不存在，这时不下结论，免得一开机就误报。
        guard let active = activeKernel else { return nil }
        return active.md5 == downloaded ? nil : downloaded
    }

    /// 人读的大小文本
    static func sizeText(_ bytes: Int) -> String {
        if bytes <= 0 { return "—" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    // MARK: - 网络与摘要小工具

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        // 这些源站大多带 CDN，禁掉缓存避免拿到旧 md5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "NodeRuntime", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }
        return data
    }

    /// 计算 MD5（CommonCrypto，已在 bridging header 里引入）
    static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 诊断

    /// 读最近若干行 Node 日志，供诊断面板/错误提示用。
    func tailLog(lines: Int = 40) -> String {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else {
            return "(no node.log)"
        }
        let all = s.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    private func appendLog(_ msg: String) {
        let line = "[swift] \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    /// 清空日志（重装/重试用）。
    func resetLog() {
        try? FileManager.default.removeItem(at: logFile)
    }
}
