import Foundation
import JavaScriptCore

/// CatPaw Spider JS 模块执行引擎
///
/// 通过 JavaScriptCore 加载 esbuild 打包好的 Spider JS 模块，
/// 并提供 nativeReq / dayjs / CryptoJS 等 shims，
/// 使 .js.md5 源可在 iOS 上直接解析视频列表/详情/播放地址。
///
/// 1.5.4：iOS 自带 JavaScriptCore，JS Spider 本来就能跑，之前用不了是引擎不完整。
/// 本轮补齐：webpack/CommonJS 运行时 shim、多 spider 按 key 路由、
/// async/Promise 结果等待、位置参数与单对象双尝试调用。
///
/// 模块接口约定（与 CatPawOpen 一致）：
/// - home()      → { class: [...], list: [...] }
/// - category()  → { page, pagecount, total, list: [...] }
/// - detail()    → { list: [{ vod_id, vod_play_url, ... }] }
/// - play()      → { url, header }
/// - search()    → { list: [...] }
final class SpiderEngine {

    static let shared = SpiderEngine()
    private init() {}

    // MARK: - 公共接口

    /// 从远程 JS 模块 URL 构建 SpiderConfig（带分类 + 视频列表）
    func buildConfig(jsURL: String, siteKey: String, siteName: String) async -> TVBoxConfig? {
        // 1. 下载 JS 模块源码
        guard let jsCode = await fetchModuleCode(jsURL: jsURL) else {
            print("[SpiderEngine] 下载模块失败: \(jsURL)")
            return nil
        }

        // 2. 创建 JSContext 并加载模块
        let context = createContext()
        guard injectModule(context: context, code: jsCode) else {
            print("[SpiderEngine] 模块加载失败")
            return nil
        }

        // 3. 调用 init()
        callMethod(context: context, name: "init", args: [])

        // 4. 调用 home() 获取分类列表
        guard let homeResult = callMethod(context: context, name: "home", args: []) else {
            print("[SpiderEngine] home() 调用失败")
            return nil
        }

        return buildTVBoxConfig(
            from: homeResult,
            context: context,
            siteKey: siteKey,
            siteName: siteName,
            jsCode: jsCode
        )
    }

