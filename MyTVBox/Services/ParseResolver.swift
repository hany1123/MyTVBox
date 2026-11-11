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

    /// 依次尝试解析规则，返回第一个拿到的 m3u8 直链。
    /// - Parameters:
    ///   - original: 原始（非直链）播放地址
    ///   - rules: 订阅配置里的 `parses`
    ///   - timeout: 每条规则的等待上限
    func resolve(original: String,
                 rules: [ParseRule],
                 timeout: TimeInterval = 12) async -> URL? {
        await waitTurn()
        defer { releaseTurn() }

        var candidates: [String] = []
        for rule in rules {
            guard let u = rule.url, !u.isEmpty, !candidates.contains(u) else { continue }
            candidates.append(u)
        }
        for u in Self.builtinParseURLs where !candidates.contains(u) {
            candidates.append(u)
        }
        guard !candidates.isEmpty else { return nil }

        for base in candidates {
            guard let target = makeURL(base: base, original: original) else { continue }
            if let found = await tryOne(target, timeout: timeout) {
                return found
            }
        }
        return nil
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
