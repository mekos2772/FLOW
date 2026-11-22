import SwiftUI

/// 歌词区。
///
/// 这个视图是 FLOW 的视觉签名：
/// - 左侧一条**竖直度量线**贯穿整个歌词区，当前行的位置由线上的实心标记表示；
/// - 歌词左对齐（不是居中），形成编辑式版面，而不是"音乐软件歌词页"；
/// - 行切换只改字重、亮度与位置，不改字号——长短句切换时基线不抖；
/// - 当前行保持在自己的槽位里，用固定最小高度吸收换行带来的高度差。
struct LyricFieldView: View {
    @Bindable var model: MorphPresentationModel

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// 当前行字号。随歌词区宽度轻微变化，但收敛在一个区间内。
    /// 当前行 / 上下文行的字号比固定在 2.2 左右：
    /// 黑白界面没有色相帮忙分区，只能靠"大小对比 + 明度对比"把当前行从上下文里拔出来。
    private var currentSize: CGFloat {
        guard let size = app?.appearance.lyricFontSize else { return 34 }
        return max(26, size + 17)
    }

    private var neighborSize: CGFloat {
        guard let size = app?.appearance.lyricFontSize else { return 15 }
        return max(12, size - 1)
    }

    /// 上下文行的槽位高度：默认行距 8 时是原来的 44pt，跟着「行距」设置增减。
    private var neighborSlotHeight: CGFloat {
        max(neighborSize * 1.6, 44 + CGFloat((app?.appearance.lyricLineSpacing ?? 8) - 8))
    }

    private var showTranslation: Bool {
        app?.appearance.showLyricTranslation ?? model.showLyricTranslation
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            ruler
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 与展开播放器的滚动歌词共用同一份菜单（见 `LyricVariantMenu`）。
        .contentShape(Rectangle())
        .lyricVariantMenu(model: model)
    }

    // MARK: - 度量线

