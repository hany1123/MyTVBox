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
