import SwiftUI

// MARK: - 间距

/// 间距令牌。8pt 网格为主，4pt 用于字内微调。
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    /// 完整播放器的外边距。编辑式排版靠大留白建立层级，这个值决定整窗的"呼吸感"。
    static let windowInset: CGFloat = 28
    /// 版面基线网格。所有纵向节奏都落在 8pt 的整数倍上，
    /// 这样标题、副标题、控件、进度线之间的距离是"同一套比例"，
    /// 而不是各自随手调的 5/6/7/9。
    static let grid: CGFloat = 8
    /// 悬浮形态里"文字 → 进度线"的统一留白。
    /// 规格要求所有形态保持统一比例，原来各形态分别是 5 / 8 / 10 / 4，视觉上像四种字体排版。
    static let lyricLineGap: CGFloat = 6
    /// 悬浮形态的统一左内边距（贴边形态因宽度受限单独用 `lyricInsetTight`）。
    static let lyricInset: CGFloat = 16
    static let lyricInsetTight: CGFloat = 10
}

// MARK: - 形状

/// 圆角令牌。
enum Radius {
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let container: CGFloat = 16
    static let board: CGFloat = 20
    /// 完整播放器窗口。比容器再大一档，让"这是一件桌面物品"的感觉成立。
    static let window: CGFloat = 22
    static let artwork: CGFloat = 14
    static let capsule: CGFloat = 28
}

// MARK: - 材质

/// 材质分层：同一区域最多两层，禁止玻璃套玻璃。
enum Surface {
    /// 窗口底：最轻的一层，内容压在它上面。
    /// 注意 SwiftUI 的 `Material` 只有 5 档 + `.bar`，没有 AppKit 的 `.underWindowBackground`/`.popover`。
    static let background: Material = .regularMaterial
    /// 中景：控制条、侧栏这类需要与内容分开的带状区域。
    static let chrome: Material = .bar
    /// 浮层：菜单、弹层。
    static let overlay: Material = .thickMaterial
    /// 窗口底色：压在材质下面，决定"看得清"这件事。
    /// 只用材质会把桌面透过来，浅色桌面上文字立刻糊成一片。
    static func windowBase(_ scheme: ColorScheme) -> Color {
        // 用**确定值**而不是 NSColor.windowBackgroundColor：
        // 后者是动态色，在无边框 + 自定义背景的窗口里解析出来的明度不稳定
        // （浅色下实测整窗落成纯白 255，与设计稿的中性灰差了一整档）。
        // 纯黑白体系：R=G=B，一丝色偏都不要（原来是 0.106/0.106/0.118，蓝味明显）。
        scheme == .dark
            ? Color(white: 0.09)
            : Color(white: 0.96)
    }

