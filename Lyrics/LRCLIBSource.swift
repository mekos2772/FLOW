import Foundation

/// 外部歌词源：LRCLIB（https://lrclib.net）。
///
/// 为什么选它：
/// - **公开、免费、无需 API Key**，接口是普通 JSON，没有签名与风控那套；
/// - 直接返回 `syncedLyrics`（带时间轴的标准 LRC），不需要自己对齐；
/// - 中文曲库覆盖不错（实测「夜曲 / 周杰伦」返回 20 条候选，多条带 33 行同步歌词）。
///
/// B 站音乐稿几乎都没有 CC 字幕（实测抽样 12 个稿件全为 0），
/// 所以外部源不是锦上添花，而是让歌词真正可用的唯一路径。
struct LRCLIBSource: Sendable {

    struct Candidate: Sendable, Equatable, Hashable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: TimeInterval
        /// 带时间轴的 LRC 文本；nil 表示这条只有纯文本歌词。
        let syncedLyrics: String?

        var hasSynced: Bool {
            guard let syncedLyrics else { return false }
            return !syncedLyrics.isEmpty
        }

        /// 是否包含 `<mm:ss.xx>` 增强型逐字时间戳。
        var hasEnhancedWordTiming: Bool {
            guard let syncedLyrics else { return false }
            return syncedLyrics.range(of: #"<\d{1,2}:\d{2}"#, options: .regularExpression) != nil
        }

        /// 界面上一行：`夜曲 · 周杰伦 · 十一月的萧邦`
        var describe: String {
            [trackName, artistName, albumName]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    var session: URLSession = .shared

    private static let base = "https://lrclib.net/api"
    /// 候选与曲目的时长最多能差多少秒（见 `rank` 里的 `isDurationCompatible`）。
    static let maximumDurationGap: TimeInterval = 30
    /// 当歌名完全一致且歌手已确认命中时，允许的时长容差（覆盖 MV 剧情前奏/Live 掌声等）。
    static let confirmedArtistDurationGap: TimeInterval = 50

    func search(title: String, artist: String?, album: String? = nil) async throws -> [Candidate] {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        return try await fetchCandidates(queryItems: items)
    }

    /// 自由关键词检索（调用 `/api/search?q=`，支持歌名与歌手混搜）。
    func search(keyword: String) async throws -> [Candidate] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await fetchCandidates(queryItems: [URLQueryItem(name: "q", value: trimmed)])
    }

    private func fetchCandidates(queryItems: [URLQueryItem]) async throws -> [Candidate] {
        var components = URLComponents(string: "\(Self.base)/search")!
        components.queryItems = queryItems
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.thirdPartyLyrics
        // LRCLIB 要求带一个能识别应用的 UA。
        request.setValue("FLOW/1.0 (music player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw RemoteHTTPFailure(code: status, message: "歌词源返回 \(status)",
                                    url: url.absoluteString)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let trackName = row["trackName"] as? String else { return nil }
            return Candidate(
                id: id,
                trackName: trackName,
                artistName: row["artistName"] as? String ?? "",
                albumName: row["albumName"] as? String ?? "",
                duration: row["duration"] as? Double ?? 0,
                syncedLyrics: row["syncedLyrics"] as? String
            )
        }
    }

    /// 排序：先要"有同步歌词"，再比标题匹配、歌手匹配，最后比时长接近度。
    ///
    /// 为什么不只按字符串相等：B 站标题常带 `- Live`、`Cover`、`【4K】`，
    /// 歌词库里的标题是纯歌名。要求完全相等会漏掉大部分能用的候选。
    static func rank(_ candidates: [Candidate],
                     title: String,
                     artist: String?,
                     duration: TimeInterval?,
                     limit: Int = 5,
                     requiresCompatibleDuration: Bool = true,
                     context: LyricQueryNormalizer.MatchContext? = nil,
                     requiresArtistEvidence: Bool = false,
                     artistIsReliable: Bool = false) -> [Candidate] {
        let wantedTitle = LyricQueryNormalizer.canonicalTitle(title)
        let wantedArtist = artist.map { LyricQueryNormalizer.normalize($0) } ?? ""
        let artistContext = artist.flatMap { $0.isEmpty ? nil : LyricQueryNormalizer.MatchContext($0) }
        let wantsInstrumental = Self.looksInstrumental(title)

        /// 标题是否有关系。**必须单独判断**：
        /// 之前只看总分，而"时长恰好接近"就能凑够 120 分，
        /// 于是一首 4 分钟的曲子会把任意一首也 4 分钟的同步歌词认成自己的歌词。
        func hasTitleSignal(_ candidate: Candidate) -> Bool {
            let candidateTitle = LyricQueryNormalizer.canonicalTitle(candidate.trackName)
            guard !wantedTitle.isEmpty, !candidateTitle.isEmpty else { return false }
            if candidateTitle == wantedTitle { return true }
            // 包含关系还要**够像**：光"含有"会把不相干的歌放进来。
            // 例：视频标题里的「英雄」能"包含"在《英雄联盟 S16 主题曲》里，
            // 但那是两件事。要求较短一方占较长一方至少 60%。
            let shared = min(candidateTitle.count, wantedTitle.count)
            let longer = max(candidateTitle.count, wantedTitle.count)
            guard shared >= 2, Double(shared) / Double(max(longer, 1)) >= 0.6 else { return false }
            return candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle)
        }

