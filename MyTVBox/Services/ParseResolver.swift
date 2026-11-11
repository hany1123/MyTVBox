import Foundation
import UIKit
import WebKit

/// 网页型线路解析层
///
/// 有些站点（官源 / 分享页）返回的不是 m3u8 直链，而是需要解析服务兑换的网页地址。
/// 这里把「非直链」交给解析服务，用隐藏的 WKWebView 执行页面脚本，
/// 页面自己解密出真实地址后，我们拦截其中出现的 `.m3u8` 交给 AVPlayer。
///
/// 为什么不直接 GET 解析接口：实测这些服务返回的是自定义加密串或动态生成的 JS，
/// 静态抓 HTML 拿不到播放地址；让页面自己跑最通用、也不需要逐家逆向算法。
@MainActor
final class ParseResolver: NSObject {

    static let shared = ParseResolver()

    /// 内置兜底解析规则（2026-11-11 实测 200 且会加载播放器页）。
    /// 订阅里若配了 `parses`，优先用订阅的；内置规则排在后面补位。
    static let builtinParseURLs: [String] = [
        "https://api.wwgz.cn:520/webcloud/relay.php?url="
    ]

    /// 1.5.1 内置 JSON 解析规则：来自 iBox 2.5.1 真机解密出的 `parsing` 表，
    /// 4 条已实测能返回 `{"code":200,"url":"...m3u8"}`。订阅没配规则时作为兜底。
    static let builtinJSONParseRules: [ParseRule] = [
        ParseRule(name: "非凡去广告", type: 1,
                  url: "https://api.hxmp4.com/api/parsing.Fjx/index?url=",
                  playKeys: ["ffm3u8"]),
        ParseRule(name: "优质去广告解析", type: 1,
                  url: "https://api.hxmp4.com/api/parsing.Yzjx/index?url=",
                  playKeys: ["1080zyk"]),
        ParseRule(name: "人人视频解析", type: 1,
                  url: "https://parsing.hxmp4.com/api/parsing.Rrmj/index?url=",
                  playKeys: ["selfrrmj"]),
        ParseRule(name: "毒舌电影", type: 1,
                  url: "https://parsing.hxmp4.com/api/parsing.Dushe/index?url=",
                  playKeys: ["selfdushe"]),
    ]

    /// 云端去广告接口：输入 m3u8 → 输出过滤掉插播广告后的 m3u8
    private static let cloudAdCleanBase = "https://api.hxmp4.com/api/parsing.Fjx/index?url="

    private let handlerName = "mytvboxm3u8"
    private var webView: WKWebView?
    private var bridge: ScriptBridge?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var seen = Set<String>()
    private var finished = true

