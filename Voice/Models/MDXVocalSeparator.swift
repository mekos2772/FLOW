import Accelerate
import Foundation

/// 原生 UVR MDX-Net (.onnx) 人声/伴奏分离器（CoreML/CPU ONNX Runtime + Accelerate STFT/ISTFT）。
final class MDXVocalSeparator: @unchecked Sendable {
    struct SeparationResult: Sendable {
        let vocalsURL: URL
        let instrumentalURL: URL
        let sampleRate: Int
        let duration: TimeInterval
    }

    private var cachedSession: ORTSession?
    private var cachedModelPath: String?
    private var cachedProvider: ORTExecutionProvider?
    private let lock = NSLock()

    func unload() {
        lock.lock()
        cachedSession = nil
        cachedModelPath = nil
        cachedProvider = nil
        lock.unlock()
    }

    /// 分离人声与伴奏到目标 `.wav` 文件（44.1kHz 立体声 Float32 WAV，供后续 RVC 与混音无损使用）。
    func separate(
        inputURL: URL,
        vocalsOutputURL: URL,
        instrumentalOutputURL: URL,
        modelURL: URL,
        provider: ORTExecutionProvider,
        overlap: Double = 0.25,
        enableDenoise: Bool = false,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> SeparationResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoiceError.missingBaseAssets([modelURL.lastPathComponent])
        }

        let session = try loadSessionIfNeeded(modelURL: modelURL, provider: provider)
        guard let inputInfo = session.inputInfos.first else {
            throw VoiceError.unsupportedModel("MDX 分离模型缺少输入张量定义")
        }
        let outputName = session.outputInfos.first?.name ?? "output"
        let params = MDXModelCatalog.resolveParams(modelURL: modelURL, inputShape: inputInfo.shape)

        let targetSR: Double = 44_100
        let decoded = try VoiceAudioDSP.decodeStereo(url: inputURL, targetSampleRate: targetSR)
        guard !decoded.left.isEmpty else {
            throw VoiceError.io("音频文件为空或解码失败：\(inputURL.lastPathComponent)")
        }

        let nSamples = min(decoded.left.count, decoded.right.count)
        let origLeft = Array(decoded.left.prefix(nSamples))
        let origRight = Array(decoded.right.prefix(nSamples))

        // 峰值归一化对齐 audio-separator `spec_utils.normalize(max_peak=0.9, min_peak=0.0)`
        var peakL: Float = 0
        var peakR: Float = 0
        vDSP_maxmgv(origLeft, 1, &peakL, vDSP_Length(nSamples))
        vDSP_maxmgv(origRight, 1, &peakR, vDSP_Length(nSamples))
        let peak = max(peakL, peakR)

        var normScale: Float = 1.0
        if peak > 0.9 {
            normScale = 0.9 / peak
        }
        var normLeft = origLeft
        var normRight = origRight
        if normScale != 1.0 {
            var s = normScale
            vDSP_vsmul(normLeft, 1, &s, &normLeft, 1, vDSP_Length(nSamples))
            vDSP_vsmul(normRight, 1, &s, &normRight, 1, vDSP_Length(nSamples))
        }

        let hopLength = 1024
        let trim = params.nFFT / 2
        let chunkSize = hopLength * (params.dimT - 1)
        let genSize = chunkSize - 2 * trim
        guard genSize > 0 else {
            throw VoiceError.unsupportedModel("MDX 参数异常 (chunkSize=\(chunkSize), trim=\(trim))")
        }

        let padTail = genSize + trim - (nSamples % genSize)
        var paddedL = [Float](repeating: 0, count: trim + nSamples + padTail)
        var paddedR = [Float](repeating: 0, count: trim + nSamples + padTail)
        paddedL.replaceSubrange(trim..<(trim + nSamples), with: normLeft)
        paddedR.replaceSubrange(trim..<(trim + nSamples), with: normRight)

        let totalPadded = paddedL.count
        let clampedOverlap = min(max(overlap, 0.0), 0.75)
        let step = max(Int((1.0 - clampedOverlap) * Double(chunkSize)), 1)

        var resultL = [Float](repeating: 0, count: totalPadded)
        var resultR = [Float](repeating: 0, count: totalPadded)
        var divider = [Float](repeating: 0, count: totalPadded)

        var start = 0
        let totalSteps = max((totalPadded + step - 1) / step, 1)
        var stepIdx = 0

