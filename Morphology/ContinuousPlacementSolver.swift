import CoreGraphics
import Foundation

/// 一个候选布局：某个形态放在某个具体位置。
struct PlacementCandidate: Sendable, Equatable {
    var morphology: PlayerMorphology
    var frame: CGRect
    var score: Double
    /// 分项得分，供日志与调试面板展示（不能只给一个总分，否则没法解释"为什么选它"）。
    var breakdown: Breakdown

    struct Breakdown: Sendable, Equatable {
        var stability: Double
        var slack: Double
        var preference: Double
        var morphologyCost: Double
        var movement: Double
    }

    /// 无遮挡等级：0 = 标准尺寸放进干净空间，1 = 勉强放得下（被压扁/很紧），2 = 有遮挡。
    /// 排序时它是**第一关键字**：先找完全没有遮挡的地方，再比分数。
    var clearance: Int
}

/// 求解结论。求解器只产出这个结构，绝不碰 NSWindow。
struct PlacementSolution: Sendable, Equatable {
    var best: PlacementCandidate?
    /// 分数最高的若干个，按分数降序。只给调试用。
    var alternatives: [PlacementCandidate]
    /// 本次求解用到的自由矩形（调试可视化要画它们）。
    var freeRects: [CGRect]
    var reason: String
    /// 快照版本号。执行器用它丢弃过期结果。
    var snapshotVersion: UInt64
}

/// 连续二维空间的布局求解器。
///
/// 与旧实现的区别：**位置不是枚举出来的几个点，而是连续变量**。
/// 对每个自由矩形、每种形态，先对"当前位置""用户记忆位置"做**投影**（把点夹回矩形内，
/// 保持尺寸、尽量少移动），再加上矩形四角/中心/贴边作为备选，
/// 最后用统一评分挑一个——所以屏幕正中间的一块空白也能放，而不是只会去四个角。
struct ContinuousPlacementSolver: Sendable {

    struct Weights: Sendable, Equatable {
        // 权重来自实测：早期版本 stability 4.2 / slack 0.8，
        // 结果会把播放器塞进"最近的一条窄缝"，而放着旁边一大块空区不用。
        // 用户要的是"主动找到合适的空间"，不是"就近塞进去"。
        var stability: Double = 1.6      // 保持不动（避免抖动，但不能压倒空间质量）
        var slack: Double = 5.0          // 空间宽裕：优先大块空区
        var preference: Double = 1.0     // 靠近用户记忆位置
        var morphologyCost: Double = 1.6 // 换形态的代价（每紧凑一档）
        var movement: Double = 1.4       // 移动距离
        var squeeze: Double = 3.0        // 被挤扁的代价
        /// 贴着屏幕上下沿（窄条）的代价：用户更希望歌词待在工作区中间的空隙里，
        /// 而不是被挤到屏幕最边上。
        var edgeBand: Double = 4.0
        var richness: Double = 0.0
    }

    var weights = Weights()
    /// 自动布局主动使用空白；手动切形态与旧调用保持标准尺寸语义。
    var usesAvailableSpace = false
    /// 与障碍物边缘的最小间距。贴上去虽然"合法"，但视觉上就是挡着人家了。
    var obstacleGap: CGFloat = 6
    /// 安全区内再留的缝，避免紧贴菜单栏/Dock。
    var edgeInset: CGFloat = 4

