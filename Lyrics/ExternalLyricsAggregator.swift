import Foundation

/// 源无关的外部歌词自动聚合检索器：磁盘 LRC 缓存 → AMLL 逐字 TTML → LRCLIB 递进搜索。
struct ExternalLyricsAggregator: Sendable {
    struct MetadataHint: Sendable {
        var title: String
        var artist: String
        var alternativeTitle: String?
        var legacyCacheKey: String?
    }

    var cache: LyricDocumentCache = .shared
    var wordLevelLyrics: AMLLLyricsProvider? = .shared
    var lrclib: LRCLIBSource = LRCLIBSource()
    var catalogResolver: MusicCatalogResolver? = .shared

    static let maxLyricQueries = 10

    func resolve(for track: Track,
                 hint: MetadataHint? = nil,
                 chosen: LRCLIBSource.Candidate? = nil,
                 allowNetwork: Bool) async throws -> LyricsDocument? {
        let rawTitle = hint?.title ?? track.title
        let rawArtist = hint?.artist ?? track.artist
        let parsed = LyricQueryNormalizer.parseTitle(rawTitle)
        let untrustedImplicitArtist = Self.isImplicitArtistUntrusted(for: track)

        // 当视频站标题未标明歌手（如口水话标题 `在录音棚听马里奥唱主角太好听了`）且联网可用时，
        // 借助权威歌曲目录（优先已导入的正规音乐插件如 QQ 音乐，兜底 Apple iTunes 公开曲库）反向识别规范歌名与歌手。
        var catalogMatch: MusicCatalogEntry? = nil
        if allowNetwork, chosen == nil, untrustedImplicitArtist, parsed.artist == nil,
           let resolver = catalogResolver {
            catalogMatch = await resolver.identify(
                rawTitle: rawTitle,
                rawArtist: rawArtist,
                duration: track.duration,
                excluding: track.sourceID,
                allowNetwork: allowNetwork
            )
        }

        let resolvedTitle = catalogMatch.map { LyricQueryNormalizer.parseTitle($0.title).title } ?? parsed.title
        let artist: String?
        if let catArtist = catalogMatch?.artist, !catArtist.isEmpty {
            artist = catArtist
        } else if let parsedArtist = parsed.artist, !parsedArtist.isEmpty {
            artist = parsedArtist
        } else if !rawArtist.isEmpty {
            artist = rawArtist
        } else {
            artist = nil
        }
        let artistIsReliable = catalogMatch != nil
            || parsed.artist != nil
            || (!track.artist.isEmpty && rawTitle == track.title && track.artist != parsed.title && !track.sourceID.rawValue.isEmpty && !untrustedImplicitArtist)
        let matchContext = LyricQueryNormalizer.MatchContext(rawTitle, rawArtist, catalogMatch?.artist, catalogMatch?.album)
        let primaryKey = TrackIdentity.storageKey(track.identity)
        let legacyKey = hint?.legacyCacheKey

        if let chosen {
            guard let lrc = chosen.syncedLyrics, !lrc.isEmpty else { return nil }
            let simplified = TextNormalizer.simplifiedLRC(lrc)
            cache.store(identity: primaryKey, title: parsed.title, lrc: simplified)
            if let legacyKey, legacyKey != primaryKey {
                cache.store(identity: legacyKey, title: parsed.title, lrc: simplified)
            }
            return Self.document(fromLRC: lrc, track: track)
        }

        if let cached = loadCachedLRC(primaryKey: primaryKey, legacyKey: legacyKey, title: resolvedTitle)
            ?? (resolvedTitle != parsed.title ? loadCachedLRC(primaryKey: primaryKey, legacyKey: legacyKey, title: parsed.title) : nil),
           let document = Self.document(fromLRC: cached, track: track) {
            let cacheConsistent = !allowNetwork
                || Self.isCachedDocumentConsistent(
                    document,
                    reliableArtist: artistIsReliable ? artist : nil,
                    context: matchContext
                )
            if cacheConsistent {
                return document
            }
        }

        let offlineWordLevel = await Self.cachedWordLevelLyrics(
            track: track,
            title: resolvedTitle,
            artist: artist,
            artistIsReliable: artistIsReliable,
            context: matchContext,
            wordLevelLyrics: wordLevelLyrics
        )
        if !allowNetwork {
            return offlineWordLevel
        }

        let searchTitle = hint?.alternativeTitle ?? resolvedTitle
        if hint?.alternativeTitle == nil || hint?.alternativeTitle == resolvedTitle, let offlineWordLevel {
            return offlineWordLevel
        }
        // 标题里可能有不止一个像歌名的片段（「冬之花/冬の花」「音质标签｜歌名」），逐字库按顺序都试一遍。
        var wordLevelTitles = [searchTitle]
        if let cat = catalogMatch {
            let cleanCat = LyricQueryNormalizer.canonicalTitle(cat.title)
            if !cleanCat.isEmpty && !wordLevelTitles.contains(cleanCat) {
                wordLevelTitles.append(cat.title)
            }
        }
        if hint?.alternativeTitle == nil {
            for candidate in LyricQueryNormalizer.titleCandidates(rawTitle)
            where !candidate.isGuess && !wordLevelTitles.contains(candidate.title) {
                wordLevelTitles.append(candidate.title)
            }
        }
        for (position, wordLevelTitle) in wordLevelTitles.prefix(4).enumerated() {
            guard let wordLevel = await wordLevelLyrics?.lyrics(
                title: wordLevelTitle,
                artist: artist,
                artistIsReliable: position == 0 && artistIsReliable,
                duration: track.duration,
                allowNetwork: true,
                context: matchContext
            ), !wordLevel.isEmpty else { continue }
            return TextNormalizer.simplified(document: LyricsDocument(
                trackIdentity: track.identity,
                lines: wordLevel,
                source: .external,
                synchronization: .synced
            ))
        }

        var ranked: [LRCLIBSource.Candidate] = []
        if let cat = catalogMatch {
            let catTitle = LyricQueryNormalizer.parseTitle(cat.title).title
            ranked = try await searchRelaxed(
                title: "\(cat.artist) - \(catTitle)",
                artist: cat.artist,
                duration: track.duration > 0 ? track.duration : nil,
                artistIsReliable: true
            )
        }
        if ranked.isEmpty, let alternative = hint?.alternativeTitle, alternative != parsed.title {
            ranked = try await searchRelaxed(
                title: alternative,
                artist: artistIsReliable ? artist : nil,
                duration: track.duration > 0 ? track.duration : nil,
                artistIsReliable: artistIsReliable
            )
        }
        if ranked.isEmpty {
            ranked = try await searchRelaxed(
                title: rawTitle,
                artist: artist,
                duration: track.duration > 0 ? track.duration : nil,
                artistIsReliable: artistIsReliable
            )
        }
        guard let picked = ranked.first, let lrc = picked.syncedLyrics else { return nil }
        let simplified = Self.annotatingMetadataIfMissing(TextNormalizer.simplifiedLRC(lrc), candidate: picked)
        cache.store(identity: primaryKey, title: resolvedTitle, lrc: simplified)
        if resolvedTitle != parsed.title {
            cache.store(identity: primaryKey, title: parsed.title, lrc: simplified)
        }
        if let legacyKey, legacyKey != primaryKey {
            cache.store(identity: legacyKey, title: resolvedTitle, lrc: simplified)
        }
        return Self.document(fromLRC: lrc, track: track)
    }

