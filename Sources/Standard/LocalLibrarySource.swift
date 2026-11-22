import AVFoundation
import Foundation

/// 内置本地音乐库数据源：管理用户授权的本地音频文件夹（security-scoped bookmarks）与单曲文件，
/// 提取音频元数据、内嵌/同目录封面以及同目录 `.lrc` / 内嵌歌词。
final class LocalLibrarySource:
    PlaybackSourceProvider,
    OfflineStreamDescriptorProviding,
    DiscoverableSourceProvider,
    @unchecked Sendable
{
    struct FolderEntry: Codable, Equatable, Sendable {
        let path: String
        let bookmarkData: Data?
    }

    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "flac", "aac", "wav", "aiff", "aif", "alac", "opus", "ogg"
    ]
    private static let coverFilenames: [String] = [
        "cover.jpg", "cover.jpeg", "cover.png",
        "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.png"
    ]

    let descriptor = SourceDescriptor(
        id: .localFile,
        displayName: String(localized: "本地音乐"),
        kind: .builtinLocal,
        requiresNetwork: false,
        supportsSearch: true,
        supportsLyrics: true,
        supportsDiscover: true,
        supportsAccount: false,
        supportsRelatedRadio: false,
        supportsQualitySelection: false
    )

    let supportsGaplessPrewarm = true

    private let defaults: UserDefaults
    private let foldersKey = "sources.localLibraryFolders"
    private let filesKey = "sources.localLibraryFiles"
    private let lock = NSLock()
    private var folders: [FolderEntry] = []
    private var fileBookmarks: [String: Data] = [:]
    private var indexedTracks: [Track] = []
    private var fileURLByExternalID: [String: URL] = [:]
    private var scopedURLs: [String: URL] = [:]
    private var hasScannedPersistedLocations = false

    init(defaults: UserDefaults = RuntimeSandbox.defaults) {
        self.defaults = defaults
        self.folders = Self.loadFolders(from: defaults, key: foldersKey)
        if let data = defaults.data(forKey: filesKey) {
            self.fileBookmarks = (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
        }
    }

    deinit {
        let urls = lock.withLock { Array(scopedURLs.values) }
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var hasConfiguredLocations: Bool {
        lock.withLock { !folders.isEmpty || !fileBookmarks.isEmpty || !indexedTracks.isEmpty }
    }

    var configuredFolderPaths: [String] {
        lock.withLock { folders.map(\.path) }
    }

    func restoreIfNeeded() async {
        let needsScan = lock.withLock { () -> Bool in
            guard !hasScannedPersistedLocations, !folders.isEmpty || !fileBookmarks.isEmpty else { return false }
            hasScannedPersistedLocations = true
            return true
        }
        guard needsScan else { return }
        _ = await rescanAllFolders()
    }

    @discardableResult
    func addFolder(_ folderURL: URL) async -> Int {
        let standardized = folderURL.standardizedFileURL
        let path = standardized.path
        let bookmark = try? standardized.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        lock.withLock {
            if !folders.contains(where: { $0.path == path }) {
                folders.append(FolderEntry(path: path, bookmarkData: bookmark))
                Self.saveFolders(folders, to: defaults, key: foldersKey)
            }
            hasScannedPersistedLocations = true
        }
        return await rescanAllFolders()
    }

    func removeFolder(path: String) async {
        lock.withLock {
            folders.removeAll { $0.path == path }
            Self.saveFolders(folders, to: defaults, key: foldersKey)
            if let scoped = scopedURLs.removeValue(forKey: path) {
                scoped.stopAccessingSecurityScopedResource()
            }
            indexedTracks.removeAll { $0.externalID.hasPrefix(path) }
            fileURLByExternalID = fileURLByExternalID.filter { !$0.key.hasPrefix(path) }
        }
        _ = await rescanAllFolders()
    }

    @discardableResult
    func addFiles(_ urls: [URL]) async -> [Track] {
        var added: [Track] = []
        for rawURL in urls {
            let fileURL = rawURL.standardizedFileURL
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            _ = beginScopeIfNeeded(for: fileURL)
            let bookmark = makeBookmark(for: fileURL)
            if let track = await extractTrack(from: fileURL, persistentIdentifier: bookmark?.base64EncodedString()) {
                lock.withLock {
                    if let bookmark {
                        fileBookmarks[track.externalID] = bookmark
                        saveFileBookmarks()
                    }
                    fileURLByExternalID[track.externalID] = fileURL
                    if let existing = indexedTracks.firstIndex(where: { $0.identity == track.identity }) {
                        indexedTracks[existing] = track
                    } else {
                        indexedTracks.append(track)
                    }
                }
                added.append(track)
            }
        }
        return added
    }

    @discardableResult
    func rescanAllFolders() async -> Int {
        let (folderSnapshot, fileSnapshot) = lock.withLock { (folders, fileBookmarks) }
        var rebuilt: [Track] = []
        var urlMap: [String: URL] = [:]
        var indexedPaths = Set<String>()

        for (externalID, bookmark) in fileSnapshot {
            let resolved = resolveBookmark(bookmark)
            let fileURL = resolved?.url ?? URL(fileURLWithPath: externalID)
            _ = beginScopeIfNeeded(for: fileURL)
            guard FileManager.default.isReadableFile(atPath: fileURL.path),
                  Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            if let track = await extractTrack(from: fileURL,
                                              persistentIdentifier: (resolved?.bookmarkData ?? bookmark).base64EncodedString(),
                                              externalID: externalID) {
                rebuilt.append(track)
                urlMap[externalID] = fileURL
                indexedPaths.insert(fileURL.standardizedFileURL.path)
            }
        }

        for entry in folderSnapshot {
            let resolved = entry.bookmarkData.flatMap { resolveBookmark($0) }
            let folderURL = resolved?.url ?? URL(fileURLWithPath: entry.path)
            _ = beginScopeIfNeeded(for: folderURL)
            let files = collectAudioFiles(in: folderURL)
            let persistent = (resolved?.bookmarkData ?? entry.bookmarkData)?.base64EncodedString()
            for fileURL in files where !indexedPaths.contains(fileURL.standardizedFileURL.path) {
                if let track = await extractTrack(from: fileURL, persistentIdentifier: persistent) {
                    rebuilt.append(track)
                    urlMap[track.externalID] = fileURL
                    indexedPaths.insert(fileURL.standardizedFileURL.path)
                }
            }
        }

        lock.withLock {
            // 保留无法创建书签、但本次运行仍可读取的单曲。
            let extras = indexedTracks.filter { urlMap[$0.externalID] == nil && fileURLByExternalID[$0.externalID] != nil }
            for extra in extras {
                if let existingURL = fileURLByExternalID[extra.externalID],
                   !indexedPaths.contains(existingURL.standardizedFileURL.path),
                   FileManager.default.fileExists(atPath: existingURL.path) {
                    rebuilt.append(extra)
                    urlMap[extra.externalID] = existingURL
                    indexedPaths.insert(existingURL.standardizedFileURL.path)
                }
            }
            indexedTracks = rebuilt.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            fileURLByExternalID = urlMap
        }
        return rebuilt.count
    }

    // MARK: - PlaybackSourceProvider

    func search(_ request: SearchRequest) async throws -> [Track] {
        await restoreIfNeeded()
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = lock.withLock { indexedTracks }
        let matched: [Track] = query.isEmpty
            ? current
            : current.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
                    || ($0.album?.localizedCaseInsensitiveContains(query) ?? false)
                    || $0.externalID.localizedCaseInsensitiveContains(query)
            }
        return Array(matched.dropFirst(request.offset).prefix(request.limit))
    }

    func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
        await restoreIfNeeded()
        let tracks = Array(lock.withLock { indexedTracks }.prefix(limit))
        progress?(TrackListBatch(tracks: tracks, checked: tracks.count, total: tracks.count))
        return tracks
    }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let (fileURL, stream) = try makeStreamDescriptor(for: track)
        return try await MainActor.run {
            try HTTPStreamPlayerSession(stream: stream, localURL: fileURL, title: track.title)
        }
    }

    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        guard quality == .auto || quality == .high || quality.prefersLossless || quality == .standard else {
            return nil
        }
        return try makeStreamDescriptor(for: track).stream
    }

    private func makeStreamDescriptor(for track: Track) throws -> (fileURL: URL, stream: AudioStreamDescriptor) {
        guard track.sourceID == descriptor.id else {
            throw PlaybackError.sourceUnavailable
        }
        let fileURL = resolvePlayableURL(for: track)
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw PlaybackError.sourceUnavailable
        }
        let ext = fileURL.pathExtension.lowercased()
        let losslessExtensions: Set<String> = ["flac", "wav", "aiff", "aif", "alac"]
        let stream = AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: ext.isEmpty ? "m4a" : ext,
            qualityTier: losslessExtensions.contains(ext) ? .lossless : .high,
            qualityID: 0,
            codec: ext.isEmpty ? "audio" : ext.uppercased(),
            bandwidth: 0,
            isLossless: losslessExtensions.contains(ext),
            url: fileURL
        )
        return (fileURL, stream)
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        session
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        switch reference.media {
        case .embedded(let data):
            return data.isEmpty ? nil : data
        case .file(let url):
            return await readArtwork(at: url)
        case .opaque(let path):
            return await readArtwork(at: URL(fileURLWithPath: path))
        case .remote(let url):
            return try? Data(contentsOf: url)
        }
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        let audioURL = resolvePlayableURL(for: track)
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        if let raw = Self.readTextFile(at: lrcURL),
           let parsed = LRCParser.parse(raw), !parsed.lines.isEmpty {
            return LyricsDocument(
                trackIdentity: track.identity,
                lines: parsed.lines,
                metadata: parsed.metadata,
                source: .sidecar,
                synchronization: parsed.synchronization
            )
        }
        if let embedded = await extractEmbeddedLyrics(from: audioURL) {
            if let parsed = LRCParser.parse(embedded), !parsed.lines.isEmpty {
                return LyricsDocument(
                    trackIdentity: track.identity,
                    lines: parsed.lines,
                    metadata: parsed.metadata,
                    source: .embedded,
                    synchronization: parsed.synchronization
                )
            }
            let plainLines = embedded
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !plainLines.isEmpty {
                let lyricLines = plainLines.enumerated().map { idx, text in
                    LyricLine(start: TimeInterval(idx), text: text)
                }
                return LyricsDocument(
                    trackIdentity: track.identity,
                    lines: lyricLines,
                    source: .embedded,
                    synchronization: .unsynced
                )
            }
        }
        return nil
    }

    func map(_ error: any Error) -> PlaybackError {
        defaultMap(error)
    }

    // MARK: - 内部扫描与元数据解析

    /// FLOW Voice 用的公开入口：把 Track 还原为本地音频文件 URL（含书签解析）。
    /// 文件不可读时返回 nil——语音转换需要真实可读的输入文件。
    func audioFileURL(for track: Track) -> URL? {
        guard track.sourceID == descriptor.id else { return nil }
        let url = resolvePlayableURL(for: track)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    private func resolvePlayableURL(for track: Track) -> URL {
        if let cached = lock.withLock({ fileURLByExternalID[track.externalID] }),
           FileManager.default.isReadableFile(atPath: cached.path) {
            return cached
        }
        let bookmark = lock.withLock { fileBookmarks[track.externalID] }
            ?? track.persistentIdentifier.flatMap { Data(base64Encoded: $0) }
        if let bookmark, let resolved = resolveBookmark(bookmark) {
            let fileURL: URL
            if (try? resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // 文件夹书签只恢复授权；实际音频仍取该文件夹下的相对路径。
                let savedPath = lock.withLock {
                    folders.first(where: { $0.bookmarkData == resolved.bookmarkData })?.path
                }
                let bookmarkPath = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
                let originalPath = [bookmarkPath, savedPath].compactMap { $0 }
                    .flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
                    .first { track.externalID.hasPrefix($0 + "/") }
                guard let originalPath else {
                    return URL(fileURLWithPath: track.externalID)
                }
                let relativePath = String(track.externalID.dropFirst(originalPath.count + 1))
                fileURL = resolved.url.appendingPathComponent(relativePath)
            } else {
                fileURL = resolved.url
                lock.withLock {
                    fileBookmarks[track.externalID] = resolved.bookmarkData
                    saveFileBookmarks()
                }
            }
            lock.withLock { fileURLByExternalID[track.externalID] = fileURL }
            return fileURL
        }
        return URL(fileURLWithPath: track.externalID)
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope,
                              includingResourceValuesForKeys: nil,
                              relativeTo: nil)
    }

    private func resolveBookmark(_ data: Data) -> (url: URL, bookmarkData: Data)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = beginScopeIfNeeded(for: url)
        guard stale, let refreshed = makeBookmark(for: url) else { return (url, data) }
        lock.withLock {
            var filesChanged = false
            for externalID in fileBookmarks.keys where fileBookmarks[externalID] == data {
                fileBookmarks[externalID] = refreshed
                filesChanged = true
            }
            if filesChanged { saveFileBookmarks() }
            var foldersChanged = false
            for index in folders.indices where folders[index].bookmarkData == data {
                folders[index] = FolderEntry(path: folders[index].path, bookmarkData: refreshed)
                foldersChanged = true
            }
            if foldersChanged { Self.saveFolders(folders, to: defaults, key: foldersKey) }
        }
        return (url, refreshed)
    }

    private func saveFileBookmarks() {
        if let data = try? JSONEncoder().encode(fileBookmarks) {
            defaults.set(data, forKey: filesKey)
        }
    }

    @discardableResult
    private func beginScopeIfNeeded(for url: URL) -> Bool {
        lock.withLock {
            let key = url.standardizedFileURL.path
            if scopedURLs[key] != nil { return true }
            guard url.startAccessingSecurityScopedResource() else { return false }
            scopedURLs[key] = url
            return true
        }
    }

    private func collectAudioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            results.append(fileURL.standardizedFileURL)
        }
        return results
    }

    private func extractTrack(from fileURL: URL,
                              persistentIdentifier: String?,
                              externalID: String? = nil) async -> Track? {
        let asset = AVURLAsset(url: fileURL)
        let rawDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        var title = ""
        var artist = ""
        var album: String?
        var hasEmbeddedArt = false

        for item in metadata {
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyTitle:
                if title.isEmpty, let value = try? await item.load(.stringValue) {
                    title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyArtist:
                if artist.isEmpty, let value = try? await item.load(.stringValue) {
                    artist = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .commonKeyAlbumName:
                if album == nil, let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { album = trimmed }
                }
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    hasEmbeddedArt = true
                }
            default:
                break
            }
        }

        if title.isEmpty {
            title = fileURL.deletingPathExtension().lastPathComponent
        }

        let artworkRef: ArtworkReference?
        if hasEmbeddedArt {
            artworkRef = ArtworkReference(.file(fileURL))
        } else if let coverURL = findFolderCover(near: fileURL) {
            artworkRef = ArtworkReference(.file(coverURL))
        } else {
            artworkRef = nil
        }

        let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
        let lyricsRef: LyricsReference? = FileManager.default.fileExists(atPath: lrcURL.path)
            ? LyricsReference(.file(lrcURL))
            : nil

        return Track(
            sourceID: descriptor.id,
            externalID: externalID ?? fileURL.standardizedFileURL.path,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artwork: artworkRef,
            lyrics: lyricsRef,
            persistentIdentifier: persistentIdentifier
        )
    }

    private func readArtwork(at url: URL) async -> Data? {
        if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return await extractEmbeddedArtwork(from: url)
        }
        return try? Data(contentsOf: url)
    }

    private func extractEmbeddedArtwork(from fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func extractEmbeddedLyrics(from fileURL: URL) async -> String? {
        let asset = AVURLAsset(url: fileURL)
        let allItems = (try? await asset.load(.metadata)) ?? []
        for item in allItems {
            if item.commonKey?.rawValue == "lyrics" || item.identifier == .iTunesMetadataLyrics {
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func findFolderCover(near audioURL: URL) -> URL? {
        let dir = audioURL.deletingLastPathComponent()
        for name in Self.coverFilenames {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func readTextFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    private static func loadFolders(from defaults: UserDefaults, key: String) -> [FolderEntry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FolderEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveFolders(_ entries: [FolderEntry], to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
