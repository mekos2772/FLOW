import CoreGraphics
import Foundation

/// 过渡用的阻尼弹簧规格。
///
/// 物理模型与 SwiftUI 的 `Spring(response:dampingRatio:)` 完全一致，
/// 但这里自己算采样值：窗口要按显示器刷新逐帧推进，
/// 而且**几何必须能被钳制**（目标框紧贴安全余量，过冲会压到别人的窗口）。
struct SpringSpec: Sendable, Equatable {
    /// 感知时长（秒）。越小越急。
    var response: Double
    /// 阻尼比。1 = 临界阻尼（到达即停）；<1 会过冲；>1 只减速、绝不越过。
    var dampingRatio: Double

    /// 自然角频率。
    var omega: Double { 2 * .pi / max(response, 0.0001) }

    /// t 秒时的进度。可以大于 1（过冲）或小于 0（起步回拉）。
    func progress(at time: Double) -> Double {
        let t = max(time, 0)
        let z = max(dampingRatio, 0.0001)
        let w = omega
        if abs(z - 1) < 1e-4 {
            // 临界阻尼：唯一解，不会过冲。
            return 1 - exp(-w * t) * (1 + w * t)
        }
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
        }
        // 过阻尼：两个实根，慢的那个主导，因此"绝不越过"。
        let s = (z * z - 1).squareRoot()
        let r1 = -z * w + w * s
        let r2 = -z * w - w * s
        let c2 = -r1 / (r1 - r2)
        let c1 = 1 - c2
        return 1 - (c1 * exp(r1 * t) + c2 * exp(r2 * t))
    }

    /// 理论稳定时间（|1-p| 降到 0.1% 所需时间）。
    ///
    /// 过阻尼要特别处理：收敛速度由**较慢的那个实根**决定，
    /// 而不是 `ζω`。用错会让躲避动画在半路就被截断（实测 E 配方差 0.39s，
    /// 收尾会肉眼可见地跳一下）。
    var settlingDuration: Double {
        let z = max(dampingRatio, 0.0001)
        guard z > 0 else { return .infinity }
        let w = omega
        let rate: Double
        if z < 1 {
            rate = z * w
        } else if abs(z - 1) < 1e-4 {
            rate = w
        } else {
            // 慢根：r = ζω - ω√(ζ²-1)
            rate = z * w - w * (z * z - 1).squareRoot()
        }
        return -log(0.001) / max(rate, 0.0001)
    }

    /// 峰值进度。欠阻尼 >1，临界与过阻尼 =1。
    var peakProgress: Double {
        guard dampingRatio < 1 else { return 1 }
        var peak = 0.0
        var t = 0.0
        while t < settlingDuration + response {
            peak = max(peak, progress(at: t))
            t += 0.002
        }
        return peak
    }
}

/// 三次贝塞尔控制点。y 可以 > 1，从而产生"冲过目标再回来"的过冲。
struct BezierCurve: Sendable, Equatable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
}

/// 一套过渡的完整配方：几何怎么走、内容怎么跟。
struct TransitionRecipe: Sendable, Equatable {
    /// 几何（窗口 frame）使用的弹簧。
    var geometry: SpringSpec
    /// 几何是否允许过冲。只有"变小"方向可以放开，变大时必然越界。
    var geometryMayOvershoot: Bool
    /// 内容层（缩放/圆角）的过冲强度，0 表示内容也不弹。
    var contentOvershoot: Double
    /// 窗口几何用的贝塞尔控制点（由弹簧曲线拟合，见 `MotionCatalog` 注释）。
    ///
    /// 为什么窗口用贝塞尔而不是自己逐帧算：
    /// 浮动面板在应用非激活时会被系统节流 `CADisplayLink`（实测回调间隔约 200ms），
    /// 自己驱动的窗口动画会明显一顿一顿。交给 AppKit 的动画上下文由系统调度即可满帧。
    /// 过冲由控制点 y > 1 表达（三次贝塞尔的 y 不受 [0,1] 约束）。
    var geometryCurve: BezierCurve
    /// 内容层使用更短的感知时长，让它比几何"先到位、再轻微回弹"。
    var contentResponseScale: Double

    /// 动画总时长（秒）。显式给出，不从弹簧稳定时间反推——
    /// 弹簧的 5%→95% 区间只占稳定时间的约 25%（实测 158ms / 0.65s），
    /// 按 settle 推时长会让"看得见的运动"短得离谱（这正是"几乎没有动画"的根源）。
    var duration: Double

    /// 给定时刻的几何进度（已按策略钳制）。
    func geometryProgress(at time: Double) -> Double {
        let raw = geometry.progress(at: time)
        return geometryMayOvershoot ? raw : min(raw, 1)
    }

    /// 给定时刻的内容缩放。过冲只体现在这里，因此不受安全区约束。
    func contentScale(at time: Double) -> Double {
        guard contentOvershoot > 0 else { return 1 }
        let spec = SpringSpec(response: geometry.response * contentResponseScale,
                              dampingRatio: geometry.dampingRatio)
        let p = spec.progress(at: time)
        // 把"超过 1 的部分"按强度放大，得到可见但不夸张的回弹。
        return 1 + (p - 1) * contentOvershoot * 4
    }
}

