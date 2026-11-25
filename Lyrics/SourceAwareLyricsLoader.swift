import Foundation

/// 歌词加载的统一策略。
///
/// 优先级顺序：
/// 1. 用户按 `TrackIdentity` 手动绑定的歌词版本（`LyricBindingStore`）；
/// 2. 数据源自身提供的原生歌词（本地 `.lrc` / 内嵌标签、OpenSubsonic、JS 插件或 B 站字幕）；
/// 3. 本地音频文件同目录 `.lrc` / 内嵌标签兜底（`FileLyricsLoader`）；
/// 4. 外部歌词聚合器（`ExternalLyricsAggregator`：磁盘缓存 → AMLL 逐字 TTML → LRCLIB）；
/// 5. 其他已启用的跨源歌词插件协同兜底（当本源与 AMLL/LRCLIB 均未命中时，向已导入的歌词/音乐插件借歌词）；
/// 6. 离线缓存歌词兜底（`offlineFallback`）。
struct SourceAwareLyricsLoader: LyricsLoading {
    let registry: SourceRegistry
    let local = FileLyricsLoader()
    var bindingStore: LyricBindingStore? = nil
    var externalAggregator: ExternalLyricsAggregator? = nil
    var networkAllowed: @Sendable () -> Bool = { true }
    var offlineFallback: (@Sendable (Track) async -> LyricsDocument?)? = nil

    func loadLyrics(for track: Track) async -> LyricsDocument? {
        if let bound = await bindingStore?.document(for: track), !bound.lines.isEmpty {
            return bound
        }
        if let provider = registry.provider(for: track.sourceID),
           let document = try? await provider.lyrics(for: track),
           !document.lines.isEmpty {
            return document
        }
        if let fileLyrics = await local.loadLyrics(for: track), !fileLyrics.lines.isEmpty {
            return fileLyrics
        }
        if track.sourceID != .mock,
           let externalAggregator,
           let external = try? await externalAggregator.resolve(for: track, allowNetwork: networkAllowed()),
           !external.lines.isEmpty {
            return external
        }
        if track.sourceID != .mock,
           networkAllowed(),
           let crossSource = await loadFromOtherLyricProviders(for: track),
           !crossSource.lines.isEmpty {
            return crossSource
        }
        if let offline = await offlineFallback?(track), !offline.lines.isEmpty {
            return offline
        }
        return nil
    }

