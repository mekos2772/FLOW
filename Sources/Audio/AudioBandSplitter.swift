import Foundation

/// 三段分频电平分析器：把一块 PCM 混成单声道后，分别过低通 / 带通 / 高通，再各求 RMS。
///
/// 给沉浸模式的背景做"跟着音乐动"用，所以只追求便宜和稳定，不追求频谱精度：
/// - 低频：二阶低通 ~150 Hz（底鼓、贝斯）；
/// - 中频：带通，中心 ~1 kHz、Q ≈ 0.7（覆盖人声、和声的大致范围）；
/// - 高频：二阶高通 ~4 kHz（镲片、齿音、空气感）。
///
/// 纯值类型、状态全部内联（无数组），`analyze*` 里不分配内存，可以直接跑在实时音频线程上。
/// 系数与滤波状态复用 EQ 的 `BiquadCoefficients` / `BiquadChannelState`（RBJ Cookbook，Float64 状态）。
struct AudioBandSplitter: Sendable {
    static let lowCutoffHz: Double = 150
    static let midCenterHz: Double = 1_000
    static let midQ: Double = 0.7
    static let highCutoffHz: Double = 4_000
    private static let butterworthQ: Double = 0.7071

    /// 起音分析的格长：约 11.6ms（44.1 kHz 下 512 个采样）。抽头一次回调约 85ms，
    /// 只发一份电平跟不上拍子，节拍跟踪要这种细格子。
    static let onsetHopSeconds: Double = 512.0 / 44_100

    private(set) var sampleRate: Double
    private var lowCoefficients = BiquadCoefficients.identity
    private var midCoefficients = BiquadCoefficients.identity
    private var highCoefficients = BiquadCoefficients.identity
    private var lowState = BiquadChannelState()
    private var midState = BiquadChannelState()
    private var highState = BiquadChannelState()

    /// 起音格子的累加状态。一格可能跨两次回调，所以放在这里而不是局部变量。
    private(set) var hopFrames = 512
    private var hopLow = 0.0
    private var hopMid = 0.0
    private var hopHigh = 0.0
    private var hopCount = 0
    private var hopStart = Double.nan
    /// 下一块缓冲"应该"从歌曲的哪一秒开始（按采样数推算）；和报来的起点差太多说明拖动过进度，半格作废。
    private var expectedNext = Double.nan
    /// 报来的起点和推算值差多少算"跳了"：比取整误差（约 12ms）大得多，比一次最短的拖动小得多。
    static let discontinuitySeconds = 0.1

    /// 未调用 `prepare` 时按 44.1 kHz 工作。
    init(sampleRate: Double = 44_100) {
        self.sampleRate = Self.normalizedSampleRate(sampleRate)
        rebuildCoefficients()
    }

    mutating func prepare(sampleRate: Double) {
        self.sampleRate = Self.normalizedSampleRate(sampleRate)
        rebuildCoefficients()
        reset()
    }

    mutating func reset() {
        lowState.reset()
        midState.reset()
        highState.reset()
        resetHop()
        expectedNext = .nan
    }

    private mutating func resetHop() {
        hopLow = 0
        hopMid = 0
        hopHigh = 0
        hopCount = 0
        hopStart = .nan
    }

    /// 交错 float32（L, R, L, R...）：`samples` 覆盖 `frameCount * stride` 个值；各声道先平均成单声道再滤波。
    mutating func analyzeInterleaved(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, stride: Int) -> AudioBandLevels {
        guard frameCount > 0, stride > 0 else { return .silent }
        // 缓冲比声明的短时只分析完整的帧，绝不越界读。
        let frames = min(frameCount, samples.count / stride)
        let scale = 1.0 / Double(stride)
        return analyze(frameCount: frames) { frame in
            let base = frame * stride
            var sum = 0.0
            for channel in 0..<stride {
                sum += Double(samples[base + channel])
            }
            return sum * scale
        }
    }

    /// 非交错（Planar）float32：每个声道一块缓冲；同样先平均成单声道。
    mutating func analyzePlanar(_ channels: [UnsafeBufferPointer<Float>], frameCount: Int) -> AudioBandLevels {
        analyzePlanarChannels(channels, frameCount: frameCount)
    }

    /// 与上面相同，直接吃抽头里现成的可写指针数组——省得在音频线程上为"只读视图"再分配一个数组。
    mutating func analyzePlanar(_ channels: [UnsafeMutableBufferPointer<Float>], frameCount: Int) -> AudioBandLevels {
        analyzePlanarChannels(channels, frameCount: frameCount)
    }

