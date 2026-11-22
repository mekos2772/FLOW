import Foundation

/// 实时节拍跟踪：从抽头切出的起音格子里估出速度、拍点和小节起点。
///
/// 纯值类型、没有时钟：渲染器每帧把新格子 `ingest` 进来，再用当前播放位置 `step` 一次；单测直接喂合成鼓点。
///
/// 做法（经典的"起音包络 + 自相关 + 梳状相位"，见 Ellis 2007 / Percival & Tzanetakis 2014）：
/// - **起音包络**：三段能量各自按慢速峰值归一化后取对数，求正向差分，低频（底鼓）权重最大、高频（镲）次之，
///   再减去 0.3 秒的局部均值——母带响度不同、混响拖尾都不会让包络整体抬高。
/// - **速度**：每 0.5 秒对最近 8 秒的包络做自相关，60–200 BPM，乘上"常见速度"先验（以 120 为中心、
///   约一个八度宽）并叠加二倍周期的相关值抑制倍速误判；换速度要连续两次胜出，倍速 / 半速视为同一家族，
///   除非明显更好否则不换。
/// - **相位**：按周期做梳状打分（越近的拍权重越大），网格钉在**歌曲时间**上；每次最多修正一成周期，
///   连续三次大偏差才重新锁定。拖动进度后网格照样有效。
/// - **小节**：低频起音按 4 拍取模累积（约 8 小节的指数平均），最强的那一拍当第一拍；换小节起点要连续 8 小节胜出。
/// - **输出时钟** `beatTime`：只调速度、从不跳变或倒退——画面上的动作因此永远连续；拖动进度时只追小数部分，一秒内追上。
struct ImmersiveBeatTracker {
    struct Output: Equatable {
        /// 当前网格的速度（BPM）；从没锁定过时是 90。
        var tempo: Double
        /// 网格此刻可不可信（0…1）。静音、没有鼓、节奏自由时趋近 0，画面上的节拍动作随之淡出。
        var confidence: Float
        /// 单调递增的拍数；小数部分是拍内相位，0 在拍点上。
        var beatTime: Double
        /// 小节内相位（0…1），0 在第一拍。
        var barPhase: Float
        var barConfidence: Float
    }

    struct Diagnostics: Equatable {
        var tempo: Double
        var confidence: Float
        var strongOnsets: Int
        /// 强起音落在预测拍点或半拍 ±50 ms 内的比例。
        var alignedRatio: Float
        /// 强起音相对最近网格点的平均偏差（正数表示起音比网格晚）。
        var meanOffsetMilliseconds: Double
    }

    static let capacity = 2048
    static let minBPM = 60.0
    static let maxBPM = 200.0
    /// 估速度用的历史长度。
    static let window = 8.0
    /// 没锁定过时假定的速度：让拍数时钟照常走，画面不会停。
    static let fallbackBPM = 90.0

    // MARK: 起音包络（环形缓冲，按到达顺序）

    private var envelope = [Float](repeating: 0, count: ImmersiveBeatTracker.capacity)
    private var lowEnvelope = [Float](repeating: 0, count: ImmersiveBeatTracker.capacity)
    /// 估速度用的两路包络：低频（底鼓、贝斯）和中高频（军鼓、镲），各自减去局部均值。
    private var lowTempoEnvelope = [Float](repeating: 0, count: ImmersiveBeatTracker.capacity)
    private var upperTempoEnvelope = [Float](repeating: 0, count: ImmersiveBeatTracker.capacity)
    private var lowMean: Float = 0
    private var upperMean: Float = 0
    private var times = [Double](repeating: 0, count: ImmersiveBeatTracker.capacity)
    private var head = 0
    private var count = 0
    private var hop = 512.0 / 44_100
    private var lastFrameTime = -Double.infinity
    private var previous = [Float](repeating: 0, count: 3)
    private var previousLow: Float = 0
    private var reference = [Float](repeating: 0, count: 3)
    private var primed = false
    private var fluxMean: Float = 0
    private var recentActivity: Float = 0
    private var longActivity: Float = 0
    private var framesSinceEstimate = 0

