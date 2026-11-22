import SwiftUI

/// 悬浮歌词四种排布（胶囊 / 双行 / 歌词板 / 贴边）与隐匿把手。
///
/// 它们共享同一个数据投影（`MorphPresentationModel`），
/// 所以歌词、进度、播放状态在形态之间不会有任何一帧不一致。

// MARK: - 胶囊

/// 歌词胶囊：单行歌词 + 细进度线，是主要的桌面陪伴形态。
struct CapsuleLyricsView: View {
    @Bindable var model: MorphPresentationModel
    var onExpand: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 胶囊底板：压在别的窗口上时必须给实底，否则白字压白底看不见。
    private var capsuleBaseStyle: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Surface.opaqueFallback(colorScheme)) }
        if model.floatingNeedsSolidBase {
            return AnyShapeStyle(Surface.overlappingFill(colorScheme))
        }
        return Surface.fill(for: .translucent, scheme: colorScheme,
                            reduceTransparency: reduceTransparency)
    }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let radius = MorphCorner.radius(for: .capsule, height: geo.size.height)
            let fit = FloatingLyricMetrics.capsule(geo.size, horizontalInset: Spacing.lyricInset)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(capsuleBaseStyle)
                    .overlay {
                        // 开了减少透明度就没有材质的柔边，用一条极细描边维持与桌面的分层
                        if reduceTransparency {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(FlowColor.hairline, lineWidth: 1)
                        }
                    }

                HStack(spacing: Spacing.xs) {
                    if model.error != nil {
                        flowIcon(systemName: "exclamationmark.triangle.fill", size: 10)
                            .foregroundStyle(Color.primary.opacity(0.6))
                    } else {
                        WaveMark(isPlaying: model.isPlaying, tint: FlowColor.emphasis(model.ambient?.swiftUIColor))
                    }
                    Text(model.floatingLine)
                        // 透明底上文字要更实：字重提一档、字距略收，靠排印本身撑住可读性。
                        .flowType(FlowType.lyricNeighbor(size: fit.primarySize))
                        .fontWeight(.semibold)
                        .tracking(-0.1)
                        .foregroundStyle(.primary)
                        .lineLimit(fit.primaryLineLimit)
                        .truncationMode(.tail)
                        // 再窄的卡片也尽量整句显示：先缩一点字距，实在不行才省略。
                        .minimumScaleFactor(0.85)
                        .contentTransition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, fit.horizontalInset)
                // 文字在整条胶囊里垂直居中；刻度线用 overlay 钉在下沿。
                // 之前把两者都塞进 ZStack(.bottom)：文字被挤到底部，看起来就是"没居中"。
            }
            .overlay(alignment: .bottom) {
                HairlineProgress(progress: model.progress,
                                 tint: FlowColor.emphasis(model.ambient?.swiftUIColor),
                                 height: FloatingLyricMetrics.progressHeight)
                    .padding(.horizontal, fit.horizontalInset)
                    .padding(.bottom, FloatingLyricMetrics.progressGap)
                    .opacity(model.track == nil ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .floatingTranslationMenu(model: model)
    }
}

// MARK: - 双行

/// 双行：当前行 + 中文译文（优先，若当前行有译文且开关开启）或下一行。
struct DoubleLineLyricsView: View {
    @Bindable var model: MorphPresentationModel
    var onExpand: () -> Void

    @Environment(\.app) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// 悬浮底板：压在别的窗口上时必须给实底，否则白字压白底看不见。
    private var capsuleBaseStyle: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Surface.opaqueFallback(colorScheme)) }
        if model.floatingNeedsSolidBase {
            return AnyShapeStyle(Surface.overlappingFill(colorScheme))
        }
        return Surface.fill(for: .translucent, scheme: colorScheme,
                            reduceTransparency: reduceTransparency)
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let radius = MorphCorner.radius(for: .capsule, height: geo.size.height)
            let fit = FloatingLyricMetrics.doubleLine(geo.size, horizontalInset: Spacing.lyricInset)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(capsuleBaseStyle)
                    .overlay {
                        // 开了减少透明度就没有材质的柔边，用一条极细描边维持与桌面的分层
                        if reduceTransparency {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(FlowColor.hairline, lineWidth: 1)
                        }
                    }
                let showsTranslation = app?.appearance.showLyricTranslation ?? model.showLyricTranslation
                let translation = showsTranslation && !model.isMasked
                    ? model.lyric.current?.translationText(showingTranslation: true) : nil
                VStack(alignment: .leading, spacing: FloatingLyricMetrics.rowGap(base: 2, lineSpacing: app?.appearance.lyricLineSpacing,
                                                                                  scale: 0.25, range: 0...6)) {
                    Text(model.floatingLine)
                        .flowType(FlowType.lyricNeighbor(size: fit.primarySize))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(fit.primaryLineLimit)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                    Text(translation ?? model.nextLine ?? " ")
                        .flowType(FlowType.lyricNeighbor(size: fit.secondarySize))
                        .foregroundStyle(Color.primary.opacity(translation != nil ? 0.72 : 0.55))
                        .lineLimit(fit.secondaryLineLimit)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                }
                // 在"扣掉进度线之后的那块空间"里垂直居中。
                // 顺序很关键：先 maxHeight 撑满，再在底部留出 `bottomInset`——
                // 这样居中发生在剩余区域内，而不会被进度线压住。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, fit.horizontalInset)
                .padding(.bottom, fit.bottomInset)

                HairlineProgress(progress: model.progress,
                                 tint: FlowColor.emphasis(model.ambient?.swiftUIColor),
                                 height: FloatingLyricMetrics.progressHeight)
                    .padding(.horizontal, fit.horizontalInset)
                    .padding(.bottom, FloatingLyricMetrics.progressGap)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .floatingTranslationMenu(model: model)
    }
}

