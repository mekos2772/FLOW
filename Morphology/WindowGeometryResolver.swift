import CoreGraphics
import Foundation

/// 屏幕的四条边。贴边形态需要知道"贴哪一条"，恢复时也要按这条边回来。
enum ScreenEdge: String, Sendable, Equatable, Codable {
    case top, bottom, left, right
}

/// 一次几何求解的结论。
struct MorphologyTarget: Sendable, Equatable {
    var frame: CGRect
    /// 是否保住了视觉锚点（顶边与左边不变）。false 表示为了放进屏幕被迫挪了位置。
    var didPreserveAnchor: Bool
    /// 贴边形态贴在哪条边。
    var edge: ScreenEdge?
    /// 求解说明，进日志与实测证据。
    var note: String
}

/// 几何解析器：把"要变成哪个形态"翻译成"窗口应该是多大、放在哪"。
///
/// 全部是纯几何运算（只依赖传入的安全区与障碍物），因此可以脱离真实窗口测试。
/// 关键设计：**先定锚点，再找空隙**。
/// 1. 尺寸由形态规格决定，塞不进安全区就压到最小尺寸；
/// 2. 锚点沿用当前窗口的"顶边 + 左边"——用户看到的是同一个东西在长/缩，
///    而不是新窗口凭空出现；
/// 3. 只有当锚点位置会压住前台窗口时，才在同一块可用矩形里换落点。
struct WindowGeometryResolver: Sendable {
    var tuning: MorphologyTuning
    /// 安全区内再留一点缝，避免窗口紧贴菜单栏或 Dock 看不出边界。
    /// 这是唯一的边距来源：所有 `clamped(into:)` 都显式传 `margin: 0`，
    /// 否则会与这里的内缩叠加，贴边形态会离屏幕边缘 8pt 而不是 4pt。
    var edgeInset: CGFloat

    init(tuning: MorphologyTuning = .default, edgeInset: CGFloat = 4) {
        self.tuning = tuning
        self.edgeInset = edgeInset
    }

    /// 求解目标形态的窗口矩形。
    ///
    /// - Parameters:
    ///   - morphology: 目标形态。
    ///   - currentFrame: 当前窗口矩形（动画中就是真实当前值，因此打断动画不会回跳）。
    ///   - zone: 安全区。
    ///   - obstacles: 前台应用窗口矩形。完整播放器忽略它。
    ///   - edge: 进入贴边形态时希望贴的边；nil 表示按当前窗口位置自动选最近的边。
    func resolve(_ morphology: PlayerMorphology,
                 currentFrame: CGRect,
                 in zone: CGRect,
                 obstacles: [CGRect] = [],
                 edge: ScreenEdge? = nil) -> MorphologyTarget {
        guard zone.width > 1, zone.height > 1 else {
            return MorphologyTarget(frame: currentFrame, didPreserveAnchor: true, edge: edge, note: "安全区为空，保持原状")
        }

        let inner = zone.insetBy(dx: edgeInset, dy: edgeInset)
        let usable = inner.width > 1 && inner.height > 1 ? inner : zone

        switch morphology {
        case .expanded:
            return resolveExpanded(currentFrame: currentFrame, in: usable)
        case .dormant:
            return resolveDormant(currentFrame: currentFrame, in: usable, edge: edge)
        case .edge:
            return resolveEdge(currentFrame: currentFrame, in: usable, obstacles: obstacles, preferred: edge)
        case .compact, .capsule:
            return resolveFloating(morphology, currentFrame: currentFrame, in: usable, obstacles: obstacles)
        }
    }

    // MARK: - 完整播放器

