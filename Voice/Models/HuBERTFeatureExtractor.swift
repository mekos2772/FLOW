import Foundation

/// HuBERT ONNX 内容特征提取器，兼容双输出（v2 768 维 + v1 256 维）与单输出 HuBERT ONNX。
final class HuBERTFeatureExtractor: @unchecked Sendable {
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

    func extractFeatures(
        audio16k: [Float],
        embeddingDim: Int,
        modelURL: URL,
        provider: ORTExecutionProvider
    ) async throws -> (data: [Float], frames: Int) {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoiceError.missingBaseAssets([modelURL.lastPathComponent])
        }

        let session = try loadSessionIfNeeded(modelURL: modelURL, provider: provider)
        let modelInputs = Self.buildInputs(for: session.inputInfos, audio16k: audio16k)

        // 按输出维度匹配 v1 (256) 或 v2 (768)
        let targetOutputName = try Self.resolveOutputName(from: session.outputInfos, embeddingDim: embeddingDim)

        let outputs = try await session.run(
            inputs: modelInputs,
            outputNames: [targetOutputName]
        )
        guard let tensor = outputs[targetOutputName], tensor.shape.count == 3 else {
            throw VoiceError.inferenceFailed("HuBERT 输出张量维度无效")
        }
        let frames = Int(tensor.shape[1])
        let dim = Int(tensor.shape[2])
        guard dim == embeddingDim else {
            throw VoiceError.inferenceFailed("HuBERT 输出特征维(\(dim))与音色要求(\(embeddingDim))不一致")
        }
        return (tensor.floatData, frames)
    }

    /// 根据目标维度解析 HuBERT ONNX 的输出节点名（供提取与兼容性校验复用）。
    static func resolveOutputName(from outputInfos: [ORTTensorInfo], embeddingDim: Int) throws -> String {
        if let named = outputInfos.first(where: { info in
            if embeddingDim == 256 {
                return info.name == "feat_v1" || info.shape.last == 256
            }
            return info.name == "feat_v2" || info.shape.last == 768
        }) {
            return named.name
        }
        if embeddingDim == 768, let first = outputInfos.first {
            return first.name
        }
        throw VoiceError.unsupportedModel(
            "hubert_base.onnx 缺少 \(embeddingDim) 维特征输出（v1 音色需使用 export_base_models.py 导出的双输出模型）"
        )
    }

    /// 根据 ONNX 模型的真实输入节点签名构造推理输入。
    /// 兼容常见单输入 (`source: float32 [B, L]`) 以及双输入 (`source` + `padding_mask: bool [B, L]`) 社区模型。
    static func buildInputs(
        for inputInfos: [ORTTensorInfo],
        audio16k: [Float]
    ) -> [String: ORTTensorInput] {
        let shape: [Int64] = [1, Int64(audio16k.count)]
        let primaryInfo = inputInfos.first(where: {
            $0.elementType == .float32 && !$0.name.localizedCaseInsensitiveContains("mask")
        }) ?? inputInfos.first(where: {
            !$0.name.localizedCaseInsensitiveContains("mask")
        }) ?? inputInfos.first

        let primaryName = primaryInfo?.name ?? "source"
        var inputs: [String: ORTTensorInput] = [
            primaryName: .float32(data: audio16k, shape: shape)
        ]

        if let maskInfo = inputInfos.first(where: {
            $0.name != primaryName && $0.name.localizedCaseInsensitiveContains("mask")
        }) {
            switch maskInfo.elementType {
            case .bool:
                inputs[maskInfo.name] = .bool(
                    data: [Bool](repeating: false, count: audio16k.count),
                    shape: shape
                )
            case .int64:
                inputs[maskInfo.name] = .int64(
                    data: [Int64](repeating: 0, count: audio16k.count),
                    shape: shape
                )
            case .float32:
                inputs[maskInfo.name] = .float32(
                    data: [Float](repeating: 0, count: audio16k.count),
                    shape: shape
                )
            default:
                inputs[maskInfo.name] = .bool(
                    data: [Bool](repeating: false, count: audio16k.count),
                    shape: shape
                )
            }
        }

        return inputs
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
