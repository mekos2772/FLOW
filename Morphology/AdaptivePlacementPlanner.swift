import CoreGraphics
import Foundation

/// 一份不可变几何输入 → 一份形态与落点结论；在后台执行，不访问窗口或 AX。
struct AdaptivePlacementPlanner: Sendable {
    struct Result: Sendable {
        var evaluation: MorphologyEvaluation
        var solution: PlacementSolution
        /// 同形态也可主动舒展或迁往明显更有用的空白。
        var improvesUseOfSpace: Bool = false
    }

    var solver = ContinuousPlacementSolver(usesAvailableSpace: true)

    func evaluate(_ environment: MorphologyEnvironment,
                  permitsMorphing: Bool,
                  promotionImprovement: Double,
                  version: UInt64) -> Result {
        let usable = environment.safeZone.insetBy(dx: solver.edgeInset, dy: solver.edgeInset)
        let free = FreeSpaceAnalyzer.maximalRects(in: usable, obstacles: environment.obstacles)
        let current = environment.current
        let forms: [PlayerMorphology] = [.compact, .capsule, .edge]
        // 恢复要求横纵方向都有余量；只有面积余量会把很长但很窄的缝误判成宽敞。
        let comfort = 1 + max(promotionImprovement, 0) / 2
        let comfortable = forms.first { form in
            let size = form.geometry.minimumSize
            return free.contains { $0.width >= size.width * comfort + solver.obstacleGap * 2
                && $0.height >= size.height * comfort + solver.obstacleGap * 2 }
        }
        let allowed: [PlayerMorphology]
        if !permitsMorphing {
            allowed = [current]
        } else if current == .expanded || current == .dormant {
            allowed = forms
        } else {
            // 同时比较当前与更宽松形态；真正有内容收益才恢复，不强制跳级。
            let limit = min(current.tightness, comfortable?.tightness ?? current.tightness)
            allowed = forms.filter { $0.tightness >= limit }
        }
        var solver = solver
        solver.usesAvailableSpace = permitsMorphing
        let solution = solver.solve(zone: environment.safeZone, obstacles: environment.obstacles,
                                    currentFrame: environment.currentFrame, current: current,
                                    preferredOrigin: nil, allowed: allowed,
                                    snapshotVersion: version, freeRects: free)
        // 求解器的语义是纯几何的：「哪儿都放不下 → 给一个把手（`.dormant`）」。
        // 但"把手"在 `dormantStyle == .hideCompletely` 下等于把窗口藏掉，
        // 那条策略由控制器负责降级（见 `MorphWindowController.applyEvaluation`），
        // 不在这里做 —— 求解器不该知道用户选的是哪种隐匿样式。
        let target = solution.best?.morphology ?? (permitsMorphing ? .dormant : current)
        let recommendation = MorphologyRecommendation(
            morphology: target,
            fitsPreferred: solution.best?.clearance == 0,
            currentStillFits: environment.currentFrame.map { frame in
                usable.contains(frame) && !environment.obstacles.contains(where: { $0.intersects(frame) })
            } ?? false,
            availableSize: solution.best?.frame.size ?? .zero)
        var improves = false
        if permitsMorphing, let frame = environment.currentFrame, let best = solution.best,
           best.morphology == current {
            let previousScore = solver.score(frame: frame, morphology: current, zone: environment.safeZone,
                                             obstacles: environment.obstacles, currentFrame: frame,
                                             current: current, preferredOrigin: nil, freeRects: free)
            let gain = best.score - previousScore
            let sizeChange = abs(best.frame.width - frame.width) >= 24 || abs(best.frame.height - frame.height) >= 20
            let distance = hypot(best.frame.minX - frame.minX, best.frame.minY - frame.minY)
            improves = gain >= max(0.65, abs(previousScore) * promotionImprovement)
                && (sizeChange || distance >= 40)
        }
        return Result(evaluation: .init(recommendation: recommendation, fits: [], note: solution.reason),
                      solution: solution, improvesUseOfSpace: improves)
    }
}

/// 同形态主动优化先等候选稳定；受遮挡的紧急移动不经过这道门槛。
struct SpatialOpportunityGate: Sendable {
    private var candidate: CGRect?
    private var since: ContinuousClock.Instant?
    let delay: Duration = .milliseconds(500)

    mutating func observe(_ frame: CGRect?, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let frame else { candidate = nil; since = nil; return nil }
        if let candidate, abs(candidate.minX - frame.minX) < 12,
           abs(candidate.minY - frame.minY) < 12, abs(candidate.width - frame.width) < 12,
           abs(candidate.height - frame.height) < 12, let since {
            return since.advanced(by: delay)
        }
        candidate = frame
        since = now
        return now.advanced(by: delay)
    }
}

/// 合并事件但不把截止时间不断向后推；拖动中的事件流不会饿死评估。
struct SpatialEvaluationSchedule: Sendable {
    private(set) var deadline: ContinuousClock.Instant?

    mutating func request(now: ContinuousClock.Instant, delay: Duration) -> Bool {
        let proposed = now.advanced(by: delay)
        if let deadline, deadline <= proposed { return false }
        deadline = proposed
        return true
    }

    mutating func consume() { deadline = nil }
}

/// 自动增高时使用已有双行/歌词板视图，持久化的排布偏好不变。
enum CapsuleSpacePresentation {
    static func shape(preferred: LyricsShape, height: CGFloat) -> LyricsShape {
        if preferred == .board || height >= 140 { return .board }
        if preferred == .doubleLine || height >= 72 { return .doubleLine }
        return .capsule
    }
}

/// 由真实窗口高度决定显示多少内容，不因自动布局改写用户的歌词排布偏好。
struct CompactSpacePresentation: Sendable {
    var size: CGSize
    var showsNext: Bool { size.height >= 108 }
    var showsContext: Bool { size.height >= 160 }
    var showsPrevious: Bool { size.height >= 224 }
    var artworkSide: CGFloat { showsContext ? 56 : 44 }
}