    func solve(zone: CGRect,
               obstacles: [CGRect],
               currentFrame: CGRect?,
               current: PlayerMorphology,
               preferredOrigin: CGPoint?,
               allowed: [PlayerMorphology],
               snapshotVersion: UInt64 = 0,
               freeRects suppliedFreeRects: [CGRect]? = nil) -> PlacementSolution {
        guard zone.width > 1, zone.height > 1 else {
            return PlacementSolution(best: nil, alternatives: [], freeRects: [], reason: "安全区为空", snapshotVersion: snapshotVersion)
        }

        let usable = zone.insetBy(dx: edgeInset, dy: edgeInset)
        let inner = usable.width > 1 && usable.height > 1 ? usable : zone
        let rawFree = suppliedFreeRects ?? FreeSpaceAnalyzer.maximalRects(in: inner, obstacles: obstacles)
        // 生成候选时先按安全间距内缩；某块矩形内缩后装不下任何形态时，仍保留原始矩形兜底。
        let gap = obstacleGap
        let freeRects = rawFree.map { rect in
            let shrunk = rect.insetBy(dx: gap, dy: gap)
            return shrunk.width > gap * 2 && shrunk.height > gap * 2 ? shrunk : rect
        }
        let diagonal = max(hypot(zone.width, zone.height), 1)

        // 硬约束优先：当前窗口本来就合法 → 一律不动。
        // 这是"移动 2pt 不该触发自动移动"的实现点，不靠阈值猜测。
        let currentSize = currentFrame.map { fitSize(current, in: $0.size) }
        let currentClearance = currentFrame.map {
            clearanceLevel(of: $0, morphology: current, obstacles: obstacles)
        } ?? 0
        let sizeAlreadyMatches = currentFrame != nil && currentSize != nil
            && abs(currentFrame!.width - currentSize!.width) < 0.5
            && abs(currentFrame!.height - currentSize!.height) < 0.5
        // 只有"当前就是最优等级（完全无遮挡）"才允许原地不动。
        // 等级更差时，即使当前合法也要去找一块干净的空间——这是用户明确要求的优先级。
        if !usesAvailableSpace, allowed.contains(current), let currentFrame, sizeAlreadyMatches, currentClearance == 0,
           isLegal(currentFrame, in: inner, obstacles: obstacles) {
            let rect = rawFree.first { $0.contains(currentFrame) } ?? inner
            let candidate = score(morphology: current, frame: currentFrame, rect: rect,
                                  currentFrame: currentFrame, preferredOrigin: preferredOrigin,
                                  current: current, diagonal: diagonal, zone: inner)
            return PlacementSolution(
                best: candidate,
                alternatives: [candidate],
                freeRects: freeRects,
                reason: "当前位置仍然合法，保持不动",
                snapshotVersion: snapshotVersion
            )
        }

        // 候选形态由调用方决定；不要提前丢掉紧凑形态，否则
        // “完整胶囊”永远没有机会赢过“被压扁的迷你”。
        var candidates: [PlacementCandidate] = []
        if usesAvailableSpace, allowed.contains(current), let currentFrame,
           isLegal(currentFrame, in: inner, obstacles: obstacles),
           let rect = freeRects.first(where: { $0.contains(currentFrame) }) {
            var candidate = score(morphology: current, frame: currentFrame, rect: rect,
                                  currentFrame: currentFrame, preferredOrigin: preferredOrigin,
                                  current: current, diagonal: diagonal, zone: inner)
            candidate.clearance = clearanceLevel(of: currentFrame, morphology: current, obstacles: obstacles)
            candidates.append(candidate)
        }
        for morphology in allowed {
            for rect in freeRects {
                candidates.append(contentsOf: positions(for: morphology,
                                                        in: rect,
                                                        obstacles: obstacles,
                                                        currentFrame: currentFrame,
                                                        preferredOrigin: preferredOrigin,
                                                        current: current,
                                                        diagonal: diagonal,
                                                        zone: inner))
            }
        }

        // 有"标准尺寸"的落点就绝不用被压扁的落点。
        // 否则会因为"离当前位置更近"而挑一块只够 381 宽的缝，把胶囊压成 381×56（实测）。
        let fullSize = candidates.filter { candidate in
            let preferred = candidate.morphology.geometry.preferredSize
            return candidate.frame.width + 0.5 >= preferred.width
                && candidate.frame.height + 0.5 >= preferred.height
        }
        if !usesAvailableSpace, !fullSize.isEmpty { candidates = fullSize }

        guard !candidates.isEmpty else {
            return PlacementSolution(best: nil, alternatives: [], freeRects: freeRects,
                                     reason: "没有任何自由矩形能容纳候选形态", snapshotVersion: snapshotVersion)
        }

        // 第一关键字：无遮挡等级；第二：评分。这样"远处完全无遮挡"能赢过"近处勉强塞下"。
        let sorted = candidates.sorted {
            if !usesAvailableSpace, $0.clearance != $1.clearance { return $0.clearance < $1.clearance }
            return $0.score > $1.score
        }
        let best = sorted[0]
        let reason = describe(best, current: current, currentFrame: currentFrame, diagonal: diagonal)
        return PlacementSolution(best: best,
                                 alternatives: Array(sorted.prefix(6)),
                                 freeRects: freeRects,
                                 reason: reason,
                                 snapshotVersion: snapshotVersion)
    }

