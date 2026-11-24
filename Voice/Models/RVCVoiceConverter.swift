import Foundation
import os

/// 原生 RVC ONNX 语音合成管道（对齐 `rvc/modules/vc/pipeline.py` 分段零过零切分、RMS 匹配与参数生效）。
final class RVCVoiceConverter: @unchecked Sendable {
    private let rmvpe = RMVPEPitchExtractor()
    private let hubert = HuBERTFeatureExtractor()

    private var cachedVoiceSessions: [ORTSession] = []
    private var cachedVoicePath: String?
    private var cachedVoiceProvider: ORTExecutionProvider?
    private var cachedVoiceThreads: Int32 = 0

    private var cachedIndex: F32VectorIndex?
    private var cachedIndexPath: String?
    private let lock = NSLock()
    private let indexSearchLock = NSLock()

    func unloadAll() {
        rmvpe.unload()
        hubert.unload()
        lock.lock()
        cachedVoiceSessions = []
        cachedVoicePath = nil
        cachedVoiceProvider = nil
        cachedVoiceThreads = 0
        cachedIndex = nil
        cachedIndexPath = nil
        lock.unlock()
    }

    struct Parameters: Sendable {
        let f0UpKey: Int
        let indexRate: Float
        let filterRadius: Int
        let rmsMixRate: Float
        let protect: Float
        let duetPitchAdapt: Bool

        init(
            f0UpKey: Int,
            indexRate: Float,
            filterRadius: Int,
            rmsMixRate: Float,
            protect: Float,
            duetPitchAdapt: Bool = false
        ) {
            self.f0UpKey = f0UpKey
            self.indexRate = indexRate
            self.filterRadius = filterRadius
            self.rmsMixRate = rmsMixRate
            self.protect = protect
            self.duetPitchAdapt = duetPitchAdapt
        }
    }

    /// 合成阶段的并行布局：开几路合成器、每路几个线程。
    struct SynthesisLayout: Sendable, Equatable {
        let workers: Int
        let threadsPerWorker: Int32
    }

    /// 单路合成器在最长分块（约 26 秒）上的峰值内存，M4 实测约 2.2GB。
    private static let synthesisPeakBytesPerWorker: UInt64 = 2_200_000_000