    /// 执行 JS 模块并调用指定方法，返回原始 JS 结果字典
    ///
    /// - Parameters:
    ///   - jsCode: 完整 JS 代码（单模块或多 spider bundle）
    ///   - method: 调用的方法名（home / category / detail / player / search）
    ///   - args: 方法参数字典
    ///   - spiderKey: bundle 中的 spider key（多 spider bundle 时必传，用于路由）
    func execute(jsCode: String, method: String, args: [String: Any], spiderKey: String? = nil) async -> [String: Any]? {
        let context = createContext()

        // 注入 bundle。webpack 打包脚本常在缺模块时抛异常，但已经把部分 spider
        // 注册到全局了 —— 不能一遇异常就整轮放弃，清掉异常继续尝试路由。
        context.evaluateScript(jsCode)
        if let exception = context.exception, !exception.isUndefined {
            print("[SpiderEngine] bundle 注入告警: \(exception.toString() ?? "unknown")")
            context.exception = nil
        }

        let key = spiderKey ?? ""
        let routerScript = """
        (function() {
            var G = (typeof __MTV_G__ !== 'undefined') ? __MTV_G__ : (function(){ return this; })();
            var key = \(jsonString(key));
            var aliases = \(aliasTableJSON());
            function look(o) {
                return (o && (typeof o === 'object' || typeof o === 'function')) ? o : null;
            }
            function hasMethod(o, m) { return !!(o && typeof o[m] === 'function'); }
            function hasAnyFn(o) {
                if (!o) return false;
                for (var k in aliases) {
                    var ns = aliases[k] || [];
                    for (var i = 0; i < ns.length; i++) {
                        if (typeof o[ns[i]] === 'function') return true;
                    }
                }
                return hasMethod(o, 'init') || hasMethod(o, 'getName');
            }
            function pickSpider() {
                // 1.5.4：多 spider bundle 会把各模块挂到注册表里，按 key 精确取
                var regs = ['__JS_SPIDER__', '__SPIDERS__', 'spiders', '__spiders__',
                            'modules', '__MODULES__', 'spiderMap', 'SPIDERS',
                            'JS_SPIDER', '__jsSpiders__', 'jsSpiders', '__SPIDER__',
                            'SPIDER', 'spider', 'spiderList', '__catSpiders__'];
                for (var i = 0; i < regs.length; i++) {
                    var reg = look(G[regs[i]]);
                    if (!reg) continue;
                    if (key) {
                        var hit = look(reg[key]);
                        if (hit) return hit;
                    }
                    if (hasAnyFn(reg)) {
                        if (!key) return reg;
                    }
                    if (look(reg.default) && hasAnyFn(reg.default)) {
                        if (!key) return reg.default;
                    }
                }
                if (key) {
                    var direct = look(G[key]);
                    if (direct) return direct;
                }
                if (typeof module !== 'undefined' && module.exports) {
                    var ex = look(module.exports);
                    if (ex) {
                        if (key && look(ex[key])) return ex[key];
                        if (hasAnyFn(ex)) return ex;
                        if (look(ex.default) && hasAnyFn(ex.default)) return ex.default;
                    }
                }
                var single = look(G.__JS_SPIDER__);
                if (single) return single;
                return G;   // 顶层函数兜底
            }
            var target = pickSpider();
            // 有些 bundle 注册的是构造函数（class / prototype 方法），
            // 直接调 target.homeContent 会是 undefined，要实例化一次。
            if (typeof target === 'function' && !hasAnyFn(target)) {
                try { var inst = new target(); if (hasAnyFn(inst)) target = inst; } catch (e) {}
            }
            if (target && target.default && !hasAnyFn(target)) {
                try { if (hasAnyFn(target.default)) target = target.default; } catch (e) {}
            }
            function invoke(m, a) {
                var names = (aliases && aliases[m]) ? aliases[m] : [m];
                var lastErr = null;
                for (var i = 0; i < names.length; i++) {
                    var fn = (target !== G) ? target[names[i]] : G[names[i]];
                    if (typeof fn !== 'function') continue;
                    try {
                        var r = fn.apply(target, a || []);
                        if (r !== undefined && r !== null) return r;
                    } catch (e) { lastErr = String(e); }
                }
                return { __mtv_error__: lastErr
                    ? ('调用 ' + m + ' 失败: ' + lastErr)
                    : ('未找到方法 ' + m) };
            }
            function init() {
                try {
                    if (target !== G && typeof target.init === 'function') target.init();
                    else if (typeof G.init === 'function') G.init();
                } catch (e) {}
            }
            return { invoke: invoke, init: init };
        })()
        """

        guard let router = context.evaluateScript(routerScript), !router.isUndefined,
              let invoke = router.objectForKeyedSubscript("invoke"), !invoke.isUndefined else {
            print("[SpiderEngine] 路由器创建失败")
            return nil
        }
        _ = router.objectForKeyedSubscript("init")?.call(withArguments: [])

        // 位置参数优先；不同 Spider 约定不一致时再退回「单个参数对象」。
        // 两种都试，避免把 (tid, pg) 写成 ({id:tid,pg:pg}) 就永远拿不到数据。
        let positional = positionalArgs(method: method, args: args)
        var attempts: [[Any]] = []
        var seen = Set<String>()
        func addAttempt(_ a: [Any]) {
            let k = jsArgsJSON(a)
            if seen.insert(k).inserted { attempts.append(a) }
        }
        addAttempt(positional)
        // TVBox 的 detailContent / playerContent 常见形态是数组参数 [id]
        if method == "detail",
           let id = args["id"] ?? args["vodId"] ?? args["vod_id"] ?? args["vid"] {
            addAttempt([[id]])
            addAttempt([id])
        }
        if !args.isEmpty { addAttempt([args]) }
        if attempts.isEmpty { addAttempt([]) }

        for attempt in attempts {
            guard let jsArr = context.evaluateScript("(\(jsArgsJSON(attempt)))"),
                  !jsArr.isUndefined else { continue }
            let raw = invoke.call(withArguments: [method as NSString, jsArr as Any])
            guard let resolved = resolvePromiseLike(raw, context: context),
                  let dict = resultToDict(resolved) else { continue }
            if let err = dict["__mtv_error__"] as? String {
                print("[SpiderEngine] \(method) 抛错: \(err)")
                continue
            }
            return dict
        }
        return nil
    }

    // MARK: - 1.5.5 真机诊断