    /// 同时切出起音格子：`mediaTime` 是这块缓冲开头在歌曲里的秒数（没有就不出格子）。
    /// 格子写进调用方预先分配好的 `onsets`，`onsetCount` 返回写了几格；写满就丢弃多出来的。
    mutating func analyzeInterleaved(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, stride: Int,
                                     mediaTime: Double?, onsets: UnsafeMutableBufferPointer<AudioOnsetFrame>,
                                     onsetCount: inout Int) -> AudioBandLevels {
        guard frameCount > 0, stride > 0 else { return .silent }
        let frames = min(frameCount, samples.count / stride)
        let scale = 1.0 / Double(stride)
        return analyze(frameCount: frames, mediaTime: mediaTime, onsets: onsets, onsetCount: &onsetCount) { frame in
            let base = frame * stride
            var sum = 0.0
            for channel in 0..<stride {
                sum += Double(samples[base + channel])
            }
            return sum * scale
        }
    }

    mutating func analyzePlanar(_ channels: [UnsafeMutableBufferPointer<Float>], frameCount: Int,
                                mediaTime: Double?, onsets: UnsafeMutableBufferPointer<AudioOnsetFrame>,
                                onsetCount: inout Int) -> AudioBandLevels {
        analyzePlanarChannels(channels, frameCount: frameCount, mediaTime: mediaTime, onsets: onsets,
                              onsetCount: &onsetCount)
    }

    // MARK: - 内部实现

    private mutating func analyzePlanarChannels<Channel: RandomAccessCollection>(
        _ channels: [Channel],
        frameCount: Int
    ) -> AudioBandLevels where Channel.Element == Float, Channel.Index == Int {
        var unused = 0
        return analyzePlanarChannels(channels, frameCount: frameCount, mediaTime: nil, onsets: nil,
                                     onsetCount: &unused)
    }

    private mutating func analyzePlanarChannels<Channel: RandomAccessCollection>(
        _ channels: [Channel],
        frameCount: Int,
        mediaTime: Double?,
        onsets: UnsafeMutableBufferPointer<AudioOnsetFrame>?,
        onsetCount: inout Int
    ) -> AudioBandLevels where Channel.Element == Float, Channel.Index == Int {
        guard frameCount > 0, !channels.isEmpty else { return .silent }
        var frames = frameCount
        for channel in channels {
            frames = min(frames, channel.count)
        }
        let scale = 1.0 / Double(channels.count)
        return analyze(frameCount: frames, mediaTime: mediaTime, onsets: onsets, onsetCount: &onsetCount) { frame in
            var sum = 0.0
            for channel in channels {
                sum += Double(channel[channel.startIndex + frame])
            }
            return sum * scale
        }
    }

    @inline(__always)
    private mutating func analyze(frameCount frames: Int, monoSample: (Int) -> Double) -> AudioBandLevels {
        var unused = 0
        return analyze(frameCount: frames, mediaTime: nil, onsets: nil, onsetCount: &unused, monoSample: monoSample)
    }

