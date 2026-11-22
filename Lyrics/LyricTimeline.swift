import Foundation

/// 歌词时间轴。所有界面共用同一个实例，位置由播放时钟驱动，不各自计时。
///
/// 查找用二分：歌词常见几百行，逐行线性扫描在 250ms 刷新下也能跑，
/// 但二分能让"每次刷新都算一遍当前行"这件事的代价与行数无关，行为更可预测。
struct LyricTimeline: Sendable, Equatable {
    let lines: [LyricLine]

    init(lines: [LyricLine]) {
        self.lines = lines.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { lines.isEmpty }

    /// 返回 `time` 时刻应当高亮的行下标：最后一个 `start <= time` 的行。
    func index(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        if time < lines[0].start { return nil }

        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= time {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    func line(at time: TimeInterval) -> LyricLine? {
        guard let index = index(at: time) else { return nil }
        return lines[index]
    }

    func nextLine(after time: TimeInterval) -> LyricLine? {
        guard !lines.isEmpty else { return nil }
        guard let index = index(at: time) else { return lines.first }
        let next = index + 1
        return next < lines.count ? lines[next] : nil
    }

    func previousLine(before time: TimeInterval) -> LyricLine? {
        guard let index = index(at: time), index > 0 else { return nil }
        return lines[index - 1]
    }

    /// 当前行内部进度 0...1，用于逐行淡出/进度条。没有下一行时按 4 秒收尾。
    func progress(at time: TimeInterval) -> Double {
        guard let index = index(at: time) else { return 0 }
        let start = lines[index].start
        let end: TimeInterval
        if let explicitEnd = lines[index].end {
            end = explicitEnd
        } else if index + 1 < lines.count {
            end = lines[index + 1].start
        } else {
            end = start + 4
        }
        guard end > start else { return 1 }
        return min(max((time - start) / (end - start), 0), 1)
    }
}
