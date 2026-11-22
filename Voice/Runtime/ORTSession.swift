import Foundation
import OnnxRuntime
import os

/// ONNX Runtime 执行提供器配置。
enum ORTExecutionProvider: Sendable, Equatable {
    case cpu
    case coreML(cacheDirectory: URL?)

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .coreML: return "CoreML"
        }
    }
}

/// ONNX 张量元素类型。
enum ORTTensorElementType: Sendable, Equatable {
    case float32
    case int64
    case int32
    case bool
    case other(UInt32)

    init(cType: ONNXTensorElementDataType) {
        switch cType {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: self = .float32
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: self = .int64
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: self = .int32
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: self = .bool
        default: self = .other(cType.rawValue)
        }
    }
}

/// 模型输入/输出节点元数据（用于 .onnx 音色包自检与校验）。
struct ORTTensorInfo: Sendable, Equatable {
    let name: String
    let elementType: ORTTensorElementType
    /// `-1` 或 `<= 0` 表示符号/动态维度。
    let shape: [Int64]
}

/// 传入 ORT 的张量数据。
enum ORTTensorInput: Sendable {
    case float32(data: [Float], shape: [Int64])
    case int64(data: [Int64], shape: [Int64])
    case bool(data: [Bool], shape: [Int64])

    var shape: [Int64] {
        switch self {
        case .float32(_, let shape), .int64(_, let shape), .bool(_, let shape):
            return shape
        }
    }
}

/// ORT 推理输出张量数据。
struct ORTTensorOutput: Sendable {
    let shape: [Int64]
    let elementType: ORTTensorElementType
    let floatData: [Float]
    let int64Data: [Int64]
}

enum ORTError: Error, LocalizedError, Sendable {
    case apiUnavailable
    case statusFailure(operation: String, message: String)
    case invalidTensorShape(String)
    case unsupportedOutputType(String, ORTTensorElementType)
    case missingOutput(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "ONNX Runtime C API 不可用"
        case .statusFailure(let op, let message):
            return "ONNX Runtime \(op) 失败: \(message)"
        case .invalidTensorShape(let msg):
            return "无效张量形状: \(msg)"
        case .unsupportedOutputType(let name, let type):
            return "不支持的输出张量类型 \(name): \(type)"
        case .missingOutput(let name):
            return "缺少输出张量: \(name)"
        case .cancelled:
            return "ONNX Runtime 推理已取消"
        }
    }
}

/// 进程级单例 OrtEnv 持有器（线程安全；初始化失败时抛出错误而非崩溃整个播放器）。
final class ORTEnvironment: @unchecked Sendable {
    private static let sharedResult: Result<ORTEnvironment, Error> = Result {
        try ORTEnvironment()
    }

    static func acquire() throws -> ORTEnvironment {
        try sharedResult.get()
    }

    let api: UnsafePointer<OrtApi>
    let env: OpaquePointer
    private let memoryInfo: OpaquePointer

    private init() throws {
        guard let base = OrtGetApiBase(),
              let rawAPI = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw ORTError.apiUnavailable
        }
        self.api = rawAPI

