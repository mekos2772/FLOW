import CryptoKit
import Foundation

/// 三级语音推理磁盘缓存管理。
///
/// 层级：`separation/` -> `conversion/` -> `renders/` + `manifests/`。
/// - 调整人声混响/响度仅重新生成 `renders/`，复用 `separation/` 与 `conversion/`；
/// - 切换音色或移调仅重跑 `conversion/` + `renders/`，复用 `separation/`；
/// - 容量超限时按 LRU 顺序回收最旧文件并同步清理对应 manifest。
final class VoiceCacheManager: @unchecked Sendable {
    static let pipelineVersion = 3

    enum Tier: String, Sendable {
        case separation
        case conversion
        case renders
        case manifests
    }

    /// 清单里随成品一起落盘的附加信息：离线页靠它列出歌曲，删除时靠两级键联动清理中间文件。
    /// 早期清单没有这些字段，读出来全是 nil。
    struct RenderMetadata: Sendable, Equatable {
        var track: Track?
        var packName: String?
        var separationKey: String?
        var conversionKey: String?

        init(track: Track? = nil, packName: String? = nil, separationKey: String? = nil, conversionKey: String? = nil) {
            self.track = track
            self.packName = packName
            self.separationKey = separationKey
            self.conversionKey = conversionKey
        }
    }

    struct StoredRender: Sendable, Equatable, Identifiable {
        var render: VoiceRender
        var metadata: RenderMetadata
        var createdAt: Date
        var bytes: Int64

        var id: String { render.cacheKey }
    }

    let rootURL: URL
    var capacityBytes: Int64
    private let fm = FileManager.default
    private let lock = NSLock()

    init(rootURL: URL, capacityBytes: Int64 = 8 << 30) {
        self.rootURL = rootURL
        self.capacityBytes = capacityBytes
        for tier in [Tier.separation, .conversion, .renders, .manifests] {
            try? fm.createDirectory(at: url(for: tier), withIntermediateDirectories: true)
        }
    }

    func url(for tier: Tier) -> URL {
        rootURL.appendingPathComponent(tier.rawValue, isDirectory: true)
    }

    // MARK: - 指纹与缓存键

