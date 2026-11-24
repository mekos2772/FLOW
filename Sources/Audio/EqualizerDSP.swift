import Foundation

/// 5 段均衡器预设。
enum EqualizerPreset: String, CaseIterable, Codable, Sendable {
    case off
    case vocal
    case bassBoost
    case warm
    case bright
    case lateNight
    case custom

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .vocal: return String(localized: "人声增强")
        case .bassBoost: return String(localized: "低音增强")
        case .warm: return String(localized: "温暖柔和")
        case .bright: return String(localized: "清亮通透")
        case .lateNight: return String(localized: "夜间轻声")
        case .custom: return String(localized: "自定义")
        }
    }

    /// 5 个频段（60 Hz / 230 Hz / 910 Hz / 3.6 kHz / 14 kHz）的预设增益（dB）。
    var defaultGainsDB: [Double] {
        switch self {
        case .off: return [0, 0, 0, 0, 0]
        case .vocal: return [-1.5, 0.5, 3.0, 2.5, 0.5]
        case .bassBoost: return [4.5, 2.5, 0.0, -0.5, 0.0]
        case .warm: return [2.0, 1.5, 0.0, -1.5, -2.5]
        case .bright: return [0.0, 0.0, 1.0, 2.5, 4.0]
        case .lateNight: return [-2.0, 1.0, 2.5, 1.5, -1.5]
        case .custom: return [0, 0, 0, 0, 0]
        }
    }
}

/// 5 段基础均衡器的频点与编解码工具。
enum EqualizerSpec {
    enum FilterKind: Sendable {
        case lowShelf
        case peaking
        case highShelf
    }

    struct Band: Identifiable, Sendable {
        let id: Int
        let frequencyHz: Double
        let label: String
        let kind: FilterKind
        let q: Double
    }

    static let bandCount = 5
    static let gainRange: ClosedRange<Double> = -12...12

    static let bands: [Band] = [
        Band(id: 0, frequencyHz: 60, label: "60 Hz", kind: .lowShelf, q: 0.7071),
        Band(id: 1, frequencyHz: 230, label: "230 Hz", kind: .peaking, q: 1.0),
        Band(id: 2, frequencyHz: 910, label: "910 Hz", kind: .peaking, q: 1.0),
        Band(id: 3, frequencyHz: 3600, label: "3.6 kHz", kind: .peaking, q: 1.0),
        Band(id: 4, frequencyHz: 14_000, label: "14 kHz", kind: .highShelf, q: 0.7071),
    ]

    static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    static func parseBands(_ raw: String) -> [Double] {
        let parsed = raw
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map(clampGain)
        guard parsed.count == bandCount else { return Array(repeating: 0, count: bandCount) }
        return parsed
    }

    static func serializeBands(_ gains: [Double]) -> String {
        let normalized = (0..<bandCount).map { index in
            index < gains.count ? clampGain(gains[index]) : 0
        }
        return normalized.map { String(format: "%.1f", $0) }.joined(separator: ",")
    }
}

/// RBJ Cookbook 二阶 IIR 滤波器系数（归一化 a0=1）。
struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoefficients()

    static func make(band: EqualizerSpec.Band, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let clampedGain = EqualizerSpec.clampGain(gainDB)
        guard abs(clampedGain) > 0.01, sampleRate > 100 else { return .identity }

        let sr = max(sampleRate, 8000)
        let freq = min(max(band.frequencyHz, 20), sr * 0.45)
        let w0 = 2.0 * Double.pi * freq / sr
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let gainAmplitude = pow(10.0, clampedGain / 40.0)

        let rawB0, rawB1, rawB2, rawA0, rawA1, rawA2: Double
        switch band.kind {
        case .peaking:
            let alpha = sinW0 / (2.0 * band.q)
            rawB0 = 1.0 + alpha * gainAmplitude
            rawB1 = -2.0 * cosW0
            rawB2 = 1.0 - alpha * gainAmplitude
            rawA0 = 1.0 + alpha / gainAmplitude
            rawA1 = -2.0 * cosW0
            rawA2 = 1.0 - alpha / gainAmplitude
        case .lowShelf:
            let alpha = sinW0 / (2.0 * band.q)
            let twoSqrtAAlpha = 2.0 * sqrt(gainAmplitude) * alpha
            rawB0 = gainAmplitude * ((gainAmplitude + 1.0) - (gainAmplitude - 1.0) * cosW0 + twoSqrtAAlpha)
            rawB1 = 2.0 * gainAmplitude * ((gainAmplitude - 1.0) - (gainAmplitude + 1.0) * cosW0)
            rawB2 = gainAmplitude * ((gainAmplitude + 1.0) - (gainAmplitude - 1.0) * cosW0 - twoSqrtAAlpha)
            rawA0 = (gainAmplitude + 1.0) + (gainAmplitude - 1.0) * cosW0 + twoSqrtAAlpha
            rawA1 = -2.0 * ((gainAmplitude - 1.0) + (gainAmplitude + 1.0) * cosW0)
            rawA2 = (gainAmplitude + 1.0) + (gainAmplitude - 1.0) * cosW0 - twoSqrtAAlpha
        case .highShelf:
            let alpha = sinW0 / (2.0 * band.q)
            let twoSqrtAAlpha = 2.0 * sqrt(gainAmplitude) * alpha
            rawB0 = gainAmplitude * ((gainAmplitude + 1.0) + (gainAmplitude - 1.0) * cosW0 + twoSqrtAAlpha)
            rawB1 = -2.0 * gainAmplitude * ((gainAmplitude - 1.0) + (gainAmplitude + 1.0) * cosW0)
            rawB2 = gainAmplitude * ((gainAmplitude + 1.0) + (gainAmplitude - 1.0) * cosW0 - twoSqrtAAlpha)
            rawA0 = (gainAmplitude + 1.0) - (gainAmplitude - 1.0) * cosW0 + twoSqrtAAlpha
            rawA1 = 2.0 * ((gainAmplitude - 1.0) - (gainAmplitude + 1.0) * cosW0)
            rawA2 = (gainAmplitude + 1.0) - (gainAmplitude - 1.0) * cosW0 - twoSqrtAAlpha
        }

        return BiquadCoefficients(
            b0: rawB0 / rawA0,
            b1: rawB1 / rawA0,
            b2: rawB2 / rawA0,
            a1: rawA1 / rawA0,
            a2: rawA2 / rawA0
        )
    }
}

