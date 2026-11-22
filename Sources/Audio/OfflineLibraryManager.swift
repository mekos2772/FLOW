import Foundation
import Observation

/// 源无关的离线音频解析协议：供 `OfflineLibraryManager` 从任意在线源下载音频、封面与歌词。
@MainActor
protocol OfflineAudioResolving: Sendable {
    func resolveTrackForOffline(_ track: Track) async -> Track
    func resolveOfflineStream(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor?
    func fetchOfflineArtwork(for track: Track) async -> Data?
    func prefetchOfflineLyrics(for track: Track) async
}

/// 可选能力：不构造播放会话、只解析出可下载的音频流描述（显式离线保存走这条路）。
protocol OfflineStreamDescriptorProviding: PlaybackSourceProvider {
    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor?
}

/// 显式离线下载与本地离线曲库管理（源无关）。
///
/// 与临时 500 MB 自动 LRU 缓存分工：
/// - 临时缓存随听随存、超限或设置页清理时释放；
/// - 显式离线保存的音频落在 `MediaAudioCache` 永久离线目录，清单落盘为 `manifest.json`，
///   断网或关闭「允许联网」仍可稳定浏览与播放。
@MainActor
@Observable
final class OfflineLibraryManager {
    struct Entry: Codable, Sendable, Equatable {
        var track: Track
        var savedAt: Date
        var qualityID: Int
        var bandwidth: Int
    }

    private struct Manifest: Codable, Sendable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    private(set) var audioCache: MediaAudioCache
    @ObservationIgnored private let manifestURL: URL?
    @ObservationIgnored private let qualityProvider: @Sendable () -> AudioQualityTier
    @ObservationIgnored private let networkAllowed: @Sendable () -> Bool
    @ObservationIgnored private let offlineLyricsLoader: (@Sendable (Track) async -> LyricsDocument?)?
    @ObservationIgnored private var records: [TrackIdentity: Entry] = [:]
    @ObservationIgnored private var inFlight: [TrackIdentity: Task<Bool, Never>] = [:]

    private(set) var tracks: [Track] = []
    private(set) var offlineIdentities: Set<TrackIdentity> = []
    private(set) var downloadingIdentities: Set<TrackIdentity> = []
    private(set) var totalBytes: Int64 = 0
    private(set) var statusMessage: String?
    private(set) var revision: Int = 0

    init(audioCache: MediaAudioCache,
         manifestURL: URL?,
         qualityProvider: @escaping @Sendable () -> AudioQualityTier = { .auto },
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         offlineLyricsLoader: (@Sendable (Track) async -> LyricsDocument?)? = nil) {
        self.audioCache = audioCache
        self.manifestURL = manifestURL
        self.qualityProvider = qualityProvider
        self.networkAllowed = networkAllowed
        self.offlineLyricsLoader = offlineLyricsLoader
        loadManifest()
        rebuildSnapshot()
    }

    func attachAudioCache(_ cache: MediaAudioCache) {
        audioCache = cache
    }

    func isOffline(_ identity: TrackIdentity) -> Bool {
        offlineIdentities.contains(identity)
    }

    func isDownloading(_ identity: TrackIdentity) -> Bool {
        downloadingIdentities.contains(identity)
    }

    func savedTrack(for identity: TrackIdentity) -> Track? {
        records[identity]?.track
    }

    private nonisolated static func cacheKeys(for track: Track) -> [String] {
        let primary = TrackIdentity.storageKey(track.identity)
        let baseKeys = track.externalID.isEmpty || track.externalID == primary
            ? [primary]
            : [primary, track.externalID]
        // JS 插件与 OpenSubsonic 旧版本把音质档位拼进了缓存键（`…-high`）。
        // 只对这两类源补查旧键：其它源的 externalID 本身可能带同样的后缀，盲目补查会认错曲目。
        let raw = track.sourceID.rawValue
        guard raw.hasPrefix("js-") || raw.hasPrefix("server-openSubsonic-") else { return baseKeys }
        let legacyKeys = AudioQualityTier.allCases.map { "\(primary)-\($0.rawValue)" }
        return baseKeys + legacyKeys
    }