    func cachedOfflineLyrics(for track: Track, legacyCacheKey: String? = nil) async -> LyricsDocument? {
        let parsed = LyricQueryNormalizer.parseTitle(track.title)
        let primaryKey = TrackIdentity.storageKey(track.identity)
        if let cached = cache.load(identity: primaryKey, title: parsed.title)
            ?? legacyCacheKey.flatMap({ cache.load(identity: $0, title: parsed.title) }),
           let doc = Self.document(fromLRC: cached, track: track) {
            return doc
        }
        let artist = parsed.artist ?? (track.artist.isEmpty ? nil : track.artist)
        let matchContext = LyricQueryNormalizer.MatchContext(track.title, track.artist)
        return await Self.cachedWordLevelLyrics(
            track: track,
            title: parsed.title,
            artist: artist,
            artistIsReliable: parsed.artist != nil,
            context: matchContext,
            wordLevelLyrics: wordLevelLyrics
        )
    }

    /// 逐个候选歌名去查，由查到的结果反过来验证候选。
    ///
    /// 每个候选的结果都按**它自己的歌名**比对（之前一律按第一个候选比，后面的候选查到了也会被判成无关）。
    /// 结果里的歌手若出现在视频标题或投稿人里，就是强证据，立刻采用；
    /// 没有歌手旁证的，择优记录兜底结果，并在全部查询均无返回时尝试繁体与全文 `q=` 检索。
    func searchRelaxed(title: String,
                       artist: String?,
                       duration: TimeInterval?,
                       limit: Int = 5,
                       requiresCompatibleDuration: Bool = true,
                       artistIsReliable: Bool = false) async throws -> [LRCLIBSource.Candidate] {
        struct Query { var title: String; var artist: String?; var album: String? = nil; var isGuess: Bool; var reliableArtist: Bool }
        var queries: [Query] = []
        var seen = Set<String>()
        func add(_ t: String, _ a: String?, album: String? = nil, isGuess: Bool, reliableArtist: Bool) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSingleCJK = trimmed.count == 1 && trimmed.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value) || (0x3041...0x30FA).contains($0.value)
            }
            guard trimmed.count >= 2 || (!isGuess && isSingleCJK) else { return }
            let key = "\(trimmed)|\(a ?? "")|\(album ?? "")"
            guard seen.insert(key).inserted else { return }
            queries.append(Query(title: trimmed, artist: a, album: album, isGuess: isGuess, reliableArtist: reliableArtist))
        }

        let candidates = LyricQueryNormalizer.titleCandidates(title)
        let workHints = LyricQueryNormalizer.workHints(title)
        let explicitBookArtist: String? = title.contains("《") ? candidates.first(where: { !$0.isGuess })?.artist : nil
        let effectiveArtistReliable = artistIsReliable || (explicitBookArtist != nil)
        let primaryReliableArtist = explicitBookArtist ?? (artistIsReliable ? artist : nil)

        for candidate in candidates {
            let queryReliable = effectiveArtistReliable && (candidate.artist != nil || primaryReliableArtist != nil)
            add(candidate.title, candidate.artist, isGuess: candidate.isGuess, reliableArtist: queryReliable)
            if let candidateArtist = candidate.artist {
                // 若该歌手有英文/中文别名（如 周杰伦↔Jay Chou、马里奥↔Mario），用别名补查，防止被前 20 条截断。
                for alias in LyricQueryNormalizer.MatchContext.aliases(for: candidateArtist) {
                    add(candidate.title, alias, isGuess: candidate.isGuess, reliableArtist: queryReliable)
                }
                // 同步追加仅按歌名查询，靠 MatchContext 别名表与作品出处反证。
                add(candidate.title, nil, isGuess: candidate.isGuess, reliableArtist: queryReliable)
            }
            // 对带影视/动漫作品出处的 OST（如《斗破苍穹》动画第四季），追加 album_name 检索。
            if !candidate.isGuess, let work = workHints.first {
                add(candidate.title, nil, album: work, isGuess: false, reliableArtist: queryReliable)
            }
        }
        if let artist, !artist.isEmpty, let primary = candidates.first(where: { !$0.isGuess }) {
            add(primary.title, artist, isGuess: false, reliableArtist: effectiveArtistReliable)
        }

        let context = LyricQueryNormalizer.MatchContext(title, artist)
        var bestFallback: (candidates: [LRCLIBSource.Candidate], rankKey: (Int, Double))?
        var firstFailure: (any Error)?
        var anyQuerySucceeded = false
        var anyRawResultReturned = false
        var queriesSent = 0

        func consider(_ found: [LRCLIBSource.Candidate], for query: Query) -> [LRCLIBSource.Candidate]? {
            if !found.isEmpty { anyRawResultReturned = true }
            let targetArtist = query.artist ?? primaryReliableArtist ?? artist
            let ranked = LRCLIBSource.rank(
                found,
                title: query.title,
                artist: targetArtist,
                duration: duration,
                limit: limit,
                requiresCompatibleDuration: requiresCompatibleDuration,
                context: context,
                requiresArtistEvidence: query.isGuess,
                artistIsReliable: query.reliableArtist
            )
            guard let top = ranked.first else { return nil }
            if LRCLIBSource.hasArtistEvidence(top, context: context)
                || LRCLIBSource.hasAlbumEvidence(top, context: context) {
                return ranked
            }
            let exactTitle = LyricQueryNormalizer.normalize(top.trackName) == LyricQueryNormalizer.normalize(query.title) ? 1 : 0
            let delta = (duration != nil && duration! > 0 && top.duration > 0) ? abs(top.duration - duration!) : 999
            if bestFallback == nil
                || exactTitle > bestFallback!.rankKey.0
                || (exactTitle == bestFallback!.rankKey.0 && delta < bestFallback!.rankKey.1) {
                bestFallback = (ranked, (exactTitle, delta))
            }
            return nil
        }

        for query in queries {
            guard queriesSent < Self.maxLyricQueries else { break }
            try Task.checkCancellation()
            // 候选多了，单次请求失败不该让整轮检索作废；全部失败才把错误报上去。
            let found: [LRCLIBSource.Candidate]
            do {
                queriesSent += 1
                found = try await lrclib.search(title: query.title, artist: query.artist, album: query.album)
                anyQuerySucceeded = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if firstFailure == nil { firstFailure = error }
                continue
            }
            if let confirmed = consider(found, for: query) {
                return confirmed
            }
            // 上游返空时若歌名存在繁体写法（如 演员→演員 / 说好不哭→說好不哭），补查一次繁体。
            if found.isEmpty, queriesSent < Self.maxLyricQueries {
                let traditionalTitle = TextNormalizer.traditional(query.title)
                if traditionalTitle != query.title {
                    try Task.checkCancellation()
                    if let tradFound = try? await lrclib.search(title: traditionalTitle, artist: query.artist, album: query.album) {
                        queriesSent += 1
                        anyQuerySucceeded = true
                        if let confirmed = consider(
                            tradFound,
                            for: Query(title: traditionalTitle, artist: query.artist, album: query.album, isGuess: query.isGuess, reliableArtist: query.reliableArtist)
                        ) {
                            return confirmed
                        }
                    }
                }
            }
        }

        // 所有 track_name 请求都未拿到任何候选时，再用自由词 `/api/search?q=` 兜底一次（覆盖歌手/歌名混写或副标题差异）。
        if bestFallback == nil, !anyRawResultReturned, queriesSent < Self.maxLyricQueries,
           let primary = candidates.first(where: { !$0.isGuess }) {
            let keywordQuery = [primary.title, primary.artist ?? workHints.first]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !keywordQuery.isEmpty {
                try Task.checkCancellation()
                if let qFound = try? await lrclib.search(keyword: keywordQuery) {
                    anyQuerySucceeded = true
                    if let confirmed = consider(
                        qFound,
                        for: Query(title: primary.title, artist: primary.artist, isGuess: false, reliableArtist: effectiveArtistReliable)
                    ) {
                        return confirmed
                    }
                }
            }
        }

        if let fallback = bestFallback?.candidates {
            return fallback
        }
        if !anyQuerySucceeded, let firstFailure { throw firstFailure }
        return []
    }

    static func cachedWordLevelLyrics(track: Track,
                                      title: String,
                                      artist: String?,
                                      artistIsReliable: Bool,
                                      context: LyricQueryNormalizer.MatchContext? = nil,
                                      wordLevelLyrics: AMLLLyricsProvider?) async -> LyricsDocument? {
        guard let lines = await wordLevelLyrics?.lyrics(
            title: title,
            artist: artist,
            artistIsReliable: artistIsReliable,
            duration: track.duration,
            allowNetwork: false,
            context: context
        ), !lines.isEmpty else { return nil }
        return TextNormalizer.simplified(document: LyricsDocument(
            trackIdentity: track.identity,
            lines: lines,
            source: .external,
            synchronization: .synced
        ))
    }

    static func document(fromLRC lrc: String, track: Track) -> LyricsDocument? {
        guard let parsed = LRCParser.parse(lrc), !parsed.lines.isEmpty else { return nil }
        return LyricsDocument(
            trackIdentity: track.identity,
            lines: parsed.lines,
            metadata: parsed.metadata,
            source: .external,
            synchronization: parsed.synchronization
        )
    }

    private func loadCachedLRC(primaryKey: String, legacyKey: String?, title: String) -> String? {
        if let hit = cache.load(identity: primaryKey, title: title) {
            return hit
        }
        if let legacyKey, let hit = cache.load(identity: legacyKey, title: title) {
            return hit
        }
        return nil
    }

    /// 视频投稿类插件（如外置 B 站 / bilibili-fetch / YouTube 插件）在标题未标明歌手时，
    /// `track.artist` 通常是投稿 UP 主而非演唱者，不能当作可靠歌手卡死匹配。
    static func isImplicitArtistUntrusted(for track: Track) -> Bool {
        SearchResultFilter.isLikelyVideoSource(sourceID: track.sourceID)
    }

    /// 缓存写盘时补齐缺失的 `[ar:]` 元标签，方便后续自检淘汰历史错配缓存。
    private static func annotatingMetadataIfMissing(_ lrc: String, candidate: LRCLIBSource.Candidate) -> String {
        let lower = lrc.lowercased()
        let artist = candidate.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !lower.contains("[ar:") else { return lrc }
        return "[ar:\(artist)]\n" + lrc
    }

    /// 校验磁盘缓存里的 `[ar:]` 歌手是否与当前曲目已知可靠歌手矛盾。
    /// 没有 `[ar:]` 标签（老缓存或纯时间轴）时放行；仅在明确标注了不同歌手且完全不匹配上下文时淘汰。
    private static func isCachedDocumentConsistent(_ document: LyricsDocument,
                                                   reliableArtist: String?,
                                                   context: LyricQueryNormalizer.MatchContext) -> Bool {
        guard let reliableArtist, !reliableArtist.isEmpty,
              let cachedArtist = document.metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cachedArtist.isEmpty else {
            return true
        }
        if context.mentions(artist: cachedArtist) { return true }
        let normCached = LyricQueryNormalizer.normalize(cachedArtist)
        let normWanted = LyricQueryNormalizer.normalize(reliableArtist)
        if normCached == normWanted
            || (normWanted.count >= 2 && normCached.contains(normWanted))
            || (normCached.count >= 2 && normWanted.contains(normCached)) {
            return true
        }
        return LyricQueryNormalizer.MatchContext(reliableArtist).mentions(artist: cachedArtist)
    }
}
