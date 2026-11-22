import CoreGraphics
import Foundation

/// 形态切换的时间参数。
///
/// 这里刻意把"多久之后允许自动收缩"与"用户是否还在用"分开：
/// 时间只做防抖，真正决定要不要收缩的是交互事件与前台状态。
/// 规格明确禁止"固定等待几秒然后强行收缩"，所以 `autoCollapseDelay`
/// 必须配合 `interactionGrace` 一起看，任何一次用户交互都会把免打扰窗口往后推。
struct MorphologyTuning: Sendable, Equatable {
    /// 前台应用切走之后，稳定多久才允许根据空间收缩。
    var autoCollapseDelay: Duration = .milliseconds(350)
    /// 用户最后一次主动操作之后的免打扰期。这段时间内绝不自动收缩。
    var interactionGrace: Duration = .milliseconds(900)
    /// 两次形态切换的最小间隔，防止在临界空间里来回跳。
    var morphologyCooldown: Duration = .milliseconds(350)
    /// 空间改善多少比例才允许放宽形态（胶囊 → 迷你）。与放置求解器用同一个量级。
    var minimumPromotionImprovement: Double = 0.18
    /// 当前位置被前台窗口遮挡超过这个比例，才算"需要避让"。
    /// 太低会因为边缘轻微交叠就乱跑；太高就变成"被压住也不动"。
    var relocationOverlapThreshold: Double = 0.18
    /// 重定位必须带来至少这么多（遮挡面积占比）的改善才值得动一下。
    /// 对应规格 6.8 的 MinimumPlacementImprovement。
    var minimumRelocationImprovement: Double = 0.15

    /// 完整展开（由小变大）。
    var expandDuration: Duration = .milliseconds(300)
    /// 收缩（由大变小）。
    var collapseDuration: Duration = .milliseconds(220)
    /// 悬浮形态之间的平级切换。
    var morphDuration: Duration = .milliseconds(180)
    /// 隐匿与恢复用最短路径。
    var dormantDuration: Duration = .milliseconds(160)

    /// 位移超过屏幕对角线这个比例时，不再让窗口横穿工作区，
    /// 改为"短暂淡出 → 迁移 → 淡入"。
    var longDistanceFraction: Double = 0.32
    /// 长距离重定位时淡出/淡入各占的时间比例。
    var crossfadeShare: Double = 0.28

    /// 放宽形态前确认空位持续存在，避免拖动经过的一瞬间展开。
    var promotionStability: Duration = .milliseconds(450)

    static let `default` = MorphologyTuning()
}