    static func audioFingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var hasher = SHA256()
        hasher.update(data: Data("\(size)|".utf8))
        let block = 1 << 20
        if size <= UInt64(block * 2) {
            if let data = try? handle.readToEnd() {
                hasher.update(data: data)
            }
        } else {
            if let head = try? handle.read(upToCount: block) {
                hasher.update(data: head)
            }
            try? handle.seek(toOffset: size - UInt64(block))
            if let tail = try? handle.read(upToCount: block) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func separationKey(audioFP: String, separationModel: String) -> String {
        let hex = sha256Hex(Data("\(audioFP)|\(separationModel)".utf8)).prefix(16)
        return "sep-\(pipelineVersion)-\(hex)"
    }

    static func conversionKey(
        separationKey: String,
        weightFP: String,
        indexFP: String?,
        engineID: String,
        parameters: [String: VoiceParameterValue],
        backendID: String
    ) -> String {
        var msg = "\(separationKey)|\(weightFP)|\(indexFP ?? "-")|\(engineID)|\(backendID)"
        for k in parameters.keys.sorted() {
            if let v = parameters[k] {
                msg += "|\(k)=\(Self.stableString(v))"
            }
        }
        let hex = sha256Hex(Data(msg.utf8)).prefix(16)
        return "vc-\(pipelineVersion)-\(hex)"
    }

    static func renderKey(conversionKey: String, instFingerprint: String, mixSpec: String) -> String {
        let hex = sha256Hex(Data("\(conversionKey)|\(instFingerprint)|\(mixSpec)".utf8)).prefix(16)
        return "render-\(pipelineVersion)-\(hex)"
    }

    private static func stableString(_ v: VoiceParameterValue) -> String {
        switch v {
        case .int(let i): return "i:\(i)"
        case .double(let d): return String(format: "d:%.4f", d)
        case .bool(let b): return "b:\(b)"
        case .string(let s): return "s:\(s)"
        }
    }

    // MARK: - 路径规则

    func vocalsURL(sepKey: String) -> URL {
        url(for: .separation).appendingPathComponent("\(sepKey).vocals.wav")
    }

    func instURL(sepKey: String) -> URL {
        url(for: .separation).appendingPathComponent("\(sepKey).inst.wav")
    }

    func convertedVocalsURL(convKey: String) -> URL {
        url(for: .conversion).appendingPathComponent("\(convKey).vocals.wav")
    }

    func renderURL(renderKey: String) -> URL {
        url(for: .renders).appendingPathComponent("\(renderKey).m4a")
    }

    func manifestURL(renderKey: String) -> URL {
        url(for: .manifests).appendingPathComponent("\(renderKey).json")
    }

    // MARK: - 读写与校验

    func separationExists(sepKey: String) -> Bool {
        fm.fileExists(atPath: vocalsURL(sepKey: sepKey).path)
            && fm.fileExists(atPath: instURL(sepKey: sepKey).path)
    }

    func conversionExists(convKey: String) -> Bool {
        fm.fileExists(atPath: convertedVocalsURL(convKey: convKey).path)
    }

    func renderExists(renderKey: String) -> Bool {
        (try? render(for: renderKey)) != nil
    }

    func render(for cacheKey: String) throws -> VoiceRender? {
        try lock.withLock {
            let mURL = manifestURL(renderKey: cacheKey)
            guard fm.fileExists(atPath: mURL.path) else { return nil }
            let data = try Data(contentsOf: mURL)
            let manifest = try JSONDecoder().decode(RenderManifest.self, from: data)
            let fileURL = resolveFileURL(storedPath: manifest.filePath, cacheKey: cacheKey)
            guard fm.fileExists(atPath: fileURL.path) else {
                throw VoiceError.cacheCorrupted("渲染清单指向缺失文件：\(fileURL.lastPathComponent)")
            }
            return VoiceRender(
                trackKey: manifest.trackKey,
                cacheKey: cacheKey,
                fileURL: fileURL,
                duration: manifest.duration,
                sampleRate: manifest.sampleRate,
                packID: manifest.packID,
                versionID: manifest.versionID,
                pipelineVersion: manifest.pipelineVersion
            )
        }
    }

    /// 清理损坏的悬空 manifest（音频丢失但 manifest 存在时调用）。
    func removeCorruptedManifest(for cacheKey: String) {
        lock.withLock {
            try? fm.removeItem(at: manifestURL(renderKey: cacheKey))
        }
    }

    /// 强制重新渲染前清理对应的转换后人声、成品混音与清单缓存（保留人声分离缓存，避免重复做 MDX 分离）。
    func invalidateRenderAndConversion(conversionKey: String, renderKey: String) {
        lock.withLock {
            if !conversionKey.isEmpty {
                try? fm.removeItem(at: convertedVocalsURL(convKey: conversionKey))
            }
            if !renderKey.isEmpty {
                try? fm.removeItem(at: renderURL(renderKey: renderKey))
                try? fm.removeItem(at: manifestURL(renderKey: renderKey))
            }
        }
    }

    func writeRenderManifest(_ render: VoiceRender, metadata: RenderMetadata = RenderMetadata()) throws {
        try lock.withLock {
            let manifest = RenderManifest(
                trackKey: render.trackKey,
                cacheKey: render.cacheKey,
                filePath: render.fileURL.path,
                duration: render.duration,
                sampleRate: render.sampleRate,
                packID: render.packID,
                versionID: render.versionID,
                pipelineVersion: render.pipelineVersion,
                createdAt: Date(),
                track: metadata.track,
                packName: metadata.packName,
                separationKey: metadata.separationKey.flatMap { $0.isEmpty ? nil : $0 },
                conversionKey: metadata.conversionKey.flatMap { $0.isEmpty ? nil : $0 }
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(manifest)
            try data.write(to: manifestURL(renderKey: render.cacheKey), options: .atomic)
        }
    }

    /// 当前管线版本下仍有音频文件的全部成品，新的在前。
    func storedRenders() -> [StoredRender] {
        lock.withLock {
            loadManifestsLocked()
                .filter { $0.manifest.pipelineVersion == Self.pipelineVersion }
                .compactMap { entry -> StoredRender? in
                    let m = entry.manifest
                    let resolved = resolveFileURL(storedPath: m.filePath, cacheKey: m.cacheKey)
                    guard fm.fileExists(atPath: resolved.path) else { return nil }
                    return StoredRender(
                        render: VoiceRender(
                            trackKey: m.trackKey,
                            cacheKey: m.cacheKey,
                            fileURL: resolved,
                            duration: m.duration,
                            sampleRate: m.sampleRate,
                            packID: m.packID,
                            versionID: m.versionID,
                            pipelineVersion: m.pipelineVersion
                        ),
                        metadata: RenderMetadata(
                            track: m.track,
                            packName: m.packName,
                            separationKey: m.separationKey,
                            conversionKey: m.conversionKey
                        ),
                        createdAt: m.createdAt,
                        bytes: fileSize(resolved)
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// 删除指定成品：音频、清单，以及只被它们引用的转换人声与分离人声/伴奏。
    ///
    /// 早期清单没记两级键，无法精确对应中间文件；`sweepWhenEmpty` 为真且删完已没有任何成品时，
    /// 把剩下的中间文件一并清掉（它们只是加速重新生成的缓存）。
    ///
    /// 有转换任务在跑时调用方要同时传 `keepIntermediates: true`：进行中的任务可能正**复用**
    /// 另一首成品的分离结果，删掉那份中间文件会让它跑到一半读不到伴奏。
    @discardableResult
    func removeRenders(cacheKeys: Set<String>,
                       sweepWhenEmpty: Bool,
                       keepIntermediates: Bool = false) -> Int64 {
        lock.withLock {
            let entries = loadManifestsLocked()
            let removed = entries.filter { cacheKeys.contains($0.manifest.cacheKey) }
            let kept = entries.filter { !cacheKeys.contains($0.manifest.cacheKey) }
            var freed: Int64 = 0

            func remove(_ target: URL) {
                guard fm.fileExists(atPath: target.path) else { return }
                let size = fileSize(target)
                if (try? fm.removeItem(at: target)) != nil { freed += size }
            }

            for entry in removed {
                let m = entry.manifest
                let audio = resolveFileURL(storedPath: m.filePath, cacheKey: m.cacheKey)
                // 只删缓存目录里的文件：清单指向别处时绝不碰用户自己的音频。
                if isInsideRoot(audio) { remove(audio) }
                remove(renderURL(renderKey: m.cacheKey))
                remove(entry.url)
            }

            if !keepIntermediates {
                let keptConversions = Set(kept.compactMap(\.manifest.conversionKey))
                let keptSeparations = Set(kept.compactMap(\.manifest.separationKey))
                for m in removed.map(\.manifest) {
                    if let conv = m.conversionKey, !keptConversions.contains(conv) {
                        remove(convertedVocalsURL(convKey: conv))
                    }
                    if let sep = m.separationKey, !keptSeparations.contains(sep) {
                        remove(vocalsURL(sepKey: sep))
                        remove(instURL(sepKey: sep))
                    }
                }
            }

            if sweepWhenEmpty, kept.isEmpty {
                for tier in [Tier.separation, .conversion, .renders] {
                    let items = (try? fm.contentsOfDirectory(at: url(for: tier), includingPropertiesForKeys: nil)) ?? []
                    for item in items { remove(item) }
                }
            }
            return freed
        }
    }

    /// 音频源文件缓存被清理或更换音质时，按 `(trackKey, packID, versionID, pipelineVersion)`
    /// 回退查找最新可用的已渲染成品，避免"明明转过却又播回原曲"。
    func latestRender(forTrackKey trackKey: String, packID: String, versionID: String) -> VoiceRender? {
        lock.withLock {
            let dir = url(for: .manifests)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return nil
            }
            let dec = JSONDecoder()
            var best: (createdAt: Date, render: VoiceRender)?
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f),
                      let m = try? dec.decode(RenderManifest.self, from: data),
                      m.pipelineVersion == Self.pipelineVersion,
                      m.trackKey == trackKey,
                      m.packID == packID,
                      m.versionID == versionID else { continue }
                let resolved = resolveFileURL(storedPath: m.filePath, cacheKey: m.cacheKey)
                guard fm.fileExists(atPath: resolved.path) else { continue }
                let render = VoiceRender(
                    trackKey: m.trackKey,
                    cacheKey: m.cacheKey,
                    fileURL: resolved,
                    duration: m.duration,
                    sampleRate: m.sampleRate,
                    packID: m.packID,
                    versionID: m.versionID,
                    pipelineVersion: m.pipelineVersion
                )
                if best == nil || m.createdAt > best!.createdAt {
                    best = (m.createdAt, render)
                }
            }
            return best?.render
        }
    }

    /// 清理低于当前管线版本的过期分离/合成/渲染缓存（如升级后废除旧版杂音缓存）。
    @discardableResult
    func pruneObsoletePipelineArtifacts() -> Int64 {
        lock.withLock {
            var freed: Int64 = 0
            let dec = JSONDecoder()
            let currentManifestPrefix = "render-\(Self.pipelineVersion)-"
            let mDir = url(for: .manifests)
            if let files = try? fm.contentsOfDirectory(at: mDir, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "json" {
                    let name = f.lastPathComponent
                    if let data = try? Data(contentsOf: f),
                       let m = try? dec.decode(RenderManifest.self, from: data) {
                        guard m.pipelineVersion < Self.pipelineVersion else { continue }
                        let audioURL = resolveFileURL(storedPath: m.filePath, cacheKey: m.cacheKey)
                        freed += fileSize(audioURL)
                        try? fm.removeItem(at: audioURL)
                        try? fm.removeItem(at: renderURL(renderKey: m.cacheKey))
                        freed += fileSize(f)
                        try? fm.removeItem(at: f)
                    } else if name.hasPrefix("render-"), !name.hasPrefix(currentManifestPrefix) {
                        freed += fileSize(f)
                        try? fm.removeItem(at: f)
                    }
                }
            }
            let validPrefixes = ["sep-\(Self.pipelineVersion)-", "vc-\(Self.pipelineVersion)-", currentManifestPrefix]
            for tier in [Tier.separation, .conversion, .renders] {
                let dir = url(for: tier)
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for item in items {
                    let name = item.lastPathComponent
                    if !validPrefixes.contains(where: { name.hasPrefix($0) }),
                       name.hasPrefix("sep-") || name.hasPrefix("vc-") || name.hasPrefix("render-") {
                        freed += fileSize(item)
                        try? fm.removeItem(at: item)
                    }
                }
            }
            return freed
        }
    }

    func evict(trackKey: String) {
        lock.withLock {
            let dir = url(for: .manifests)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return
            }
            let dec = JSONDecoder()
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f),
                      let m = try? dec.decode(RenderManifest.self, from: data),
                      m.trackKey == trackKey else { continue }
                let audioURL = resolveFileURL(storedPath: m.filePath, cacheKey: m.cacheKey)
                try? fm.removeItem(at: audioURL)
                try? fm.removeItem(at: renderURL(renderKey: m.cacheKey))
                try? fm.removeItem(at: f)
            }
        }
    }

