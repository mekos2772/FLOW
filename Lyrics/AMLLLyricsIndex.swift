import Foundation

/// AMLL 逐词歌词库的索引（`metadata/raw-lyrics-index.jsonl`，约 1.7MB / 3400+ 条）。
///
/// 索引只给出"有哪些歌、对应哪个文件"，真正的 TTML 在命中之后才下载。
struct AMLLLyricsIndex: Sendable {
    struct Entry: Sendable, Equatable, Hashable {
        var musicName: String
        var artists: [String]
        var file: String
    }

    let entries: [Entry]

    static let empty = AMLLLyricsIndex(entries: [])

    /// 解析 JSONL。坏行直接跳过——索引是外部数据，不能让一行坏数据毁掉整个库。
    static func parse(_ data: Data) -> AMLLLyricsIndex {
        guard let text = String(data: data, encoding: .utf8) else { return .empty }
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let file = object["rawLyricFile"] as? String else { continue }
            let metadata = object["metadata"] as? [[Any]] ?? []
            var fields: [String: [String]] = [:]
            for pair in metadata {
                guard pair.count == 2, let key = pair[0] as? String else { continue }
                fields[key] = (pair[1] as? [String]) ?? []
            }
            let names = fields["musicName"] ?? []
            guard let name = names.first, !name.isEmpty else { continue }
            entries.append(Entry(musicName: name, artists: fields["artists"] ?? [], file: file))
        }
        return AMLLLyricsIndex(entries: entries)
    }

    /// 一次匹配的结果。
    struct Match: Sendable, Equatable {
        var entry: Entry
        /// 歌手也对上了。没对上的匹配只凭歌名，调用方必须再做一次旁证（时长）才能用。
        var isArtistConfirmed: Bool
    }

    /// 兼容入口：只要条目，不关心置信度。
    func bestMatch(title: String, artist: String?) -> Entry? {
        match(title: title, artist: artist, artistIsReliable: false)?.entry
    }

    /// 按标题 + 歌手挑一条。
    ///
    /// **同名不等于同一首。** 库里有草东没有派对的《我们》，不代表陈奕迅的《我们》也能用它的歌词；
    /// 逐词歌词排在所有歌词源的最前面，一旦认错，屏幕上滚动的就是另一首歌——
    /// 而且看起来"非常精确"，比没有歌词更糟。所以规则是保守的：
    ///
    /// 1. 歌手对得上 → 用它（歌名相等，或构成包含关系且长度比例 ≥ 60%）；
    /// 2. 歌手**可靠**（来自标题里的「歌手 - 歌名」）却对不上 → 不用；
    /// 3. 歌手未知/不可靠（B 站的"歌手位"常常只是 UP 主）→ 只在歌名**完全相等**、
    ///    且库里叫这个名字的只有一位歌手时才给出，并标成"未确认"。
    func match(title: String, artist: String?, artistIsReliable: Bool) -> Match? {
        let wanted = LyricQueryNormalizer.normalize(title)
        guard !wanted.isEmpty else { return nil }
        let wantedArtist = artist.map { LyricQueryNormalizer.normalize($0) } ?? ""

        var exact: [Entry] = []
        var loose: [Entry] = []
        for entry in entries {
            let name = LyricQueryNormalizer.normalize(entry.musicName)
            guard !name.isEmpty else { continue }
            if name == wanted {
                exact.append(entry)
                continue
            }
            let shorter = min(name.count, wanted.count)
            let longer = max(name.count, wanted.count)
            guard shorter >= 2,
                  Double(shorter) / Double(max(longer, 1)) >= 0.6,
                  name.contains(wanted) || wanted.contains(name) else { continue }
            loose.append(entry)
        }

        func artistMatches(_ entry: Entry) -> Bool {
            guard wantedArtist.count >= 2 else { return false }
            return entry.artists.contains { candidate in
                let normalized = LyricQueryNormalizer.normalize(candidate)
                guard normalized.count >= 2 else { return false }
                return normalized == wantedArtist
                    || normalized.contains(wantedArtist) || wantedArtist.contains(normalized)
            }
        }

        if !wantedArtist.isEmpty {
            if let hit = exact.first(where: artistMatches) ?? loose.first(where: artistMatches) {
                return Match(entry: hit, isArtistConfirmed: true)
            }
            if artistIsReliable { return nil }
        }

        guard let first = exact.first else { return nil }
        let distinctArtists = Set(exact.map { entry in
            entry.artists.map { LyricQueryNormalizer.normalize($0) }.sorted().joined(separator: "|")
        })
        guard distinctArtists.count == 1 else { return nil }
        return Match(entry: first, isArtistConfirmed: false)
    }

    /// 手动关键词搜索（支持只搜歌名、只搜歌手或“歌手 - 歌名”混合关键词）。
    func search(query: String, artist: String? = nil, limit: Int = 10) -> [Entry] {
        guard limit > 0 else { return [] }
        let wanted = LyricQueryNormalizer.normalize(query)
        let wantedArtist = artist.map { LyricQueryNormalizer.normalize($0) } ?? ""
        let tokens = Self.searchTokens(from: query)
        guard !wanted.isEmpty || !wantedArtist.isEmpty || !tokens.isEmpty else { return [] }

        var scored: [(entry: Entry, score: Int)] = []
        for entry in entries {
            let normTitle = LyricQueryNormalizer.normalize(entry.musicName)
            let normArtists = entry.artists.map { LyricQueryNormalizer.normalize($0) }.filter { !$0.isEmpty }
            guard !normTitle.isEmpty else { continue }

            var score = 0
            if !wantedArtist.isEmpty {
                let exactArtist = normArtists.contains(wantedArtist)
                let fuzzyArtist = exactArtist || normArtists.contains {
                    $0.contains(wantedArtist) || wantedArtist.contains($0)
                }
                guard fuzzyArtist else { continue }
                score += exactArtist ? 50 : 30
            }

            if !wanted.isEmpty {
                if normTitle == wanted {
                    score += 100
                } else if normTitle.hasPrefix(wanted) {
                    score += 75
                } else if normTitle.contains(wanted) || wanted.contains(normTitle) {
                    score += 55
                } else if !tokens.isEmpty {
                    let combined = ([normTitle] + normArtists).joined(separator: " ")
                    let hitAllTokens = tokens.allSatisfy { combined.contains($0) }
                    if hitAllTokens {
                        let hitsTitle = tokens.contains { normTitle.contains($0) || $0.contains(normTitle) }
                        score += hitsTitle ? 45 : 30
                    } else {
                        continue
                    }
                } else {
                    continue
                }
            } else if wantedArtist.isEmpty {
                continue
            } else {
                // 只按歌手搜时也要有基础正分。
                score += 10
            }

            scored.append((entry: entry, score: score))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.musicName.count != rhs.entry.musicName.count {
                    return lhs.entry.musicName.count < rhs.entry.musicName.count
                }
                return lhs.entry.file < rhs.entry.file
            }
            .prefix(limit)
            .map(\.entry)
    }

    private static func searchTokens(from raw: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-－—/·《》"))
        return raw.components(separatedBy: separators)
            .map { LyricQueryNormalizer.normalize($0) }
            .filter { !$0.isEmpty }
    }
}
