import Foundation

/// 推理后端能力描述。
struct VoiceBackendCapability: Hashable, Sendable {
    var id: String
    var displayName: String
    var available: Bool
    var notes: String
}

/// 原生 ONNX Runtime 推理后端抽象（支持扩展新硬件后端）。
protocol VoiceInferenceBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var intraOpThreads: Int32 { get }
    var isAvailable: Bool { get }
    var availabilityNotes: String { get }
    func executionProvider(cacheDirectory: URL?) -> ORTExecutionProvider
}

/// CoreML + CPU 混合后端：人声分离走 CoreML（实测由 GPU 执行），音高、特征与合成走 CPU 多路并行。
/// 各模型的设备是按实测耗时分的，见 `docs/FLOW_VOICE.md`「设备分配」。
struct CoreMLONNXBackend: VoiceInferenceBackend, Sendable {
    let id = "onnx-coreml"
    let displayName = "GPU + CPU 混合 (ONNX)"
    let intraOpThreads: Int32 = 4

    var isAvailable: Bool {
        ORTEnvironment.isCoreMLAvailable()
    }

    var availabilityNotes: String {
        isAvailable ? "CoreML EP 可用（人声分离走 GPU，其余模型走 CPU 并行）" : "CoreML EP 不可用，将回退 CPU"
    }

    func executionProvider(cacheDirectory: URL?) -> ORTExecutionProvider {
        .coreML(cacheDirectory: cacheDirectory)
    }
}

/// 纯 CPU ONNX Runtime + Accelerate BLAS 后端（稳定兜底）。
struct CPUONNXBackend: VoiceInferenceBackend, Sendable {
    let id = "onnx-cpu"
    let displayName = "CPU (ONNX + Accelerate)"
    let intraOpThreads: Int32 = 4
    let isAvailable = true
    let availabilityNotes = "ARM64 NEON + Accelerate BLAS 原生执行"

    func executionProvider(cacheDirectory: URL?) -> ORTExecutionProvider {
        .cpu
    }
}

/// 推理后端注册表；自动探测真机 CoreML EP 可用性。
final class VoiceBackendRegistry: @unchecked Sendable {
    static let shared = VoiceBackendRegistry()

    private let backends: [any VoiceInferenceBackend]

    init(backends: [any VoiceInferenceBackend] = [
        CoreMLONNXBackend(),
        CPUONNXBackend(),
    ]) {
        self.backends = backends
    }

    func backend(for id: String) -> (any VoiceInferenceBackend)? {
        backends.first { $0.id == id }
    }

    func preferredBackend() -> any VoiceInferenceBackend {
        backends.first(where: \.isAvailable) ?? CPUONNXBackend()
    }

    func capabilities() -> [VoiceBackendCapability] {
        backends.map {
            VoiceBackendCapability(
                id: $0.id,
                displayName: $0.displayName,
                available: $0.isAvailable,
                notes: $0.availabilityNotes
            )
        }
    }
}
