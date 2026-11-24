import Foundation
import Observation

/// 统一的多音源注册、启停、聚合搜索与扩展能力分发中心。
///
/// 表现层仅通过 `SourceManager` 与能力协议读取所有音源，彻底屏蔽具体平台实现。
@MainActor
@Observable
final class SourceManager: OfflineAudioResolving {
    struct ManagedSource: Identifiable {
        let id: SourceID
        var descriptor: SourceDescriptor
        var provider: any PlaybackSourceProvider
        var isEnabled: Bool
        var isBuiltIn: Bool
        var originLabel: String
        var accountController: (any SourceAccountController)?
        var qualityController: (any QualitySelectableSourceController)?
        var offlineResolver: (any OfflineAudioResolving)?
        var verifier: (@Sendable ([Track], (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track])?
        var visibilityFilter: (@MainActor @Sendable (Track) -> Bool)?
    }

    enum ImportFormat: String, Sendable {
        case jsPlugin
        case jsonTemplate
        case openSubsonic
        case webDAV
        case localDirectory
    }

    @ObservationIgnored let registry: SourceRegistry
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let networkEnabledProvider: @Sendable () -> Bool
    @ObservationIgnored private let preferredQualityProvider: @Sendable () -> AudioQualityTier?
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let serverConfigStore: ServerSourceConfigStore
    @ObservationIgnored private let importedStore: ImportedSourceStore
    @ObservationIgnored private let githubDiscovery: GitHubSourceDiscovery
    @ObservationIgnored private let externalPluginsDirectories: [URL]
    /// 可一键开启的预设。正式运行用内置目录；测试注入带远端地址的假预设，覆盖"远端获取 + 联网门控"这条路径。
    @ObservationIgnored private let apiPresets: [ExternalAPIPreset]
    @ObservationIgnored private let streamingAssetBuilder: StreamingAssetBuilder?
    @ObservationIgnored private(set) var localLibrary: LocalLibrarySource?
    @ObservationIgnored private var records: [SourceID: ManagedSource] = [:]
    @ObservationIgnored private var order: [SourceID] = []

    private(set) var sources: [ManagedSource] = []
    var activeBrowseSourceID: SourceID? {
        didSet { persistPreferences() }
    }
    var aggregateSearchEnabled: Bool {
        didSet { persistPreferences() }
    }
    var isNetworkEnabled: Bool {
        networkEnabledProvider()
    }
    private(set) var revision = 0

    /// Phase 3/4 将向此处挂载脚本 / 服务器 / 本地文件夹导入实现。
    @ObservationIgnored var importFileHandler: ((URL) async throws -> ManagedSource)?

    private static let activeBrowseKey = "sources.activeBrowseID"
    private static let aggregateSearchKey = "sources.aggregateSearch"
    private static let disabledSetKey = "sources.disabledIDs"

    init(registry: SourceRegistry,
         networkEnabledProvider: @escaping @Sendable () -> Bool = { true },
         preferredQualityProvider: @escaping @Sendable () -> AudioQualityTier? = { nil },
         defaults: UserDefaults = RuntimeSandbox.defaults,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         importedSourcesDirectory: URL = ImportedSourceStore.defaultDirectory,
         externalPluginsDirectories: [URL]? = nil,
         apiPresets: [ExternalAPIPreset] = ExternalAPIPresetCatalog.presets,
         session: URLSession = .shared,
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         hlsAssetBuilder: HLSAssetBuilder? = nil) {
        self.registry = registry
        self.networkEnabledProvider = networkEnabledProvider
        self.preferredQualityProvider = preferredQualityProvider
        self.defaults = defaults
        self.secrets = secrets
        self.serverConfigStore = ServerSourceConfigStore(defaults: defaults, secrets: secrets)
        self.importedStore = ImportedSourceStore(
            directory: importedSourcesDirectory,
            session: session,
            secrets: secrets,
            networkAllowed: networkEnabledProvider,
            streamingAssetBuilder: streamingAssetBuilder,
            hlsAssetBuilder: hlsAssetBuilder
        )
        self.githubDiscovery = GitHubSourceDiscovery(
            session: session,
            secrets: secrets,
            networkAllowed: networkEnabledProvider
        )
        self.externalPluginsDirectories = externalPluginsDirectories ?? ExternalAPIPresetCatalog.defaultExternalDirectories()
        self.apiPresets = apiPresets
        self.streamingAssetBuilder = streamingAssetBuilder
        let savedActive = defaults.string(forKey: Self.activeBrowseKey)
        self.activeBrowseSourceID = savedActive.map(SourceID.init(rawValue:))
        self.aggregateSearchEnabled = defaults.object(forKey: Self.aggregateSearchKey) as? Bool ?? true
    }

