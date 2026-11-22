import Foundation

/// 推理引擎扩展点（当前实现 RVC ONNX；可扩展 Seed-VC 等协议）。
protocol VoiceEngineAdapter: Sendable {
    var engineID: String { get }
    var displayName: String { get }
    var modelExtensions: [String] { get }
    var parameterSpecs: [VoiceParameterSpec] { get }
    var preferredBackendIDs: [String] { get }

    /// 读取并验证模型结构与指纹，不执行完整语音推理。
    func inspect(modelURL: URL) async throws -> VoiceModelInspection

    /// 将参数覆盖规范化并裁剪到引擎支持范围。
    func normalizeParameters(_ overrides: [String: VoiceParameterValue]) -> [String: VoiceParameterValue]
}

struct VoiceModelInspection: Hashable, Sendable {
    var architectureHint: String      // "v1" / "v2"
    var sampleRate: Int               // 32000 / 40000 / 48000
    var hasF0: Bool
    var speakerCount: Int
    var embeddingDim: Int             // 256 (v1) / 768 (v2)
    var interChannels: Int            // 默认 192
    var fingerprint: String
}

/// 全局引擎注册表；默认自动注册内置 RVC 引擎。
final class VoiceEngineRegistry: @unchecked Sendable {
    static let shared = VoiceEngineRegistry()

    private var adapters: [String: any VoiceEngineAdapter] = [:]
    private let lock = NSLock()

    init(adapters: [any VoiceEngineAdapter] = [RVCEngineAdapter()]) {
        for adapter in adapters {
            self.adapters[adapter.engineID] = adapter
        }
    }

    func register(_ adapter: any VoiceEngineAdapter) {
        lock.withLock {
            adapters[adapter.engineID] = adapter
        }
    }

    func adapter(for engineID: String) -> (any VoiceEngineAdapter)? {
        lock.withLock {
            adapters[engineID]
        }
    }

    var allAdapters: [any VoiceEngineAdapter] {
        lock.withLock {
            Array(adapters.values).sorted { $0.engineID < $1.engineID }
        }
    }
}