/// 单声道转置 Direct Form II 状态。低频下保持 Float64 状态避免量化噪声。
struct BiquadChannelState: Sendable {
    var z1: Double = 0
    var z2: Double = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ sample: Double, using c: BiquadCoefficients) -> Double {
        let output = c.b0 * sample + z1
        z1 = c.b1 * sample - c.a1 * output + z2
        z2 = c.b2 * sample - c.a2 * output
        return output
    }
}

/// 响度增益 + 5 段均衡 + 立体声联动动态峰值限幅器。纯值实现，音频线程与单测共用。
struct AudioEffectsProcessor: Sendable {
    /// 动态峰值限幅阈值（约 -1.0 dBFS），低于该值严格线性零染色。
    static let limiterThreshold: Double = 0.89
    /// 限幅器平滑释放时间（秒）：足够长以抑制波形级谐波失真，又足够快以自然恢复动态。
    static let limiterReleaseSeconds: Double = 0.12

    private(set) var sampleRate: Double
    private(set) var channelCount: Int
    private(set) var coefficients: [BiquadCoefficients]
    private(set) var isEQBypassed: Bool
    private(set) var currentGain: Double
    private(set) var targetGain: Double
    private(set) var limiterGain: Double
    private var states: [[BiquadChannelState]] // [channel][band]

    init(sampleRate: Double = 44_100,
         channelCount: Int = 2,
         bandGainsDB: [Double] = Array(repeating: 0, count: EqualizerSpec.bandCount),
         loudnessGain: Double = 1.0) {
        self.sampleRate = max(sampleRate, 8000)
        let channels = max(1, channelCount)
        self.channelCount = channels
        self.coefficients = Array(repeating: .identity, count: EqualizerSpec.bandCount)
        self.isEQBypassed = true
        let clampedGain = min(max(loudnessGain, 0.1), 2.5)
        self.currentGain = clampedGain
        self.targetGain = clampedGain
        self.limiterGain = 1.0
        self.states = Array(
            repeating: Array(repeating: BiquadChannelState(), count: EqualizerSpec.bandCount),
            count: channels
        )
        update(bandGainsDB: bandGainsDB, loudnessGain: clampedGain, snapGain: true)
    }

    mutating func prepare(sampleRate: Double, channelCount: Int, bandGainsDB: [Double], loudnessGain: Double) {
        self.sampleRate = max(sampleRate, 8000)
        self.channelCount = max(1, channelCount)
        self.limiterGain = 1.0
        self.states = Array(
            repeating: Array(repeating: BiquadChannelState(), count: EqualizerSpec.bandCount),
            count: self.channelCount
        )
        update(bandGainsDB: bandGainsDB, loudnessGain: loudnessGain, snapGain: true)
    }

    mutating func update(bandGainsDB: [Double], loudnessGain: Double, snapGain: Bool = false) {
        var bypassed = true
        for index in 0..<EqualizerSpec.bandCount {
            let db = index < bandGainsDB.count ? EqualizerSpec.clampGain(bandGainsDB[index]) : 0
            if abs(db) > 0.01 { bypassed = false }
            coefficients[index] = BiquadCoefficients.make(
                band: EqualizerSpec.bands[index],
                gainDB: db,
                sampleRate: sampleRate
            )
        }
        isEQBypassed = bypassed
        let clamped = min(max(loudnessGain, 0.1), 2.5)
        targetGain = clamped
        if snapGain { currentGain = clamped }
    }