    @discardableResult
    func clearAll() throws -> Int64 {
        try lock.withLock {
            let freed = totalCacheBytesLocked()
            for tier in [Tier.separation, .conversion, .renders, .manifests] {
                let tierURL = url(for: tier)
                let items = (try? fm.contentsOfDirectory(at: tierURL, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    try fm.removeItem(at: item)
                }
            }
            return freed
        }
    }

    func totalCacheBytes() -> Int64 {
        lock.withLock { totalCacheBytesLocked() }
    }

    /// 当三层缓存总量超过 `capacityBytes` 时 LRU 清理，并联动删除对应清单。
    /// 成品会在离线页列出，所以先清可重建的分离/转换中间文件，实在不够才动最旧的成品。
    @discardableResult
    func enforceCapacity() -> Int64 {
        lock.withLock {
            var entries: [(url: URL, tier: Tier, size: Int64, mtime: Date)] = []
            var total: Int64 = 0
            for tier in [Tier.renders, .conversion, .separation] {
                let dir = url(for: tier)
                guard let items = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
                ) else { continue }
                for item in items {
                    let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let sz = Int64(vals?.fileSize ?? 0)
                    let mtime = vals?.contentModificationDate ?? .distantPast
                    entries.append((item, tier, sz, mtime))
                    total += sz
                }
            }
            guard total > capacityBytes else { return 0 }
            entries.sort { lhs, rhs in
                let lhsIsRender = lhs.tier == .renders
                let rhsIsRender = rhs.tier == .renders
                if lhsIsRender != rhsIsRender { return !lhsIsRender }
                return lhs.mtime < rhs.mtime
            }
            var freed: Int64 = 0
            for entry in entries {
                if total - freed <= capacityBytes { break }
                if (try? fm.removeItem(at: entry.url)) != nil {
                    freed += entry.size
                    if entry.tier == .renders {
                        let key = entry.url.deletingPathExtension().lastPathComponent
                        try? fm.removeItem(at: manifestURL(renderKey: key))
                    }
                }
            }
            return freed
        }
    }