    /// 悬浮胶囊 / 迷你条：极轻的黑白半透明材质。
    ///
    /// 不用系统 `Material`：材质会把桌面颜色透上来并做一层 vibrancy，
    /// 在纯黑白体系里等于重新引入彩色（彩色壁纸会让胶囊发绿、发蓝）。
    /// 这里用**显式的黑白半透明**，颜色完全可控。
    static func translucentFill(_ scheme: ColorScheme) -> Color {
        // "透明歌词"：胶囊默认只剩一层几乎看不见的纸底（浅 26% / 深 4%）。
        // 文字靠加粗与字号撑对比，而不是靠底板——底板一厚就回到"卡片"的感觉。
        // 底板必须保证"文字在任何背景上都读得出来"。
        // 之前深色外观用 4% 白底：壁纸一浅、或窗口压上来，白字直接消失（实测整条歌词看不见）。
        // 现在深色外观铺一层**深色压底**（不透明度 42%），浅色外观铺白色压底；
        // 透明感保留（还能看见壁纸），但不再赌背景颜色。
        scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.62)
    }

    /// 压在**别的窗口**上时用的底。
    ///
    /// 透明胶囊只在壁纸上有足够对比；一旦允许压住别人窗口（空间挤到没有空位时的让位），
    /// 白底窗口上就会出现"白字压白底"——实测整条歌词看不见。
    /// 这种情况必须给一层实底，宁可牺牲透明感也不能没有字。
    static func overlappingFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.72) : Color.white.opacity(0.92)
    }

    /// 贴边 / 隐匿形态：几乎没有背景，只留一层极淡的纸底。
    static func bareFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.34) : Color.white.opacity(0.5)
    }

    /// 系统开启「减少透明度」时的替代底色。
    ///
    /// 材质是半透明的，开了 reduce-transparency 还铺磨砂等于和系统设置对着干：
    /// 文字会浮在壁纸上，对比度直接崩。这里给一个不透明底 + 一条细描边维持分层
    /// （不透明底失去的层次感靠描边补回来）。
    static func opaqueFallback(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.12)
            : Color(white: 0.97)
    }

    /// 统一入口：给定形态所需的表面层，返回可直接 `.fill` 的样式。
    /// - `reduceTransparency` 为真时不铺材质，改用不透明底。
    static func fill(for layer: SurfaceLayer,
                     scheme: ColorScheme,
                     reduceTransparency: Bool) -> AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(opaqueFallback(scheme))
        }
        switch layer {
        case .container: return AnyShapeStyle(background)
        case .translucent: return AnyShapeStyle(translucentFill(scheme))
        // 贴边形态平时只有一层极淡的纸底（"几乎没背景"），但开了减少透明度就必须给实底，
        // 否则文字直接压在壁纸上。
        case .bare: return AnyShapeStyle(bareFill(scheme))
        }
    }

    /// 形态规格里的背景层 → 实际材质。`bare` 返回 nil 表示不铺任何背景。
    static func material(for layer: SurfaceLayer) -> Material? {
        switch layer {
        case .container: return background
        // 悬浮形态不再用系统材质（会把壁纸的彩色透上来）。
        case .translucent, .bare: return nil
        }
    }
}

// MARK: - 动效

/// 动效令牌。数值区间来自设计规范，曲线按场景区分——
/// 不要给所有交互套同一个 `.easeInOut`。
enum Motion {
    /// 按钮按下/悬停
    static let micro: Double = 0.14
    /// 控件状态切换（开关、选中态）
    static let control: Double = 0.22
    /// 歌词行切换：需要"连续运动"的观感
    static let lyric: Double = 0.34
    /// 悬浮窗形态变形
    static let morph: Double = 0.42
    /// 封面切换
    static let artwork: Double = 0.55
    /// 背景氛围色过渡：最慢，避免颜色抖动抢注意力
    static let ambient: Double = 0.78

    /// 完整展开：比收缩更有仪式感，但不超过 0.6s。
    static let expand: Double = 0.56
    /// 收缩：快一点，因为用户在离开。
    static let collapse: Double = 0.40
    /// 隐匿：最短路径。
    static let dormant: Double = 0.26
    /// 次级内容抽屉。
    static let drawer: Double = 0.30
    /// 内容跨形态交接（旧内容淡出 / 新内容淡入的重叠窗口）。
    static let handoff: Double = 0.26

    /// 位移/尺寸类：轻微减速，落点确定，不弹跳。
    static func move(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.61, 0.24, 1.0, duration: duration)
    }

    /// 带阻尼的弹簧：歌词行切换、卡片形态变化的"跃动"来源。
    ///
    /// 用 SwiftUI 原生弹簧（不是自算曲线），因为它会跟随刷新率逐帧插值，
    /// 而且 `bounce` 参数把"过冲多少"表达得非常直接。
    /// - bounce 0 = 临界阻尼（不弹）；0.2–0.3 是"有弹性但不夸张"的区间。
    static func spring(response: Double = 0.38, bounce: Double = 0.26) -> Animation {
        .spring(response: response, dampingFraction: 1 - bounce)
    }

    /// 歌词行切换：略快、有弹性。
    static let lyricSpring = spring(response: 0.34, bounce: 0.30)
    /// 歌词整体滚动：慢一点，避免整块文字抖。
    static let lyricScroll = spring(response: 0.44, bounce: 0.18)

    /// 透明度类：线性一点更干净。
    static func fade(_ duration: Double) -> Animation {
        .easeOut(duration: duration)
    }

    /// 抽屉/面板：进入时轻微减速，退出时更快。
    static func panel(_ duration: Double, presenting: Bool) -> Animation {
        .timingCurve(presenting ? 0.20 : 0.40, presenting ? 0.72 : 0.0, 0.24, 1.0,
                     duration: presenting ? duration : duration * 0.78)
    }

    /// 尊重"减少动态效果"：需要位移动画的地方统一走这里。
    static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - 排版