// MARK: - 歌词板

/// 歌词板：随纵向空位展示歌词上下文；强调线跟随当前行，不把空白撑成装饰。
struct BoardLyricsView: View {
    @Bindable var model: MorphPresentationModel
    var onExpand: () -> Void

    @Environment(\.app) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// 悬浮底板：压在别的窗口上时必须给实底，否则白字压白底看不见。
    private var capsuleBaseStyle: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Surface.opaqueFallback(colorScheme)) }
        if model.floatingNeedsSolidBase {
            return AnyShapeStyle(Surface.overlappingFill(colorScheme))
        }
        return Surface.fill(for: .translucent, scheme: colorScheme,
                            reduceTransparency: reduceTransparency)
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let radius = MorphCorner.radius(for: .capsule, height: geo.size.height)
            let fit = FloatingLyricMetrics.board(geo.size, horizontalInset: Spacing.lyricInset)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: min(radius, 24), style: .continuous)
                    .fill(capsuleBaseStyle)
                    .overlay {
                        if reduceTransparency {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(FlowColor.hairline, lineWidth: 1)
                        }
                    }

                VStack(alignment: .leading, spacing: FloatingLyricMetrics.rowGap(base: fit.showsPrevious ? 8 : 6,
                                                                                  lineSpacing: app?.appearance.lyricLineSpacing,
                                                                                  scale: 0.5, range: 2...18)) {
                    if fit.showsPrevious, let previous = model.previousLine, !previous.isEmpty {
                        Text(previous)
                            .flowType(FlowType.lyricNeighbor(size: fit.secondarySize))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    let showsTranslation = app?.appearance.showLyricTranslation ?? model.showLyricTranslation
                    let translation = showsTranslation && !model.isMasked
                        ? model.lyric.current?.translationText(showingTranslation: true) : nil
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.floatingLine)
                            .flowType(FlowType.lyricCurrent(size: fit.primarySize))
                            .foregroundStyle(.primary)
                            // 行数由**可用高度**算出来，而不是写死 2/3 行：
                            // 卡片拉高之后下半张不该空着（之前 200pt 高也只有两行）。
                            .lineLimit(fit.primaryLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                        if let translation {
                            Text(translation)
                                .flowType(FlowType.lyricNeighbor(size: max(11, fit.secondarySize)))
                                .foregroundStyle(Color.primary.opacity(0.76))
                                .lineLimit(max(1, fit.secondaryLineLimit))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(FlowColor.emphasis(model.ambient?.swiftUIColor))
                            .frame(width: 2)
                            .padding(.vertical, 2)
                    }
                    if let next = model.nextLine, !next.isEmpty {
                        Text(next)
                            .flowType(FlowType.lyricNeighbor(size: fit.secondarySize))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .lineLimit(fit.secondaryLineLimit)
                            .truncationMode(.tail)
                    } else if model.track == nil, !model.isMasked {
                        Text("点击打开完整播放器，搜索你想听的音乐")
                            .flowType(.caption)
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .lineLimit(fit.secondaryLineLimit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, fit.horizontalInset)
                .padding(.top, 16)
                .padding(.bottom, fit.bottomInset + 12)

                HairlineProgress(progress: model.progress,
                                 tint: FlowColor.emphasis(model.ambient?.swiftUIColor),
                                 height: FloatingLyricMetrics.progressHeight)
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, FloatingLyricMetrics.progressGap + 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: min(radius, 24), style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .floatingTranslationMenu(model: model)
    }
}

// MARK: - 贴边

/// 贴边：极窄的一条，尽量保留一行歌词，背景几乎不存在。
struct EdgeLyricsView: View {
    @Bindable var model: MorphPresentationModel
    var edge: ScreenEdge
    var onExpand: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let radius = MorphCorner.radius(for: .edge, height: geo.size.height)
            let fit = FloatingLyricMetrics.edge(geo.size, horizontalInset: Spacing.lyricInsetTight)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Surface.opaqueFallback(colorScheme)) : model.floatingNeedsSolidBase
                          ? AnyShapeStyle(Surface.overlappingFill(colorScheme))
                          : Surface.fill(for: .bare, scheme: colorScheme,
                                       reduceTransparency: reduceTransparency))

                HStack(spacing: 6) {
                    // 贴右边时整体镜像：状态标记靠屏幕外缘，文字向中心读，
                    // 否则贴右边会变成"文字紧贴外缘、图标浮在中间"的怪样子。
                    if edge != .right, edge != .top, edge != .bottom {
                        WaveMark(isPlaying: model.isPlaying, tint: .primary, scale: 0.85)
                    }
                    Text(model.floatingLine)
                        .flowType(FlowType.lyricNeighbor(size: fit.primarySize))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(fit.primaryLineLimit)
                        .truncationMode(edge == .right ? .head : .tail)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity, alignment: edge == .right ? .trailing : .leading)
                    if edge == .right {
                        WaveMark(isPlaying: model.isPlaying, tint: .primary, scale: 0.85)
                    }
                }
                .padding(.horizontal, fit.horizontalInset)
                .padding(.bottom, fit.bottomInset + 4)

                HairlineProgress(progress: model.progress, height: 1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .floatingTranslationMenu(model: model)
    }
}