        var createdEnv: OpaquePointer?
        let envStatus = rawAPI.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "FLOWVoice", &createdEnv)
        if let envStatus {
            let msg = rawAPI.pointee.GetErrorMessage(envStatus).map { String(cString: $0) } ?? "unknown"
            rawAPI.pointee.ReleaseStatus(envStatus)
            throw ORTError.statusFailure(operation: "CreateEnv", message: msg)
        }
        guard let createdEnv else {
            throw ORTError.statusFailure(operation: "CreateEnv", message: "null OrtEnv")
        }
        self.env = createdEnv

        var memInfo: OpaquePointer?
        let memStatus = rawAPI.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo)
        if let memStatus {
            let msg = rawAPI.pointee.GetErrorMessage(memStatus).map { String(cString: $0) } ?? "unknown"
            rawAPI.pointee.ReleaseStatus(memStatus)
            rawAPI.pointee.ReleaseEnv(createdEnv)
            throw ORTError.statusFailure(operation: "CreateCpuMemoryInfo", message: msg)
        }
        guard let memInfo else {
            rawAPI.pointee.ReleaseEnv(createdEnv)
            throw ORTError.statusFailure(operation: "CreateCpuMemoryInfo", message: "null OrtMemoryInfo")
        }
        self.memoryInfo = memInfo
    }

    deinit {
        api.pointee.ReleaseMemoryInfo(memoryInfo)
        api.pointee.ReleaseEnv(env)
    }

    var cpuMemoryInfo: OpaquePointer { memoryInfo }

    static var runtimeVersion: String {
        guard let base = OrtGetApiBase(), let cStr = base.pointee.GetVersionString() else {
            return "unknown"
        }
        return String(cString: cStr)
    }

    /// 真正探测当前设备/系统上 CoreML Execution Provider 是否可挂载。
    static func isCoreMLAvailable() -> Bool {
        guard let env = try? acquire() else { return false }
        var opts: OpaquePointer?
        guard env.api.pointee.CreateSessionOptions(&opts) == nil, let opts else {
            return false
        }
        defer { env.api.pointee.ReleaseSessionOptions(opts) }
        if let status = OrtSessionOptionsAppendExecutionProvider_CoreML(opts, COREML_FLAG_CREATE_MLPROGRAM.rawValue) {
            env.api.pointee.ReleaseStatus(status)
            return false
        }
        return true
    }

    func check(_ status: OpaquePointer?, operation: String) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
        api.pointee.ReleaseStatus(status)
        throw ORTError.statusFailure(operation: operation, message: message)
    }
}

/// 线程安全、支持中断取消的 ONNX Runtime 会话包装。
final class ORTSession: @unchecked Sendable {
    let modelURL: URL
    private(set) var activeProviderName: String
    let inputInfos: [ORTTensorInfo]
    let outputInfos: [ORTTensorInfo]

    private let env: ORTEnvironment
    private var session: OpaquePointer
    private let intraOpThreads: Int32
    private let allowCPUFallback: Bool
    private var isUsingCoreML: Bool
    private let runLock = NSLock()
    private let cancelState = OSAllocatedUnfairLock<CancelState>(initialState: CancelState())

    private struct SendableOpaquePointer: @unchecked Sendable, Equatable {
        let raw: OpaquePointer
    }

    private struct CancelState: Sendable {
        var cancelled = false
        var activeRunOptions: SendableOpaquePointer?
    }

    /// 加载 ONNX 模型；若请求 CoreML 且挂载或构建图失败，可自动回退 CPU EP。
    init(
        modelURL: URL,
        provider: ORTExecutionProvider = .coreML(cacheDirectory: nil),
        intraOpThreads: Int32 = 4,
        allowCPUFallback: Bool = true
    ) throws {
        self.env = try ORTEnvironment.acquire()
        self.modelURL = modelURL
        self.intraOpThreads = intraOpThreads
        self.allowCPUFallback = allowCPUFallback
        do {
            let (sess, provName) = try Self.createSession(
                modelURL: modelURL,
                provider: provider,
                intraOpThreads: intraOpThreads
            )
            self.session = sess
            self.activeProviderName = provName
            if case .coreML = provider {
                self.isUsingCoreML = true
            } else {
                self.isUsingCoreML = false
            }
        } catch {
            guard allowCPUFallback, case .coreML = provider else {
                throw error
            }
            let (sess, provName) = try Self.createSession(
                modelURL: modelURL,
                provider: .cpu,
                intraOpThreads: intraOpThreads
            )
            self.session = sess
            self.activeProviderName = "\(provName) (CoreML 回退)"
            self.isUsingCoreML = false
        }
        self.inputInfos = try Self.readIOInfos(session: self.session, isInput: true)
        self.outputInfos = try Self.readIOInfos(session: self.session, isInput: false)
    }

    deinit {
        env.api.pointee.ReleaseSession(session)
    }

    /// 快速校验并读取 `.onnx` 的输入输出元数据（会随核心逻辑复用会话创建，但不长期占用内存）。
    static func inspect(modelURL: URL) throws -> (inputs: [ORTTensorInfo], outputs: [ORTTensorInfo]) {
        let session = try ORTSession(
            modelURL: modelURL,
            provider: .cpu,
            intraOpThreads: 1,
            allowCPUFallback: false
        )
        return (session.inputInfos, session.outputInfos)
    }