/// 排版层级。层级靠字号/字重/字距/透明度建立，不靠边框和底色。
///
/// 编辑式排版的关键是**字距**：大字号收紧、小号标签放开，
/// 这一条比字号本身更能拉开与系统默认界面的距离。
struct FlowType: Sendable, Equatable {
    var size: CGFloat
    var weight: Font.Weight
    var tracking: CGFloat
    var lineSpacing: CGFloat
    var monospacedDigit: Bool

    init(size: CGFloat, weight: Font.Weight = .regular, tracking: CGFloat = 0,
         lineSpacing: CGFloat = 0, monospacedDigit: Bool = false) {
        self.size = size
        self.weight = weight
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.monospacedDigit = monospacedDigit
    }

    var font: Font {
        let base = Font.system(size: size, weight: weight)
        return monospacedDigit ? base.monospacedDigit() : base
    }

    func scaled(_ factor: CGFloat) -> FlowType {
        FlowType(size: size * factor, weight: weight, tracking: tracking * factor,
                 lineSpacing: lineSpacing * factor, monospacedDigit: monospacedDigit)
    }

    /// 小号标签：放开字距 + 全大写，是最省力的"编辑感"来源。
    static let wordmark = FlowType(size: 10.5, weight: .semibold, tracking: 3.0)
    static let eyebrow = FlowType(size: 10, weight: .semibold, tracking: 1.7)
    /// 主标题：字号略收、字距收紧——大字号靠"紧"显得精密，靠"粗"只会显得笨。
    static let trackTitle = FlowType(size: 31, weight: .semibold, tracking: -0.9, lineSpacing: 0)
    static let trackTitleCompact = FlowType(size: 20, weight: .semibold, tracking: -0.3)
    static let artist = FlowType(size: 12, weight: .medium, tracking: 0.6)
    static let body = FlowType(size: 13, weight: .regular)
    // 首页用正常阅读字号，不沿用悬浮形态的小标签。
    static let pageTitle = FlowType(size: 26, weight: .semibold, tracking: -0.5)
    static let homeTitle = FlowType(size: 16, weight: .medium)
    static let homeControl = FlowType(size: 14, weight: .medium)
    static let homeSecondary = FlowType(size: 13)
    static let caption = FlowType(size: 11.5, weight: .regular, tracking: 0.3)
    static let timecode = FlowType(size: 10.5, weight: .medium, tracking: 0.5, monospacedDigit: true)
    static let lyric = FlowType(size: 16, weight: .regular, tracking: 0.1, lineSpacing: 5)
    /// 分区标签（"现在播放""歌词""接下来"）：小字号 + 大字距，靠空气拉开层级。
    static let sectionLabel = FlowType(size: 9.5, weight: .semibold, tracking: 2.0)

    /// 当前歌词：字号最大、字重最重、字距收紧，行距按字号比例给。
    static func lyricCurrent(size: CGFloat) -> FlowType {
        FlowType(size: size, weight: .semibold, tracking: -0.4, lineSpacing: max(4, size * 0.22))
    }

    static func lyricNeighbor(size: CGFloat) -> FlowType {
        // 上下文行加一点字距：小字号下正字距更好读，也让"上下文"与"当前行"的收紧形成对比。
        FlowType(size: size, weight: .regular, tracking: 0.2, lineSpacing: max(2, size * 0.18))
    }
}

// MARK: - 颜色