    var enabledSources: [ManagedSource] {
        sources.filter(\.isEnabled)
    }

    var nonMockSources: [ManagedSource] {
        sources.filter { $0.id != .mock }
    }

    /// 主界面可用于浏览/搜索的可用音源列表（过滤掉被用户禁用的源与关网时的纯网络源规则按需由页面呈现）。
    var browsableSources: [ManagedSource] {
        sources.filter { $0.isEnabled && $0.id != .mock }
    }

    var hasAnyConfiguredSource: Bool {
        !nonMockSources.isEmpty
    }

    var activeBrowseSource: ManagedSource? {
        if let activeBrowseSourceID,
           let matched = sources.first(where: { $0.id == activeBrowseSourceID && $0.isEnabled }) {
            return matched
        }
        return browsableSources.first ?? enabledSources.first
    }

    func managedSource(for id: SourceID) -> ManagedSource? {
        records[id]
    }

    func displayName(for sourceID: SourceID) -> String {
        if let managed = records[sourceID] {
            return managed.descriptor.displayName
        }
        if let registered = registry.provider(for: sourceID) {
            return registered.descriptor.displayName
        }
        switch sourceID {
        case .localFile: return String(localized: "本地音频")
        case .mock: return String(localized: "模拟源")
        default: return sourceID.rawValue
        }
    }

