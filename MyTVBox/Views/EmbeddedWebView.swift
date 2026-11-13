//
//  EmbeddedWebView.swift
//  MyTVBox
//
//  1.7.1：App 内嵌 WebView。
//
//  起因：猫爪源的「配置|中心」站点详情里只有一行
//  `手机扫码打开：http://10.64.81.45:18923/website`
//  —— 那是源以为自己在电脑上跑，把宿主机的局域网 IP 拼了进去。
//  手机上既没法扫码（屏幕就在看这个），复制到浏览器也未必能开。
//
//  处理：识别出这个地址后，把「局域网 IP:端口」改写成 `127.0.0.1:端上Node端口`，
//  用 App 内的 WKWebView 直接打开，配置页原样可用。
//

import SwiftUI
import WebKit

// MARK: - WKWebView 包装

struct EmbeddedWebView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 配置页有表单，允许自动填充/保存
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 地址不变时不重复加载，避免用户正在填表单被重置
        if uiView.url == nil, uiView.isLoading == false {
            uiView.load(URLRequest(url: url))
        }
    }
}

// MARK: - 配置中心弹窗

struct ConfigCenterSheet: View {

    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PlayerTheme.ink.ignoresSafeArea()
                EmbeddedWebView(url: url)
                    .id(reloadToken)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("配置中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PlayerTheme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tint(PlayerTheme.amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(PlayerTheme.sans(14, weight: .heavy))
                        .tint(PlayerTheme.amber)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 地址识别与改写

enum ConfigCenterURL {

    /// 从一段文本里找出配置中心地址，并把局域网 IP 换成端上 Node 的 127.0.0.1。
    ///
    /// 匹配形如 `http://10.64.81.45:18923/website` / `https://1.2.3.4:8080/website/index.html`。
    /// 只认 IPv4 字面量，避免误伤普通网页链接。
    ///
    /// 1.8.19 兜底：源的配置页路径不一定叫 `/website`（有的写成 `/config`、`/admin`，
    /// 或者只有 `:端口/`）。当站名 / 站 key 表明这是配置类站点时，放宽到任意
    /// `IPv4:端口[/路径]`。之前只认 `/website`，换个源就识别不出来，
    /// 页面直接退化成「没拿到可播线路」的报错浮层，把入口整个盖住了。
    static func extract(from text: String, siteName: String? = nil, siteKey: String? = nil) -> URL? {
        guard !text.isEmpty else { return nil }

        let strict = #"https?://[0-9]{1,3}(?:\.[0-9]{1,3}){3}:[0-9]{1,5}/website[^\s"'”’）)]*"#
        if let url = match(text, pattern: strict) { return url }

        let hint = ((siteName ?? "") + " " + (siteKey ?? "")).lowercased()
        let looksLikeConfig = hint.contains("配置") || hint.contains("扫码")
            || hint.contains("config") || hint.contains("setting")
            || text.contains("配置中心") || text.contains("扫码")
        guard looksLikeConfig else { return nil }

        let loose = #"https?://[0-9]{1,3}(?:\.[0-9]{1,3}){3}:[0-9]{1,5}(?:/[^\s"'”’）)，。；、]*)?"#
        return match(text, pattern: loose)
    }

    private static func match(_ text: String, pattern: String) -> URL? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        var raw = ns.substring(with: m.range)
        // 只保留到第一个空白/中文标点为止
        if let cut = raw.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "，" || $0 == "。" }) {
            raw = String(raw[raw.startIndex..<cut])
        }
        // 端上 Node 只监听 127.0.0.1，源拼出来的局域网 IP 必须整段换掉。
        // 用 URLComponents 而不是字符串替换：源里可能写成 `:18923`（没有结尾斜杠）、
        // 也可能带查询参数，字符串替换会漏。
        guard var comps = URLComponents(string: raw), comps.host != nil else { return nil }
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = NodeRuntime.shared.port
        return comps.url
    }
}