        func isArtistConfirmed(_ candidate: Candidate) -> Bool {
            if hasArtistEvidence(candidate, context: context) { return true }
            guard !wantedArtist.isEmpty else { return false }
            let candidateArtist = LyricQueryNormalizer.normalize(candidate.artistName)
            guard !candidateArtist.isEmpty else { return false }
            if candidateArtist == wantedArtist
                || (wantedArtist.count >= 2 && candidateArtist.contains(wantedArtist))
                || (candidateArtist.count >= 2 && wantedArtist.contains(candidateArtist)) {
                return true
            }
            return artistContext?.mentions(artist: candidate.artistName) == true
        }

        func hasStrongEvidence(_ candidate: Candidate) -> Bool {
            isArtistConfirmed(candidate) || hasAlbumEvidence(candidate, context: context)
        }

        // 统计命中当前歌名的同步候选中存在多少位不同歌手，用于识别《主角》《我们》这类同名异曲歧义。
        let titleMatchedSynced = candidates.filter {
            $0.hasSynced && hasTitleSignal($0) && !Self.isPlaceholderInstrumentalLyrics($0.syncedLyrics)
        }
        let distinctArtists = Set(
            titleMatchedSynced
                .map { LyricQueryNormalizer.normalize($0.artistName) }
                .filter { !$0.isEmpty }
        )
        let isAmbiguousTitle = distinctArtists.count >= 2

        func score(_ candidate: Candidate) -> Int {
            var value = 0
            if candidate.hasSynced { value += 100 }
            if candidate.hasEnhancedWordTiming { value += 2 }
            let candidateTitle = LyricQueryNormalizer.canonicalTitle(candidate.trackName)
            if candidateTitle == wantedTitle { value += 40 }
            else if hasTitleSignal(candidate) {
                value += 20
            }
            // 伴奏 / 纯音乐条目在原曲非伴奏时大幅降权（如 LRCLIB 中 album="伴奏" 或 track="重生(伴奏)"）。
            if !wantsInstrumental && Self.isInstrumentalCandidate(candidate) {
                value -= 50
            }
            // 完整多行歌词优先于仅有 1~2 行残缺文本的条目。
            if Self.substantiveLyricLineCount(candidate.syncedLyrics) >= 8 {
                value += 8
            }
            // 歌手或作品专辑出现在视频标题或投稿人里：与歌手栏对上同样有分量。
            if hasArtistEvidence(candidate, context: context) { value += 30 }
            if hasAlbumEvidence(candidate, context: context) { value += 25 }
            return value + Self.artistAndDurationBonus(for: candidate, wantedArtist: wantedArtist, artistContext: artistContext, duration: duration)
        }

        /// 防错配门禁（与 AMLL 同名不等于同一首规则对齐）：
        /// 1. 猜出来的歌名（`requiresArtistEvidence`）：必须歌名精确相等且有歌手/作品旁证；
        /// 2. 歧义同名歌（库里存在 ≥ 2 位不同歌手的同名歌）：自动匹配必须有歌手或作品旁证，不能盲选；
        /// 3. 已明确知道可靠歌手（如 `在录音棚听马里奥的《主角》` 提取出 `马里奥`），而候选歌手不匹配：
        ///    对短歌名（≤ 3 字）或歧义同名歌直接拒绝，避免把别歌手的同名歌贴到屏幕上。
        func passesEvidenceGate(_ candidate: Candidate) -> Bool {
            if requiresArtistEvidence {
                return LyricQueryNormalizer.canonicalTitle(candidate.trackName) == wantedTitle
                    && hasStrongEvidence(candidate)
            }
            guard requiresCompatibleDuration else { return true }
            if isAmbiguousTitle && !hasStrongEvidence(candidate) {
                return false
            }
            if artistIsReliable && !wantedArtist.isEmpty && !hasStrongEvidence(candidate) {
                let candidateArtist = LyricQueryNormalizer.normalize(candidate.artistName)
                if !candidateArtist.isEmpty {
                    // 短歌名同名异曲概率极高，可靠歌手不匹配一律拒绝；
                    // 较长单曲（如 6 字翻唱且库中仅单一原唱）只允许时长非常接近（≤ 15s）的情况。
                    if wantedTitle.count <= 3 || isAmbiguousTitle {
                        return false
                    }
                    if let duration, duration > 0, candidate.duration > 0,
                       abs(candidate.duration - duration) > 15 {
                        return false
                    }
                }
            }
            return true
        }

