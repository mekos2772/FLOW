import Foundation

/// 音色包清单：`Application Support/FLOW/Voice/Packs/<packID>/pack.json`。
struct VoicePackManifest: Codable, Hashable, Sendable {
    static let currentFormatVersion = 2

    var formatVersion: Int = Self.currentFormatVersion
    var packID: String
    var displayName: String
    var engineID: String
    var versions: [VoicePackVersion]
    var selectedVersionID: String
    var coverFileName: String?
    var parameterOverrides: [String: VoiceParameterValue]

    var selectedVersion: VoicePackVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    init(
        formatVersion: Int = Self.currentFormatVersion,
        packID: String,
        displayName: String,
        engineID: String,
        versions: [VoicePackVersion],
        selectedVersionID: String,
        coverFileName: String? = nil,
        parameterOverrides: [String: VoiceParameterValue] = [:]
    ) {
        self.formatVersion = formatVersion
        self.packID = packID
        self.displayName = displayName
        self.engineID = engineID
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.coverFileName = coverFileName
        self.parameterOverrides = parameterOverrides
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, packID, displayName, engineID, versions
        case selectedVersionID, coverFileName, parameterOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        packID = try c.decode(String.self, forKey: .packID)
        displayName = try c.decode(String.self, forKey: .displayName)
        engineID = try c.decode(String.self, forKey: .engineID)
        versions = try c.decode([VoicePackVersion].self, forKey: .versions)
        selectedVersionID = try c.decode(String.self, forKey: .selectedVersionID)
        coverFileName = try c.decodeIfPresent(String.self, forKey: .coverFileName)
        parameterOverrides = try c.decodeIfPresent([String: VoiceParameterValue].self, forKey: .parameterOverrides) ?? [:]
    }
}

/// 音色包单个模型版本条目。
struct VoicePackVersion: Codable, Hashable, Sendable {
    var id: String
    var weightFileName: String
    var indexFileName: String?
    var weightFingerprint: String
    var indexFingerprint: String?
    var sampleRate: Int
    var architectureHint: String
    var hasF0: Bool
    var embeddingDim: Int
    var interChannels: Int
    var speakerCount: Int
    var importedAt: Date

    init(
        id: String,
        weightFileName: String,
        indexFileName: String? = nil,
        weightFingerprint: String,
        indexFingerprint: String? = nil,
        sampleRate: Int,
        architectureHint: String,
        hasF0: Bool = true,
        embeddingDim: Int = 768,
        interChannels: Int = 192,
        speakerCount: Int = 1,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.weightFileName = weightFileName
        self.indexFileName = indexFileName
        self.weightFingerprint = weightFingerprint
        self.indexFingerprint = indexFingerprint
        self.sampleRate = sampleRate
        self.architectureHint = architectureHint
        self.hasF0 = hasF0
        self.embeddingDim = embeddingDim
        self.interChannels = interChannels
        self.speakerCount = speakerCount
        self.importedAt = importedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, weightFileName, indexFileName, weightFingerprint, indexFingerprint
        case sampleRate, architectureHint, hasF0, embeddingDim, interChannels, speakerCount, importedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        weightFileName = try c.decode(String.self, forKey: .weightFileName)
        indexFileName = try c.decodeIfPresent(String.self, forKey: .indexFileName)
        weightFingerprint = try c.decode(String.self, forKey: .weightFingerprint)
        indexFingerprint = try c.decodeIfPresent(String.self, forKey: .indexFingerprint)
        sampleRate = try c.decode(Int.self, forKey: .sampleRate)
        architectureHint = try c.decode(String.self, forKey: .architectureHint)
        hasF0 = try c.decodeIfPresent(Bool.self, forKey: .hasF0) ?? true
        embeddingDim = try c.decodeIfPresent(Int.self, forKey: .embeddingDim)
            ?? (architectureHint == "v1" ? 256 : 768)
        interChannels = try c.decodeIfPresent(Int.self, forKey: .interChannels) ?? 192
        speakerCount = try c.decodeIfPresent(Int.self, forKey: .speakerCount) ?? 1
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? .distantPast
    }
}

/// 离线转换工具生成的 `.voicepack/pack.json` 描述格式。
struct VoicePackConverterManifest: Codable, Hashable, Sendable {
    var format: String?
    var name: String?
    var engine: String?
    var architecture: String?
    var hasF0: Bool?
    var sampleRate: Int?
    var embeddingDim: Int?
    var interChannels: Int?
    var speakerCount: Int?
    var modelFile: String
    var indexFile: String?
    var indexRows: Int?
    var indexDim: Int?
    var f0UpKeyDefault: Int?
    var onnxSha256: String?
}

/// 强类型参数值，用于持久化与参数规范化。
enum VoiceParameterValue: Codable, Hashable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .bool, .string: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .bool, .string: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int, .double, .string: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .int, .double, .bool: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.typeMismatch(
            VoiceParameterValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "不支持的参数值类型")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

/// 引擎参数声明，驱动高级设置 UI 与范围裁剪。
struct VoiceParameterSpec: Codable, Hashable, Sendable {
    enum Control: String, Codable, Sendable {
        case slider
        case stepper
        case toggle
        case picker
    }