    func registerSource(_ provider: any PlaybackSourceProvider,
                        isBuiltIn: Bool = false,
                        originLabel: String = "",
                        accountController: (any SourceAccountController)? = nil,
                        qualityController: (any QualitySelectableSourceController)? = nil,
                        offlineResolver: (any OfflineAudioResolving)? = nil,
                        verifier: (@Sendable ([Track], (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track])? = nil,
                        visibilityFilter: (@MainActor @Sendable (Track) -> Bool)? = nil) {
        let id = provider.descriptor.id
        let disabledIDs = Set(defaults.stringArray(forKey: Self.disabledSetKey) ?? [])
        let enabled = records[id]?.isEnabled ?? !disabledIDs.contains(id.rawValue)

        let entry = ManagedSource(
            id: id,
            descriptor: provider.descriptor,
            provider: provider,
            isEnabled: enabled,
            isBuiltIn: isBuiltIn,
            originLabel: originLabel.isEmpty ? provider.descriptor.displayName : originLabel,
            accountController: accountController,
            qualityController: qualityController,
            offlineResolver: offlineResolver,
            verifier: verifier,
            visibilityFilter: visibilityFilter
        )
        if records[id] == nil {
            order.append(id)
        }
        records[id] = entry
        syncRegistry(for: entry)
        rebuildSnapshot()
    }

    func isTrackVisible(_ track: Track) -> Bool {
        if let filter = records[track.sourceID]?.visibilityFilter {
            return filter(track)
        }
        return true
    }

    func unregisterSource(_ id: SourceID) {
        records.removeValue(forKey: id)
        order.removeAll { $0 == id }
        registry.unregister(id)
        if activeBrowseSourceID == id {
            activeBrowseSourceID = browsableSources.first?.id
        }
        rebuildSnapshot()
    }

    func setSourceEnabled(_ id: SourceID, enabled: Bool) {
        guard var entry = records[id] else { return }
        entry.isEnabled = enabled
        records[id] = entry
        saveDisabledSet()
        syncRegistry(for: entry)
        if !enabled, activeBrowseSourceID == id {
            activeBrowseSourceID = browsableSources.first?.id
        } else if enabled, activeBrowseSourceID == nil, id != .mock {
            activeBrowseSourceID = id
        }
        rebuildSnapshot()
    }

    func selectActiveBrowseSource(_ id: SourceID) {
        guard records[id]?.isEnabled == true else { return }
        activeBrowseSourceID = id
        revision &+= 1
    }

    func syncNetworkState() {
        for id in order {
            if let entry = records[id] {
                syncRegistry(for: entry)
            }
        }
        revision &+= 1
    }

    // MARK: - 发现与搜索

    func discoverTracks(sourceID: SourceID? = nil,
                        limit: Int = 60,
                        progress: (@Sendable (TrackListBatch) -> Void)? = nil) async throws -> [Track] {
        guard let target = sourceID.flatMap({ records[$0] }) ?? activeBrowseSource else {
            return []
        }
        guard target.isEnabled else { return [] }
        if target.descriptor.requiresNetwork && !isNetworkEnabled {
            throw PlaybackError.networkDisabled
        }
        if let discoverable = target.provider as? any DiscoverableSourceProvider {
            return try await discoverable.discoverTracks(limit: limit, progress: progress)
        }
        return []
    }

    func canResolveQueryDirectly(_ query: String) -> Bool {
        enabledSources.contains { entry in
            guard let resolver = entry.provider as? any URLResolvableSourceProvider else { return false }
            return resolver.canHandleQuery(query)
        }
    }

    func search(query: String,
                aggregate: Bool? = nil,
                progress: (@Sendable (TrackListBatch) -> Void)? = nil) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        for entry in enabledSources {
            if let resolver = entry.provider as? any URLResolvableSourceProvider,
               resolver.canHandleQuery(trimmed) {
                if entry.descriptor.requiresNetwork && !isNetworkEnabled {
                    throw PlaybackError.networkDisabled
                }
                do {
                    let resolved = try await resolver.resolveQuery(trimmed)
                    if !resolved.isEmpty { return resolved }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 插件的 canHandleQuery 只是粗筛，普通关键词也可能被"认领"；
                    // 解析失败或返回空时交给后面的解析器和普通搜索，而不是直接给用户一个空结果。
                }
            }
        }

        let shouldAggregate = aggregate ?? aggregateSearchEnabled
        let candidates: [ManagedSource]
        if shouldAggregate {
            candidates = browsableSources.filter {
                $0.descriptor.supportsSearch && (!$0.descriptor.requiresNetwork || isNetworkEnabled)
            }
        } else if let active = activeBrowseSource, active.descriptor.supportsSearch {
            if active.descriptor.requiresNetwork && !isNetworkEnabled {
                return try await searchOfflineFallback(keyword: trimmed, preferredSource: active)
            }
            candidates = [active]
        } else {
            candidates = []
        }

        guard !candidates.isEmpty else {
            if !isNetworkEnabled {
                return try await searchOfflineFallback(keyword: trimmed, preferredSource: activeBrowseSource)
            }
            return []
        }

        if candidates.count == 1, let only = candidates.first {
            if let discoverableSearch = only.provider as? any SearchingWithProgressProvider {
                return try await discoverableSearch.search(trimmed, progress: progress)
            }
            let raw = try await only.provider.search(SearchRequest(query: trimmed, limit: 30))
            if let verifier = only.verifier {
                return try await verifier(raw, progress)
            }
            return raw
        }

        return try await withThrowingTaskGroup(of: [Track].self) { group in
            for entry in candidates {
                group.addTask {
                    do {
                        if let searching = entry.provider as? any SearchingWithProgressProvider {
                            return try await searching.search(trimmed, progress: nil)
                        }
                        let raw = try await entry.provider.search(SearchRequest(query: trimmed, limit: 20))
                        if let verifier = entry.verifier {
                            return try await verifier(raw, nil)
                        }
                        return raw
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return []
                    }
                }
            }
            var merged: [Track] = []
            var seen = Set<TrackIdentity>()
            for try await batch in group {
                for track in batch where seen.insert(track.identity).inserted {
                    merged.append(track)
                }
                progress?(TrackListBatch(tracks: merged, checked: merged.count, total: merged.count))
            }
            return merged
        }
    }