    /// 按核心数与内存挑最快的布局。
    ///
    /// M4（4 性能核 + 6 能效核）上每 20 秒分块的实测耗时：1 路 4 线程 7.5–9.7s、1 路 8 线程 7.4s、
    /// 2 路 4 线程 6.9s、3 路 3 线程 6.0s、4 路 2 线程 6.5s。合成器搬到 CoreML/GPU 反而要 36–200s，所以只在 CPU 上并行。
    /// 每多一路就多占约 2.2GB，所以路数还受物理内存约束（合计不超过三分之一），不够就退回单路多线程：
    /// 8GB 机器 1 路，16GB 机器 2 路，24GB 及以上 3 路。
    static func synthesisLayout(
        chunkCount: Int,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> SynthesisLayout {
        let cores = max(cores, 1)
        let memoryCap = Int(physicalMemory / 3 / synthesisPeakBytesPerWorker)
        let workers = max(1, min(3, chunkCount, cores / 3, memoryCap))
        let threads = workers == 1 ? min(8, cores) : max(2, min(4, cores / workers))
        return SynthesisLayout(workers: workers, threadsPerWorker: Int32(threads))
    }

    private struct ChunkPlan: Sendable {
        let audio: [Float]
        let pitchCoarse: [Int64]?
        let pitchFloat: [Float]?
    }

    /// 执行纯原生 RVC 推理，返回 `(samples: [Float], sampleRate: Int)`。
    func convertVocals(
        vocalsURL: URL,
        voiceModelURL: URL,
        indexURL: URL?,
        rmvpeURL: URL,
        hubertURL: URL,
        expectedSampleRate: Int,
        hasF0: Bool,
        embeddingDim: Int,
        interChannels: Int,
        params: Parameters,
        provider: ORTExecutionProvider,
        synthesisLayout layoutOverride: SynthesisLayout? = nil,
        stageHandler: @escaping @Sendable (VoiceTaskStage, Double, String?) -> Void
    ) async throws -> (samples: [Float], sampleRate: Int) {
        try Task.checkCancellation()
        stageHandler(.decode, 0.0, "正在解码人声音频")

        let sr16k = 16_000
        let window = 160
        let xPad = 1
        let xQuery = 3
        let xCenter = 18
        let xMax = 22

        let tPad = sr16k * xPad
        let tPadTgt = expectedSampleRate * xPad
        let tPad2 = tPad * 2
        let tQuery = sr16k * xQuery
        let tCenter = sr16k * xCenter
        let tMax = sr16k * xMax

        var audio = try VoiceAudioDSP.decodeMono(url: vocalsURL, targetSampleRate: Double(sr16k))
        guard !audio.isEmpty else {
            throw VoiceError.io("人声解码为空：\(vocalsURL.lastPathComponent)")
        }

        // 峰值归一化到 <= 0.95 并 5 阶 48Hz Butterworth 高通滤除次声底噪
        let absMax = audio.reduce(Float(0)) { max($0, abs($1)) }
        let normDiv = absMax / 0.95
        if normDiv > 1.0 {
            let inv = 1.0 / normDiv
            for i in 0..<audio.count { audio[i] *= inv }
        }
        audio = VoiceAudioDSP.butterworthHighPass48Hz16k(audio)

        // 搜索能量最小的静音分割点（对齐 RVC pipeline.py）
        var optTs: [Int] = []
        if audio.count > tMax {
            let energyWindowPad = VoiceAudioDSP.reflectPad1D(audio, pad: window / 2)
            var audioSum = [Float](repeating: 0, count: audio.count)
            for i in 0..<window {
                for j in 0..<audio.count {
                    audioSum[j] += abs(energyWindowPad[i + j])
                }
            }
            var t = tCenter
            while t < audio.count {
                let qStart = max(t - tQuery, 0)
                let qEnd = min(t + tQuery, audioSum.count)
                if qStart < qEnd {
                    var bestIdx = qStart
                    var minVal = audioSum[qStart]
                    for k in qStart..<qEnd {
                        if audioSum[k] < minVal {
                            minVal = audioSum[k]
                            bestIdx = k
                        }
                    }
                    optTs.append((bestIdx / window) * window)
                }
                t += tCenter
            }
        }

        let audioPad = VoiceAudioDSP.reflectPad1D(audio, pad: tPad)
        let totalPLen = audioPad.count / window

        var pitchCoarse: [Int64] = []
        var pitchFloat: [Float] = []
        if hasF0 {
            try Task.checkCancellation()
            stageHandler(.f0, 0.15, "正在提取 RMVPE 音高")
            let extracted = try await rmvpe.extractF0(
                audio16kPad: audioPad,
                targetFrames: totalPLen,
                f0UpKey: params.f0UpKey,
                filterRadius: params.filterRadius,
                duetPitchAdapt: params.duetPitchAdapt,
                modelURL: rmvpeURL,
                provider: .cpu
            )
            pitchCoarse = extracted.coarse
            pitchFloat = extracted.continuous
        }

        // 先把整段人声切成分块计划（切点与原先完全一致），再多路并行合成。
        var plans: [ChunkPlan] = []
        var startSample = 0
        for cutSample in optTs {
            let endInPad = min(cutSample + tPad2 + window, audioPad.count)
            let frameStart = startSample / window
            let frameEnd = min((cutSample + tPad2) / window, totalPLen)
            plans.append(ChunkPlan(
                audio: Array(audioPad[startSample..<endInPad]),
                pitchCoarse: hasF0 ? Array(pitchCoarse[frameStart..<frameEnd]) : nil,
                pitchFloat: hasF0 ? Array(pitchFloat[frameStart..<frameEnd]) : nil
            ))
            startSample = cutSample
        }
        let finalFrameStart = startSample / window
        plans.append(ChunkPlan(
            audio: Array(audioPad[startSample..<audioPad.count]),
            pitchCoarse: hasF0 ? Array(pitchCoarse[finalFrameStart..<totalPLen]) : nil,
            pitchFloat: hasF0 ? Array(pitchFloat[finalFrameStart..<totalPLen]) : nil
        ))

        // 各模型按实测最快的设备分配（M4）：MDX 分离走 CoreML/GPU；RMVPE、HuBERT 与 NSF-HiFiGAN 合成器走 CPU。
        // 后三者输入长度是动态的：HuBERT 与合成器在 CoreML 上建图失败，RMVPE 能跑但比 CPU 慢 2–10 倍；
        // 合成器即使固定形状搬上 GPU 也比 CPU 慢 5–20 倍。合成器是耗时大头，所以在 CPU 上开多路并行。
        let layout = layoutOverride ?? Self.synthesisLayout(chunkCount: plans.count)
        let voiceSessions = try loadVoiceSessionsIfNeeded(modelURL: voiceModelURL, provider: .cpu, layout: layout)
        // 每路合成器跑完会留着约 2GB 的工作内存，任务结束只保留一路给下一首复用。
        defer { trimVoiceSessionCache(keeping: 1) }

        let index: F32VectorIndex?
        if let indexURL, params.indexRate > 0, FileManager.default.fileExists(atPath: indexURL.path) {
            index = try loadIndexIfNeeded(url: indexURL)
        } else {
            index = nil
        }

        stageHandler(.convert, 0.25, "正在合成目标音色")
        let chunkPlans = plans
        let totalChunks = chunkPlans.count
        let nextChunk = OSAllocatedUnfairLock(initialState: 0)
        let finishedChunks = OSAllocatedUnfairLock(initialState: 0)
        let indexRate = params.indexRate
        let protect = params.protect

        // 每路从共享游标领下一块；HuBERT 会话各路共用（每块不到 1 秒，由会话内部串行）。
        let synthesized = try await withThrowingTaskGroup(of: [(Int, [Float])].self) { group in
            for voiceSession in voiceSessions {
                group.addTask { [self] in
                    var produced: [(Int, [Float])] = []
                    while true {
                        try Task.checkCancellation()
                        let chunkIndex = nextChunk.withLock { next -> Int in
                            defer { next += 1 }
                            return next
                        }
                        guard chunkIndex < totalChunks else { break }
                        let plan = chunkPlans[chunkIndex]
                        let syn = try await inferChunk(
                            audioSlice: plan.audio,
                            pitchCoarse: plan.pitchCoarse,
                            pitchFloat: plan.pitchFloat,
                            hasF0: hasF0,
                            embeddingDim: embeddingDim,
                            interChannels: interChannels,
                            index: index,
                            indexRate: indexRate,
                            protect: protect,
                            hubertURL: hubertURL,
                            provider: .cpu,
                            voiceSession: voiceSession
                        )
                        produced.append((chunkIndex, syn))
                        let done = finishedChunks.withLock { count -> Int in
                            count += 1
                            return count
                        }
                        stageHandler(.convert, 0.25 + 0.65 * (Double(done) / Double(totalChunks)), nil)
                    }
                    return produced
                }
            }
            var ordered = [[Float]?](repeating: nil, count: totalChunks)
            for try await batch in group {
                for (chunkIndex, syn) in batch {
                    ordered[chunkIndex] = syn
                }
            }
            return ordered
        }

        // 按原顺序拼接，结果与串行合成的分块一一对应。
        var renderedChunks: [Float] = []
        for syn in synthesized {
            guard let syn else {
                throw VoiceError.inferenceFailed("RVC 分块合成结果缺失")
            }
            trimAndAppend(syn, tPadTgt: tPadTgt, into: &renderedChunks)
        }
        stageHandler(.convert, 0.92, nil)

        if params.rmsMixRate < 0.999 && !renderedChunks.isEmpty {
            renderedChunks = VoiceAudioDSP.matchRMS(
                input: audio,
                inputSampleRate: sr16k,
                output: renderedChunks,
                outputSampleRate: expectedSampleRate,
                outputMixRate: params.rmsMixRate
            )
        }

        // 与 RVC pipeline.py 末尾限幅一致：保留峰值 <= 0.99
        let outMax = renderedChunks.reduce(Float(0)) { max($0, abs($1)) }
        if outMax > 0.99 {
            let scale = 0.99 / outMax
            for i in 0..<renderedChunks.count { renderedChunks[i] *= scale }
        }

        return (renderedChunks, expectedSampleRate)
    }

    private func inferChunk(
        audioSlice: [Float],
        pitchCoarse: [Int64]?,
        pitchFloat: [Float]?,
        hasF0: Bool,
        embeddingDim: Int,
        interChannels: Int,
        index: F32VectorIndex?,
        indexRate: Float,
        protect: Float,
        hubertURL: URL,
        provider: ORTExecutionProvider,
        voiceSession: ORTSession
    ) async throws -> [Float] {
        // 补 320 个尾部静音采样，确保 HuBERT 卷积帧数上采样 2x 后不短于目标音频帧数
        var hubertInput = audioSlice
        hubertInput.append(contentsOf: repeatElement(Float(0), count: 320))

        let (rawFeats, hubertFrames) = try await hubert.extractFeatures(
            audio16k: hubertInput,
            embeddingDim: embeddingDim,
            modelURL: hubertURL,
            provider: provider
        )

        var blendedFeats = rawFeats
        if let index, indexRate > 0 {
            // 检索要临时开一张「帧数 × 索引行数」的点积表（9 万行索引约 0.4GB），Accelerate 自己已是多线程，
            // 各路排队做，免得同时开好几张。
            blendedFeats = try indexSearchLock.withLock {
                try index.searchAndBlend(
                    features: rawFeats,
                    frameCount: hubertFrames,
                    rate: indexRate
                )
            }
        }

        // 沿时间轴 2x 最近邻插值：frames -> frames * 2
        let upFrames = hubertFrames * 2
        var upFeats = upsample2xNearest(blendedFeats, frames: hubertFrames, dim: embeddingDim)
        let rawUpFeats = (protect < 0.5 && hasF0)
            ? upsample2xNearest(rawFeats, frames: hubertFrames, dim: embeddingDim)
            : []

        let audioFramesCap = audioSlice.count / 160
        let pLen = min(upFrames, hasF0 ? min(audioFramesCap, pitchFloat?.count ?? audioFramesCap) : audioFramesCap)
        guard pLen > 0 else { return [] }

        if pLen < upFrames {
            upFeats = Array(upFeats.prefix(pLen * embeddingDim))
        }

        // 清辅音/气音保护（protect < 0.5 时在无声帧恢复未经过索引混合的原声特征）
        if protect < 0.5, hasF0, let pf = pitchFloat {
            let keepWeight = 1.0 - protect
            for t in 0..<pLen where pf[t] < 1.0 {
                let rowStart = t * embeddingDim
                for d in 0..<embeddingDim {
                    let i = rowStart + d
                    upFeats[i] = upFeats[i] * protect + rawUpFeats[i] * keepWeight
                }
            }
        }

        // 生成标准正态噪声 rnd [1, interChannels, pLen]
        let rnd = deterministicNormalNoise(count: interChannels * pLen, seed: UInt64(pLen &+ audioSlice.count))

        var inputs: [String: ORTTensorInput] = [
            "phone": .float32(data: upFeats, shape: [1, Int64(pLen), Int64(embeddingDim)]),
            "phone_lengths": .int64(data: [Int64(pLen)], shape: [1]),
            "sid": .int64(data: [0], shape: [1]),
            "rnd": .float32(data: rnd, shape: [1, Int64(interChannels), Int64(pLen)]),
        ]

        if hasF0, let pc = pitchCoarse, let pf = pitchFloat {
            inputs["pitch"] = .int64(data: Array(pc.prefix(pLen)), shape: [1, Int64(pLen)])
            inputs["nsff0"] = .float32(data: Array(pf.prefix(pLen)), shape: [1, Int64(pLen)])
        }

        let outputName = voiceSession.outputInfos.first?.name ?? "audio"
        let outputs = try await voiceSession.run(inputs: inputs, outputNames: [outputName])
        guard let audioOut = outputs[outputName]?.floatData else {
            throw VoiceError.inferenceFailed("RVC 合成器未返回 audio 输出")
        }
        return audioOut
    }

    private func trimAndAppend(_ samples: [Float], tPadTgt: Int, into dest: inout [Float]) {
        guard samples.count > 2 * tPadTgt else {
            dest.append(contentsOf: samples)
            return
        }
        dest.append(contentsOf: samples[tPadTgt..<(samples.count - tPadTgt)])
    }

    private func upsample2xNearest(_ src: [Float], frames: Int, dim: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2 * dim)
        for t in 0..<frames {
            let srcBase = t * dim
            let dst0 = (t * 2) * dim
            let dst1 = (t * 2 + 1) * dim
            out.replaceSubrange(dst0..<(dst0 + dim), with: src[srcBase..<(srcBase + dim)])
            out.replaceSubrange(dst1..<(dst1 + dim), with: src[srcBase..<(srcBase + dim)])
        }
        return out
    }

