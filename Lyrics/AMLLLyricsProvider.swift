import CryptoKit
import Foundation

/// 从 `amll-dev/amll-ttml-db`（CC0）取逐词歌词。
///
/// 两步走，代价都很小：
/// 1. 索引（约 1.7MB）**下载一次**并缓存到磁盘，之后本地检索；
/// 2. 命中之后才下载那一个 TTML 文件。
///
/// 不克隆整个仓库（750MB）——那对桌面应用是不可接受的启动代价。
@MainActor
final class AMLLLyricsProvider {
    /// 正式运行用的那一个。**测试宿主里不联网**：单元测试必须离线可复现，
    /// 而这条路径默认就挂在每一次歌词加载上。
    nonisolated static let shared = AMLLLyricsProvider(allowsNetwork: !RuntimeSandbox.isTestHost)

    private static let indexURL = URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl")!
    private static let fileBase = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/raw-lyrics/"

    /// 索引多久算过期。歌词库更新不快，一周足够。
    private static let indexTTL: TimeInterval = 7 * 24 * 3600
    /// 下载失败之后多久再试。
    private static let retryInterval: TimeInterval = 10 * 60

    private let session: URLSession
    private let allowsNetwork: Bool
    private let cacheDirectoryOverride: URL?
    private var cachedIndex: AMLLLyricsIndex?
    private var isRefreshing = false
    private var lastDownloadFailure: Date?

    nonisolated init(session: URLSession = .shared, allowsNetwork: Bool = true, cacheDirectory: URL? = nil) {
        self.session = session
        self.allowsNetwork = allowsNetwork
        self.cacheDirectoryOverride = cacheDirectory
    }

