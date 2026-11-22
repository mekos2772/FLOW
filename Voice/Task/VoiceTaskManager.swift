import Foundation

/// 纯原生 Swift ONNX 语音转换调度器（直跑 CoreML / CPU ONNX + Accelerate，无外部进程）。
@MainActor
final class VoiceTaskManager {
    struct QueuedJob: Sendable {
        let job: VoiceConversionJob
        let backend: any VoiceInferenceBackend
        let submitDate: Date
    }

    private let cache: VoiceCacheManager
    private let assets: VoiceModelAssetsManager
    private let engineRegistry: VoiceEngineRegistry
    private let backendRegistry: VoiceBackendRegistry
    private let allowNetwork: @Sendable () -> Bool
    private let mirrorConfigProvider: @Sendable () -> VoiceModelMirrorConfig
    private let onStateChanged: (@MainActor (String, VoiceTaskState) -> Void)?

    private let separator = MDXVocalSeparator()
    private let converter = RVCVoiceConverter()

    private var queue: [QueuedJob] = []
    private var activeJobID: String?
    private var activeTask: Task<Void, Never>?
    private var states: [String: VoiceTaskState] = [:]
    private var progresses: [String: VoiceTaskProgress] = [:]
    private var activeJobByTrack: [String: String] = [:]
    private var jobsByID: [String: VoiceConversionJob] = [:]

    init(
        cache: VoiceCacheManager,
        assets: VoiceModelAssetsManager,
        engineRegistry: VoiceEngineRegistry = .shared,
        backendRegistry: VoiceBackendRegistry = .shared,
        allowNetwork: @escaping @Sendable () -> Bool = { false },
        mirrorConfigProvider: @escaping @Sendable () -> VoiceModelMirrorConfig = { .default },
        onStateChanged: (@MainActor (String, VoiceTaskState) -> Void)? = nil
    ) {
        self.cache = cache
        self.assets = assets
        self.engineRegistry = engineRegistry
        self.backendRegistry = backendRegistry
        self.allowNetwork = allowNetwork
        self.mirrorConfigProvider = mirrorConfigProvider
        self.onStateChanged = onStateChanged
    }

    @discardableResult
    func enqueue(
        job: VoiceConversionJob,
        backend: (any VoiceInferenceBackend)? = nil,
        replacing: Bool = true
    ) throws -> String {
        guard engineRegistry.adapter(for: job.engineID) != nil else {
            throw VoiceError.engineNotRegistered(job.engineID)
        }
        if replacing, let oldID = activeJobByTrack[job.trackKey],
           let oldState = states[oldID], !oldState.isTerminal {
            cancel(jobID: oldID)
        }

        let chosenBackend = backend ?? backendRegistry.preferredBackend()
        let queued = QueuedJob(job: job, backend: chosenBackend, submitDate: Date())
        jobsByID[job.jobID] = job
        activeJobByTrack[job.trackKey] = job.jobID
        queue.append(queued)
        progresses[job.jobID] = VoiceTaskProgress(
            jobID: job.jobID,
            stage: .queued,
            fraction: 0,
            message: "已加入处理队列"
        )
        emit(job.jobID, .queued)
        pumpQueue()
        return job.jobID
    }

    func cancel(jobID: String) {
        if let idx = queue.firstIndex(where: { $0.job.jobID == jobID }) {
            let removed = queue.remove(at: idx)
            if activeJobByTrack[removed.job.trackKey] == jobID {
                activeJobByTrack.removeValue(forKey: removed.job.trackKey)
            }
            emit(jobID, .cancelled)
            return
        }

        if activeJobID == jobID {
            if let job = jobsByID[jobID], activeJobByTrack[job.trackKey] == jobID {
                activeJobByTrack.removeValue(forKey: job.trackKey)
            }
            // 先切换为终态 .cancelled，防止任务退出间隙被 .failed / .succeeded 覆盖
            emit(jobID, .cancelled)
            activeTask?.cancel()
        }
    }