    private func searchOfflineFallback(keyword: String, preferredSource: ManagedSource?) async throws -> [Track] {
        let localOnly = browsableSources.filter { !$0.descriptor.requiresNetwork && $0.descriptor.supportsSearch }
        if !localOnly.isEmpty {
            var merged: [Track] = []
            for entry in localOnly {
                if let items = try? await entry.provider.search(SearchRequest(query: keyword, limit: 30)) {
                    merged.append(contentsOf: items)
                }
            }
            if !merged.isEmpty { return merged }
        }
        if let preferredSource,
           let searching = preferredSource.provider as? any SearchingWithProgressProvider,
           let cached = try? await searching.search(keyword, progress: nil),
           !cached.isEmpty {
            return cached
        }
        throw PlaybackError.networkDisabled
    }

    func verifyTracks(_ tracks: [Track],
                      progress: (@Sendable (TrackListBatch) -> Void)? = nil) async throws -> [Track] {
        guard !tracks.isEmpty else { return [] }
        var grouped: [SourceID: [Track]] = [:]
        for track in tracks {
            grouped[track.sourceID, default: []].append(track)
        }
        var verifiedByID: [TrackIdentity: Track] = [:]
        for (sourceID, groupTracks) in grouped {
            if let verifier = records[sourceID]?.verifier {
                if let verified = try? await verifier(groupTracks, progress) {
                    for item in verified {
                        verifiedByID[item.identity] = item
                    }
                }
            } else {
                for item in groupTracks {
                    verifiedByID[item.identity] = item
                }
            }
        }
        return tracks.compactMap { verifiedByID[$0.identity] }
    }

    // MARK: - 音质与电台扩展

    /// 音质偏好是全局设置：同步给所有支持多档音质的音源，而不只是当前浏览源。
    func applyPreferredQuality(_ tier: AudioQualityTier) async {
        for controller in sources.compactMap(\.qualityController) {
            _ = await controller.applyQuality(tier)
        }
        revision &+= 1
    }

    var activeQualityController: (any QualitySelectableSourceController)? {
        if let active = activeBrowseSource, active.isEnabled, let controller = active.qualityController {
            return controller
        }
        return sources.first { $0.isEnabled && $0.qualityController != nil }?.qualityController
            ?? sources.compactMap(\.qualityController).first
    }

    func relatedProvider(for sourceID: SourceID) -> (any RelatedRadioSourceProvider)? {
        guard let entry = records[sourceID], entry.isEnabled else { return nil }
        // 关了「允许联网」就不再向服务器要相关歌曲（离线播放 Subsonic 曲目放到队尾时也一样）。
        if entry.descriptor.requiresNetwork && !isNetworkEnabled { return nil }
        return entry.provider as? any RelatedRadioSourceProvider
    }

    @discardableResult
    func importSource(from url: URL) async throws -> ManagedSource {
        let all = try await importSources(from: url)
        guard let last = all.last else {
            throw RemoteHTTPFailure(code: -1, message: String(localized: "未导入任何可用音源"), url: url.absoluteString)
        }
        return last
    }

