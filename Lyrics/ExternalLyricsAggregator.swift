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

    static let maxLyricQueries = 8

    func resolve(for track: Track,
                 hint: MetadataHint? = nil,
                 chosen: LRCLIBSource.Candidate? = nil,
                 allowNetwork: Bool) async throws -> LyricsDocument? {
        let rawTitle = hint?.title ?? track.title
        let rawArtist = hint?.artist ?? track.artist
        let parsed = LyricQueryNormalizer.parseTitle(rawTitle)
        let artist = parsed.artist ?? (rawArtist.isEmpty ? nil : rawArtist)
        let artistIsReliable = parsed.artist != nil
            || (!track.artist.isEmpty && rawTitle == track.title && track.artist != parsed.title && !track.sourceID.rawValue.isEmpty && !needsImplicitArtistUntrusted(track))
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

        if let cached = loadCachedLRC(primaryKey: primaryKey, legacyKey: legacyKey, title: parsed.title),
           let document = Self.document(fromLRC: cached, track: track) {
            return document
        }

        let offlineWordLevel = await Self.cachedWordLevelLyrics(
            track: track,
            title: parsed.title,
            artist: artist,
            artistIsReliable: artistIsReliable,
            wordLevelLyrics: wordLevelLyrics
        )
        if !allowNetwork {
            return offlineWordLevel
        }

        let searchTitle = hint?.alternativeTitle ?? parsed.title
        if hint?.alternativeTitle == nil || hint?.alternativeTitle == parsed.title, let offlineWordLevel {
            return offlineWordLevel
        }
        // 标题里可能有不止一个像歌名的片段（「冬之花/冬の花」「音质标签｜歌名」），逐字库按顺序都试一遍。
        var wordLevelTitles = [searchTitle]
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
                allowNetwork: true
            ), !wordLevel.isEmpty else { continue }
            return TextNormalizer.simplified(document: LyricsDocument(
                trackIdentity: track.identity,
                lines: wordLevel,
                source: .external,
                synchronization: .synced
            ))
        }

        var ranked: [LRCLIBSource.Candidate] = []
        if let alternative = hint?.alternativeTitle, alternative != parsed.title {
            ranked = try await searchRelaxed(
                title: alternative,
                artist: artist,
                duration: track.duration > 0 ? track.duration : nil
            )
        }
        if ranked.isEmpty {
            ranked = try await searchRelaxed(
                title: rawTitle,
                artist: artist,
                duration: track.duration > 0 ? track.duration : nil
            )
        }
        guard let picked = ranked.first, let lrc = picked.syncedLyrics else { return nil }
        let simplified = TextNormalizer.simplifiedLRC(lrc)
        cache.store(identity: primaryKey, title: parsed.title, lrc: simplified)
        if let legacyKey, legacyKey != primaryKey {
            cache.store(identity: legacyKey, title: parsed.title, lrc: simplified)
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
        return await Self.cachedWordLevelLyrics(
            track: track,
            title: parsed.title,
            artist: artist,
            artistIsReliable: parsed.artist != nil,
            wordLevelLyrics: wordLevelLyrics
        )
    }

    /// 逐个候选歌名去查，由查到的结果反过来验证候选。
    ///
    /// 每个候选的结果都按**它自己的歌名**比对（之前一律按第一个候选比，后面的候选查到了也会被判成无关）。
    /// 结果里的歌手若出现在视频标题或投稿人里，就是强证据，立刻采用；
    /// 没有歌手旁证的，先记下第一个正经候选的结果，等其余候选都试过再用它兜底。
    func searchRelaxed(title: String,
                       artist: String?,
                       duration: TimeInterval?,
                       limit: Int = 5,
                       requiresCompatibleDuration: Bool = true) async throws -> [LRCLIBSource.Candidate] {
        struct Query { var title: String; var artist: String?; var isGuess: Bool }
        var queries: [Query] = []
        var seen = Set<String>()
        func add(_ t: String, _ a: String?, isGuess: Bool) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return }
            guard seen.insert(trimmed + "|" + (a ?? "")).inserted else { return }
            queries.append(Query(title: trimmed, artist: a, isGuess: isGuess))
        }

        let candidates = LyricQueryNormalizer.titleCandidates(title)
        for candidate in candidates {
            add(candidate.title, candidate.artist, isGuess: candidate.isGuess)
        }
        if let artist, !artist.isEmpty, let primary = candidates.first(where: { !$0.isGuess }) {
            add(primary.title, artist, isGuess: false)
        }

        let context = LyricQueryNormalizer.MatchContext(title, artist)
        var fallback: [LRCLIBSource.Candidate] = []
        var firstFailure: (any Error)?
        var anyQuerySucceeded = false
        for query in queries.prefix(Self.maxLyricQueries) {
            try Task.checkCancellation()
            // 候选多了，单次请求失败不该让整轮检索作废；全部失败才把错误报上去。
            let found: [LRCLIBSource.Candidate]
            do {
                found = try await lrclib.search(title: query.title, artist: query.artist)
                anyQuerySucceeded = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if firstFailure == nil { firstFailure = error }
                continue
            }
            let ranked = LRCLIBSource.rank(
                found,
                title: query.title,
                artist: query.artist ?? artist,
                duration: duration,
                limit: limit,
                requiresCompatibleDuration: requiresCompatibleDuration,
                context: context,
                requiresArtistEvidence: query.isGuess
            )
            guard let top = ranked.first else { continue }
            if LRCLIBSource.hasArtistEvidence(top, context: context) { return ranked }
            if fallback.isEmpty { fallback = ranked }
        }
        if fallback.isEmpty, !anyQuerySucceeded, let firstFailure { throw firstFailure }
        return fallback
    }

    static func cachedWordLevelLyrics(track: Track,
                                      title: String,
                                      artist: String?,
                                      artistIsReliable: Bool,
                                      wordLevelLyrics: AMLLLyricsProvider?) async -> LyricsDocument? {
        guard let lines = await wordLevelLyrics?.lyrics(
            title: title,
            artist: artist,
            artistIsReliable: artistIsReliable,
            duration: track.duration,
            allowNetwork: false
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

    private func needsImplicitArtistUntrusted(_ track: Track) -> Bool {
        // 视频投稿类插件（如外置 B 站插件）标题未标明歌手时，author 可能是 UP 主而非演唱者。
        track.sourceID.rawValue == "js-bilibili" || track.sourceID.rawValue == "bilibili"
    }
}