    func cancelAll() {
        let queuedItems = queue
        queue.removeAll()
        for item in queuedItems {
            if activeJobByTrack[item.job.trackKey] == item.job.jobID {
                activeJobByTrack.removeValue(forKey: item.job.trackKey)
            }
            emit(item.job.jobID, .cancelled)
        }
        if let running = activeJobID {
            cancel(jobID: running)
        }
    }

    func state(for jobID: String) -> VoiceTaskState? { states[jobID] }
    func progress(for jobID: String) -> VoiceTaskProgress? { progresses[jobID] }
    func job(for jobID: String) -> VoiceConversionJob? { jobsByID[jobID] }

    func activeJob(for trackKey: String) -> (jobID: String, state: VoiceTaskState, progress: VoiceTaskProgress?)? {
        guard let id = activeJobByTrack[trackKey], let st = states[id] else { return nil }
        return (id, st, progresses[id])
    }

    func shutdown() {
        cancelAll()
        separator.unload()
        converter.unloadAll()
    }

    // MARK: - 串行执行循环

    private func pumpQueue() {
        guard activeJobID == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        start(next)
    }

    private func start(_ item: QueuedJob) {
        let job = item.job
        let backend = item.backend
        activeJobID = job.jobID
        updateRunning(jobID: job.jobID, stage: .decode, fraction: 0.02, message: "准备推理引擎 (\(backend.displayName))")

        let cache = self.cache
        let assets = self.assets
        let separator = self.separator
        let converter = self.converter
        let allowNetwork = self.allowNetwork
        let mirrorConfigProvider = self.mirrorConfigProvider
        let coremlCacheDir = cache.rootURL.appendingPathComponent("CoreMLCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: coremlCacheDir, withIntermediateDirectories: true)

        let progressReporter: @Sendable (VoiceTaskStage, Double, String?) -> Void = { [weak self] stage, fraction, message in
            Task { @MainActor in
                self?.updateRunning(jobID: job.jobID, stage: stage, fraction: fraction, message: message)
            }
        }

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let pipelineStart = Date()
            var metrics: [String: Double] = [:]

            do {
                let provider = backend.executionProvider(cacheDirectory: coremlCacheDir)
                let render = try await Self.executePipeline(
                    job: job,
                    provider: provider,
                    cache: cache,
                    assets: assets,
                    separator: separator,
                    converter: converter,
                    allowNetwork: allowNetwork,
                    mirrorConfig: mirrorConfigProvider(),
                    metrics: &metrics,
                    progress: progressReporter
                )
                metrics["totalSeconds"] = Date().timeIntervalSince(pipelineStart)
                await MainActor.run { [weak self] in
                    self?.finishJob(job: job, render: render, metrics: metrics)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.finishCancelled(job: job)
                }
            } catch ORTError.cancelled {
                await MainActor.run { [weak self] in
                    self?.finishCancelled(job: job)
                }
            } catch let err as VoiceError {
                await MainActor.run { [weak self] in
                    if case .cancelled = err {
                        self?.finishCancelled(job: job)
                    } else {
                        self?.finishFailed(job: job, error: err)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    if Task.isCancelled {
                        self?.finishCancelled(job: job)
                    } else {
                        self?.finishFailed(job: job, error: .inferenceFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    private static func executePipeline(
        job: VoiceConversionJob,
        provider: ORTExecutionProvider,
        cache: VoiceCacheManager,
        assets: VoiceModelAssetsManager,
        separator: MDXVocalSeparator,
        converter: RVCVoiceConverter,
        allowNetwork: @escaping @Sendable () -> Bool,
        mirrorConfig: VoiceModelMirrorConfig,
        metrics: inout [String: Double],
        progress: @escaping @Sendable (VoiceTaskStage, Double, String?) -> Void
    ) async throws -> VoiceRender {
        try Task.checkCancellation()

        let inputURL = URL(fileURLWithPath: job.inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path),
              VoiceAudioDSP.audioDurationSeconds(url: inputURL) > 0.05 else {
            throw VoiceError.io("原曲音频尚未完整缓存或无法解码：\(inputURL.lastPathComponent)")
        }

        let sepMode = job.parameters["separation_model"]?.stringValue ?? "mdx-vocals"
        let useMDX = sepMode != "none"

        // 若缺少或检测到不兼容旧版编码器（如原版 hubert-base-ls960），在允许联网时自动拉取 ContentVec 并校验；
        // 离线时给出明确的兼容提示，绝不放行错模型生成杂音。
        _ = await assets.verifyHubertCompatibilityIfNeeded()
        let mirror = mirrorConfig
        // 首次生成缺底座模型时先自动下载；进度写进任务状态，用户能看到下到哪儿了。
        func autoDownload(_ kind: VoiceModelAssetsManager.AssetKind, label: String, stage: VoiceTaskStage, at fraction: Double) async throws {
            progress(stage, fraction, "\(label)…")
            _ = try await assets.downloadAsset(kind, networkAllowed: allowNetwork, mirrorConfig: mirror) { pct in
                progress(stage, fraction, "\(label) \(Int((pct * 100).rounded()))%")
            }
        }
        if !assets.assetIsReady(.hubert) {
            if !allowNetwork(),
               let reason = assets.statusSummary().first(where: { $0.kind == .hubert })?.incompatibleReason {
                throw VoiceError.unsupportedModel(reason)
            }
            try Task.checkCancellation()
            try await autoDownload(.hubert, label: String(localized: "正在下载声音特征模型"), stage: .f0, at: 0.04)
        }
        if job.hasF0, !assets.assetIsReady(.rmvpe) {
            try Task.checkCancellation()
            try await autoDownload(.rmvpe, label: String(localized: "正在下载音高模型"), stage: .f0, at: 0.07)
        }
        if useMDX, !assets.assetIsReady(.mdxSeparator) {
            try Task.checkCancellation()
            try await autoDownload(.mdxSeparator, label: String(localized: "正在下载人声分离模型"), stage: .separate, at: 0.09)
        }

        let missing = assets.missingRequiredAssets(requiresF0: job.hasF0, requiresSeparation: useMDX)
        if !missing.isEmpty {
            throw VoiceError.missingBaseAssets(missing.map(\.fileName))
        }

        let rmvpeURL = assets.url(for: .rmvpe)
        let hubertURL = assets.url(for: .hubert)
        let mdxURL = assets.url(for: .mdxSeparator)

        // 阶段 1：一级缓存（人声/伴奏分离）
        var vocalsURL = inputURL
        var instURL: URL?

        if useMDX {
            if !job.separationKey.isEmpty, cache.separationExists(sepKey: job.separationKey) {
                vocalsURL = cache.vocalsURL(sepKey: job.separationKey)
                instURL = cache.instURL(sepKey: job.separationKey)
                metrics["separationCached"] = 1
                progress(.separate, 0.25, "命中分离缓存")
            } else {
                let t0 = Date()
                let targetVocals = job.vocalsPath.map(URL.init(fileURLWithPath:))
                    ?? cache.vocalsURL(sepKey: job.separationKey.isEmpty ? job.jobID : job.separationKey)
                let targetInst = job.accompanimentPath.map(URL.init(fileURLWithPath:))
                    ?? cache.instURL(sepKey: job.separationKey.isEmpty ? job.jobID : job.separationKey)

                let stagingVocals = targetVocals.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).vocals.wav")
                let stagingInst = targetInst.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).inst.wav")
                defer {
                    try? FileManager.default.removeItem(at: stagingVocals)
                    try? FileManager.default.removeItem(at: stagingInst)
                }

                let (overlap, enableDenoise): (Double, Bool) = switch job.qualityMode {
                case "fast": (0.15, false)
                case "best": (0.35, true)
                default: (0.25, false)
                }

                _ = try await separator.separate(
                    inputURL: inputURL,
                    vocalsOutputURL: stagingVocals,
                    instrumentalOutputURL: stagingInst,
                    modelURL: mdxURL,
                    provider: provider,
                    overlap: overlap,
                    enableDenoise: enableDenoise
                ) { frac in
                    progress(.separate, 0.05 + 0.27 * frac, "正在分离人声与伴奏")
                }

                try Task.checkCancellation()
                try moveReplacing(from: stagingVocals, to: targetVocals)
                try moveReplacing(from: stagingInst, to: targetInst)
                vocalsURL = targetVocals
                instURL = targetInst
                metrics["separationSeconds"] = Date().timeIntervalSince(t0)
            }
        }

        // 阶段 2：二级缓存（RVC 转换人声）
        let convTargetURL = job.convertedVocalsPath.map(URL.init(fileURLWithPath:))
            ?? (!job.conversionKey.isEmpty ? cache.convertedVocalsURL(convKey: job.conversionKey) : nil)

        var convertedMono: [Float]
        var convertedSR = job.sampleRate > 0 ? job.sampleRate : 40_000

        if !job.conversionKey.isEmpty, cache.conversionExists(convKey: job.conversionKey),
           let cachedConvURL = convTargetURL {
            progress(.convert, 0.85, "命中音色合成缓存")
            convertedMono = try VoiceAudioDSP.decodeMono(url: cachedConvURL, targetSampleRate: Double(convertedSR))
            metrics["conversionCached"] = 1
        } else {
            let t0 = Date()
            let params = RVCVoiceConverter.Parameters(
                f0UpKey: job.parameters["f0_up_key"]?.intValue ?? 0,
                indexRate: Float(job.parameters["index_rate"]?.doubleValue ?? 0.75),
                filterRadius: job.parameters["filter_radius"]?.intValue ?? 3,
                rmsMixRate: Float(job.parameters["rms_mix_rate"]?.doubleValue ?? 0.25),
                protect: Float(job.parameters["protect"]?.doubleValue ?? 0.33)
            )
            let result = try await converter.convertVocals(
                vocalsURL: vocalsURL,
                voiceModelURL: URL(fileURLWithPath: job.weightPath),
                indexURL: job.indexPath.map(URL.init(fileURLWithPath:)),
                rmvpeURL: rmvpeURL,
                hubertURL: hubertURL,
                expectedSampleRate: convertedSR,
                hasF0: job.hasF0,
                embeddingDim: job.embeddingDim,
                interChannels: job.interChannels,
                params: params,
                provider: provider
            ) { stage, subFrac, msg in
                let base = useMDX ? 0.32 : 0.05
                let span = useMDX ? 0.54 : 0.81
                progress(stage, base + span * subFrac, msg)
            }
            convertedMono = result.samples
            convertedSR = result.sampleRate
            metrics["conversionSeconds"] = Date().timeIntervalSince(t0)

            if let convTargetURL {
                let stagingConv = convTargetURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).conv.wav")
                defer { try? FileManager.default.removeItem(at: stagingConv) }
                try writeMonoWAV(samples: convertedMono, sampleRate: Double(convertedSR), to: stagingConv)
                try moveReplacing(from: stagingConv, to: convTargetURL)
            }
        }

        // 阶段 3：三级缓存（混音与导出 .m4a）
        try Task.checkCancellation()
        progress(.mix, 0.88, instURL != nil ? "正在与伴奏混音" : "准备导出音频")
        let tMix = Date()

        let finalLeft: [Float]
        let finalRight: [Float]
        let exportSR: Double

        if let instURL {
            exportSR = 44_100
            let inst = try VoiceAudioDSP.decodeStereo(url: instURL, targetSampleRate: exportSR)
            let vocalResampled = try VoiceAudioDSP.resample(convertedMono, from: Double(convertedSR), to: exportSR)
            let mixed = VoiceAudioDSP.mixVocalAndInstrumental(
                vocalLeft: vocalResampled,
                vocalRight: nil,
                instLeft: inst.left,
                instRight: inst.right
            )
            finalLeft = mixed.left
            finalRight = mixed.right
        } else {
            exportSR = Double(convertedSR)
            finalLeft = convertedMono
            finalRight = convertedMono
        }

        progress(.encode, 0.94, "正在写入渲染音频")
        let finalOutURL = URL(fileURLWithPath: job.outputPath)
        let stagingOut = finalOutURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: stagingOut) }

        let written = try VoiceAudioDSP.writeM4A(
            left: finalLeft,
            right: finalRight,
            sampleRate: exportSR,
            to: stagingOut
        )
        try Task.checkCancellation()
        try moveReplacing(from: written.url, to: finalOutURL)
        metrics["mixEncodeSeconds"] = Date().timeIntervalSince(tMix)

        let render = VoiceRender(
            trackKey: job.trackKey,
            cacheKey: job.renderKey.isEmpty
                ? finalOutURL.deletingPathExtension().lastPathComponent
                : job.renderKey,
            fileURL: finalOutURL,
            duration: written.duration,
            sampleRate: written.sampleRate,
            packID: job.packID,
            versionID: job.versionID,
            pipelineVersion: job.pipelineVersion
        )
        try cache.writeRenderManifest(render, metadata: VoiceCacheManager.RenderMetadata(
            track: job.track,
            packName: job.packName,
            separationKey: job.separationKey,
            conversionKey: job.conversionKey
        ))
        cache.enforceCapacity()
        return render
    }

    private func finishJob(job: VoiceConversionJob, render: VoiceRender, metrics: [String: Double]) {
        guard activeJobID == job.jobID else { return }
        defer {
            activeJobID = nil
            activeTask = nil
            pumpQueue()
        }
        if states[job.jobID] == .cancelled {
            try? FileManager.default.removeItem(at: render.fileURL)
            cache.removeCorruptedManifest(for: render.cacheKey)
            return
        }
        progresses[job.jobID] = VoiceTaskProgress(
            jobID: job.jobID,
            stage: .done,
            fraction: 1.0,
            message: "完成",
            metrics: metrics
        )
        if activeJobByTrack[job.trackKey] == job.jobID {
            activeJobByTrack.removeValue(forKey: job.trackKey)
        }
        emit(job.jobID, .succeeded(renderURL: render.fileURL, duration: render.duration, metrics: metrics))
    }

    private func finishCancelled(job: VoiceConversionJob) {
        if activeJobID == job.jobID {
            activeJobID = nil
            activeTask = nil
        }
        if activeJobByTrack[job.trackKey] == job.jobID {
            activeJobByTrack.removeValue(forKey: job.trackKey)
        }
        if states[job.jobID] != .cancelled {
            progresses[job.jobID] = VoiceTaskProgress(jobID: job.jobID, stage: .cancelled, fraction: 0, message: "已取消")
            emit(job.jobID, .cancelled)
        }
        pumpQueue()
    }

    private func finishFailed(job: VoiceConversionJob, error: VoiceError) {
        if activeJobID == job.jobID {
            activeJobID = nil
            activeTask = nil
        }
        if activeJobByTrack[job.trackKey] == job.jobID {
            activeJobByTrack.removeValue(forKey: job.trackKey)
        }
        if states[job.jobID] != .cancelled {
            progresses[job.jobID] = VoiceTaskProgress(
                jobID: job.jobID,
                stage: .failed,
                fraction: 0,
                message: error.localizedDescription
            )
            emit(job.jobID, .failed(error))
        }
        pumpQueue()
    }

    private func updateRunning(jobID: String, stage: VoiceTaskStage, fraction: Double, message: String?) {
        guard activeJobID == jobID, states[jobID] != .cancelled else { return }
        let clamped = min(max(fraction, 0), 0.99)
        progresses[jobID] = VoiceTaskProgress(jobID: jobID, stage: stage, fraction: clamped, message: message)
        emit(jobID, .running(stage: stage, fraction: clamped, message: message))
    }

    private func emit(_ jobID: String, _ state: VoiceTaskState) {
        states[jobID] = state
        onStateChanged?(jobID, state)
    }

    private static func moveReplacing(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            _ = try fm.replaceItemAt(dst, withItemAt: src)
        } else {
            try fm.moveItem(at: src, to: dst)
        }
    }

    private static func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        try VoiceAudioDSP.writeWAV(left: samples, right: nil, sampleRate: sampleRate, to: url)
    }
}
