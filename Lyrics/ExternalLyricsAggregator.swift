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

    static let maxLyricQueries = 6

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
        if let wordLevel = await wordLevelLyrics?.lyrics(
            title: searchTitle,
            artist: artist,
            artistIsReliable: artistIsReliable,
            duration: track.duration,
            allowNetwork: true
        ), !wordLevel.isEmpty {
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

    func searchRelaxed(title: String,
                       artist: String?,
                       duration: TimeInterval?,
                       limit: Int = 5,
                       requiresCompatibleDuration: Bool = true) async throws -> [LRCLIBSource.Candidate] {
        let wantedTitle = LyricQueryNormalizer.parseTitle(title).title
        var queries: [(String, String?)] = []
        var seen = Set<String>()
        func add(_ t: String, _ a: String?) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return }
            guard seen.insert(trimmed + "|" + (a ?? "")).inserted else { return }
            queries.append((trimmed, a))
        }

        for candidate in LyricQueryNormalizer.titleCandidates(title) {
            add(candidate.title, nil)
            if let artist = candidate.artist { add(candidate.title, artist) }
        }
        if let artist, !artist.isEmpty {
            add(LyricQueryNormalizer.parseTitle(title).title, artist)
        }

        for (queryTitle, queryArtist) in queries.prefix(Self.maxLyricQueries) {
            try Task.checkCancellation()
            let candidates = try await lrclib.search(title: queryTitle, artist: queryArtist)
            let ranked = LRCLIBSource.rank(
                candidates,
                title: wantedTitle,
                artist: queryArtist ?? artist,
                duration: duration,
                limit: limit,
                requiresCompatibleDuration: requiresCompatibleDuration
            )
            if !ranked.isEmpty { return ranked }
        }
        return []
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
