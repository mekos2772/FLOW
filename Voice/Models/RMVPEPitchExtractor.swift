import Foundation

/// RMVPE ONNX F0 音高提取与量化（对齐 RVC `rmvpe.py` + `pipeline.get_f0`）。
final class RMVPEPitchExtractor: @unchecked Sendable {
    private static let centsMapping: [Float] = {
        var mapping = [Float](repeating: 0, count: 368)
        for i in 0..<360 {
            mapping[4 + i] = Float(20 * i) + 1997.3794084376191
        }
        return mapping
    }()

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

    /// 提取并量化 F0：返回 `(pitchCoarse [Int64 1..255], pitchF0 [Float Hz])`。
    func extractF0(
        audio16kPad: [Float],
        targetFrames pLen: Int,
        f0UpKey: Int,
        filterRadius: Int,
        modelURL: URL,
        provider: ORTExecutionProvider
    ) async throws -> (coarse: [Int64], continuous: [Float]) {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoiceError.missingBaseAssets([modelURL.lastPathComponent])
        }

        let session = try loadSessionIfNeeded(modelURL: modelURL, provider: provider)
        let threshold: Float = 0.03
        let inputSchema = Self.detectInputSchema(from: session.inputInfos)
        let inputName = Self.primaryInputInfo(from: session.inputInfos)?.name ?? (inputSchema == .waveform ? "waveform" : "mel")
        let outputName = session.outputInfos.first?.name ?? "salience"

        var nFrames = max(pLen, audio16kPad.count / 160)
        let nBins = 128
        var paddedFrames = 0
        var melInput: [Float] = []

        if inputSchema == .mel {
            let (mel, melFrames) = try VoiceAudioDSP.rmvpeLogMelSpectrogram(audio16k: audio16kPad)
            nFrames = melFrames
            paddedFrames = 32 * ((melFrames - 1) / 32 + 1)

            // mel 布局从 [128, nFrames] 填充至 [1, 128, paddedFrames]
            melInput = [Float](repeating: 0, count: nBins * paddedFrames)
            if paddedFrames == melFrames {
                melInput = mel
            } else {
                for b in 0..<nBins {
                    let srcStart = b * melFrames
                    let dstStart = b * paddedFrames
                    melInput.replaceSubrange(dstStart..<(dstStart + melFrames), with: mel[srcStart..<(srcStart + melFrames)])
                }
            }
        }

        let outputs = try await session.run(
            inputs: Self.buildInputs(
                schema: inputSchema,
                inputInfos: session.inputInfos,
                primaryName: inputName,
                melInput: melInput,
                nBins: nBins,
                paddedFrames: paddedFrames,
                audio16k: audio16kPad,
                threshold: threshold
            ),
            outputNames: [outputName]
        )
        guard let outputTensor = outputs[outputName] else {
            throw VoiceError.inferenceFailed("RMVPE 未返回有效输出")
        }

        var f0 = decodeOutput(tensor: outputTensor, nFrames: nFrames, threshold: threshold)
        let shiftFactor = powf(2.0, Float(f0UpKey) / 12.0)
        if shiftFactor != 1.0 {
            for i in 0..<f0.count {
                f0[i] *= shiftFactor
            }
        }

        // filter_radius >= 3 时对连续有声段应用 3 点中值平滑（对齐 RVC 去跳变习惯；< 3 保留原始 RMVPE）
        if filterRadius >= 3 {
            f0 = medianFilter3(f0)
        }

        // 截断或右侧补齐至 pLen
        var trimmed = [Float](repeating: 0, count: pLen)
        let copyCount = min(f0.count, pLen)
        if copyCount > 0 {
            trimmed.replaceSubrange(0..<copyCount, with: f0[0..<copyCount])
        }