    private var cacheDirectory: URL? {
        let directory = cacheDirectoryOverride
            ?? RuntimeSandbox.cachesDirectory().appendingPathComponent("SpatialLyricsPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var indexCacheFile: URL? {
        cacheDirectory?.appendingPathComponent("amll-index.jsonl")
    }

    private var ttmlCacheDirectory: URL? {
        guard let directory = cacheDirectory?.appendingPathComponent("amll-ttml", isDirectory: true) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func ttmlCacheFile(for relativePath: String) -> URL? {
        let key = SHA256.hash(data: Data(relativePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        return ttmlCacheDirectory?.appendingPathComponent("\(key).ttml")
    }

    struct LoadedTTML: Sendable {
        let rawXML: String
        let lines: [LyricLine]
    }

    /// 取逐词歌词。没命中、拿不准或网络失败都返回 nil——调用方退回 LRCLIB。
    ///
    /// - Parameters:
    ///   - artistIsReliable: `artist` 是否真的是歌手（来自标题的「歌手 - 歌名」），
    ///     而不是拿 UP 主名字充数。
    ///   - duration: 曲目时长。只凭歌名对上的结果要靠它做旁证。
    func lyrics(title: String,
                artist: String?,
                artistIsReliable: Bool = false,
                duration: TimeInterval = 0,
                allowNetwork: Bool = true) async -> [LyricLine]? {
        let effectiveNetwork = allowsNetwork && allowNetwork
        let index = await ensureIndex(allowNetwork: effectiveNetwork)
        guard !index.entries.isEmpty,
              let match = index.match(title: title, artist: artist, artistIsReliable: artistIsReliable),
              let loaded = await resolveTTML(relativePath: match.entry.file, effectiveNetwork: effectiveNetwork) else {
            return nil
        }

        // 歌手没对上：只凭"同名"不够，再看时间轴和这条音频对不对得上。
        if !match.isArtistConfirmed, !Self.isPlausible(lines: loaded.lines, duration: duration) {
            return nil
        }
        return loaded.lines
    }

    /// 手动在 AMLL 索引中检索候选条目；已有本地索引时离线也能立即搜索。
    func search(title: String,
                artist: String? = nil,
                limit: Int = 10,
                allowNetwork: Bool = true) async -> [AMLLLyricsIndex.Entry] {
        let effectiveNetwork = allowsNetwork && allowNetwork
        let index = await ensureIndex(allowNetwork: effectiveNetwork)
        guard !index.entries.isEmpty else { return [] }
        return index.search(query: title, artist: artist, limit: limit)
    }

    /// 获取并缓存指定 AMLL 条目的 TTML 原文与解析结果，供手动绑定持久化使用。
    func loadTTML(for entry: AMLLLyricsIndex.Entry, allowNetwork: Bool = true) async -> LoadedTTML? {
        let effectiveNetwork = allowsNetwork && allowNetwork
        return await resolveTTML(relativePath: entry.file, effectiveNetwork: effectiveNetwork)
    }

    private func resolveTTML(relativePath: String, effectiveNetwork: Bool) async -> LoadedTTML? {
        if let cached = loadCachedTTML(for: relativePath) {
            return cached
        }
        guard effectiveNetwork,
              let url = Self.fileURL(for: relativePath),
              let data = try? await fetch(url),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let parsed = AMLLTTMLParser.parse(xml)
        guard !parsed.isEmpty else { return nil }
        storeTTML(data, for: relativePath)
        return LoadedTTML(rawXML: xml, lines: parsed)
    }

    private func loadCachedTTML(for relativePath: String) -> LoadedTTML? {
        guard let file = ttmlCacheFile(for: relativePath),
              let data = try? Data(contentsOf: file),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let parsed = AMLLTTMLParser.parse(xml)
        return parsed.isEmpty ? nil : LoadedTTML(rawXML: xml, lines: parsed)
    }

    private func storeTTML(_ data: Data, for relativePath: String) {
        guard let file = ttmlCacheFile(for: relativePath) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// 构造逐词歌词文件地址：对路径段做转义，避免文件名含空格或中文导致 URL 返回 nil。
    static func fileURL(for relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let base = URL(string: Self.fileBase) else { return nil }
        return base.appendingPathComponent(trimmed)
    }

    /// 时间轴和曲目时长是否**大致相容**。
    ///
    /// 同名异曲的时长几乎不会一样：歌词的最后一句既不该在曲子结束之后才开始，
    /// 也不该在曲子的前半段就唱完了。时长未知时没法旁证，按不相容处理。
    static func isPlausible(lines: [LyricLine], duration: TimeInterval) -> Bool {
        guard duration > 0, let last = lines.last else { return false }
        let lastEnd = last.end ?? last.start
        guard last.start <= duration + 2 else { return false }
        return lastEnd >= duration * 0.5 && lastEnd >= duration - 120
    }

    // MARK: - 索引

    private func ensureIndex(allowNetwork: Bool) async -> AMLLLyricsIndex {
        if let cachedIndex, !cachedIndex.entries.isEmpty { return cachedIndex }

        // 磁盘上有就先用，**哪怕已经过期**：旧索引只是少了最近新增的歌，
        // 而"过期就当没有"意味着一断网整个逐词歌词功能就消失了。
        if let cached = loadCachedIndex() {
            let index = AMLLLyricsIndex.parse(cached.data)
            if !index.entries.isEmpty {
                cachedIndex = index
                // 只在**真的过期**时后台刷新。之前这里不看新旧，
                // 每次启动的第一次歌词请求都会重下一遍 1.7MB。
                if !cached.isFresh, allowNetwork { refreshInBackground() }
                return index
            }
        }

        guard allowNetwork else { return .empty }
        // 刚失败过就先别再试：不让每一次歌词加载都白等一个超时。
        if let lastDownloadFailure,
           Date().timeIntervalSince(lastDownloadFailure) < Self.retryInterval {
            return .empty
        }
        guard let data = await downloadIndexData() else {
            lastDownloadFailure = Date()
            return .empty
        }
        return storeIndex(data) ?? .empty
    }

    /// 缓存是否还算新鲜。
    ///
    /// 抽成纯函数：原来这条判断和文件 I/O 缠在一起，覆盖率永远是 0，
    /// 也测不到"恰好过期"这种边界。
    static func isCacheFresh(modified: Date, now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(modified)
        // 时钟回拨（文件时间在未来）也当作新鲜：宁可先用旧索引，也别无谓地重下 1.7MB。
        if age < 0 { return true }
        return age < ttl
    }

    private func loadCachedIndex() -> (data: Data, isFresh: Bool)? {
        guard let file = indexCacheFile,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, Self.isCacheFresh(modified: modified, now: Date(), ttl: Self.indexTTL))
    }

    private func refreshInBackground() {
        guard allowsNetwork, !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            if let data = await self.downloadIndexData() { self.storeIndex(data) }
            self.isRefreshing = false
        }
    }

    /// 落盘并换上新索引。内容解析不出任何条目时**不覆盖**旧文件
    /// （拿到的可能是一张错误页），返回 nil。
    @discardableResult
    private func storeIndex(_ data: Data) -> AMLLLyricsIndex? {
        let index = AMLLLyricsIndex.parse(data)
        guard !index.entries.isEmpty else { return nil }
        if let file = indexCacheFile { try? data.write(to: file, options: .atomic) }
        cachedIndex = index
        return index
    }

    private func downloadIndexData() async -> Data? {
        guard allowsNetwork else { return nil }
        return try? await fetch(Self.indexURL)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.lyricsIndex
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
