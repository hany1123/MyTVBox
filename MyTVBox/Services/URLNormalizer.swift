import Foundation

/// URL 规范化：把含中文（或其他非 ASCII）域名的地址转换成可用的 URL
///
/// iOS 16 上 `URL(string:)` 严格遵循 RFC 3986，遇到 `http://www.饭太硬.art/tv`
/// 这类中文域名会直接返回 nil，导致订阅地址被判定为「URL 格式不合法」。
/// 这里按 IDNA 规则把主机名逐段转成 punycode（RFC 3492），路径与查询串做百分号编码，
/// 其余部分保持原样，从而产出 `http://www.xn--sss604efuw.art/tv` 这种合法地址。
enum URLNormalizer {

    /// 规范化并返回 URL；无法修复时返回 nil
    static func url(_ raw: String) -> URL? {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return nil }
        if let u = URL(string: normalized) { return u }
        // 兜底：整体百分号编码后重试（覆盖路径里残留的非法字符）
        if let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let u = URL(string: escaped) {
            return u
        }
        return nil
    }

    /// 把任意地址规范化为 ASCII 安全的字符串；无法解析时原样返回
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // 全 ASCII 且本身合法 → 不折腾
        let isAllASCII = trimmed.unicodeScalars.allSatisfy { $0.value < 128 }
        if isAllASCII, URL(string: trimmed) != nil { return trimmed }

        // 缺协议头时补 http://
        guard let schemeRange = trimmed.range(of: "://") else {
            return normalize("http://" + trimmed)
        }

        let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()
        let rest = String(trimmed[schemeRange.upperBound...])

        // 切出 authority 与 path/query/fragment
        var authority = rest
        var tail = ""
        if let idx = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(rest[rest.startIndex..<idx])
            tail = String(rest[idx...])
        }

        // userinfo@host:port
        var userinfo = ""
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[authority.startIndex...at])
            authority = String(authority[authority.index(after: at)...])
        }

        var host = authority
        var port = ""
        if let colon = authority.lastIndex(of: ":") {
            let candidate = String(authority[authority.index(after: colon)...])
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isNumber }) {
                host = String(authority[authority.startIndex..<colon])
                port = ":" + candidate
            }
        }

        let asciiHost: String
        if host.hasPrefix("[") || host.isEmpty || host.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            asciiHost = host
        } else {
            asciiHost = host
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { punycode(String($0)) }
                .joined(separator: ".")
        }

        return "\(scheme)://\(userinfo)\(asciiHost)\(port)\(percentEncode(tail))"
    }

    // MARK: - 路径编码

    private static func percentEncode(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        if s.unicodeScalars.allSatisfy({ $0.value < 128 }) { return s }
        // 先保护已有转义，编码后再还原，避免 %E4 被二次编码成 %25E4
        let guarded = s.replacingOccurrences(of: "%", with: "@@PCT@@")
        let encoded = guarded.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? guarded
        return encoded
            .replacingOccurrences(of: "@@PCT@@", with: "%")
            .replacingOccurrences(of: "%2540%2540PCT%2540%2540", with: "%")
    }

    // MARK: - Punycode（RFC 3492 编码）

    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    private static func digitToChar(_ d: Int) -> Character {
        if d < 26 { return Character(Unicode.Scalar(UInt8(d + 97))) }
        return Character(Unicode.Scalar(UInt8(d - 26 + 48)))
    }

    private static func adapt(_ delta: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
        var d = firstTime ? delta / damp : delta / 2
        d += d / numPoints
        var k = 0
        while d > ((base - tMin) * tMax) / 2 {
            d /= (base - tMin)
            k += base
        }
        return k + ((base - tMin + 1) * d) / (d + skew)
    }

    /// 单个域名段编码；已是 ASCII 则原样返回
    private static func punycode(_ label: String) -> String {
        let scalars = Array(label.lowercased().unicodeScalars)
        guard scalars.contains(where: { $0.value >= 128 }) else { return label.lowercased() }

        var output = ""
        var basicCount = 0
        for s in scalars where s.value < 128 {
            output.append(Character(s))
            basicCount += 1
        }
        var handled = basicCount
        if basicCount > 0 { output.append("-") }

        var n = initialN
        var delta = 0
        var bias = initialBias

        while handled < scalars.count {
            // 找到下一个待处理的最小码点
            var m = Int.max
            for s in scalars where Int(s.value) >= n {
                m = min(m, Int(s.value))
            }
            if m == Int.max { break }

            delta += (m - n) * (handled + 1)
            n = m

            for s in scalars {
                let c = Int(s.value)
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t: Int
                        if k <= bias { t = tMin }
                        else if k >= bias + tMax { t = tMax }
                        else { t = k - bias }
                        if q < t { break }
                        output.append(digitToChar(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digitToChar(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }

        return "xn--" + output
    }
}
