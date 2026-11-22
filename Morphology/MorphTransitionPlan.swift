import CoreGraphics
import Foundation

/// 变形动画的执行计划。
///
/// 分离出来是为了让"动画怎么演"成为可测试的数据：
/// 时长、曲线、是否需要淡出迁移，全部由形态与几何决定，而不是散落在窗口代码里的魔法数字。
struct MorphTransitionPlan: Sendable, Equatable {
    var from: PlayerMorphology
    var to: PlayerMorphology
    var fromFrame: CGRect
    var toFrame: CGRect
    /// 窗口几何动画时长。
    var duration: Duration
    /// 是否需要"淡出 → 迁移 → 淡入"（远距离重定位）。
    var relocatesThroughFade: Bool
    /// 内容交接的重叠比例：旧内容淡出与新内容淡入的重叠时间占比。
    var contentOverlapShare: Double
    /// 说明文字，进日志。
    var note: String

    /// 位移距离 / 屏幕对角线。用于判断是否算"远距离"。
    func relativeDistance(screenDiagonal: CGFloat) -> Double {
        let delta = hypot(toFrame.midX - fromFrame.midX, toFrame.midY - fromFrame.midY)
        return Double(delta / max(screenDiagonal, 1))
    }

    /// 由几何决定一个计划。
    static func make(from: PlayerMorphology,
                     to: PlayerMorphology,
                     fromFrame: CGRect,
                     toFrame: CGRect,
                     screenDiagonal: CGFloat,
                     tuning: MorphologyTuning,
                     reduceMotion: Bool) -> MorphTransitionPlan {
        let distance = hypot(toFrame.midX - fromFrame.midX, toFrame.midY - fromFrame.midY)
        let ratio = Double(distance / max(screenDiagonal, 1))
        let longDistance = ratio > tuning.longDistanceFraction && to.isFloating && from.isFloating

        var duration: Duration
        if reduceMotion {
            duration = .milliseconds(0)
        } else if to == .expanded || from == .expanded {
            duration = to == .expanded ? tuning.expandDuration : tuning.collapseDuration
        } else if to == .dormant || from == .dormant {
            duration = tuning.dormantDuration
        } else {
            duration = tuning.morphDuration
        }

        let note: String
        if reduceMotion {
            note = "减少动态效果：直接切换，只保留极短淡入淡出"
        } else if longDistance {
            note = "远距离重定位（\(Int(ratio * 100))% 屏幕对角线）：淡出迁移淡入，不横穿工作区"
        } else {
            note = "连续变形 \(from.rawValue) → \(to.rawValue)"
        }

        return MorphTransitionPlan(
            from: from,
            to: to,
            fromFrame: fromFrame,
            toFrame: toFrame,
            duration: duration,
            relocatesThroughFade: longDistance && !reduceMotion,
            contentOverlapShare: reduceMotion ? 0.5 : 0.35,
            note: note
        )
    }
}