    /// 核对磁盘离线音频文件，保持内存清单、真实文件与占用体积一致。
    @discardableResult
    func refresh() async -> [Track] {
        var valid: [TrackIdentity: Entry] = [:]
        for (identity, entry) in records {
            var exists = false
            for key in Self.cacheKeys(for: entry.track) {
                if await audioCache.isOffline(cacheKey: key) {
                    exists = true
                    break
                }
            }
            if exists {
                valid[identity] = entry
            }
        }
        if valid.count != records.count {
            records = valid
            saveManifest()
        }
        totalBytes = await audioCache.offlineSize()
        rebuildSnapshot()
        return tracks
    }

    /// 显式离线保存单曲（音频优先转存已有本地缓存，否则从音源解析取流下载，并顺手缓存封面与歌词）。
    @discardableResult
    func download(_ track: Track, using resolver: (any OfflineAudioResolving)?) async -> Bool {
        guard track.sourceID != .mock else { return false }
        if let existing = inFlight[track.identity] {
            return await existing.value
        }
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performDownload(track, using: resolver)
        }
        inFlight[track.identity] = task
        let result = await task.value
        inFlight[track.identity] = nil
        return result
    }

    /// 批量离线保存曲目列表，返回成功保存在本地离线库的数量。
    @discardableResult
    func downloadAll(_ items: [Track], using resolver: (any OfflineAudioResolving)?) async -> Int {
        let targets = items.filter { $0.sourceID != .mock }
        guard !targets.isEmpty else { return 0 }
        var succeeded = 0
        for (offset, track) in targets.enumerated() {
            statusMessage = String(localized: "正在离线保存（\(offset + 1)/\(targets.count)）")
            if await download(track, using: resolver) {
                succeeded += 1
            }
        }
        statusMessage = succeeded == targets.count
            ? String(localized: "已全部离线保存（\(succeeded) 首）")
            : String(localized: "离线保存完成：成功 \(succeeded)/\(targets.count) 首")
        return succeeded
    }

    func remove(_ track: Track) async {
        inFlight[track.identity]?.cancel()
        inFlight[track.identity] = nil
        downloadingIdentities.remove(track.identity)
        for key in Self.cacheKeys(for: track) {
            await audioCache.removeOffline(cacheKey: key)
        }
        records.removeValue(forKey: track.identity)
        saveManifest()
        totalBytes = await audioCache.offlineSize()
        rebuildSnapshot()
        revision &+= 1
    }

    func clearAll() async {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        downloadingIdentities.removeAll()
        await audioCache.clearOffline()
        records.removeAll()
        saveManifest()
        totalBytes = await audioCache.offlineSize()
        statusMessage = nil
        rebuildSnapshot()
        revision &+= 1
    }

    /// 离线（或联网开关关闭）时直接用磁盘已有音频构造通用播放会话，零网络请求。
    func offlineSession(for track: Track,
                        quality: AudioQualityTier? = nil,
                        onStreamPicked: (@Sendable (AudioStreamDescriptor) -> Void)? = nil) async throws -> (any PlaybackSession)? {
        guard track.sourceID != .mock else { return nil }
        let requested = quality ?? qualityProvider()
        var cached: MediaAudioCache.CachedAudio?
        for key in Self.cacheKeys(for: track) {
            if let exact = await audioCache.cachedAudio(cacheKey: key, matching: requested) {
                cached = exact
                break
            }
        }
        if cached == nil {
            for key in Self.cacheKeys(for: track) {
                if let fallback = await audioCache.cachedAudio(cacheKey: key, matching: nil) {
                    cached = fallback
                    break
                }
            }
        }
        guard let cached else {
            return nil
        }
        onStreamPicked?(cached.stream)
        return try HTTPStreamPlayerSession(
            stream: cached.stream,
            localURL: cached.url,
            title: track.title,
            cacheKey: cached.stream.cacheKey
        )
    }

