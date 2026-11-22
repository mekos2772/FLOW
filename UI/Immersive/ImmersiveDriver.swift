import Foundation
import simd

/// 把"音频电平 + 播放状态 + 鼠标位置"变成着色器参数。
///
/// 纯值类型、没有时钟依赖：渲染器每帧喂一次 `Input`，单测直接喂合成的时间序列。
///
/// 设计约束（来自参考作品与 docs/IMMERSIVE_MODE.md）：
/// - **自适应归一化**：每个频段各自跟踪峰值与底噪，安静的歌和响的歌都落在同一个 0…1 区间，
///   画面不会因为母带响度不同而一首死气沉沉、一首手舞足蹈；
/// - **小信号几乎不响应**：归一化后再过一条幂曲线，底噪与混响尾巴不会让画面一直抖；
/// - **快起慢落**：低频包络 50ms 起、280ms 落，起音脉冲至少间隔 250ms，最多一秒四次；
/// - **两个时钟都单调递增**：`flow` 随能量变快变慢，但从不倒退或跳变——
///   直接把能量乘到时间上会让画面在每个鼓点处"抽一下"，这是廉价感的主要来源。
struct ImmersiveDriver {
    struct Input {
        var dt: Double
        /// 这一帧拿到的新电平；`nil` 表示没有新数据（沿用上一次，超过 0.4 秒视为静音）。
        var levels: AudioBandLevels?
        var isPlaying: Bool
        /// 来自 `ImmersiveResponse.gain`：0 不跟随，0.5 轻柔，1 标准。
        var response: Float
        var reduceMotion: Bool
        /// 鼠标在窗口里的位置（-1…1，y 朝上）；`nil` 表示鼠标不在窗口里。
        var pointer: SIMD2<Float>?
    }

    struct Output: Equatable {
        var time: Float
        var flow: Float
        var energy: Float
        var bass: Float
        var mid: Float
        var high: Float
        var pulse: Float
        var lift: Float
        var parallax: SIMD2<Float>
        var motion: Float
    }

    /// 单个频段的自适应归一化：峰值快升慢降（约 6 秒），底噪慢升快降。
    struct BandNormalizer {
        private(set) var peak: Float = 0.02
        private(set) var floor: Float = 0
        private var primed = false

        mutating func normalize(_ value: Float, dt: Double) -> Float {
            let x = value.isFinite ? max(value, 0) : 0
            if !primed {
                floor = x * 0.5
                peak = max(x, 0.02)
                primed = true
            }
            if x > peak {
                peak = x
            } else {
                peak += (x - peak) * Float(1 - exp(-dt / 6.0))
            }
            if x < floor {
                floor += (x - floor) * Float(1 - exp(-dt / 0.6))
            } else {
                floor += (x - floor) * Float(1 - exp(-dt / 9.0))
            }
            peak = max(peak, floor + 0.004, 0.006)
            let n = (x - floor) / (peak - floor)
            return pow(min(max(n, 0), 1), 1.4)
        }
    }

    private(set) var time: Double = 0
    private(set) var flow: Double = 0

    private var lowNorm = BandNormalizer()
    private var midNorm = BandNormalizer()
    private var highNorm = BandNormalizer()
    private var fullNorm = BandNormalizer()

    private var heldLevels: AudioBandLevels = .silent
    private var levelAge: Double = .infinity

    private var bass: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var energy: Float = 0
    private var pulse: Float = 0
    private var liftShort: Float = 0
    private var liftLong: Float = 0
    private var lift: Float = 0.5

    private var lowFast: Float = 0
    private var fluxMean: Float = 0
    private var lastOnset: Double = -10
    private(set) var onsetCount = 0

    private var pointer = SIMD2<Float>(0, 0)

