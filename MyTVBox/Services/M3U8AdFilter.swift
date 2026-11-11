import Foundation

// MARK: - m3u8 广告段智能过滤（1.4.7）
//
// 采集站常见的插广告手法：在正片前后/中间插入一段 #EXT-X-DISCONTINUITY 分组，
// 用独立域名或 /ad/ 路径、短时长分片（2~5 秒）、独立 EXT-X-KEY 甚至 CUE 标记。
// AVPlayer 只能在拿到 playlist 之前动手，所以由 LocalPlaylistProxy 先拉原始 m3u8，
// 交给这里清洗，再把分片改写成绝对地址回吐，分片本身仍直连 CDN。
//
// 原则：宁可漏杀也不误杀。采用「多项特征加权打分」，只有累计到阈值才整组剔除。

enum M3U8AdFilter {

    struct Stats {
        var removedSegments: Int = 0
        var removedSeconds: Double = 0
        var isMaster: Bool = false

        var summary: String? {
            guard removedSegments > 0 else { return nil }
            let sec = Int(removedSeconds.rounded())
            return "已过滤 \(removedSegments) 段广告 · 约 \(sec) 秒"
        }
    }

    struct Output {
        let text: String
        let stats: Stats
    }

    private struct Segment {
        let uri: String
        let duration: Double
        let tags: [String]
        let group: Int
        let host: String
    }

    /// 路径/域名里出现这些基本可确定是广告（刻意不放 ad.mp4 之类易误伤前后缀的词）
    private static let strongKeywords = [
        "/ad/", "/ads/", "/adm/", "/gg/", "advert", "adserver",
        "guanggao", "广告", "vast", "preroll", "midroll", "postroll", "spotx"
    ]
    private static let weakKeywords = ["banner", "promo", "sponsor", "impression"]

    private static let headerTags = [
        "#EXTM3U", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION",
        "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-PLAYLIST-TYPE",
        "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-START",
        "#EXT-X-ALLOW-CACHE", "#EXT-X-DEFINE", "#EXT-X-SESSION-KEY",
        "#EXT-X-DISCONTINUITY-SEQUENCE"
    ]

    /// - parameter proxyURLFor: 把 master playlist 里 variant 的绝对地址改写到本地代理，
    ///   这样下一级 media playlist 也会被清洗；传 nil 则仅做绝对化。
    static func clean(_ raw: String,
                      baseURL: URL,
                      proxyURLFor: ((String) -> String)? = nil) -> Output {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if lines.contains(where: {
            $0.hasPrefix("#EXT-X-STREAM-INF") || $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF")
        }) {
            return cleanMaster(lines, baseURL: baseURL, proxyURLFor: proxyURLFor)
        }
        return cleanMedia(lines, baseURL: baseURL)
    }

    // MARK: - Master playlist

