import Foundation

/// 权威音乐曲库条目（来自已导入的正规音乐插件如 QQ 音乐/网易云，或 Apple iTunes 公开曲库）。
///
/// 用途：
/// 1. 搜歌交叉校准：把视频站搜索结果与正规曲库的 `(歌名, 歌手, 时长)` 比对，确认真歌并淘汰非音乐视频；
/// 2. 乱标题反向识别：面对没有书名号/横线的口水话视频标题，用曲库实体反推规范歌名、歌手与专辑。
struct MusicCatalogEntry: Sendable, Equatable, Hashable {
    enum Origin: String, Sendable, Hashable {
        case peerMusicPlugin
        case itunesPublic
    }

    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let origin: Origin

    var canonicalTitle: String {
        LyricQueryNormalizer.canonicalTitle(title)
    }
}

/// 权威歌曲目录解析器：优先复用用户已启用的正规音乐插件（如 QQ 音乐 / 网易云等非视频站源），
/// 默认兜底苹果官方公开免费的 iTunes Search API（HK 华语/日韩/欧美曲库，免 Key、合规）。
final class MusicCatalogResolver: @unchecked Sendable {
    static let shared = MusicCatalogResolver(allowsNetwork: !RuntimeSandbox.isTestHost)

    private static let itunesEndpoint = "https://itunes.apple.com/search"
    private static let cacheTTL: TimeInterval = 30 * 60
    private static let maxCacheEntries = 200

    private let session: URLSession
    private let allowsNetwork: Bool
    private let networkAllowed: @Sendable () -> Bool
    private weak var registry: SourceRegistry?
    private let lock = NSLock()
    private var cache: [String: (entries: [MusicCatalogEntry], fetchedAt: Date)] = [:]

    init(session: URLSession = .shared,
         allowsNetwork: Bool = true,
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         registry: SourceRegistry? = nil) {
        self.session = session
        self.allowsNetwork = allowsNetwork
        self.networkAllowed = networkAllowed
        self.registry = registry
    }

    /// 绑定当前应用的源注册表，使目录查询能自动优先借用已导入的正规音乐插件（如 QQ 音乐插件）。
    func attach(registry: SourceRegistry) {
        lock.withLock { self.registry = registry }
    }

    /// 查询关键词对应的权威歌曲目录列表（带内存缓存，避免重复请求）。
    func lookup(query rawQuery: String,
                excluding sourceID: SourceID? = nil,
                limit: Int = 10,
                allowNetwork: Bool = true) async -> [MusicCatalogEntry] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cacheKey = "\(sourceID?.rawValue ?? "*")::\(LyricQueryNormalizer.normalize(trimmed))"
        if let cached = cachedEntries(for: cacheKey) {
            return Array(cached.prefix(limit))
        }

        let canUseNetwork = allowsNetwork && allowNetwork && networkAllowed()
        var merged: [MusicCatalogEntry] = []

        // 1. 优先向用户已启用的正规音乐插件（如 QQ 音乐 / 网易云等非视频站源）查询歌曲目录。
        if canUseNetwork {
            let peers = peerCatalogProviders(excluding: sourceID)
            for provider in peers.prefix(2) {
                if Task.isCancelled { return [] }
                if let tracks = try? await provider.search(SearchRequest(query: trimmed, limit: limit)),
                   !tracks.isEmpty {
                    for track in tracks where !track.title.isEmpty && !track.artist.isEmpty {
                        merged.append(MusicCatalogEntry(
                            title: TextNormalizer.simplified(track.title),
                            artist: TextNormalizer.simplified(track.artist),
                            album: TextNormalizer.simplified(track.album ?? ""),
                            duration: track.duration,
                            origin: .peerMusicPlugin
                        ))
                    }
                    if merged.count >= 6 { break }
                }
            }
        }

        // 2. 兜底/补充：查询苹果官方公开的 iTunes Search API（HK 曲库对国漫/华语/港台/日韩覆盖全面）。
        if canUseNetwork && merged.count < 6 {
            if let itunesHits = await fetchITunesCatalog(term: trimmed, limit: max(limit, 10)) {
                merged.append(contentsOf: itunesHits)
            }
        }

