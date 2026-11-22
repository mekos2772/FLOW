import Foundation

/// 播放模式。
enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off
    case one
    case all

    var next: RepeatMode {
        switch self {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }
}

/// 播放队列。
///
/// 三个列表各司其职：
/// - `items` 是基础队列（播放列表）；
/// - `nextUp` 是"下一首播放"，后进先出——用户连点两次，最后点的那首先播；
/// - `later` 是"稍后播放"，先进先出，排在 nextUp 之后。
///
/// 随机播放用「本周期已播集合」去重：一轮内不会重复同一首，整轮走完才重置。
/// 这样既满足"不无意义地重复"，又保证用户手动切歌后仍然可预期。
struct PlaybackQueue: Codable, Sendable, Equatable {
    private(set) var items: [Track.ID]
    private(set) var currentID: Track.ID?
    /// 手动插播的曲目不在 `items` 里，需要记住"插播前真正播到哪"，
    /// 否则插播结束后无法回到原来的顺序位置。
    private(set) var anchorID: Track.ID?
    private(set) var nextUp: [Track.ID]
    private(set) var later: [Track.ID]
    private(set) var playedInCycle: [Track.ID]

    var repeatMode: RepeatMode
    /// 非 nil 表示随机开启，值作为确定性种子。
    var shuffleSeed: UInt64?

    init(items: [Track.ID] = [],
         currentID: Track.ID? = nil,
         nextUp: [Track.ID] = [],
         later: [Track.ID] = [],
         anchorID: Track.ID? = nil,
         playedInCycle: [Track.ID] = [],
         repeatMode: RepeatMode = .off,
         shuffleSeed: UInt64? = nil) {
        self.items = items
        self.currentID = currentID
        self.anchorID = anchorID ?? currentID.flatMap { items.contains($0) ? $0 : nil }
        self.nextUp = nextUp
        self.later = later
        // 当前曲目视为本轮已播，否则随机模式可能立刻重复播放它。
        if playedInCycle.isEmpty, let currentID, items.contains(currentID) {
            self.playedInCycle = [currentID]
        } else {
            self.playedInCycle = playedInCycle
        }
        self.repeatMode = repeatMode
        self.shuffleSeed = shuffleSeed
    }

    var isEmpty: Bool { items.isEmpty && nextUp.isEmpty && later.isEmpty }
    var isShuffling: Bool { shuffleSeed != nil }

    var currentIndex: Int? { currentID.flatMap { items.firstIndex(of: $0) } }

    // MARK: - 基础操作

    mutating func replace(items newItems: [Track.ID], current: Track.ID?) {
        items = newItems
        currentID = current
        anchorID = current
        playedInCycle = current.map { [$0] } ?? []
        nextUp.removeAll()
        later.removeAll()
    }

    mutating func setCurrent(_ id: Track.ID?) {
        currentID = id
        guard let id else { return }
        if items.contains(id) {
            anchorID = id
            if !playedInCycle.contains(id) { playedInCycle.append(id) }
        }
    }

    /// 下一首播放（后进先出）。
    ///
    /// 同一首只排一次：已经在"下一首"里就提到最前，在"稍后"里就挪过来。
    /// 之前是无条件 `append`——右键连点两次，同一首歌会连播两遍。
    mutating func enqueueNext(_ id: Track.ID) {
        nextUp.removeAll { $0 == id }
        later.removeAll { $0 == id }
        nextUp.append(id)
    }

    /// 稍后播放（先进先出）。已经排着的不重复加。
    mutating func enqueueLater(_ id: Track.ID) {
        guard !nextUp.contains(id), !later.contains(id) else { return }
        later.append(id)
    }

    /// 直接跳到某一首（用户在列表里点了它）。
    ///
    /// **不重建队列**：
    /// - 已经在 `items` 里 → 只移动"当前"，列表顺序、手动排的"下一首/稍后"原样保留；
    /// - 排在"下一首/稍后"里 → 提前轮到它，从缓冲里取走；
    /// - 都不在 → 插到当前顺序位置之后（插播），播完接着原来的顺序往下走。
    ///
    /// 旧实现每次点歌都 `replace(items:)`：用户刚拖好的顺序、刚删掉的条目、
    /// 刚排的"下一首播放"，点一下队列里别的歌就全部还原/清空。
    mutating func jump(to id: Track.ID) {
        nextUp.removeAll { $0 == id }
        later.removeAll { $0 == id }
        if !items.contains(id) {
            let insertion = sequenceIndex().map { $0 + 1 } ?? items.count
            items.insert(id, at: min(insertion, items.count))
        }
        setCurrent(id)
    }