/// 过渡配方表：**唯一**决定"哪种动作用什么手感"的地方。
///
/// 用户选定的口径：形态切换用 C 弹性、移动用 B 轻阻尼、被动动作用 E 过阻尼。
/// 歌词动画不在此表内——它保持原有曲线，不被这次改造波及。
enum MotionCatalog {
    /// C 弹性：明显物件感，约 5% 过冲。
    static let elastic = SpringSpec(response: 0.36, dampingRatio: 0.68)
    /// B 轻阻尼：收得住，约 1% 过冲。
    static let lightDamping = SpringSpec(response: 0.30, dampingRatio: 0.86)
    /// E 过阻尼：绝不越过。
    ///
    /// response 必须比欠阻尼配方的**更小**：过阻尼的尾巴很长，
    /// 同样的 response 反而收敛更慢（ζ=1.3 / 0.26s 要 0.61s，
    /// 比弹性的 0.65s 只快一点点，作为"被动动作"还不够利落）。
    static let overdamped = SpringSpec(response: 0.20, dampingRatio: 1.30)
    /// 临界阻尼：需要"干净且仍然算弹簧"时使用。
    static let critical = SpringSpec(response: 0.32, dampingRatio: 1.0)

    /// 展开到完整播放器。
    ///
    /// 几何钳制：目标框已经贴着安全余量（6pt 障碍间距 + 4pt 边距），
    /// 1020 宽的窗口过冲 5% 就是 51pt，必然压到别的窗口。
    static let expand = TransitionRecipe(geometry: SpringSpec(response: 0.40, dampingRatio: 0.68),
                                         geometryMayOvershoot: false,
                                         contentOvershoot: 0.05,
                                         geometryCurve: BezierCurve(x1: 0.42, y1: 0.00, x2: 0.30, y2: 1.000),
                                         contentResponseScale: 0.85,
                                         duration: 0.48)

    /// 收缩成悬浮形态。
    ///
    /// **几何可以放开过冲**：越界只会更小，不会压到任何东西。
    /// 所以这是全表里手感最弹的一个。
    static let collapse = TransitionRecipe(geometry: SpringSpec(response: 0.34, dampingRatio: 0.68),
                                           geometryMayOvershoot: true,
                                           contentOvershoot: 0.05,
                                           geometryCurve: BezierCurve(x1: 0.40, y1: 0.00, x2: 0.30, y2: 1.000),
                                         contentResponseScale: 0.85,
                                         duration: 0.44)

    /// 悬浮形态之间互切（胶囊 ↔ 迷你 ↔ 贴边）：高频操作，回弹要短促。
    static let morph = TransitionRecipe(geometry: SpringSpec(response: 0.30, dampingRatio: 0.68),
                                        geometryMayOvershoot: false,
                                        contentOvershoot: 0.05,
                                        geometryCurve: BezierCurve(x1: 0.40, y1: 0.00, x2: 0.28, y2: 1.000),
                                         contentResponseScale: 0.9,
                                         duration: 0.42)

    /// 同形态移动：只是位置变化，1% 回弹就够。
    static let move = TransitionRecipe(geometry: SpringSpec(response: 0.30, dampingRatio: 0.86),
                                       geometryMayOvershoot: false,
                                       contentOvershoot: 0,
                                       geometryCurve: BezierCurve(x1: 0.36, y1: 0.00, x2: 0.26, y2: 1.000),
                                         contentResponseScale: 1,
                                         duration: 0.36)

    /// 躲避让位：被动动作，最快贴上目标、绝不越过，也不抢注意力。
    static let dodge = TransitionRecipe(geometry: SpringSpec(response: 0.20, dampingRatio: 1.30),
                                        geometryMayOvershoot: false,
                                        contentOvershoot: 0,
                                        geometryCurve: BezierCurve(x1: 0.22, y1: 0.00, x2: 0.28, y2: 1.000),
                                         contentResponseScale: 1,
                                         duration: 0.24)

    /// 收进隐匿把手：消失在即，弹一下反而拖沓，应是全表最快。
    static let hide = TransitionRecipe(geometry: SpringSpec(response: 0.16, dampingRatio: 1.30),
                                       geometryMayOvershoot: false,
                                       contentOvershoot: 0,
                                       geometryCurve: BezierCurve(x1: 0.20, y1: 0.00, x2: 0.26, y2: 1.000),
                                         contentResponseScale: 1,
                                         duration: 0.20)

    /// 从隐匿恢复：重新出现要有存在感，但别弹得夸张。
    static let restore = TransitionRecipe(geometry: SpringSpec(response: 0.32, dampingRatio: 0.86),
                                          geometryMayOvershoot: false,
                                          contentOvershoot: 0.03,
                                          geometryCurve: BezierCurve(x1: 0.36, y1: 0.00, x2: 0.26, y2: 1.000),
                                         contentResponseScale: 0.9,
                                         duration: 0.36)

    /// 按形态与方向挑选配方。
    static func recipe(from: PlayerMorphology, to: PlayerMorphology) -> TransitionRecipe {
        if to == .expanded { return expand }
        if from == .expanded { return collapse }
        if to == .dormant { return hide }
        if from == .dormant { return restore }
        return morph
    }
}

extension SpringSpec {
    /// SwiftUI `Animation.spring(response:bounce:)` 的等价表示。
    ///
    /// SwiftUI 的 `bounce` 与阻尼比是**互补**关系：`dampingFraction = 1 - bounce`。
    /// 有了这条映射，歌词那类 SwiftUI 弹簧也能用本文件的解析模型算过冲与稳定时间，
    /// 不必再写第二套公式。
    static func swiftUI(response: Double, bounce: Double) -> SpringSpec {
        SpringSpec(response: response, dampingRatio: min(max(1 - bounce, 0.0001), 3))
    }
}