    private func resolveExpanded(currentFrame: CGRect, in zone: CGRect) -> MorphologyTarget {
        let geometry = PlayerMorphology.expanded.geometry
        let size = geometry.fitted(into: zone.size)
        // 顶边 + 左边不动：折叠/展开时用户盯着的是标题和歌词，它们的位置不该跳。
        var frame = CGRect(x: currentFrame.minX, y: currentFrame.maxY - size.height,
                           width: size.width, height: size.height)
        let clamped = frame.clamped(into: zone, margin: 0)
        let preserved = abs(clamped.origin.x - frame.origin.x) < 0.5
            && abs(clamped.origin.y - frame.origin.y) < 0.5
        frame = clamped
        return MorphologyTarget(
            frame: frame,
            didPreserveAnchor: preserved,
            edge: nil,
            note: preserved ? "以左上角为锚点展开" : "空间不足，完整播放器被推回安全区"
        )
    }

    // MARK: - 迷你 / 胶囊

    private func resolveFloating(_ morphology: PlayerMorphology,
                                 currentFrame: CGRect,
                                 in zone: CGRect,
                                 obstacles: [CGRect]) -> MorphologyTarget {
        let inner = zone.insetBy(dx: edgeInset, dy: edgeInset)
        let usable = inner.width > 1 && inner.height > 1 ? inner : zone
        // 先试**标准尺寸 + 当前锚点**：只要它不压到任何障碍物，就用它。
        // 形态的窗口尺寸是设计规格（胶囊 392×56 等），不能为了塞进一条缝就改尺寸——
        // 挤压只在"标准尺寸真的放不下"时才允许。
        let canonicalSize = morphology.geometry.fitted(into: usable.size)
        let canonical = CGRect(x: currentFrame.minX,
                               y: currentFrame.maxY - canonicalSize.height,
                               width: canonicalSize.width,
                               height: canonicalSize.height)
            .integral
            .clamped(into: usable, margin: 0)
        let canonicalFree = obstacles.allSatisfy { !$0.intersects(canonical) }
        if canonicalFree, usable.contains(canonical) {
            let preserved = abs(canonical.minX - currentFrame.minX) < 0.5
                && abs(canonical.maxY - currentFrame.maxY) < 0.5
            return MorphologyTarget(frame: canonical, didPreserveAnchor: preserved, edge: nil,
                                    note: preserved ? "锚点保持，尺寸切到 \(morphology.rawValue)"
                                                    : "标准尺寸放在最近的合法位置")
        }

        // 标准尺寸放不下（会压住别的窗口）：位置交给连续空间求解器，
        // 它会在"自由矩形内的任意合法坐标"里挑一个，必要时才压缩尺寸。
        let solution = ContinuousPlacementSolver(edgeInset: edgeInset).solve(
            zone: zone,
            obstacles: obstacles,
            currentFrame: currentFrame,
            current: morphology,
            preferredOrigin: nil,
            allowed: [morphology]
        )
        guard let best = solution.best else {
            // 这一形态放不下：退回原位置，让上层去降级。
            return MorphologyTarget(frame: currentFrame.integral.clamped(into: zone, margin: 0),
                                    didPreserveAnchor: true, edge: nil,
                                    note: "空间不足，\(morphology.rawValue) 保持原状等降级")
        }
        let preserved = abs(best.frame.minX - currentFrame.minX) < 0.5
            && abs(best.frame.maxY - currentFrame.maxY) < 0.5
        return MorphologyTarget(
            frame: best.frame,
            didPreserveAnchor: preserved,
            edge: nil,
            note: solution.reason
        )
    }

