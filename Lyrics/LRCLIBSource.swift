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

    func search(title: String, artist: String?) async throws -> [Candidate] {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
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
                     requiresCompatibleDuration: Bool = true) -> [Candidate] {
        let wantedTitle = LyricQueryNormalizer.normalize(title)
        let wantedArtist = artist.map { LyricQueryNormalizer.normalize($0) } ?? ""

        /// 标题是否有关系。**必须单独判断**：
        /// 之前只看总分，而"时长恰好接近"就能凑够 120 分，
        /// 于是一首 4 分钟的曲子会把任意一首也 4 分钟的同步歌词认成自己的歌词。
        func hasTitleSignal(_ candidate: Candidate) -> Bool {
            let candidateTitle = LyricQueryNormalizer.normalize(candidate.trackName)
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

        func score(_ candidate: Candidate) -> Int {
            var value = 0
            if candidate.hasSynced { value += 100 }
            let candidateTitle = LyricQueryNormalizer.normalize(candidate.trackName)
            if candidateTitle == wantedTitle { value += 40 }
            else if hasTitleSignal(candidate) {
                value += 20
            }
            return value + Self.artistAndDurationBonus(for: candidate, wantedArtist: wantedArtist, duration: duration)
        }

        /// 时长是否说得过去。两边都知道时长、却差了半分钟以上，
        /// 基本可以确定是另一个版本（现场 / Remix / 加长版）甚至另一首歌——
        /// 它的时间轴套在这条音频上，从头到尾都是错位的。
        func isDurationCompatible(_ candidate: Candidate) -> Bool {
            // 手动「换一版」时不设这道门：用户是看着清单自己挑的，挑哪版是他的权利。
            guard requiresCompatibleDuration else { return true }
            guard let duration, duration > 0, candidate.duration > 0 else { return true }
            return abs(candidate.duration - duration) <= Self.maximumDurationGap
        }

        // 只认"有同步歌词 + 标题真的有关系"的候选。
        //
        // 之前只过滤 `hasSynced`：只要带时间轴就收，于是一个只靠时长蹭到 4 分的结果
        // 也会被当成这首曲子的歌词——"配上了但全错"比"没有歌词"更糟。
        // 现在要求标题至少构成包含关系（相等 +40 / 包含 +20），即基础分 100 之上还要有标题信号。
        let scored = candidates
            .filter { $0.hasSynced && hasTitleSignal($0) && isDurationCompatible($0) }
            .map { (candidate: $0, score: score($0)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.candidate.id < rhs.candidate.id
            }
            .prefix(limit)
            .map(\.candidate)
        return Array(scored)
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
                                               duration: TimeInterval?) -> Int {
        var bonus = 0
        if !wantedArtist.isEmpty {
            let candidateArtist = LyricQueryNormalizer.normalize(candidate.artistName)
            if candidateArtist == wantedArtist { bonus += 30 }
            else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
                bonus += 15
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