    @discardableResult
    func importSources(from url: URL, initialUserVariables: [String: String]? = nil) async throws -> [ManagedSource] {
        if let importFileHandler {
            let one = try await importFileHandler(url)
            return [one]
        }
        let normalized = url.isFileURL ? url : (SourceDomainPolicy.normalizeImportURL(url.absoluteString) ?? url)
        let imported = try await importedStore.importFromURL(normalized)
        if Task.isCancelled {
            // 用户在导入弹窗里点了取消：已经落盘的脚本一并删掉，别等下次启动才冒出来。
            for item in imported { importedStore.remove(sourceID: item.sourceID) }
            throw CancellationError()
        }
        var registeredList: [ManagedSource] = []
        for item in imported {
            if let initialUserVariables, !initialUserVariables.isEmpty, case .js(let js) = item {
                js.runtime.saveUserVariables(initialUserVariables)
            }
            let id = registerImportedProvider(item)
            if activeBrowseSourceID == nil {
                selectActiveBrowseSource(id)
            }
            if let managed = records[id] {
                registeredList.append(managed)
            }
        }
        guard !registeredList.isEmpty else {
            throw RemoteHTTPFailure(code: -1, message: String(localized: "未导入任何可用音源"), url: url.absoluteString)
        }
        return registeredList
    }

    // MARK: - GitHub 音源自动搜索与配置发现

    var hasGitHubToken: Bool {
        githubDiscovery.hasToken
    }

    var importedOriginURLs: Set<String> {
        Set(
            importedStore.loadRecords()
                .compactMap(\.originURL)
                .map { SourceDomainPolicy.normalizeImportURL($0)?.absoluteString ?? $0 }
        )
    }

    func saveGitHubToken(_ token: String) throws {
        try githubDiscovery.saveToken(token)
        revision &+= 1
    }

    func clearGitHubToken() {
        githubDiscovery.clearToken()
        revision &+= 1
    }

    func parseGitHubDirectTarget(_ query: String) -> GitHubDirectTarget? {
        GitHubSourceDiscovery.parseDirectRepositoryTarget(query)
    }

    func searchGitHubRepositories(query: String) async throws -> [GitHubRepoCandidate] {
        try await githubDiscovery.searchRepositories(query: query)
    }

    func searchGitHubFiles(query: String) async throws -> [GitHubConfigCandidate] {
        let candidates = try await githubDiscovery.searchFiles(query: query)
        return try await githubDiscovery.inspectCandidates(candidates)
    }

    func inspectGitHubRepository(_ repo: GitHubRepoCandidate,
                                 branchOverride: String? = nil,
                                 preferredPath: String? = nil) async throws -> [GitHubConfigCandidate] {
        let candidates = try await githubDiscovery.inspectRepository(
            repo,
            branchOverride: branchOverride,
            preferredPath: preferredPath
        )
        return try await githubDiscovery.inspectCandidates(candidates)
    }

    func inspectGitHubManifest(at rawURL: URL) async throws -> [GitHubManifestEntry] {
        try await githubDiscovery.inspectManifest(at: rawURL)
    }

    // MARK: - 外部多 API 预设（开放接口，默认未启用）

    var availableAPIPresets: [ExternalAPIPreset] {
        apiPresets
    }

    func isPresetImported(_ preset: ExternalAPIPreset) -> Bool {
        records[preset.sourceID] != nil
    }

    func isPresetEnabled(_ preset: ExternalAPIPreset) -> Bool {
        records[preset.sourceID]?.isEnabled == true
    }

    func presetOriginDescription(_ preset: ExternalAPIPreset) -> String {
        if ExternalAPIPresetCatalog.resolveLocalPresetURL(preset, in: externalPluginsDirectories) != nil {
            return String(localized: "来源：外置插件目录")
        }
        if preset.remoteURL != nil {
            return String(localized: "来源：GitHub 远端获取")
        }
        return String(localized: "来源：开放 API 模板")
    }

    @discardableResult
    func setPresetEnabled(_ preset: ExternalAPIPreset, enabled: Bool) async throws -> ManagedSource? {
        if !enabled {
            if records[preset.sourceID] != nil {
                setSourceEnabled(preset.sourceID, enabled: false)
            }
            return nil
        }

        if let existing = records[preset.sourceID] {
            if !existing.isEnabled {
                setSourceEnabled(preset.sourceID, enabled: true)
            }
            if activeBrowseSourceID == nil {
                selectActiveBrowseSource(preset.sourceID)
            }
            return records[preset.sourceID]
        }

        let imported = try await importPreset(preset)
        return imported.first { $0.id == preset.sourceID } ?? imported.first
    }