    private func resolveEdge(currentFrame: CGRect,
                             in zone: CGRect,
                             obstacles: [CGRect],
                             preferred: ScreenEdge?) -> MorphologyTarget {
        let geometry = PlayerMorphology.edge.geometry
        let edge = preferred ?? nearestEdge(to: currentFrame, in: zone)
        let thin = min(geometry.preferredSize.height, zone.height)
        var frame: CGRect

        switch edge {
        case .left, .right:
            let width = min(geometry.preferredSize.width, zone.width)
            let y = min(max(currentFrame.midY - thin / 2, zone.minY), zone.maxY - thin)
            let x = edge == .left ? zone.minX : zone.maxX - width
            frame = CGRect(x: x, y: y, width: width, height: thin)
        case .top, .bottom:
            let width = min(max(currentFrame.width, geometry.minimumSize.width), zone.width)
            let x = min(max(currentFrame.midX - width / 2, zone.minX), zone.maxX - width)
            let y = edge == .top ? zone.maxY - thin : zone.minY
            frame = CGRect(x: x, y: y, width: width, height: thin)
        }

        frame = frame.integral.clamped(into: zone, margin: 0)
        // 贴边形态本来就允许压在窗口边缘上一点点，这里只避开"完全被盖住"的情况。
        let dominated = obstacles.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        return MorphologyTarget(
            frame: frame,
            didPreserveAnchor: abs(frame.midX - currentFrame.midX) < 1,
            edge: edge,
            note: dominated ? "贴到 \(edge.rawValue) 边，仍被前台窗口部分覆盖" : "贴到 \(edge.rawValue) 边"
        )
    }

    // MARK: - 隐匿

    private func resolveDormant(currentFrame: CGRect, in zone: CGRect, edge: ScreenEdge?) -> MorphologyTarget {
        let geometry = PlayerMorphology.dormant.geometry
        let nearest = edge ?? nearestEdge(to: currentFrame, in: zone)
        // 把手是竖条，只适合贴左右边；贴到顶/底边时改成横条，避免变成一根竖着的细棍。
        let resolvedEdge: ScreenEdge = (nearest == .top || nearest == .bottom) ? .right : nearest
        let size = resolvedEdge == .left || resolvedEdge == .right
            ? geometry.preferredSize
            : CGSize(width: geometry.preferredSize.height, height: geometry.preferredSize.width)
        var frame = CGRect(x: currentFrame.midX - size.width / 2,
                           y: currentFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        switch resolvedEdge {
        case .top:
            frame.origin.y = zone.maxY - size.height
            frame.origin.x = min(max(frame.minX, zone.minX), zone.maxX - size.width)
        case .bottom:
            frame.origin.y = zone.minY
            frame.origin.x = min(max(frame.minX, zone.minX), zone.maxX - size.width)
        case .left:
            frame.origin.x = zone.minX
            frame.origin.y = min(max(frame.minY, zone.minY), zone.maxY - size.height)
        case .right:
            frame.origin.x = zone.maxX - size.width
            frame.origin.y = min(max(frame.minY, zone.minY), zone.maxY - size.height)
        }
        return MorphologyTarget(
            frame: frame.integral,
            didPreserveAnchor: false,
            edge: resolvedEdge,
            note: "收敛到 \(resolvedEdge.rawValue) 边的把手"
        )
    }

    // MARK: - 工具

    /// 距离窗口中心最近的一条边。
    func nearestEdge(to frame: CGRect, in zone: CGRect) -> ScreenEdge {
        let distances: [(ScreenEdge, CGFloat)] = [
            (.left, abs(frame.midX - zone.minX)),
            (.right, abs(zone.maxX - frame.midX)),
            (.bottom, abs(frame.midY - zone.minY)),
            (.top, abs(zone.maxY - frame.midY)),
        ]
        // 同距离时优先左右边：横向歌词条贴在侧边时视觉重量更轻。
        // 比较函数必须是严格弱序，否则 min(by:) 的结果不确定。
        return distances.min { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 0.5 { return lhs.1 < rhs.1 }
            return edgePriority(lhs.0) < edgePriority(rhs.0)
        }?.0 ?? .top
    }

    private func edgePriority(_ edge: ScreenEdge) -> Int {
        edge == .left || edge == .right ? 0 : 1
    }

    private func largestSize(in rects: [CGRect]) -> CGSize? {
        rects.first.map(\.size)
    }

    private func fits(_ frame: CGRect, size: CGSize, in zone: CGRect) -> Bool {
        abs(frame.width - size.width) < 0.5
            && abs(frame.height - size.height) < 0.5
            && zone.contains(frame)
    }
}
