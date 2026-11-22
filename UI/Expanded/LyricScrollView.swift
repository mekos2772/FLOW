import SwiftUI

/// Apple Music 风格的滚动歌词。
///
/// 与旧的「编辑式三行版面」的区别：
/// - **整段歌词**滚动，而不是只显示当前行与前后行；
/// - 当前行居中、放大、提亮，其余行按距离衰减并轻微失焦；
/// - 行切换带**弹簧跃动**（新行从略小弹到正常，整块列表一起上移）；
/// - 点击任意一行跳转到该句。
///
/// 布局计算在 `LyricScrollLayout`（纯逻辑、可测），这里只负责呈现与动画。
struct LyricScrollView: View {
    @Bindable var model: MorphPresentationModel
    /// 行数据。默认取当前歌词引擎的文档；显式传入可用于预览与测试。
    ///
    /// 之前这里直接读 `app?.lyricEngine`，导致这个视图无法脱离容器渲染，
    /// 也无法验证"换行后画面真的变了"。
    var providedLines: [LyricLine]?
    /// 字号跟着版面比例走：窗口越大，歌词越大（播放页按歌词区高度算好传进来）。
    var fontScale: CGFloat = 1

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// 行切换瞬间的"压一下"状态。true 时当前行缩到 `bounceStartScale`，
    /// 随后由弹簧动画回到 1.0 —— 这就是跃动。
    @State private var isBouncing = false

    /// 基准字号（上下文行）。歌词和封面并排居中后，歌词是页面的主角，字要撑得起来。
    private var baseSize: CGFloat {
        guard let size = app?.appearance.lyricFontSize else { return 20 * fontScale }
        return max(18, size + 5) * fontScale
    }
    /// 「行距」设置：默认 8 就是原来的版面；每加减 1 pt，行与行之间的空隙跟着变（随版面缩放）。
    private var rowGapAdjustment: CGFloat {
        CGFloat((app?.appearance.lyricLineSpacing ?? 8) - 8) * fontScale
    }
    /// 当前行字号 = 基准 × 2，最小 36（同样随版面缩放）。
    private var currentSize: CGFloat { max(36 * fontScale, baseSize * 2) }

    private var showTranslation: Bool {
        app?.appearance.showLyricTranslation ?? model.showLyricTranslation
    }

    private var translationSize: CGFloat {
        max(13, baseSize * 0.9)
    }

    private var lines: [LyricLine] {
        providedLines ?? app?.lyricEngine.document?.lines ?? []
    }

    /// 当前高亮行。
    ///
    /// 还没有当前行（前奏 / 未播放 / 加载失败停在 0:00）时**回落到第 0 行**：
    /// 否则所有行都会套用"远处行人"样式（30% 不透明度 + 模糊），
    /// 整块歌词看起来像一张灰掉的、没有重点的图——用户会问"这歌词怎么是这样的"。
    /// 首行高亮既符合"马上要唱这一句"的预期，也让未播放状态有明确锚点。
    private var currentIndex: Int? {
        if let index = model.lyric.index { return index }
        return lines.isEmpty ? nil : 0
    }

    var body: some View {
        Group {
            if model.isMasked {
                maskedState
            } else if providedLines == nil && model.lyricState == .unsynced {
                unsyncedLyrics
            } else if lines.isEmpty {
                emptyState
            } else {
                scrollingLyrics
            }
        }
        // 空状态写着「在歌词区点右键可以换一版」，菜单就必须真的在。
        .contentShape(Rectangle())
        .lyricVariantMenu(model: model)
    }

    // MARK: - 滚动歌词