    // 同一时刻只允许一个页面在解析；后来的请求排队，避免后一次 resolve
    // 把前一次的 CheckedContinuation 覆盖掉导致永久挂起。
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 注入到页面最前面的 JS：抓 fetch / XHR / media.src / DOM 变更 / 资源请求，
    /// 并定期全文扫 `.m3u8`，命中就回传 native。
    private static let hookScript = #"""
    (function () {
      if (window.__mytvbox_hooked) return;
      window.__mytvbox_hooked = true;

      var re = /https?:\/\/[^"'<>\s\\()]+\.m3u8[^"'<>\s\\()']*/g;

      function hit(u) {
        try {
          if (!u) return;
          u = String(u);
          if (u.indexOf('.m3u8') === -1) return;
          if (u.indexOf('http') !== 0) return;
          window.webkit.messageHandlers.mytvboxm3u8.postMessage(u);
        } catch (e) {}
      }
      function scan(s) {
        try {
          if (!s || typeof s !== 'string') return;
          var m; re.lastIndex = 0;
          while ((m = re.exec(s))) hit(m[0]);
        } catch (e) {}
      }

      // 1) fetch 请求地址 + 响应正文
      var of = window.fetch;
      if (of) window.fetch = function (a, b) {
        try { hit(typeof a === 'string' ? a : (a && a.url)); } catch (e) {}
        var p = of.apply(this, arguments);
        try {
          if (p && p.then) p.then(function (r) {
            try {
              if (r && r.clone) r.clone().text().then(function (t) { scan(t); }).catch(function () {});
            } catch (e) {}
            return r;
          }).catch(function () {});
        } catch (e) {}
        return p;
      };

      // 2) XHR 请求地址 + 响应正文
      try {
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) {
          try { hit(u); } catch (e) {}
          try {
            this.addEventListener('load', function () {
              try { scan(this.responseText); } catch (e) {}
            });
          } catch (e) {}
          return oo.apply(this, arguments);
        };
      } catch (e) {}

      // 3) <video>/<source> 赋值
      try {
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          get: d.get, configurable: true,
          set: function (v) { hit(v); return d.set.call(this, v); }
        });
      } catch (e) {}

      // 4) DOM 变化
      try {
        new MutationObserver(function (ms) {
          ms.forEach(function (m) {
            (m.addedNodes || []).forEach(function (n) {
              if (!n) return;
              if (n.tagName === 'VIDEO' || n.tagName === 'SOURCE') hit(n.src || n.getAttribute('src'));
              if (n.querySelectorAll) n.querySelectorAll('video,source').forEach(function (v) {
                hit(v.src || v.getAttribute('src'));
              });
              if (n.tagName === 'SCRIPT') scan(n.textContent);
            });
            if (m.target && m.target.tagName === 'VIDEO') hit(m.target.src);
          });
        }).observe(document, { childList: true, subtree: true, attributes: true,
                               attributeFilter: ['src'], characterData: false });
      } catch (e) {}

      // 5) 定时兜底：整页 outerHTML + 已发起的网络请求（hls.js 的 .m3u8 会出现在这里）
      setInterval(function () {
        try {
          if (document.documentElement) scan(document.documentElement.outerHTML);
        } catch (e) {}
        try {
          var es = performance.getEntriesByType('resource') || [];
          for (var i = 0; i < es.length; i++) hit(es[i].name);
        } catch (e) {}
      }, 700);
    })();
    """#

    // MARK: - 公开入口

    /// 依次尝试解析规则，返回第一个拿到的播放直链。
    ///
    /// 1.5.1 增强：
    /// - `type == 1` 走 **JSON 直解**（直接 GET 接口 → 解析 JSON 里的 url），
    ///   比隐藏 WebView 更快更可靠，适配真机抓到的 `{"code":200,"url":"…m3u8"}`；
    /// - `flag`（线路名 / `vod_play_from`）优先命中声明了对应 `play_key` 的规则；
    /// - 其余规则仍走 WKWebView 页面脚本拦截。
    func resolve(original: String,
                 rules: [ParseRule],
                 flag: String? = nil,
                 timeout: TimeInterval = 12) async -> URL? {
        await waitTurn()
        defer { releaseTurn() }

        var ordered: [ParseRule] = []
        var seenRules = Set<String>()
        for rule in rules + Self.builtinJSONParseRules {
            guard let u = rule.url, !u.isEmpty, seenRules.insert(u).inserted else { continue }
            ordered.append(rule)
        }
        if let f = flag, !f.isEmpty {
            let hit = ordered.filter { $0.matches(flag: f) }
            let rest = ordered.filter { !$0.matches(flag: f) }
            ordered = hit + rest
        }

        for rule in ordered {
            guard let base = rule.url,
                  let target = makeURL(base: base, original: original) else { continue }
            if rule.type == 1 {
                if let found = await resolveJSON(target, timeout: min(timeout, 8)) {
                    return found
                }
            } else if let found = await tryOne(target, timeout: timeout) {
                return found
            }
        }

        // 内置网页型兜底
        for u in Self.builtinParseURLs {
            guard let target = makeURL(base: u, original: original) else { continue }
            if let found = await tryOne(target, timeout: timeout) { return found }
        }
        return nil
    }

    /// 云端去广告：把 m3u8 送进服务端换成过滤后的播放列表。
    /// 不走 waitTurn 闸门（避免与 resolve 互相等待）；失败返回 nil，调用方静默退回直连。
    func cleanM3U8(original: String, timeout: TimeInterval = 8) async -> URL? {
        guard original.lowercased().contains(".m3u8"), isPlayable(original) else { return nil }
        guard let target = makeURL(base: Self.cloudAdCleanBase, original: original) else {
            return nil
        }
        return await resolveJSON(target, timeout: timeout)
    }

    /// type=1 规则：直接请求接口并从响应里取播放地址
    private func resolveJSON(_ urlString: String, timeout: TimeInterval) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("okhttp/4.9.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return extractMediaURL(from: data)
        } catch {
            return nil
        }
    }

    private func extractMediaURL(from data: Data) -> URL? {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let found = findMediaURL(in: obj, depth: 0) {
            return found
        }
        if let text = String(data: data, encoding: .utf8) {
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlayable(line), let u = URL(string: line) { return u }
            }
        }
        return nil
    }

    /// 递归找第一个可播放地址；优先常见字段，避免把 code / msg 之类误当地址
    private func findMediaURL(in any: Any?, depth: Int) -> URL? {
        guard depth < 6, let any else { return nil }
        if let s = any as? String {
            let clean = s.replacingOccurrences(of: "\\/", with: "/")
            guard isPlayable(clean) else { return nil }
            return URL(string: clean)
        }
        if let arr = any as? [Any] {
            for x in arr {
                if let u = findMediaURL(in: x, depth: depth + 1) { return u }
            }
        }
        if let d = any as? [String: Any] {
            for k in ["url", "m3u8", "mp4", "playUrl", "data"] {
                if let v = d[k], let u = findMediaURL(in: v, depth: depth + 1) { return u }
            }
            for (_, v) in d {
                if let u = findMediaURL(in: v, depth: depth + 1) { return u }
            }
        }
        return nil
    }

    private func isPlayable(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: "\\/", with: "/")
        guard t.hasPrefix("http://") || t.hasPrefix("https://") else { return false }
        let lower = t.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4") ||
               lower.contains("/hls/") || lower.contains(".flv")
    }

    /// 解析规则一般是 `https://host/?url=` 直接拼接；带 `$` 的复杂模板暂不支持。
    private func makeURL(base: String, original: String) -> String? {
        guard !base.contains("$") else { return nil }
        let encoded = original.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? original
        return base + encoded
    }

    // MARK: - 串行闸门

    private func waitTurn() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // busy 仍为 true：锁由 releaseTurn() 直接交接，无需再次置位
    }

    private func releaseTurn() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume(returning: ())
        }
    }

    // MARK: - 单次解析

    private func tryOne(_ urlString: String, timeout: TimeInterval) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        cancelPending()
        finished = false
        seen.removeAll()

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.hookScript,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        let b = ScriptBridge()
        b.onMessage = { [weak self] text in
            Task { @MainActor in
                guard let self, !self.finished,
                      self.seen.insert(text).inserted,
                      text.contains(".m3u8"),
                      let u = URL(string: text) else { return }
                self.finish(u)
            }
        }
        content.add(b, name: handlerName)
        bridge = b

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: CGRect(x: -1, y: -1, width: 1, height: 1),
                           configuration: config)
        wv.alpha = 0.01
        wv.isHidden = false
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 Mobile/15E148 Safari/604.1"
        webView = wv
        attach(wv)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("https://www.mgtv.com/", forHTTPHeaderField: "Referer")
        wv.load(request)

        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            self.continuation = c
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                guard let self, !self.finished else { return }
                self.finish(nil)
            }
        }
    }

    /// WKWebView 必须挂进窗口层级才会稳定跑 JS / 发起子资源请求。
    private func attach(_ wv: WKWebView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        window?.addSubview(wv)
    }

    private func cancelPending() {
        guard let c = continuation else {
            cleanupWebView()
            return
        }
        finished = true
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupWebView()
        c.resume(returning: nil)
    }

    private func finish(_ url: URL?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let c = continuation
        continuation = nil
        cleanupWebView()
        c?.resume(returning: url)
    }

    private func cleanupWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: handlerName)
        webView = nil
        bridge = nil
    }
}

/// WKUserContentController 会强引用 handler，用独立桥接对象避免 ParseResolver 被循环持有。
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        onMessage?(text)
    }
}