/// 颜色令牌。
///
/// 规则来自规格 2.5：封面色只做**氛围来源**，不做整窗填充。
/// 因此这里提供的都是"带透明度的强调色"，且必须经过 `ambient` 降饱和处理。
enum FlowColor {
    /// 分隔线：比系统 separator 更淡，避免界面被线切碎。
    static let hairline = Color.primary.opacity(0.08)
    /// 次级文字。
    /// 次要文字。
    ///
    /// 用**动态 NSColor** 而不是 `Color.primary.opacity(...)`：
    /// 同一个透明度在深色底和浅色底上的可读性完全不同（浅色 55% 黑偏糊），
    /// 动态色能按外观自动换档，调用点一处都不用改。
    static let secondaryText = Color(nsColor: NSColor(name: "flow.secondaryText") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // 静态令牌也要照顾「提高对比度」：系统这个开关就是用户说"我看不清"。
        // 之前只有 `secondaryText(contrast:)` 这个函数版本会变，而调用点几乎都用静态属性，
        // 等于开关按了没反应（实测审查发现）。
        let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor.labelColor.withAlphaComponent(isDark ? (high ? 0.74 : 0.58)
                                                            : (high ? 0.82 : 0.68))
    })

    /// 次要文字按明度分档：白底上的 55% 黑比黑底上的 55% 白更糊，
    /// 所以浅色模式要压得更实一点。
    static func secondaryText(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return Color.primary.opacity(0.82) }
        return Color.primary.opacity(scheme == .dark ? 0.58 : 0.66)
    }

    /// 前后歌词：故意压暗，但不能压到"看得见却读不出"。
    static func lyricNeighbor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        if contrast == .increased { return Color.primary.opacity(scheme == .dark ? 0.66 : 0.74) }
        return Color.primary.opacity(scheme == .dark ? 0.44 : 0.52)
    }

    /// 提高对比度时把次要文字调亮：系统这个开关就是替用户说"我看不清"。
    static func secondaryText(contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.primary.opacity(0.78) : secondaryText
    }

    /// 前后歌词这类"故意压暗"的文字：提高对比度时也抬到可读区。
    static func neighborText(contrast: ColorSchemeContrast, base: Double = 0.40) -> Color {
        contrast == .increased ? Color.primary.opacity(min(base + 0.24, 0.72)) : Color.primary.opacity(base)
    }
    /// 三级文字（标签、时间码）。
    static let tertiaryText = Color(nsColor: NSColor(name: "flow.tertiaryText") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor.labelColor.withAlphaComponent(isDark ? (high ? 0.62 : 0.48)
                                                            : (high ? 0.72 : 0.58))
    })
    /// 悬停底色。
    static let hover = Color.primary.opacity(0.06)
    /// 按下底色。
    static let pressed = Color.primary.opacity(0.11)
    /// 进度轨道。
    static let track = Color.primary.opacity(0.12)

    /// 强调色：纯黑白体系里唯一的高对比元素。
    ///
    /// 浅色下用纯黑、深色下用纯白——不再取系统强调色（那会带进蓝/紫等彩色），
    /// 也不做任何饱和度处理。当前歌词竖标、播放进度、激活态都走这个色。
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1) : Color(white: 0)
    }

    /// 封面氛围色在某一块区域里的强度。
    ///
    /// 纯黑白体系里氛围光必须**去饱和**：封面再鲜艳，落到界面上也只能是一团中性灰，
    /// 否则等于把彩色渐变偷偷放回来。
    static func ambientWash(_ color: Color?, colorScheme: ColorScheme) -> Color {
        guard let color else { return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06) }
        let gray = Color(nsColor: (NSColor(color).usingColorSpace(.genericGray) ?? .gray))
        return gray.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    /// 当前歌词的强调色：只在"当前行左侧的竖标"和进度线用，正文仍是主文字色。
    static func emphasis(_ color: Color?) -> Color {
        Color.primary
    }
}

// MARK: - 文字样式修饰器

extension View {
    /// 应用 `FlowType`：字体 + 字距 + 行距一次到位。
    func flowType(_ type: FlowType) -> some View {
        self
            .font(type.font)
            .tracking(type.tracking)
            .lineSpacing(type.lineSpacing)
    }
}

/// 控件状态：悬停/按下只做亮度与极小的尺寸变化，不做整体缩放。
struct InteractiveHighlight: ViewModifier {
    var cornerRadius: CGFloat = Radius.control
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.micro), reduceMotion: reduceMotion),
                       value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func interactiveHighlight(cornerRadius: CGFloat = Radius.control) -> some View {
        modifier(InteractiveHighlight(cornerRadius: cornerRadius))
    }
}