    mutating func resetStates() {
        limiterGain = 1.0
        for c in states.indices {
            for b in states[c].indices {
                states[c][b].reset()
            }
        }
    }

    /// 逐帧更新包络限幅增益：超阈值即时压低避免削波失真，回落时按指数包络平滑释放。
    @inline(__always)
    private mutating func nextLimiterGain(framePeak: Double, releaseStep: Double) -> Double {
        let desired = framePeak > Self.limiterThreshold
            ? (Self.limiterThreshold / framePeak)
            : 1.0
        if desired < limiterGain {
            limiterGain = desired
        } else {
            limiterGain += (desired - limiterGain) * releaseStep
        }
        return limiterGain
    }

    /// 逐帧处理非交错（Planar）声道缓冲（单通道一数组）。
    mutating func processPlanar(_ channels: [UnsafeMutableBufferPointer<Float>], frameCount: Int) {
        guard frameCount > 0 else { return }
        let activeChannels = min(channels.count, states.count)
        let rampStep = 1.0 / max(1.0, sampleRate * 0.05)
        let releaseStep = 1.0 - exp(-1.0 / max(1.0, sampleRate * Self.limiterReleaseSeconds))

        for frame in 0..<frameCount {
            if abs(targetGain - currentGain) > rampStep {
                currentGain += currentGain < targetGain ? rampStep : -rampStep
            } else {
                currentGain = targetGain
            }
            let gain = currentGain
            var framePeak = 0.0
            for channel in 0..<activeChannels {
                let raw = Double(channels[channel][frame])
                var value = (raw.isFinite && abs(raw) < 1e6) ? raw : 0.0
                if !isEQBypassed {
                    for band in 0..<EqualizerSpec.bandCount {
                        value = states[channel][band].process(value, using: coefficients[band])
                    }
                    if !value.isFinite {
                        for band in 0..<EqualizerSpec.bandCount {
                            states[channel][band].reset()
                        }
                        value = 0.0
                    }
                }
                let scaled = value * gain
                let absVal = abs(scaled)
                if absVal > framePeak { framePeak = absVal }
                channels[channel][frame] = Float(scaled)
            }
            let limit = nextLimiterGain(framePeak: framePeak, releaseStep: releaseStep)
            if limit < 0.999999 || framePeak > 0.92 {
                for channel in 0..<activeChannels {
                    let out = Double(channels[channel][frame]) * limit
                    channels[channel][frame] = Float(Self.softLimit(out))
                }
            }
        }
    }

    /// 逐帧处理交错声道缓冲（L, R, L, R...）。
    mutating func processInterleaved(_ buffer: UnsafeMutableBufferPointer<Float>,
                                     frameCount: Int,
                                     stride channelStride: Int) {
        guard frameCount > 0, channelStride > 0 else { return }
        let activeChannels = min(channelStride, states.count)
        let rampStep = 1.0 / max(1.0, sampleRate * 0.05)
        let releaseStep = 1.0 - exp(-1.0 / max(1.0, sampleRate * Self.limiterReleaseSeconds))

        for frame in 0..<frameCount {
            if abs(targetGain - currentGain) > rampStep {
                currentGain += currentGain < targetGain ? rampStep : -rampStep
            } else {
                currentGain = targetGain
            }
            let gain = currentGain
            let base = frame * channelStride
            guard base + activeChannels <= buffer.count else { break }
            var framePeak = 0.0
            for channel in 0..<activeChannels {
                let raw = Double(buffer[base + channel])
                var value = (raw.isFinite && abs(raw) < 1e6) ? raw : 0.0
                if !isEQBypassed {
                    for band in 0..<EqualizerSpec.bandCount {
                        value = states[channel][band].process(value, using: coefficients[band])
                    }
                    if !value.isFinite {
                        for band in 0..<EqualizerSpec.bandCount {
                            states[channel][band].reset()
                        }
                        value = 0.0
                    }
                }
                let scaled = value * gain
                let absVal = abs(scaled)
                if absVal > framePeak { framePeak = absVal }
                buffer[base + channel] = Float(scaled)
            }
            let limit = nextLimiterGain(framePeak: framePeak, releaseStep: releaseStep)
            if limit < 0.999999 || framePeak > 0.92 {
                for channel in 0..<activeChannels {
                    let out = Double(buffer[base + channel]) * limit
                    buffer[base + channel] = Float(Self.softLimit(out))
                }
            }
        }
    }

    /// 软膝限幅：0.92 以下严格线性，超过后渐进压向 ±0.99 防止极端瞬态硬削波；非有限值归零防炸耳。
    @inline(__always)
    static func softLimit(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        let sign = x < 0 ? -1.0 : 1.0
        let absX = abs(x)
        if absX <= 0.92 { return x }
        let excess = absX - 0.92
        let compressed = 0.92 + 0.07 * (excess / (0.07 + excess))
        return sign * min(compressed, 0.99)
    }
}
