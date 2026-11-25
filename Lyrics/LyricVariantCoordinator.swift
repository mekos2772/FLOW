import Foundation

/// 手动搜词 / 换一版歌词时的统一候选条目（统一封装 AMLL 逐字库与 LRCLIB 源）。
struct LyricVariantCandidate: Identifiable, Hashable, Sendable {
    enum SourceKind: String, Sendable, Hashable {
        case amll
        case lrclib
    }

    let id: String
    let source: SourceKind
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: TimeInterval?
    let hasWordTiming: Bool
    let amllEntry: AMLLLyricsIndex.Entry?
    let lrclibCandidate: LRCLIBSource.Candidate?

    static func fromAMLL(_ entry: AMLLLyricsIndex.Entry) -> LyricVariantCandidate {
        let artistsText = entry.artists.filter { !$0.isEmpty }.joined(separator: " / ")
        let sample = "\(entry.musicName) \(artistsText)"
        let convert = TextNormalizer.converter(forDocument: sample)
        return LyricVariantCandidate(
            id: "amll:\(entry.file)",
            source: .amll,
            trackName: convert(entry.musicName),
            artistName: convert(artistsText),
            albumName: "",
            duration: nil,
            hasWordTiming: true,
            amllEntry: entry,
            lrclibCandidate: nil
        )
    }

    static func fromLRCLIB(_ raw: LRCLIBSource.Candidate) -> LyricVariantCandidate {
        let sample = [raw.trackName, raw.artistName, raw.albumName].joined(separator: " ")
        let convert = TextNormalizer.converter(forDocument: sample)
        let normalized = LRCLIBSource.Candidate(
            id: raw.id,
            trackName: convert(raw.trackName),
            artistName: convert(raw.artistName),
            albumName: convert(raw.albumName),
            duration: raw.duration,
            syncedLyrics: raw.syncedLyrics
        )
        return LyricVariantCandidate(
            id: "lrclib:\(normalized.id)",
            source: .lrclib,
            trackName: normalized.trackName,
            artistName: normalized.artistName,
            albumName: normalized.albumName,
            duration: normalized.duration > 0 ? normalized.duration : nil,
            hasWordTiming: normalized.hasEnhancedWordTiming,
            amllEntry: nil,
            lrclibCandidate: normalized
        )
    }

    /// 展示用来源标签。
    var sourceBadge: String {
        switch source {
        case .amll:
            return String(localized: "AMLL 逐字")
        case .lrclib:
            return hasWordTiming ? String(localized: "LRCLIB 逐字") : "LRCLIB"
        }
    }

    /// 次要信息行：`周杰伦 · 十一月的萧邦 · 04:46`。
    var secondarySummary: String {
        var parts: [String] = []
        if !artistName.isEmpty { parts.append(artistName) }
        if !albumName.isEmpty { parts.append(albumName) }
        if let duration, duration > 0 { parts.append(DurationText.clock(duration)) }
        return parts.joined(separator: " · ")
    }

