import SwiftUI

/// 视频卡片 —— "终端瓦片"美学
/// - 2:3 海报、左上角 L 形角标、右上角等宽备注、左下角索引编号
/// - 失败/缺图时降级为 NO SIGNAL 占位
struct VideoCardView: View {

    let item: VideoItem
    /// 可选的序号（用于在卡片左下显示 "01" "02" ...）
    let index: Int?
    /// 紧凑模式（4 列及以上时缩小字号与装饰）
    let compact: Bool

    init(item: VideoItem, index: Int? = nil, compact: Bool = false) {
        self.item = item
        self.index = index
        self.compact = compact
    }

    private var titleSize: CGFloat { compact ? 11 : 13 }
    private var metaSize: CGFloat { compact ? 8 : 10 }
    private var badgeSize: CGFloat { compact ? 7.5 : 9 }
    private var badgePadH: CGFloat { compact ? 5 : 7 }
    private var badgePadV: CGFloat { compact ? 2 : 3 }
    private var overlayPad: CGFloat { compact ? 5 : 7 }
    private var cornerSize: CGFloat { compact ? 9 : 12 }
    private var posterRadius: CGFloat { compact ? 8 : 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            poster
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                Text(item.vodName)
                    .font(TVBoxTheme.text(titleSize, weight: .semibold))
                    .foregroundStyle(TVBoxTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta = subMeta {
                    Text(meta)
                        .font(TVBoxTheme.mono(metaSize, weight: .medium))
                        .foregroundStyle(TVBoxTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - 海报

    private var poster: some View {
        GeometryReader { geo in
            posterImage
                .frame(width: geo.size.width, height: geo.size.width * 1.5)
                .clipped()
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: posterRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: posterRadius, style: .continuous)
                .stroke(TVBoxTheme.stroke, lineWidth: 1)
        )
        .overlay(scanlineOverlay)
        .overlay(cornerBracketTL, alignment: .topLeading)
        .overlay(cornerBracketBR, alignment: .bottomTrailing)
        .overlay(remarkBadge, alignment: .topTrailing)
        .overlay(indexBadge, alignment: .bottomLeading)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let s = item.vodPic, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    posterPlaceholder
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    posterPlaceholder
                @unknown default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [TVBoxTheme.surfaceRaised, TVBoxTheme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 噪点斜纹
            GeometryReader { geo in
                Path { p in
                    let step: CGFloat = 8
                    var x: CGFloat = -geo.size.height
                    while x < geo.size.width {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x + geo.size.height, y: geo.size.height))
                        x += step
                    }
                }
                .stroke(Color.white.opacity(0.025), lineWidth: 0.5)
            }
            VStack(spacing: 6) {
                Image(systemName: "tv")
                    .font(.system(size: compact ? 18 : 26, weight: .light))
                    .foregroundStyle(TVBoxTheme.textMuted)
                Text("// NO SIGNAL")
                    .font(TVBoxTheme.mono(compact ? 7 : 9, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(TVBoxTheme.textMuted)
            }
        }
    }

    // MARK: - 装饰

    private var cornerBracketTL: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: cornerSize))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: cornerSize, y: 0))
        }
        .stroke(TVBoxTheme.accent.opacity(0.85), lineWidth: 1.5)
        .frame(width: cornerSize, height: cornerSize)
        .padding(overlayPad)
        .allowsHitTesting(false)
    }

    private var cornerBracketBR: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: cornerSize))
            p.addLine(to: CGPoint(x: cornerSize, y: cornerSize))
            p.addLine(to: CGPoint(x: cornerSize, y: 0))
        }
        .stroke(TVBoxTheme.accent.opacity(0.55), lineWidth: 1.5)
        .frame(width: cornerSize, height: cornerSize)
        .padding(overlayPad)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var remarkBadge: some View {
        if let r = item.vodRemarks?.trimmingCharacters(in: .whitespaces),
           !r.isEmpty {
            Text(r)
                .font(TVBoxTheme.mono(badgeSize, weight: .heavy))
                .tracking(0.5)
                .lineLimit(1)
                .foregroundStyle(.black)
                .padding(.horizontal, badgePadH)
                .padding(.vertical, badgePadV)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(TVBoxTheme.accent)
                )
                .shadow(color: TVBoxTheme.accent.opacity(0.5), radius: 6, y: 2)
                .padding(overlayPad)
        }
    }

    @ViewBuilder
    private var indexBadge: some View {
        if let idx = index {
            HStack(spacing: 3) {
                Text("//")
                    .font(TVBoxTheme.mono(badgeSize, weight: .heavy))
                    .foregroundStyle(TVBoxTheme.accent.opacity(0.7))
                Text(String(format: "%02d", idx))
                    .font(TVBoxTheme.mono(badgeSize + 2, weight: .black))
                    .foregroundStyle(TVBoxTheme.accent)
            }
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.black.opacity(0.55))
            )
            .padding(overlayPad)
        }
    }

    private var scanlineOverlay: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.55)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    // MARK: - 元信息字符串

    private var subMeta: String? {
        var parts: [String] = []
        if let y = item.vodYear?.trimmingCharacters(in: .whitespaces), !y.isEmpty {
            parts.append(y)
        }
        if let a = item.vodArea?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
            parts.append(a)
        }
        if let t = item.typeName?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            parts.append(t)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
#if compiler(>=5.9)
@available(iOS 17, *)
struct Preview_VideoCardView: PreviewProvider {
    static var previews: some View {
        ZStack {
            TVBoxTheme.bg.ignoresSafeArea()
            HStack(spacing: 14) {
                VideoCardView(
                    item: VideoItem(
                        vodId: "1", vodName: "示例剧集名称很长很长很长",
                        vodPic: nil, vodRemarks: "更新至 12 集",
                        vodYear: "2024", vodArea: "中国"
                    ),
                    index: 1
                )
                VideoCardView(
                    item: VideoItem(
                        vodId: "2", vodName: "另一个示例",
                        vodPic: "https://invalid.example/x.jpg",
                        vodRemarks: "HD"
                    ),
                    index: 2
                )
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}
#endif

#endif