    private var scrollingLyrics: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let textWidth = geo.size.width - Spacing.xl * 2
            let texts = wrappedTexts(width: textWidth)
            // 布局是唯一权威：行位置、缩放、明暗全部来自 `LyricScrollLayout`。
            // 视图只负责把内容按 `scrollOffset` 平移，并在行变化时用弹簧过渡。
            let layout = LyricScrollLayout.make(
                lineCount: lines.count,
                currentIndex: currentIndex,
                baseLineHeight: Double(baseSize * 2.1 + rowGapAdjustment),
                currentLineHeight: Double(currentSize * 1.75 + rowGapAdjustment),
                visibleHeight: Double(height),
                lineTexts: texts,
                availableWidth: Double(geo.size.width) - Double(Spacing.xl) * 2,
                fontSize: Double(baseSize),
                currentFontSize: Double(currentSize),
                translationTexts: showTranslation ? lines.map { $0.translationText(showingTranslation: true) } : [],
                translationFontSize: Double(translationSize))

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    // 顶部/底部各补半个可视区，当前行是首行或末行时也能居中，
                    // 而不至于把那一行推出可视区（否则首行会被裁掉一半）。
                    Color.clear.frame(height: height / 2)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        // **强制**用布局给的高度。
                        //
                        // 之前这里是让文字自然撑开，而滚动偏移由 `LyricScrollLayout`
                        // 的合成行高算出来——两套模型每行差几 pt，累计之后
                        // "看到的行"和"布局认为居中的行"不是同一行，点击就错位。
                        row(index: index, line: line, text: texts[index], layout: layout,
                            textWidth: textWidth)
                            .frame(height: layout.heights.indices.contains(index)
                                   ? layout.heights[index] : nil)
                    }
                    Color.clear.frame(height: height / 2)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .offset(y: offset(for: layout, height: Double(height)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(reduceMotion ? nil : Motion.lyricScroll, value: currentIndex)
            .onChange(of: currentIndex) { _, _ in
                guard !reduceMotion else { return }
                // 先压小再弹回：一次完整跃动。
                isBouncing = true
                withAnimation(Motion.lyricSpring) { isBouncing = false }
            }
        }
    }

    /// 内容整体的纵向偏移，使当前行正好落在可视区中心。
    ///
    /// 记 `h` 为可视区高度。上方垫了 `h/2`，所以某行中心在视图坐标里是
    /// `h/2 + centers[i]`（`centers[i]` 已相对滚动后的中心）。
    /// 要让当前行（`centers == 0`）落在视图中心 `h/2`，偏移必须再加回 `-h/2`：
    ///
    ///     offset = -h/2 - scrollOffset
    ///
    /// 之前漏了这一项：不垫片时偏移正好是 `-scrollOffset`（看起来对），
    /// 一加垫片就整体下移半屏，当前行掉到下半部分。
    private func offset(for layout: LyricScrollLayout.Layout, height: Double) -> CGFloat {
        CGFloat(-height / 2 - layout.scrollOffset)
    }

    /// 当前句附近几行按短语折行（中文按字可断，系统会把「(这一页)」拆成「(这 / 一页)」）。
    /// 更远的行本来就隐去了，不必量。折好的文字同时交给布局估行高，两边按同一份文字算。
    private func wrappedTexts(width: CGFloat) -> [String] {
        lines.enumerated().map { index, line in
            guard let current = currentIndex, abs(index - current) <= 3, !line.text.isEmpty else { return line.text }
            let isCurrent = index == current
            return ImmersiveLyricWrap.wrapped(line.text, width: width, fontSize: isCurrent ? currentSize : baseSize,
                                              weight: isCurrent ? .bold : .semibold, tracking: 0)
        }
    }

    @ViewBuilder
    private func row(index: Int, line: LyricLine, text: String, layout: LyricScrollLayout.Layout,
                     textWidth: CGFloat) -> some View {
        let style = layout.style(at: index) ?? .init(scale: 0.72, opacity: 0.3, blur: 0.6, isCurrent: false)
        let translation = line.translationText(showingTranslation: showTranslation)

        VStack(alignment: .leading, spacing: style.isCurrent ? 4 : 2) {
            primaryRowText(line: line, text: text, isCurrent: style.isCurrent, textWidth: textWidth)
                .font(.system(size: style.isCurrent ? currentSize : baseSize,
                              weight: style.isCurrent ? .bold : .semibold,
                              design: .default))
                .foregroundStyle(style.isCurrent ? Color.primary : Color.primary.opacity(0.72))
                .multilineTextAlignment(.leading)
                .lineLimit(style.isCurrent ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)

            if let translation {
                Text(translation)
                    .font(.system(size: style.isCurrent ? translationSize : max(11, translationSize * 0.85),
                                  weight: .regular,
                                  design: .default))
                    .foregroundStyle(Color.primary.opacity(style.isCurrent ? 0.68 : 0.48))
                    .multilineTextAlignment(.leading)
                    .lineLimit(style.isCurrent ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(style.opacity)
        .blur(radius: reduceMotion ? 0 : style.blur)
        // 跃动：非当前行缩小；当前行从 bounceStartScale 弹到 1.0。
        .scaleEffect(scale(for: style), anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xl)
        // 纵向高度完全由外层 `.frame(height:)` 决定，保证布局坐标与点击坐标完全一致。
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { seek(to: line) }
        .animation(reduceMotion ? nil : Motion.lyricSpring, value: currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(translation.map { "\(line.text) \($0)" } ?? line.text))
        .accessibilityAddTraits(style.isCurrent ? [.isSelected] : [])
        .accessibilityAction(named: Text("从这一句开始播放")) { seek(to: line) }
    }

    @ViewBuilder
    private func primaryRowText(line: LyricLine, text: String, isCurrent: Bool, textWidth: CGFloat) -> some View {
        if isCurrent, line.hasWordTiming, !line.text.isEmpty {
            Text(ImmersiveLyricWrap.wrapped(LyricWordHighlight.attributedString(for: line, at: model.lyric.time),
                                            width: textWidth, fontSize: currentSize, weight: .bold, tracking: 0))
        } else {
            Text(text.isEmpty ? "♪" : text)
        }
    }

    /// 行的实际缩放：非当前行按布局衰减；当前行在跃动起始帧压小，再弹回 1。
    private func scale(for style: LyricScrollLayout.LineStyle) -> CGFloat {
        guard style.isCurrent else { return style.scale }
        return isBouncing ? LyricScrollLayout.bounceStartScale : 1.0
    }

    // MARK: - 其它状态

    private var maskedState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("隐私模式已开启")
                .flowType(FlowType.lyricCurrent(size: currentSize))
                .foregroundStyle(FlowColor.secondaryText)
            Text("歌名与歌词已隐藏")
                .flowType(FlowType.lyricNeighbor(size: baseSize))
                .foregroundStyle(FlowColor.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(Spacing.xl)
    }

    private var unsyncedLyrics: some View {
        let plain = model.lyric.unsyncedLines.isEmpty ? lines.map(\.text) : model.lyric.unsyncedLines
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(plain.enumerated()), id: \.offset) { _, text in
                    Text(text.isEmpty ? "♪" : text)
                        .flowType(FlowType.lyricNeighbor(size: baseSize))
                        .foregroundStyle(FlowColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.xl)
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private var emptyState: some View {
        if providedLines == nil && model.lyricState == .loading && model.track != nil {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("正在载入歌词")
                    .flowType(FlowType.lyricNeighbor(size: baseSize))
                    .foregroundStyle(FlowColor.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(Spacing.xl)
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(model.track == nil ? "还没有播放"
                     : (providedLines == nil && model.lyricState == .failed ? "歌词加载失败" : "没有找到同步歌词"))
                    .flowType(FlowType.lyricCurrent(size: currentSize))
                    .foregroundStyle(FlowColor.secondaryText)
                Text(model.track == nil
                     ? "在歌词区右边搜索，或点一首推荐"
                     : "在歌词区点右键可以换一版")
                    .flowType(FlowType.lyricNeighbor(size: baseSize))
                    .foregroundStyle(FlowColor.tertiaryText)
                if model.track != nil, providedLines == nil {
                    LyricQuickActionsBar(model: model)
                        .padding(.top, Spacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(Spacing.xl)
        }
    }

    private func seek(to line: LyricLine) {
        guard let engine = app?.lyricEngine, let document = engine.document,
              let playback = app?.playback else { return }
        let offset = engine.userOffset + document.embeddedOffset
        Task { await playback.seek(to: max(0, line.start - offset)) }
    }
}

extension LyricWordHighlight {
    /// 用 `AttributedString` 为逐字/逐词片段赋予前景透明度，支持跨多行自然折行的高亮渲染。
    /// - Parameter baseAlpha: 还没唱到的字的不透明度。沉浸模式压在动态画面上，要比纯色底更实一点。
    static func attributedString(for line: LyricLine, at time: TimeInterval, baseAlpha: Double = 0.32) -> AttributedString {
        var result = AttributedString()
        for run in runs(for: line, at: time) {
            var segment = AttributedString(run.text)
            let alpha = baseAlpha + (1 - baseAlpha) * min(max(run.progress, 0), 1)
            segment.foregroundColor = Color.primary.opacity(alpha)
            result.append(segment)
        }
        return result
    }
}