private struct FloatingTranslationMenuModifier: ViewModifier {
    @Bindable var model: MorphPresentationModel
    @Environment(\.app) private var app

    func body(content: Content) -> some View {
        content.contextMenu {
            let showing = app?.appearance.showLyricTranslation ?? model.showLyricTranslation
            Button(showing ? "隐藏中文译文" : "显示中文译文") {
                let next = !showing
                if let app {
                    app.setShowLyricTranslation(next)
                } else {
                    model.showLyricTranslation = next
                }
            }
        }
    }
}

private extension View {
    func floatingTranslationMenu(model: MorphPresentationModel) -> some View {
        modifier(FloatingTranslationMenuModifier(model: model))
    }
}

// MARK: - 隐匿把手

/// 隐匿形态的边缘把手。
///
/// 参考产品形态是**贴边竖条 + 三点**，不是一颗圆点：
/// 竖条更容易点中，贴着左右边缘时也不抢桌面视觉重心。
/// 默认仍然完全隐藏（全屏时不该有任何东西盖上去），开启把手策略才出现。
struct DormantHandleView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MorphPresentationModel
    var onExpand: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            // 把手用**确定的底色**而不是薄材质：贴在壁纸上时材质会被壁纸吃掉，
            // 变成一坨发灰的脏块（实机看过）。这里保持"有实体感但不抢眼"。
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(handleBase)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.5)

            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(FlowColor.emphasis(model.ambient?.swiftUIColor))
                        .frame(width: 3, height: 3)
                        .opacity(dotOpacity(index))
                }
            }
            .opacity(isHovering ? 0.35 : 1)

            if isHovering {
                flowIcon(systemName: "arrow.up.left.and.arrow.down.right", size: 9)
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.fade(Motion.control), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: onExpand)
        .help("显示 FLOW")
        .accessibilityLabel("FLOW 把手")
        .accessibilityAddTraits(.isButton)
    }

    /// 把手的底色：跟随外观取一档中性色，保证在任何壁纸上都能看清边界。
    private var handleBase: Color {
        colorScheme == .dark
            ? Color(white: 0.20).opacity(0.94)
            : Color(white: 0.93).opacity(0.96)
    }

    /// 播放时三点依次变亮，停着时保持静态——不做无限动画。
    private func dotOpacity(_ index: Int) -> Double {
        guard model.isPlaying else { return 0.55 }
        let phase = Int(Date().timeIntervalSince1970 * 2) % 3
        return phase == index ? 1 : 0.45
    }
}

// MARK: - 播放状态波形

/// 播放状态标识：三条短线，播放时高低起伏但极克制（不做无限动画）。
struct WaveMark: View {
    var isPlaying: Bool
    var tint: Color
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(isPlaying ? 0.85 : 0.4))
                    .frame(width: 2 * scale, height: height(for: index) * scale)
            }
        }
        .frame(width: 12 * scale, height: 12 * scale)
        .onAppear { startIfNeeded() }
        .onChange(of: isPlaying) { _, _ in startIfNeeded() }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        guard isPlaying, !reduceMotion else {
            return index == 1 ? 8 : 4
        }
        let base: [CGFloat] = [4, 10, 6]
        let offset = sin(phase + CGFloat(index) * 1.4)
        return max(2, base[index] * (0.6 + 0.4 * offset))
    }

    private func startIfNeeded() {
        guard isPlaying, !reduceMotion else {
            phase = 0
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            phase = .pi
        }
    }
}

extension FloatingLyricMetrics {
    /// 「行距」设置在悬浮多行形态里的行间距：默认 8 时等于原来的 `base`，
    /// 按比例缩小变化幅度并夹在范围内，别把歌词挤出固定高度的胶囊 / 歌词板。
    static func rowGap(base: CGFloat, lineSpacing: Double?, scale: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let delta = CGFloat((lineSpacing ?? 8) - 8) * scale
        return min(max(base + delta, range.lowerBound), range.upperBound)
    }
}