    /// 在后台线程同步执行，输出一段可直接复制给开发者的运行时事实。
    /// 不依赖网络抓包，也不需要 Xcode 控制台。
    func diagnoseSync(site: Site?) -> String {
        var out: [String] = []
        out.append("=== MyTVBox 1.5.5 Spider 诊断 ===")
        out.append("site.name     : \(site?.name ?? "nil")")
        out.append("site.key      : \(site?.key ?? "nil")")
        out.append("site.spiderKey: \(site?.spiderKey ?? "nil")")
        let typeText = site.map { String($0.type) } ?? "nil"
        out.append("site.type     : \(typeText)")
        let keys = SpiderContextManager.shared.registeredKeys()
        out.append("moduleCode 注册数: \(keys.count)")
        out.append("moduleCode keys  : \(keys.prefix(24).joined(separator: ", "))")

        guard let site,
              let code = SpiderContextManager.shared.moduleCode(for: site.key) else {
            out.append("")
            out.append("!! 该站点没有注册 bundle（moduleCode）。")
            out.append("若上面的 keys 里有相近 key，说明合并池改名后没同步。")
            return out.joined(separator: "\n")
        }

        out.append("bundle 字节数    : \(code.utf8.count)")
        out.append("")
        out.append("--- bundle HEAD (1200) ---")
        out.append(String(code.prefix(1200)))
        out.append("--- bundle TAIL (600) ---")
        out.append(String(code.suffix(600)))
        out.append("")
        out.append("--- 源码关键字出现次数 ---")
        for n in ["home", "homeContent", "homeVod", "category", "categoryContent",
                  "detail", "detailContent", "play", "playerContent", "search",
                  "searchContent", "init", "class Spider", "__JS_SPIDER__",
                  "module.exports", "exports.", "globalThis", "window.", "require(",
                  "document", "navigator", "axios", "fetch"] {
            let c = code.components(separatedBy: n).count - 1
            if c > 0 { out.append("  \(n) x\(c)") }
        }

        let key = site.spiderKey ?? ""
        let context = createContext()
        context.evaluateScript(code)
        if let e = context.exception, !e.isUndefined {
            out.append("")
            out.append("!! bundle 注入异常: \(e.toString() ?? "unknown")")
            context.exception = nil
        } else {
            out.append("bundle 注入异常  : (none)")
        }

        let probe = """
        (function() {
            var G = (typeof __MTV_G__ !== 'undefined') ? __MTV_G__ : (function(){ return this; })();
            var key = \(jsonString(key));
            var regs = ['__JS_SPIDER__','__SPIDERS__','spiders','__spiders__','modules',
                        '__MODULES__','spiderMap','SPIDERS','JS_SPIDER','__jsSpiders__',
                        'jsSpiders','__SPIDER__','SPIDER','spider','spiderList','__catSpiders__'];
            var lines = [];
            function fns(o) {
                var a = [];
                if (!o) return a;
                try { for (var k in o) { if (typeof o[k] === 'function') a.push(k); } } catch (e) {}
                return a.slice(0, 40);
            }
            function keys(o) {
                try { return Object.keys(o).slice(0, 30); } catch (e) { return []; }
            }
            var hit = null;
            for (var i = 0; i < regs.length; i++) {
                var o = G[regs[i]];
                if (o === undefined || o === null) continue;
                lines.push(regs[i] + ' type=' + (typeof o) + ' keys=[' + keys(o).join(',') + '] fns=[' + fns(o).join(',') + ']');
                if (key && o[key]) {
                    hit = o[key];
                    lines.push('  >> HIT [' + key + '] keys=[' + keys(hit).join(',') + '] fns=[' + fns(hit).join(',') + ']');
                }
                if (o.default) lines.push('  >> default keys=[' + keys(o.default).join(',') + '] fns=[' + fns(o.default).join(',') + ']');
            }
            try {
                var ex = module.exports;
                lines.push('module.exports type=' + (typeof ex) + ' keys=[' + keys(ex).join(',') + '] fns=[' + fns(ex).join(',') + ']');
                if (!hit && key && ex && ex[key]) hit = ex[key];
                if (ex && ex.default) {
                    lines.push('  >> module.exports.default keys=[' + keys(ex.default).join(',') + '] fns=[' + fns(ex.default).join(',') + ']');
                    if (!hit) hit = ex.default;
                }
                if (!hit && ex && fns(ex).length > 0) hit = ex;
            } catch (e) { lines.push('module.exports probe err: ' + e); }
            lines.push('GLOBAL fns=[' + fns(G).slice(0, 60).join(',') + ']');
            lines.push('GLOBAL spider-ish keys=[' + keys(G).filter(function(k){ return /spider|js_|catpaw/i.test(k); }).slice(0, 40).join(',') + ']');
            lines.push('TARGET: ' + (hit ? ('keys=[' + keys(hit).join(',') + '] fns=[' + fns(hit).join(',') + ']') : 'NOT FOUND'));
            if (hit) {
                var f = hit.homeContent || hit.home || hit.homeVod;
                if (typeof f === 'function') {
                    try {
                        var v = f.call(hit);
                        if (v && typeof v.then === 'function') lines.push('HOME_RESULT: Promise');
                        else lines.push('HOME_RESULT: ' + String(JSON.stringify(v)).slice(0, 500));
                    } catch (e) { lines.push('HOME_RESULT ERROR: ' + e); }
                } else {
                    lines.push('HOME_RESULT: no home fn; target fns=[' + fns(hit).join(',') + ']');
                }
            }
            return lines;
        })()
        """
        let arr = (context.evaluateScript(probe)?.toArray() as? [String]) ?? []
        out.append("")
        out.append("--- 运行时结构 ---")
        out.append(contentsOf: arr)
        if let e = context.exception, !e.isUndefined {
            out.append("!! probe 异常: \(e.toString() ?? "unknown")")
            context.exception = nil
        }

        let logs = context.objectForKeyedSubscript("__mtv_logs__")?.toArray() ?? []
        out.append("")
        out.append("--- console 日志 (\(logs.count)) ---")
        for l in logs.prefix(40) { out.append("  \(l)") }
        return out.joined(separator: "\n")
    }

