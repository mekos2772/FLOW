import CoreGraphics
import Foundation

/// 播放器的五种形态。
///
/// 这五种形态是**同一个播放器实体**的五种存在方式，不是五个窗口：
/// 它们共享播放状态、歌词时间轴、主题色与空间位置记忆，可以在彼此之间连续变形。
/// 与 `Overlay/LyricsShape` 的区别：`LyricsShape` 只描述悬浮歌词"长得像什么"，
/// `PlayerMorphology` 描述"整个播放器此刻以什么方式存在"，包含完整播放器本身。
enum PlayerMorphology: String, Codable, CaseIterable, Sendable, Equatable {
    /// 完整播放器：用户主动操作时的形态，允许与其他窗口重叠。
    case expanded
    /// 迷你播放器：已开始工作但仍需要快速控制。
    case compact
    /// 歌词胶囊：默认的桌面陪伴形态。
    case capsule
    /// 贴边：只剩一条紧贴屏幕边缘的歌词。
    case edge
    /// 隐匿：不可见，或只留一个极小的边缘把手。
    case dormant

    /// 从最占空间到最不占空间的顺序。空间降级与升级都按这条轴判断，避免"随意跳级"。
    static let tightnessOrder: [PlayerMorphology] = [.expanded, .compact, .capsule, .edge, .dormant]

    /// 位置越小越紧凑。用于比较两个形态谁更"收敛"。
    var tightness: Int {
        PlayerMorphology.tightnessOrder.firstIndex(of: self) ?? PlayerMorphology.tightnessOrder.count
    }

    /// 是否属于"需要避让其他窗口"的悬浮形态。
    ///
    /// `expanded` 明确排除：它是用户正在使用的应用窗口，允许覆盖别人的窗口。
    /// 如果连完整播放器都要找空隙，用户会看到一个到处乱跑的主界面。
    var isFloating: Bool { self != .expanded }

    /// 是否接受键盘焦点。只有完整播放器需要输入焦点；
    /// 其余形态一旦抢焦点，用户正在打的字就会断掉。
    var acceptsKeyFocus: Bool { self == .expanded }

    /// 是否参与自动形态决策。`expanded` 只能由用户意图进入或离开。
    var participatesInAutoMorph: Bool { self != .expanded }

    var displayName: String {
        switch self {
        case .expanded: return "完整"
        case .compact: return "迷你"
        case .capsule: return "胶囊"
        case .edge: return "贴边"
        case .dormant: return "隐匿"
        }
    }

    var symbolName: String {
        switch self {
        case .expanded: return "rectangle.inset.filled"
        case .compact: return "rectangle.compress.vertical"
        case .capsule: return "capsule"
        case .edge: return "rectangle.portrait.arrowtriangle.2.outward"
        case .dormant: return "moon"
        }
    }

    /// 往下收敛一档；已经在最紧凑时返回自身。
    func tightened() -> PlayerMorphology {
        let order = PlayerMorphology.tightnessOrder
        let index = min(tightness + 1, order.count - 1)
        return order[index]
    }

    /// 往上放宽一档；已经在最完整时返回自身。
    func loosened() -> PlayerMorphology {
        let order = PlayerMorphology.tightnessOrder
        let index = max(tightness - 1, 0)
        return order[index]
    }