    var key: String
    var title: String
    var control: Control
    var min: Double?
    var max: Double?
    var step: Double?
    var options: [String]?
    var defaultValue: VoiceParameterValue
    var advanced: Bool
    var help: String?
}

/// 推理任务阶段。
enum VoiceTaskStage: String, Codable, Sendable {
    case queued
    case decode
    case separate
    case f0
    case convert
    case mix
    case encode
    case done
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .decode: return "解码音频"
        case .separate: return "人声分离"
        case .f0: return "提取音高"
        case .convert: return "音色合成"
        case .mix: return "人声混音"
        case .encode: return "导出音频"
        case .done: return "已完成"
        case .failed: return "处理失败"
        case .cancelled: return "已取消"
        }
    }
}

/// 音色转换作业请求。
struct VoiceConversionJob: Codable, Hashable, Sendable {
    var jobID: String
    var trackKey: String
    var inputPath: String
    var vocalsPath: String?
    var accompanimentPath: String?
    var convertedVocalsPath: String?
    var outputPath: String
    var separationKey: String
    var conversionKey: String
    var renderKey: String
    var packID: String
    var versionID: String
    var engineID: String
    var weightPath: String
    var indexPath: String?
    var sampleRate: Int
    var hasF0: Bool
    var embeddingDim: Int
    var interChannels: Int
    var parameters: [String: VoiceParameterValue]
    var qualityMode: String
    var pipelineVersion: Int
    /// 写进渲染清单供离线页展示：歌名/封面与生成时的音色名（音色包被删后仍能认出来）。
    var track: Track?
    var packName: String?

    init(
        jobID: String,
        trackKey: String,
        inputPath: String,
        vocalsPath: String? = nil,
        accompanimentPath: String? = nil,
        convertedVocalsPath: String? = nil,
        outputPath: String,
        separationKey: String = "",
        conversionKey: String = "",
        renderKey: String = "",
        packID: String,
        versionID: String,
        engineID: String,
        weightPath: String,
        indexPath: String? = nil,
        sampleRate: Int,
        hasF0: Bool = true,
        embeddingDim: Int = 768,
        interChannels: Int = 192,
        parameters: [String: VoiceParameterValue],
        qualityMode: String = "balanced",
        pipelineVersion: Int,
        track: Track? = nil,
        packName: String? = nil
    ) {
        self.jobID = jobID
        self.trackKey = trackKey
        self.inputPath = inputPath
        self.vocalsPath = vocalsPath
        self.accompanimentPath = accompanimentPath
        self.convertedVocalsPath = convertedVocalsPath
        self.outputPath = outputPath
        self.separationKey = separationKey
        self.conversionKey = conversionKey
        self.renderKey = renderKey
        self.packID = packID
        self.versionID = versionID
        self.engineID = engineID
        self.weightPath = weightPath
        self.indexPath = indexPath
        self.sampleRate = sampleRate
        self.hasF0 = hasF0
        self.embeddingDim = embeddingDim
        self.interChannels = interChannels
        self.parameters = parameters
        self.qualityMode = qualityMode
        self.pipelineVersion = pipelineVersion
        self.track = track
        self.packName = packName
    }
}

struct VoiceTaskProgress: Codable, Hashable, Sendable {
    var jobID: String
    var stage: VoiceTaskStage
    var fraction: Double
    var message: String?
    var metrics: [String: Double]?
}

enum VoiceTaskState: Equatable, Sendable {
    case queued
    case running(stage: VoiceTaskStage, fraction: Double, message: String?)
    case succeeded(renderURL: URL, duration: TimeInterval, metrics: [String: Double])
    case failed(VoiceError)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

enum VoiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidManifest(reason: String)
    case unsupportedModel(_ reason: String)
    case missingBaseAssets([String])
    case networkDisabled(String)
    case engineNotRegistered(String)
    case backendUnavailable(String)
    case inferenceFailed(String)
    case cacheCorrupted(String)
    case jobNotFound(String)
    case cancelled
    case io(String)
    /// 有转换任务在跑时不允许整体清缓存：任务正握着分离/转换中间文件，删了会当场失败。
    case cacheBusy

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let r):
            return "音色配置无效: \(r)"
        case .unsupportedModel(let r):
            return "模型不受支持: \(r)"
        case .missingBaseAssets(let names):
            return "缺少基础 ONNX 模型: \(names.joined(separator: "、"))"
        case .networkDisabled(let r):
            return "网络访问已关闭: \(r)"
        case .engineNotRegistered(let id):
            return "未注册推理引擎: \(id)"
        case .backendUnavailable(let r):
            return "推理后端不可用: \(r)"
        case .inferenceFailed(let r):
            return "音色合成失败: \(r)"
        case .cacheCorrupted(let r):
            return "缓存损坏: \(r)"
        case .jobNotFound(let id):
            return "任务不存在: \(id)"
        case .cancelled:
            return "已取消"
        case .io(let r):
            return "文件读写失败: \(r)"
        case .cacheBusy:
            return "有转换正在进行，完成或取消后再清理缓存"
        }
    }

    var localizedDescription: String {
        errorDescription ?? "未知音色处理错误"
    }
}

struct VoiceRender: Hashable, Sendable {
    var trackKey: String
    var cacheKey: String
    var fileURL: URL
    var duration: TimeInterval
    var sampleRate: Int
    var packID: String
    var versionID: String
    var pipelineVersion: Int
}
