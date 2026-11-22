import Foundation

/// "接下来"列表的纯逻辑。
///
/// 抽出来是因为这段顺序规则**很容易写错**，而且错了之后界面看起来完全正常：
/// 最早用的是 `items.filter { $0 != currentID }`——排除了当前曲，却保留了它
/// **前面**已经播过的那些。播到第 5 首时，「接下来」显示的是队列第 1 首。
///
/// 现在不再自己拼顺序，而是**拿队列的副本真的往后走一遍**：
/// 手动插播、随机、列表循环都由队列自己的 `advance()` 决定，
/// 界面上预告的下一首和真正播出来的下一首不可能再对不上。
/// （之前随机播放时这里仍按列表顺序预告，预告的和实际播的是两回事。）
enum UpNextPlanner {
    /// - Parameter limit: 最多预告多少首。nil 表示走到队列自然结束。
    static func upcoming(queue: PlaybackQueue, currentID: Track.ID?, limit: Int? = nil) -> [Track.ID] {
        var probe = queue
        // 单曲循环下 `advance()` 永远返回当前这首；"接下来"仍然展示队列里排着的内容。
        if probe.repeatMode == .one { probe.repeatMode = .off }
        let cap = limit ?? (queue.items.count + queue.nextUp.count + queue.later.count)

        var result: [Track.ID] = []
        var seen = Set<Track.ID>()
        if let currentID { seen.insert(currentID) }
        while result.count < cap, let next = probe.advance() {
            // 列表循环会绕回来：走到见过的曲目就停。
            guard seen.insert(next).inserted else { break }
            result.append(next)
        }
        return result
    }
}
