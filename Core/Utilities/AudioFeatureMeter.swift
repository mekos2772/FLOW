import Foundation
import os

/// 一帧音频的分频段电平（线性 RMS，0…约 1）。
struct AudioBandLevels: Equatable, Sendable {
    var low: Float    // ~20–150 Hz（底鼓、贝斯）
    var mid: Float    // ~300 Hz–2.5 kHz（人声、和声）
    var high: Float   // ~4 kHz 以上（镲片、齿音、空气感）
    var full: Float   // 全频
    static let silent = AudioBandLevels(low: 0, mid: 0, high: 0, full: 0)
}

/// 起音分析的一格：约 11ms 的三段均方能量，带它在歌曲里的时间。
///
/// 抽头每次回调约 85ms，只发一份电平跟不上拍子；节拍跟踪要的是这种细格子。
/// `mediaTime` 是这格开头在歌曲里的秒数（来自抽头的 `timeRangeOut`），
/// 所以节拍网格钉在歌曲时间上，拖动进度、输出延迟都不影响对齐。
struct AudioOnsetFrame: Equatable, Sendable {
    var mediaTime: Double
    /// 这一格的时长（秒），通常 0.010–0.012。
    var duration: Double
    var low: Float
    var mid: Float
    var high: Float
}

/// 实时音频特征的"信箱"：音频线程写入最新一帧的分频段电平，界面按自己的帧率去取。
///
/// 为什么不用 AsyncStream / Combine 推送：写入方是 `MTAudioProcessingTap` 的实时线程，
/// 那里不能分配内存、不能碰 Swift 并发调度；而读取方（沉浸模式背景）只关心"最新一帧"，
/// 漏掉中间几帧毫无影响。所以这里只存一份快照 + 序号，读写都只是一次短暂的不公平锁。
///
/// 播放暂停时抽头不再回调，快照会停在最后一帧——读取方应按 `timestamp` 判断陈旧并自行衰减。
final class AudioFeatureMeter: @unchecked Sendable {
    static let shared = AudioFeatureMeter()

    struct Reading: Equatable, Sendable {
        var levels: AudioBandLevels
        var timestamp: ContinuousClock.Instant?   // nil = 从未收到
        var sequence: UInt64                       // 每次 publish +1
    }

    private static let emptyReading = Reading(levels: .silent, timestamp: nil, sequence: 0)

    /// 起音格子的环形缓冲：约 23 秒。读取方按序号增量取，落后超过一圈就只拿到最近一圈。
    static let onsetCapacity = 2048

    private struct OnsetRing: Sendable {
        var frames = [AudioOnsetFrame](repeating: AudioOnsetFrame(mediaTime: 0, duration: 0, low: 0, mid: 0, high: 0),
                                       count: AudioFeatureMeter.onsetCapacity)
        /// 累计写入的格数，也是最新一格的序号。
        var written: UInt64 = 0
    }

    // 开关与快照分两把锁：音频线程每个回调都要读一次开关，不该和界面读快照互相等待。
    // 开关是个计数：沉浸页和播放页的场景背景可能前后脚出现、消失，谁最后离开谁才关。
    private let enabled = OSAllocatedUnfairLock(initialState: 0)
    private let reading = OSAllocatedUnfairLock(initialState: AudioFeatureMeter.emptyReading)
    private let onsetRing = OSAllocatedUnfairLock(initialState: OnsetRing())

    init() {}

    /// 只有打开沉浸模式时才需要分析；关闭时音频线程直接跳过，零开销。
    ///
    /// 关闭**不会**清空快照；需要从零开始时显式调用 `reset()`。
    var isEnabled: Bool {
        get { enabled.withLock { $0 > 0 } }
        set { enabled.withLock { $0 = newValue ? max($0, 1) : 0 } }
    }

    /// 一个需要电平的画面出现了（沉浸页、播放页的场景背景）。与 `release()` 成对调用。
    func acquire() {
        enabled.withLock { $0 += 1 }
    }

    func release() {
        enabled.withLock { $0 = max($0 - 1, 0) }
    }

    /// 由实时音频线程调用：不分配内存、不进 Swift 并发，只拿一次不公平锁。
    func publish(_ levels: AudioBandLevels, at instant: ContinuousClock.Instant = .now) {
        let sanitized = AudioBandLevels(
            low: Self.sanitize(levels.low),
            mid: Self.sanitize(levels.mid),
            high: Self.sanitize(levels.high),
            full: Self.sanitize(levels.full)
        )
        reading.withLock { r in
            r.levels = sanitized
            r.timestamp = instant
            r.sequence &+= 1
        }
    }

    func latest() -> Reading {
        reading.withLock { $0 }
    }

    /// 由实时音频线程调用：把这次回调切出的起音格子追加进环形缓冲（原地写，不分配）。
    func publishOnsets(_ frames: UnsafeBufferPointer<AudioOnsetFrame>) {
        guard !frames.isEmpty else { return }
        // 锁内闭包要求 Sendable；这块缓冲只在本次调用期间读，不会逃逸。
        nonisolated(unsafe) let source = frames
        onsetRing.withLock { ring in
            for frame in source {
                let slot = Int(ring.written % UInt64(Self.onsetCapacity))
                ring.frames[slot] = AudioOnsetFrame(mediaTime: frame.mediaTime, duration: frame.duration,
                                                    low: Self.sanitize(frame.low), mid: Self.sanitize(frame.mid),
                                                    high: Self.sanitize(frame.high))
                ring.written &+= 1
            }
        }
    }

    /// 取序号 `sequence` 之后写入的格子，追加到 `output`，返回最新序号（下次再传回来）。
    func onsets(after sequence: UInt64, into output: inout [AudioOnsetFrame]) -> UInt64 {
        onsetRing.withLockUnchecked { ring in
            let capacity = UInt64(Self.onsetCapacity)
            let oldest = ring.written > capacity ? ring.written - capacity : 0
            // 序号比最新的还大，说明中间 reset 过，从头取。
            var index = sequence > ring.written ? oldest : max(sequence, oldest)
            while index < ring.written {
                output.append(ring.frames[Int(index % capacity)])
                index += 1
            }
            return ring.written
        }
    }

    func reset() {
        reading.withLock { $0 = Self.emptyReading }
        onsetRing.withLock { $0.written = 0 }
    }

    /// 非有限值 / 负数一律压成 0：下游拿电平直接驱动动画，NaN 会让整帧渲染失效。
    @inline(__always)
    private static func sanitize(_ value: Float) -> Float {
        value.isFinite && value > 0 ? value : 0
    }
}
