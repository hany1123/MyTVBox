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

        // 1.5.6：iOS 16.3 的 JSC 不支持正则后行断言 (?<= / (?<!。
        // 6.6MB 的 esbuild bundle 只要有一处，整份脚本在**解析阶段**就被拒，
        // 一行都不会执行（真机诊断：SyntaxError: Invalid regular expression:
        // invalid group specifier name，注册表全空、TARGET NOT FOUND）。
        // 1.5.9：用 .js.md5 的 hash 作源指纹，缓存「语法降级 + factory map」。
        // 这两步每次都要扫 6.6MB，同一份 bundle 只要做一次。
        let cacheKey = SpiderContextManager.shared.cacheKey(
            forSpiderKey: spiderKey, codeLength: jsCode.utf8.count)
        let patched: String
        let fixes: Int
        if let hit = SpiderContextManager.shared.preprocessedCode(for: cacheKey) {
            patched = hit
            fixes = 0
        } else {
            let p = Self.downgradeForJSC(jsCode)
            patched = p.0
            fixes = p.1
            SpiderContextManager.shared.setPreprocessedCode(p.0, for: cacheKey)
        }
        // 1.5.9：源站每次重新混淆，按结构抠出 meta.key → 工厂函数名，
        // 让 router 能精确实例化目标 spider，不再只靠碰运气的模块表扫描。
        var factoryDict: [String: String] = [:]
        if let hit = SpiderContextManager.shared.cachedFactoryMap(for: cacheKey) {
            factoryDict = hit
        } else {
            for f in extractFactoryMap(from: jsCode) where !f.fn.isEmpty {
                factoryDict[f.key] = f.fn
            }
            SpiderContextManager.shared.setCachedFactoryMap(factoryDict, for: cacheKey)
        }
        context.setObject(factoryDict, forKeyedSubscript: "__MTV_FACTORY_MAP__" as NSString)
        // webpack 打包脚本常在缺模块时抛异常，但已经把部分 spider
        // 注册到全局了 —— 不能一遇异常就整轮放弃，清掉异常继续尝试路由。
        context.evaluateScript(patched)
        if let exception = context.exception, !exception.isUndefined {
            print("[SpiderEngine] bundle 注入告警 (降级 \(fixes) 处): \(exception.toString() ?? "unknown")")
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
                if (!o || o === __mtv_stub__) return false;
                for (var k in aliases) {
                    var ns = aliases[k] || [];
                    for (var i = 0; i < ns.length; i++) {
                        if (typeof o[ns[i]] === 'function') return true;
                    }
                }
                return hasMethod(o, 'init') || hasMethod(o, 'getName');
            }
            // 1.5.8：真机报告显示这份 esbuild 包顶层 module.exports 是
            // fastify/avvio 服务端 (start/stop)，真 spider 藏在 q() 惰性模块里。
            // 猫爪 iOS (CatVodSpiderios) 的 spider 是工厂函数，返回
            // { meta:{key,name,type}, init, home, category, detail, play, search }。
            function metaOf(o) {
                try { return (o && o.meta && typeof o.meta === 'object') ? o.meta : null; }
                catch (e) { return null; }
            }
            function metaKey(o) {
                var m = metaOf(o);
                try { return m ? String(m.key || '') : ''; } catch (e) { return ''; }
            }
            function materialize(o) {
                if (!o || o === __mtv_stub__) return o;
                if (typeof o !== 'function') return o;
                if (metaKey(o) || hasAnyFn(o)) return o;
                var forms = [
                    function(){ return o({}); },
                    function(){ return new o(); },
                    function(){ return o(); }
                ];
                for (var i = 0; i < forms.length; i++) {
                    try {
                        var r = forms[i]();
                        if (r && r !== o && (metaKey(r) || hasAnyFn(r))) return r;
                    } catch (e) {}
                }
                return o;
            }
            var __mtv_mod_cache__ = null;
            function moduleSpiders() {
                if (__mtv_mod_cache__) return __mtv_mod_cache__;
                var out = [], seen = [], mk = [];
                try { mk = Object.keys(G); } catch (e) { __mtv_mod_cache__ = out; return out; }
                var skip = G.__MTV_SKIP__ || [];
                var deadline = Date.now() + 8000;
                for (var i = 0; i < mk.length && i < 700 && out.length < 120 && Date.now() < deadline; i++) {
                    var mn = mk[i];
                    if (!/^[A-Za-z_$][A-Za-z0-9_$]{0,8}$/.test(mn)) continue;
                    if (skip.indexOf(mn) >= 0) continue;
                    var mf = null;
                    try { mf = G[mn]; } catch (e) { continue; }
                    if (typeof mf !== 'function' || mf === __mtv_stub__) continue;
                    var mr = null;
                    try { mr = mf(); } catch (e) { continue; }
                    if (!mr || mr === __mtv_stub__) continue;
                    var cands = [mr], subs = [];
                    try { subs = Object.keys(mr).slice(0, 20); } catch (e) {}
                    for (var s = 0; s < subs.length; s++) {
                        try { cands.push(mr[subs[s]]); } catch (e) {}
                    }
                    for (var c = 0; c < cands.length && out.length < 80; c++) {
                        var raw = cands[c];
                        if (!raw || raw === __mtv_stub__) continue;
                        if (typeof raw !== 'object' && typeof raw !== 'function') continue;
                        var built = materialize(raw);
                        if (!built || built === __mtv_stub__) continue;
                        if (!metaKey(built) && !hasAnyFn(built)) continue;
                        var sig = metaKey(built);
                        if (sig && seen.indexOf(sig) >= 0) continue;
                        if (sig) seen.push(sig);
                        out.push(built);
                    }
                }
                __mtv_mod_cache__ = out;
                return out;
            }
            function pickSpider() {
                // 1.5.9：源码静态抠出的 meta.key → 工厂名，抗混淆，优先级最高。
                // 真机报告里 push 的工厂 Fx0 没被模块表探测到，但源码里明明白白。
                var fmap = G.__MTV_FACTORY_MAP__ || {};
                if (key && fmap[key]) {
                    var ff = null;
                    try { ff = G[fmap[key]]; } catch (e) {}
                    if (typeof ff === 'function') {
                        var builtFactory = materialize(ff);
                        if (metaKey(builtFactory) === key) return builtFactory;
                    }
                }
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
                // 1.5.8：模块表才是这份 esbuild 包里唯一可靠的 spider 来源。
                // 必须放在全局扫描之前 —— 万能 Proxy stub 的任意属性会让
                // go[key] 命中，把 fallback 污染成一个没有任何方法的空函数。
                var modsMid = moduleSpiders();
                if (key) {
                    for (var mm2 = 0; mm2 < modsMid.length; mm2++) {
                        if (metaKey(modsMid[mm2]) === key) return modsMid[mm2];
                    }
                }
                for (var mm3 = 0; mm3 < modsMid.length; mm3++) {
                    if (hasMethod(modsMid[mm3], 'home') || hasMethod(modsMid[mm3], 'homeContent')) return modsMid[mm3];
                }
                if (modsMid.length) return modsMid[0];
                var single = look(G.__JS_SPIDER__);
                if (single) return single;
                // 1.5.6：esbuild bundle 常把 spider 挂到自定义 var 上，
                // 已知注册表名单覆盖不到。扫一遍全局对象找带 spider 方法的那个。
                try {
                    var gk = Object.keys(G);
                    var fallback = null;
                    for (var gi = 0; gi < gk.length; gi++) {
                        var go = G[gk[gi]];
                        if (!go || go === __mtv_stub__ || (typeof go !== 'object' && typeof go !== 'function')) continue;
                        if (key && go[key] && hasAnyFn(go[key])) return go[key];
                        if (key && go[key]) fallback = fallback || go[key];
                        if (!key && hasAnyFn(go)) return go;
                        if (!fallback && go.default && hasAnyFn(go.default)) fallback = go.default;
                        if (!fallback && hasAnyFn(go)) fallback = go;
                    }
                    if (fallback) return fallback;
                } catch (e) {}
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
                    var arg = { body: {}, extend: {}, ext: {} };
                    if (target !== G && typeof target.init === 'function') return target.init(arg);
                    if (typeof G.init === 'function') return G.init(arg);
                } catch (e) {}
                return null;
            }
            return { invoke: invoke, init: init };
        })()
        """

        guard let router = context.evaluateScript(routerScript), !router.isUndefined,
              let invoke = router.objectForKeyedSubscript("invoke"), !invoke.isUndefined else {
            print("[SpiderEngine] 路由器创建失败")
            return nil
        }
        // 1.5.8：猫爪 iOS spider 的 init 是 async 且吃 {body} 参数；
        // 不落地会让后续 home/category 拿不到 extend / filters。
        if let initRaw = router.objectForKeyedSubscript("init")?.call(withArguments: []) {
            _ = resolvePromiseLike(initRaw, context: context)
        }

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
        if !args.isEmpty {
            // 1.5.8：CatVodSpiderios 是单对象参数，业务字段在
            // o.body.id / o.body.pg / o.extend，不是 TVBox 的位置参数。
            addAttempt([args])
            addAttempt([["body": args] as [String: Any]])
            var mixed: [String: Any] = ["body": args, "extend": [:], "ext": [:]]
            for (k, v) in args { mixed[k] = v }
            addAttempt([mixed])
        }
        if attempts.isEmpty { addAttempt([]) }

        var weakResult: [String: Any]?
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
            // 参数形态不对时 spider 常返回 {} / {list:[]}，不能当成成功提前返回
            if hasPayload(dict) { return dict }
            if weakResult == nil { weakResult = dict }
        }
        return weakResult
    }

    // MARK: - 1.5.6 JSC 语法兼容

    /// iOS 16.3 的 JavaScriptCore 不支持正则后行断言 `(?<=` / `(?<!`。
    /// 只要 bundle 里出现一处，整份脚本会在**解析阶段**被拒（一行都不执行），
    /// 报 `SyntaxError: Invalid regular expression: invalid group specifier name`。
    /// 这类正则大多来自 Node polyfill，spider 业务不依赖；降级成非捕获组
    /// `(?:` 可让脚本完整加载。命名捕获组 `(?<name>` 不动（JSC 支持）。
    static func downgradeForJSC(_ code: String) -> (String, Int) {
        var out = code
        var total = 0
        for token in ["(?<=", "(?<!"] {
            let n = out.components(separatedBy: token).count - 1
            if n > 0 {
                out = out.replacingOccurrences(of: token, with: "(?:")
                total += n
            }
        }
        return (out, total)
    }

    /// 把 JSC 异常的行列信息 + 出错行源码写进诊断报告
    private func describeJSCException(_ e: JSValue, code: String, into out: inout [String]) {
        let line = Int(e.objectForKeyedSubscript("line")?.toInt32() ?? 0)
        let column = Int(e.objectForKeyedSubscript("column")?.toInt32() ?? 0)
        out.append("  异常位置: line=\(line) column=\(column)")
        let stack = e.objectForKeyedSubscript("stack")?.toString() ?? ""
        if !stack.isEmpty, stack != "undefined" {
            out.append("  stack: \(String(stack.prefix(400)))")
        }
        if line > 0 {
            let lines = code.components(separatedBy: .newlines)
            let idx = min(max(line - 1, 0), max(lines.count - 1, 0))
            if lines.indices.contains(idx) {
                out.append("  附近源码: \(String(lines[idx].prefix(400)))")
            }
        }
    }

    // MARK: - 1.5.7 源码静态取样

    /// 这份 6.6MB bundle 可能是 Node 服务端程序；即使运行时跑不通，
    /// 也要能把 meta / spider 方法定义 / 接口 URL 抠出来走「静态生成订阅」路线。
    private func appendSamples(of code: String, needles: [String],
                               perNeedle: Int, width: Int, into out: inout [String]) {
        for needle in needles {
            var cursor = code.startIndex
            var n = 0
            while n < perNeedle, cursor < code.endIndex,
                  let r = code.range(of: needle, options: .literal,
                                     range: cursor..<code.endIndex) {
                let start = code.index(r.lowerBound, offsetBy: -60,
                                       limitedBy: code.startIndex) ?? code.startIndex
                let end = code.index(r.upperBound, offsetBy: width,
                                     limitedBy: code.endIndex) ?? code.endIndex
                let snippet = String(code[start..<end])
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                out.append("  [\(needle)] \(snippet)")
                n += 1
                cursor = end
            }
        }
    }

    /// 1.5.9：从混淆过的 bundle 源码里静态抠出 `meta:{key:"K"` 对应的工厂函数名。
    /// 真机两轮报告 bundle 分别是 6627774 / 6629280 字节，变量名全变（Wx0→Fx0），
    /// 说明源站每次请求都重新混淆 —— 只能按结构提取，绝不能硬编码变量名。
    /// 纯字符串扫描，不用 NSRegularExpression，避免 Swift 转义地狱与大串正则开销。
    private func extractFactoryMap(from code: String, limit: Int = 90) -> [(key: String, fn: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        var cursor = code.startIndex
        let marker = "meta:{key:"
        while out.count < limit, cursor < code.endIndex,
              let r = code.range(of: marker, options: .literal,
                                 range: cursor..<code.endIndex) {
            var key = ""
            var q = r.upperBound
            if q < code.endIndex, code[q] == "\"" || code[q] == "'" {
                let quote = code[q]
                q = code.index(after: q)
                let s = q
                while q < code.endIndex, code[q] != quote { q = code.index(after: q) }
                if q < code.endIndex, s < q { key = String(code[s..<q]) }
            }
            // 往前 500 字符内找最近的 `function NAME(`
            let back = code.index(r.lowerBound, offsetBy: -500,
                                  limitedBy: code.startIndex) ?? code.startIndex
            let prefix = String(code[back..<r.lowerBound])
            var fn = ""
            if let fr = prefix.range(of: "function ", options: [.literal, .backwards]) {
                var p = fr.upperBound
                let s = p
                while p < prefix.endIndex {
                    let c = prefix[p]
                    if c.isLetter || c.isNumber || c == "_" || c == "$" {
                        p = prefix.index(after: p)
                    } else { break }
                }
                if p > s {
                    var after = p
                    while after < prefix.endIndex, prefix[after] == " " {
                        after = prefix.index(after: after)
                    }
                    if after < prefix.endIndex, prefix[after] == "(" {
                        fn = String(prefix[s..<p])
                    }
                }
            }
            if !key.isEmpty, !seen.contains(key) {
                seen.insert(key)
                out.append((key, fn))
            }
            cursor = code.index(r.upperBound, offsetBy: 1,
                                limitedBy: code.endIndex) ?? code.endIndex
        }
        return out
    }

    /// 轻量 URL 扫描（不在 6.6MB 上跑正则，避免卡住诊断线程）
    private func extractURLs(from code: String, limit: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var cursor = code.startIndex
        while out.count < limit, cursor < code.endIndex,
              let r = code.range(of: "http", options: [.literal, .caseInsensitive],
                                 range: cursor..<code.endIndex) {
            var end = r.lowerBound
            var n = 0
            while end < code.endIndex, n < 180 {
                let c = code[end]
                if c == "\"" || c == "'" || c == "`" || c == " " ||
                   c == "\n" || c == "\r" || c == ")" || c == "\\" ||
                   c == "<" || c == ">" { break }
                end = code.index(after: end)
                n += 1
            }
            let u = String(code[r.lowerBound..<end])
            if u.count > 14, u.contains("."), seen.insert(u).inserted { out.append(u) }
            cursor = end < code.endIndex ? code.index(after: end) : code.endIndex
        }
        return out
    }

    // MARK: - 1.5.5 真机诊断

    /// 在后台线程同步执行，输出一段可直接复制给开发者的运行时事实。
    /// 不依赖网络抓包，也不需要 Xcode 控制台。
    func diagnoseSync(site: Site?) -> String {
        var out: [String] = []
        let appVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        out.append("=== MyTVBox " + appVer + " (build " + buildVer + ") Spider 诊断 ===")

        // 1.7.3：先报端上 Node 状态。上一轮最大的问题就是「诊断里看不出 Node 到底起没起来」，
        // 只能靠站点 key 前缀（catpaw_ = JSC 路线，noderelay_ = Node 路线）反推。
        let rt = NodeRuntime.shared

        // 1.7.7：闪退排查要的第一手信息 —— 上次是怎么没的 + 现在跑的是哪份内核
        out.append("")
        out.append("--- 内核与崩溃 ---")
        if let k = rt.activeKernel {
            out.append("运行中内核    : \(k.source) \(k.bytes) B md5 \(k.md5)")
        } else {
            out.append("运行中内核    : (未记录到 kernel.txt)")
        }
        if let p = rt.pendingKernelMD5 {
            out.append("已下载待生效  : md5 \(p)（需完全退出 App 再打开）")
        }
        // 1.7.8：/config 到底慢在哪一步，直接看这两行
        out.append("本机源配置    : " + LocalSourceCache.lastProbe)
        out.append("配置缓存      : " + LocalSourceCache.describe())
        // 1.8.5：进程真实物理内存（含 V8 堆 + 视频缓冲 + 位图），判 Jetsam 的基准
        out.append("进程内存      : " + MemoryProbe.summary())
        // 1.8.4：老大问「慢是不是某些站点没加载」—— 直接把被跳过的坏站列出来
        let cooling = SiteHealth.shared.coolingKeys()
        out.append("站点健康      : " + (cooling.isEmpty
            ? "无冷却站（每个站都参与搜索）"
            : "冷却 \(cooling.count) 站（连续失败 ≥3 次，10 分钟内跳过）"))
        if !cooling.isEmpty {
            out.append("冷却站点      : " + cooling.prefix(12).joined(separator: ", ")
                       + (cooling.count > 12 ? " …" : ""))
            out.append("              : 这些站每次搜索都要等满超时，是「慢」的主因；成功一次会自动解禁")
        }
        // 1.8.0：闪退定位 —— 上次最后停在哪个动作上（`开` 之后没有对应的 `完`）
        // 1.8.2：只认「本次启动线之前」的内容，且必须同时给出上一轮最后一行。
        // 上一版只找 `开 `，最后一行是 `弃 搜索` 时就报「无记录」—— 恰是崩溃现场。
        if let step = SessionTrace.interruptedStep() {
            out.append("上次最后停在  : \(step)（这一步没走完 → 崩在这里）")
        } else if let last = SessionTrace.previousLastLine() {
            // 1.8.4：措辞改中性。末行是 `弃/记/完` 不代表一定正常收尾 ——
            // 进程完全可能死在那一行之后、下一个动作还没来得及写「开」。
            out.append("上次最后停在  : \(last)（上一轮末行；若仍闪退，则崩在这条之后）")
        } else {
            out.append("上次最后停在  : （本版首次启动，还没有上一轮记录）")
        }
        let prevTail = SessionTrace.previousTail(3)
        if !prevTail.isEmpty {
            out.append("上一轮末 3 行 :")
            for line in prevTail {
                out.append("  " + line)
            }
        }
        let marks = SessionTrace.recent(8)
        if !marks.isEmpty {
            out.append("最近轨迹      :")
            for line in marks {
                out.append("  " + line)
            }
        }
        if let crash = CrashGuard.lastReport() {
            out.append("上次崩溃记录  :")
            for line in crash.split(separator: "\n").suffix(24) {
                out.append("  " + line)
            }
        } else {
            out.append("上次崩溃记录  : 无（若是闪退，多半是内存被系统回收或 V8 堆溢出）")
        }

        out.append("")
        out.append("--- 端上 Node 运行时 ---")
        out.append("node ready    : \(rt.isReady ? "YES" : "NO")")
        // 1.8.6：node_start 是阻塞调用，它返回 = Node 已经结束。
        // 以前完全不记退出码，才会出现「node ready YES 却全连不上」的假象。
        out.append("node 已退出   : \(rt.nodeDidExit ? "YES" : "NO")")
        out.append("node 退出码   : \(rt.lastExitCode.map(String.init) ?? "—")（9=启动参数不被接受）")
        out.append("node 启动故障 : \(rt.bootFailureText ?? "无")")
        out.append("node baseURL  : \(rt.baseURL)")
        out.append("relay baseURL : " + (NodeRelayService.shared.baseURL ?? "nil"))
        // 1.8.5：12 行只够看到 undici 栈的尾巴，看不到错误首行和内存曲线
        let logTail = rt.tailLog(lines: 40)
        out.append("node.log 尾部 :")
        for line in logTail.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append("  " + line)
        }
        out.append("")
        // 1.8.5：不再押单一假设，把 6 类原因的证据逐项列出来
        out.append(contentsOf: CrashDiagnostic.lines())
        out.append("--- 站点路由 ---")
        if let site {
            let isNode = NodeRelayService.isNodeSite(site)
            let isSpider = SpiderEngine.isSpiderSite(site)
            let hasModule = SpiderContextManager.shared.moduleCode(for: site.key) != nil
            out.append("isNodeSite    : \(isNode)")
            if site.key.hasPrefix("catpaw_") {
                out.append("  !! key 前缀 catpaw_ = 旧 JSC 路线，端上必然跑不起来；")
                out.append("     正常应该是 noderelay_*（来自端上 Node 的 /config）")
            }
            out.append("isSpiderSite  : \(isSpider)")
            out.append("有 moduleCode : \(hasModule)")
        } else {
            out.append("（未选中站点）")
        }
        out.append("")

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
            if let site, NodeRelayService.isNodeSite(site) {
                out.append("该站点走端上 Node（POST \(NodeRelayService.shared.baseURL ?? "")/spider/…），")
                out.append("不需要也不会注册 bundle —— 后面的 JSC 注入诊断对它没有意义。")
            } else {
                out.append("!! 该站点没有注册 bundle（moduleCode）。")
                out.append("若上面的 keys 里有相近 key，说明合并池改名后没同步。")
            }
            return out.joined(separator: "\n")
        }

        out.append("bundle 字节数    : \(code.utf8.count)")
        out.append("bundle MD5      : " + (SpiderContextManager.shared.sourceHash(for: site.key) ?? "未知（本轮未走 .js.md5 索引）"))
        out.append("预处理缓存键    : " + SpiderContextManager.shared.cacheKey(forSpiderKey: site.spiderKey, codeLength: code.utf8.count))
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

        // 1.5.7：运行时路线可能被 Node 依赖卡死，先把源码里的站点信息抠出来
        out.append("")
        out.append("--- 源码取样：meta / spider 方法 ---")
        appendSamples(of: code,
                      needles: ["meta:{", "meta: {", "homeContent", "categoryContent",
                                "detailContent", "playerContent", "module.exports",
                                "__JS_SPIDER__"],
                      perNeedle: 3, width: 200, into: &out)
        // 1.5.9：源站每次重新混淆，按结构把 meta.key → 工厂名抠出来，
        // 下一轮报告能直接对照「目标 key 的工厂在不在全局」。
        let factories = extractFactoryMap(from: code)
        out.append("")
        out.append("--- FACTORY MAP（源码 meta.key → 工厂函数名）---")
        out.append("共 " + String(factories.count) + " 个：" + factories.prefix(90).map { $0.key + ":" + ($0.fn.isEmpty ? "?" : $0.fn) }.joined(separator: ", "))
        let urls = extractURLs(from: code, limit: 80)
        out.append("")
        out.append("--- URL 样本 (\(urls.count)) ---")
        for u in urls { out.append("  \(u)") }

        let key = site.spiderKey ?? ""

        // 1) 原始注入：保留最原始的错误，便于对照
        let rawContext = createContext()
        rawContext.evaluateScript(code)
        out.append("")
        out.append("--- 原始注入 ---")
        if let e = rawContext.exception, !e.isUndefined {
            out.append("!! 原始注入异常: \(e.toString() ?? "unknown")")
            describeJSCException(e, code: code, into: &out)
            rawContext.exception = nil
        } else {
            out.append("原始注入: 成功")
        }

        // 2) 降级注入：与 App 实际执行路径完全一致
        let (patched, fixes) = Self.downgradeForJSC(code)
        out.append("")
        out.append("--- 语法降级后注入（实际生效路径）---")
        out.append("lookbehind 降级处数: \(fixes)")
        let context = createContext()
        let factoryNames = factories.map { $0.fn }.filter { !$0.isEmpty }
        context.setObject(factoryNames, forKeyedSubscript: "__MTV_FACTORY_NAMES__" as NSString)
        var factoryDict: [String: String] = [:]
        for f in factories where !f.fn.isEmpty { factoryDict[f.key] = f.fn }
        context.setObject(factoryDict, forKeyedSubscript: "__MTV_FACTORY_MAP__" as NSString)
        context.evaluateScript(patched)
        if let e = context.exception, !e.isUndefined {
            out.append("!! 降级后仍有异常: \(e.toString() ?? "unknown")")
            describeJSCException(e, code: patched, into: &out)
            context.exception = nil
        } else {
            out.append("降级后注入: 成功")
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
                if (!hit && ex && (ex.homeContent || ex.home || ex.homeVod || ex.categoryContent || ex.category)) hit = ex;
            } catch (e) { lines.push('module.exports probe err: ' + e); }
            lines.push('GLOBAL fns=[' + fns(G).slice(0, 60).join(',') + ']');
            lines.push('GLOBAL spider-ish keys=[' + keys(G).filter(function(k){ return /spider|js_|catpaw/i.test(k); }).slice(0, 40).join(',') + ']');
            // 1.5.6：注册名未知时，扫全部全局对象找带 spider 方法的候选
            var spiderNames = ['home','homeContent','homeVod','category','categoryContent',
                               'detail','detailContent','play','playerContent','search','searchContent'];
            function looksSpider(o) {
                if (!o || o === __mtv_stub__ || (typeof o !== 'object' && typeof o !== 'function')) return false;
                for (var si = 0; si < spiderNames.length; si++) {
                    if (typeof o[spiderNames[si]] === 'function') return true;
                }
                return false;
            }
            var found = [];
            try {
                var gk = Object.keys(G);
                for (var gi = 0; gi < gk.length && found.length < 24; gi++) {
                    try {
                        var go = G[gk[gi]];
                        if (!go) continue;
                        if (key && go[key] && looksSpider(go[key])) {
                            found.push(gk[gi] + '[' + key + '] fns=[' + fns(go[key]).slice(0, 20).join(',') + ']');
                            if (!hit) hit = go[key];
                        }
                        if (looksSpider(go)) {
                            found.push(gk[gi] + ' fns=[' + fns(go).slice(0, 20).join(',') + ']');
                            if (!hit && !key) hit = go;
                        }
                        if (go.default && looksSpider(go.default)) {
                            found.push(gk[gi] + '.default fns=[' + fns(go.default).slice(0, 20).join(',') + ']');
                            if (!hit) hit = go.default;
                        }
                        var sub = Object.keys(go).slice(0, 10);
                        for (var bi = 0; bi < sub.length && found.length < 24; bi++) {
                            if (looksSpider(go[sub[bi]])) {
                                found.push(gk[gi] + '.' + sub[bi] + ' fns=[' + fns(go[sub[bi]]).slice(0, 15).join(',') + ']');
                                if (!hit && key && sub[bi] === key) hit = go[sub[bi]];
                            }
                        }
                    } catch (e2) {}
                }
            } catch (e3) { lines.push('global scan err: ' + e3); }
            lines.push('GLOBAL spider candidates (' + found.length + '):');
            for (var fi = 0; fi < found.length; fi++) lines.push('  ' + found[fi]);
            // 顶层初始化链可能在中间抛错，spider 模块还没被 require。
            // esbuild 的 q() 返回的惰性加载器本身是全局函数，直接调一遍找导出。
            var probed = [];
            try {
                var mk = Object.keys(G);
                var __pskip__ = G.__MTV_SKIP__ || [];
                var __probe_deadline__ = Date.now() + 8000;
                for (var mi = 0; mi < mk.length && mi < 700 && probed.length < 40 && Date.now() < __probe_deadline__; mi++) {
                    var mn = mk[mi];
                    if (!/^[A-Za-z_$][A-Za-z0-9_$]{0,8}$/.test(mn)) continue;
                    if (__pskip__.indexOf(mn) >= 0) continue;
                    var mf = G[mn];
                    if (typeof mf !== 'function' || mf === __mtv_stub__) continue;
                    try {
                        var mr = mf();
                        if (!mr) continue;
                        if (looksSpider(mr)) {
                            var mm = '';
                            try { mm = mr.meta ? JSON.stringify(mr.meta) : ''; } catch (e) {}
                            probed.push(mk[mi] + ' meta=' + (mm || '-') + ' fns=[' + fns(mr).slice(0, 20).join(',') + ']');
                            if (!hit) hit = mr;
                        }
                        try {
                            var msub = Object.keys(mr).slice(0, 12);
                            for (var mj = 0; mj < msub.length && probed.length < 12; mj++) {
                                if (looksSpider(mr[msub[mj]])) {
                                    probed.push(mk[mi] + '.' + msub[mj] + ' fns=[' + fns(mr[msub[mj]]).slice(0, 15).join(',') + ']');
                                    if (!hit) hit = mr[msub[mj]];
                                }
                            }
                        } catch (e5) {}
                    } catch (e4) {}
                }
            } catch (e6) { lines.push('module probe err: ' + e6); }
            lines.push('MODULE PROBE (' + probed.length + '):');
            for (var pi = 0; pi < probed.length; pi++) lines.push('  ' + probed[pi]);
            // 1.5.8：列出模块表里所有 meta.key，并按正式 execute 的规则路由一次
            var __route_keys__ = [], __route_hit__ = null;
            try {
                var rk = Object.keys(G);
                var __rskip__ = G.__MTV_SKIP__ || [];
                var __r_deadline__ = Date.now() + 8000;
                for (var ri = 0; ri < rk.length && ri < 700 && Date.now() < __r_deadline__; ri++) {
                    var rn = rk[ri];
                    if (!/^[A-Za-z_$][A-Za-z0-9_$]{0,8}$/.test(rn)) continue;
                    if (__rskip__.indexOf(rn) >= 0) continue;
                    var rf = null;
                    try { rf = G[rn]; } catch (e) { continue; }
                    if (typeof rf !== 'function' || rf === __mtv_stub__) continue;
                    try {
                        var rr = rf();
                        if (!rr) continue;
                        var rlist = [rr];
                        try { var rs = Object.keys(rr).slice(0, 15); for (var rj = 0; rj < rs.length; rj++) rlist.push(rr[rs[rj]]); } catch (e) {}
                        for (var rc = 0; rc < rlist.length; rc++) {
                            var ro = rlist[rc];
                            if (!ro || (typeof ro !== 'object' && typeof ro !== 'function')) continue;
                            var rmeta = null;
                            try { rmeta = ro.meta; } catch (e) {}
                            if (!rmeta) continue;
                            var rkey = '';
                            try { rkey = String(rmeta.key || ''); } catch (e) {}
                            if (!rkey) continue;
                            if (__route_keys__.indexOf(rkey) < 0) __route_keys__.push(rkey);
                            if (key && rkey === key && !__route_hit__) __route_hit__ = ro;
                        }
                    } catch (e) {}
                }
            } catch (e) { lines.push('META ROUTE err: ' + e); }
            var __fn_names__ = G.__MTV_FACTORY_NAMES__ || [];
            var __fn_live__ = [];
            for (var fi = 0; fi < __fn_names__.length && fi < 90; fi++) {
                var fnm = __fn_names__[fi];
                if (!fnm) continue;
                __fn_live__.push(fnm + ':' + (typeof G[fnm]));
            }
            lines.push('FACTORY GLOBAL (' + __fn_live__.length + '): [' + __fn_live__.join(',') + ']');
            lines.push('META ROUTE keys (' + __route_keys__.length + '): [' + __route_keys__.slice(0, 120).join(',') + ']');
            lines.push('META ROUTE hit for key=' + key + ': ' + (__route_hit__ ? 'YES' : 'NO'));
            if (__route_hit__) hit = __route_hit__;
            lines.push('TARGET: ' + (hit ? ('keys=[' + keys(hit).join(',') + '] fns=[' + fns(hit).join(',') + ']') : 'NOT FOUND'));
            if (hit) {
                var f = hit.homeContent || hit.home || hit.homeVod;
                if (typeof f === 'function') {
                    try {
                        var v = f.call(hit, { body: {}, extend: {} });
                        if (v && typeof v.then === 'function') {
                            G.__mtv_home_promise__ = v;
                            lines.push('HOME_RESULT: Promise (落地结果见下方)');
                        }
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

        // 1.5.9：把 home() 的 Promise 真正落地，报告里能看到分类/列表原文
        if let p = context.objectForKeyedSubscript("__mtv_home_promise__"), !p.isUndefined {
            _ = resolvePromiseLike(p, context: context)
            let text = context.evaluateScript("(function(){ try { var s = JSON.stringify(__mtv_value__); return String(s === undefined ? __mtv_value__ : s).slice(0, 900); } catch(e) { return '落地失败: ' + e; } })()")?.toString() ?? "nil"
            out.append("HOME_RESULT 落地: " + text)
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

    /// 1.5.8：多参数形态依次试时，`{}` / `{list:[]}` 这类空壳不能算成功，
    /// 否则真正对的那次调用永远轮不到。
    private func hasPayload(_ dict: [String: Any]) -> Bool {
        for (k, v) in dict {
            if k == "__mtv_error__" { continue }
            if let a = v as? [Any], !a.isEmpty { return true }
            if let d = v as? [String: Any], !d.isEmpty { return true }
            if let s = v as? String, !s.isEmpty { return true }
            if let n = v as? NSNumber, n.intValue != 0 { return true }
        }
        return false
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
            "var process = { env: {}, platform: 'ios', version: 'v18.0.0', argv: [], pid: 1, ppid: 1, nextTick: function(f){ try { if (typeof f === 'function') f(); } catch(e){} }, hrtime: (function(){ var h = function(){ return [0, 0]; }; h.bigint = function(){ try { return BigInt(Date.now()) * BigInt(1000000); } catch(e) { return Date.now() * 1000000; } }; return h; })(), cpuUsage: function(){ return { user: 0, system: 0 }; }, memoryUsage: function(){ return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }; }, cwd: function(){ return '/'; }, uptime: function(){ return 0; }, on: function(){}, once: function(){}, exit: function(){}, versions: { node: '18.0.0' }, stdout: { write: function(){} }, stderr: { write: function(){} } };",
            "var __mtv_stub__ = (function(){",
            "  var f = function(){ return __mtv_stub__; };",
            "  if (typeof Proxy === 'undefined') return f;",
            "  try {",
            "    return new Proxy(f, {",
            "      get: function(t, k) {",
            "        if (k === 'then' || k === 'toJSON') return undefined;",
            "        if (k === 'home' || k === 'homeContent' || k === 'homeVod' || k === 'category' || k === 'categoryContent' || k === 'detail' || k === 'detailContent' || k === 'play' || k === 'playerContent' || k === 'search' || k === 'searchContent' || k === 'init') return undefined;",
            "        if (k === Symbol.toPrimitive) return function(){ return ''; };",
            "        if (k === '__esModule') return false;",
            "        if (k === 'length' || k === 'name' || k === 'prototype') return t[k];",
            "        return __mtv_stub__;",
            "      },",
            "      apply: function(){ return __mtv_stub__; },",
            "      construct: function(){ return __mtv_stub__; },",
            "      has: function(){ return true; }",
            "    });",
            "  } catch(e) { return f; }",
            "})();",
            "var __mtv_EE__ = function(){ this._h = {}; };",
            "__mtv_EE__.prototype.on = function(k,f){ (this._h[k]=this._h[k]||[]).push(f); return this; };",
            "__mtv_EE__.prototype.once = function(k,f){ return this.on(k,f); };",
            "__mtv_EE__.prototype.off = __mtv_EE__.prototype.removeListener = function(){ return this; };",
            "__mtv_EE__.prototype.emit = function(k){ var a=this._h[k]||[], args=[].slice.call(arguments,1); for(var i=0;i<a.length;i++){ try{a[i].apply(null,args);}catch(e){} } return a.length>0; };",
            "__mtv_EE__.prototype.removeAllListeners = function(){ this._h={}; return this; };",
            "var __mtv_ALS__ = function(){ this._s = {}; };",
            "__mtv_ALS__.prototype.getStore = function(){ return this._s; };",
            "__mtv_ALS__.prototype.run = function(s, f){ var o=this._s; this._s=s||{}; try { return f ? f() : undefined; } finally { this._s=o; } };",
            "__mtv_ALS__.prototype.enterWith = function(s){ this._s = s || {}; };",
            "__mtv_ALS__.prototype.disable = function(){ this._s = {}; };",
            "var require = function(name) {",
            "  name = String(name || '');",
            "  if (name === 'dayjs') return (typeof dayjs !== 'undefined') ? dayjs : __mtv_stub__;",
            "  if (name === 'crypto-js' || name === 'CryptoJS') return (typeof CryptoJS !== 'undefined') ? CryptoJS : __mtv_stub__;",
            "  if (name === 'util' || name === 'node:util') return { debuglog: function(){ return function(){}; }, inspect: function(x){ try { return JSON.stringify(x); } catch(e){ return String(x); } }, promisify: function(f){ return f; }, format: function(){ return [].slice.call(arguments).join(' '); }, inherits: function(){}, TextEncoder: TextEncoder, TextDecoder: TextDecoder, types: {} };",
            "  if (name === 'events' || name === 'node:events') return { EventEmitter: __mtv_EE__, default: __mtv_EE__ };",
            "  if (name === 'buffer' || name === 'node:buffer') return { Buffer: Buffer, default: Buffer };",
            "  if (name === 'process' || name === 'node:process') return process;",
            "  if (name === 'crypto' || name === 'node:crypto') return { createHash: function(){ return { update: function(){ return this; }, digest: function(){ return ''; } }; }, randomBytes: function(n){ return new Array(n||16).fill(0); }, randomUUID: function(){ return '00000000-0000-0000-0000-000000000000'; } };",
            "  if (name === 'path' || name === 'node:path') return { join: function(){ return [].slice.call(arguments).join('/'); }, resolve: function(){ return [].slice.call(arguments).join('/'); }, basename: function(p){ return String(p).split('/').pop(); }, dirname: function(p){ return String(p).split('/').slice(0,-1).join('/'); }, extname: function(){ return ''; }, sep: '/' };",
            "  if (name === 'url' || name === 'node:url') return { URL: (typeof URL !== 'undefined') ? URL : __mtv_stub__, URLSearchParams: (typeof URLSearchParams !== 'undefined') ? URLSearchParams : __mtv_stub__, fileURLToPath: function(p){ return String(p); } };",
            "  if (name === 'stream' || name === 'node:stream') return { Readable: __mtv_EE__, Writable: __mtv_EE__, Duplex: __mtv_EE__, Transform: __mtv_EE__, PassThrough: __mtv_EE__, pipeline: function(){}, finished: function(){} };",
            "  if (name === 'axios' || name === 'node-fetch' || name === 'undici' || name === 'cross-fetch') return { get: function(u){ return Promise.resolve({status:200,data:nativeReq(String(u),'GET',null,null)}); }, post: function(u,b){ return Promise.resolve({status:200,data:nativeReq(String(u),'POST',null,String(b))}); }, request: function(){ return Promise.resolve({status:200,data:{}}); }, create: function(){ return this; }, default: fetch };",
            "  if (name === 'fs' || name === 'node:fs') return { readFileSync: function(){ return ''; }, existsSync: function(){ return false; }, promises: {} };",
            "  if (name === 'os' || name === 'node:os') return { platform: function(){ return 'ios'; }, tmpdir: function(){ return '/tmp'; }, EOL: String.fromCharCode(10), cpus: function(){ return []; } };",
            "  if (name === 'async_hooks' || name === 'node:async_hooks') return { AsyncLocalStorage: __mtv_ALS__, AsyncResource: __mtv_EE__, createHook: function(){ return { enable: function(){}, disable: function(){} }; }, executionAsyncId: function(){ return 0; }, triggerAsyncId: function(){ return 0; } };",
            "  if (name === 'perf_hooks' || name === 'node:perf_hooks') return { performance: { now: function(){ return Date.now(); } }, PerformanceObserver: function(){} };",
            "  return __mtv_stub__;",
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
            "var __mtv_bytes__ = function(n, src) {",
            "  var a = new Uint8Array(Math.max(0, Number(n) || 0));",
            "  if (typeof src === 'string') { for (var si = 0; si < a.length && si < src.length; si++) a[si] = src.charCodeAt(si) & 255; }",
            "  a.write = function(s, off, len) { try { var t = String(s), k = Number(off) || 0, m = Math.min(len || t.length, a.length - k); for (var wi = 0; wi < m; wi++) a[k+wi] = t.charCodeAt(wi) & 255; return m; } catch(e) { return 0; } };",
            "  a.toString = function(enc) { try { if (enc === 'base64') return nativeBase64(String.fromCharCode.apply(null, Array.prototype.slice.call(a, 0, 256)), false); if (enc === 'hex') { var hh=''; for (var hi=0; hi<a.length && hi<512; hi++) hh += ('0'+a[hi].toString(16)).slice(-2); return hh; } return String.fromCharCode.apply(null, Array.prototype.slice.call(a, 0, 4096)); } catch(e) { return ''; } };",
            "  a.equals = function(b) { return String(a) === String(b); };",
            "  a.copy = function(t) { try { t.set(a.subarray(0, Math.min(t.length, a.length))); } catch(e) {} return a.length; };",
            "  a.readUInt8 = function(o) { return a[Number(o)||0] || 0; };",
            "  a.writeUInt8 = function(v, o) { var k=Number(o)||0; a[k]=Number(v)&255; return k+1; };",
            "  a.readUInt16LE = function(o) { var k=Number(o)||0; return (a[k]||0) | ((a[k+1]||0)<<8); };",
            "  a.writeUInt16LE = function(v, o) { var k=Number(o)||0; a[k]=v&255; a[k+1]=(v>>8)&255; return k+2; };",
            "  a.readUInt32LE = function(o) { var k=Number(o)||0; return ((a[k]||0)|((a[k+1]||0)<<8)|((a[k+2]||0)<<16)|((a[k+3]||0)<<24))>>>0; };",
            "  a.writeUInt32LE = function(v, o) { var k=Number(o)||0; for(var qi=0; qi<4; qi++) a[k+qi]=(v>>>(qi*8))&255; return k+4; };",
            "  a.toJSON = function(){ return { type: 'Buffer', data: Array.prototype.slice.call(a, 0, 512) }; };",
            "  return a;",
            "};",
            "var __mtv_buf_base__ = function(n, src){ return __mtv_bytes__(n, src); };",
            "__mtv_buf_base__.from = function(s, enc){ try { if (enc === 'base64') { var d = nativeBase64(String(s), true); return __mtv_bytes__(d.length, d); } if (s && s.length !== undefined && typeof s !== 'string') return __mtv_bytes__(s.length); return __mtv_bytes__(String(s).length, String(s)); } catch(e) { return __mtv_bytes__(0); } };",
            "__mtv_buf_base__.alloc = function(n){ return __mtv_bytes__(n); };",
            "__mtv_buf_base__.allocUnsafe = function(n){ return __mtv_bytes__(n); };",
            "__mtv_buf_base__.allocUnsafeSlow = function(n){ return __mtv_bytes__(n); };",
            "__mtv_buf_base__.concat = function(list){ try { var parts=(list||[]).map(function(x){ return (x && x.length !== undefined) ? Array.prototype.slice.call(x, 0, x.length) : []; }); var flat=[].concat.apply([], parts); var o=__mtv_bytes__(flat.length); for(var ci=0; ci<flat.length; ci++) o[ci]=flat[ci]&255; return o; } catch(e) { return __mtv_bytes__(0); } };",
            "__mtv_buf_base__.isBuffer = function(x){ return !!(x && x instanceof Uint8Array); };",
            "__mtv_buf_base__.byteLength = function(s){ try { return String(s).length; } catch(e) { return 0; } };",
            "__mtv_buf_base__.compare = function(){ return 0; };",
            "__mtv_buf_base__.poolSize = 8192;",
            "var Buffer = new Proxy(__mtv_buf_base__, {",
            "  get: function(t, k) {",
            "    if (k in t) return t[k];",
            "    if (k === Symbol.toPrimitive) return function(){ return ''; };",
            "    if (k === 'then' || k === 'toJSON') return undefined;",
            "    return function(){ return __mtv_bytes__(0); };",
            "  },",
            "  apply: function(t, thiz, a){ return __mtv_bytes__(Number(a[0])||0, typeof a[0]==='string' ? a[0] : undefined); },",
            "  construct: function(t, a){ return __mtv_bytes__(Number(a[0])||0, typeof a[0]==='string' ? a[0] : undefined); },",
            "  has: function(){ return true; }",
            "});",
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
            "var setImmediate = function(f){ try { if (typeof f === 'function') f(); } catch(e){} return 0; };",
            "var clearImmediate = function(){};",
            "var queueMicrotask = function(f){ try { if (typeof f === 'function') f(); } catch(e){} };",
            "var structuredClone = function(x){ try { return JSON.parse(JSON.stringify(x)); } catch(e) { return x; } };",
            "var performance = { now: function(){ return Date.now(); }, timeOrigin: Date.now() };",
            "if (typeof URL === 'undefined') { var URL = function(u){ this.href=String(u||''); this.search=''; this.searchParams={ get:function(){ return null; }, set:function(){} }; }; }",
            "if (typeof URLSearchParams === 'undefined') { var URLSearchParams = function(s){ this._s=String(s||''); }; URLSearchParams.prototype.get=function(){ return null; }; URLSearchParams.prototype.set=function(){}; URLSearchParams.prototype.toString=function(){ return this._s; }; }",
            "var __MTV_SKIP__ = ['nativeReq','nativeBase64','nativeMd5','nativeAesDecrypt','fetch','require','setTimeout','setInterval','clearTimeout','setImmediate','clearImmediate','queueMicrotask','print','btoa','atob','structuredClone','Buffer','URL','URLSearchParams','TextEncoder','TextDecoder','__mtv_stub__','__mtv_EE__','__mtv_ALS__','__mtv_log__','__mtv_bytes__','__mtv_buf_base__'];",
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
    // 1.5.9：.js.md5 的 hash 是源指纹；同一份 bundle 的预处理结果全局复用
    private var currentSourceHash: String?
    private var hashByKey: [String: String] = [:]
    private var preprocessed: [String: String] = [:]
    private var factoryMaps: [String: [String: String]] = [:]
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
        if let h = currentSourceHash { hashByKey[key] = h }
    }

    // MARK: - 1.5.9 源指纹 / 预处理缓存

    func setCurrentSourceHash(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        currentSourceHash = hash
    }

    func sourceHash(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashByKey[key]
    }

    /// 注意：不能在这里调用同样加锁的 sourceHash(for:)，NSLock 非递归会死锁。
    func cacheKey(forSpiderKey spiderKey: String?, codeLength: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        if let sk = spiderKey, let h = hashByKey["catpaw_" + sk] { return h }
        return "len_" + String(codeLength)
    }

    func preprocessedCode(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return preprocessed[key]
    }

    func setPreprocessedCode(_ code: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        preprocessed[key] = code
    }

    func cachedFactoryMap(for key: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return factoryMaps[key]
    }

    func setCachedFactoryMap(_ map: [String: String], for key: String) {
        lock.lock(); defer { lock.unlock() }
        factoryMaps[key] = map
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
        hashByKey.removeValue(forKey: key)
    }
}