        /// 时长是否说得过去。两边都知道时长、却差了半分钟以上，
        /// 基本可以确定是另一个版本（现场 / Remix / 加长版）甚至另一首歌——
        /// 它的时间轴套在这条音频上，从头到尾都是错位的。
        /// 仅在歌名完全一致且歌手/作品已确认命中时放宽到 50 秒，覆盖 MV 剧情前奏/Live 尾奏。
        func isDurationCompatible(_ candidate: Candidate) -> Bool {
            // 手动「换一版」时不设这道门：用户是看着清单自己挑的，挑哪版是他的权利。
            guard requiresCompatibleDuration else { return true }
            guard let duration, duration > 0, candidate.duration > 0 else { return true }
            let gap = abs(candidate.duration - duration)
            if gap <= Self.maximumDurationGap { return true }
            let exactTitle = LyricQueryNormalizer.canonicalTitle(candidate.trackName) == wantedTitle
            return exactTitle && hasStrongEvidence(candidate) && gap <= Self.confirmedArtistDurationGap
        }

        // 只认"有同步歌词 + 非纯音乐空壳 + 标题真的有关系"的候选。
        let scored = candidates
            .filter {
                $0.hasSynced
                    && !Self.isPlaceholderInstrumentalLyrics($0.syncedLyrics)
                    && hasTitleSignal($0)
                    && isDurationCompatible($0)
                    && passesEvidenceGate($0)
            }
            .map { (candidate: $0, score: score($0)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if let duration, duration > 0, lhs.candidate.duration > 0, rhs.candidate.duration > 0 {
                    let lDelta = abs(lhs.candidate.duration - duration)
                    let rDelta = abs(rhs.candidate.duration - duration)
                    if abs(lDelta - rDelta) > 0.5 { return lDelta < rDelta }
                }
                return lhs.candidate.id < rhs.candidate.id
            }
            .prefix(limit)
            .map(\.candidate)
        return Array(scored)
    }

    /// 这条歌词的歌手是否出现在视频标题或投稿人里。
    static func hasArtistEvidence(_ candidate: Candidate,
                                  context: LyricQueryNormalizer.MatchContext?) -> Bool {
        guard let context, !candidate.artistName.isEmpty else { return false }
        return context.mentions(artist: candidate.artistName)
    }

    /// 这条歌词的专辑或歌名副标题中的作品出处是否出现在视频标题里（如《斗破苍穹》动画原声带）。
    static func hasAlbumEvidence(_ candidate: Candidate,
                                 context: LyricQueryNormalizer.MatchContext?) -> Bool {
        guard let context else { return false }
        // 1. 先检查歌名自身是否含作品书名号（如 LRCLIB 中 `明天 - 《斗破苍穹》决战云岚片尾曲`）
        for work in LyricQueryNormalizer.workHints(candidate.trackName) {
            let normWork = LyricQueryNormalizer.normalize(work)
            if normWork.count >= 2, context.folded.contains(normWork) {
                return true
            }
        }
        // 2. 再检查专辑名（去掉「原声带」「OST」等后缀后与标题比对）
        let normalizedAlbum = LyricQueryNormalizer.normalize(candidate.albumName)
        guard normalizedAlbum.count >= 2 else { return false }
        // 专辑名等于歌名本身时（同名专辑）不能充当额外作品旁证，避免误放行。
        if normalizedAlbum == LyricQueryNormalizer.canonicalTitle(candidate.trackName) {
            return false
        }
        if context.folded.contains(normalizedAlbum) { return true }
        let albumLower = TextNormalizer.simplified(candidate.albumName).lowercased()
        let compactAlbum = albumLower.filter { !$0.isWhitespace }
        guard compactAlbum.count >= 2 else { return false }
        let stripped = compactAlbum
            .replacingOccurrences(of: "电视原声带", with: "")
            .replacingOccurrences(of: "动画原声带", with: "")
            .replacingOccurrences(of: "电影原声带", with: "")
            .replacingOccurrences(of: "原声带", with: "")
            .replacingOccurrences(of: "原声大碟", with: "")
            .replacingOccurrences(of: "主题曲", with: "")
            .replacingOccurrences(of: "片尾曲", with: "")
            .replacingOccurrences(of: "片头曲", with: "")
            .replacingOccurrences(of: "插曲", with: "")
            .replacingOccurrences(of: "ost", with: "")
        guard stripped.count >= 2, stripped != LyricQueryNormalizer.canonicalTitle(candidate.trackName) else {
            return false
        }
        return context.folded.contains(stripped)
    }