    private var ruler: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let markerHeight = min(56, height * 0.22)
            let center = height * 0.46
            ZStack(alignment: .top) {
                Capsule()
                    .fill(FlowColor.primaryRule)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(FlowColor.emphasis(model.ambient?.swiftUIColor))
                    .frame(width: 2, height: markerHeight)
                    .offset(y: center - markerHeight / 2)
                    .opacity(model.lyricState == .loaded ? 1 : 0.25)
            }
            .frame(maxWidth: .infinity)
            .animation(Motion.respectingReduceMotion(Motion.move(Motion.lyric), reduceMotion: reduceMotion),
                       value: model.lyric.index)
        }
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.isMasked {
            placeholder(title: "隐私模式已开启", detail: "歌名与歌词已隐藏", showsSpinner: false)
        } else {
            switch model.lyricState {
            case .loaded:
                synced
            case .unsynced:
                unsynced
            case .loading:
                placeholder(title: "正在载入歌词", detail: nil, showsSpinner: true)
            case .failed:
                placeholder(title: "歌词加载失败", detail: "可尝试手动搜词，或直接导入本地 .lrc / .ttml", showsSpinner: false, showActions: model.track != nil)
            case .empty, .idle:
                if model.track == nil {
                    idle
                } else {
                    placeholder(title: "没有找到歌词", detail: "可手动搜词换一版，或直接导入本地 .lrc / .ttml", showsSpinner: false, showActions: true)
                }
            }
        }
    }

    /// 已同步歌词：上/当前/下三行 + 一条更远处的一行，形成纵深。
    private var synced: some View {
        VStack(alignment: .leading, spacing: 0) {
            lineSlot(model.previousLine, line: model.lyric.previous, opacity: 0.26, size: neighborSize, height: neighborSlotHeight)
            currentLine
            lineSlot(model.nextLine, line: model.lyric.next, opacity: 0.42, size: neighborSize, height: neighborSlotHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 当前行。
    ///
    /// 槽位高度固定（96pt），换行时不改变布局；新行从下方 26pt 处淡入并上移到位，
    /// 旧行同时向上淡出——这就是"内容在折叠/推进"的观感来源，而不是整块列表滚动。
    /// 减少动态效果时只有淡入淡出，没有位移。
    private var currentLine: some View {
        let translation = showTranslation ? model.currentLyricTranslation : nil
        return ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                currentPrimaryText
                    .flowType(FlowType.lyricCurrent(size: currentSize))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let translation {
                    Text(translation)
                        .flowType(FlowType.lyricNeighbor(size: max(13, neighborSize * 1.05)))
                        .foregroundStyle(Color.primary.opacity(0.68))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .id(lineIdentity)
            .transition(lineTransition)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(.vertical, Spacing.xxs)
        .clipped()
        .animation(reduceMotion ? nil : Motion.move(Motion.lyric), value: lineIdentity)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var currentPrimaryText: some View {
        if !model.isMasked,
           let line = model.lyric.current,
           line.hasWordTiming,
           !line.text.isEmpty {
            Text(LyricWordHighlight.attributedString(for: line, at: model.lyric.time))
        } else {
            Text(model.currentLyricText)
        }
    }

    /// 当前行的身份：行号变化即触发一次位移过渡。没有行号时退化成文本本身。
    private var lineIdentity: String {
        if let index = model.lyric.index { return "line-\(index)" }
        return model.currentLyricText
    }

    private var lineTransition: AnyTransition {
        if reduceMotion { return .opacity }
        // 位移要大过一行字高的一半，否则新旧两行在淡入淡出期间会叠在一起，
        // 观感像"重影"而不是"推进"（浅色大字下尤其明显）。
        return .asymmetric(
            insertion: .offset(y: 34).combined(with: .opacity),
            removal: .offset(y: -30).combined(with: .opacity)
        )
    }

    /// 前后行的对比度按"外观 + 系统提高对比度"决定。
    /// 之前写死 `opacity`：浅色模式下 0.34 的黑几乎读不出来（实机截图确认）。
    private func neighborTone(_ base: Double) -> Color {
        FlowColor.lyricNeighbor(scheme: colorScheme, contrast: contrast)
    }

    private func lineSlot(_ text: String?, line: LyricLine?, opacity: Double, size: CGFloat, height: CGFloat) -> some View {
        Text(text ?? " ")
            .flowType(FlowType.lyricNeighbor(size: size))
            .foregroundStyle(neighborTone(opacity))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { seek(to: line) }
            .accessibilityAction(named: Text("从这一句开始播放")) { seek(to: line) }
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.lyric), reduceMotion: reduceMotion),
                       value: text)
    }

    /// 纯文本歌词：不做自动滚动，交给用户滚。
    private var unsynced: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(model.lyric.unsyncedLines.enumerated()), id: \.offset) { _, text in
                    Text(text.isEmpty ? "♪" : text)
                        .flowType(FlowType.lyricNeighbor(size: neighborSize))
                        .foregroundStyle(FlowColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, Spacing.s)
        }
        .scrollIndicators(.never)
    }

    /// 空闲态：展示音源主页（无配置音源时由主页内部呈现导入引导）。
    @ViewBuilder
    private var idle: some View {
        if app != nil {
            OnlineHomeView(model: model)
                .padding(.top, Spacing.xs)
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("未在播放")
                    .flowType(FlowType.lyricCurrent(size: currentSize * 0.8))
                    .foregroundStyle(FlowColor.secondaryText)
                Text("拖入音频即可直接播放，或在首页添加本地目录与在线音源。")
                    .flowType(FlowType.lyricNeighbor(size: neighborSize))
                    .foregroundStyle(FlowColor.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, Spacing.m)
        }
    }

    private func placeholder(title: LocalizedStringKey, detail: LocalizedStringKey?, showsSpinner: Bool, showActions: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            }
            Text(title)
                .flowType(FlowType.lyricNeighbor(size: neighborSize * 1.1))
                .foregroundStyle(FlowColor.secondaryText)
            if let detail {
                Text(detail)
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
            }
            if showActions, model.track != nil {
                LyricQuickActionsBar(model: model)
                    .padding(.top, Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, Spacing.l)
    }

    // MARK: - 交互

    private func seek(to line: LyricLine?) {
        guard let line, let engine = app?.lyricEngine, let document = engine.document else { return }
        guard let playback = app?.playback else { return }
        let offset = engine.userOffset + document.embeddedOffset
        Task { await playback.seek(to: max(0, line.start - offset)) }
    }
}

private extension FlowColor {
    /// 度量线的底色。
    static var primaryRule: Color { Color.primary.opacity(0.10) }
}