    /// 整体恢复（冷启动）：把上次保存的队列原样装回来。
    ///
    /// 与 `replace` 的区别是它**保留**"下一首/稍后"与随机进度——
    /// 那些也是用户排好的东西，重启不该丢。
    static func restored(from saved: PlaybackQueue, keeping known: Set<Track.ID>) -> PlaybackQueue {
        var queue = saved
        queue.items = saved.items.filter(known.contains)
        queue.nextUp = saved.nextUp.filter(known.contains)
        queue.later = saved.later.filter(known.contains)
        queue.playedInCycle = saved.playedInCycle.filter(known.contains)
        if let current = saved.currentID, !known.contains(current) { queue.currentID = nil }
        if let anchor = saved.anchorID, !queue.items.contains(anchor) { queue.anchorID = nil }
        return queue
    }

    func remappingIDs(_ ids: [Track.ID: Track.ID]) -> PlaybackQueue {
        func unique(_ input: [Track.ID]) -> [Track.ID] {
            var seen: Set<Track.ID> = []
            return input.compactMap { ids[$0] }.filter { seen.insert($0).inserted }
        }
        return PlaybackQueue(items: unique(items), currentID: currentID.flatMap { ids[$0] },
                             nextUp: unique(nextUp), later: unique(later),
                             anchorID: anchorID.flatMap { ids[$0] }, playedInCycle: unique(playedInCycle),
                             repeatMode: repeatMode, shuffleSeed: shuffleSeed)
    }

    mutating func clearLater() {
        later.removeAll()
    }

    /// 把一首从"下一首/稍后"里撤掉。返回是否真的撤了。
    @discardableResult
    mutating func removePending(_ id: Track.ID) -> Bool {
        let before = nextUp.count + later.count
        nextUp.removeAll { $0 == id }
        later.removeAll { $0 == id }
        return nextUp.count + later.count != before
    }

    /// 清空"接下来的"：当前曲目之后的所有排队条目。
    ///
    /// 之前的「清空待播」只清 `later` 缓冲，而屏幕上看到的那一列在 `items` 里，
    /// 点了没反应。用户按下这个按钮的意图是"我不想听后面这些了"，
    /// 所以这里截断 `items`、并把手动插入的两个缓冲一起清掉。
    /// 当前曲目**保留**——清的是"待播"，不是"正在播"。
    /// 返回是否真的动了队列，调用方据此决定要不要提示。
    @discardableResult
    mutating func clearUpNext() -> Bool {
        var changed = !nextUp.isEmpty || !later.isEmpty
        nextUp.removeAll()
        later.removeAll()
        guard !items.isEmpty, let index = sequenceIndex() else { return changed }
        if index + 1 < items.count {
            items.removeSubrange((index + 1)..<items.count)
            changed = true
        }
        return changed
    }