    /// 异步执行推理；支持 Swift Concurrency Task 取消并实时触发 `OrtRunOptionsSetTerminate`。
    func run(
        inputs: [String: ORTTensorInput],
        outputNames: [String]? = nil
    ) async throws -> [String: ORTTensorOutput] {
        try Task.checkCancellation()
        let resolvedOutputs = outputNames ?? outputInfos.map(\.name)

        cancelState.withLock { state in
            state.cancelled = false
            state.activeRunOptions = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    do {
                        let result = try self.runSync(inputs: inputs, outputNames: resolvedOutputs)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.qualityOfService = .userInitiated
                thread.name = "com.flow.voice.ort.\(modelURL.deletingPathExtension().lastPathComponent)"
                thread.start()
            }
        } onCancel: { [self] in
            self.cancelActiveRun()
        }
    }

    func cancelActiveRun() {
        let optsToTerminate: SendableOpaquePointer? = cancelState.withLock { state in
            state.cancelled = true
            return state.activeRunOptions
        }
        if let optsToTerminate {
            if let st = env.api.pointee.RunOptionsSetTerminate(optsToTerminate.raw) {
                env.api.pointee.ReleaseStatus(st)
            }
        }
    }

    /// 同步执行推理（测试或内部已处于独立线程时可直接调用）。
    func runSync(
        inputs: [String: ORTTensorInput],
        outputNames: [String]? = nil
    ) throws -> [String: ORTTensorOutput] {
        runLock.lock()
        defer { runLock.unlock() }

        let api = env.api
        let targetOutputNames = outputNames ?? outputInfos.map(\.name)

        var runOptions: OpaquePointer?
        try env.check(api.pointee.CreateRunOptions(&runOptions), operation: "CreateRunOptions")
        guard let runOptions else {
            throw ORTError.apiUnavailable
        }
        let boxedRunOpts = SendableOpaquePointer(raw: runOptions)
        defer {
            cancelState.withLock { state in
                if state.activeRunOptions == boxedRunOpts {
                    state.activeRunOptions = nil
                }
            }
            api.pointee.ReleaseRunOptions(boxedRunOpts.raw)
        }

        let alreadyCancelled = cancelState.withLock { state -> Bool in
            state.activeRunOptions = boxedRunOpts
            return state.cancelled
        }
        if alreadyCancelled || Task.isCancelled {
            throw ORTError.cancelled
        }

        let orderedNames = Array(inputs.keys)
        var ortInputValues: [OpaquePointer?] = Array(repeating: nil, count: orderedNames.count)
        defer {
            for val in ortInputValues {
                if let val { api.pointee.ReleaseValue(val) }
            }
        }

        // 持有连续数组拷贝直到 Run 返回，确保裸指针在 C 调用期间始终有效。
        var floatHolders: [[Float]] = []
        var int64Holders: [[Int64]] = []
        var boolHolders: [[UInt8]] = []
        var shapeHolders: [[Int64]] = []
        floatHolders.reserveCapacity(orderedNames.count)
        int64Holders.reserveCapacity(orderedNames.count)
        boolHolders.reserveCapacity(orderedNames.count)
        shapeHolders.reserveCapacity(orderedNames.count)

        func makeTensor<Element>(
            storage: inout [[Element]],
            data: [Element],
            shape: [Int64],
            shapeIndex: Int,
            name: String,
            dataType: ONNXTensorElementDataType
        ) throws -> OpaquePointer? {
            let expectedCount = Self.elementCount(shape: shape)
            guard expectedCount == data.count else {
                throw ORTError.invalidTensorShape("\(name): shape \(shape) 需要 \(expectedCount) 个元素，收到 \(data.count)")
            }
            storage.append(data)
            let dataIdx = storage.count - 1
            let byteCount = max(data.count, 1) * MemoryLayout<Element>.stride
            var created: OpaquePointer?
            try storage[dataIdx].withUnsafeMutableBytes { rawBuf in
                try shapeHolders[shapeIndex].withUnsafeBufferPointer { shapeBuf in
                    try env.check(
                        api.pointee.CreateTensorWithDataAsOrtValue(
                            env.cpuMemoryInfo,
                            rawBuf.baseAddress,
                            byteCount,
                            shapeBuf.baseAddress,
                            shapeBuf.count,
                            dataType,
                            &created
                        ),
                        operation: "CreateTensorWithDataAsOrtValue(\(name))"
                    )
                }
            }
            return created
        }

        for (index, name) in orderedNames.enumerated() {
            guard let tensor = inputs[name] else { continue }
            var shape = tensor.shape
            shapeHolders.append(shape)
            let shapeIdx = shapeHolders.count - 1

            switch tensor {
            case .float32(let data, _):
                ortInputValues[index] = try makeTensor(
                    storage: &floatHolders,
                    data: data,
                    shape: shape,
                    shapeIndex: shapeIdx,
                    name: name,
                    dataType: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
                )
            case .int64(let data, _):
                ortInputValues[index] = try makeTensor(
                    storage: &int64Holders,
                    data: data,
                    shape: shape,
                    shapeIndex: shapeIdx,
                    name: name,
                    dataType: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                )
            case .bool(let data, _):
                ortInputValues[index] = try makeTensor(
                    storage: &boolHolders,
                    data: data.map { $0 ? 1 : 0 },
                    shape: shape,
                    shapeIndex: shapeIdx,
                    name: name,
                    dataType: ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL
                )
            }
            _ = shape.popLast() // silence unused mutation warning if any
        }

        var ortOutputValues: [OpaquePointer?] = Array(repeating: nil, count: targetOutputNames.count)
        defer {
            for val in ortOutputValues {
                if let val { api.pointee.ReleaseValue(val) }
            }
        }

        let inputCStrs: [UnsafeMutablePointer<CChar>?] = orderedNames.map { strdup($0) }
        let outputCStrs: [UnsafeMutablePointer<CChar>?] = targetOutputNames.map { strdup($0) }
        defer {
            inputCStrs.forEach { if let p = $0 { free(p) } }
            outputCStrs.forEach { if let p = $0 { free(p) } }
        }

        let inputConstPtrs: [UnsafePointer<CChar>?] = inputCStrs.map { UnsafePointer($0) }
        let outputConstPtrs: [UnsafePointer<CChar>?] = outputCStrs.map { UnsafePointer($0) }
        let inputValConstPtrs: [OpaquePointer?] = ortInputValues

        do {
            try invokeRun(
                session: session,
                runOptions: runOptions,
                inputNames: inputConstPtrs,
                inputVals: inputValConstPtrs,
                outputNames: outputConstPtrs,
                outputVals: &ortOutputValues
            )
        } catch let ortErr as ORTError {
            let wasCancelled = cancelState.withLock { $0.cancelled }
            if wasCancelled || Task.isCancelled {
                throw ORTError.cancelled
            }
            guard allowCPUFallback, isUsingCoreML else {
                throw ortErr
            }
            // 若 CoreML 在首个动态输入尺寸 Run 时 E5RT 编译异常，就地切换纯 CPU EP 重试一次。
            let (cpuSession, cpuName) = try Self.createSession(
                modelURL: modelURL,
                provider: .cpu,
                intraOpThreads: intraOpThreads
            )
            env.api.pointee.ReleaseSession(session)
            session = cpuSession
            isUsingCoreML = false
            activeProviderName = "\(cpuName) (CoreML 运行时回退)"
            for i in 0..<ortOutputValues.count {
                if let v = ortOutputValues[i] {
                    api.pointee.ReleaseValue(v)
                    ortOutputValues[i] = nil
                }
            }
            try invokeRun(
                session: session,
                runOptions: runOptions,
                inputNames: inputConstPtrs,
                inputVals: inputValConstPtrs,
                outputNames: outputConstPtrs,
                outputVals: &ortOutputValues
            )
        }

        return try extractOutputs(outputNames: targetOutputNames, outputValues: ortOutputValues)
    }

