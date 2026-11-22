import CoreGraphics
import Foundation

/// 评分权重。全部可调，默认值经过手工调参：位置记忆 > 移动成本 > 边缘偏好。
struct PlacementWeights: Sendable, Equatable {
    var fit: Double = 1.0
    var preferred: Double = 0.55
    var edge: Double = 0.15
    var occlusion: Double = 2.0
    var movement: Double = 0.45
    var morphing: Double = 0.30
    var instability: Double = 0.60
}

/// 稳定性参数。规格给出的起始值，全部可通过初始化注入，便于测试不同组合。
struct PlacementTuning: Sendable, Equatable {
    var debounce: Duration = .milliseconds(100)
    var snapDistance: CGFloat = 12
    /// 新方案相对当前方案的提升比例低于此值时保持不动。
    var minimumImprovement: Double = 0.15
    var morphologyCooldown: Duration = .milliseconds(800)
}

/// 纯函数放置求解器。不接触任何窗口对象，输入快照、输出决策，因此可以被穷举测试。
struct PlacementSolver: Sendable {
    var weights = PlacementWeights()
    var tuning = PlacementTuning()
    var shapes: [LyricsShape] = [.board, .doubleLine, .capsule, .edge]

    struct Candidate: Sendable, Equatable {
        var frame: CGRect
        var shape: LyricsShape
        var score: Double
        var occlusion: Double
    }

    func solve(_ snapshot: SpatialSnapshot) -> PlacementDecision {
        // 1. 全屏：直接隐藏。这是唯一优先于"用户锁定"的规则。
        if snapshot.frontmostApp?.isFullscreen == true {
            return PlacementDecision(
                frame: snapshot.floatingFrame ?? defaultFrame(snapshot, shape: snapshot.currentShape),
                shape: snapshot.currentShape,
                reason: .hidden,
                shouldHide: true
            )
        }

        let zone = snapshot.safeZone
        guard zone.width > 0, zone.height > 0 else {
            return PlacementDecision(
                frame: snapshot.floatingFrame ?? .zero,
                shape: snapshot.currentShape,
                reason: .hidden,
                shouldHide: true
            )
        }

        // 2. 用户锁定：只做可见性修复，不因评分更高而移动。
        if snapshot.isLocked, let current = snapshot.floatingFrame {
            return PlacementDecision(
                frame: current.clamped(into: zone),
                shape: snapshot.currentShape,
                reason: .locked,
                shouldHide: false
            )
        }

        // 3. 求解。
        let free = FreeSpaceAnalyzer.maximalRects(in: zone, obstacles: snapshot.obstacles)
        var candidates: [Candidate] = []

        for rect in free {
            for shape in shapes where shape.preferredSize.width <= rect.width
                && shape.preferredSize.height <= rect.height {
                for anchor in FreeSpaceAnalyzer.anchorPoints(in: rect, size: shape.preferredSize) {
                    let score = score(frame: anchor, shape: shape, snapshot: snapshot, container: rect)
                    candidates.append(Candidate(frame: anchor, shape: shape, score: score.total, occlusion: score.occlusion))
                }
            }
        }

        // 当前位置始终参与竞争，否则"保持不动"永远赢不了新候选。
        if let current = snapshot.floatingFrame, zone.contains(current) {
            let score = score(frame: current, shape: snapshot.currentShape, snapshot: snapshot, container: zone)
            if score.occlusion == 0 {
                candidates.append(Candidate(frame: current, shape: snapshot.currentShape,
                                            score: score.total, occlusion: 0))
            }
        }

        guard let best = candidates.max(by: { lhs, rhs in
            // 同分时按坐标排序，保证求解结果确定，不会在等价候选之间来回跳。
            if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score < rhs.score }
            if abs(lhs.frame.minY - rhs.frame.minY) > 0.5 { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX > rhs.frame.minX
        }) else {
            return fallback(snapshot)
        }

        // 4. 滞回：当前方案仍然有效时，新方案必须明显更好才允许移动。
        if let current = snapshot.floatingFrame, zone.contains(current) {
            let currentScore = score(frame: current, shape: snapshot.currentShape,
                                     snapshot: snapshot, container: zone)
            if currentScore.occlusion == 0 {
                let improvement = (best.score - currentScore.total) / max(abs(currentScore.total), 0.001)
                if improvement < tuning.minimumImprovement {
                    return PlacementDecision(
                        frame: current,
                        shape: snapshot.currentShape,
                        reason: .keepCurrent,
                        shouldHide: false
                    )
                }
            }
        }

        let reason: PlacementDecision.PlacementReason = best.shape == snapshot.currentShape ? .solved : .solved
        return PlacementDecision(
            frame: EdgeSnap.snap(best.frame, in: zone, distance: tuning.snapDistance),
            shape: best.shape,
            reason: reason,
            shouldHide: false
        )
    }

