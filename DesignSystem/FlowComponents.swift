import AppKit
import SwiftUI

// MARK: - 标签

/// 小号全大写标签。编辑式排版的"骨架线"，只出现在分区顶部。
struct SectionLabel: View {
    let text: LocalizedStringKey
    var color: Color = FlowColor.tertiaryText

    init(text: LocalizedStringKey, color: Color = FlowColor.tertiaryText) {
        self.text = text
        self.color = color
    }

    /// 已经是运行时拼好的字符串（比如错误标题），没法再走 key 查表。
    init(verbatim text: String, color: Color = FlowColor.tertiaryText) {
        self.text = LocalizedStringKey(text)
        self.color = color
    }

    var body: some View {
        Text(text)
            .flowType(.sectionLabel)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// 一行弱化的说明文字。
struct FlowCaption: View {
    let text: LocalizedStringKey

    init(text: LocalizedStringKey) { self.text = text }

    /// 运行时字符串（错误文案、偏移量等）用这个入口，不查表。
    init(verbatim text: String) { self.text = LocalizedStringKey(text) }

    var body: some View {
        Text(text)
            .flowType(.caption)
            .foregroundStyle(FlowColor.tertiaryText)
    }
}

// MARK: - 按钮

/// 图标按钮。视觉 15pt、命中区 30pt——看着轻，点得中。
struct FlowIconButton: View {
    let systemName: String
    /// 无障碍名称。用 LocalizedStringKey 而不是 String：
    /// 图标按钮没有可见文字，VoiceOver 念的就是这句——它必须跟着语言走。
    let label: LocalizedStringKey
    var isActive = false
    var isEnabled = true
    var size: CGFloat = 30
    var symbolSize: CGFloat = 15
    /// 完整窗口采用清楚的按钮状态；悬浮形态保留原有轻量样式。
    var prominent = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            // 命中自定义字形表就画 Beadline 图标，没命中回落 SF——第三方语义不强行替换。
            flowIcon(systemName: systemName, size: symbolSize)
                .foregroundStyle(prominent
                                 ? Color.primary.opacity(isEnabled ? (isHovering || isActive ? 1 : 0.78) : 0.3)
                                 : foreground.opacity(isEnabled ? (isHovering || isActive ? 1 : 0.55) : 0.28))
                .frame(width: size, height: size)
                .background(prominent && isEnabled && (isHovering || isActive) ? FlowColor.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(Motion.respectingReduceMotion(Motion.fade(Motion.micro), reduceMotion: reduceMotion),
                   value: isHovering)
        .accessibilityLabel(Text(label))
        .help(label)
    }

    private var foreground: Color {
        if !isEnabled { return FlowColor.tertiaryText.opacity(0.5) }
        return isActive ? Color.primary : FlowColor.secondaryText
    }
}

/// 主播放键。40pt 圆，静态时只比周围略亮一点——不做彩色大圆抢注意力。
struct FlowPlayButton: View {
    let isPlaying: Bool
    var size: CGFloat = 44
    /// 没有可播曲目时置灰。
    ///
    /// 这个按钮以前永远可点：空闲态点下去什么都没发生——看起来"坏了"，
    /// 其实是队列里根本没有东西。宁可灰掉，也不要给一个没有反应的按钮。
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                // 实心主色圆是整页唯一的强对比块：黑白界面需要一个"视觉落点"，
                // 否则视线在满屏灰阶里没有着落点。
                Circle()
                    .fill(Color.primary.opacity(!isEnabled ? 0.18 : (isHovering ? 0.92 : 1)))
                flowIcon(systemName: isPlaying ? "pause.fill" : "play.fill",
                         size: size * 0.4, weight: .semibold)
                    .foregroundStyle(Surface.windowBase(colorScheme).opacity(isEnabled ? 1 : 0.5))
                    // play 三角形视觉重心偏左，右移 0.5pt 才看起来居中。
                    .offset(x: isPlaying ? 0 : 0.5)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(Motion.respectingReduceMotion(Motion.fade(Motion.micro), reduceMotion: reduceMotion),
                   value: isHovering)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }
}

/// 文字按钮（抽屉底部、空态引导用）。
struct FlowTextButton: View {
    let title: LocalizedStringKey
    var symbolName: String?
    var prominent = false
    let action: () -> Void