    private func invokeRun(
        session: OpaquePointer,
        runOptions: OpaquePointer,
        inputNames: [UnsafePointer<CChar>?],
        inputVals: [OpaquePointer?],
        outputNames: [UnsafePointer<CChar>?],
        outputVals: inout [OpaquePointer?]
    ) throws {
        let api = env.api
        try inputNames.withUnsafeBufferPointer { inNamesBuf in
            try inputVals.withUnsafeBufferPointer { inValsBuf in
                try outputNames.withUnsafeBufferPointer { outNamesBuf in
                    try outputVals.withUnsafeMutableBufferPointer { outValsBuf in
                        try env.check(
                            api.pointee.Run(
                                session,
                                runOptions,
                                inNamesBuf.baseAddress,
                                inValsBuf.baseAddress,
                                inputNames.count,
                                outNamesBuf.baseAddress,
                                outputNames.count,
                                outValsBuf.baseAddress
                            ),
                            operation: "Run(\(modelURL.lastPathComponent))"
                        )
                    }
                }
            }
        }
    }

    private func extractOutputs(
        outputNames: [String],
        outputValues: [OpaquePointer?]
    ) throws -> [String: ORTTensorOutput] {
        let api = env.api
        var results: [String: ORTTensorOutput] = [:]
        results.reserveCapacity(outputNames.count)

        for (index, name) in outputNames.enumerated() {
            guard let outVal = outputValues[index] else {
                throw ORTError.missingOutput(name)
            }
            var typeInfo: OpaquePointer?
            try env.check(api.pointee.GetTensorTypeAndShape(outVal, &typeInfo), operation: "GetTensorTypeAndShape")
            guard let typeInfo else {
                throw ORTError.missingOutput(name)
            }
            defer { api.pointee.ReleaseTensorTypeAndShapeInfo(typeInfo) }

            var cType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try env.check(api.pointee.GetTensorElementType(typeInfo, &cType), operation: "GetTensorElementType")
            var dimCount: Int = 0
            try env.check(api.pointee.GetDimensionsCount(typeInfo, &dimCount), operation: "GetDimensionsCount")
            var shape = [Int64](repeating: 0, count: dimCount)
            if dimCount > 0 {
                try shape.withUnsafeMutableBufferPointer { buf in
                    try env.check(api.pointee.GetDimensions(typeInfo, buf.baseAddress, dimCount), operation: "GetDimensions")
                }
            }
            let count = Self.elementCount(shape: shape)
            var rawDataPtr: UnsafeMutableRawPointer?
            try env.check(api.pointee.GetTensorMutableData(outVal, &rawDataPtr), operation: "GetTensorMutableData")

            let elemType = ORTTensorElementType(cType: cType)
            switch elemType {
            case .float32:
                var floats = [Float](repeating: 0, count: count)
                if count > 0, let rawDataPtr {
                    let src = rawDataPtr.assumingMemoryBound(to: Float.self)
                    floats.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress?.update(from: src, count: count)
                    }
                }
                results[name] = ORTTensorOutput(shape: shape, elementType: elemType, floatData: floats, int64Data: [])
            case .int64:
                var ints = [Int64](repeating: 0, count: count)
                if count > 0, let rawDataPtr {
                    let src = rawDataPtr.assumingMemoryBound(to: Int64.self)
                    ints.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress?.update(from: src, count: count)
                    }
                }
                results[name] = ORTTensorOutput(shape: shape, elementType: elemType, floatData: [], int64Data: ints)
            default:
                throw ORTError.unsupportedOutputType(name, elemType)
            }
        }

        return results
    }

    // MARK: - Helpers

    private static func createSession(
        modelURL: URL,
        provider: ORTExecutionProvider,
        intraOpThreads: Int32
    ) throws -> (OpaquePointer, String) {
        let env = try ORTEnvironment.acquire()
        let api = env.api
        var opts: OpaquePointer?
        try env.check(api.pointee.CreateSessionOptions(&opts), operation: "CreateSessionOptions")
        guard let opts else { throw ORTError.apiUnavailable }
        defer { api.pointee.ReleaseSessionOptions(opts) }

        try env.check(api.pointee.SetIntraOpNumThreads(opts, intraOpThreads), operation: "SetIntraOpNumThreads")

        var providerName = "CPU"
        if case .coreML(let cacheDir) = provider {
            let keys = [
                kCoremlProviderOption_ModelFormat,
                kCoremlProviderOption_MLComputeUnits,
                kCoremlProviderOption_EnableOnSubgraphs,
                cacheDir != nil ? kCoremlProviderOption_ModelCacheDirectory : nil,
            ].compactMap { $0 }
            let values: [String] = [
                "MLProgram",
                String(cString: kCoremlProviderOption_MLComputeUnits_ALL),
                "1",
                cacheDir?.path,
            ].compactMap { $0 }

            let keyCStrs: [UnsafeMutablePointer<CChar>?] = keys.map { strdup($0) }
            let valCStrs: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
            defer {
                keyCStrs.forEach { if let p = $0 { free(p) } }
                valCStrs.forEach { if let p = $0 { free(p) } }
            }
            let keyPtrs: [UnsafePointer<CChar>?] = keyCStrs.map { UnsafePointer($0) }
            let valPtrs: [UnsafePointer<CChar>?] = valCStrs.map { UnsafePointer($0) }
            let status = "CoreML".withCString { provCStr in
                keyPtrs.withUnsafeBufferPointer { kBuf in
                    valPtrs.withUnsafeBufferPointer { vBuf in
                        api.pointee.SessionOptionsAppendExecutionProvider(
                            opts,
                            provCStr,
                            kBuf.baseAddress,
                            vBuf.baseAddress,
                            keys.count
                        )
                    }
                }
            }
            try env.check(status, operation: "AppendExecutionProvider(CoreML)")
            providerName = "CoreML"
        }

        var sess: OpaquePointer?
        try modelURL.path.withCString { pathPtr in
            try env.check(api.pointee.CreateSession(env.env, pathPtr, opts, &sess), operation: "CreateSession(\(modelURL.lastPathComponent))")
        }
        guard let sess else { throw ORTError.apiUnavailable }
        return (sess, providerName)
    }

    private static func readIOInfos(session: OpaquePointer, isInput: Bool) throws -> [ORTTensorInfo] {
        let env = try ORTEnvironment.acquire()
        let api = env.api
        var count: Int = 0
        if isInput {
            try env.check(api.pointee.SessionGetInputCount(session, &count), operation: "SessionGetInputCount")
        } else {
            try env.check(api.pointee.SessionGetOutputCount(session, &count), operation: "SessionGetOutputCount")
        }

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try env.check(api.pointee.GetAllocatorWithDefaultOptions(&allocator), operation: "GetAllocatorWithDefaultOptions")
        guard let allocator else { throw ORTError.apiUnavailable }

        var infos: [ORTTensorInfo] = []
        infos.reserveCapacity(count)

        for index in 0..<count {
            var namePtr: UnsafeMutablePointer<CChar>?
            if isInput {
                try env.check(api.pointee.SessionGetInputName(session, index, allocator, &namePtr), operation: "SessionGetInputName")
            } else {
                try env.check(api.pointee.SessionGetOutputName(session, index, allocator, &namePtr), operation: "SessionGetOutputName")
            }
            let name = namePtr.map { String(cString: $0) } ?? "io_\(index)"
            if let namePtr {
                _ = api.pointee.AllocatorFree(allocator, namePtr)
            }

            var typeInfo: OpaquePointer?
            if isInput {
                try env.check(api.pointee.SessionGetInputTypeInfo(session, index, &typeInfo), operation: "SessionGetInputTypeInfo")
            } else {
                try env.check(api.pointee.SessionGetOutputTypeInfo(session, index, &typeInfo), operation: "SessionGetOutputTypeInfo")
            }
            guard let typeInfo else { continue }
            defer { api.pointee.ReleaseTypeInfo(typeInfo) }

            var tensorInfoPtr: OpaquePointer?
            try env.check(api.pointee.CastTypeInfoToTensorInfo(typeInfo, &tensorInfoPtr), operation: "CastTypeInfoToTensorInfo")
            guard let tensorInfoPtr else { continue }

            var elemType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try env.check(api.pointee.GetTensorElementType(tensorInfoPtr, &elemType), operation: "GetTensorElementType")
            var dimCount: Int = 0
            try env.check(api.pointee.GetDimensionsCount(tensorInfoPtr, &dimCount), operation: "GetDimensionsCount")
            var dims = [Int64](repeating: 0, count: dimCount)
            if dimCount > 0 {
                try dims.withUnsafeMutableBufferPointer { buf in
                    try env.check(api.pointee.GetDimensions(tensorInfoPtr, buf.baseAddress, dimCount), operation: "GetDimensions")
                }
            }
            infos.append(ORTTensorInfo(name: name, elementType: ORTTensorElementType(cType: elemType), shape: dims))
        }
        return infos
    }

    private static func elementCount(shape: [Int64]) -> Int {
        guard !shape.isEmpty else { return 1 }
        return shape.reduce(1) { partial, dim in
            partial * max(Int(dim), 0)
        }
    }
}