    // MARK: - 评分

    struct ScoreBreakdown {
        var total: Double
        var occlusion: Double
    }

    func score(frame: CGRect, shape: LyricsShape, snapshot: SpatialSnapshot, container: CGRect) -> ScoreBreakdown {
        let zone = snapshot.safeZone
        guard zone.width > 0, zone.height > 0 else { return ScoreBreakdown(total: -.infinity, occlusion: 1) }

        let area = max(frame.width * frame.height, 1)
        let overlap = snapshot.obstacles.reduce(CGFloat.zero) { partial, obstacle in
            let inter = obstacle.intersection(frame)
            return partial + (inter.isNull ? 0 : inter.width * inter.height)
        }
        let occlusion = min(1, overlap / area)

        // 适配度：容器越大越从容，但用平方根压低，避免"最大矩形通吃"。
        let slack = container.width * container.height / area
        let fit = min(1, sqrt(slack) / 2)

        // 位置记忆：用户偏好点归一化到安全区，比较候选中心距离。
        var preferred = 0.5
        if let origin = snapshot.userPreferredOrigin {
            let target = CGPoint(
                x: zone.minX + origin.x * zone.width,
                y: zone.minY + origin.y * zone.height
            )
            let distance = hypot(frame.midX - target.x, frame.midY - target.y)
            let diagonal = hypot(zone.width, zone.height)
            preferred = max(0, 1 - Double(distance / max(diagonal, 1)))
        }

        // 边缘偏好：贴近安全区边界更"不打扰"。
        let nearestEdge = min(
            min(frame.minX - zone.minX, zone.maxX - frame.maxX),
            min(frame.minY - zone.minY, zone.maxY - frame.maxY)
        )
        let edge = max(0, 1 - Double(max(nearestEdge, 0) / 240))

        // 移动成本：相对当前位置的位移。
        var movement = 0.0
        if let current = snapshot.floatingFrame {
            let delta = hypot(frame.midX - current.midX, frame.midY - current.midY)
            let diagonal = hypot(zone.width, zone.height)
            movement = min(1, Double(delta / max(diagonal, 1)))
        }

        let morphing = shape == snapshot.currentShape ? 0.0 : 1.0

        let total = fit * weights.fit
            + preferred * weights.preferred
            + edge * weights.edge
            - occlusion * weights.occlusion
            - movement * weights.movement
            - morphing * weights.morphing

        return ScoreBreakdown(total: total, occlusion: occlusion)
    }

    // MARK: - 兜底

    /// 没有任何合法候选（障碍物几乎占满、或所有形态都放不下）：贴最近边并接受最小重叠。
    private func fallback(_ snapshot: SpatialSnapshot) -> PlacementDecision {
        let zone = snapshot.safeZone
        let size = CGSize(
            width: min(snapshot.preferredSize.width, zone.width),
            height: min(snapshot.preferredSize.height, zone.height)
        )

        let current = snapshot.floatingFrame
        let center = current.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: zone.midX, y: zone.midY)

        // 投影到最近的一条边。
        let distances: [(edge: Int, distance: CGFloat)] = [
            (0, abs(center.x - zone.minX)),
            (1, abs(zone.maxX - center.x)),
            (2, abs(center.y - zone.minY)),
            (3, abs(zone.maxY - center.y)),
        ]
        let nearest = distances.min { $0.distance < $1.distance }?.edge ?? 0

        var frame = CGRect(x: zone.midX - size.width / 2, y: zone.midY - size.height / 2,
                           width: size.width, height: size.height)
        switch nearest {
        case 0: frame.origin.x = zone.minX
        case 1: frame.origin.x = zone.maxX - size.width
        case 2: frame.origin.y = zone.minY
        default: frame.origin.y = zone.maxY - size.height
        }
        frame = frame.integral.clamped(into: zone)

        return PlacementDecision(frame: frame, shape: snapshot.currentShape,
                                 reason: .fallbackEdge, shouldHide: false)
    }

    private func defaultFrame(_ snapshot: SpatialSnapshot, shape: LyricsShape) -> CGRect {
        let zone = snapshot.safeZone
        let size = shape.preferredSize
        return CGRect(x: zone.midX - size.width / 2, y: zone.maxY - size.height - 24,
                      width: size.width, height: size.height).clamped(into: zone)
    }
}