    // MARK: - 1.5.4 运行时补充

    /// 判断某个站点该不该走 JS Spider 引擎（mddcloud 走自己的原生客户端）
    static func isSpiderSite(_ site: Site) -> Bool {
        guard site.type == 3, !MddCloudService.isMddSite(site) else { return false }
        return SpiderContextManager.shared.moduleCode(for: site.key) != nil
    }

    /// 统一入口：业务层只需要给站点 + 方法名 + 参数
    func call(site: Site, method: String, args: [String: Any]) async -> [String: Any]? {
        guard let code = SpiderContextManager.shared.moduleCode(for: site.key) else { return nil }
        return await execute(jsCode: code, method: method, args: args,
                             spiderKey: site.spiderKey)
    }

    /// 按 TVBox / 猫爪约定把字典转成位置参数
    private func positionalArgs(method: String, args: [String: Any]) -> [Any] {
        func first(_ keys: [String]) -> Any? {
            for k in keys { if let v = args[k] { return v } }
            return nil
        }
        switch method {
        case "category":
            var out: [Any] = []
            if let v = first(["id", "tid", "t", "type_id"]) { out.append(v) }
            if let v = first(["pg", "page"]) { out.append(v) }
            return out
        case "detail":
            if let v = first(["id", "vodId", "vod_id", "vid"]) { return [v] }
        case "search":
            var out: [Any] = []
            if let v = first(["wd", "keyword", "key", "q"]) { out.append(v) }
            if let v = first(["quick"]) { out.append(v) }
            return out
        case "play":
            var out: [Any] = []
            if let v = first(["flag", "play_key", "from"]) { out.append(v) }
            if let v = first(["id", "url", "play", "episode"]) { out.append(v) }
            return out
        default:
            break
        }
        return []
    }

    /// TVBox / 猫爪两套常见命名：home vs homeContent、play vs playerContent …
    /// 只认一套名字会让整份 bundle 明明加载成功却一个方法都调不到。
    private func aliasTableJSON() -> String {
        let table: [String: [String]] = [
            "home": ["home", "homeContent", "homeVod"],
            "category": ["category", "categoryContent"],
            "detail": ["detail", "detailContent"],
            "play": ["play", "playerContent", "player"],
            "search": ["search", "searchContent"],
        ]
        guard JSONSerialization.isValidJSONObject(table),
              let data = try? JSONSerialization.data(withJSONObject: table),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func jsArgsJSON(_ values: [Any]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// 等 Promise / async 函数落地。
    /// JSC 没有事件循环，但每次 evaluateScript 会排空微任务队列；
    /// 网络桥是同步的（nativeReq + semaphore），fetch 返回已 resolve 的 Promise，
    /// 所以轮询几次即可拿到结果。
    private func resolvePromiseLike(_ value: JSValue?, context: JSContext) -> JSValue? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        let then = value.objectForKeyedSubscript("then")
        guard let then, !then.isUndefined else { return value }

        context.setObject(value, forKeyedSubscript: "__mtv_promise__" as NSString)
        context.evaluateScript("""
        var __mtv_done__ = false, __mtv_value__ = null, __mtv_error__ = null;
        try {
            __mtv_promise__.then(function(v){ __mtv_value__ = v; __mtv_done__ = true; },
                                 function(e){ __mtv_error__ = String(e); __mtv_done__ = true; });
        } catch (e) { __mtv_error__ = String(e); __mtv_done__ = true; }
        """)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if context.evaluateScript("__mtv_done__")?.toBool() == true { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let err = context.evaluateScript("__mtv_error__")?.toString(),
           err != "undefined", !err.isEmpty {
            print("[SpiderEngine] Promise 拒绝: \(err)")
            return nil
        }
        let out = context.objectForKeyedSubscript("__mtv_value__")
        return (out?.isUndefined ?? true) ? nil : out
    }

    /// JSValue → 字典；兼容 spider 返回 JSON 字符串（如 play() 的 JSON.stringify）
    private func resultToDict(_ value: JSValue?) -> [String: Any]? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if let dict = value.toObject() as? [String: Any] { return normalizeSpiderDict(dict) }
        guard let str = value.toString(), let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any] else { return nil }
        return normalizeSpiderDict(json)
    }

