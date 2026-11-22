import Foundation

/// 原生 RVC ONNX 引擎适配器：直接通过 ONNX Runtime 检查模型计算图，完全不依赖 Python 或 pickle。
struct RVCEngineAdapter: VoiceEngineAdapter, Sendable {
    let engineID = "rvc"
    let displayName = "RVC (ONNX 原生)"
    let modelExtensions = ["voicepack", "onnx"]
    let preferredBackendIDs = ["onnx-coreml", "onnx-cpu"]

    let parameterSpecs: [VoiceParameterSpec] = [
        .init(
            key: "f0_up_key",
            title: "移调（半音）",
            control: .stepper,
            min: -12,
            max: 12,
            step: 1,
            options: nil,
            defaultValue: .int(0),
            advanced: false,
            help: "男声转女声通常 +8~+12，女声转男声 -8~-12。"
        ),
        .init(
            key: "separation_model",
            title: "人声分离",
            control: .picker,
            min: nil,
            max: nil,
            step: nil,
            options: ["mdx-vocals", "none"],
            defaultValue: .string("mdx-vocals"),
            advanced: false,
            help: "使用 UVR-MDX-NET 分离伴奏后再转换；干声可直接选择 none。"
        ),
        .init(
            key: "index_rate",
            title: "音色索引占比",
            control: .slider,
            min: 0,
            max: 1,
            step: 0.05,
            options: nil,
            defaultValue: .double(0.75),
            advanced: true,
            help: "仅音色包含 .f32bin 索引时生效：高值更接近训练音色，低值更贴近原唱。"
        ),
        .init(
            key: "filter_radius",
            title: "F0 平滑滤波",
            control: .stepper,
            min: 0,
            max: 7,
            step: 1,
            options: nil,
            defaultValue: .int(3),
            advanced: true,
            help: ">= 3 时对 RMVPE 提取的音高应用中值平滑，减少毛刺与八度跳变。"
        ),
        .init(
            key: "rms_mix_rate",
            title: "响度包络融合",
            control: .slider,
            min: 0,
            max: 1,
            step: 0.05,
            options: nil,
            defaultValue: .double(0.25),
            advanced: true,
            help: "控制原人声与合成结果之间的动态响度匹配比例。"
        ),
        .init(
            key: "protect",
            title: "清辅音保护",
            control: .slider,
            min: 0,
            max: 0.5,
            step: 0.01,
            options: nil,
            defaultValue: .double(0.33),
            advanced: true,
            help: "保护气声与清辅音咬字，0.5 表示关闭。"
        ),
    ]

    /// 校验并解析 `.voicepack` 目录或单个 `.onnx` 模型，计算流式 SHA256 指纹。
    func inspect(modelURL: URL) async throws -> VoiceModelInspection {
        let ext = modelURL.pathExtension.lowercased()
        if ext == "pth" || ext == "pt" || ext == "ckpt" {
            throw VoiceError.unsupportedModel(
                String(localized: "这是训练用的 .pth 文件，App 不能直接使用，需要先在电脑上转换成音色包。")
            )
        }

        let onnxURL: URL
        var packManifest: VoicePackConverterManifest?
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir), isDir.boolValue {
            let metaURL = modelURL.appendingPathComponent("pack.json")
            if let data = try? Data(contentsOf: metaURL),
               let decoded = try? JSONDecoder().decode(VoicePackConverterManifest.self, from: data) {
                packManifest = decoded
                onnxURL = modelURL.appendingPathComponent(decoded.modelFile)
            } else {
                onnxURL = modelURL.appendingPathComponent("model.onnx")
            }
        } else {
            guard ext == "onnx" else {
                throw VoiceError.unsupportedModel("仅支持 .voicepack 或 .onnx 模型（当前：.\(ext)）")
            }
            onnxURL = modelURL
            let siblingMeta = modelURL.deletingLastPathComponent().appendingPathComponent("pack.json")
            if let data = try? Data(contentsOf: siblingMeta),
               let decoded = try? JSONDecoder().decode(VoicePackConverterManifest.self, from: data) {
                packManifest = decoded
            }
        }