        let coarse = quantizeF0Coarse(trimmed)
        return (coarse, trimmed)
    }

    func decodeF0(salience: [Float], nFrames: Int, threshold: Float = 0.03) -> [Float] {
        let numBins = 360
        let paddedWidth = 368
        var f0 = [Float](repeating: 0, count: nFrames)
        var rowPadded = [Float](repeating: 0, count: paddedWidth)

        for t in 0..<nFrames {
            let rowBase = t * numBins
            guard rowBase + numBins <= salience.count else { break }

            var bestIdx = 0
            var bestVal: Float = -Float.greatestFiniteMagnitude
            for b in 0..<numBins {
                let v = salience[rowBase + b]
                if v > bestVal {
                    bestVal = v
                    bestIdx = b
                }
            }
            if bestVal <= threshold {
                f0[t] = 0
                continue
            }

            rowPadded.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            rowPadded.replaceSubrange(4..<(4 + numBins), with: salience[rowBase..<(rowBase + numBins)])

            let center = bestIdx + 4
            let start = center - 4
            let end = center + 5
            var prodSum: Float = 0
            var weightSum: Float = 0
            for k in start..<end {
                let w = rowPadded[k]
                prodSum += w * Self.centsMapping[k]
                weightSum += w
            }
            let cents = weightSum > 0 ? (prodSum / weightSum) : 0
            let hz = 10.0 * powf(2.0, cents / 1200.0)
            f0[t] = abs(hz - 10.0) < 1e-4 ? 0 : hz
        }
        return f0
    }

    func quantizeF0Coarse(_ f0: [Float]) -> [Int64] {
        let f0Min: Float = 50
        let f0Max: Float = 1100
        let f0MelMin = 1127.0 * logf(1.0 + f0Min / 700.0)
        let f0MelMax = 1127.0 * logf(1.0 + f0Max / 700.0)
        let scale: Float = 254.0 / (f0MelMax - f0MelMin)

        return f0.map { hz in
            var mel = hz > 0 ? 1127.0 * logf(1.0 + hz / 700.0) : 0
            if mel > 0 {
                mel = (mel - f0MelMin) * scale + 1.0
            }
            if mel <= 1.0 { mel = 1.0 }
            if mel > 255.0 { mel = 255.0 }
            return Int64(mel.rounded())
        }
    }

    private func medianFilter3(_ x: [Float]) -> [Float] {
        guard x.count >= 3 else { return x }
        var out = x
        for i in 1..<(x.count - 1) {
            let a = x[i - 1], b = x[i], c = x[i + 1]
            let sorted = [a, b, c].sorted()
            out[i] = sorted[1]
        }
        return out
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

    enum RMVPEInputSchema: Equatable, Sendable {
        case mel
        case waveform
    }

    static func primaryInputInfo(from inputInfos: [ORTTensorInfo]) -> ORTTensorInfo? {
        inputInfos.first(where: { !$0.name.localizedCaseInsensitiveContains("thred") && !$0.name.localizedCaseInsensitiveContains("threshold") && $0.shape.count >= 2 })
            ?? inputInfos.first
    }

    static func detectInputSchema(from inputInfos: [ORTTensorInfo]) -> RMVPEInputSchema {
        guard let primary = primaryInputInfo(from: inputInfos) else { return .mel }
        if primary.shape.count == 2 {
            return .waveform
        }
        return .mel
    }

    static func buildInputs(
        schema: RMVPEInputSchema,
        inputInfos: [ORTTensorInfo],
        primaryName: String,
        melInput: [Float],
        nBins: Int,
        paddedFrames: Int,
        audio16k: [Float],
        threshold: Float
    ) -> [String: ORTTensorInput] {
        var result: [String: ORTTensorInput] = [:]
        switch schema {
        case .mel:
            result[primaryName] = .float32(data: melInput, shape: [1, Int64(nBins), Int64(paddedFrames)])
        case .waveform:
            result[primaryName] = .float32(data: audio16k, shape: [1, Int64(audio16k.count)])
        }

        if let thredInfo = inputInfos.first(where: {
            $0.name != primaryName && ($0.name.localizedCaseInsensitiveContains("thred") || $0.name.localizedCaseInsensitiveContains("threshold"))
        }) {
            let scalarShape: [Int64] = thredInfo.shape.isEmpty ? [] : (thredInfo.shape.map { $0 > 0 ? $0 : 1 })
            let count = max(1, scalarShape.reduce(1) { $0 * Int($1) })
            result[thredInfo.name] = .float32(data: [Float](repeating: threshold, count: count), shape: scalarShape)
        }
        return result
    }

    func decodeOutput(tensor: ORTTensorOutput, nFrames: Int, threshold: Float) -> [Float] {
        if tensor.shape.count == 3, (tensor.shape.last ?? 0) == 360 || tensor.floatData.count >= 360 {
            let maxSalienceFrames = tensor.floatData.count / 360
            let safeFrames = max(0, min(nFrames, maxSalienceFrames))
            if safeFrames > 0 {
                return decodeF0(salience: tensor.floatData, nFrames: safeFrames, threshold: threshold)
            }
        }
        return tensor.floatData
    }
}
