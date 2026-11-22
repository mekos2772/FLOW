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

/// Apple CoreML Execution Provider + CPU 混合后端（优先使用 Neural Engine / GPU）。
struct CoreMLONNXBackend: VoiceInferenceBackend, Sendable {
    let id = "onnx-coreml"
    let displayName = "CoreML + Neural Engine (ONNX)"
    let intraOpThreads: Int32 = 4

    var isAvailable: Bool {
        ORTEnvironment.isCoreMLAvailable()
    }

    var availabilityNotes: String {
        isAvailable ? "CoreML EP 可用（MLProgram + ANE/GPU 自动调度）" : "CoreML EP 不可用，将回退 CPU"
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