    /// 给一个"已经选定的位置"打分。调试面板/叠加层要显示真实评分，
    /// 不能拿占位 0 冒充（规格 §十一 明确要求显示 layout score）。
    func score(frame: CGRect,
               morphology: PlayerMorphology,
               zone: CGRect,
               obstacles: [CGRect],
               currentFrame: CGRect?,
               current: PlayerMorphology,
               preferredOrigin: CGPoint?,
               freeRects suppliedFreeRects: [CGRect]? = nil) -> Double {
        let usable = zone.insetBy(dx: edgeInset, dy: edgeInset)
        let inner = usable.width > 1 && usable.height > 1 ? usable : zone
        let raw = suppliedFreeRects ?? FreeSpaceAnalyzer.maximalRects(in: inner, obstacles: obstacles)
        let spaces = usesAvailableSpace ? raw.map { rect in
            let shrunk = rect.insetBy(dx: obstacleGap, dy: obstacleGap)
            return shrunk.width > obstacleGap * 2 && shrunk.height > obstacleGap * 2 ? shrunk : rect
        } : raw
        let rect = spaces
            .filter { $0.contains(frame) }
            .max { $0.width * $0.height < $1.width * $1.height } ?? inner
        let diagonal = max(hypot(zone.width, zone.height), 1)
        return score(morphology: morphology, frame: frame, rect: rect,
                     currentFrame: currentFrame, preferredOrigin: preferredOrigin,
                     current: current, diagonal: diagonal, zone: inner).score
    }

    // MARK: - 位置生成

    /// 为"某个形态放进某个自由矩形"生成候选位置。
    ///
    /// 关键在于前两个：它们把**任意的**当前坐标/记忆坐标夹回矩形，
    /// 于是落点是连续量而不是角点。
    private func positions(for morphology: PlayerMorphology,
                           in rect: CGRect,
                           obstacles: [CGRect],
                           currentFrame: CGRect?,
                           preferredOrigin: CGPoint?,
                           current: PlayerMorphology,
                           diagonal: CGFloat,
                           zone: CGRect) -> [PlacementCandidate] {
        let sizes = usesAvailableSpace ? sizeVariants(for: morphology, in: rect)
            : [fitSize(morphology, in: rect.size)]
        return sizes.flatMap { size in
            positions(for: morphology, size: size, in: rect, obstacles: obstacles,
                      currentFrame: currentFrame, preferredOrigin: preferredOrigin,
                      current: current, diagonal: diagonal, zone: zone)
        }
    }