    /// 几何规格。所有尺寸集中在这里，视图与窗口层都不写裸数字。
    var geometry: MorphologyGeometry {
        switch self {
        case .expanded:
            return MorphologyGeometry(
                preferredSize: CGSize(width: 1020, height: 640),
                minimumSize: CGSize(width: 780, height: 480),
                maximumSize: nil,
                isResizable: true,
                cornerRadius: 22,
                surface: .container,
                showsWindowChrome: true
            )
        case .compact:
            return MorphologyGeometry(
                preferredSize: CGSize(width: 420, height: 80),
                minimumSize: CGSize(width: 320, height: 68),
                maximumSize: CGSize(width: 640, height: 240),
                isResizable: false,
                cornerRadius: 18,
                surface: .translucent,
                showsWindowChrome: false
            )
        case .capsule:
            return MorphologyGeometry(
                preferredSize: CGSize(width: 392, height: 56),
                minimumSize: CGSize(width: 240, height: 44),
                maximumSize: CGSize(width: 640, height: 200),
                isResizable: false,
                cornerRadius: 28,
                surface: .translucent,
                showsWindowChrome: false
            )
        case .edge:
            return MorphologyGeometry(
                preferredSize: CGSize(width: 300, height: 34),
                minimumSize: CGSize(width: 168, height: 26),
                maximumSize: CGSize(width: 900, height: 44),
                isResizable: false,
                cornerRadius: 10,
                surface: .bare,
                showsWindowChrome: false
            )
        case .dormant:
            // 参考产品形态：不是一颗圆点，而是一条**贴边竖条**（三点）。
            // 竖条更长更好点中，且贴着左右边缘时不会破坏桌面的视觉重心。
            return MorphologyGeometry(
                preferredSize: CGSize(width: 26, height: 72),
                minimumSize: CGSize(width: 20, height: 52),
                maximumSize: CGSize(width: 40, height: 120),
                isResizable: false,
                cornerRadius: 13,
                surface: .bare,
                showsWindowChrome: false
            )
        }
    }
}

/// 隐匿形态的两种策略（规格 3.5）。
enum DormantStyle: String, Codable, Sendable, Equatable, CaseIterable {
    /// 完全隐藏，只留菜单栏与快捷键入口。
    case hideCompletely
    /// 留一颗极小的边缘把手，点一下就回来。
    case edgeHandle

    var displayName: String {
        switch self {
        case .hideCompletely: return "完全隐藏"
        case .edgeHandle: return "保留边缘把手"
        }
    }
}

/// 背景层厚度。同一区域最多一层，禁止玻璃叠玻璃。
enum SurfaceLayer: String, Sendable, Equatable {
    /// 完整播放器：一层低存在感的系统材质。
    case container
    /// 迷你 / 胶囊：轻薄磨砂。
    case translucent
    /// 贴边 / 隐匿：几乎没有背景，只靠文字本身。
    case bare
}

/// 单个形态的几何与表现规格。
struct MorphologyGeometry: Sendable, Equatable {
    var preferredSize: CGSize
    var minimumSize: CGSize
    /// `nil` 表示不设上限（完整播放器可以被拉到任意大）。
    var maximumSize: CGSize?
    var isResizable: Bool
    /// 基础圆角。连续圆角在高度变化时会被压到 `height / 2`，所以胶囊永远是真胶囊。
    var cornerRadius: CGFloat
    var surface: SurfaceLayer
    var showsWindowChrome: Bool

    /// 圆角随高度连续变化：高度比两倍圆角还小时，圆角收缩成胶囊。
    /// 这样"从矩形变成胶囊"是随窗口高度插值自然发生的，不需要单独一条动画。
    func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        let half = max(height, 0) / 2
        return min(cornerRadius, half)
    }

    /// 把期望尺寸塞进可用空间。低于最小尺寸时不再压缩，交给上层判断"放不下"。
    func fitted(into available: CGSize) -> CGSize {
        var width = min(preferredSize.width, max(available.width, minimumSize.width))
        var height = min(preferredSize.height, max(available.height, minimumSize.height))
        if let maximumSize {
            width = min(width, maximumSize.width)
            height = min(height, maximumSize.height)
        }
        return CGSize(width: max(width, minimumSize.width), height: max(height, minimumSize.height))
    }

    /// 该形态能否放进给定尺寸。
    func fits(in size: CGSize, requirePreferred: Bool = false) -> Bool {
        let need = requirePreferred ? preferredSize : minimumSize
        return size.width >= need.width - 0.5 && size.height >= need.height - 0.5
    }
}