        while start < totalPadded {
            try Task.checkCancellation()
            let end = min(start + chunkSize, totalPadded)
            let actualLen = end - start

            var chunkL = [Float](repeating: 0, count: chunkSize)
            var chunkR = [Float](repeating: 0, count: chunkSize)
            chunkL.replaceSubrange(0..<actualLen, with: paddedL[start..<end])
            chunkR.replaceSubrange(0..<actualLen, with: paddedR[start..<end])

            let (stftTensor, stftFrames) = try VoiceAudioDSP.mdxSTFT(
                left: chunkL,
                right: chunkR,
                nFFT: params.nFFT,
                hopLength: hopLength,
                dimF: params.dimF
            )

            // 清零最低 3 个频 bin（对齐 MDXSeparator）
            var maskedSpec = stftTensor
            let planeStride = params.dimF * stftFrames
            for ch in 0..<4 {
                let base = ch * planeStride
                for f in 0..<min(3, params.dimF) {
                    let rowStart = base + f * stftFrames
                    for t in 0..<stftFrames {
                        maskedSpec[rowStart + t] = 0
                    }
                }
            }

            let specShape: [Int64] = [1, 4, Int64(params.dimF), Int64(stftFrames)]
            let specPred: [Float]
            if enableDenoise {
                let posOut = try await session.run(
                    inputs: [inputInfo.name: .float32(data: maskedSpec, shape: specShape)],
                    outputNames: [outputName]
                )
                guard let posData = posOut[outputName]?.floatData else {
                    throw VoiceError.inferenceFailed("MDX 输出缺失")
                }
                var negSpec = maskedSpec
                var negOne: Float = -1.0
                vDSP_vsmul(negSpec, 1, &negOne, &negSpec, 1, vDSP_Length(negSpec.count))
                let negOut = try await session.run(
                    inputs: [inputInfo.name: .float32(data: negSpec, shape: specShape)],
                    outputNames: [outputName]
                )
                guard let negData = negOut[outputName]?.floatData else {
                    throw VoiceError.inferenceFailed("MDX 降噪输出缺失")
                }
                var avg = [Float](repeating: 0, count: posData.count)
                for i in 0..<min(posData.count, negData.count) {
                    avg[i] = 0.5 * posData[i] - 0.5 * negData[i]
                }
                specPred = avg
            } else {
                let out = try await session.run(
                    inputs: [inputInfo.name: .float32(data: maskedSpec, shape: specShape)],
                    outputNames: [outputName]
                )
                guard let data = out[outputName]?.floatData else {
                    throw VoiceError.inferenceFailed("MDX 输出缺失")
                }
                specPred = data
            }

            let inv = try VoiceAudioDSP.mdxISTFT(
                tensor: specPred,
                dimF: params.dimF,
                frames: stftFrames,
                nFFT: params.nFFT,
                hopLength: hopLength,
                targetLength: chunkSize
            )

            let win = clampedOverlap > 0 ? VoiceAudioDSP.hannWindowSymmetric(length: actualLen) : nil
            for i in 0..<actualLen {
                let w = win?[i] ?? 1.0
                resultL[start + i] += inv.left[i] * w
                resultR[start + i] += inv.right[i] * w
                divider[start + i] += w
            }

            stepIdx += 1
            progressHandler(min(Double(stepIdx) / Double(totalSteps), 0.98))
            start += step
        }

        let invNorm = 1.0 / normScale
        var primaryL = [Float](repeating: 0, count: nSamples)
        var primaryR = [Float](repeating: 0, count: nSamples)
        for i in 0..<nSamples {
            let idx = trim + i
            let d = max(divider[idx], 1e-8)
            primaryL[i] = (resultL[idx] / d) * invNorm
            primaryR[i] = (resultR[idx] / d) * invNorm
        }

        var secondaryL = [Float](repeating: 0, count: nSamples)
        var secondaryR = [Float](repeating: 0, count: nSamples)
        let comp = params.compensate
        for i in 0..<nSamples {
            secondaryL[i] = origLeft[i] - primaryL[i] * comp
            secondaryR[i] = origRight[i] - primaryR[i] * comp
        }

        let (vocalsL, vocalsR, instL, instR) = params.isVocalPrimary
            ? (primaryL, primaryR, secondaryL, secondaryR)
            : (secondaryL, secondaryR, primaryL, primaryR)

        try VoiceAudioDSP.writeWAV(left: vocalsL, right: vocalsR, sampleRate: targetSR, to: vocalsOutputURL)
        try VoiceAudioDSP.writeWAV(left: instL, right: instR, sampleRate: targetSR, to: instrumentalOutputURL)
        progressHandler(1.0)

        return SeparationResult(
            vocalsURL: vocalsOutputURL,
            instrumentalURL: instrumentalOutputURL,
            sampleRate: Int(targetSR),
            duration: Double(nSamples) / targetSR
        )
    }

    private func loadSessionIfNeeded(modelURL: URL, provider: ORTExecutionProvider) throws -> ORTSession {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSession, cachedModelPath == modelURL.path, cachedProvider == provider {
            return cachedSession
        }
        let session = try ORTSession(
            modelURL: modelURL,
            provider: provider,
            intraOpThreads: 4,
            allowCPUFallback: true
        )
        cachedSession = session
        cachedModelPath = modelURL.path
        cachedProvider = provider
        return session
    }
}
