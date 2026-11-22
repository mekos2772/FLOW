import SwiftUI

/// 迷你播放器（Compact）。
///
/// 横向空带保留封面、歌名与控制键；纵向空位充足时增加歌词上下文。
/// 副信息优先显示当前歌词——这样从迷你收缩成胶囊时，用户盯着的那行字不会变。
struct CompactBarView: View {
    @Bindable var model: MorphPresentationModel
    var onExpand: () -> Void
    var onTogglePlay: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    /// 拖动进度线后跳到目标秒数。
    var onSeek: (TimeInterval) -> Void

    /// 拖动中的进度（0…1）。非 nil 时进度线跟手，松手才真正 seek。
    @State private var scrubProgress: Double?

    private var scrubBinding: Binding<Double> {
        Binding(get: { scrubProgress ?? model.progress },
                set: { scrubProgress = min(max($0, 0), 1) })
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// 深浅由根视图的局部背景策略提供；轻投影只负责纹理分离。
    private var textLegibilityShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        colorScheme == .dark
            ? (Color.black.opacity(0.55), 2.5, 1)
            : (Color.black.opacity(0.18), 2, 1)
    }

    private var compactBaseStyle: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Surface.opaqueFallback(colorScheme)) }
        if model.floatingNeedsSolidBase {
            return AnyShapeStyle(Surface.overlappingFill(colorScheme))
        }
        return Surface.fill(for: .translucent, scheme: colorScheme, reduceTransparency: false)
    }

    /// 副标题优先当前歌词，其次艺术家；两者都没有时给本地化兜底。
    private var subtitle: LocalizedStringKey? {
        if let line = model.lyric.current?.text, !line.isEmpty, !model.isMasked {
            return LocalizedStringKey(line)
        }
        if let artist = model.displayArtist { return LocalizedStringKey(artist) }
        return model.isMasked ? "隐私模式已开启" : "在完整播放器里浏览或搜索音乐"
    }

    var body: some View {
        GeometryReader { geometry in
            // 动画期间用钉住的目标尺寸：断点只落地时变一次，不逐帧换视图树。
            let presentationSize = model.presentationSizeOverride ?? geometry.size
            let presentation = CompactSpacePresentation(size: presentationSize)
            let fit = FloatingLyricMetrics.compact(presentationSize,
                                                   horizontalInset: presentation.showsContext ? 18 : Spacing.s,
                                                   showsContext: presentation.showsContext)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(compactBaseStyle)
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.s) {
                        ArtworkSlab(image: model.artwork, ambient: model.ambient,
                                    side: presentation.artworkSide,
                                    cornerRadius: Radius.control, showsAmbientGlow: false)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayTitle.map { LocalizedStringKey($0) } ?? "还没有播放")
                                .flowType(FlowType.trackTitleCompact.scaled(presentation.showsContext ? 0.9 : 0.74))
                                .foregroundStyle(.primary)
                                .lineLimit(presentation.showsContext ? 2 : 1)
                            Text(subtitle ?? LocalizedStringKey(""))
                                .flowType(.caption)
                                .foregroundStyle(Color.primary.opacity(0.68))
                                .lineLimit(presentation.showsContext ? 2 : 1)
                                .contentTransition(.opacity)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 动画期间关掉文字投影：它要逐帧离屏渲染，是这块版面上最贵的装饰。
                        .shadow(color: model.isAnimatingGeometry ? .clear : textLegibilityShadow.color,
                                radius: textLegibilityShadow.radius, y: textLegibilityShadow.y)
                        // QQ 音乐 / 网易云的迷你条都是"上一首 / 播放 / 下一首"三键。
                        // 这里原来只有播放与下一首，想退一首必须展开成完整播放器。
                        HStack(spacing: 0) {
                            FlowIconButton(systemName: "backward.fill", label: "上一首",
                                           isEnabled: model.track != nil, size: 26, symbolSize: 11,
                                           action: onPrevious)
                            FlowPlayButton(isPlaying: model.isPlaying, size: 30, action: onTogglePlay)
                            FlowIconButton(systemName: "forward.fill", label: "下一首",
                                           isEnabled: model.track != nil, size: 26, symbolSize: 11,
                                           action: onNext)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    if presentation.showsContext {
                        VStack(alignment: .leading, spacing: 8) {
                            if fit.showsPrevious, let previous = model.previousLine, !model.isMasked {
                                Text(previous)
                                    .flowType(.caption)
                                    .foregroundStyle(Color.primary.opacity(0.38))
                                    .lineLimit(1)
                            }
                            if model.showsFloatingLine {
                                Text(model.floatingLine)
                                    .flowType(FlowType.lyricCurrent(size: fit.primarySize))
                                    .foregroundStyle(.primary)
                                    .lineLimit(fit.primaryLineLimit)
                            }
                            Text(model.nextLine ?? (model.track == nil ? "点这里展开" : " "))
                                .flowType(.caption)
                                .foregroundStyle(Color.primary.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                    } else if presentation.showsNext {
                        Text(model.nextLine ?? (model.track == nil ? "点这里展开" : " "))
                            .flowType(.caption)
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 10)
                    }
                    // 这条线原来只是画出来的：2pt 高、不可交互，想拖回去只能展开完整播放器。
                    // 换成真正的滑杆——外观仍是 2pt 贴底细线，热区 20pt，可拖、可读屏。
                    HairlineSlider(value: scrubBinding,
                                   range: 0...1,
                                   onEditingChanged: { editing in
                                       guard !editing, let target = scrubProgress else { return }
                                       onSeek(target * max(model.duration, 0))
                                       scrubProgress = nil
                                   },
                                   accessibilityLabel: "播放进度",
                                   pinsTrackToBottom: true)
                        .opacity(model.track == nil ? 0 : 1)
                        .disabled(model.track == nil)
                        .frame(height: 20)
                }
                .padding(.horizontal, fit.horizontalInset)
                .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(FlowColor.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onTapGesture(perform: onExpand)
            .accessibilityElement(children: .contain)
        }
    }

    private var radius: CGFloat {
        PlayerMorphology.compact.geometry.cornerRadius
    }
}

/// 形态内容的圆角：随高度连续收敛，因此"矩形变胶囊"是随窗口高度插值发生的。
enum MorphCorner {
    static func radius(for morphology: PlayerMorphology, height: CGFloat) -> CGFloat {
        morphology.geometry.cornerRadius(forHeight: height)
    }
}