    @discardableResult
    func importPreset(_ preset: ExternalAPIPreset) async throws -> [ManagedSource] {
        let registered: [ManagedSource]
        if let localURL = ExternalAPIPresetCatalog.resolveLocalPresetURL(preset, in: externalPluginsDirectories) {
            registered = try await importSources(from: localURL)
        } else if let remoteURL = preset.remoteURL {
            registered = try await importSources(from: remoteURL)
        } else if let fallbackJSON = preset.fallbackTemplateJSON {
            let providers = try await importedStore.importPayload(
                data: Data(fallbackJSON.utf8),
                filenameHint: "\(preset.id).flow.json",
                originURL: nil
            )
            var list: [ManagedSource] = []
            for item in providers {
                let id = registerImportedProvider(item)
                if activeBrowseSourceID == nil {
                    selectActiveBrowseSource(id)
                }
                if let managed = records[id] {
                    list.append(managed)
                }
            }
            registered = list
        } else {
            throw RemoteHTTPFailure(
                code: -1,
                message: String(localized: "未找到可用的外部配置或网络地址：\(preset.displayName)"),
                url: preset.localRelativePath
            )
        }

        for source in registered where !source.isEnabled {
            setSourceEnabled(source.id, enabled: true)
        }
        return registered.compactMap { records[$0.id] }
    }

    func updateJSPluginVariables(sourceID: SourceID, values: [String: String]) {
        guard let jsSource = records[sourceID]?.provider as? JSPluginSource else { return }
        jsSource.runtime.saveUserVariables(values)
        revision &+= 1
    }

    func userVariableSpecs(for sourceID: SourceID) -> [JSPluginUserVariable] {
        (records[sourceID]?.provider as? JSPluginSource)?.manifest.userVariables ?? []
    }

    func userVariableValues(for sourceID: SourceID) -> [String: String] {
        (records[sourceID]?.provider as? JSPluginSource)?.runtime.userVariableValues() ?? [:]
    }

    // MARK: - 内置标准数据源配置与恢复（本地音乐库 / OpenSubsonic / WebDAV / 第三方插件）

    func restoreStandardSources() async {
        let local = ensureLocalLibrary()
        if local.hasConfiguredLocations {
            await local.restoreIfNeeded()
            registerLocalLibrary(local)
        }
        for config in serverConfigStore.loadAll() {
            registerServerConfig(config)
        }
        for imported in importedStore.restoreAll() {
            _ = registerImportedProvider(imported)
        }
    }

    @discardableResult
    func addLocalFolder(_ folderURL: URL) async -> Int {
        let local = ensureLocalLibrary()
        let count = await local.addFolder(folderURL)
        registerLocalLibrary(local)
        if activeBrowseSourceID == nil {
            selectActiveBrowseSource(.localFile)
        }
        revision &+= 1
        return count
    }

