import Foundation
import Observation

/// FLOW Voice 门面（全原生 Swift + ONNX Runtime）。
@MainActor
@Observable
final class VoiceManager {
    enum VoiceQualityMode: String, CaseIterable, Identifiable, Sendable {
        case fast
        case balanced
        case best

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fast: return "快速"
            case .balanced: return "均衡"
            case .best: return "精细降噪"
            }
        }
    }

    // MARK: - 持久化设置映射

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled, !showEntryInPlayer {
                showEntryInPlayer = true
            }
            onVoiceContextChanged?()
            Task { await settings.setVoiceAIEnabled(isEnabled) }
        }
    }

    /// 是否在播放器栏与沉浸胶囊显示「音色」快捷入口（完全卸载后自动隐藏，随时可在设置开启或导入恢复）。
    var showEntryInPlayer: Bool {
        didSet {
            guard oldValue != showEntryInPlayer else { return }
            Task { await settings.setVoiceEntryVisible(showEntryInPlayer) }
        }
    }

    var selectedPackID: String? {
        didSet {
            guard oldValue != selectedPackID else { return }
            invalidateRenderLookupCache()
            Task { await settings.setVoiceSelectedPackID(selectedPackID) }
        }
    }

    var qualityMode: VoiceQualityMode {
        didSet {
            guard oldValue != qualityMode else { return }
            invalidateRenderLookupCache()
            Task { await settings.setVoiceQualityMode(qualityMode.rawValue) }
        }
    }

    // MARK: - UI 响应式状态

    var packs: [VoicePackManifest] = []
    var progressByJob: [String: VoiceTaskProgress] = [:]
    var renders: [String: VoiceRender] = [:]
    var backendCapabilities: [VoiceBackendCapability] = []
    var assetStatuses: [VoiceModelAssetsManager.AssetStatus] = []
    var activeBackendName: String = "CPU (ONNX + Accelerate)"
    var cacheTotalBytes: Int64 = 0
    var packsTotalBytes: Int64 = 0
    var assetsTotalBytes: Int64 = 0
    var lastError: String?
    var trackErrors: [String: String] = [:]
    var isDownloadingAsset: VoiceModelAssetsManager.AssetKind?
    var assetDownloadProgress: [VoiceModelAssetsManager.AssetKind: Double] = [:]
    var isDownloadingAllBaseAssets: Bool = false
    var downloadingRemoteModelIDs: Set<String> = []
    var remoteModelDownloadProgress: [String: Double] = [:]
    var fetchingInputTrackKeys: Set<String> = []
    var mirrorMode: VoiceMirrorMode = .hfMirror
    var customHFMirror: String = VoiceModelMirrorConfig.defaultHFMirrorBase
    var customGitHubMirror: String = ""
    /// 离线页「AI 翻唱」列表的数据源：生成完成、删除、清空后自动刷新。
    private(set) var storedCovers: [StoredCover] = []

    /// 离线页的一条 AI 翻唱：同一首歌同一音色只列最新一份，旧参数生成的版本随它一起删除。
    struct StoredCover: Identifiable, Equatable, Sendable {
        let latest: VoiceCacheManager.StoredRender
        let cacheKeys: Set<String>
        let bytes: Int64

        var id: String { latest.id }
        var trackKey: String { latest.render.trackKey }
        var packID: String { latest.render.packID }
        var track: Track? { latest.metadata.track }
    }

    var mirrorConfig: VoiceModelMirrorConfig {
        VoiceModelMirrorConfig(
            mode: mirrorMode,
            customHFMirrorBase: customHFMirror,
            customGitHubPrefix: customGitHubMirror
        )
    }

    var isNetworkEnabled: Bool {
        settings.enableNetwork
    }

    var totalDiskFootprintBytes: Int64 {
        assetsTotalBytes + packsTotalBytes + cacheTotalBytes
    }

    var hasAnyLocalData: Bool {
        !packs.isEmpty || totalDiskFootprintBytes > 0 || assetStatuses.contains(where: \.exists)
    }

    var baseModelsReady: Bool {
        // 先读取 assetStatuses 保持 @Observable 视图依赖订阅，再直接按磁盘与兼容缓存实时核对，
        // 避免后台静默自动下载或外部替换模型后因内存快照未及时重扫而误报缺失。
        _ = assetStatuses
        return assets.assetIsReady(.rmvpe) && assets.assetIsReady(.hubert)
    }

    var hubertIncompatibleReason: String? {
        assetStatuses.first(where: { $0.kind == .hubert })?.incompatibleReason
    }

    var mdxSeparatorReady: Bool {
        _ = assetStatuses
        return assets.assetIsReady(.mdxSeparator)
    }

    // MARK: - 依赖

    let packStore: VoicePackStore
    let cache: VoiceCacheManager
    let assets: VoiceModelAssetsManager
    let discovery: VoiceModelDiscovery
    let presetStore: VoicePresetStore
    /// 在线音色卡片的中文译名缓存（系统翻译结果）。
    let nameTranslations: VoiceNameTranslations

    private let settings: any SettingsStoring
    private let engineRegistry: VoiceEngineRegistry
    private let backendRegistry: VoiceBackendRegistry
    private var activeBackend: (any VoiceInferenceBackend)?
    @ObservationIgnored
    private var tasks: VoiceTaskManager?
    @ObservationIgnored
    private var persistParamTask: Task<Void, Never>?
    @ObservationIgnored
    private var uncachedTrackKeys: Set<String> = []
    @ObservationIgnored
    private var isVerifyingHubert = false
    /// 从离线页点播时钉住的成品（trackKey → 成品）：播放它而不是按当前音色/参数匹配。
    @ObservationIgnored
    private var pinnedRenders: [String: VoiceRender] = [:]
    /// 进行中的底座/音色下载（id → 取消闭包）：卸载、关联网或用户点取消时统一叫停。
    @ObservationIgnored
    private var downloadCancellers: [String: @Sendable () -> Void] = [:]
    /// 用户点了「生成并播放 AI 版」但成品还没好：记下曲目，等这首渲染完成热切换时自动起播。
    /// 之前这个意图在"没命中缓存"的分支里被直接丢掉，生成完了却停在原曲不播。
    @ObservationIgnored
    private var pendingAutoplayTrackKey: String?

    var inputResolver: ((Track) async -> URL?)?
    var inputEnsurer: ((Track) async -> URL?)?
    var onVoiceContextChanged: (@MainActor () -> Void)?
    var onAttach: (@MainActor () -> Void)?
    var onPlayVersionRequested: (@MainActor (_ track: Track, _ autoplay: Bool) async -> Void)?
    /// 整首装载并起播（离线页点歌用，不是同曲切版本）。
    var onStartTrackRequested: (@MainActor (_ track: Track) async -> Void)?

    init(
        settings: any SettingsStoring,
        packStore: VoicePackStore,
        cache: VoiceCacheManager,
        assets: VoiceModelAssetsManager,
        presetStore: VoicePresetStore,
        discovery: VoiceModelDiscovery = VoiceModelDiscovery(),
        engineRegistry: VoiceEngineRegistry = .shared,
        backendRegistry: VoiceBackendRegistry = .shared
    ) {
        self.settings = settings
        self.isEnabled = settings.voiceAIEnabled
        self.showEntryInPlayer = settings.voiceEntryVisible
        self.selectedPackID = settings.voiceSelectedPackID
        self.qualityMode = VoiceQualityMode(rawValue: settings.voiceQualityMode) ?? .balanced
        let initialMirrorMode = VoiceMirrorMode(rawValue: settings.voiceMirrorModeRaw) ?? .hfMirror
        self.mirrorMode = initialMirrorMode
        self.customHFMirror = settings.voiceCustomHFMirror
        self.customGitHubMirror = settings.voiceCustomGitHubMirror
        self.packStore = packStore
        self.cache = cache
        self.assets = assets
        self.presetStore = presetStore
        self.nameTranslations = VoiceNameTranslations(
            fileURL: cache.rootURL.appendingPathComponent("name-translations.json")
        )
        self.discovery = discovery
        self.engineRegistry = engineRegistry
        self.backendRegistry = backendRegistry
        self.networkFlagBox = LockedBox(initial: settings.enableNetwork)
        self.mirrorConfigBox = LockedBox(initial: VoiceModelMirrorConfig(
            mode: initialMirrorMode,
            customHFMirrorBase: settings.voiceCustomHFMirror,
            customGitHubPrefix: settings.voiceCustomGitHubMirror
        ))
        reloadPacks()
        refreshEnvironmentStatus()
    }

    func attach() async {
        ensureTaskManager()
        _ = cache.pruneObsoletePipelineArtifacts()
        reloadPacks()
        reloadStoredCovers()
        refreshEnvironmentStatus()
        onAttach?()
        await verifyInstalledHubertInBackground()
    }

    private func ensureTaskManager() {
        guard tasks == nil else { return }
        let netBox = networkFlagBox
        let mirrorBox = mirrorConfigBox
        netBox.value = settings.enableNetwork
        mirrorBox.value = mirrorConfig
        tasks = VoiceTaskManager(
            cache: cache,
            assets: assets,
            engineRegistry: engineRegistry,
            backendRegistry: backendRegistry,
            allowNetwork: { netBox.value },
            mirrorConfigProvider: { mirrorBox.value },
            onStateChanged: { [weak self] jobID, state in
                self?.noteTaskState(jobID: jobID, state: state)
            }
        )
    }

    @ObservationIgnored
    private let networkFlagBox: LockedBox<Bool>
    @ObservationIgnored
    private let mirrorConfigBox: LockedBox<VoiceModelMirrorConfig>

    func refreshEnvironmentStatus() {
        networkFlagBox.value = settings.enableNetwork
        mirrorConfigBox.value = mirrorConfig
        backendCapabilities = backendRegistry.capabilities()
        let chosen = backendRegistry.preferredBackend()
        activeBackend = chosen
        activeBackendName = chosen.displayName
        assetStatuses = assets.statusSummary()
        cacheTotalBytes = cache.totalCacheBytes()
        packsTotalBytes = packStore.totalPacksBytes()
        assetsTotalBytes = assets.totalAssetsBytes()
        if !isVerifyingHubert,
           assetStatuses.first(where: { $0.kind == .hubert })?.exists == true,
           hubertIncompatibleReason == nil {
            Task { [weak self] in
                await self?.verifyInstalledHubertInBackground()
            }
        }
    }

    /// 异步校验本机已安装的 HuBERT 模型是否为真正 RVC ContentVec 编码器（首次检查，发现旧版原版 HuBERT 即阻断并提示重下）。
    func verifyInstalledHubertInBackground() async {
        guard !isVerifyingHubert else { return }
        isVerifyingHubert = true
        defer { isVerifyingHubert = false }
        let foundBad = await assets.verifyHubertCompatibilityIfNeeded()
        assetStatuses = assets.statusSummary()
        if foundBad, let reason = hubertIncompatibleReason {
            lastError = reason
            invalidateRenderLookupCache()
        }
    }

    func reloadPacks() {
        packs = (try? packStore.allPacks()) ?? []
        if let selected = selectedPackID,
           !packs.contains(where: { $0.packID == selected }) {
            selectedPackID = packs.first?.packID
        } else if selectedPackID == nil, let first = packs.first {
            selectedPackID = first.packID
        }
        packsTotalBytes = packStore.totalPacksBytes()
    }

    var selectedPack: VoicePackManifest? {
        if let id = selectedPackID, let hit = packs.first(where: { $0.packID == id }) {
            return hit
        }
        return packs.first
    }

    func selectPack(_ packID: String) {
        selectedPackID = packID
    }

    func coverURL(for pack: VoicePackManifest) -> URL? {
        packStore.coverURL(for: pack)
    }

    // MARK: - 音色包管理

    @discardableResult
    func importPack(
        weightURL: URL,
        displayName: String? = nil,
        indexURL: URL? = nil,
        coverURL: URL? = nil
    ) async throws -> VoicePackManifest {
        let manifest = try await packStore.importPack(
            weightURL: weightURL,
            indexURL: indexURL,
            coverURL: coverURL,
            displayName: displayName,
            engineID: "rvc",
            registry: engineRegistry
        )
        reloadPacks()
        selectedPackID = manifest.packID
        showEntryInPlayer = true
        return manifest
    }

    @discardableResult
    func addVersion(
        packID: String,
        versionName: String? = nil,
        weightURL: URL,
        indexURL: URL? = nil
    ) async throws -> VoicePackManifest {
        let manifest = try await packStore.addVersion(
            packID: packID,
            weightURL: weightURL,
            indexURL: indexURL,
            versionName: versionName,
            registry: engineRegistry
        )
        reloadPacks()
        invalidateRenderLookupCache()
        return manifest
    }

    func selectVersion(packID: String, versionID: String) throws {
        try packStore.selectVersion(packID: packID, versionID: versionID)
        reloadPacks()
        invalidateRenderLookupCache()
    }

    func deletePack(_ packID: String) throws {
        _ = try packStore.delete(packID: packID)
        renders = renders.filter { $0.value.packID != packID }
        reloadPacks()
    }

    func renamePack(_ packID: String, to displayName: String) throws {
        try packStore.rename(packID: packID, displayName: displayName)
        reloadPacks()
    }

    func setParameterOverrides(packID: String, overrides: [String: VoiceParameterValue]) throws {
        try packStore.setParameterOverrides(packID: packID, overrides: overrides)
        reloadPacks()
        invalidateRenderLookupCache()
    }

    /// UI 滑动条实时调整：立即刷新内存参数并节流（250ms）落盘。
    func setParameterOverride(packID: String, key: String, value: VoiceParameterValue) {
        guard let idx = packs.firstIndex(where: { $0.packID == packID }) else { return }
        var overrides = packs[idx].parameterOverrides
        overrides[key] = value
        packs[idx].parameterOverrides = overrides
        invalidateRenderLookupCache()

        persistParamTask?.cancel()
        persistParamTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            try? self.packStore.setParameterOverrides(packID: packID, overrides: overrides)
        }
    }

    func parameterValue(
        packID: String,
        key: String,
        default defaultValue: VoiceParameterValue
    ) -> VoiceParameterValue {
        guard let pack = packs.first(where: { $0.packID == packID }) else { return defaultValue }
        return pack.parameterOverrides[key] ?? defaultValue
    }

    func parameterSpecs(for pack: VoicePackManifest) -> [VoiceParameterSpec] {
        engineRegistry.adapter(for: pack.engineID)?.parameterSpecs ?? []
    }

    func applyPreset(_ preset: VoiceProcessingPreset) throws {
        guard let pack = selectedPack else { return }
        var overrides = pack.parameterOverrides
        for (k, v) in preset.parameters { overrides[k] = v }
        try packStore.setParameterOverrides(packID: pack.packID, overrides: overrides)
        if let raw = preset.suggestedQualityMode,
           let mode = VoiceQualityMode(rawValue: raw) {
            qualityMode = mode
        }
        reloadPacks()
        invalidateRenderLookupCache()
    }

    // MARK: - 模型资产与缓存管理

    /// 计算图检查与几百 MB 的 SHA256 放到后台，别卡住设置窗口。
    func importBaseAsset(from sourceURL: URL, kind: VoiceModelAssetsManager.AssetKind) async throws {
        let assets = self.assets
        _ = try await Task.detached(priority: .userInitiated) {
            try assets.importAsset(from: sourceURL, kind: kind)
        }.value
        showEntryInPlayer = true
        refreshEnvironmentStatus()
    }

    static func assetDownloadID(_ kind: VoiceModelAssetsManager.AssetKind) -> String {
        "asset:\(kind.rawValue)"
    }

    func downloadBaseAsset(_ kind: VoiceModelAssetsManager.AssetKind) async throws {
        isDownloadingAsset = kind
        assetDownloadProgress[kind] = 0
        defer {
            isDownloadingAsset = nil
            assetDownloadProgress[kind] = nil
        }
        let activeMirror = mirrorConfig
        mirrorConfigBox.value = activeMirror
        networkFlagBox.value = settings.enableNetwork
        let netBox = networkFlagBox
        let assets = self.assets
        try await trackDownload(Self.assetDownloadID(kind)) { [weak self] in
            _ = try await assets.downloadAsset(
                kind,
                networkAllowed: { netBox.value },
                mirrorConfig: activeMirror
            ) { pct in
                Task { @MainActor in
                    self?.assetDownloadProgress[kind] = pct
                }
            }
        }
        showEntryInPlayer = true
        refreshEnvironmentStatus()
    }

    // MARK: - 下载生命周期

    private func trackDownload<T: Sendable>(
        _ id: String,
        _ work: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { @MainActor in try await work() }
        let cancelled = LockedBox(initial: false)
        downloadCancellers[id] = {
            cancelled.value = true
            task.cancel()
        }
        defer { downloadCancellers[id] = nil }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancelled.value = true
            task.cancel()
        }
        // 取消请求恰好落在下载完成之后：结果作废，别让卸载后的东西又装回来。
        if cancelled.value { throw CancellationError() }
        return value
    }

    func cancelDownload(_ id: String) {
        downloadCancellers[id]?()
    }

    func cancelAllDownloads() {
        for cancel in downloadCancellers.values { cancel() }
    }

    /// 「允许联网」变化：同步给下载与任务读取的开关；关掉时叫停所有进行中的下载。
    func networkSettingChanged() {
        networkFlagBox.value = settings.enableNetwork
        if !settings.enableNetwork {
            cancelAllDownloads()
        }
    }

    /// 导入设置备份后重新读取持久化的 Voice 设置。
    func reloadSettings() {
        isEnabled = settings.voiceAIEnabled
        showEntryInPlayer = settings.voiceEntryVisible
        qualityMode = VoiceQualityMode(rawValue: settings.voiceQualityMode) ?? .balanced
        if let stored = settings.voiceSelectedPackID, packs.contains(where: { $0.packID == stored }) {
            selectedPackID = stored
        }
        mirrorMode = VoiceMirrorMode(rawValue: settings.voiceMirrorModeRaw) ?? .hfMirror
        customHFMirror = settings.voiceCustomHFMirror
        customGitHubMirror = settings.voiceCustomGitHubMirror
        refreshEnvironmentStatus()
    }

    /// 生成前置是否满足：选了音色，且底座已就绪或允许联网（生成任务会先自动补齐缺的底座模型）。
    var canStartGeneration: Bool {
        selectedPack != nil && (baseModelsReady || isNetworkEnabled)
    }

    /// 一键自动获取所有尚未就绪的底座 ONNX 模型（RMVPE / HuBERT-ContentVec / MDX）。
    func downloadAllMissingBaseAssets() async throws {
        guard settings.enableNetwork else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法自动获取底座模型。")
        }
        isDownloadingAllBaseAssets = true
        defer { isDownloadingAllBaseAssets = false }
        for kind in VoiceModelAssetsManager.AssetKind.allCases where !assets.assetIsReady(kind) {
            try Task.checkCancellation()
            try await downloadBaseAsset(kind)
        }
    }

    // MARK: - 镜像源与远端音色自动检索、下载直连导入

    func setMirrorMode(_ mode: VoiceMirrorMode) {
        guard mirrorMode != mode else { return }
        mirrorMode = mode
        mirrorConfigBox.value = mirrorConfig
        let raw = mode.rawValue
        Task { await settings.setVoiceMirrorModeRaw(raw) }
    }

    func setCustomHFMirror(_ value: String) {
        let normalized = VoiceModelMirrorConfig.normalizedBaseURLString(
            value,
            fallback: VoiceModelMirrorConfig.defaultHFMirrorBase
        )
        customHFMirror = normalized
        mirrorConfigBox.value = mirrorConfig
        Task { await settings.setVoiceCustomHFMirror(normalized) }
    }

    func setCustomGitHubMirror(_ value: String) {
        let normalized = VoiceModelMirrorConfig.normalizedOptionalPrefix(value)
        customGitHubMirror = normalized
        mirrorConfigBox.value = mirrorConfig
        Task { await settings.setVoiceCustomGitHubMirror(normalized) }
    }

    func searchVoiceModelRepos(
        query: String,
        platform: VoiceModelSearchPlatform
    ) async throws -> [VoiceModelRepoSummary] {
        let netBox = networkFlagBox
        netBox.value = settings.enableNetwork
        return try await discovery.searchRepositories(
            query: query,
            platform: platform,
            mirrorConfig: mirrorConfig,
            allowNetwork: { netBox.value }
        )
    }

    func inspectVoiceModelRepo(_ repo: VoiceModelRepoSummary) async throws -> [VoiceModelRemoteFile] {
        let netBox = networkFlagBox
        netBox.value = settings.enableNetwork
        return try await discovery.inspectRepository(
            repo,
            mirrorConfig: mirrorConfig,
            allowNetwork: { netBox.value }
        )
    }

    /// 自动获取「精选」页卡片：检索 HuggingFace 上含可运行音色的仓库并读取详情。
    /// 连不上或关了联网时 `reachable == false`，界面用内置清单兜底。
    func discoverOnlineVoices(maxRepos: Int = 6) async -> (files: [VoiceModelRemoteFile], reachable: Bool) {
        guard settings.enableNetwork else { return ([], false) }
        var repos: [VoiceModelRepoSummary] = []
        var reachable = false
        for query in OnlineVoiceCatalog.searchQueries {
            guard !Task.isCancelled else { break }
            guard let found = try? await searchVoiceModelRepos(query: query, platform: .huggingFace) else { continue }
            reachable = true
            for repo in found where !repos.contains(where: { $0.id == repo.id }) {
                repos.append(repo)
            }
        }
        var files: [VoiceModelRemoteFile] = []
        for repo in repos.prefix(maxRepos) {
            guard !Task.isCancelled else { break }
            if let found = try? await inspectVoiceModelRepo(repo) {
                files.append(contentsOf: found)
            }
        }
        return (files, reachable)
    }

    /// 已导入的音色里有没有这个远端音色：按模型文件 SHA256 认，用户改过名也认得出来。
    func importedPack(for file: VoiceModelRemoteFile) -> VoicePackManifest? {
        let modelSHA = file.sha256
            ?? file.packFiles?.first { $0.name.lowercased().hasSuffix(".onnx") }?.sha256
        guard let sha = modelSHA?.lowercased(), !sha.isEmpty else { return nil }
        return packs.first { pack in
            pack.versions.contains { $0.weightFingerprint.lowercased() == sha }
        }
    }

    @discardableResult
    func downloadAndImportRemoteModel(_ file: VoiceModelRemoteFile, displayName: String? = nil) async throws -> VoicePackManifest {
        try await downloadAndImportRemote(
            trackingID: file.id,
            url: file.downloadURL,
            suggestedFileName: file.fileName,
            displayName: displayName ?? file.displayName,
            expectedSHA256: file.sha256,
            companionIndexURL: file.companionIndexURL,
            inferCompanionIndex: false,
            packFiles: file.packFiles
        )
    }

    @discardableResult
    func downloadAndImportPack(
        from url: URL,
        displayName: String? = nil
    ) async throws -> VoicePackManifest {
        try await downloadAndImportRemote(
            trackingID: "direct:\(url.absoluteString)",
            url: url,
            suggestedFileName: url.lastPathComponent,
            displayName: displayName,
            expectedSHA256: nil,
            companionIndexURL: nil
        )
    }

    private func downloadAndImportRemote(
        trackingID: String,
        url: URL,
        suggestedFileName: String?,
        displayName: String?,
        expectedSHA256: String?,
        companionIndexURL: URL?,
        inferCompanionIndex: Bool = true,
        packFiles: [VoiceModelRemoteFile.PackFile]? = nil
    ) async throws -> VoicePackManifest {
        guard !downloadingRemoteModelIDs.contains(trackingID) else {
            throw VoiceError.io(String(localized: "这个音色正在下载，请稍候。"))
        }
        let netBox = networkFlagBox
        netBox.value = settings.enableNetwork
        downloadingRemoteModelIDs.insert(trackingID)
        remoteModelDownloadProgress[trackingID] = 0
        defer {
            downloadingRemoteModelIDs.remove(trackingID)
            remoteModelDownloadProgress[trackingID] = nil
        }

        let discovery = self.discovery
        let mirror = mirrorConfig
        let payload = try await trackDownload(trackingID) { [weak self] in
            try await discovery.downloadRemoteModel(
                from: url,
                suggestedFileName: suggestedFileName,
                displayName: displayName,
                expectedSHA256: expectedSHA256,
                companionIndexURL: companionIndexURL,
                inferCompanionIndex: inferCompanionIndex,
                packFiles: packFiles,
                mirrorConfig: mirror,
                allowNetwork: { netBox.value }
            ) { pct in
                Task { @MainActor in
                    self?.remoteModelDownloadProgress[trackingID] = pct
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: payload.stagingDirectory) }

        return try await importPack(
            weightURL: payload.modelFileURL,
            displayName: payload.inferredDisplayName,
            indexURL: payload.indexFileURL
        )
    }

    @discardableResult
    func removeBaseAsset(_ kind: VoiceModelAssetsManager.AssetKind) throws -> Int64 {
        let freed = try assets.removeAsset(kind)
        refreshEnvironmentStatus()
        onVoiceContextChanged?()
        return freed
    }

    @discardableResult
    func clearAllCache() throws -> Int64 {
        // 有转换在跑时不能清：任务正握着分离/转换中间文件，删掉会让它当场失败。
        guard !isConverting else { throw VoiceError.cacheBusy }
        let freed = try cache.clearAll()
        renders.removeAll()
        pinnedRenders.removeAll()
        progressByJob.removeAll()
        trackErrors.removeAll()
        uncachedTrackKeys.removeAll()
        lastError = nil
        reloadStoredCovers()
        refreshEnvironmentStatus()
        // 正在播的 AI 版文件已被删掉：让播放端退回原曲。
        onVoiceContextChanged?()
        return freed
    }

    // MARK: - 离线页：AI 翻唱成品管理

    func reloadStoredCovers() {
        var groups: [String: [VoiceCacheManager.StoredRender]] = [:]
        var order: [String] = []
        for stored in cache.storedRenders() {
            let groupKey = "\(stored.render.trackKey)|\(stored.render.packID)"
            if groups[groupKey] == nil { order.append(groupKey) }
            groups[groupKey, default: []].append(stored)
        }
        storedCovers = order.compactMap { groupKey in
            guard let items = groups[groupKey], let latest = items.first else { return nil }
            return StoredCover(
                latest: latest,
                cacheKeys: Set(items.map(\.id)),
                bytes: items.reduce(0) { $0 + $1.bytes }
            )
        }
    }

    /// 优先用音色包当前的名字（改名后同步），包已删除时退回生成时记下的名字。
    func packName(for cover: StoredCover) -> String {
        packs.first { $0.packID == cover.packID }?.displayName
            ?? cover.latest.metadata.packName
            ?? String(localized: "已删除的音色")
    }

    /// 从离线页播放：钉住列表里每首歌的这份成品（不受当前所选音色与参数影响），再整首起播点中的那首。
    func playStoredCover(_ cover: StoredCover, track: Track, queue: [StoredCover]) async {
        for item in queue.reversed() {
            pinnedRenders[item.trackKey] = item.latest.render
        }
        pinnedRenders[cover.trackKey] = cover.latest.render
        if !isEnabled {
            isEnabled = true
        }
        await onStartTrackRequested?(track)
    }

    /// 删除 AI 翻唱（含同曲同音色的旧版本与只属于它们的中间文件），返回释放的字节数。
    /// 有转换在跑时中间文件一律不动：进行中的任务可能正复用这些分离结果。
    @discardableResult
    func deleteStoredCovers(_ covers: [StoredCover]) -> Int64 {
        let keys = covers.reduce(into: Set<String>()) { $0.formUnion($1.cacheKeys) }
        guard !keys.isEmpty else { return 0 }
        let freed = cache.removeRenders(cacheKeys: keys,
                                        sweepWhenEmpty: !isConverting,
                                        keepIntermediates: isConverting)
        renders = renders.filter { !keys.contains($0.value.cacheKey) }
        pinnedRenders = pinnedRenders.filter { !keys.contains($0.value.cacheKey) }
        reloadStoredCovers()
        refreshEnvironmentStatus()
        onVoiceContextChanged?()
        return freed
    }

    /// 进度表只保存排队中/进行中的任务（终态即移除）。
    var isConverting: Bool {
        !progressByJob.isEmpty
    }

    /// 完全卸载 FLOW Voice 本地组件与数据：取消在途任务、清除底座 ONNX 模型、音色包、三级缓存与自定义预设，
    /// 并可隐藏播放栏入口，将占用归零并退回初始选装未安装状态。
    @discardableResult
    func uninstallAll(hidePlayerEntry: Bool = true) throws -> Int64 {
        persistParamTask?.cancel()
        tasks?.cancelAll()
        cancelAllDownloads()
        isEnabled = false
        selectedPackID = nil
        let freedCache = try cache.clearAll()
        let freedPacks = try packStore.deleteAll()
        let freedAssets = try assets.removeAllAssets()
        try? presetStore.resetCustomPresets()
        renders.removeAll()
        pinnedRenders.removeAll()
        storedCovers = []
        progressByJob.removeAll()
        trackErrors.removeAll()
        uncachedTrackKeys.removeAll()
        lastError = nil
        if hidePlayerEntry {
            showEntryInPlayer = false
        }
        reloadPacks()
        refreshEnvironmentStatus()
        onVoiceContextChanged?()
        return freedCache + freedPacks + freedAssets
    }

    // MARK: - 渲染请求 / 取消 / 查询

    func errorMessage(for track: Track) -> String? {
        trackErrors[TrackIdentity.storageKey(track.identity)]
    }

    /// 显式触发 AI 翻唱渲染。
    /// - Parameter force: 为 `true` 时绕过并清理现有渲染/转换人声缓存，强制重新合成（保留人声分离缓存）。
    func requestRender(for track: Track, force: Bool = false) async throws -> VoiceRender? {
        let key = TrackIdentity.storageKey(track.identity)
        if !force, let hit = await resolvePlayableRender(for: track) {
            return hit
        }
        var url = await inputResolver?(track)
        if url == nil, let inputEnsurer {
            fetchingInputTrackKeys.insert(key)
            defer { fetchingInputTrackKeys.remove(key) }
            url = await inputEnsurer(track)
        }
        guard let url else {
            let message = String(localized: "原曲音频尚未获取完成，请等待缓冲完成后再生成 AI 翻唱。")
            uncachedTrackKeys.insert(key)
            trackErrors[key] = message
            lastError = message
            throw VoiceError.io(message)
        }
        return try await requestRender(for: track, inputAudioURL: url, force: force)
    }

    /// 只由用户显式操作触发（生成/重新生成/切到 AI 版）；切歌与搜索播放从不自动入队。
    func requestRender(for track: Track, inputAudioURL: URL, force: Bool = false) async throws -> VoiceRender? {
        try await enqueueRender(for: track, inputAudioURL: inputAudioURL, force: force)
    }

    private func enqueueRender(
        for track: Track,
        inputAudioURL: URL,
        force: Bool
    ) async throws -> VoiceRender? {
        ensureTaskManager()
        networkFlagBox.value = settings.enableNetwork

        guard let pack = selectedPack, let version = pack.selectedVersion else {
            throw VoiceError.invalidManifest(reason: "未选中有效音色包")
        }
        guard let adapter = engineRegistry.adapter(for: pack.engineID) else {
            throw VoiceError.engineNotRegistered(pack.engineID)
        }
        let backend = activeBackend ?? backendRegistry.preferredBackend()

        let key = TrackIdentity.storageKey(track.identity)
        uncachedTrackKeys.remove(key)
        // 用户要按当前音色重新生成：离线页钉住的旧成品让位。
        pinnedRenders.removeValue(forKey: key)
        trackErrors.removeValue(forKey: key)
        lastError = nil

        let keys = try await cacheKeys(
            for: track,
            pack: pack,
            version: version,
            inputAudioURL: inputAudioURL,
            backendID: backend.id
        )

        if force {
            renders.removeValue(forKey: key)
            cache.invalidateRenderAndConversion(conversionKey: keys.conversionKey, renderKey: keys.renderKey)
        } else {
            do {
                if let hit = try cache.render(for: keys.renderKey) {
                    renders[key] = hit
                    trackErrors.removeValue(forKey: key)
                    return hit
                }
            } catch VoiceError.cacheCorrupted {
                cache.removeCorruptedManifest(for: keys.renderKey)
            }
        }

        let jobParams = adapter.normalizeParameters(pack.parameterOverrides)
        let weightURL = packStore.weightURL(for: pack, version: version)
        let indexURL = packStore.indexURL(for: pack, version: version)
        let sepKey = keys.separationKey

        let job = VoiceConversionJob(
            jobID: UUID().uuidString,
            trackKey: key,
            inputPath: inputAudioURL.path,
            vocalsPath: cache.vocalsURL(sepKey: sepKey).path,
            accompanimentPath: cache.instURL(sepKey: sepKey).path,
            convertedVocalsPath: cache.convertedVocalsURL(convKey: keys.conversionKey).path,
            outputPath: cache.renderURL(renderKey: keys.renderKey).path,
            separationKey: sepKey,
            conversionKey: keys.conversionKey,
            renderKey: keys.renderKey,
            packID: pack.packID,
            versionID: version.id,
            engineID: pack.engineID,
            weightPath: weightURL.path,
            indexPath: indexURL?.path,
            sampleRate: version.sampleRate,
            hasF0: version.hasF0,
            embeddingDim: version.embeddingDim,
            interChannels: version.interChannels,
            parameters: jobParams,
            qualityMode: qualityMode.rawValue,
            pipelineVersion: VoiceCacheManager.pipelineVersion,
            track: track,
            packName: pack.displayName
        )

        _ = try tasks?.enqueue(job: job, backend: backend, replacing: true)
        return nil
    }

    func cancelRender(trackKey: String) {
        if let active = tasks?.activeJob(for: trackKey) {
            tasks?.cancel(jobID: active.jobID)
            progressByJob.removeValue(forKey: active.jobID)
        }
    }

    func existingRender(for track: Track) -> VoiceRender? {
        let key = TrackIdentity.storageKey(track.identity)
        guard let hit = renders[key] else { return nil }
        if let pack = selectedPack,
           (hit.packID != pack.packID || hit.versionID != pack.selectedVersion?.id) {
            return nil
        }
        return hit
    }

    /// 检查当前曲目是否已有可播的 AI 渲染成品（优先精确参数+文件指纹匹配；原曲流缓存丢失时回退扫描清单）。
    @discardableResult
    func resolvePlayableRender(
        for track: Track,
        inputResolver overrideResolver: ((Track) async -> URL?)? = nil
    ) async -> VoiceRender? {
        let key = TrackIdentity.storageKey(track.identity)
        if let pinned = pinnedRenders[key] {
            if FileManager.default.fileExists(atPath: pinned.fileURL.path) {
                renders[key] = pinned
                trackErrors.removeValue(forKey: key)
                return pinned
            }
            pinnedRenders.removeValue(forKey: key)
        }
        guard let pack = selectedPack,
              let version = pack.selectedVersion else {
            return nil
        }
        let activeResolver = overrideResolver ?? self.inputResolver
        if let inputURL = await activeResolver?(track) {
            if uncachedTrackKeys.remove(key) != nil {
                trackErrors.removeValue(forKey: key)
            }
            let backendID = (activeBackend ?? backendRegistry.preferredBackend()).id
            if let keys = try? await cacheKeys(
                for: track,
                pack: pack,
                version: version,
                inputAudioURL: inputURL,
                backendID: backendID
            ) {
                do {
                    if let hit = try cache.render(for: keys.renderKey),
                       FileManager.default.fileExists(atPath: hit.fileURL.path) {
                        renders[key] = hit
                        trackErrors.removeValue(forKey: key)
                        return hit
                    }
                } catch VoiceError.cacheCorrupted {
                    cache.removeCorruptedManifest(for: keys.renderKey)
                } catch {}
                renders.removeValue(forKey: key)
                return nil
            }
        }
        if let fallback = cache.latestRender(forTrackKey: key, packID: pack.packID, versionID: version.id) {
            renders[key] = fallback
            trackErrors.removeValue(forKey: key)
            return fallback
        }
        renders.removeValue(forKey: key)
        return nil
    }

    /// 播放端能否走 AI 版：总开关打开，且底座模型齐备或这首歌有离线页钉住的现成成品（播成品不需要模型）。
    func canRouteToVoice(_ track: Track) -> Bool {
        guard isEnabled else { return false }
        return baseModelsReady || pinnedRenders[TrackIdentity.storageKey(track.identity)] != nil
    }

    /// 异步刷新某首歌在当前音色与参数下磁盘缓存是否命中（关闭总开关时同样检查，供播放切换控件展示可用状态）。
    func refreshRenderAvailability(for track: Track) async {
        _ = await resolvePlayableRender(for: track)
    }

    /// 切回播放原曲。
    func switchToOriginalPlayback(for track: Track? = nil, autoplay: Bool = false) async {
        RedactingLog.info("voice switchToOriginal requested autoplay=\(autoplay) hasTrack=\(track != nil) hasHandler=\(onPlayVersionRequested != nil)")
        // 用户改主意要原曲了：之前挂着的"生成完自动播 AI 版"作废。
        pendingAutoplayTrackKey = nil
        if isEnabled {
            isEnabled = false
        }
        if autoplay, let track {
            await onPlayVersionRequested?(track, true)
        }
    }

    /// 切换到播放 AI 翻唱（若尚无成品且前置就绪，则拉取原声并自动排队生成，就绪后自动热切换）。
    func switchToVoicePlayback(for track: Track, autoplay: Bool = true) async throws {
        let hit = await resolvePlayableRender(for: track)
        if !isEnabled {
            isEnabled = true
        }
        if let hit {
            RedactingLog.info("voice switchToVoice cache hit pack=\(hit.packID) hasHandler=\(onPlayVersionRequested != nil) autoplay=\(autoplay)")
            await onPlayVersionRequested?(track, autoplay)
            return
        }
        let key = TrackIdentity.storageKey(track.identity)
        // 还没成品：把"生成好就自动播"记下来，等这首渲染完成热切换时消费（缓存命中时当场就播了）。
        pendingAutoplayTrackKey = autoplay ? key : nil
        if let active = tasks?.activeJob(for: key), !active.state.isTerminal {
            RedactingLog.info("voice switchToVoice active job exists autoplay=\(autoplay)")
            return
        }
        RedactingLog.info("voice switchToVoice cache miss, requesting render autoplay=\(autoplay)")
        _ = try await requestRender(for: track, force: false)
    }

    /// 热切换时调用：若这首正是用户要求"生成完就播"的，消费掉标记并返回 true。
    func consumePendingAutoplay(for trackKey: String) -> Bool {
        guard pendingAutoplayTrackKey == trackKey else { return false }
        pendingAutoplayTrackKey = nil
        return true
    }

    func taskInfo(for track: Track) -> (state: VoiceTaskState, progress: VoiceTaskProgress?)? {
        let key = TrackIdentity.storageKey(track.identity)
        guard let active = tasks?.activeJob(for: key) else { return nil }
        let p = progressByJob[active.jobID] ?? active.progress
        return (active.state, p)
    }

    func shutdown() {
        persistParamTask?.cancel()
        tasks?.shutdown()
    }

    // MARK: - 缓存键计算

    struct CacheKeys: Sendable {
        var audioFP: String
        var separationKey: String
        var conversionKey: String
        var renderKey: String
    }

    func cacheKeys(
        for track: Track,
        pack: VoicePackManifest,
        version: VoicePackVersion,
        inputAudioURL: URL,
        backendID: String? = nil
    ) async throws -> CacheKeys {
        let resolvedBackendID = backendID ?? (activeBackend ?? backendRegistry.preferredBackend()).id
        let adapter = engineRegistry.adapter(for: pack.engineID)
        let params = adapter?.normalizeParameters(pack.parameterOverrides) ?? pack.parameterOverrides
        let sepMode = params["separation_model"]?.stringValue ?? "mdx-vocals"
        let effectiveSepModel = sepMode == "none" ? "none" : "\(sepMode)-\(qualityMode.rawValue)"

        let audioFP = try await Task.detached(priority: .utility) {
            try VoiceCacheManager.audioFingerprint(of: inputAudioURL)
        }.value

        let sepKey = VoiceCacheManager.separationKey(
            audioFP: audioFP,
            separationModel: effectiveSepModel
        )
        let convKey = VoiceCacheManager.conversionKey(
            separationKey: sepKey,
            weightFP: version.weightFingerprint,
            indexFP: version.indexFingerprint,
            engineID: pack.engineID,
            parameters: params,
            backendID: resolvedBackendID
        )
        let renderKey = VoiceCacheManager.renderKey(
            conversionKey: convKey,
            instFingerprint: sepKey,
            mixSpec: "\(effectiveSepModel)|v2"
        )
        return CacheKeys(audioFP: audioFP, separationKey: sepKey, conversionKey: convKey, renderKey: renderKey)
    }

    // MARK: - Private

    private func clearPendingAutoplay(for trackKey: String) {
        if pendingAutoplayTrackKey == trackKey {
            pendingAutoplayTrackKey = nil
        }
    }

    private func invalidateRenderLookupCache() {
        renders.removeAll()
        // 换音色/版本/参数说明用户要按新设置播放，离线页钉住的成品不再优先。
        pinnedRenders.removeAll()
        onVoiceContextChanged?()
    }

    private func noteTaskState(jobID: String, state: VoiceTaskState) {
        switch state {
        case .queued:
            progressByJob[jobID] = VoiceTaskProgress(jobID: jobID, stage: .queued, fraction: 0, message: "排队中")
        case .running(let stage, let fraction, let message):
            progressByJob[jobID] = VoiceTaskProgress(jobID: jobID, stage: stage, fraction: fraction, message: message)
        case .succeeded(let renderURL, let duration, _):
            if let job = tasks?.job(for: jobID) {
                let render = VoiceRender(
                    trackKey: job.trackKey,
                    cacheKey: job.renderKey.isEmpty ? renderURL.deletingPathExtension().lastPathComponent : job.renderKey,
                    fileURL: renderURL,
                    duration: duration,
                    sampleRate: job.sampleRate,
                    packID: job.packID,
                    versionID: job.versionID,
                    pipelineVersion: job.pipelineVersion
                )
                renders[job.trackKey] = render
                trackErrors.removeValue(forKey: job.trackKey)
                uncachedTrackKeys.remove(job.trackKey)
            }
            progressByJob.removeValue(forKey: jobID)
            lastError = nil
            reloadStoredCovers()
            refreshEnvironmentStatus()
            onVoiceContextChanged?()
        case .failed(let err):
            progressByJob.removeValue(forKey: jobID)
            if let job = tasks?.job(for: jobID) {
                trackErrors[job.trackKey] = err.localizedDescription
                uncachedTrackKeys.remove(job.trackKey)
                clearPendingAutoplay(for: job.trackKey)
            }
            lastError = err.localizedDescription
            refreshEnvironmentStatus()
        case .cancelled:
            progressByJob.removeValue(forKey: jobID)
            if let job = tasks?.job(for: jobID) {
                clearPendingAutoplay(for: job.trackKey)
            }
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(initial: Value) {
        self._value = initial
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