    // 估计用的暂存，初始化时分配好，之后不再分配。
    private var scratch = [Float](repeating: 0, count: ImmersiveBeatTracker.capacity)
    private var correlation = [Float](repeating: 0, count: 512)
    private var scores = [Float](repeating: 0, count: 512)
    private var bandScores = [Float](repeating: 0, count: 512)
    /// 速度打分的长期平均（约 8 秒时间常数）：主歌、副歌、过门的节奏型不同，单看 8 秒窗口容易在
    /// 三连音、附点这类关系之间来回跳；平均之后，整首歌一贯的那个速度会稳稳胜出。
    private var history = [Float](repeating: 0, count: 512)
    private var historyPrimed = false

    // MARK: 网格（歌曲时间）

    private var period: Double?
    private var anchor = 0.0
    private var anchored = false
    private var beatIndexOffset = 0
    private var candidatePeriod: Double?
    private var candidateHits = 0
    private var familyHits = 0
    private var largePhaseErrors = 0
    private var salience: Float = 0
    private var confidence: Float = 0

    // MARK: 小节

    private var barAccumulator = [Float](repeating: 0, count: 4)
    private var barBeats = 0
    private var barOffset: Int?
    private var barCandidate = 0
    private var barCandidateBeats = 0
    private var barConfidence: Float = 0
    private var lastBarBeat = Int.min

    // MARK: 输出时钟

    private var beatTime = 0.0
    /// 网格拍号与输出拍数之间的整数差：拖动进度时改它，让输出只追小数部分。
    private var beatShift = 0.0
    /// 小节参考点（拍数）的平滑值：小节起点或整数差变化时，在一拍左右的时间里滑过去，不跳。
    private var barReference: Double?

    init() {}

    mutating func reset() {
        self = ImmersiveBeatTracker()
    }

    // MARK: - 输入

    mutating func ingest<C: Collection>(_ frames: C) where C.Element == AudioOnsetFrame {
        for frame in frames { push(frame) }
    }

