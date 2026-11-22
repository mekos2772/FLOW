import CoreGraphics
import Foundation

/// 形态决策的空间输入。只放纯几何与播放器自身状态，不放 NSScreen/NSWindow。
struct MorphologyEnvironment: Sendable, Equatable {
    /// 当前显示器的安全区（已扣除菜单栏/Dock/刘海）。
    var safeZone: CGRect
    /// 前台应用的窗口矩形（已裁剪到本屏）。没有辅助功能权限时为空。
    var obstacles: [CGRect]
    /// 播放器当前窗口矩形。用于判断"能不能原地不动"。
    var currentFrame: CGRect?
    var current: PlayerMorphology
    /// 当前窗口被前台窗口遮挡的面积比例（0…1）。
    ///
    /// 只看"这个形态放不放得下"是不够的：胶囊完全可能在被浏览器压住的位置上
    /// "放得下"，于是永远`noBetterOption`——这正是"只会收缩、不会避让"的根因。
    var currentOverlap: Double = 0
}

/// 单个悬浮形态在当前空间里的适配情况。
struct MorphologyFit: Sendable, Equatable {
    var morphology: PlayerMorphology
    /// 能否以期望尺寸放下。
    var fitsPreferred: Bool
    /// 能否以最小尺寸放下。
    var fitsMinimum: Bool
    /// 能容纳它的最大可用矩形尺寸。
    var availableSize: CGSize
    /// 可用面积 / 期望面积。越大越从容。
    var slack: Double
}

/// 一次空间评估的完整结论。
struct MorphologyEvaluation: Sendable, Equatable {
    var recommendation: MorphologyRecommendation
    var fits: [MorphologyFit]
    /// 为什么推荐这个形态，直接用于日志与实测证据。
    var note: String

    func fit(for morphology: PlayerMorphology) -> MorphologyFit? {
        fits.first { $0.morphology == morphology }
    }
}

/// 形态决策引擎：给定可用空间，推荐"最宽松且放得下"的悬浮形态。
///
/// 三条硬规则：
/// 1. **完整播放器不参与空间竞争**——它是用户正在用的窗口，允许压住别人的窗口。
///    `expanded` 只能由用户意图进入或离开，引擎永远不推荐它。
/// 2. **能不动就不动**：当前形态仍以期望尺寸放得下时，一律保持。
/// 3. **换形态要有代价判断**：收紧只在"真的放不下"时发生；
///    放宽需要空间余量达到 `minimumPromotionImprovement`，否则会在临界空间里来回跳。
struct MorphologyEngine: Sendable {
    var tuning: MorphologyTuning
    /// 参与自动决策的形态，从宽松到紧凑。顺序即优先级。
    var candidates: [PlayerMorphology]

    init(tuning: MorphologyTuning = .default,
         candidates: [PlayerMorphology] = [.compact, .capsule, .edge]) {
        self.tuning = tuning
        self.candidates = candidates
    }

    func evaluate(_ environment: MorphologyEnvironment) -> MorphologyEvaluation {
        let zone = environment.safeZone
        guard zone.width > 1, zone.height > 1 else {
            return MorphologyEvaluation(
                recommendation: MorphologyRecommendation(
                    morphology: .dormant, fitsPreferred: false, currentStillFits: false,
                    availableSize: .zero),
                fits: [],
                note: "安全区为空"
            )
        }

        let free = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: environment.obstacles)
        let largest = free.first ?? zone
        let fits = candidates.map { fit(for: $0, in: free) }

        // 从宽松到紧凑，第一个"连最小尺寸都放得下"的形态就是空间允许的上限。
        let workable = fits.first { $0.fitsMinimum }
        let comfortable = fits.first { $0.fitsPreferred }
        let currentFit = fits.first { $0.morphology == environment.current }
        // 被压住就不算"仍然放得下"：必须允许移动到别处，必要时再降级。
        let displaced = environment.currentOverlap > tuning.relocationOverlapThreshold
        let currentStillFits = (currentFit?.fitsMinimum ?? false) && !displaced

        guard let workable else {
            return MorphologyEvaluation(
                recommendation: MorphologyRecommendation(
                    morphology: .dormant, fitsPreferred: false, currentStillFits: false,
                    availableSize: largest.size),
                fits: fits,
                note: "所有悬浮形态都放不下"
            )
        }