    private func positions(for morphology: PlayerMorphology,
                           size: CGSize,
                           in rect: CGRect,
                           obstacles: [CGRect],
                           currentFrame: CGRect?,
                           preferredOrigin: CGPoint?,
                           current: PlayerMorphology,
                           diagonal: CGFloat,
                           zone: CGRect) -> [PlacementCandidate] {
        guard size.width <= rect.width + 0.5, size.height <= rect.height + 0.5 else { return [] }

        var frames: [CGRect] = []
        if let currentFrame {
            frames.append(project(currentFrame, size: size, into: rect))
        }
        if let preferredOrigin {
            frames.append(project(CGRect(origin: preferredOrigin, size: size), size: size, into: rect))
        }
        if let currentFrame {
            // 形态切换时用户看到的是"同一个东西在缩"，所以优先保住原来的顶边/左边。
            let anchors: [CGPoint] = [
                CGPoint(x: currentFrame.minX, y: currentFrame.maxY - size.height), // 左上
                CGPoint(x: currentFrame.minX, y: currentFrame.minY),               // 左下
                CGPoint(x: currentFrame.maxX - size.width, y: currentFrame.maxY - size.height), // 右上
                CGPoint(x: currentFrame.maxX - size.width, y: currentFrame.minY),  // 右下
            ]
            for origin in anchors {
                frames.append(project(CGRect(origin: origin, size: size), size: size, into: rect))
            }
        }
        frames.append(contentsOf: FreeSpaceAnalyzer.anchorPoints(in: rect, size: size))
        if let edge = edgeSnap(morphology, in: rect, size: size, near: currentFrame) {
            frames.append(edge)
        }
        // 矩形很大时，再补几个"梯度"位置：贴着矩形左/右三分之一处，
        // 让"自由区域中间"也有候选，而不是只有四角和中心。
        for fraction in [0.25, 0.75] {
            let x = rect.minX + (rect.width - size.width) * fraction
            let y = rect.minY + (rect.height - size.height) / 2
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
        }

        var result: [PlacementCandidate] = []
        var seen: Set<String> = []
        for frame in frames.map({ $0.integral }) {
            // 合法性必须同时满足：完整落在**这块自由矩形**内（不是整个安全区），且不碰任何障碍物。
            // 之前这里只校验了安全区，于是"贴着障碍物下缘 33pt 的窄条"也能放进去，
            // 结果播放器被摆到了浏览器里面（实测踩到）。
            guard isLegal(frame, in: rect, obstacles: obstacles) else { continue }
            let key = "\(morphology.rawValue)-\(frame.origin.x)-\(frame.origin.y)-\(frame.width)-\(frame.height)"
            guard seen.insert(key).inserted else { continue }
            var scored = score(morphology: morphology,
                               frame: frame,
                               rect: rect,
                               currentFrame: currentFrame,
                               preferredOrigin: preferredOrigin,
                               current: current,
                               diagonal: diagonal, zone: zone)
            scored.clearance = clearanceLevel(of: frame, morphology: morphology, obstacles: obstacles)
            result.append(scored)
        }
        return result
    }

    /// 0 = 标准尺寸放进一块有余量的空间；1 = 标准尺寸但空间很紧，或被压到最小尺寸；2 = 有遮挡。
    func clearanceLevel(of frame: CGRect,
                        morphology: PlayerMorphology,
                        obstacles: [CGRect]) -> Int {
        if obstacles.contains(where: { $0.intersects(frame) }) { return 2 }
        let preferred = morphology.geometry.preferredSize
        let squeezed = frame.width + 0.5 < preferred.width || frame.height + 0.5 < preferred.height
        return squeezed ? 1 : 0
    }

    /// 不只放大外壳：compact 的高度档位对应控制条、双行歌词、歌词卡片。
    /// 保留最小适配；大块空间里到内容上限就停止增长，不把桌面填成一面墙。
    private func sizeVariants(for morphology: PlayerMorphology, in rect: CGRect) -> [CGSize] {
        let base = fitSize(morphology, in: rect.size)
        guard let maximum = morphology.geometry.maximumSize else { return [base] }
        var sizes = [base]
        let width = floor(min(maximum.width, rect.width))
        let heights: [CGFloat]
        switch morphology {
        case .compact: heights = [80, 112, 168, 240]
        case .capsule: heights = [56, 76, 152, 200]
        case .edge: heights = [34, 44]
        default: return sizes
        }
        for height in heights where height <= rect.height && width >= morphology.geometry.minimumSize.width {
            let size = CGSize(width: width, height: height)
            if !sizes.contains(size) { sizes.append(size) }
        }
        return sizes
    }

    private func fitSize(_ morphology: PlayerMorphology, in available: CGSize) -> CGSize {
        let geometry = morphology.geometry
        var width = min(geometry.preferredSize.width, max(available.width, geometry.minimumSize.width))
        var height = min(geometry.preferredSize.height, max(available.height, geometry.minimumSize.height))
        if let maximum = geometry.maximumSize {
            width = min(width, maximum.width)
            height = min(height, maximum.height)
        }
        return CGSize(width: max(width, geometry.minimumSize.width), height: max(height, geometry.minimumSize.height))
    }