        let deduped = Self.deduplicate(merged)
        if !deduped.isEmpty {
            storeCache(deduped, for: cacheKey)
        }
        return Array(deduped.prefix(limit))
    }

    /// 针对任意杂乱的视频标题，借助权威歌曲目录反推出规范的 `(歌名, 歌手, 专辑)`。
    func identify(rawTitle: String,
                  rawArtist: String,
                  duration: TimeInterval,
                  excluding sourceID: SourceID? = nil,
                  allowNetwork: Bool = true) async -> MusicCatalogEntry? {
        let parsed = LyricQueryNormalizer.parseTitle(rawTitle)
        let primaryTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primaryTitle.isEmpty else { return nil }

        // 先构造 1~2 个高命中查询词（优先 歌名 + 歌手，其次纯歌名，最后书名号/核心词）。
        var terms: [String] = []
        if let artist = parsed.artist, !artist.isEmpty {
            terms.append("\(primaryTitle) \(artist)")
        }
        terms.append(primaryTitle)

        // 若标题较长且没有书名号/歌手（如口水话标题 `在录音棚听马里奥唱主角太好听了`），
        // 抽取清理噪词后的核心词组去查曲库。
        if parsed.artist == nil, primaryTitle.count > 10 {
            let coreTerms = Self.extractSearchFragments(from: rawTitle)
            for term in coreTerms where !terms.contains(term) {
                terms.append(term)
            }
        }

        for term in terms.prefix(3) {
            if Task.isCancelled { return nil }
            let entries = await lookup(query: term, excluding: sourceID, limit: 12, allowNetwork: allowNetwork)
            if let hit = Self.matchTitleAgainstCatalog(
                rawTitle: rawTitle,
                rawArtist: rawArtist,
                duration: duration,
                entries: entries
            ) {
                return hit
            }
        }
        return nil
    }

    // MARK: - 纯函数交叉匹配（供搜歌与歌词识别共用，离线可完整单测）

    /// 检查单条权威曲目 `(歌名, 歌手, 时长)` 是否与视频标题/投稿人双向吻合。
    ///
    /// 返回匹配得分（0 表示不匹配）：
    /// - 歌名与歌手同时出现在视频标题/投稿人中 → 强确认命中（>= 22 分）；
    /// - 时长相容（±45s）额外加分，彻底区分同名异曲。
    static func matchScore(trackTitle: String,
                           trackArtist: String,
                           trackDuration: TimeInterval,
                           against entry: MusicCatalogEntry) -> Int {
        let entryTitle = entry.canonicalTitle
        guard !entryTitle.isEmpty else { return 0 }

        let context = LyricQueryNormalizer.MatchContext(trackTitle, trackArtist)
        let foldedTitle = TextNormalizer.simplified(trackTitle.precomposedStringWithCompatibilityMapping)
            .lowercased()
            .filter { !$0.isWhitespace }

        // 1. 歌名必须出现在视频标题中（支持繁简归一化与无标点匹配）。
        let titleMatched: Bool
        if entryTitle.count == 1 {
            // 单字歌名要求被书名号/引号/分隔符明确界定，避免普通汉字误撞。
            titleMatched = foldedTitle.contains("《\(entryTitle)》")
                || foldedTitle.contains("「\(entryTitle)」")
                || LyricQueryNormalizer.canonicalTitle(LyricQueryNormalizer.parseTitle(trackTitle).title) == entryTitle
        } else {
            titleMatched = context.folded.contains(entryTitle)
                || LyricQueryNormalizer.canonicalTitle(trackTitle).contains(entryTitle)
        }
        guard titleMatched else { return 0 }

        // 2. 歌手（含中英文别名）必须命中视频标题或投稿人。
        guard !entry.artist.isEmpty, context.mentions(artist: entry.artist) else { return 0 }

        // 3. 时长若两边都已知，差值超过 90 秒（且不是 Live 演唱会加长版）不视为同一单曲。
        var score = 22
        if trackDuration > 0 && entry.duration > 0 {
            let gap = abs(trackDuration - entry.duration)
            if gap <= 12 {
                score += 10
            } else if gap <= 45 {
                score += 6
            } else if gap <= 90 {
                score += 2
            } else {
                return 0
            }
        }

        // 书名号或解析主标题与权威歌名完全相等，再给精确度加分。
        let parsedMain = LyricQueryNormalizer.canonicalTitle(LyricQueryNormalizer.parseTitle(trackTitle).title)
        if parsedMain == entryTitle {
            score += 6
        }
        // 专辑/作品名也在标题里出现（如《斗破苍穹》），再给强旁证加分。
        let normAlbum = LyricQueryNormalizer.normalize(entry.album)
        if normAlbum.count >= 2 && normAlbum != entryTitle && context.folded.contains(normAlbum) {
            score += 4
        }
        return score
    }

    /// 从权威曲库候选中，选出与原始视频标题/时长最吻合的一条规范曲目。
    static func matchTitleAgainstCatalog(rawTitle: String,
                                         rawArtist: String,
                                         duration: TimeInterval,
                                         entries: [MusicCatalogEntry]) -> MusicCatalogEntry? {
        guard !entries.isEmpty else { return nil }
        var best: (entry: MusicCatalogEntry, score: Int)?
        for entry in entries {
            // 跳过纯伴奏目录条目（除非视频标题本身写明了伴奏）
            let lowerEntry = TextNormalizer.simplified(entry.title + " " + entry.album).lowercased()
            let lowerRaw = TextNormalizer.simplified(rawTitle).lowercased()
            if !lowerRaw.contains("伴奏") && (lowerEntry.contains("伴奏") || lowerEntry.contains("instrumental")) {
                continue
            }
            let s = matchScore(trackTitle: rawTitle, trackArtist: rawArtist, trackDuration: duration, against: entry)
            guard s > 0 else { continue }
            if best == nil || s > best!.score {
                best = (entry, s)
            }
        }
        return best?.entry
    }

    /// 从权威曲库中挑出最热门的不同歌手名，生成定向补搜词（如搜 `"主角"` → `["主角 马里奥", "主角 林俊杰"]`）。
    static func topArtistSupplementQueries(for rawQuery: String,
                                           entries: [MusicCatalogEntry],
                                           limit: Int = 2) -> [String] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let normQuery = LyricQueryNormalizer.canonicalTitle(trimmed)
        let lowerQuery = TextNormalizer.simplified(trimmed).lowercased()
        var artists: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard entry.canonicalTitle == normQuery || entry.canonicalTitle.contains(normQuery) else { continue }
            let cleanArtist = entry.artist
                .split(whereSeparator: { "/&,、".contains($0) })
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard cleanArtist.count >= 2 else { continue }
            let normArtist = LyricQueryNormalizer.normalize(cleanArtist)
            guard !normArtist.isEmpty, !lowerQuery.contains(normArtist), seen.insert(normArtist).inserted else { continue }
            artists.append("\(trimmed) \(cleanArtist)")
            if artists.count >= limit { break }
        }
        return artists
    }

    /// 解析 Apple iTunes Search API 的 JSON 响应（纯函数，便于离线单测）。
    static func parseITunesResponse(_ data: Data) -> [MusicCatalogEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["results"] as? [[String: Any]] else {
            return []
        }
        var results: [MusicCatalogEntry] = []
        results.reserveCapacity(rows.count)
        for row in rows {
            guard let rawTrack = row["trackName"] as? String,
                  let rawArtist = row["artistName"] as? String else { continue }
            let title = TextNormalizer.simplified(rawTrack).trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = TextNormalizer.simplified(rawArtist).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !artist.isEmpty else { continue }
            let album = TextNormalizer.simplified((row["collectionName"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let millis = (row["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0
            results.append(MusicCatalogEntry(
                title: title,
                artist: artist,
                album: album,
                duration: millis > 0 ? millis / 1000.0 : 0,
                origin: .itunesPublic
            ))
        }
        return deduplicate(results)
    }

    // MARK: - 内部网络与缓存辅助

    private func fetchITunesCatalog(term: String, limit: Int) async -> [MusicCatalogEntry]? {
        var components = URLComponents(string: Self.itunesEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: "hk"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 5), 15))),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.5
        request.setValue("FLOW/1.0 (music player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return Self.parseITunesResponse(data)
    }

    private func peerCatalogProviders(excluding sourceID: SourceID?) -> [any PlaybackSourceProvider] {
        guard let registry = lock.withLock({ self.registry }) else { return [] }
        return registry.allProviders.filter { provider in
            let desc = provider.descriptor
            return desc.id != sourceID
                && desc.id != .mock
                && desc.id != .localFile
                && desc.supportsSearch
                && !SearchResultFilter.isLikelyVideoSource(
                    sourceID: desc.id,
                    displayName: desc.displayName,
                    allowedDomains: desc.allowedDomains
                )
        }
    }

    private func cachedEntries(for key: String) -> [MusicCatalogEntry]? {
        lock.withLock {
            guard let item = cache[key] else { return nil }
            if Date().timeIntervalSince(item.fetchedAt) > Self.cacheTTL {
                cache.removeValue(forKey: key)
                return nil
            }
            return item.entries
        }
    }

    private func storeCache(_ entries: [MusicCatalogEntry], for key: String) {
        lock.withLock {
            if cache.count >= Self.maxCacheEntries {
                cache.removeAll()
            }
            cache[key] = (entries, Date())
        }
    }

    private static func deduplicate(_ entries: [MusicCatalogEntry]) -> [MusicCatalogEntry] {
        var seen = Set<String>()
        var result: [MusicCatalogEntry] = []
        for entry in entries {
            let key = "\(entry.canonicalTitle)|\(LyricQueryNormalizer.normalize(entry.artist))"
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }
        return result
    }

    private static func extractSearchFragments(from rawTitle: String) -> [String] {
        let stripped = rawTitle
            .replacingOccurrences(of: #"[【\[（(][^】\]）)]*[】\]）)]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?:在录音棚|百万豪装|豪装录音棚|戴上耳机|用十万|单曲循环|听一遍就爱上|太好听了|真的很好听|试听|聆听|听|唱|翻唱|的)"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return compact.count >= 2 && compact.count <= 24 ? [compact] : []
    }
}