    /// 跨源歌词协同：向其他已启用且同时支持「搜索 + 歌词」的外部插件（如用户导入的歌词网/音乐平台插件）
    /// 借取同步歌词，严格复用歌名 + 歌手 + 时长防错配校验，绝不盲取同名异曲。
    private func loadFromOtherLyricProviders(for track: Track) async -> LyricsDocument? {
        let peers = registry.allProviders.filter { provider in
            let desc = provider.descriptor
            return desc.id != track.sourceID
                && desc.id != .mock
                && desc.id != .localFile
                && desc.supportsSearch
                && desc.supportsLyrics
                && !SearchResultFilter.isLikelyVideoSource(
                    sourceID: desc.id,
                    displayName: desc.displayName,
                    allowedDomains: desc.allowedDomains
                )
        }
        guard !peers.isEmpty else { return nil }

        let parsed = LyricQueryNormalizer.parseTitle(track.title)
        let wantedTitle = LyricQueryNormalizer.canonicalTitle(parsed.title)
        guard !wantedTitle.isEmpty else { return nil }

        let untrustedArtist = ExternalLyricsAggregator.isImplicitArtistUntrusted(for: track)
        let reliableArtist: String? = {
            if let a = parsed.artist, !a.isEmpty { return a }
            if !untrustedArtist, !track.artist.isEmpty, track.artist != parsed.title { return track.artist }
            return nil
        }()
        let context = LyricQueryNormalizer.MatchContext(track.title, track.artist)
        let searchQuery = [parsed.title, reliableArtist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        for provider in peers.prefix(3) {
            if Task.isCancelled { return nil }
            guard let candidates = try? await provider.search(SearchRequest(query: searchQuery, limit: 10)),
                  !candidates.isEmpty else { continue }
            guard let picked = Self.pickVerifiedPeerCandidate(
                candidates,
                wantedTitle: wantedTitle,
                reliableArtist: reliableArtist,
                duration: track.duration,
                context: context
            ) else { continue }
            guard let doc = try? await provider.lyrics(for: picked),
                  doc.isSynced,
                  !doc.lines.isEmpty else { continue }
            return LyricsDocument(
                trackIdentity: track.identity,
                lines: doc.lines,
                metadata: doc.metadata,
                source: .external,
                synchronization: doc.synchronization,
                embeddedOffset: doc.embeddedOffset
            )
        }
        return nil
    }

    static func pickVerifiedPeerCandidate(_ candidates: [Track],
                                          wantedTitle: String,
                                          reliableArtist: String?,
                                          duration: TimeInterval,
                                          context: LyricQueryNormalizer.MatchContext) -> Track? {
        let wantedArtistNorm = reliableArtist.map { LyricQueryNormalizer.normalize($0) } ?? ""
        let artistContext = reliableArtist.flatMap { LyricQueryNormalizer.MatchContext($0) }

        func titleMatches(_ candidate: Track) -> Bool {
            let candTitle = LyricQueryNormalizer.canonicalTitle(candidate.title)
            guard !candTitle.isEmpty else { return false }
            if candTitle == wantedTitle { return true }
            let shorter = min(candTitle.count, wantedTitle.count)
            let longer = max(candTitle.count, wantedTitle.count)
            return shorter >= 2
                && Double(shorter) / Double(max(longer, 1)) >= 0.6
                && (candTitle.contains(wantedTitle) || wantedTitle.contains(candTitle))
        }

        func artistConfirmed(_ candidate: Track) -> Bool {
            guard !candidate.artist.isEmpty else { return false }
            if context.mentions(artist: candidate.artist) { return true }
            if !wantedArtistNorm.isEmpty {
                let norm = LyricQueryNormalizer.normalize(candidate.artist)
                if norm == wantedArtistNorm
                    || (wantedArtistNorm.count >= 2 && norm.contains(wantedArtistNorm))
                    || (norm.count >= 2 && wantedArtistNorm.contains(norm)) {
                    return true
                }
                if artistContext?.mentions(artist: candidate.artist) == true { return true }
            }
            return false
        }

        let titleHits = candidates.filter(titleMatches)
        guard !titleHits.isEmpty else { return nil }

        let distinctArtists = Set(
            titleHits.map { LyricQueryNormalizer.normalize($0.artist) }.filter { !$0.isEmpty }
        )
        let isAmbiguous = distinctArtists.count >= 2

        let eligible = titleHits.filter { candidate in
            let confirmed = artistConfirmed(candidate)
            if isAmbiguous && !confirmed { return false }
            if reliableArtist != nil && !confirmed && (wantedTitle.count <= 3 || isAmbiguous) {
                return false
            }
            if duration > 0 && candidate.duration > 0 {
                let gap = abs(candidate.duration - duration)
                let limit: TimeInterval = confirmed ? 50 : 30
                if gap > limit { return false }
            }
            return true
        }

        return eligible.max { lhs, rhs in
            let lScore = (artistConfirmed(lhs) ? 50 : 0)
                + (LyricQueryNormalizer.canonicalTitle(lhs.title) == wantedTitle ? 30 : 10)
                - (duration > 0 && lhs.duration > 0 ? Int(abs(lhs.duration - duration)) : 15)
            let rScore = (artistConfirmed(rhs) ? 50 : 0)
                + (LyricQueryNormalizer.canonicalTitle(rhs.title) == wantedTitle ? 30 : 10)
                - (duration > 0 && rhs.duration > 0 ? Int(abs(rhs.duration - duration)) : 15)
            return lScore < rScore
        }
    }
}