    var describe: String {
        [trackName, artistName, albumName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 协调右键「换一版歌词 / 手动搜词」的跨源检索与按 `TrackIdentity` 持久化绑定。
@MainActor
final class LyricVariantCoordinator {
    let bindingStore: LyricBindingStore
    weak var lyricEngine: LyricEngine?
    var amllProvider: AMLLLyricsProvider
    var lrclibSource: LRCLIBSource
    var networkAllowed: @Sendable () -> Bool

    init(bindingStore: LyricBindingStore,
         lyricEngine: LyricEngine? = nil,
         amllProvider: AMLLLyricsProvider = .shared,
         lrclibSource: LRCLIBSource = LRCLIBSource(),
         networkAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.bindingStore = bindingStore
        self.lyricEngine = lyricEngine
        self.amllProvider = amllProvider
        self.lrclibSource = lrclibSource
        self.networkAllowed = networkAllowed
    }

    /// 从当前曲目解析适合预填进搜索框的「关键词 + 可靠歌手」。
    func suggestedQuery(for track: Track) -> (keyword: String, artist: String) {
        let parsed = LyricQueryNormalizer.parseTitle(track.title)
        let keyword = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist: String
        if let parsedArtist = parsed.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedArtist.isEmpty {
            artist = parsedArtist
        } else if ExternalLyricsAggregator.isImplicitArtistUntrusted(for: track) {
            // 视频投稿源（如 bilibili / bilibili-fetch）标题未标明歌手时，track.artist 往往是 UP 主，
            // 预填进歌手栏会干扰 AMLL/LRCLIB 的默认检索。
            artist = ""
        } else {
            artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (keyword.isEmpty ? track.title : keyword, artist)
    }

    /// 打开 Popover 时的默认候选推荐（AMLL 逐字 + LRCLIB）。
    func defaultCandidates(for track: Track) async -> [LyricVariantCandidate] {
        let suggested = suggestedQuery(for: track)
        let artistArg = suggested.artist.isEmpty ? nil : suggested.artist
        let canUseNetwork = networkAllowed()

        async let amllTask: [AMLLLyricsIndex.Entry] = amllProvider.search(
            title: suggested.keyword, artist: artistArg, limit: 6, allowNetwork: canUseNetwork
        )
        async let lrcTask: [LRCLIBSource.Candidate] = canUseNetwork
            ? searchLRCLIB(keyword: suggested.keyword,
                           artist: artistArg,
                           workHint: LyricQueryNormalizer.workHints(track.title).first,
                           duration: track.duration)
            : []

        let amll = await amllTask.map(LyricVariantCandidate.fromAMLL)
        let lrc = await lrcTask.map(LyricVariantCandidate.fromLRCLIB)
        return deduplicated(amll + lrc)
    }

    /// 手动关键词搜词：支持仅歌名、仅歌手、「歌手 - 歌名」混合输入及双字段检索 LRCLIB / AMLL。
    func search(keyword: String, artist: String, for track: Track?) async -> [LyricVariantCandidate] {
        let cleanKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKeyword.isEmpty || !cleanArtist.isEmpty else { return [] }

        let parsed = LyricQueryNormalizer.parseTitle(cleanKeyword)
        let effectiveTitle = cleanArtist.isEmpty && parsed.artist != nil ? parsed.title : cleanKeyword
        let effectiveArtist = !cleanArtist.isEmpty ? cleanArtist : parsed.artist
        let canUseNetwork = networkAllowed()

        async let amllTask = searchAMLLManual(rawKeyword: cleanKeyword,
                                              title: effectiveTitle.isEmpty ? cleanKeyword : effectiveTitle,
                                              artist: effectiveArtist,
                                              limit: 10,
                                              allowNetwork: canUseNetwork)
        async let lrcTask = searchLRCLIBManual(rawKeyword: cleanKeyword,
                                               title: effectiveTitle,
                                               artist: effectiveArtist,
                                               reversedTitle: cleanArtist.isEmpty ? parsed.artist : nil,
                                               reversedArtist: cleanArtist.isEmpty && parsed.artist != nil ? parsed.title : nil,
                                               duration: track?.duration,
                                               allowNetwork: canUseNetwork)

        let amll = await amllTask.map(LyricVariantCandidate.fromAMLL)
        let lrc = await lrcTask.map(LyricVariantCandidate.fromLRCLIB)
        return deduplicated(amll + lrc)
    }

    /// 应用候选并按 `TrackIdentity` 持久化绑定。
    @discardableResult
    func apply(_ candidate: LyricVariantCandidate, for track: Track) async -> LyricsDocument? {
        let document: LyricsDocument?
        switch candidate.source {
        case .amll:
            guard let entry = candidate.amllEntry,
                  let loaded = await amllProvider.loadTTML(for: entry, allowNetwork: networkAllowed()),
                  !Task.isCancelled,
                  !loaded.lines.isEmpty else {
                return nil
            }
            let rawDoc = LyricsDocument(
                trackIdentity: track.identity,
                lines: loaded.lines,
                source: .external,
                synchronization: .synced
            )
            document = saveAndOverride(
                track: track,
                sourceIdentifier: candidate.id,
                providerName: "AMLL",
                trackName: candidate.trackName,
                artistName: candidate.artistName,
                albumName: candidate.albumName,
                format: .ttml,
                rawPayload: loaded.rawXML,
                rawDocument: rawDoc
            )

        case .lrclib:
            guard let raw = candidate.lrclibCandidate,
                  let lrc = raw.syncedLyrics,
                  !lrc.isEmpty else {
                return nil
            }
            let normalizedLRC = TextNormalizer.simplifiedLRC(lrc)
            guard !Task.isCancelled,
                  let parsed = LRCParser.parse(normalizedLRC),
                  !parsed.lines.isEmpty else {
                return nil
            }
            let rawDoc = LyricsDocument(
                trackIdentity: track.identity,
                lines: parsed.lines,
                metadata: parsed.metadata,
                source: .external,
                synchronization: parsed.synchronization
            )
            document = saveAndOverride(
                track: track,
                sourceIdentifier: candidate.id,
                providerName: "LRCLIB",
                trackName: candidate.trackName,
                artistName: candidate.artistName,
                albumName: candidate.albumName,
                format: .lrc,
                rawPayload: normalizedLRC,
                rawDocument: rawDoc
            )
            Self.cacheSyncedLRC(track: track, lrc: normalizedLRC)
        }

        return document
    }

    /// 从用户选择或拖入的本地 `.lrc` / `.ttml` 文件读取并持久化绑定为指定曲目的歌词，实时刷新显示。
    @discardableResult
    func applyLocalLyricFile(at fileURL: URL, for track: Track) -> LyricsDocument? {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: fileURL),
              let rawText = Self.decodeLyricText(data) else {
            return nil
        }

        let ext = fileURL.pathExtension.lowercased()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if ext == "ttml" || trimmed.hasPrefix("<tt") || trimmed.hasPrefix("<?xml") {
            let lines = AMLLTTMLParser.parse(rawText)
            guard !lines.isEmpty else { return nil }
            let rawDoc = LyricsDocument(
                trackIdentity: track.identity,
                lines: lines,
                source: .external,
                synchronization: .synced
            )
            return saveAndOverride(
                track: track,
                sourceIdentifier: "local:\(fileURL.lastPathComponent)",
                providerName: String(localized: "本地歌词"),
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album ?? "",
                format: .ttml,
                rawPayload: rawText,
                rawDocument: rawDoc
            )
        }

        let normalizedLRC = TextNormalizer.simplifiedLRC(rawText)
        let rawDoc: LyricsDocument
        if let parsed = LRCParser.parse(normalizedLRC), !parsed.lines.isEmpty {
            rawDoc = LyricsDocument(
                trackIdentity: track.identity,
                lines: parsed.lines,
                metadata: parsed.metadata,
                source: .external,
                synchronization: parsed.synchronization
            )
        } else {
            // 纯文本逐行歌词降级，避免用户导入无时间戳文本时完全失败。
            let plainLines = normalizedLRC
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { LyricLine(start: 0, text: $0) }
            guard !plainLines.isEmpty else { return nil }
            rawDoc = LyricsDocument(
                trackIdentity: track.identity,
                lines: plainLines,
                source: .external,
                synchronization: .unsynced
            )
        }

        let saved = saveAndOverride(
            track: track,
            sourceIdentifier: "local:\(fileURL.lastPathComponent)",
            providerName: String(localized: "本地歌词"),
            trackName: track.title,
            artistName: track.artist,
            albumName: track.album ?? "",
            format: .lrc,
            rawPayload: normalizedLRC,
            rawDocument: rawDoc
        )
        if rawDoc.synchronization == .synced {
            Self.cacheSyncedLRC(track: track, lrc: normalizedLRC)
        }
        return saved
    }

    private static func cacheSyncedLRC(track: Track, lrc: String) {
        let titleKey = LyricQueryNormalizer.parseTitle(track.title).title
        LyricDocumentCache.shared.store(
            identity: TrackIdentity.storageKey(track.identity),
            title: titleKey.isEmpty ? track.title : titleKey,
            lrc: lrc
        )
    }

    private func saveAndOverride(
        track: Track,
        sourceIdentifier: String,
        providerName: String,
        trackName: String,
        artistName: String,
        albumName: String,
        format: LyricPayloadFormat,
        rawPayload: String,
        rawDocument: LyricsDocument
    ) -> LyricsDocument {
        let normalized = TextNormalizer.simplified(document: rawDocument)
        let record = BoundLyricRecord(
            version: 1,
            identity: track.identity,
            sourceIdentifier: sourceIdentifier,
            providerName: providerName,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            format: format,
            payload: rawPayload,
            boundAt: Date()
        )
        bindingStore.save(record)
        if lyricEngine?.currentIdentity == track.identity {
            lyricEngine?.overrideDocument(normalized)
        }
        return normalized
    }

    private static func decodeLyricText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        if let gb = String(data: data, encoding: gbEncoding) {
            return gb
        }
        return String(data: data, encoding: .utf16)
    }

    /// 解除手动绑定并立刻重新触发自动匹配。
    func clearBinding(for track: Track) async {
        bindingStore.remove(for: track.identity)
        LyricDocumentCache.shared.remove(identity: TrackIdentity.storageKey(track.identity))
        if lyricEngine?.currentIdentity == track.identity {
            await lyricEngine?.load(track: track)
        }
    }

    // MARK: - 私有检索辅助

    private func searchAMLL(keyword: String, artist: String?, limit: Int,
                            allowNetwork: Bool) async -> [AMLLLyricsIndex.Entry] {
        let strict = await amllProvider.search(title: keyword, artist: artist,
                                               limit: limit, allowNetwork: allowNetwork)
        if !strict.isEmpty || artist == nil { return strict }
        // 歌手过滤无结果时退回仅按关键词搜一遍，避免填偏歌手漏掉库里已有条目。
        return await amllProvider.search(title: keyword, artist: nil,
                                         limit: limit, allowNetwork: allowNetwork)
    }

    private func searchAMLLManual(rawKeyword: String, title: String, artist: String?,
                                  limit: Int, allowNetwork: Bool) async -> [AMLLLyricsIndex.Entry] {
        let primary = await searchAMLL(keyword: title, artist: artist, limit: limit, allowNetwork: allowNetwork)
        if !primary.isEmpty || rawKeyword == title || rawKeyword.isEmpty { return primary }
        // 当单栏混合写法（如"歌名 - 歌手"）按正向拆解无命中时，使用原始全文再做分词匹配。
        return await amllProvider.search(title: rawKeyword, artist: nil, limit: limit, allowNetwork: allowNetwork)
    }

    private func searchLRCLIB(keyword: String,
                              artist: String?,
                              workHint: String? = nil,
                              duration: TimeInterval?) async -> [LRCLIBSource.Candidate] {
        guard !keyword.isEmpty else { return [] }
        var collected = (try? await lrclibSource.search(title: keyword, artist: artist)) ?? []
        if let artist, !artist.isEmpty {
            for alias in LyricQueryNormalizer.MatchContext.aliases(for: artist) where collected.count < 6 {
                if let aliasHits = try? await lrclibSource.search(title: keyword, artist: alias) {
                    collected.append(contentsOf: aliasHits)
                }
            }
        }
        if let workHint, !workHint.isEmpty, collected.count < 6 {
            if let albumHits = try? await lrclibSource.search(title: keyword, artist: nil, album: workHint) {
                collected.append(contentsOf: albumHits)
            }
        }
        if collected.isEmpty, artist != nil {
            collected = (try? await lrclibSource.search(title: keyword, artist: nil)) ?? []
        }
        if collected.isEmpty {
            let trad = TextNormalizer.traditional(keyword)
            if trad != keyword {
                collected = (try? await lrclibSource.search(title: trad, artist: nil)) ?? []
            }
        }
        if collected.isEmpty {
            let q = [keyword, artist ?? workHint].compactMap { $0 }.joined(separator: " ")
            if let qHits = try? await lrclibSource.search(keyword: q) {
                collected.append(contentsOf: qHits)
            }
        }
        return LRCLIBSource.rankManual(collected, query: keyword, artist: artist,
                                       duration: duration, limit: 8)
    }

    private func searchLRCLIBManual(rawKeyword: String,
                                    title: String,
                                    artist: String?,
                                    reversedTitle: String?,
                                    reversedArtist: String?,
                                    duration: TimeInterval?,
                                    allowNetwork: Bool) async -> [LRCLIBSource.Candidate] {
        guard allowNetwork else { return [] }
        var combined: [LRCLIBSource.Candidate] = []
        if !title.isEmpty {
            if let direct = try? await lrclibSource.search(title: title, artist: artist) {
                combined.append(contentsOf: direct)
            }
            if combined.isEmpty, artist != nil,
               let titleOnly = try? await lrclibSource.search(title: title, artist: nil) {
                combined.append(contentsOf: titleOnly)
            }
        }
        if combined.isEmpty, let reversedTitle, !reversedTitle.isEmpty,
           let swapped = try? await lrclibSource.search(title: reversedTitle, artist: reversedArtist) {
            combined.append(contentsOf: swapped)
        }
        let fallbackQuery = !rawKeyword.isEmpty ? rawKeyword : (artist ?? "")
        let shouldQueryFulltext = combined.isEmpty || rawKeyword.contains(" ") || title.isEmpty
        if shouldQueryFulltext, !fallbackQuery.isEmpty,
           let qHits = try? await lrclibSource.search(keyword: fallbackQuery) {
            combined.append(contentsOf: qHits)
        }
        let rankingQuery = title.isEmpty ? rawKeyword : (combined.isEmpty ? rawKeyword : (!rawKeyword.isEmpty && rawKeyword != title ? rawKeyword : title))
        return LRCLIBSource.rankManual(combined, query: rankingQuery,
                                       artist: artist, duration: duration, limit: 12)
    }

    private func deduplicated(_ items: [LyricVariantCandidate]) -> [LyricVariantCandidate] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
