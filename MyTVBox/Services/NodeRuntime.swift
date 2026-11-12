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

    // 1.8.6：node_start 是**阻塞**调用，它返回就等于 Node 事件循环已经结束。
    // 以前完全不记这件事，结果 Node 死了 Swift 还以为端口活着，一直发 /config。
    // rc=9 是 Node 的 kInvalidCommandLineArgument（本机实测 `node --非法flag` → 9），
    // 1.8.5 给 NODE_OPTIONS 加的 --expose-gc 在端上 nodejs-mobile v18.20.4 不被接受，
    // 于是 main.js 一行没跑、整个本机源瘫痪。这些字段让失败可见、可诊断、可恢复。
    private(set) var lastExitCode: Int32?
    private(set) var nodeDidExit = false
    private(set) var bootNote: String?

    /// 给 UI/诊断读的一句话失败原因；nil 表示没有已知启动故障
    var bootFailureText: String? {
        guard nodeDidExit, let rc = lastExitCode else { return nil }
        if rc == 9 {
            return "本机内核启动失败（rc=9 · 启动参数不被接受）"
        }
        return "本机内核已退出（rc=\(rc)）"
    }

    /// App 内部访问 Node 服务的基址。
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private var booted = false
    private let lock = NSLock()
    /// 1.7.8：`/config` 单飞任务（启动预热与界面加载共用同一次请求）
    private var localConfigTask: Task<Data?, Never>?

    private init() {}

    // MARK: - 路径

    private var workDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("nodejs-project", isDirectory: true)
    }

    private var readyFile: URL { workDir.appendingPathComponent("ready.txt") }
    /// 1.7.6：main.js 启动时写入「实际加载了哪份内核」
    private var kernelLogFile: URL { workDir.appendingPathComponent("kernel.txt") }
    /// 1.8.7：main.js 写入「fetch 兼容层有没有装」，独立文件，不用在日志里翻
    private var shimFile: URL { workDir.appendingPathComponent("shim.txt") }
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
        nodeDidExit = false
        lastExitCode = nil
        bootNote = nil
        isReady = false
        localConfigTask = nil
        lock.unlock()

        // 1.8.6：**同步**清掉上一次运行留下的就绪标记。
        // 旧实现把删除放在后台线程里，而 waitUntilReady 主线程立刻开始轮询 ——
        // 于是先读到上一次写的 ready.txt=18923，直接判定 isReady=true，
        // 对着一个已经没人监听的端口狂发 /config。诊断里「node ready : YES」
        // 却全是 Could not connect，就是这么来的。
        try? FileManager.default.removeItem(at: readyFile)
        try? FileManager.default.removeItem(at: kernelLogFile)
        // 1.8.7：shim.txt 也是「本次进程」的状态，不能读到上一次的
        try? FileManager.default.removeItem(at: shimFile)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchNode()
        }
    }

    /// 真正调用 node_start 的地方（阻塞在本后台线程，直到 Node 事件循环结束）。
    private func launchNode() {
        do {
            try installProjectIfNeeded()
        } catch {
            NSLog("[NodeRuntime] 安装资源失败: \(error.localizedDescription)")
            appendLog("FATAL install: \(error.localizedDescription)")
            markExited(rc: -1, note: "安装资源失败: \(error.localizedDescription)")
            return
        }

        let mainPath = workDir.appendingPathComponent("main.js").path
        guard FileManager.default.fileExists(atPath: mainPath) else {
            appendLog("FATAL: main.js 不存在 \(mainPath)")
            markExited(rc: -1, note: "main.js 不存在")
            return
        }

        // 环境变量交给 bundle 读
        setenv("PORT", "\(NodeRuntime.defaultPort)", 1)
        setenv("HOST", "127.0.0.1", 1)
        setenv("NODE_ENV", "production", 1)
        setenv("HOME", workDir.path, 1)

        // 1.7.1 把堆上限压到 128 MB 想防 Jetsam，方向反了：V8 撞到堆上限会
        // `FATAL ERROR: Reached heap limit` → abort 整个进程。1.7.7 改 512 MB。
        // 1.8.5 加的 `--expose-gc` 在端上 nodejs-mobile v18.20.4 不被接受：
        // node_start 直接以 **rc=9（kInvalidCommandLineArgument）** 返回，
        // main.js 一行都没执行 → 本机源全瘫、界面停在「内核启动中…」。
        // 1.8.6：回到 1.8.4 已实测可启动的唯一参数。以后往 NODE_OPTIONS
        // 里加任何 flag，都必须先在真机确认 node_start 仍返回 0。
        setenv("NODE_OPTIONS", "--max-old-space-size=512", 1)

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
        appendLog("node_start exited rc=\(rc)")
        markExited(rc: rc, note: rc == 9
                   ? "rc=9 启动参数不被接受（NODE_OPTIONS）"
                   : "Node 事件循环结束")
    }

    /// 1.8.6：Node 退出是**硬事实**，立刻复位所有「就绪」假象并留现场。
    private func markExited(rc: Int32, note: String) {
        lock.lock()
        nodeDidExit = true
        lastExitCode = rc
        bootNote = note
        isReady = false
        localConfigTask = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: readyFile)
        SessionTrace.mark("败 Node 启动 rc=\(rc) \(note)")
    }

    /// 1.8.6：手动/回前台自愈。node_start 已退出时复位状态再引导一次。
    /// 注意：nodejs-mobile 不保证同一进程能二次初始化，所以这里**只在明确失败后**
    /// 由用户动作或回前台触发一次，不做无人值守的循环重启。
    func restartNode() {
        appendLog("restartNode: 重新引导端上内核")
        SessionTrace.mark("记 重启内核")
        lock.lock()
        booted = false
        nodeDidExit = false
        lastExitCode = nil
        bootNote = nil
        isReady = false
        localConfigTask = nil
        lock.unlock()
        startIfNeeded()
    }

    // MARK: - 等待就绪

    /// 轮询 ready.txt **并真的敲一次 /health**，直到 Node 起好或超时。
    /// 1.8.6：只读文件会把上一次运行残留的 ready.txt 当成「端口活着」。
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // node_start 已返回 = Node 已经结束，别再傻等 120 秒
            if nodeDidExit { isReady = false; return false }
            if let p = currentReadyPort(), await healthOK(p) {
                port = p
                isReady = true
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        isReady = false
        return false
    }

    /// 1.8.6：真实端口探测。严格校验 /health 的 name 指纹，
    /// 避免把别的进程占用的 18923 误当成猫爪源。
    private func healthOK(_ p: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(p)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("close", forHTTPHeaderField: "Connection")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["name"] as? String) == "CatVodSpiderios" else { return false }
            return true
        } catch {
            return false
        }
    }

    /// 已就绪则直接返回，否则等。用于从后台回前台的重连场景。
    @discardableResult
    func ensureReady(timeout: TimeInterval = 90) async -> Bool {
        // 1.8.6：isReady 也必须用真实 /health 复核，不能看标志位就放行
        if isReady, await healthOK(port) { return true }
        isReady = false
        if nodeDidExit {
            restartNode()
        } else {
            startIfNeeded()
        }
        return await waitUntilReady(timeout: timeout)
    }

    /// 1.7.7：预热 /config。
    ///
    /// 源刚 listen 的时候，`/config` 内部还要去拉远端站点配置（设备上是解释执行，
    /// 第一次可能要十几秒），App 这时候去拉就成了「超时 → 0 个站点 → 用户发现
    /// 得手动点一下订阅才出来」。先在这儿敲一次把它的缓存热起来，超时给足。
    ///
    /// 1.7.8：改成「单飞 + 落缓存」—— 启动预热与界面加载共用同一次请求，
    /// 不会再出现两份 /config 同时飞、把设备上的源压得更慢。
    func warmUpConfig(timeout: TimeInterval = 60) async {
        _ = await fetchLocalConfigOnce(timeout: timeout)
    }

    /// 单飞地取一次 `/config`（同一进程内只发一次，结果落缓存并复用）。
    @discardableResult
    func fetchLocalConfigOnce(timeout: TimeInterval = 60) async -> Data? {
        // 启动预热和界面加载会同时进来，占位要加锁，否则会各飞一个请求
        lock.lock()
        if let t = localConfigTask {
            lock.unlock()
            return await t.value
        }
        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            // 1.8.6：node_start 已退出就不再发 /config —— 旧版会一直重试到超时，
            // 日志里刷满 Could not connect，还把「失败」写进本机源状态。
            guard self.isReady, !self.nodeDidExit else { return nil }
            guard let url = URL(string: self.baseURL + "/config") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.cachePolicy = .reloadIgnoringLocalCacheData
            // 1.7.8：不用 keep-alive。URLSession 复用到已经被 Node 关掉的旧连接时，
            // 请求会一直挂到超时（表现就是「转很久圈然后失败」）；本机回环上
            // 每次新建连接的开销可以忽略，直接 close 最稳。
            req.setValue("close", forHTTPHeaderField: "Connection")
            let t0 = Date()
            var lastError: Error?
            // 1.8.0：连接被拒时补一次。实测过「ready 了但 TCP 还没接受连接」的瞬间
            // （`Could not connect to the server.` 0.0s），等一下就能连上。
            // 1.8.2：2 次 → 3 次、退避 0.8s/1.6s。1.8.1 的 node.log 里还有
            // `[swift] config 1.1s 失败: Could not connect to the server.` —— 冷启动时
            // bundle 刚 start() resolved、READY 刚打印，端口还在握手窗口里，两次都撞上了。
            for attempt in 0..<3 {
                do {
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let cost = Date().timeIntervalSince(t0)
                    self.appendLog(String(format: "config %.1fs %d bytes (try %d)",
                                          cost, data.count, attempt + 1))
                    if data.count > 200 {
                        LocalSourceCache.save(data)
                        LocalSourceCache.note(String(format: "成功 %.1fs · %d 字节", cost, data.count))
                    }
                    return data
                } catch {
                    lastError = error
                    let code = (error as? URLError)?.code
                    let retriable = (code == .cannotConnectToHost
                                     || code == .networkConnectionLost
                                     || code == .notConnectedToInternet)
                    if retriable, attempt < 2 {
                        let wait = 0.8 * Double(attempt + 1)
                        self.appendLog(String(format: "config 连接失败（%@），%.1f 秒后重试",
                                              error.localizedDescription, wait))
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        continue
                    }
                    break
                }
            }
            let cost = Date().timeIntervalSince(t0)
            let desc = lastError?.localizedDescription ?? "unknown"
            self.appendLog(String(format: "config %.1fs 失败: %@", cost, desc))
            LocalSourceCache.note(String(format: "失败 %.1fs · %@", cost, desc))
            // 失败要清掉单飞占位，否则「重新加载」永远拿到同一个失败结果
            self.lock.lock()
            self.localConfigTask = nil
            self.lock.unlock()
            return nil
        }
        localConfigTask = task
        lock.unlock()
        return await task.value
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

    /// 1.8.7：node.log 每 10 秒一条 mem10，tail 40 行几乎全是内存样本 ——
    /// 1.8.6 的诊断里 `fetch shim: installed`、FATAL 首行、`node_start rc=` 全被挤出视野，
    /// 只留下一串看不懂的 undici 栈帧。这里**按本次启动之后**全文提取关键行。
    func keyLogLines(sinceLastBoot: Bool = true, limit: Int = 60) -> [String] {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        var lines = s.split(separator: "\n").map(String.init)
        if sinceLastBoot, let boot = lines.lastIndex(where: { $0.contains("=== boot ===") }) {
            lines = Array(lines[boot...])
        }
        let keys = ["=== boot ===", "fetch shim:", "WARN fetch-shim", "FATAL",
                    "EXIT code=", "node_start exited rc=", "READY on port",
                    "kernel.txt", "config ", "mem HIGH", "install:"]
        let hits = lines.filter { line in keys.contains { line.contains($0) } }
        return Array(hits.suffix(limit))
    }

    /// 1.8.13：本次启动后 /play 相关的全部轨迹（REQ / RES / FETCH / BIGBODY / mem1）。
    /// 与 keyLogLines 分开 —— mem1 在 /play 窗口内每秒一条，若混进 60 行关键行
    /// 窗口，会把 FATAL 首行、shim 状态、rc=9 全挤掉（BF2 的坑不能再踩一次）。
    func playTraceLines(sinceLastBoot: Bool = true, limit: Int = 90) -> [String] {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        var lines = s.split(separator: "\n").map(String.init)
        if sinceLastBoot, let boot = lines.lastIndex(where: { $0.contains("=== boot ===") }) {
            lines = Array(lines[boot...])
        }
        return Self.traceHits(lines, limit: limit)
    }

    /// 上一轮（倒数第二个 boot 到最后一个 boot 之间）的 /play 轨迹。
    /// 崩溃发生在上一轮，用户重开 App 才看得到诊断 —— 只看「本次启动后」会全是空的。
    func previousPlayTraceLines(limit: Int = 90) -> [String] {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        let lines = s.split(separator: "\n").map(String.init)
        let boots = lines.indices.filter { lines[$0].contains("=== boot ===") }
        guard boots.count >= 2 else { return [] }
        let slice = Array(lines[boots[boots.count - 2]..<boots[boots.count - 1]])
        return Self.traceHits(slice, limit: limit)
    }

    private static func traceHits(_ lines: [String], limit: Int) -> [String] {
        let keys = ["REQ ", "RES ", "RES-ABORT", "FETCH ", "FETCHERR ",
                    "BIGBODY", "MEM1 ", "mem1 ", "INFLIGHT", "WARN reqtrace"]
        return Array(lines.filter { line in keys.contains { line.contains($0) } }.suffix(limit))
    }

    /// 1.8.7：端上 Node 写的 fetch 兼容层状态（独立文件，不必翻日志）
    var fetchShimText: String {
        guard let data = try? Data(contentsOf: shimFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "未记录（内核未启动或旧版残留）"
        }
        let installed = (obj["installed"] as? Bool) ?? false
        let hasWasm = (obj["hasWebAssembly"] as? Bool) ?? false
        let at = (obj["at"] as? String) ?? ""
        let time = at.split(separator: "T").dropFirst().first.map { String($0.prefix(8)) } ?? at
        if installed { return "已安装（本机无 WebAssembly）· \(time) UTC" }
        return "跳过（本机 WebAssembly=\(hasWasm ? "YES" : "NO")）· \(time) UTC"
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