    /// 把一个矩形**投影**进目标矩形：保持尺寸，原点夹到合法范围内。
    /// 这就是"任意合法坐标"的来源——不在四角，也不在中心。
    private func project(_ frame: CGRect, size: CGSize, into rect: CGRect) -> CGRect {
        let maxX = Swift.max(rect.minX, rect.maxX - size.width)
        let maxY = Swift.max(rect.minY, rect.maxY - size.height)
        return CGRect(x: Swift.min(Swift.max(frame.minX, rect.minX), maxX),
                      y: Swift.min(Swift.max(frame.minY, rect.minY), maxY),
                      width: size.width,
                      height: size.height)
    }

    /// 贴边形态：贴到矩形离屏幕边缘最近的那一侧。
    private func edgeSnap(_ morphology: PlayerMorphology,
                          in rect: CGRect,
                          size: CGSize,
                          near currentFrame: CGRect?) -> CGRect? {
        guard morphology == .edge || morphology == .dormant else { return nil }
        guard let currentFrame else { return nil }
        // 选矩形里离当前位置最近的那条边
        let options: [CGRect] = [
            CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: rect.maxX - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height),
            CGRect(x: rect.midX - size.width / 2, y: rect.maxY - size.height, width: size.width, height: size.height),
        ]
        return options.min { lhs, rhs in
            distance(lhs, currentFrame) < distance(rhs, currentFrame)
        }
    }

    // MARK: - 合法性

    /// 合法 = 完全落在安全区内 + 不与任何障碍物相交。
    private func isLegal(_ frame: CGRect, in zone: CGRect, obstacles: [CGRect]) -> Bool {
        guard zone.insetBy(dx: -0.5, dy: -0.5).contains(frame) else { return false }
        return !obstacles.contains { $0.intersects(frame) }
    }

    // MARK: - 评分

    /// 在这块矩形里，**按标准尺寸**能放下的最宽松形态。
    /// 比它更紧凑就属于"没必要地缩"，要额外扣分——否则一条又长又矮的空带
    /// 会让 edge 拿到满分 slack，把明明放得下 mini 的空间浪费掉。
    /// 当前空间能容纳的最宽松形态。
    ///
    /// 判据用**最小尺寸**而不是标准尺寸：形态本身有尺寸区间（mini 320…560、胶囊 240…640），
    /// 一个 320pt 宽的空隙放得下 320 宽的 mini，就该用它，而不是退到 300×34 的贴边条，
    /// 白白浪费掉大半个空隙（用户反馈"变形种类少、用不满空白"）。
    /// "尽量接近标准尺寸"由评分里的 squeeze 惩罚负责，不在这里一刀切。
    func widestSupportedMorphology(in freeRects: [CGRect]) -> PlayerMorphology? {
        [PlayerMorphology.compact, .capsule, .edge].first { morphology in
            let minimum = morphology.geometry.minimumSize
            return freeRects.contains { $0.width + 0.5 >= minimum.width && $0.height + 0.5 >= minimum.height }
        }
    }

    private func supportedMorphology(in rect: CGRect, current: PlayerMorphology) -> PlayerMorphology? {
        [PlayerMorphology.compact, .capsule, .edge].first { morphology in
            let preferred = morphology.geometry.preferredSize
            return preferred.width <= rect.width + 0.5 && preferred.height <= rect.height + 0.5
        }
    }

    private func score(morphology: PlayerMorphology,
                       frame: CGRect,
                       rect: CGRect,
                       currentFrame: CGRect?,
                       preferredOrigin: CGPoint?,
                       current: PlayerMorphology,
                       diagonal: CGFloat,
                       zone: CGRect) -> PlacementCandidate {
        let moved = currentFrame.map { distance(frame, $0) } ?? 0
        let movement = Double(Swift.min(moved / diagonal, 1))
        let stability = 1 - movement
        // 对数刻度：空区面积是播放器的 12 倍和 29 倍，对用户都是"很宽裕"，
        // 但线性比例会让两者几乎一样，无法区分"窄缝"与"大空区"。
        let areaRatio = Double((rect.width * rect.height) / Swift.max(frame.width * frame.height, 1))
        let slack = usesAvailableSpace
            ? min(1, Double(min(rect.width / 640, rect.height / 240)))
            : Swift.min(log2(Swift.max(areaRatio, 1)) / 4, 1)
        let preference: Double
        if let preferredOrigin {
            let drift = hypot(frame.minX - preferredOrigin.x, frame.minY - preferredOrigin.y)
            preference = 1 - Double(Swift.min(drift / diagonal, 1))
        } else {
            preference = 0.5
        }
        // 左上角与当前一致 = 用户看到"同一个东西在伸缩"，给满稳定分。
        let anchorKept = currentFrame.map {
            abs(frame.minX - $0.minX) < 0.5 && abs(frame.maxY - $0.maxY) < 0.5
        } ?? false
        let stabilityWithAnchor = anchorKept ? 1.0 : stability
        // 贴着安全区上下沿 24pt 内算"边条"。
        let edgeBandPenalty = (frame.minY < zone.minY + 24) || (frame.maxY > zone.maxY - 24)
        // 被挤扁要扣分：44pt 高的胶囊虽然合法，但比正常的 420×80 迷你更难看也更难读。
        let preferred = morphology.geometry.preferredSize
        let squeeze = 1 - min(
            min(frame.width / max(preferred.width, 1), frame.height / max(preferred.height, 1)), 1
        )
        let steps = abs(morphology.tightness - current.tightness)
        var morphologyCost = Double(steps) / Double(PlayerMorphology.tightnessOrder.count)
        // 空间本来放得下更宽松的形态，却选了更紧的：额外罚。
        if let supported = supportedMorphology(in: rect, current: current),
           morphology.tightness > supported.tightness {
            let excess = Double(morphology.tightness - supported.tightness)
            morphologyCost += excess * 0.45
        }

        // 用户偏好：优先落在**工作区中间的空隙**，而不是贴着屏幕上下沿的窄条。
        // 窄条虽然"完全无遮挡"，但它离工作内容最远，观感上像被挤到边角。
        let contentUtility = usesAvailableSpace ? utility(morphology: morphology, size: frame.size) : 0
        let total = weights.stability * stabilityWithAnchor
            + weights.slack * slack
            + weights.preference * preference
            + contentUtility
            - weights.morphologyCost * morphologyCost
            - weights.movement * movement
            - weights.squeeze * Double(squeeze)
            - (edgeBandPenalty ? (usesAvailableSpace ? 0.8 : weights.edgeBand) : 0)


        return PlacementCandidate(
            morphology: morphology,
            frame: frame,
            score: total,
            breakdown: .init(stability: stabilityWithAnchor, slack: slack, preference: preference,
                             morphologyCost: morphologyCost, movement: movement),
            clearance: 0
        )
    }

    /// 同一空白区的余量评分不因播放器变小而升高；内容收益单独计分。
    private func utility(morphology: PlayerMorphology, size: CGSize) -> Double {
        switch morphology {
        case .compact:
            let width = min(1, max(0, Double(size.width - 320) / 320))
            let height = min(1, max(0, Double(size.height - 80) / 160))
            return 3.0 + width * 1.2 + height * 2.8
        case .capsule:
            let context = min(1, max(0, Double(size.height - 56) / 144))
            return 1.4 + min(1, Double(size.width) / 640) * 0.8 + context * 2.4
        case .edge: return 0.4 + min(1, Double(size.width) / 900) * 0.4
        default: return 0
        }
    }

    /// 位移按**左上角**算，不按中心距。
    ///
    /// 形态切换时尺寸会变，中心点必然跳（完整形态缩成胶囊，中心能跳 180pt），
    /// 用中心距会把"原地缩小"判成"移动了很多"，于是去选一个更小的矩形把锚点丢掉。
    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.minX - b.minX, a.maxY - b.maxY)
    }

    private func describe(_ candidate: PlacementCandidate,
                          current: PlayerMorphology,
                          currentFrame: CGRect?,
                          diagonal: CGFloat) -> String {
        let moved = currentFrame.map { Int(distance(candidate.frame, $0)) } ?? 0
        if candidate.morphology == current {
            return "保持 \(current.rawValue)，在自由区域内移动 \(moved)pt"
        }
        return "\(current.rawValue) → \(candidate.morphology.rawValue)，移动 \(moved)pt"
    }
}