    /// FLOW Voice 用的公开入口：返回该曲目已缓存到磁盘的音频文件 URL。
    /// 不挑音质——拿任何已落盘版本；没有缓存返回 nil。
    func cachedAudioFileURL(for track: Track) async -> URL? {
        for key in Self.cacheKeys(for: track) {
            if let cached = await audioCache.cachedAudio(cacheKey: key, matching: nil) {
                return cached.url
            }
        }
        return nil
    }

    /// 供用户显式点击「生成 AI 版」时使用：先复用已落盘缓存；
    /// 若当前正在边播边下流媒体，则等待本轮完整流落盘；必要且允许联网时主动拉取原声完整音频再开始转换。
    func ensureCachedAudioFileURL(for track: Track, using resolver: (any OfflineAudioResolving)?) async -> URL? {
        if let cached = await cachedAudioFileURL(for: track) {
            return cached
        }
        for key in Self.cacheKeys(for: track) {
            if let waited = await audioCache.waitForInFlightCachedAudio(cacheKey: key) {
                return waited.url
            }
        }
        guard track.sourceID != .mock, let resolver, networkAllowed() else {
            return nil
        }
        let resolved = await resolver.resolveTrackForOffline(track)
        let requested = qualityProvider()
        guard let candidate = try? await resolver.resolveOfflineStream(for: resolved, quality: requested) else {
            return nil
        }
        return try? await audioCache.localFile(descriptor: candidate, networkAllowed: networkAllowed)
    }

    /// 离线时读取已落盘的 LRC 或 AMLL 逐字 TTML 歌词（零网络请求）。
    func offlineLyrics(for track: Track) async -> LyricsDocument? {
        if let loader = offlineLyricsLoader {
            return await loader(track)
        }
        return await ExternalLyricsAggregator().cachedOfflineLyrics(
            for: track,
            legacyCacheKey: track.externalID
        )
    }

    private func performDownload(_ track: Track, using resolver: (any OfflineAudioResolving)?) async -> Bool {
        downloadingIdentities.insert(track.identity)
        defer { downloadingIdentities.remove(track.identity) }

        let requested = qualityProvider()
        var resolved = track
        if let resolver, networkAllowed() {
            resolved = await resolver.resolveTrackForOffline(track)
        }

        var promotedDescriptor: AudioStreamDescriptor?
        for key in Self.cacheKeys(for: resolved) {
            if let promoted = await audioCache.promoteCachedToOffline(cacheKey: key, matching: requested) {
                promotedDescriptor = promoted.stream
                break
            }
        }

        let pickedStream: AudioStreamDescriptor
        if let promotedDescriptor {
            pickedStream = promotedDescriptor
        } else {
            guard let resolver, networkAllowed() else { return false }
            do {
                guard let candidate = try await resolver.resolveOfflineStream(for: resolved, quality: requested) else {
                    return false
                }
                _ = try await audioCache.saveOffline(descriptor: candidate)
                pickedStream = candidate
            } catch {
                return false
            }
        }

        if let resolver, networkAllowed() {
            if ArtworkStore.shared.image(forIdentity: resolved.identity) == nil,
               let data = await resolver.fetchOfflineArtwork(for: resolved),
               !data.isEmpty {
                ArtworkStore.shared.store(data, for: resolved.identity)
            }
            await resolver.prefetchOfflineLyrics(for: resolved)
        }

        records[resolved.identity] = Entry(
            track: resolved,
            savedAt: Date(),
            qualityID: pickedStream.qualityID,
            bandwidth: pickedStream.bandwidth
        )
        saveManifest()
        totalBytes = await audioCache.offlineSize()
        rebuildSnapshot()
        revision &+= 1
        return true
    }

    private func rebuildSnapshot() {
        let sorted = records.values.sorted { $0.savedAt > $1.savedAt }
        tracks = sorted.map(\.track)
        offlineIdentities = Set(records.keys)
    }

    private func loadManifest() {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
              decoded.version == 1 else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.entries.map { ($0.track.identity, $0) })
    }

    private func saveManifest() {
        guard let manifestURL else { return }
        let directory = manifestURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sorted = records.values.sorted { $0.savedAt > $1.savedAt }
        guard let data = try? JSONEncoder().encode(Manifest(entries: sorted)) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