    private static func looksInstrumental(_ text: String) -> Bool {
        let lower = TextNormalizer.simplified(text).lowercased()
        return ["伴奏", "纯音乐", "instrumental", "off vocal", "karaoke", "inst."].contains { lower.contains($0) }
    }

    private static func isInstrumentalCandidate(_ candidate: Candidate) -> Bool {
        looksInstrumental(candidate.trackName) || looksInstrumental(candidate.albumName)
    }

    /// 检测仅有「纯音乐，请欣赏」/「暂无歌词」等占位文本的空壳 LRC。
    private static func isPlaceholderInstrumentalLyrics(_ lrc: String?) -> Bool {
        guard let lrc, !lrc.isEmpty else { return true }
        let lines = lrc.split(whereSeparator: \.isNewline)
            .map { raw -> String in
                String(raw)
                    .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        let placeholderCues = ["纯音乐，请欣赏", "纯音乐,请欣赏", "纯音乐 请欣赏", "纯音乐，敬请欣赏", "此歌曲为没有填词的纯音乐", "暂无歌词", "instrumental"]
        if lines.count <= 2, lines.allSatisfy({ line in
            let lower = TextNormalizer.simplified(line).lowercased()
            return placeholderCues.contains(where: { lower.contains($0) })
        }) {
            return true
        }
        return false
    }

    private static func substantiveLyricLineCount(_ lrc: String?) -> Int {
        guard let lrc, !lrc.isEmpty else { return 0 }
        return lrc.split(whereSeparator: \.isNewline).reduce(into: 0) { count, raw in
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("[") else { return }
            let body = line
                .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { count += 1 }
        }
    }

    /// 手动搜词排序：保留所有带时间轴的候选（支持混写关键词与不同翻唱标题），按相关性及增强逐字支持排序。
    static func rankManual(_ candidates: [Candidate],
                           query: String,
                           artist: String?,
                           duration: TimeInterval?,
                           limit: Int = 12) -> [Candidate] {
        guard limit > 0 else { return [] }
        let wantedQuery = LyricQueryNormalizer.normalize(query)
        let wantedArtist = artist.map { LyricQueryNormalizer.normalize($0) } ?? ""
        let queryTokens = query
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-－—/·")))
            .map { LyricQueryNormalizer.normalize($0) }
            .filter { !$0.isEmpty }

        var unique: [Int: Candidate] = [:]
        for candidate in candidates where candidate.hasSynced {
            unique[candidate.id] = candidate
        }

        return unique.values
            .map { candidate -> (candidate: Candidate, score: Int) in
                let normTitle = LyricQueryNormalizer.normalize(candidate.trackName)
                let normArtist = LyricQueryNormalizer.normalize(candidate.artistName)
                var score = candidate.hasEnhancedWordTiming ? 10 : 0
                if !wantedQuery.isEmpty {
                    if normTitle == wantedQuery { score += 50 }
                    else if normTitle.hasPrefix(wantedQuery) { score += 35 }
                    else if normTitle.contains(wantedQuery) || wantedQuery.contains(normTitle) { score += 25 }
                    else if !queryTokens.isEmpty {
                        let combined = normTitle + " " + normArtist
                        let hits = queryTokens.filter { combined.contains($0) }.count
                        score += hits * 10
                    }
                }
                score += artistAndDurationBonus(for: candidate, wantedArtist: wantedArtist, duration: duration)
                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.candidate.id < rhs.candidate.id
            }
            .prefix(limit)
            .map(\.candidate)
    }

    private static func artistAndDurationBonus(for candidate: Candidate,
                                               wantedArtist: String,
                                               artistContext: LyricQueryNormalizer.MatchContext? = nil,
                                               duration: TimeInterval?) -> Int {
        var bonus = 0
        if !wantedArtist.isEmpty {
            let candidateArtist = LyricQueryNormalizer.normalize(candidate.artistName)
            if candidateArtist == wantedArtist { bonus += 30 }
            else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
                bonus += 15
            } else if artistContext?.mentions(artist: candidate.artistName) == true {
                bonus += 25
            }
        }
        if let duration, duration > 0, candidate.duration > 0 {
            let delta = abs(candidate.duration - duration)
            if delta <= 3 { bonus += 20 }
            else if delta <= 10 { bonus += 10 }
            else if delta <= 30 { bonus += 4 }
        }
        return bonus
    }
}