        guard FileManager.default.fileExists(atPath: onnxURL.path) else {
            throw VoiceError.invalidManifest(reason: "找不到 ONNX 模型文件：\(onnxURL.lastPathComponent)")
        }

        let (inputs, outputs) = try ORTSession.inspect(modelURL: onnxURL)
        guard !inputs.isEmpty, !outputs.isEmpty else {
            throw VoiceError.unsupportedModel("ONNX 模型缺少有效输入或输出节点")
        }

        let inputMap = Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, $0) })
        guard let phone = inputMap["phone"] else {
            throw VoiceError.unsupportedModel("不是有效的 RVC ONNX 模型（缺少 phone 输入）")
        }
        guard inputMap["phone_lengths"] != nil, inputMap["sid"] != nil, inputMap["rnd"] != nil else {
            throw VoiceError.unsupportedModel("RVC ONNX 模型缺少必需输入 (phone_lengths/sid/rnd)")
        }

        let hasF0 = inputMap["pitch"] != nil && inputMap["nsff0"] != nil
        let embDimFromGraph = Int(phone.shape.last ?? 0)
        let embDim = embDimFromGraph > 0 ? embDimFromGraph : (packManifest?.embeddingDim ?? 768)
        guard embDim == 256 || embDim == 768 else {
            throw VoiceError.unsupportedModel("不支持的特征维度：\(embDim)（仅支持 RVC v1 256 / v2 768）")
        }

        let archHint = packManifest?.architecture ?? (embDim == 256 ? "v1" : "v2")
        let interDimGraph = inputMap["rnd"]?.shape.count == 3 ? Int(inputMap["rnd"]?.shape[1] ?? 0) : 0
        let interChannels = interDimGraph > 0 ? interDimGraph : (packManifest?.interChannels ?? 192)
        let sampleRate = Self.normalizedSampleRate(packManifest?.sampleRate, filename: onnxURL.lastPathComponent)
        let speakerCount = max(packManifest?.speakerCount ?? 1, 1)
        let fingerprint = try VoiceModelAssetsManager.sha256File(url: onnxURL)

        return VoiceModelInspection(
            architectureHint: archHint,
            sampleRate: sampleRate,
            hasF0: hasF0,
            speakerCount: speakerCount,
            embeddingDim: embDim,
            interChannels: interChannels,
            fingerprint: fingerprint
        )
    }

    func normalizeParameters(_ overrides: [String: VoiceParameterValue]) -> [String: VoiceParameterValue] {
        var result: [String: VoiceParameterValue] = [:]
        for spec in parameterSpecs {
            let raw = overrides[spec.key] ?? spec.defaultValue
            result[spec.key] = clamp(raw, to: spec)
        }
        for (k, v) in overrides where result[k] == nil {
            result[k] = v
        }
        return result
    }

    private func clamp(_ value: VoiceParameterValue, to spec: VoiceParameterSpec) -> VoiceParameterValue {
        switch spec.control {
        case .slider, .stepper:
            if case .int = spec.defaultValue, let rawInt = value.intValue ?? value.doubleValue.map({ Int($0.rounded()) }) {
                var clamped = rawInt
                if let lo = spec.min { clamped = max(clamped, Int(lo)) }
                if let hi = spec.max { clamped = min(clamped, Int(hi)) }
                return .int(clamped)
            }
            if let d = value.doubleValue {
                var clamped = d
                if let lo = spec.min { clamped = max(clamped, lo) }
                if let hi = spec.max { clamped = min(clamped, hi) }
                return .double(clamped)
            }
            return spec.defaultValue
        case .toggle:
            return value.boolValue.map { .bool($0) } ?? spec.defaultValue
        case .picker:
            if let s = value.stringValue, spec.options?.contains(s) == true {
                return .string(s)
            }
            return spec.defaultValue
        }
    }

    private static func normalizedSampleRate(_ declared: Int?, filename: String) -> Int {
        if let declared, [32_000, 40_000, 48_000].contains(declared) {
            return declared
        }
        let lower = filename.lowercased()
        if lower.contains("48k") { return 48_000 }
        if lower.contains("32k") { return 32_000 }
        return 40_000
    }
}