    mutating func step(_ input: Input) -> Output {
        let dt = min(max(input.dt, 0), 0.25)
        let motionScale: Double = input.reduceMotion ? 0.3 : 1
        time += dt * (input.isPlaying ? 1 : 0.4) * motionScale

        if let levels = input.levels {
            heldLevels = levels
            levelAge = 0
        } else {
            levelAge += dt
        }
        let live = input.isPlaying && levelAge < 0.4
        let levels = live ? heldLevels : .silent

        let nLow = lowNorm.normalize(levels.low, dt: dt)
        let nMid = midNorm.normalize(levels.mid, dt: dt)
        let nHigh = highNorm.normalize(levels.high, dt: dt)
        let nFull = fullNorm.normalize(levels.full, dt: dt)

        bass = Self.follow(bass, to: nLow, dt: dt, attack: 0.05, release: 0.28)
        mid = Self.follow(mid, to: nMid, dt: dt, attack: 0.08, release: 0.40)
        high = Self.follow(high, to: nHigh, dt: dt, attack: 0.04, release: 0.22)
        energy = Self.follow(energy, to: nFull, dt: dt, attack: 0.8, release: 1.6)

        // 段落起伏：几秒的短期能量相对半分钟的长期能量，副歌高、主歌低；本身再平滑一次。
        liftShort = Self.follow(liftShort, to: nFull, dt: dt, attack: 3.5, release: 3.5)
        liftLong = Self.follow(liftLong, to: nFull, dt: dt, attack: 30, release: 30)
        let liftTarget = live ? min(max(0.5 + (liftShort - liftLong) * 2.2, 0), 1) : 0.5
        lift = Self.follow(lift, to: liftTarget, dt: dt, attack: 2.5, release: 2.5)

        // 起音：低频的正向突变超过自适应阈值，且距上次至少 250ms。
        let flux = max(0, nLow - lowFast)
        lowFast = Self.follow(lowFast, to: nLow, dt: dt, attack: 0.12, release: 0.12)
        fluxMean = Self.follow(fluxMean, to: flux, dt: dt, attack: 1.0, release: 1.0)
        let threshold = max(0.12, fluxMean * 2.2 + 0.05)
        if live, flux > threshold, time - lastOnset > 0.25 {
            pulse = 1
            lastOnset = time
            onsetCount += 1
        } else {
            pulse *= Float(exp(-dt / 0.42))
        }

        let gain = min(max(input.response, 0), 1)
        let energyOut = 0.35 + (energy - 0.35) * gain
        let liftOut = 0.5 + (lift - 0.5) * gain

        // 流动时钟：能量只改变速度，积分后单调递增；暂停时慢下来但不停。
        let rate = (0.55 + 0.75 * Double(energyOut)) * (input.isPlaying ? 1 : 0.3) * (input.reduceMotion ? 0.2 : 1)
        flow += dt * rate

        // 视差：五十多秒一圈的缓慢漂移 + 鼠标（平滑 1.2 秒）。减少动态效果时完全关闭。
        var parallax = SIMD2<Float>(0, 0)
        if !input.reduceMotion {
            let target = input.pointer ?? .zero
            let k = Float(1 - exp(-dt / 1.2))
            pointer += (target - pointer) * k
            let tt = Float(time)
            let drift = SIMD2<Float>(sin(tt * 2 * .pi / 53) * 0.45, sin(tt * 2 * .pi / 71 + 1) * 0.30)
            parallax = simd_clamp(drift + pointer * 0.6, SIMD2(repeating: -1), SIMD2(repeating: 1))
        }

        return Output(time: Float(time.truncatingRemainder(dividingBy: 86_400)),
                      flow: Float(flow.truncatingRemainder(dividingBy: 86_400)),
                      energy: energyOut,
                      bass: bass * gain,
                      mid: mid * gain,
                      high: high * gain,
                      pulse: pulse * gain,
                      lift: liftOut,
                      parallax: parallax,
                      motion: input.reduceMotion ? 0.15 : 1)
    }

    /// 一阶指数跟随：上升用 `attack`、下降用 `release`（秒）。
    static func follow(_ current: Float, to target: Float, dt: Double, attack: Double, release: Double) -> Float {
        let tau = target > current ? attack : release
        let k = Float(1 - exp(-dt / max(tau, 1e-4)))
        return current + (target - current) * k
    }
}

/// 换歌时调色板的平滑过渡：2.4 秒、两端都缓的曲线。明暗结构变化越大越需要慢，
/// 参考作品里最舒服的过渡都在 1–3 秒之间。
struct ImmersivePaletteBlend {
    private(set) var from: ImmersivePalette
    private(set) var to: ImmersivePalette
    private var progress: Double = 1
    static let duration: Double = 2.4

    init(_ palette: ImmersivePalette) {
        from = palette
        to = palette
    }

    var current: ImmersivePalette {
        let t = progress
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return from.mixed(with: to, amount: Float(eased))
    }

    var isSettled: Bool { progress >= 1 }

    mutating func retarget(_ palette: ImmersivePalette) {
        guard palette != to else { return }
        from = current
        to = palette
        progress = 0
    }

    mutating func advance(_ dt: Double, instant: Bool = false) {
        progress = instant ? 1 : min(1, progress + dt / Self.duration)
    }
}