    private static func cleanMaster(_ lines: [String],
                                    baseURL: URL,
                                    proxyURLFor: ((String) -> String)?) -> Output {
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                out.append(rewriteURIAttribute(in: line, baseURL: baseURL))
            } else {
                let absolute = resolve(trimmed, base: baseURL)
                out.append(proxyURLFor?(absolute) ?? absolute)
            }
        }
        var stats = Stats()
        stats.isMaster = true
        return Output(text: out.joined(separator: "\n") + "\n", stats: stats)
    }

    // MARK: - Media playlist

    private static func cleanMedia(_ lines: [String], baseURL: URL) -> Output {
        var headerLines: [String] = []
        var segments: [Segment] = []
        var pending: [String] = []
        var group = 0
        var sawURI = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#EXT-X-DISCONTINUITY"),
                   !trimmed.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                    group += 1
                }
                pending.append(line)
                continue
            }

            if !sawURI {
                sawURI = true
                var firstTags: [String] = []
                for tag in pending {
                    if headerTags.contains(where: { tag.hasPrefix($0) }) {
                        headerLines.append(tag)
                    } else {
                        firstTags.append(tag)
                    }
                }
                pending = firstTags
            }

            segments.append(Segment(
                uri: trimmed,
                duration: extinfDuration(pending),
                tags: pending,
                group: group,
                host: host(of: trimmed, base: baseURL)
            ))
            pending = []
        }

        // 最后一个分片之后的标签（#EXT-X-ENDLIST 等）
        let trailingLines = pending

        let mainHost = dominantHost(segments)
        let groupIDs = Array(Set(segments.map { $0.group })).sorted()
        var dropped = Set<Int>()

        if groupIDs.count >= 2 {
            for g in groupIDs {
                let idxs = segments.indices.filter { segments[$0].group == g }
                guard !idxs.isEmpty else { continue }
                let slice = idxs.map { segments[$0] }
                if groupScore(slice, mainHost: mainHost) >= 5 {
                    dropped.formUnion(idxs)
                }
            }
        } else {
            // 没有 discontinuity 时逐片判断，只剔除「强关键词」或「异域名 + 弱关键词」
            for (idx, seg) in segments.enumerated() {
                if segmentScore(seg, mainHost: mainHost) >= 5 {
                    dropped.insert(idx)
                }
            }
        }

        var stats = Stats()
        var out: [String] = headerLines.map { rewriteURIAttribute(in: $0, baseURL: baseURL) }
        for (idx, seg) in segments.enumerated() {
            if dropped.contains(idx) {
                stats.removedSegments += 1
                stats.removedSeconds += seg.duration
                continue
            }
            out.append(contentsOf: seg.tags.map { rewriteURIAttribute(in: $0, baseURL: baseURL) })
            out.append(resolve(seg.uri, base: baseURL))
        }
        out.append(contentsOf: trailingLines.map { rewriteURIAttribute(in: $0, baseURL: baseURL) })

        // 丢掉开头若干分片后，必须把 MEDIA-SEQUENCE 往前推，否则直播流会等待不存在的序号
        if let firstKept = segments.indices.first(where: { !dropped.contains($0) }),
           firstKept > 0 {
            let prefix = "#EXT-X-MEDIA-SEQUENCE:"
            if let i = out.firstIndex(where: { $0.hasPrefix(prefix) }),
               let old = Int(String(out[i].dropFirst(prefix.count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)) {
                out[i] = "\(prefix)\(old + firstKept)"
            }
        }

        return Output(text: out.joined(separator: "\n") + "\n", stats: stats)
    }

    // MARK: - 打分

    /// 一组分片越像「短、独立域名、广告关键词、独立 KEY/CUE」越可疑
    private static func groupScore(_ segs: [Segment], mainHost: String) -> Int {
        let duration = segs.reduce(0.0) { $0 + $1.duration }
        let joinedURI = segs.map { $0.uri.lowercased() }.joined(separator: " ")
        let joinedTags = segs.flatMap { $0.tags }.joined(separator: " ").lowercased()
        let hosts = Set(segs.map { $0.host })

        var score = 0
        if hosts.count == 1, let h = hosts.first, !h.isEmpty, h != mainHost {
            score += 4                                   // 整组换了域名
        }
        if strongKeywords.contains(where: { joinedURI.contains($0) }) {
            score += 4                                   // 路径/域名含广告词
        }
        if joinedTags.contains("ad-id") || joinedTags.contains("vast")
            || joinedTags.contains("scte35") || joinedTags.contains("cue-out") {
            score += 3                                   // 广告插播标记
        }
        if duration <= 45 { score += 2 }
        if duration <= 15 { score += 2 }
        if segs.count >= 2, duration / Double(segs.count) <= 3.0 {
            score += 2                                   // 多个 2~3 秒碎片
        }
        return score
    }

    private static func segmentScore(_ seg: Segment, mainHost: String) -> Int {
        let u = seg.uri.lowercased()
        var score = 0
        if strongKeywords.contains(where: { u.contains($0) }) { score += 5 }
        if !seg.host.isEmpty, seg.host != mainHost,
           weakKeywords.contains(where: { u.contains($0) }) {
            score += 2
        }
        return score
    }

    // MARK: - 工具

    private static func dominantHost(_ segs: [Segment]) -> String {
        var counts: [String: Int] = [:]
        for seg in segs where !seg.host.isEmpty {
            counts[seg.host, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }

    private static func extinfDuration(_ tags: [String]) -> Double {
        for tag in tags.reversed() where tag.hasPrefix("#EXTINF:") {
            let raw = tag.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
            return Double(String(raw).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private static func host(of uri: String, base: URL) -> String {
        (URL(string: uri, relativeTo: base) ?? URL(string: uri))?.host?.lowercased() ?? ""
    }

    private static func resolve(_ uri: String, base: URL) -> String {
        let lower = uri.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return uri }
        return URL(string: uri, relativeTo: base)?.absoluteString ?? uri
    }

    /// 把 #EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA 里的 URI="..." 改成绝对地址
    private static func rewriteURIAttribute(in line: String, baseURL: URL) -> String {
        guard let open = line.range(of: "URI=\"") else { return line }
        let start = open.upperBound
        guard let close = line[start...].range(of: "\"") else { return line }
        let original = String(line[start..<close.lowerBound])
        var out = line
        out.replaceSubrange(start..<close.lowerBound, with: resolve(original, base: baseURL))
        return out
    }
}