        // 被前台窗口压住：形态不变但要求移动（currentStillFits=false 会让执行器重定位）。
        if displaced, let current = currentFit, current.fitsMinimum {
            return MorphologyEvaluation(
                recommendation: MorphologyRecommendation(
                    morphology: current.morphology,
                    fitsPreferred: current.fitsPreferred,
                    currentStillFits: false,
                    availableSize: current.availableSize),
                fits: fits,
                note: "被前台窗口遮挡 \(Int(environment.currentOverlap * 100))%，需要移动"
            )
        }

        // 当前形态仍然可用：能不动就不动，只有明显更宽松的形态才值得放宽。
        if let current = currentFit, current.fitsMinimum {
            if let looser = comfortable,
               looser.morphology.tightness < current.morphology.tightness,
               looser.morphology.tightness >= current.morphology.loosened().tightness,
               looser.slack >= 1 + tuning.minimumPromotionImprovement {
                return MorphologyEvaluation(
                    recommendation: MorphologyRecommendation(
                        morphology: looser.morphology,
                        fitsPreferred: true,
                        currentStillFits: true,
                        availableSize: looser.availableSize),
                    fits: fits,
                    note: "空间变宽，\(current.morphology.rawValue) → \(looser.morphology.rawValue)"
                )
            }
            return MorphologyEvaluation(
                recommendation: MorphologyRecommendation(
                    morphology: current.morphology,
                    fitsPreferred: current.fitsPreferred,
                    currentStillFits: true,
                    availableSize: current.availableSize),
                fits: fits,
                note: current.fitsPreferred ? "当前形态仍然放得下，保持不动" : "空间偏紧，保持当前形态并使用最小尺寸"
            )
        }

        return MorphologyEvaluation(
            recommendation: MorphologyRecommendation(
                morphology: workable.morphology,
                fitsPreferred: workable.fitsPreferred,
                currentStillFits: currentStillFits,
                availableSize: workable.availableSize),
            fits: fits,
            note: "空间不足，\(environment.current.rawValue) → \(workable.morphology.rawValue)"
        )
    }

    /// 放宽判断：只在候选比当前更宽松（tightness 更小）且余量提升足够时才成立。
    private func considerPromotion(from current: MorphologyFit, ideal: MorphologyFit) -> MorphologyFit? {
        guard ideal.morphology.tightness < current.morphology.tightness else { return nil }
        guard ideal.fitsPreferred else { return nil }
        let gain = ideal.slack - current.slack
        guard gain >= tuning.minimumPromotionImprovement else { return nil }
        // 一次只放宽一档：胶囊不能直接跳到迷你以外更宽的形态。
        let nextLooser = current.morphology.loosened()
        guard ideal.morphology.tightness >= nextLooser.tightness else { return nil }
        return ideal
    }

    /// 在极大可用矩形里找能容纳该形态的最大矩形。
    ///
    /// 必须取**同一个矩形**的宽高：把 A 矩形的宽和 B 矩形的高拼起来，
    /// 会得出一个实际不存在的位置，进而推荐放不下的形态。
    private func fit(for morphology: PlayerMorphology, in free: [CGRect]) -> MorphologyFit {
        let geometry = morphology.geometry
        var best = CGSize.zero
        var bestArea: CGFloat = 0
        for rect in free {
            guard rect.width >= geometry.minimumSize.width - 0.5,
                  rect.height >= geometry.minimumSize.height - 0.5 else { continue }
            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                best = rect.size
            }
        }
        let fitsMinimum = bestArea > 0 && geometry.fits(in: best)
        let fitsPreferred = fitsMinimum && geometry.fits(in: best, requirePreferred: true)
        let area = fitsMinimum ? geometry.fitted(into: best) : .zero
        let areaOfNeeded = max(area.width * area.height, 1)
        let slack = (best.width * best.height) / areaOfNeeded
        return MorphologyFit(
            morphology: morphology,
            fitsPreferred: fitsPreferred,
            fitsMinimum: fitsMinimum,
            availableSize: best,
            slack: fitsMinimum ? Double(slack) : 0
        )
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