    init(title: LocalizedStringKey, symbolName: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.prominent = prominent
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xxs) {
                if let symbolName {
                    flowIcon(systemName: symbolName, size: prominent ? 14 : 11)
                }
                Text(title).flowType(prominent ? .homeControl : .caption)
            }
            .foregroundStyle(isHovering ? Color.primary : FlowColor.secondaryText)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isHovering ? FlowColor.hover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 封面

/// 封面块。
///
/// 只铺一层：封面图本身 + 背后一团低强度氛围光。
/// 规格禁止"卡片套卡片"，所以这里没有描边、没有内嵌材质、没有高光。
struct ArtworkSlab: View {
    let image: NSImage?
    let ambient: ArtworkPalette.Color?
    var side: CGFloat
    var cornerRadius: CGFloat = Radius.artwork
    var showsAmbientGlow = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 纯黑白体系里不再有封面氛围光晕：彩色被抽走后，光晕只剩一圈脏灰。
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))

            if let image {
                // `aspectRatio(.fill)` 的**布局尺寸会超出**给定的 frame：
                // 把 `frame` 直接挂在图片上时，非正方形封面会把整个方块撑宽
                // （实测 244pt 的槽位被撑到 326pt，并且左边缘被推出窗口）。
                // 正确做法是先用一个固定尺寸的透明块占住槽位，再把图放进它的 overlay——
                // overlay 不参与父级尺寸计算，溢出部分交给 `clipped()` 裁掉。
                Color.clear
                    .frame(width: side, height: side)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                // 无封面时不是"一块灰砖"，而是一层极浅的纸 + 一枚很淡的音符。
                FlowIconView(glyph: .note, size: side * 0.22)
                    .foregroundStyle(FlowColor.tertiaryText.opacity(0.5))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 1px hairline：让封面与白底之间有一条"刻线"，而不是靠阴影浮起来。
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(FlowColor.hairline, lineWidth: 1)
        }
        .accessibilityLabel("专辑封面")
    }
}

// MARK: - 进度

/// 细进度线。只画轨道与已完成部分，拖动交给 `HairlineSlider`。
struct HairlineProgress: View {
    var progress: Double
    var tint: Color = .primary
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FlowColor.track)
                Capsule()
                    .fill(tint.opacity(0.75))
                    .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - 结构

/// 1pt 分隔线。比系统 separator 更淡。
struct FlowDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(FlowColor.hairline)
            .frame(height: 1)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

/// 次级内容抽屉的容器。
///
/// 只铺一层材质，正文直接压在它上面：不再套卡片、不再加描边。
struct DrawerSurface<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(FlowColor.hairline)
                    .frame(width: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
    }
}

/// 列表行：悬停高亮 + 选中态，不带卡片底色。
struct FlowRow<Content: View, Trailing: View>: View {
    var isSelected: Bool
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                // 用 `Button` 而不是 `.onTapGesture`：后者没有按钮语义，
                // VoiceOver 不会说"可点击"，键盘也聚焦不到、按不了空格。
                // 这是 SwiftUI 里最典型的无障碍坑——看着能点，辅助技术看不见。
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: Spacing.xs) {
            content
            Spacer(minLength: Spacing.xs)
            trailing
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isSelected ? FlowColor.hover : (isHovering ? FlowColor.hover.opacity(0.6) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

extension FlowRow where Trailing == EmptyView {
    init(isSelected: Bool = false,
         action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
        self.trailing = EmptyView()
    }
}