    /// 逐帧取单声道样本 → 三路滤波 → 各自累加平方和 → RMS；给了歌曲时间就顺带切起音格子。
    ///
    /// 任何一路出现 NaN / inf（输入里混进了坏样本，或滤波器被打爆）时：
    /// 本块返回全 0，并清空滤波状态，保证下一块从干净状态重新开始，不会被"毒化"。
    @inline(__always)
    private mutating func analyze(frameCount frames: Int,
                                  mediaTime: Double?,
                                  onsets: UnsafeMutableBufferPointer<AudioOnsetFrame>?,
                                  onsetCount: inout Int,
                                  monoSample: (Int) -> Double) -> AudioBandLevels {
        onsetCount = 0
        guard frames > 0 else { return .silent }
        let slicing = onsets != nil && (mediaTime?.isFinite ?? false)
        var start = mediaTime ?? 0
        if slicing {
            // 抽头报的起点是按编码包取整的（实测每块 960 帧，起点以约 11.6ms 为步长跳动），
            // 不能拿它逐块对齐，否则格子时长忽长忽短、还会倒退。连续播放时按采样数往后数；
            // 只有跳了一大截（拖动进度、换歌）才以报来的起点重新起格、半格作废。
            if !expectedNext.isFinite || abs(start - expectedNext) > Self.discontinuitySeconds {
                resetHop()
            } else {
                start = expectedNext
            }
            if hopCount == 0 { hopStart = start }
            expectedNext = start + Double(frames) / sampleRate
        }
        var lowSum = 0.0
        var midSum = 0.0
        var highSum = 0.0
        var fullSum = 0.0
        for frame in 0..<frames {
            let x = monoSample(frame)
            let low = lowState.process(x, using: lowCoefficients)
            let mid = midState.process(x, using: midCoefficients)
            let high = highState.process(x, using: highCoefficients)
            lowSum += low * low
            midSum += mid * mid
            highSum += high * high
            fullSum += x * x
            guard slicing, let onsets else { continue }
            hopLow += low * low
            hopMid += mid * mid
            hopHigh += high * high
            hopCount += 1
            if hopCount == hopFrames {
                if onsetCount < onsets.count, hopLow.isFinite, hopMid.isFinite, hopHigh.isFinite {
                    let n = Double(hopFrames)
                    onsets[onsetCount] = AudioOnsetFrame(mediaTime: hopStart, duration: n / sampleRate,
                                                         low: Float(hopLow / n), mid: Float(hopMid / n),
                                                         high: Float(hopHigh / n))
                    onsetCount += 1
                }
                resetHop()
                hopStart = start + Double(frame + 1) / sampleRate
            }
        }
        guard lowSum.isFinite, midSum.isFinite, highSum.isFinite, fullSum.isFinite, isStateFinite else {
            reset()
            onsetCount = 0
            return .silent
        }
        let n = Double(frames)
        return AudioBandLevels(
            low: Float(sqrt(lowSum / n)),
            mid: Float(sqrt(midSum / n)),
            high: Float(sqrt(highSum / n)),
            full: Float(sqrt(fullSum / n))
        )
    }

    private var isStateFinite: Bool {
        lowState.z1.isFinite && lowState.z2.isFinite
            && midState.z1.isFinite && midState.z2.isFinite
            && highState.z1.isFinite && highState.z2.isFinite
    }

    private mutating func rebuildCoefficients() {
        lowCoefficients = Self.lowPass(cutoffHz: Self.lowCutoffHz, q: Self.butterworthQ, sampleRate: sampleRate)
        midCoefficients = Self.bandPass(centerHz: Self.midCenterHz, q: Self.midQ, sampleRate: sampleRate)
        highCoefficients = Self.highPass(cutoffHz: Self.highCutoffHz, q: Self.butterworthQ, sampleRate: sampleRate)
        hopFrames = max(64, Int((sampleRate * Self.onsetHopSeconds).rounded()))
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 44_100 }
        return max(value, 8000)
    }

    // RBJ Cookbook：低通 / 高通 / 带通（恒定 0 dB 峰值增益）。

    private static func lowPass(cutoffHz: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (cosW0, sinW0) = trig(cutoffHz, sampleRate: sampleRate)
        let alpha = sinW0 / (2.0 * q)
        return normalized(
            b0: (1.0 - cosW0) / 2.0, b1: 1.0 - cosW0, b2: (1.0 - cosW0) / 2.0,
            a0: 1.0 + alpha, a1: -2.0 * cosW0, a2: 1.0 - alpha
        )
    }

    private static func highPass(cutoffHz: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (cosW0, sinW0) = trig(cutoffHz, sampleRate: sampleRate)
        let alpha = sinW0 / (2.0 * q)
        return normalized(
            b0: (1.0 + cosW0) / 2.0, b1: -(1.0 + cosW0), b2: (1.0 + cosW0) / 2.0,
            a0: 1.0 + alpha, a1: -2.0 * cosW0, a2: 1.0 - alpha
        )
    }

    private static func bandPass(centerHz: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let (cosW0, sinW0) = trig(centerHz, sampleRate: sampleRate)
        let alpha = sinW0 / (2.0 * q)
        return normalized(
            b0: alpha, b1: 0, b2: -alpha,
            a0: 1.0 + alpha, a1: -2.0 * cosW0, a2: 1.0 - alpha
        )
    }

    /// 频点不能贴近奈奎斯特（8 kHz 采样时 4 kHz 高通会退化），与 EQ 一样钳到 0.45·Fs 以内。
    private static func trig(_ frequencyHz: Double, sampleRate: Double) -> (cos: Double, sin: Double) {
        let freq = min(max(frequencyHz, 20), sampleRate * 0.45)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        return (cos(w0), sin(w0))
    }

    private static func normalized(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