    /// 拖拽排序：把 `source` 位置的行移动到 `destination`。
    mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), items.count - 1)
        guard clamped != source else { return }
        let id = items.remove(at: source)
        items.insert(id, at: clamped)
    }

    mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removed = items.remove(at: index)
        if removed == currentID { currentID = nil }
        if removed == anchorID { anchorID = nil }
    }

    // MARK: - 推进

    /// 下一首。返回 nil 表示队列走完且不循环。
    mutating func advance() -> Track.ID? {
        // 单曲循环仅影响自然结束；用户主动切歌与手动待播仍然推进。
        if let manual = nextUp.popLast() {
            return promoteManual(manual)
        }
        if !later.isEmpty {
            return promoteManual(later.removeFirst())
        }

        guard !items.isEmpty else { return nil }

        if isShuffling {
            return advanceShuffled()
        }

        guard let index = sequenceIndex() else {
            setCurrent(items.first)
            return items.first
        }
        let nextIndex = index + 1
        if nextIndex < items.count {
            setCurrent(items[nextIndex])
            return items[nextIndex]
        }
        guard repeatMode == .all else { return nil }
        setCurrent(items.first)
        return items.first
    }

    /// 手动排的那一首轮到了：把它并进 `items`，放在当前顺序位置之后。
    ///
    /// 为什么要并进去：手动排的曲目常常**本来就在列表里**（在榜单里右键
    /// "下一首播放"第 20 首）。旧实现只改 `currentID`，而顺序基准取的是
    /// 它在 `items` 里的位置——于是播完第 20 首直接接第 21 首，
    /// 中间第 2–19 首全部被跳过。并进来（等于"挪到下一首"）之后，
    /// 播完它接的仍是原来该播的那一首，列表里也看得见它。
    private mutating func promoteManual(_ id: Track.ID) -> Track.ID {
        guard id != currentID else {
            setCurrent(id)
            return id
        }
        var insertion = sequenceIndex().map { $0 + 1 } ?? items.count
        if let existing = items.firstIndex(of: id) {
            items.remove(at: existing)
            if existing < insertion { insertion -= 1 }
        }
        items.insert(id, at: min(max(insertion, 0), items.count))
        setCurrent(id)
        return id
    }

    /// 播完当前这首之后还有没有东西可播（不改动队列）。
    ///
    /// 电台靠它判断"队列真的走完了"——只有那时才轮得到它接歌。
    var hasNext: Bool {
        var probe = self
        return probe.advance() != nil
    }

    /// 下一首会是谁（不改动队列）。预加载用。
    var peekNext: Track.ID? {
        var probe = self
        return probe.advance()
    }

    /// 队首是否还有"上一首"可退。
    ///
    /// 供播放内核在**真正调用 `regress()` 之前**判断边界：
    /// `regress()` 是 mutating 的，探路会推进队列；而边界处该做的是重播本曲，
    /// 不是把当前曲目丢掉。
    var hasPrevious: Bool {
        guard !items.isEmpty else { return false }
        if isShuffling { return playedInCycle.count >= 2 }
        guard let index = sequenceIndex() else { return false }
        return index > 0 || repeatMode == .all
    }

    /// 上一首。随机模式下按本周期播放历史回退。
    mutating func regress() -> Track.ID? {
        guard !items.isEmpty else { return nil }

        if isShuffling {
            guard playedInCycle.count >= 2 else { return nil }
            let previousID = playedInCycle[playedInCycle.count - 2]
            playedInCycle.removeLast()
            currentID = previousID
            return previousID
        }

        guard let index = sequenceIndex() else { return nil }
        if index > 0 {
            let previous = items[index - 1]
            setCurrent(previous)
            return previous
        }
        guard repeatMode == .all else { return nil }
        let last = items[items.count - 1]
        setCurrent(last)
        return last
    }

    /// 顺序推进的基准位置：优先当前曲目，其次手动插播前的锚点。
    private func sequenceIndex() -> Int? {
        if let currentID, let index = items.firstIndex(of: currentID) { return index }
        if let anchorID, let index = items.firstIndex(of: anchorID) { return index }
        return nil
    }

    private mutating func advanceShuffled() -> Track.ID? {
        let remaining = items.filter { !playedInCycle.contains($0) }
        if remaining.isEmpty {
            guard repeatMode == .all else { return nil }
            playedInCycle = []
            let first = items[Int(shuffleIndex(seed: shuffleSeed ?? 0, bound: UInt64(items.count)))]
            setCurrent(first)
            return first
        }
        let pick = Int(shuffleIndex(seed: shuffleSeed ?? 0, bound: UInt64(remaining.count)))
        let chosen = remaining[pick]
        setCurrent(chosen)
        return chosen
    }

    /// 确定性伪随机：同一 seed + 同一剩余集合必得同一结果，重启后行为可复现。
    private func shuffleIndex(seed: UInt64, bound: UInt64) -> UInt64 {
        guard bound > 0 else { return 0 }
        var value = seed &* 6364136223846793005 &+ UInt64(playedInCycle.count) &* 1442695040888963407
        value ^= value >> 33
        value = value &* 0xff51afd7ed558ccd
        value ^= value >> 33
        return value % bound
    }
}