    @discardableResult
    func openLocalAudioURLs(_ urls: [URL]) async -> [Track] {
        let local = ensureLocalLibrary()
        var directFiles: [URL] = []
        var firstAddedTracks: [Track] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                _ = await local.addFolder(url)
            } else {
                directFiles.append(url)
            }
        }
        if !directFiles.isEmpty {
            firstAddedTracks = await local.addFiles(directFiles)
        }
        if firstAddedTracks.isEmpty {
            firstAddedTracks = (try? await local.discoverTracks(limit: 100, progress: nil)) ?? []
        }
        if local.hasConfiguredLocations {
            registerLocalLibrary(local)
            if activeBrowseSourceID == nil {
                selectActiveBrowseSource(.localFile)
            }
        }
        revision &+= 1
        return firstAddedTracks
    }

    func removeLocalFolder(path: String) async {
        guard let local = localLibrary else { return }
        await local.removeFolder(path: path)
        if !local.hasConfiguredLocations {
            unregisterSource(.localFile)
        } else {
            revision &+= 1
        }
    }

    func addServerSource(_ config: ServerSourceConfig,
                         password: String,
                         validateConnection: Bool = true,
                         session: URLSession = .shared) async throws {
        if validateConnection {
            guard isNetworkEnabled else { throw PlaybackError.networkDisabled }
            switch config.kind {
            case .openSubsonic:
                let store = InMemorySecretStore()
                try store.save(password, account: config.passwordAccountKey)
                let probe = OpenSubsonicSource(config: config, secrets: store, session: session, streamingAssetBuilder: streamingAssetBuilder)
                try await probe.testConnection()
            case .webDAV:
                let store = InMemorySecretStore()
                try store.save(password, account: config.passwordAccountKey)
                let probe = WebDAVSource(config: config, secrets: store, session: session, streamingAssetBuilder: streamingAssetBuilder)
                try await probe.testConnection()
            }
        }
        // 连接测试期间用户点了取消：不保存服务器和密码。
        try Task.checkCancellation()
        try serverConfigStore.upsert(config, password: password)
        registerServerConfig(config, session: session)
        if activeBrowseSourceID == nil {
            selectActiveBrowseSource(config.sourceID)
        }
    }

    func removeConfiguredSource(_ id: SourceID) {
        serverConfigStore.remove(sourceID: id)
        importedStore.remove(sourceID: id)
        if let jsProvider = records[id]?.provider as? JSPluginSource {
            jsProvider.runtime.clearUserVariables()
            jsProvider.runtime.invalidate()
        }
        if id == .localFile, let local = localLibrary {
            Task {
                for path in local.configuredFolderPaths {
                    await local.removeFolder(path: path)
                }
            }
        }
        unregisterSource(id)
        // 从禁用名单里去掉：以后重新导入同一个源时应当是启用状态。
        saveDisabledSet()
    }

    private func registerImportedProvider(_ imported: ImportedSourceStore.ImportedProvider) -> SourceID {
        switch imported {
        case .js(let source):
            if let old = records[source.descriptor.id]?.provider as? JSPluginSource {
                old.runtime.invalidate()
            }
            // 控制器在构造时读取当前档位，必须先把已保存的偏好写进音源。
            if let tier = preferredQualityProvider() { source.updateQuality(tier) }
            let account: (any SourceAccountController)? = source.manifest.capabilities.hasAuth
                ? JSPluginAccountController(source: source)
                : nil
            let quality: (any QualitySelectableSourceController)? = source.descriptor.supportsQualitySelection
                ? JSPluginQualityController(source: source)
                : nil
            registerSource(
                source,
                isBuiltIn: false,
                originLabel: source.manifest.author ?? String(localized: "JS 音源插件"),
                accountController: account,
                qualityController: quality
            )
            return source.descriptor.id
        case .json(let source):
            registerSource(
                source,
                isBuiltIn: false,
                originLabel: String(localized: "JSON 接口模板")
            )
            return source.descriptor.id
        case .server(let config, let password):
            try? serverConfigStore.upsert(config, password: password ?? "")
            registerServerConfig(config)
            return config.sourceID
        }
    }

    private func ensureLocalLibrary() -> LocalLibrarySource {
        if let localLibrary { return localLibrary }
        let created = LocalLibrarySource(defaults: defaults)
        localLibrary = created
        return created
    }

    private func registerLocalLibrary(_ local: LocalLibrarySource) {
        registerSource(
            local,
            isBuiltIn: false,
            originLabel: String(localized: "本地目录")
        )
    }

    private func registerServerConfig(_ config: ServerSourceConfig, session: URLSession = .shared) {
        switch config.kind {
        case .openSubsonic:
            let source = OpenSubsonicSource(
                config: config,
                secrets: secrets,
                session: session,
                streamingAssetBuilder: streamingAssetBuilder
            )
            if let tier = preferredQualityProvider() { source.updateQuality(tier) }
            let quality = OpenSubsonicQualityController(source: source)
            registerSource(
                source,
                isBuiltIn: false,
                originLabel: config.kind.displayName,
                qualityController: quality
            )
        case .webDAV:
            let source = WebDAVSource(
                config: config,
                secrets: secrets,
                session: session,
                streamingAssetBuilder: streamingAssetBuilder
            )
            registerSource(
                source,
                isBuiltIn: false,
                originLabel: config.kind.displayName
            )
        }
    }

    // MARK: - OfflineAudioResolving

    func resolveTrackForOffline(_ track: Track) async -> Track {
        guard let resolver = records[track.sourceID]?.offlineResolver else {
            return (await registry.provider(for: track.sourceID)?.resolve(track)) ?? track
        }
        return await resolver.resolveTrackForOffline(track)
    }

    func resolveOfflineStream(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        if let resolver = records[track.sourceID]?.offlineResolver {
            return try await resolver.resolveOfflineStream(for: track, quality: quality)
        }
        guard let provider = records[track.sourceID]?.provider as? any OfflineStreamDescriptorProviding else {
            return nil
        }
        return try await provider.offlineStreamDescriptor(for: track, quality: quality)
    }

    func fetchOfflineArtwork(for track: Track) async -> Data? {
        if let resolver = records[track.sourceID]?.offlineResolver {
            return await resolver.fetchOfflineArtwork(for: track)
        }
        guard let artwork = track.artwork else { return nil }
        return try? await registry.provider(for: track.sourceID)?.artwork(for: artwork)
    }

    func prefetchOfflineLyrics(for track: Track) async {
        if let resolver = records[track.sourceID]?.offlineResolver {
            await resolver.prefetchOfflineLyrics(for: track)
            return
        }
        // 音源自带的歌词只在内存里：不落进离线歌词缓存，关网播放时就是「没有找到同步歌词」。
        guard let document = try? await registry.provider(for: track.sourceID)?.lyrics(for: track),
              document.synchronization == .synced,
              !document.lines.isEmpty else { return }
        LyricDocumentCache.shared.store(
            identity: TrackIdentity.storageKey(track.identity),
            title: LyricQueryNormalizer.parseTitle(track.title).title,
            lrc: Self.lrcText(from: document)
        )
    }

    /// 同步歌词转回 LRC；译文按双语 LRC 惯例写成同时间戳的第二行。
    static func lrcText(from document: LyricsDocument) -> String {
        func stamp(_ seconds: TimeInterval) -> String {
            let centis = Int((max(0, seconds) * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", centis / 6000, (centis / 100) % 60, centis % 100)
        }
        var lines: [String] = []
        for line in document.lines {
            lines.append(stamp(line.start) + line.text)
            if let translation = line.translation, !translation.isEmpty {
                lines.append(stamp(line.start) + translation)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 内部维护

    private func syncRegistry(for entry: ManagedSource) {
        let shouldExpose = entry.isEnabled && (!entry.descriptor.requiresNetwork || isNetworkEnabled)
        if shouldExpose {
            registry.register(entry.provider)
        } else {
            registry.unregister(entry.id)
        }
    }

    private func rebuildSnapshot() {
        sources = order.compactMap { records[$0] }
        revision &+= 1
    }

    private func persistPreferences() {
        defaults.set(activeBrowseSourceID?.rawValue, forKey: Self.activeBrowseKey)
        defaults.set(aggregateSearchEnabled, forKey: Self.aggregateSearchKey)
    }

    private func saveDisabledSet() {
        let disabled = order.compactMap { id in
            records[id]?.isEnabled == false ? id.rawValue : nil
        }
        defaults.set(disabled, forKey: Self.disabledSetKey)
    }
}

/// 可选能力：支持增量搜索进度回调的源。
protocol SearchingWithProgressProvider: PlaybackSourceProvider {
    func search(_ keyword: String, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track]
}
