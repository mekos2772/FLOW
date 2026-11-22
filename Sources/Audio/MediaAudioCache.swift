import CryptoKit
import Foundation

/// 源无关的音频流缓存与永久离线库存储。
///
/// - 临时缓存（500 MB LRU 上限）随听随存、超限按最久未使用淘汰（保护正在播放文件）；
/// - 永久离线文件独立保存在离线目录，不受 LRU 淘汰与常规缓存清理影响；
/// - 统一承接 HTTP 206 首片起播（`ProgressiveAudioStream`）与整段下载。
actor MediaAudioCache {
    static let shared = MediaAudioCache()

    /// 有效音频文件的最小体积下限（命中校验与写入校验共用同一常量）。
    static let minimumUsefulBytes = 64 * 1024

    static let maxBytes = 500 * 1024 * 1024
    static let trimTargetRatio = 0.8

    static let supportedExtensions: Set<String> = ["m4a", "mp3", "flac", "aac", "wav", "ogg", "opus", "aiff", "aif", "alac"]

    enum MediaSource: Sendable {
        case local(URL)
        case stream(ProgressiveAudioStream)
        case hls(StreamingPreparedAsset)
    }

    struct CachedAudio: Sendable, Equatable {
        let url: URL
        let stream: AudioStreamDescriptor
    }

    private let directory: URL
    private let offlineDirectory: URL
    private let session: URLSession
    private let initialStreamChunkBytes: Int
    private let streamChunkBytes: Int
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var inFlightOpen: [String: Task<MediaSource, Error>] = [:]
    private var inFlightOpenWaiters: [String: Int] = [:]
    private var inFlightStreams: [String: ProgressiveAudioStream] = [:]
    private var onAudioCached: (@Sendable (String) -> Void)?

    func setOnAudioCached(_ handler: (@Sendable (String) -> Void)?) {
        onAudioCached = handler
    }

    func waitForInFlightCachedAudio(cacheKey: String) async -> CachedAudio? {
        if let hit = cachedAudio(cacheKey: cacheKey, matching: nil) {
            return hit
        }
        let prefixes = Self.matchingPrefixes(for: cacheKey)
        if let active = inFlightStreams.first(where: { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        })?.value {
            _ = await active.waitForLocalFile()
            return cachedAudio(cacheKey: cacheKey, matching: nil)
        }
        return nil
    }

    private static let pinnedLock = NSLock()
    nonisolated(unsafe) private static var pinnedPaths: Set<String> = []

    nonisolated static func pin(_ url: URL) {
        pinnedLock.lock(); defer { pinnedLock.unlock() }
        pinnedPaths.insert(url.standardizedFileURL.path)
    }

    nonisolated static func unpin(_ url: URL) {
        pinnedLock.lock(); defer { pinnedLock.unlock() }
        pinnedPaths.remove(url.standardizedFileURL.path)
    }

    nonisolated static var currentPinnedPaths: Set<String> {
        pinnedLock.lock(); defer { pinnedLock.unlock() }
        return pinnedPaths
    }

    init(directory: URL? = nil,
         offlineDirectory: URL? = nil,
         session: URLSession = .shared,
         initialStreamChunkBytes: Int = ProgressiveAudioStream.defaultInitialChunkBytes,
         streamChunkBytes: Int = ProgressiveAudioStream.defaultChunkBytes) {
        let base = directory ?? RuntimeSandbox.cachesDirectory()
            .appendingPathComponent("FLOW/MediaAudio", isDirectory: true)
        let offlineBase = offlineDirectory ?? (
            directory == nil
                ? (RuntimeSandbox.applicationSupportDirectory() ?? RuntimeSandbox.cachesDirectory())
                    .appendingPathComponent("FLOW/OfflineAudio", isDirectory: true)
                : base.appendingPathComponent("offline", isDirectory: true)
        )
        self.directory = base
        self.offlineDirectory = offlineBase
        self.session = session
        self.initialStreamChunkBytes = initialStreamChunkBytes
        self.streamChunkBytes = streamChunkBytes
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlineBase, withIntermediateDirectories: true)
    }

    nonisolated static func safeKey(_ raw: String) -> String {
        let allowed = raw.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        }
        let name = String(allowed)
        return name.isEmpty ? "unknown" : name
    }

    /// 无损防碰撞缓存键前缀：保留前 32 字符可读前缀，并附加完整原文 SHA-256 前 16 位十六进制摘要，
    /// 彻底避免非 ASCII/中文路径或 `-` / `_` / `/` 符号经 `safeKey` 压缩后撞键串歌。
    nonisolated static func uniquePrefix(_ raw: String) -> String {
        let readable = String(safeKey(raw).prefix(32))
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(readable)_\(hex)"
    }

    private nonisolated static func matchingPrefixes(for raw: String) -> [String] {
        let primary = "\(uniquePrefix(raw))-"
        // 仅当原文完全由 ASCII 字母数字构成（`safeKey` 100% 无损）时才兼容历史无摘要文件名，防止有损前缀误命中。
        let legacy = safeKey(raw)
        if !raw.isEmpty, raw == legacy {
            return [primary, "\(legacy)-"]
        }
        return [primary]
    }

    nonisolated func location(for descriptor: AudioStreamDescriptor) -> URL {
        let name = "\(Self.uniquePrefix(descriptor.cacheKey))-\(descriptor.qualityID)-\(descriptor.bandwidth).\(descriptor.fileExtension)"
        return directory.appendingPathComponent(name)
    }

    nonisolated static func sniffAudioExtension(data: Data,
                                                mimeType: String? = nil,
                                                suggestedFilename: String? = nil) -> String? {
        if data.count >= 12 {
            let bytes = [UInt8](data.prefix(64))
            if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return "flac" }
            if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return "mp3" }
            if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
                return (bytes[1] & 0x06) == 0 ? "aac" : "mp3"
            }
            if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
                if String(data: data.prefix(64), encoding: .ascii)?.contains("OpusHead") == true { return "opus" }
                return "ogg"
            }
            if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
               bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 { return "wav" }
            if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "m4a" }
        }
        if let mime = mimeType?.lowercased() {
            if mime.contains("flac") { return "flac" }
            if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
            if mime.contains("mp4") || mime.contains("m4a") { return "m4a" }
            if mime.contains("aac") { return "aac" }
            if mime.contains("opus") { return "opus" }
            if mime.contains("ogg") { return "ogg" }
            if mime.contains("wav") { return "wav" }
        }
        if let ext = suggestedFilename.map({ ($0 as NSString).pathExtension.lowercased() }),
           supportedExtensions.contains(ext) {
            return ext
        }
        return nil
    }

    nonisolated func offlineLocation(for descriptor: AudioStreamDescriptor) -> URL {
        let name = "\(Self.uniquePrefix(descriptor.cacheKey))-\(descriptor.qualityID)-\(descriptor.bandwidth).\(descriptor.fileExtension)"
        return offlineDirectory.appendingPathComponent(name)
    }

    private nonisolated func existingAudioFile(matching target: URL,
                                              expectedExtension: String,
                                              touchModificationDate: Bool) -> URL? {
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > Self.minimumUsefulBytes {
            if touchModificationDate {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            }
            return target
        }
        let stem = target.deletingPathExtension()
        for altExt in Self.supportedExtensions where altExt != expectedExtension {
            let candidate = stem.appendingPathExtension(altExt)
            if let size = try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? Int,
               size > Self.minimumUsefulBytes {
                if touchModificationDate {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
                }
                return candidate
            }
        }
        return nil
    }

    nonisolated func offlineDirectoryURL() -> URL { offlineDirectory }

    // MARK: - LRU 淘汰

    @discardableResult
    func trimIfNeeded(maxBytes: Int = maxBytes,
                      targetRatio: Double = trimTargetRatio) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var entries: [(url: URL, size: Int, used: Date)] = []
        var total = 0
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int else { continue }
            let used = (attributes[FileAttributeKey.modificationDate] as? Date) ?? .distantPast
            entries.append((url, size, used))
            total += size
        }
        guard total > maxBytes else { return 0 }

        let target = Int(Double(maxBytes) * min(max(targetRatio, 0.1), 0.95))
        var removed = 0
        let pinned = Self.currentPinnedPaths
        let stalePartCutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasSuffix(".part") {
            let url = directory.appendingPathComponent(name)
            if pinned.contains(url.standardizedFileURL.path) { continue }
            let mtime = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if mtime < stalePartCutoff {
                try? manager.removeItem(at: url)
            }
        }
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > target else { break }
            if pinned.contains(entry.url.standardizedFileURL.path) { continue }
            if (try? manager.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed += 1
            }
        }
        return removed
    }

    // MARK: - 缓存与离线查找

    func cachedAudio(cacheKey: String, matching requested: AudioQualityTier?) -> CachedAudio? {
        if let offline = bestCachedAudio(in: offlineDirectory, cacheKey: cacheKey, matching: requested, touchModificationDate: false) {
            return offline
        }
        return bestCachedAudio(in: directory, cacheKey: cacheKey, matching: requested, touchModificationDate: true)
    }

    func offlineAudio(cacheKey: String, matching requested: AudioQualityTier?) -> CachedAudio? {
        bestCachedAudio(in: offlineDirectory, cacheKey: cacheKey, matching: requested, touchModificationDate: false)
    }

    func isOffline(cacheKey: String) -> Bool {
        offlineAudio(cacheKey: cacheKey, matching: nil) != nil
    }

    func promoteCachedToOffline(cacheKey: String, matching requested: AudioQualityTier?) -> CachedAudio? {
        if let existing = offlineAudio(cacheKey: cacheKey, matching: requested) {
            return existing
        }
        guard let cached = bestCachedAudio(in: directory, cacheKey: cacheKey, matching: requested, touchModificationDate: false) else {
            return nil
        }
        let target = offlineLocation(for: cached.stream)
        guard copyToOffline(from: cached.url, to: target, cacheKey: cacheKey) else { return nil }
        return CachedAudio(url: target, stream: cached.stream)
    }

    func saveOffline(descriptor: AudioStreamDescriptor) async throws -> URL {
        let baseTarget = offlineLocation(for: descriptor)
        if let hit = existingAudioFile(matching: baseTarget, expectedExtension: descriptor.fileExtension, touchModificationDate: false) {
            return hit
        }
        let sourceURL = try await localFile(descriptor: descriptor)
        let ext = sourceURL.pathExtension.isEmpty ? descriptor.fileExtension : sourceURL.pathExtension.lowercased()
        let finalTarget = baseTarget.deletingPathExtension().appendingPathExtension(ext)
        guard copyToOffline(from: sourceURL, to: finalTarget, cacheKey: descriptor.cacheKey) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return finalTarget
    }

    func removeOffline(cacheKey: String) {
        removeMatchingFiles(in: offlineDirectory, prefixes: Self.matchingPrefixes(for: cacheKey), keeping: nil)
    }

    func offlineSize() -> Int64 {
        directoryAudioSize(offlineDirectory)
    }

    func clearOffline() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: offlineDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let pinned = Self.currentPinnedPaths
        for url in files where Self.supportedExtensions.contains(url.pathExtension.lowercased())
            && !pinned.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 流式打开与下载

    func openMedia(descriptor: AudioStreamDescriptor,
                   networkAllowed: @escaping @Sendable () -> Bool = { true }) async throws -> MediaSource {
        if let hit = existingAudioFile(
            matching: offlineLocation(for: descriptor),
            expectedExtension: descriptor.fileExtension,
            touchModificationDate: false
        ) {
            return .local(hit)
        }
        let target = location(for: descriptor)
        if let hit = existingAudioFile(
            matching: target,
            expectedExtension: descriptor.fileExtension,
            touchModificationDate: true
        ) {
            return .local(hit)
        }

        let key = target.lastPathComponent
        if let existingStream = inFlightStreams[key] {
            existingStream.retainConsumer()
            return .stream(existingStream)
        }
        if let existingDownload = inFlight[key] {
            return .local(try await existingDownload.value)
        }

        let openTask: Task<MediaSource, Error>
        if let existingOpen = inFlightOpen[key] {
            openTask = existingOpen
        } else {
            let progressive = ProgressiveAudioStream(
                remoteURL: descriptor.url,
                backupURLs: descriptor.backupURLs,
                destinationURL: target,
                session: session,
                headers: descriptor.headers,
                allowedDomains: descriptor.allowedDomains,
                networkAllowed: networkAllowed,
                initialChunkBytes: initialStreamChunkBytes,
                chunkBytes: streamChunkBytes,
                minimumUsefulBytes: Self.minimumUsefulBytes,
                onComplete: { [weak self] _ in
                    Task { await self?.handleStreamFinished(key: key, cacheKey: descriptor.cacheKey, completed: true) }
                },
                onAbandon: { [weak self] in
                    Task { await self?.handleStreamFinished(key: key, cacheKey: descriptor.cacheKey, completed: false) }
                }
            )
            openTask = Task<MediaSource, Error> {
                switch try await progressive.start() {
                case let .localFile(url):
                    return .local(url)
                case let .streaming(active):
                    return .stream(active)
                }
            }
            inFlightOpen[key] = openTask
        }

        inFlightOpenWaiters[key, default: 0] += 1
        let outcomeResult: Result<MediaSource, Error>
        do {
            outcomeResult = .success(try await openTask.value)
        } catch {
            outcomeResult = .failure(error)
        }

        let remainingWaiters = max(0, (inFlightOpenWaiters[key] ?? 1) - 1)
        if remainingWaiters == 0 {
            inFlightOpenWaiters.removeValue(forKey: key)
            inFlightOpen.removeValue(forKey: key)
        } else {
            inFlightOpenWaiters[key] = remainingWaiters
        }

        switch outcomeResult {
        case let .failure(error):
            throw error
        case let .success(result):
            switch result {
            case .local, .hls:
                _ = trimIfNeeded()
                try Task.checkCancellation()
                return result
            case let .stream(active):
                if active.isCompleted {
                    _ = trimIfNeeded()
                    try Task.checkCancellation()
                    return .local(active.destinationURL)
                }
                if !Task.isCancelled {
                    active.retainConsumer()
                    inFlightStreams[key] = active
                }
                if remainingWaiters == 0 {
                    active.releaseConsumer()
                }
                try Task.checkCancellation()
                return result
            }
        }
    }

    private func handleStreamFinished(key: String, cacheKey: String, completed: Bool) {
        inFlightStreams.removeValue(forKey: key)
        if completed {
            _ = trimIfNeeded()
            onAudioCached?(cacheKey)
        }
    }

    func localFile(descriptor: AudioStreamDescriptor,
                   networkAllowed: @escaping @Sendable () -> Bool = { true }) async throws -> URL {
        if descriptor.url.isFileURL {
            guard FileManager.default.isReadableFile(atPath: descriptor.url.path) else {
                throw PlaybackError.sourceUnavailable
            }
            return descriptor.url
        }
        let target = location(for: descriptor)
        if let hit = existingAudioFile(
            matching: target,
            expectedExtension: descriptor.fileExtension,
            touchModificationDate: true
        ) {
            return hit
        }
        let stem = target.deletingPathExtension()

        let key = target.lastPathComponent
        if let existingStream = inFlightStreams[key],
           let completedURL = await existingStream.waitForLocalFile() {
            return completedURL
        }
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<URL, Error> {
            var request = URLRequest(url: descriptor.url)
            for (field, value) in descriptor.headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.timeoutInterval = NetworkTimeouts.audioDownload

            let (data, response) = try await PluginHTTPClient.data(
                for: request,
                session: session,
                allowedDomains: descriptor.allowedDomains,
                networkAllowed: networkAllowed
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 && status != 206 {
                RedactingLog.error("audio download failed http=\(status) key=\(descriptor.cacheKey)")
            }
            guard status == 200 || status == 206 else {
                throw RemoteHTTPFailure(code: status,
                                        message: "音频下载失败（HTTP \(status)）",
                                        url: descriptor.url.absoluteString)
            }
            guard data.count > Self.minimumUsefulBytes else {
                throw RemoteHTTPFailure(code: -1,
                                        message: "音频分片过小（\(data.count) 字节）",
                                        url: descriptor.url.absoluteString)
            }
            let detectedExt = Self.sniffAudioExtension(
                data: data,
                mimeType: response.mimeType,
                suggestedFilename: response.suggestedFilename
            )
            let finalURL = (detectedExt.map { stem.appendingPathExtension($0) }) ?? target
            try data.write(to: finalURL, options: .atomic)
            _ = self.trimIfNeeded()
            self.onAudioCached?(descriptor.cacheKey)
            return finalURL
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    nonisolated func evictIfCached(cacheKey: String, url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
        RedactingLog.error("audio cache evicted key=\(cacheKey)")
    }

    func totalSize() -> Int64 {
        directoryAudioSize(directory)
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let pinned = Self.currentPinnedPaths
        let offlinePath = offlineDirectory.standardizedFileURL.path
        for url in files where url.standardizedFileURL.path != offlinePath
            && !pinned.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func evict(cacheKey: String) {
        removeMatchingFiles(in: directory, prefixes: Self.matchingPrefixes(for: cacheKey), keeping: nil)
    }

    // MARK: - 文件检索与持久化辅助

    private func copyToOffline(from sourceURL: URL, to target: URL, cacheKey: String) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
        let ext = target.pathExtension.isEmpty ? "m4a" : target.pathExtension
        let staging = offlineDirectory.appendingPathComponent(".tmp-\(UUID().uuidString).\(ext)")
        defer { try? manager.removeItem(at: staging) }
        do {
            if manager.fileExists(atPath: staging.path) {
                try manager.removeItem(at: staging)
            }
            try manager.copyItem(at: sourceURL, to: staging)
            removeMatchingFiles(in: offlineDirectory, prefixes: Self.matchingPrefixes(for: cacheKey), keeping: target)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    private func removeMatchingFiles(in folder: URL, prefixes: [String], keeping keepURL: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let pinned = Self.currentPinnedPaths
        let keepPath = keepURL?.standardizedFileURL.path
        for url in files {
            let name = url.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }),
                  Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            if path == keepPath || pinned.contains(path) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func bestCachedAudio(in folder: URL,
                                 cacheKey: String,
                                 matching requested: AudioQualityTier?,
                                 touchModificationDate: Bool) -> CachedAudio? {
        let prefixes = Self.matchingPrefixes(for: cacheKey)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var candidates: [CachedAudio] = []
        for url in files {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard let matchedPrefix = prefixes.first(where: { name.hasPrefix($0) }),
                  Self.supportedExtensions.contains(ext) else { continue }
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                  size > Self.minimumUsefulBytes else { continue }
            guard let descriptor = Self.parseCachedDescriptor(
                cacheKey: cacheKey,
                name: name,
                prefix: matchedPrefix,
                url: url
            ) else { continue }
            if let requested, !Self.matches(descriptor: descriptor, requested: requested) { continue }
            candidates.append(CachedAudio(url: url, stream: descriptor))
        }

        guard let picked = candidates.max(by: { lhs, rhs in
            if lhs.stream.isLossless != rhs.stream.isLossless {
                return !lhs.stream.isLossless && rhs.stream.isLossless
            }
            if lhs.stream.bandwidth != rhs.stream.bandwidth {
                return lhs.stream.bandwidth < rhs.stream.bandwidth
            }
            return lhs.stream.qualityID < rhs.stream.qualityID
        }) else { return nil }

        if touchModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: picked.url.path)
        }
        return picked
    }

    private func directoryAudioSize(_ folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        )) ?? []
        return files.reduce(Int64(0)) { partial, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values?.isDirectory != true else { return partial }
            return partial + Int64(values?.fileSize ?? 0)
        }
    }

    private nonisolated static func parseCachedDescriptor(cacheKey: String,
                                                          name: String,
                                                          prefix: String,
                                                          url: URL) -> AudioStreamDescriptor? {
        let ext = url.pathExtension.lowercased()
        let stem = String(name.dropFirst(prefix.count).dropLast(ext.count + 1))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let qualityID = Int(parts[0]),
              let bandwidth = Int(parts[1]) else { return nil }

        let qualityTier: AudioQualityTier
        let codec: String
        let isLossless: Bool

        switch qualityID {
        case 30251:
            qualityTier = .hiRes
            codec = "FLAC"
            isLossless = true
        case 30250:
            qualityTier = .lossless
            codec = "E-AC-3"
            isLossless = true
        case 30280, 30232:
            qualityTier = .high
            codec = ext == "mp3" ? "MP3" : "AAC"
            isLossless = false
        case 30216:
            qualityTier = .standard
            codec = ext == "mp3" ? "MP3" : "AAC"
            isLossless = false
        default:
            isLossless = (ext == "flac" || ext == "wav" || ext == "alac")
            codec = ext.uppercased()
            qualityTier = isLossless ? .lossless : (bandwidth >= 192_000 ? .high : .standard)
        }

        return AudioStreamDescriptor(
            cacheKey: cacheKey,
            fileExtension: ext,
            qualityTier: qualityTier,
            qualityID: qualityID,
            codec: codec,
            bandwidth: bandwidth,
            sampleRate: nil,
            isLossless: isLossless,
            url: url
        )
    }

    private nonisolated static func matches(descriptor: AudioStreamDescriptor, requested: AudioQualityTier) -> Bool {
        switch requested {
        case .auto: return true
        case .standard: return descriptor.qualityTier == .standard
        case .high: return descriptor.qualityTier == .high
        case .lossless, .hifi: return descriptor.isLossless
        case .hiRes: return descriptor.qualityTier == .hiRes
        }
    }
}