    private mutating func push(_ frame: AudioOnsetFrame) {
        guard frame.mediaTime.isFinite, frame.duration.isFinite, frame.duration > 0.002, frame.duration < 0.1 else { return }
        if lastFrameTime.isFinite {
            let gap = frame.mediaTime - lastFrameTime
            // 往回跳或往前跳了一大截：拖动过进度。包络历史作废，网格留着（同一首歌，速度不变）。
            if gap < -0.05 || gap > 0.5 {
                breakSegment()
            } else if gap < frame.duration * 0.5 {
                return
            }
        }
        hop = frame.duration
        lastFrameTime = frame.mediaTime

        let bands = [Self.clean(frame.low), Self.clean(frame.high), Self.clean(frame.mid)]
        let weights: [Float] = [1.0, 0.6, 0.35]
        let referenceRate = Float(1 - exp(-hop / 10))
        var flux: Float = 0
        var rises: [Float] = [0, 0, 0]
        for b in 0..<3 {
            let e = bands[b]
            reference[b] = e > reference[b] ? e : reference[b] + (e - reference[b]) * referenceRate
            let x = log(1 + 50 * e / max(reference[b], 1e-12))
            rises[b] = primed ? max(x - previous[b], 0) : 0
            previous[b] = x
            flux += rises[b] * weights[b]
        }
        primed = true
        let localRate = Float(1 - exp(-hop / 0.3))
        fluxMean += (flux - fluxMean) * localRate
        let onset = max(flux - fluxMean, 0)
        let upper = rises[1] + rises[2]
        lowMean += (rises[0] - lowMean) * localRate
        upperMean += (upper - upperMean) * localRate

        envelope[head] = onset
        // 找第一拍用线性的低频上冲（按慢速峰值归一）：对数压缩会把重拍和轻拍压得差不多。
        lowEnvelope[head] = max(bands[0] - previousLow, 0) / max(reference[0], 1e-12)
        previousLow = bands[0]
        lowTempoEnvelope[head] = max(rises[0] - lowMean, 0)
        upperTempoEnvelope[head] = max(upper - upperMean, 0)
        times[head] = frame.mediaTime
        head = (head + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
        recentActivity += (onset - recentActivity) * Float(1 - exp(-hop / 1.0))
        longActivity += (onset - longActivity) * Float(1 - exp(-hop / 20))

        framesSinceEstimate += 1
        if framesSinceEstimate >= Int(0.5 / hop), count >= Int(3.5 / hop) {
            framesSinceEstimate = 0
            estimate()
        }
    }

    private mutating func breakSegment() {
        count = 0
        primed = false
        framesSinceEstimate = 0
        lastBarBeat = Int.min
    }

    private static func clean(_ value: Float) -> Float {
        value.isFinite && value > 0 ? value : 0
    }

    /// 第 `back` 个最近的格子（0 = 最新）。
    private func index(back: Int) -> Int {
        (head - 1 - back + Self.capacity * 2) % Self.capacity
    }

    // MARK: - 估计

    /// 一路包络的速度打分：自相关 + 二倍、四倍周期（一小节）的相关值，乘上常见速度先验，按本路最大值归一。
    /// 真正的拍子在小节上也会重复；三连音、附点那种 1.5 拍的周期在四倍处落不到小节线上。
    private mutating func scoreTempo(_ source: [Float], n: Int, minLag: Int, maxLag: Int, topLag: Int) -> Bool {
        // 先用三点三角窗把包络抹宽一点：拍长很少正好是整数个格子（134 BPM ≈ 38.6 格），
        // 尖峰会被劈到相邻两个格子里各剩一半，输给碰巧落在整数格上的错误速度。
        for i in 0..<n {
            let c = source[index(back: n - 1 - i)]
            let l = i > 0 ? source[index(back: n - i)] : c
            let r = i + 1 < n ? source[index(back: n - 2 - i)] : c
            scratch[i] = 0.25 * l + 0.5 * c + 0.25 * r
        }
        for lag in 0...topLag {
            var sum: Float = 0
            var i = lag
            while i < n {
                sum += scratch[i] * scratch[i - lag]
                i += 1
            }
            correlation[lag] = sum / Float(n - lag)
        }
        guard correlation[0] > 1e-9 else { return false }
        var peak: Float = 0
        for lag in minLag...maxLag {
            let bpm = 60 / (Double(lag) * hop)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let score = (max(correlation[lag], 0) + 0.5 * max(correlation[min(2 * lag, topLag)], 0)
                         + 0.5 * max(correlation[min(4 * lag, topLag)], 0)) * prior
            bandScores[lag] = score
            peak = max(peak, score)
        }
        guard peak > 0 else { return false }
        for lag in minLag...maxLag { bandScores[lag] /= peak }
        return true
    }

    private mutating func estimate() {
        let n = min(count, Int(Self.window / hop))
        let minLag = max(2, Int((60 / Self.maxBPM / hop).rounded(.down)))
        let maxLag = Int((60 / Self.minBPM / hop).rounded(.up))
        let topLag = min(4 * maxLag + 2, correlation.count - 1)
        guard n > topLag + 8 else { return }

        // 低频和中高频分别打分再加权投票：R&B、嘻哈里底鼓常踩"1、2 拍半"，单看低频会把 134 听成 89；
        // 军鼓、镲落在拍上和半拍上，更可靠，票数多一些。
        for lag in minLag...maxLag { scores[lag] = 0 }
        var voters: Float = 0
        for (source, weight) in [(lowTempoEnvelope, Float(0.4)), (upperTempoEnvelope, Float(0.6))]
        where scoreTempo(source, n: n, minLag: minLag, maxLag: maxLag, topLag: topLag) {
            for lag in minLag...maxLag { scores[lag] += bandScores[lag] * weight }
            voters += weight
        }
        guard voters > 0 else {
            salience = 0
            return
        }
        var currentMax: Float = 0
        var total: Float = 0
        for lag in minLag...maxLag {
            scores[lag] /= voters
            total += scores[lag]
            currentMax = max(currentMax, scores[lag])
        }
        guard currentMax > 0 else {
            salience = 0
            return
        }
        // 打分先按本窗口最大值归一，再进长期平均：响的段落不会压过安静段落的证据。
        var best = minLag
        var bestHistory: Float = -1
        for lag in minLag...maxLag {
            let normalized = scores[lag] / currentMax
            history[lag] = historyPrimed ? history[lag] * 0.94 + normalized * 0.06 : normalized
            if history[lag] > bestHistory {
                bestHistory = history[lag]
                best = lag
            }
        }
        historyPrimed = true
        // 可信度看的是"此刻这一段"是否支持这个速度：过门、只剩人声时自然掉下来。
        let mean = total / Float(maxLag - minLag + 1)
        salience = max(scores[best] - mean, 0) / currentMax

        // 抛物线插值求亚格精度。
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = history[best - 1], b = history[best], c = history[best + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-12 { lag += Double(max(min(0.5 * (a - c) / denom, 0.5), -0.5)) }
        }
        updateTempo(candidate: lag * hop, score: bestHistory)
        if let period { updatePhase(period: period, n: n) }
    }

    private static func near(_ a: Double, _ b: Double, tolerance: Double = 0.04) -> Bool { abs(a / b - 1) < tolerance }

    private mutating func updateTempo(candidate: Double, score: Float) {
        guard let current = period else {
            // 第一次锁定：连续两次估到差不多的速度，而且相关峰够突出。
            if let previousCandidate = candidatePeriod, Self.near(candidate, previousCandidate), salience > 0.15 {
                candidateHits += 1
            } else {
                candidatePeriod = candidate
                candidateHits = salience > 0.15 ? 1 : 0
            }
            if candidateHits >= 3 {
                period = candidate
                candidatePeriod = nil
                candidateHits = 0
            }
            return
        }
        if Self.near(candidate, current) {
            // 相位锁住以后周期主要靠锁相环细调；自相关的估计带着格子量化的噪声，只轻轻参考。
            setPeriod(current + (candidate - current) * (largePhaseErrors == 0 && confidence > 0.5 ? 0.08 : 0.3))
            candidatePeriod = nil
            candidateHits = 0
            familyHits = 0
            return
        }
        let currentLag = Int((current / hop).rounded())
        let currentScore = (max(currentLag - 1, 0)...min(currentLag + 1, history.count - 1)).map { history[$0] }.max() ?? 0
        // 倍速、半速、三连音（3:2）这些关系在同一首歌里都会出现局部的相关峰——视为同一家族，
        // 除非明显更好（1.4 倍）且连续胜出 10 秒，否则保持现在的。
        let family = [2.0, 0.5, 3.0, 1.0 / 3, 1.5, 2.0 / 3].contains { Self.near(candidate / current, $0) }
        if family {
            familyHits = score > currentScore * 1.4 ? familyHits + 1 : 0
            if familyHits >= 20 {
                setPeriod(candidate)
                familyHits = 0
            }
            return
        }
        // 不相干的速度：打分已经是长期平均，持续领先 5% 达 3 秒就说明之前锁错了（常见于没有鼓的前奏）。
        if let previousCandidate = candidatePeriod, Self.near(candidate, previousCandidate), score > currentScore * 1.05 {
            candidateHits += 1
        } else {
            candidatePeriod = candidate
            candidateHits = score > currentScore * 1.05 ? 1 : 0
        }
        if candidateHits >= 6 {
            setPeriod(candidate)
            candidatePeriod = nil
            candidateHits = 0
        }
    }

    /// 换周期时把锚点挪到离最新数据最近的拍点上，拍号跟着平移——相位和拍号都不跳。
    private mutating func setPeriod(_ new: Double) {
        guard let old = period else {
            period = new
            return
        }
        let now = lastFrameTime.isFinite ? lastFrameTime : anchor
        let shift = ((now - anchor) / old).rounded()
        anchor += shift * old
        beatIndexOffset += Int(shift)
        period = new
    }

    private mutating func updatePhase(period: Double, n: Int) {
        let p = period / hop
        let beats = Int(Double(n) / p)
        guard beats >= 2 else { return }
        func comb(_ phase: Double) -> Float {
            var score: Float = 0
            var weight: Float = 1
            for k in 0..<beats {
                let back = phase + Double(k) * p
                let i0 = Int(back)
                guard i0 + 1 < n else { break }
                let f = Float(back - Double(i0))
                score += (envelope[index(back: i0)] * (1 - f) + envelope[index(back: i0 + 1)] * f) * weight
                weight *= 0.88
            }
            return score
        }
        var bestPhase = 0.0
        var bestScore: Float = -1
        var phase = 0.0
        while phase < p {
            let score = comb(phase)
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
            phase += 0.5
        }
        guard bestScore > 0 else { return }
        // 三点抛物线细化（步长半格）。
        if bestPhase >= 0.5 {
            let a = comb(bestPhase - 0.5), c = comb(bestPhase + 0.5)
            let denom = a - 2 * bestScore + c
            if abs(denom) > 1e-12 { bestPhase += 0.5 * Double(max(min(0.5 * (a - c) / denom, 0.5), -0.5)) }
        }
        // 包络的格子以开头计时，起音落在格子中间：补回半格。
        let observed = times[index(back: 0)] - bestPhase * hop + hop * 0.5

        guard anchored else {
            anchor = observed
            anchored = true
            accumulateBars(period: period, n: n)
            return
        }
        // 锚点挪到离这次观测最近的拍点上（拍号跟着平移）：周期哪怕差千分之一，
        // 锚点离得远了误差也会一拍拍累积起来；锚点始终跟着最近的拍，误差就不会滚雪球。
        let elapsed = (observed - anchor) / period
        let shift = elapsed.rounded()
        anchor += shift * period
        beatIndexOffset += Int(shift)
        let error = elapsed - shift
        if abs(error) < 0.3 {
            anchor += max(min(error * 0.5, 0.1), -0.1) * period
            // 锁相环的频率项：每次都晚到（或早到）说明周期本身偏了，按每拍的平均偏差慢慢修正周期。
            if shift >= 1 {
                let drift = error / shift
                self.period = period * (1 + max(min(drift * 0.3, 0.004), -0.004))
            }
            largePhaseErrors = 0
        } else {
            largePhaseErrors += 1
            if largePhaseErrors >= 3 {
                // 重新锁定：拍号尽量接上原来的，小节起点不至于乱掉。
                anchor = observed
                largePhaseErrors = 0
            }
        }
        accumulateBars(period: period, n: n)
    }

    /// 每个新拍点处的低频起音按拍号取模累积，最强的那一拍当第一拍。
    private mutating func accumulateBars(period: Double, n: Int) {
        let newest = times[index(back: 0)]
        let oldest = times[index(back: n - 1)]
        let first = Int(((oldest - anchor) / period).rounded(.up))
        let last = Int(((newest - anchor) / period - 0.1).rounded(.down))
        guard last >= first else { return }
        let decay: Float = 0.969
        var added = 0
        let from = lastBarBeat == Int.min ? first : max(first, lastBarBeat + 1 - beatIndexOffset)
        guard from <= last else { return }
        for j in from...last {
            let t = anchor + Double(j) * period
            let back = Int(((newest - t) / hop).rounded())
            guard back >= 2, back + 2 < n else { continue }
            var strength: Float = 0
            for d in -2...2 { strength = max(strength, lowEnvelope[index(back: back + d)]) }
            let beat = j + beatIndexOffset
            let slot = ((beat % 4) + 4) % 4
            for s in 0..<4 { barAccumulator[s] *= decay }
            barAccumulator[slot] += strength
            lastBarBeat = beat
            barBeats += 1
            added += 1
        }
        guard added > 0 else { return }
        let sorted = barAccumulator.enumerated().sorted { $0.element > $1.element }
        let top = sorted[0], second = sorted[1]
        barConfidence = top.element > 1e-6 ? min(max((top.element - second.element) / top.element * 2, 0), 1)
            * min(Float(barBeats) / 16, 1) : 0
        guard let current = barOffset else {
            if barBeats >= 8 { barOffset = top.offset }
            return
        }
        if top.offset == current {
            barCandidateBeats = 0
        } else if top.offset == barCandidate {
            barCandidateBeats += added
            if barCandidateBeats >= 32 {
                barOffset = top.offset
                barCandidateBeats = 0
            }
        } else {
            barCandidate = top.offset
            barCandidateBeats = added
        }
    }

    // MARK: - 每帧

    mutating func step(mediaTime: Double?, dt rawDt: Double, isPlaying: Bool) -> Output {
        let dt = rawDt.isFinite ? min(max(rawDt, 0), 0.25) : 0
        var target: Float = 0
        if period != nil, longActivity > 1e-6 {
            // 最近 1 秒的起音相对半分钟的平均：静下来两秒就掉到门槛以下，可信度跟着归零。
            let activity = Self.smoothstep(0.15, 0.6, recentActivity / longActivity)
            target = Self.smoothstep(0.18, 0.45, salience) * activity
        }
        let tau = target > confidence ? 1.2 : 0.5
        confidence += (target - confidence) * Float(1 - exp(-dt / tau))

        let p = period ?? 60 / Self.fallbackBPM
        let beatsPerSecond = 1 / p
        if isPlaying, let t = mediaTime, t.isFinite {
            if period != nil {
                let gridPosition = (t - anchor) / p + Double(beatIndexOffset)
                // 误差按"照常走完这一帧之后"算：否则稳态时输出会比网格提前整整一帧（30 帧下约 33 ms）。
                let nominal = beatTime + beatsPerSecond * dt
                var error = gridPosition + beatShift - nominal
                if abs(error) > 1.5 {
                    // 拖动进度或第一次锁定：只追小数部分，整数差记进 beatShift。
                    beatShift = (nominal - gridPosition).rounded()
                    error = gridPosition + beatShift - nominal
                }
                beatTime += beatsPerSecond * dt * min(max(1 + 2 * error, 0), 2)
            } else {
                beatTime += beatsPerSecond * dt
            }
        }

        var barPhase: Float = 0
        if let offset = barOffset {
            let goal = beatShift + Double(offset)
            if var reference = barReference {
                var delta = (goal - reference).truncatingRemainder(dividingBy: 4)
                if delta > 2 { delta -= 4 } else if delta < -2 { delta += 4 }
                let maxStep = beatsPerSecond * dt
                reference += max(min(delta, maxStep), -maxStep)
                barReference = reference
            } else {
                barReference = goal
            }
            let position = (beatTime - (barReference ?? goal)) / 4
            barPhase = Float(position - position.rounded(.down))
        } else {
            let position = beatTime / 4
            barPhase = Float(position - position.rounded(.down))
        }
        return Output(tempo: 60 / p, confidence: confidence, beatTime: beatTime, barPhase: barPhase,
                      barConfidence: barOffset == nil ? 0 : barConfidence * min(confidence * 2, 1))
    }

    // MARK: - 诊断

    func diagnostics(window: Double = 20) -> Diagnostics {
        let tempo = 60 / (period ?? 60 / Self.fallbackBPM)
        guard count > 8 else {
            return Diagnostics(tempo: tempo, confidence: confidence, strongOnsets: 0, alignedRatio: 0, meanOffsetMilliseconds: 0)
        }
        let n = min(count, Int(window / hop))
        var mean: Float = 0
        for i in 0..<n { mean += envelope[index(back: i)] }
        mean /= Float(n)
        var variance: Float = 0
        for i in 0..<n {
            let d = envelope[index(back: i)] - mean
            variance += d * d
        }
        let threshold = mean + 1.5 * sqrt(variance / Float(n))
        var strong = 0, aligned = 0
        var offsetSum = 0.0
        var lastPeak = -Double.infinity
        for i in stride(from: n - 2, through: 1, by: -1) {
            let v = envelope[index(back: i)]
            guard v > threshold, v >= envelope[index(back: i + 1)], v > envelope[index(back: i - 1)] else { continue }
            let t = times[index(back: i)] + hop * 0.5
            guard t - lastPeak > 0.1 else { continue }
            lastPeak = t
            strong += 1
            guard let period else { continue }
            let half = period / 2
            var offset = (t - anchor) / half
            offset = (offset - offset.rounded()) * half
            offsetSum += offset
            if abs(offset) <= 0.05 { aligned += 1 }
        }
        return Diagnostics(tempo: tempo, confidence: confidence, strongOnsets: strong,
                           alignedRatio: strong > 0 ? Float(aligned) / Float(strong) : 0,
                           meanOffsetMilliseconds: strong > 0 && period != nil ? offsetSum / Double(strong) * 1000 : 0)
    }

    /// 调试用：长期平均后的速度打分（BPM, 分数），按 BPM 从高到低。
    var tempoScores: [(bpm: Double, score: Float)] {
        let minLag = max(2, Int((60 / Self.maxBPM / hop).rounded(.down)))
        let maxLag = Int((60 / Self.minBPM / hop).rounded(.up))
        return (minLag...maxLag).map { (60 / (Double($0) * hop), history[$0]) }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 把节拍跟踪器的输出整理成送进着色器的 `rhythm`（拍数、小节相位、小节幅度、拍子幅度）。
///
/// - 幅度 = 可信度（平滑过）× 节拍联动档位 × 随音乐变化；暂停、静音、减少动态效果时一秒内淡出；
/// - 快歌（128 BPM 以上）按半速给画面：每拍一动显得忙乱，和"低频、低幅"的原则冲突，
///   《七里香》142、《我落泪情绪零碎》134 听感上也是半速。回落到 122 以下才恢复，免得在门槛附近来回切；
/// - 画面拍数自己积分，向"小节里该在的那一拍"用调速的方式靠拢：切半速、换歌、跟踪器重新对齐小节时都不跳。
struct ImmersiveRhythm {
    private(set) var groove: Float = 0
    private(set) var halfTime = false
    private(set) var visualBeats = 0.0
    private var barParity = 0
    private var lastBarPhase: Float = 0
    private var lastTrackerBeat: Double?

    /// 换歌时跟踪器从零开始数拍；画面拍数接着走，只是不再拿新旧两段做差。
    mutating func trackChanged() {
        lastTrackerBeat = nil
    }

    mutating func step(_ beat: ImmersiveBeatTracker.Output, dt: Double, active: Bool,
                       response: Float, sync: ImmersiveBeatSync) -> SIMD4<Float> {
        groove = ImmersiveDriver.follow(groove, to: active ? beat.confidence : 0, dt: dt, attack: 1.0, release: 0.6)
        if beat.tempo > 128 { halfTime = true } else if beat.tempo < 122 { halfTime = false }
        if beat.barPhase < lastBarPhase - 0.5 { barParity ^= 1 }
        lastBarPhase = beat.barPhase

        let delta = lastTrackerBeat.map { max(beat.beatTime - $0, 0) } ?? 0
        lastTrackerBeat = beat.beatTime
        let desired = halfTime ? (Double(barParity) + Double(beat.barPhase)) * 2 : Double(beat.barPhase) * 4
        var error = (desired - visualBeats).truncatingRemainder(dividingBy: 4)
        if error >= 2 { error -= 4 } else if error < -2 { error += 4 }
        visualBeats += delta * (halfTime ? 0.5 : 1) * min(max(1 + 0.8 * error, 0), 2)

        let barPosition = visualBeats / 4
        let gain = response * groove
        return SIMD4(Float(visualBeats.truncatingRemainder(dividingBy: 4096)),
                     Float(barPosition - barPosition.rounded(.down)),
                     gain * sync.barGain * (0.5 + 0.5 * beat.barConfidence),
                     gain * sync.beatGain)
    }
}