    /// 各家 Spider 字段名不统一：class/classes/types、list/data/vodlist …
    private func normalizeSpiderDict(_ dict: [String: Any]) -> [String: Any] {
        var out = dict
        if out["class"] == nil {
            for k in ["classes", "types", "cate", "filters"] {
                if let v = dict[k] { out["class"] = v; break }
            }
        }
        if out["list"] == nil {
            for k in ["data", "vodlist", "videos", "items", "result"] {
                if let v = dict[k], v is [[String: Any]] { out["list"] = v; break }
            }
            if out["list"] == nil, let nested = dict["data"] as? [String: Any] {
                if let v = nested["list"] { out["list"] = v }
                if out["class"] == nil, let v = nested["class"] { out["class"] = v }
            }
        }
        return out
    }

    // MARK: - 内部工具

    /// 将 Swift 字典转为 JSON 字符串（JS 中使用）
    private func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8) else {
            return "'\(s)'"
        }
        // JSONSerialization 输出 ["s"]，去掉 [ 和 ] 得到 "s"
        return String(str.dropFirst().dropLast())
    }

    /// 1.5.4 起参数构造集中在 positionalArgs / jsArgsJSON，这里保留兼容入口。
    private func buildJSArgs(args: [String: Any], context: JSContext) -> [Any] {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let str = String(data: data, encoding: .utf8),
              let obj = context.evaluateScript("(\(str))") else { return [] }
        return [obj as Any]
    }

    /// 下载模块源码（支持 .js.md5 → 取 MD5 → 下载对应 JS 文件）
    private func fetchModuleCode(jsURL: String) async -> String? {
        let network = NetworkManager.shared

        // 如果是 .js.md5，先取 MD5 再下载对应文件
        let actualURL: String
        if jsURL.lowercased().hasSuffix(".js.md5") {
            guard let md5Data = try? await network.data(from: jsURL),
                  let md5 = String(data: md5Data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let baseURL = jsURL.components(separatedBy: ".md5").first else {
                return nil
            }
            actualURL = "\(baseURL)/\(md5)"
        } else {
            actualURL = jsURL
        }

        // 尝试构造的 URL
        if let data = try? await network.data(from: actualURL),
           let code = String(data: data, encoding: .utf8),
           !code.contains("<html>") {
            return code
        }

        // Fallback：对 .js.md5 URL，尝试跟随 .js 的 302 重定向
        if jsURL.lowercased().hasSuffix(".js.md5"),
           let jsPath = jsURL.components(separatedBy: ".md5").first,
           let data = try? await network.data(from: jsPath),
           let code = String(data: data, encoding: .utf8),
           !code.contains("<html>") {
            return code
        }

        return nil
    }

    /// 创建带原生桥接的 JSContext
    private func createContext() -> JSContext {
        let context = JSContext()!
        // 原生函数先注入，后面的 JS shim 才能在运行时解析到它们
        setupNativeBridge(context: context)
        setupConsole(context: context)
        setupRuntimeShims(context: context)
        setupDayjs(context: context)
        setupCryptoShims(context: context)
        setupReqShim(context: context)
        return context
    }

    /// 注入并执行模块代码
    private func injectModule(context: JSContext, code: String) -> Bool {
        context.evaluateScript(code)
        return !context.exception.isUndefined
    }

    // MARK: - JS Shims

    /// 1.5.4：补齐猫爪 / TVBox Spider 打包脚本常用的运行时全局。
    /// 旧实现只有 console/dayjs/CryptoJS/req，webpack bundle 一注入就抛
    /// `module is not defined` / `require is not a function`，整份脚本白跑。
    private func setupRuntimeShims(context: JSContext) {
        let lines = [
            "var __MTV_G__ = (function(){ return this; })();",
            "var module = { exports: {} }; var exports = module.exports;",
            "var window = __MTV_G__; var self = __MTV_G__; var global = __MTV_G__;",
            "var process = { env: {}, platform: 'ios', version: '1.0', argv: [] };",
            "var require = function(name) {",
            "  if (name === 'dayjs') return (typeof dayjs !== 'undefined') ? dayjs : function(){};",
            "  if (name === 'crypto-js' || name === 'CryptoJS') return (typeof CryptoJS !== 'undefined') ? CryptoJS : {};",
            "  if (name === 'crypto') return { createHash: function(){ return { update: function(){ return this; }, digest: function(){ return ''; } }; } };",
            "  return {};",
            "};",
            "var __mtv_store__ = {};",
            "var localStorage = {",
            "  getItem: function(k){ return Object.prototype.hasOwnProperty.call(__mtv_store__, k) ? __mtv_store__[k] : null; },",
            "  setItem: function(k,v){ __mtv_store__[k] = String(v); },",
            "  removeItem: function(k){ delete __mtv_store__[k]; },",
            "  clear: function(){ __mtv_store__ = {}; }",
            "};",
            "var setTimeout = function(fn){ try { if (typeof fn === 'function') fn(); } catch(e){} return 0; };",
            "var clearTimeout = function(){}; var setInterval = function(){ return 0; }; var clearInterval = function(){};",
            "var Buffer = { from: function(s){ return { toString: function(enc){ return enc === 'base64' ? nativeBase64(String(s), false) : String(s); } }; } };",
            "var btoa = function(s){ return nativeBase64(String(s), false); };",
            "var atob = function(s){ return nativeBase64(String(s), true); };",
            "function fetch(url, opts) {",
            "  opts = opts || {};",
            "  var method = (opts.method || 'GET').toUpperCase();",
            "  var headers = opts.headers || {};",
            "  var body = null;",
            "  if (opts.body != null) { body = (typeof opts.body === 'string') ? opts.body : JSON.stringify(opts.body); }",
            "  var r = nativeReq(String(url), String(method), JSON.stringify(headers), body) || {};",
            "  var d = r.data;",
            "  var text = (typeof d === 'string') ? d : (function(){ try { return JSON.stringify(d); } catch(e) { return ''; } })();",
            "  var status = r.status || 200;",
            "  var resp = {",
            "    ok: status >= 200 && status < 300, status: status, url: String(url),",
            "    text: function(){ return Promise.resolve(text); },",
            "    json: function(){ return Promise.resolve((function(){ try { return JSON.parse(text); } catch(e) { return null; } })()); },",
            "    headers: { get: function(){ return null; } }",
            "  };",
            "  return Promise.resolve(resp);",
            "}",
            "function print(x){ try { console.log(String(x)); } catch(e){} }",
            "var document = { cookie: '', title: '', referrer: '',",
            "  getElementById: function(){ return null; },",
            "  querySelector: function(){ return null; },",
            "  querySelectorAll: function(){ return []; },",
            "  createElement: function(){ return { style: {}, setAttribute: function(){}, appendChild: function(){} }; },",
            "  addEventListener: function(){}, head: { appendChild: function(){} }, body: { appendChild: function(){} } };",
            "var navigator = { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15', platform: 'iPhone', language: 'zh-CN', appVersion: '16.3' };",
            "var location = { href: '', protocol: 'https:', host: '', hostname: '', pathname: '/', search: '' };",
            "var screen = { width: 1170, height: 2532 };",
            "var TextEncoder = function(){}; TextEncoder.prototype.encode = function(s){ try { return Array.from(unescape(encodeURIComponent(String(s))), function(c){ return c.charCodeAt(0); }); } catch(e) { return []; } };",
            "var TextDecoder = function(){}; TextDecoder.prototype.decode = function(a){ try { return decodeURIComponent(escape(String.fromCharCode.apply(null, a))); } catch(e) { return ''; } };",
        ]
        context.evaluateScript(lines.joined(separator: "\n"))
    }


    private func setupConsole(context: JSContext) {
        context.evaluateScript("""
        var __mtv_logs__ = [];
        function __mtv_log__(level, args) {
            try {
                var s = [];
                for (var i = 0; i < args.length; i++) {
                    try { s.push((typeof args[i] === 'object') ? JSON.stringify(args[i]) : String(args[i])); }
                    catch (e) { s.push(String(args[i])); }
                }
                if (__mtv_logs__.length < 200) __mtv_logs__.push(level + ': ' + s.join(' ').slice(0, 400));
            } catch (e) {}
        }
        var console = {
            log: function(){ __mtv_log__('log', arguments); },
            warn: function(){ __mtv_log__('warn', arguments); },
            error: function(){ __mtv_log__('error', arguments); },
            info: function(){ __mtv_log__('info', arguments); },
            debug: function(){ __mtv_log__('debug', arguments); }
        };
        """)
    }

    /// 最小化 dayjs shim —— 覆盖模块中 dayjs().valueOf() / .unix() / .format() / .subtract()
    private func setupDayjs(context: JSContext) {
        context.evaluateScript("""
        function dayjs(input) {
            var d = input ? new Date(input) : new Date();
            return {
                valueOf: function() { return d.getTime(); },
                unix: function() { return Math.floor(d.getTime() / 1000); },
                format: function(f) {
                    var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
                    return f
                        .replace('YYYY', d.getFullYear())
                        .replace('MM', pad(d.getMonth() + 1))
                        .replace('DD', pad(d.getDate()))
                        .replace('HH', pad(d.getHours()))
                        .replace('mm', pad(d.getMinutes()))
                        .replace('ss', pad(d.getSeconds()));
                },
                add: function(n, unit) {
                    var nd = new Date(d);
                    if (unit === 'day' || unit === 'd') nd.setDate(nd.getDate() + n);
                    else if (unit === 'hour' || unit === 'h') nd.setHours(nd.getHours() + n);
                    else if (unit === 'minute' || unit === 'm') nd.setMinutes(nd.getMinutes() + n);
                    else if (unit === 'second' || unit === 's') nd.setSeconds(nd.getSeconds() + n);
                    else if (unit === 'month') nd.setMonth(nd.getMonth() + n);
                    else if (unit === 'year') nd.setFullYear(nd.getFullYear() + n);
                    return dayjs(nd);
                },
                subtract: function(n, unit) { return this.add(-n, unit); },
                toDate: function() { return d; }
            };
        }
        dayjs.utc = function(input) { return dayjs(input); };
        dayjs.duration = function(v, u) { return { asMilliseconds: function() { return v; } }; };
        """)
    }

    /// CryptoJS 最小化 shim（MD5 / Hex / Base64 / AES）
    private func setupCryptoShims(context: JSContext) {
        context.evaluateScript("""
        var CryptoJS = CryptoJS || {};

        // MD5
        CryptoJS.MD5 = function(s) {
            var r = nativeMd5(typeof s === 'string' ? s : s.toString());
            return { toString: function() { return r; } };
        };

        // 编码工具
        CryptoJS.enc = {
            Utf8: {
                parse: function(s) { return s; },
                stringify: function(s) { return typeof s === 'string' ? s : ''; }
            },
            Hex: {
                stringify: function(s) { return typeof s === 'string' ? s : ''; },
                parse: function(s) { return s; }
            },
            Base64: {
                stringify: function(s) { return nativeBase64(typeof s === 'string' ? s : s.toString(), false); },
                parse: function(s) { return nativeBase64(typeof s === 'string' ? s : s.toString(), true); }
            }
        };

        // AES 解密
        CryptoJS.AES = {
            decrypt: function(src, key, opts) {
                var cipherText = (typeof src === 'object' && src.ciphertext) ? nativeBase64(src.ciphertext.toString(), true) : src.toString();
                var k = typeof key === 'string' ? key : key.toString();
                var iv = (opts && opts.iv) ? (typeof opts.iv === 'string' ? opts.iv : opts.iv.toString()) : '';
                var decrypted = nativeAesDecrypt(cipherText, k, iv);
                return {
                    toString: function(enc) { return decrypted; }
                };
            }
        };

        // Pad
        CryptoJS.pad = { Pkcs7: {} };
        CryptoJS.mode = { CBC: {} };
        """)
    }

    /// axios-style req shim
    private func setupReqShim(context: JSContext) {
        context.evaluateScript("""
        function req(url, opts) {
            opts = opts || {};
            var method = (opts.method || 'get').toLowerCase();
            var headers = opts.headers || {};
            var headersJSON = JSON.stringify(headers);
            var body = null;
            if (opts.data) {
                if (typeof opts.data === 'string') {
                    body = opts.data;
                } else {
                    body = JSON.stringify(opts.data);
                    if (!headers['Content-Type']) {
                        headers['Content-Type'] = 'application/json';
                        headersJSON = JSON.stringify(headers);
                    }
                }
            }
            var result = nativeReq(url, method, headersJSON, body);
            if (typeof result === 'string') {
                try { result = JSON.parse(result); } catch(e) {}
            }
            return result;
        }
        req.get = function(url, opts) {
            opts = opts || {};
            opts.method = 'get';
            return req(url, opts);
        };
        req.post = function(url, opts) {
            opts = opts || {};
            opts.method = 'post';
            return req(url, opts);
        };
        """)
    }

    /// 注入 nativeReq / nativeBase64 / nativeMd5 / nativeAesDecrypt 桥接
    private func setupNativeBridge(context: JSContext) {
        // nativeReq
        let reqBlock: @convention(block) (String, String, String?, String?) -> [String: Any]? = { url, method, headersJSON, body in
            SpiderBridge.nativeReq(url: url, method: method, headersJSON: headersJSON, body: body)
        }
        context.setObject(reqBlock, forKeyedSubscript: "nativeReq" as NSString)

        // nativeBase64
        let b64Block: @convention(block) (String, Bool) -> String = { input, decode in
            SpiderBridge.nativeBase64(input, decode: decode)
        }
        context.setObject(b64Block, forKeyedSubscript: "nativeBase64" as NSString)

        // nativeMd5
        let md5Block: @convention(block) (String) -> String = { input in
            SpiderBridge.nativeMd5(input)
        }
        context.setObject(md5Block, forKeyedSubscript: "nativeMd5" as NSString)

        // nativeAesDecrypt
        let aesBlock: @convention(block) (String, String, String) -> String = { cipher, key, iv in
            SpiderBridge.nativeAesDecrypt(ciphertext: cipher, key: key, iv: iv)
        }
        context.setObject(aesBlock, forKeyedSubscript: "nativeAesDecrypt" as NSString)
    }

    // MARK: - JS 方法调用

    private func callMethod(context: JSContext, name: String, args: [Any]) -> [String: Any]? {
        let fn = context.objectForKeyedSubscript(name)
        guard let fn = fn, !fn.isUndefined else { return nil }

        var jsArgs: [Any] = []
        for arg in args {
            if let dict = arg as? [String: Any] {
                // 通过 JSON 序列化将 Dictionary 转为 JS 对象
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let jsObj = context.evaluateScript("(\(jsonString))")
                    jsArgs.append(jsObj as Any)
                } else {
                    jsArgs.append(jsObject(from: [:], context: context))
                }
            } else {
                jsArgs.append(arg)
            }
        }

        let result = fn.call(withArguments: jsArgs)
        guard let result = result, !result.isUndefined else { return nil }
        guard let dict = result.toObject() as? [String: Any] else { return nil }
        return dict
    }

    /// 将 Swift 字典转为 JSValue（用于参数传递）
    private func jsObject(from dict: [String: Any], context: JSContext) -> JSValue {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return JSValue(object: NSDictionary(), in: context)
        }
        return context.evaluateScript("(\(jsonString))")
    }

    // MARK: - 配置构建

    /// 从 home() 返回的 { class: [...] } 构建 TVBoxConfig
    private func buildTVBoxConfig(
        from homeResult: [String: Any],
        context: JSContext,
        siteKey: String,
        siteName: String,
        jsCode: String
    ) -> TVBoxConfig? {
        // 解析分类列表
        guard let classList = homeResult["class"] as? [[String: Any]], !classList.isEmpty else {
            return nil
        }

        var categories: [String] = []
        for cat in classList {
            if let name = cat["type_name"] as? String {
                categories.append(name)
            }
        }

        let site = Site(
            key: siteKey,
            name: siteName,
            type: 3,  // Spider 类型
            api: nil,
            searchable: 1,
            quickSearch: 1,
            categories: categories.isEmpty ? nil : categories
        )

        // 将 JSContext 和模块代码存入全局引用，后续调用复用
        SpiderContextManager.shared.register(key: siteKey, context: context)
        SpiderContextManager.shared.registerModuleCode(key: siteKey, code: jsCode)

        return TVBoxConfig(sites: [site])
    }
}

// MARK: - JSContext 生命周期管理

/// 管理已加载的 Spider JSContext，避免重复加载
final class SpiderContextManager {
    static let shared = SpiderContextManager()
    private var contexts: [String: JSContext] = [:]
    private var moduleCodes: [String: String] = [:]
    // 多订阅并发加载 + 后台诊断会同时读写字典，之前是无锁的
    private let lock = NSLock()
    private init() {}

    func register(key: String, context: JSContext) {
        lock.lock(); defer { lock.unlock() }
        contexts[key] = context
    }

    func context(for key: String) -> JSContext? {
        lock.lock(); defer { lock.unlock() }
        return contexts[key]
    }

    func registerModuleCode(key: String, code: String) {
        lock.lock(); defer { lock.unlock() }
        moduleCodes[key] = code
    }

    func moduleCode(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return moduleCodes[key]
    }

    func registeredKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(moduleCodes.keys).sorted()
    }

    func remove(key: String) {
        lock.lock(); defer { lock.unlock() }
        contexts.removeValue(forKey: key)
        moduleCodes.removeValue(forKey: key)
    }
}
