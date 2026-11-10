import SwiftUI

/// 可复用的内容网格 —— 手机 3 列 / 大屏 4~5 列；底部支持加载更多指示器
/// - 倒数第 4 个 item 出现时触发 onLoadMore（避免到底再触发的延迟感）
struct ContentGridView: View {

    let items: [VideoItem]
    let isLoadingMore: Bool
    let onLoadMore: () -> Void
    let onItemTap: (VideoItem) -> Void

    /// 水平内边距
    private let horizontalPadding: CGFloat = 12
    private let columnSpacing: CGFloat = 10
    private let rowSpacing: CGFloat = 14

    /// 按可用宽度决定列数：手机 3 列，iPad / 横屏更多
    private func columnCount(for width: CGFloat) -> Int {
        if width >= 820 { return 6 }
        if width >= 620 { return 5 }
        if width >= 480 { return 4 }
        return 3
    }

    var body: some View {
        // GeometryReader 只用于测量父级宽度，不占高度
        VStack(spacing: 0) {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: GridWidthKey.self, value: proxy.size.width)
            }
            .frame(height: 0)

            if let width = gridWidth {
                let columns = columnCount(for: width)
                let totalSpacing = columnSpacing * CGFloat(columns - 1)
                let cardWidth = max(64, (width - totalSpacing - horizontalPadding * 2) / CGFloat(columns))
                let compact = columns >= 4

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: columnSpacing),
                                   count: columns),
                    spacing: rowSpacing
                ) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            onItemTap(item)
                        } label: {
                            VideoCardView(item: item, index: idx + 1, compact: compact)
                        }
                        .buttonStyle(CardPressStyle())
                        .onAppear {
                            let triggerIndex = max(0, items.count - 4)
                            if idx >= triggerIndex { onLoadMore() }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }

            if isLoadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(TVBoxTheme.accent)
                        .scaleEffect(0.8)
                    Text("// LOADING MORE")
                        .font(TVBoxTheme.mono(10, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(TVBoxTheme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .transition(.opacity)
            }
        }
        .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }
    }

    @State private var gridWidth: CGFloat?
}

private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let v = nextValue()
        if v > 0 { value = v }
    }
}

/// 卡片按下动效：轻微缩放 + 提亮
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