    // MARK: - Private

    private func resolveFileURL(storedPath: String, cacheKey: String) -> URL {
        if !storedPath.isEmpty {
            return URL(fileURLWithPath: storedPath)
        }
        return renderURL(renderKey: cacheKey)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(sz)
    }

    private func loadManifestsLocked() -> [(url: URL, manifest: RenderManifest)] {
        guard let files = try? fm.contentsOfDirectory(at: url(for: .manifests), includingPropertiesForKeys: nil) else {
            return []
        }
        let dec = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? dec.decode(RenderManifest.self, from: data) else { return nil }
            return (file, manifest)
        }
    }

    private func isInsideRoot(_ candidate: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func totalCacheBytesLocked() -> Int64 {
        var total: Int64 = 0
        for tier in [Tier.renders, .conversion, .separation, .manifests] {
            let dir = url(for: tier)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for item in items {
                total += fileSize(item)
            }
        }
        return total
    }

    private struct RenderManifest: Codable {
        var trackKey: String
        var cacheKey: String
        var filePath: String
        var duration: TimeInterval
        var sampleRate: Int
        var packID: String
        var versionID: String
        var pipelineVersion: Int
        var createdAt: Date
        var track: Track?
        var packName: String?
        var separationKey: String?
        var conversionKey: String?

        init(
            trackKey: String,
            cacheKey: String,
            filePath: String,
            duration: TimeInterval,
            sampleRate: Int,
            packID: String,
            versionID: String,
            pipelineVersion: Int,
            createdAt: Date,
            track: Track? = nil,
            packName: String? = nil,
            separationKey: String? = nil,
            conversionKey: String? = nil
        ) {
            self.trackKey = trackKey
            self.cacheKey = cacheKey
            self.filePath = filePath
            self.duration = duration
            self.sampleRate = sampleRate
            self.packID = packID
            self.versionID = versionID
            self.pipelineVersion = pipelineVersion
            self.createdAt = createdAt
            self.track = track
            self.packName = packName
            self.separationKey = separationKey
            self.conversionKey = conversionKey
        }

        enum CodingKeys: String, CodingKey {
            case trackKey, cacheKey, filePath, duration, sampleRate, packID, versionID, pipelineVersion, createdAt
            case track, packName, separationKey, conversionKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trackKey = try c.decode(String.self, forKey: .trackKey)
            cacheKey = try c.decode(String.self, forKey: .cacheKey)
            filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
            duration = try c.decode(TimeInterval.self, forKey: .duration)
            sampleRate = try c.decode(Int.self, forKey: .sampleRate)
            packID = try c.decode(String.self, forKey: .packID)
            versionID = try c.decode(String.self, forKey: .versionID)
            pipelineVersion = try c.decode(Int.self, forKey: .pipelineVersion)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            // 曲目信息坏了不该拖累整份清单：成品照样能播，只是离线页退回用身份反查歌名。
            track = try? c.decodeIfPresent(Track.self, forKey: .track)
            packName = try c.decodeIfPresent(String.self, forKey: .packName)
            separationKey = try c.decodeIfPresent(String.self, forKey: .separationKey)
            conversionKey = try c.decodeIfPresent(String.self, forKey: .conversionKey)
        }
    }
}