    private func deterministicNormalNoise(count: Int, seed: UInt64) -> [Float] {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        @inline(__always)
        func nextUniform() -> Float {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            let mantissa = Float((state >> 40) & 0xFF_FFFF) + 1.0
            return mantissa / Float(1 << 24)
        }
        var out = [Float](repeating: 0, count: count)
        var i = 0
        while i + 1 < count {
            let u1 = max(nextUniform(), 1e-7)
            let u2 = nextUniform()
            let r = sqrtf(-2.0 * logf(u1))
            let theta = 2.0 * Float.pi * u2
            out[i] = r * cosf(theta)
            out[i + 1] = r * sinf(theta)
            i += 2
        }
        if i < count {
            let u1 = max(nextUniform(), 1e-7)
            let u2 = nextUniform()
            out[i] = sqrtf(-2.0 * logf(u1)) * cosf(2.0 * Float.pi * u2)
        }
        return out
    }

    /// 按布局准备好若干路合成器会话；同一音色、同一线程数的已有会话直接复用，不够再补。
    private func loadVoiceSessionsIfNeeded(
        modelURL: URL,
        provider: ORTExecutionProvider,
        layout: SynthesisLayout
    ) throws -> [ORTSession] {
        let effectiveURL = (try? ONNXSineGenSanitizer.sanitizeIfNeeded(modelURL: modelURL)) ?? modelURL
        lock.lock()
        defer { lock.unlock() }
        let reusable = cachedVoicePath == modelURL.path
            && cachedVoiceProvider == provider
            && cachedVoiceThreads == layout.threadsPerWorker
        var sessions = reusable ? Array(cachedVoiceSessions.prefix(layout.workers)) : []
        while sessions.count < layout.workers {
            sessions.append(try ORTSession(
                modelURL: effectiveURL,
                provider: provider,
                intraOpThreads: layout.threadsPerWorker,
                allowCPUFallback: true
            ))
        }
        cachedVoiceSessions = sessions
        cachedVoicePath = modelURL.path
        cachedVoiceProvider = provider
        cachedVoiceThreads = layout.threadsPerWorker
        return sessions
    }

    private func trimVoiceSessionCache(keeping count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if cachedVoiceSessions.count > count {
            cachedVoiceSessions.removeLast(cachedVoiceSessions.count - count)
        }
    }

    private func loadIndexIfNeeded(url: URL) throws -> F32VectorIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIndex, cachedIndexPath == url.path {
            return cachedIndex
        }
        let idx = try F32VectorIndex(url: url)
        cachedIndex = idx
        cachedIndexPath = url.path
        return idx
    }
}
