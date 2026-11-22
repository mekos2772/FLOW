import Foundation

/// 原生 RVC ONNX 语音合成管道（对齐 `rvc/modules/vc/pipeline.py` 分段零过零切分、RMS 匹配与参数生效）。
final class RVCVoiceConverter: @unchecked Sendable {
    private let rmvpe = RMVPEPitchExtractor()
    private let hubert = HuBERTFeatureExtractor()

    private var cachedVoiceSession: ORTSession?
    private var cachedVoicePath: String?
    private var cachedVoiceProvider: ORTExecutionProvider?

    private var cachedIndex: F32VectorIndex?
    private var cachedIndexPath: String?
    private let lock = NSLock()

    func unloadAll() {
        rmvpe.unload()
        hubert.unload()
        lock.lock()
        cachedVoiceSession = nil
        cachedVoicePath = nil
        cachedVoiceProvider = nil
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
        stageHandler: @Sendable (VoiceTaskStage, Double, String?) -> Void
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
                modelURL: rmvpeURL,
                provider: .cpu
            )
            pitchCoarse = extracted.coarse
            pitchFloat = extracted.continuous
        }

        // 动态长序列 Transformer (HuBERT) 与 NSF-HiFiGAN 合成器直接走 ARM64 CPU/AMX，
        // 避免 CoreML E5RT 动态图分段 90+ 次编译失败后再回退的数秒开销；RMVPE/MDX 则保持 CoreML ANE 加速。
        let voiceSession = try loadVoiceSessionIfNeeded(modelURL: voiceModelURL, provider: .cpu)
        let index: F32VectorIndex?
        if let indexURL, params.indexRate > 0, FileManager.default.fileExists(atPath: indexURL.path) {
            index = try loadIndexIfNeeded(url: indexURL)
        } else {
            index = nil
        }

        stageHandler(.convert, 0.25, "正在合成目标音色")
        var renderedChunks: [Float] = []
        var startSample = 0
        let totalChunks = optTs.count + 1
        var chunkIdx = 0

        for cutSample in optTs {
            try Task.checkCancellation()
            let endInPad = min(cutSample + tPad2 + window, audioPad.count)
            let chunkAudio = Array(audioPad[startSample..<endInPad])
            let frameStart = startSample / window
            let frameEnd = min((cutSample + tPad2) / window, totalPLen)

            let subPitch = hasF0 ? Array(pitchCoarse[frameStart..<frameEnd]) : nil
            let subPitchF = hasF0 ? Array(pitchFloat[frameStart..<frameEnd]) : nil

            let syn = try await inferChunk(
                audioSlice: chunkAudio,
                pitchCoarse: subPitch,
                pitchFloat: subPitchF,
                hasF0: hasF0,
                embeddingDim: embeddingDim,
                interChannels: interChannels,
                index: index,
                indexRate: params.indexRate,
                protect: params.protect,
                hubertURL: hubertURL,
                provider: .cpu,
                voiceSession: voiceSession
            )
            trimAndAppend(syn, tPadTgt: tPadTgt, into: &renderedChunks)
            startSample = cutSample
            chunkIdx += 1
            stageHandler(.convert, 0.25 + 0.65 * (Double(chunkIdx) / Double(totalChunks)), nil)
        }

        // 最后一段
        try Task.checkCancellation()
        let finalAudio = Array(audioPad[startSample..<audioPad.count])
        let finalFrameStart = startSample / window
        let finalPitch = hasF0 ? Array(pitchCoarse[finalFrameStart..<totalPLen]) : nil
        let finalPitchF = hasF0 ? Array(pitchFloat[finalFrameStart..<totalPLen]) : nil
        let finalSyn = try await inferChunk(
            audioSlice: finalAudio,
            pitchCoarse: finalPitch,
            pitchFloat: finalPitchF,
            hasF0: hasF0,
            embeddingDim: embeddingDim,
            interChannels: interChannels,
            index: index,
            indexRate: params.indexRate,
            protect: params.protect,
            hubertURL: hubertURL,
            provider: .cpu,
            voiceSession: voiceSession
        )
        trimAndAppend(finalSyn, tPadTgt: tPadTgt, into: &renderedChunks)
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
            blendedFeats = try index.searchAndBlend(
                features: rawFeats,
                frameCount: hubertFrames,
                rate: indexRate
            )
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

    private func loadVoiceSessionIfNeeded(modelURL: URL, provider: ORTExecutionProvider) throws -> ORTSession {
        let effectiveURL = (try? ONNXSineGenSanitizer.sanitizeIfNeeded(modelURL: modelURL)) ?? modelURL
        lock.lock()
        defer { lock.unlock() }
        if let cachedVoiceSession, cachedVoicePath == modelURL.path, cachedVoiceProvider == provider {
            return cachedVoiceSession
        }
        let session = try ORTSession(
            modelURL: effectiveURL,
            provider: provider,
            intraOpThreads: 4,
            allowCPUFallback: true
        )
        cachedVoiceSession = session
        cachedVoicePath = modelURL.path
        cachedVoiceProvider = provider
        return session
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
