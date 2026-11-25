import Foundation

/// 源无关的歌曲标题与歌手查询词清洗工具。
///
/// 统一用于 AMLL 索引、LRCLIB 检索/排序及长标题精简展示，
/// 同时去除视频站/网盘常见的装饰括号、分辨率与推广尾缀噪声。
enum LyricQueryNormalizer {

    struct ParsedTitle: Sendable, Equatable {
        var title: String
        var artist: String?
        /// 猜出来的候选：空格拆出的词、括号里的内容、横线调换后的另一侧。
        /// 它可能其实是歌手名或栏目名，歌词源的结果要有歌手旁证才采用。
        var isGuess: Bool = false
    }

    /// 用来旁证「这条歌词的歌手确实出现在视频标题或投稿人里」的上下文。
    struct MatchContext: Sendable, Equatable {
        /// 繁转简、小写、去掉空白后的整段文字，供中日文名字做包含判断。
        let folded: String
        /// 按非字母数字切开的小写词，供较短的拉丁文名字做整词判断（避免 IU 命中 studio 这类误伤）。
        let words: Set<String>

        init(_ texts: String?...) {
            let joined = texts.compactMap { $0 }.joined(separator: " ")
            let lowered = TextNormalizer.simplified(joined.precomposedStringWithCompatibilityMapping).lowercased()
            folded = lowered.filter { !$0.isWhitespace }
            words = Set(lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        }

        /// 常见中英文歌手别名分组（均以繁转简小写存储），用于解决视频标题写中文歌手、
        /// 而外部歌词库（如 LRCLIB / AMLL）登记英文艺名导致旁证失配的问题。
        private static let artistAliasGroups: [[String]] = [
            ["周杰伦", "jay chou"],
            ["孙燕姿", "stefanie sun"],
            ["林俊杰", "jj lin"],
            ["陈奕迅", "eason chan"],
            ["邓紫棋", "g.e.m.", "gem"],
            ["王菲", "faye wong"],
            ["蔡依林", "jolin tsai"],
            ["陶喆", "david tao"],
            ["王力宏", "wang leehom", "leehom wang"],
            ["五月天", "mayday"],
            ["张学友", "jacky cheung"],
            ["张国荣", "leslie cheung"],
            ["张惠妹", "a-mei", "amei"],
            ["梁静茹", "fish leong"],
            ["莫文蔚", "karen mok"],
            ["薛之谦", "joker xue"],
            ["毛不易", "mao buyi"],
            ["蔡健雅", "tanya chua"],
            ["李荣浩", "ronghao li"],
            ["方大同", "khalil fong"],
            ["林宥嘉", "yoga lin"],
            ["田馥甄", "hebe tien"],
            ["许嵩", "vae xu"],
            ["汪苏泷", "silence wang"],
            ["张杰", "jason zhang"],
            ["张靓颖", "jane zhang"],
            ["周深", "zhou shen", "charlie zhou"],
            ["告五人", "accusefive"],
            ["草东没有派对", "no party for cao dong"],
            ["落日飞车", "sunset rollercoaster"],
            ["刘德华", "andy lau"],
            ["郭富城", "aaron kwok"],
            ["黎明", "leon lai"],
            ["谢霆锋", "nicholas tse"],
            ["古巨基", "leo ku"],
            ["杨千嬅", "miriam yeung"],
            ["容祖儿", "joey yung"],
            ["林忆莲", "sandy lam"],
            ["陈粒", "chen li"],
            ["米津玄师", "kenshi yonezu"],
            ["宇多田光", "hikaru utada"],
            ["中岛美嘉", "mika nakashima"],
            ["久石让", "joe hisaishi"],
            ["马里奥", "mario"],
        ]

        /// 返回与给定歌手名同组的其他中英文别名（用于中文歌手查不到时用英文艺名补查）。
        static func aliases(for artist: String) -> [String] {
            let lowered = TextNormalizer.simplified(artist.precomposedStringWithCompatibilityMapping)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = lowered.filter { !$0.isWhitespace }
            guard compact.count >= 2 else { return [] }
            for group in artistAliasGroups {
                let matched = group.contains { alias in
                    alias == lowered || alias.filter { !$0.isWhitespace } == compact
                }
                if matched {
                    return group.filter { alias in
                        alias != lowered && alias.filter { !$0.isWhitespace } != compact
                    }
                }
            }
            return []
        }

        /// 歌手署名里是否至少有一位出现在上下文中。署名按 `/ & , 、 ; feat.` 拆成多人。
        func mentions(artist: String) -> Bool {
            let lowered = TextNormalizer.simplified(artist.precomposedStringWithCompatibilityMapping).lowercased()
            let parts = lowered
                .replacingOccurrences(of: #"\b(feat|ft|featuring|with)\b\.?"#, with: "/", options: .regularExpression)
                .split(whereSeparator: { "/&,、;".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.contains { part in
                if matchesSingleName(part) { return true }
                // 别名互查：若当前歌手名属于已知中英别名组，组内任一别名出现在上下文即视为命中。
                let compact = part.filter { !$0.isWhitespace }
                for group in Self.artistAliasGroups {
                    let hitGroup = group.contains { alias in
                        alias == part || alias.filter { !$0.isWhitespace } == compact
                    }
                    if hitGroup {
                        return group.contains { alias in alias != part && matchesSingleName(alias) }
                    }
                }
                return false
            }
        }

        private func matchesSingleName(_ part: String) -> Bool {
            let compact = part.filter { !$0.isWhitespace }
            guard compact.count >= 2 else { return false }
            if compact.allSatisfy({ $0.isASCII }) {
                // 拉丁文名字：整词命中，或足够长时的连续命中。
                let tokens = part.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
                if !tokens.isEmpty, tokens.allSatisfy(words.contains) { return true }
                return compact.count >= 5 && folded.contains(compact)
            }
            return folded.contains(compact)
        }
    }

    /// 归一化匹配键：繁转简、小写、剥离噪声括号与常见视频装饰后缀。
    static func normalize(_ title: String) -> String {
        var text = TextNormalizer.simplified(title.precomposedStringWithCompatibilityMapping).lowercased()
        for pair in [("【", "】"), ("[", "]"), ("（", "）"), ("(", ")")] {
            while let start = text.range(of: pair.0),
                  let end = text.range(of: pair.1, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let noise = ["4k", "8k", "hdr", "mv", "官方", "高清", "无损", "完整版", "纯享", "字幕版", "中文字幕"]
        for word in noise {
            text = text.replacingOccurrences(of: word, with: "")
        }
        return text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 供歌词库候选比对的“核心歌名”归一化：
    /// 在 `normalize` 基础上进一步剥离官方曲库常见的后缀副标题（如 `明天 - 《斗破苍穹》决战云岚片尾曲`、
    /// `孤勇者 - 《英雄联盟》主题曲`、`Shape of You - Acoustic`、`夜曲 - Live`、`珊瑚海 feat. 梁心颐`）
    /// 与无语义标点差异（`'`、`·`、`.`、`,`、`!`、`?`），避免真实歌曲因副标题拉长而被 60% 长度比误杀。
    static func canonicalTitle(_ raw: String) -> String {
        var text = TextNormalizer.simplified(raw.precomposedStringWithCompatibilityMapping).lowercased()
        for pair in [("【", "】"), ("[", "]"), ("（", "）"), ("(", ")")] {
            while let start = text.range(of: pair.0),
                  let end = text.range(of: pair.1, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // 剥离 `feat. / ft.` 合唱尾缀
        text = text.replacingOccurrences(
            of: #"\s+(?:feat|ft|featuring)\.?\s+.*$"#,
            with: "",
            options: .regularExpression
        )
        // 剥离 ` - 副标题`（如 OST 作品说明、Live/Remaster/Acoustic/Version/Edit/Mix/年份版等）
        let subtitlePattern = #"\s*[-—–－]\s*(?:《|「|『|动画|动漫|电影|电视剧|网剧|剧集|游戏|番剧|主题曲|片尾曲|片头曲|插曲|推广曲|印象曲|原声|ost|live|acoustic|remaster|remix|mix|edit|ver|version|demo|radio|instrumental|inst\.?|伴奏|纯音乐|纯享|完整版|现场|\d{4}).*$"#
        let stripped = text.replacingOccurrences(of: subtitlePattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty {
            text = stripped
        }
        let normalized = normalize(text)
        let punctuation = CharacterSet(charactersIn: "'’`·.,!?;:~～，。！？、；：\"“”《》「」『』")
        let cleaned = String(normalized.unicodeScalars.filter { !punctuation.contains($0) })
        return cleaned.isEmpty ? normalized : cleaned
    }

    /// 从可能带有歌手或装饰后缀的原始标题中解析「歌名 + 可选歌手」。
    static func parseTitle(_ raw: String) -> ParsedTitle {
        let candidates = titleCandidates(raw)
        guard let first = candidates.first else {
            return ParsedTitle(title: sanitizeDisplay(raw), artist: nil)
        }
        let artist = candidates.first(where: { $0.artist != nil && $0.title == first.title && !$0.isGuess })?.artist
        return ParsedTitle(title: sanitizeDisplay(first.title), artist: artist)
    }

    /// 按可信度递进生成检索候选：明确的歌名 → 带歌手 → 猜测（`isGuess`）。
    ///
    /// 视频标题没有固定格式，同一首歌能写成「歌手 - 歌名」「歌名-歌手」「音质标签｜歌名 歌手」。
    /// 这里不赌哪一段是歌名，而是把每一段都列成候选，由歌词源的结果反过来验证。
    static func titleCandidates(_ raw: String) -> [ParsedTitle] {
        // 书名号已经明确标出歌名；其后的歌手、音质标签和宣传文案不能反过来替代它，
        // 但同时保留书名号紧邻的歌手名，避免把视频 UP 主误当歌手。
        let explicit = explicitTitles(raw)
        if !explicit.isEmpty {
            let artist = extractArtistAroundBookTitle(raw)
            return explicit.map { ParsedTitle(title: $0, artist: artist) }
        }
        return structuralCandidates(raw)
    }

    /// 书名号里的歌名，外加同一标题里用「」『』或括号给出的原文名
    /// （例：《冬之花》宫本浩次（冬の花）——歌词库里只有日文名）。
    private static func explicitTitles(_ raw: String) -> [String] {
        let books = bookTitleContents(raw)
        guard !books.isEmpty else { return [] }
        var results: [String] = []
        var seen = Set<String>()
        func add(_ title: String, allowSingleCJK: Bool = false) {
            let cleaned = sanitizeDisplay(title)
            guard isUsable(cleaned, allowSingleCJK: allowSingleCJK),
                  seen.insert(normalize(cleaned)).inserted else { return }
            results.append(cleaned)
        }
        books.forEach { add($0, allowSingleCJK: true) }
        let text = normalizePunctuation(raw)
        for (open, close) in [("「", "」"), ("『", "』")] {
            for inner in pairedContents(text, open: open, close: close) where inner.count <= 30 {
                add(cleanTail(stripNoiseWords(trimAll(inner))))
            }
        }
        for inner in pairedContents(text, open: "(", close: ")") where inner.count <= 30 && containsKanaOrHangul(inner) {
            add(trimAll(inner))
        }
        return results
    }

    /// 提取标题中提到的影视/动漫/游戏作品出处（如 `（《斗破苍穹》动画第四季...）` 中的 `"斗破苍穹"`），
    /// 供 OST 歌词检索与专辑上下文旁证使用，避免被误当成歌名。
    static func workHints(_ raw: String) -> [String] {
        let matches = bookTitleMatches(raw)
        let works = matches.filter(\.isWorkReference).map(\.title)
        var seen = Set<String>()
        return works.filter { seen.insert(normalize($0)).inserted }
    }

    /// 从带书名号的标题里提取书名号紧邻的歌手名：
    /// - 优先围绕**主歌名书名号**（排除影视/动漫作品出处书名号）检索；
    /// - 优先右侧紧接 `- / — / |` 的署名（如 `《珊瑚海》-周杰伦/Lara梁心颐`、`《Anti-Hero》-Taylor Swift`）；
    /// - 其次左侧简洁署名或自然语言句式（如 `孙燕姿《逆光》`、`在录音棚听马里奥的《主角》`）。
    private static func extractArtistAroundBookTitle(_ raw: String) -> String? {
        let text = normalizePunctuation(raw)
        let matches = bookTitleMatches(raw)
        guard let primary = matches.first(where: { !$0.isWorkReference }) ?? matches.first else {
            return nil
        }

        // 1. 先检查书名号右侧显式用分隔符引导的歌手（最可靠）
        let afterRaw = String(text[primary.closeRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        if let first = afterRaw.first, "-|:：/".contains(first) {
            let tail = String(afterRaw.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let artist = cleanCandidateArtist(firstClause(of: tail)) {
                return artist
            }
        }

        // 2. 再检查书名号左侧（去掉前置【...】标签和画质噪词；支持自然语言句式如「在录音棚听马里奥的」）
        let beforeRaw = strippingAllBracketBlocks(String(text[..<primary.openRange.lowerBound]))
        let beforeLastSegment = beforeRaw.split(separator: "|").last.map(String.init) ?? beforeRaw
        if let artist = extractArtistFromPrefixPhrase(beforeLastSegment) ?? cleanCandidateArtist(beforeLastSegment) {
            return artist
        }

        // 3. 最后检查书名号右侧紧贴的短人名（如 `《冬之花》宫本浩次（冬の花）`）
        if !afterRaw.isEmpty {
            let headClause = firstClause(of: afterRaw)
            if let artist = cleanCandidateArtist(headClause) {
                return artist
            }
        }
        return nil
    }

    /// 从自然语言前缀短语中提取歌手名，例如：
    /// - `在录音棚听马里奥的` → `马里奥`
    /// - `戴上耳机听周杰伦的` → `周杰伦`
    /// - `单曲循环陈奕迅` → `陈奕迅`
    /// - `马里奥的` → `马里奥`
    private static func extractArtistFromPrefixPhrase(_ raw: String) -> String? {
        let trimmed = trimEdges(raw)
        guard !trimmed.isEmpty else { return nil }

        // 先尝试从常见引导动词之后切出歌手名（优先取最后一个动词后的部分）
        let pattern = #"(?:试听|聆听|听过|听|翻唱|演唱|献唱|合唱|独唱|清唱|学唱|唱|播放|循环|重温|欣赏|感受|品味|带来|感受一下)(?:一首|一下|这首|完|完这首)?\s*([^《》|｜,，。！？!?]{2,20}?)(?:的)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
           match.numberOfRanges >= 2 {
            let captured = (trimmed as NSString).substring(with: match.range(at: 1))
            if let artist = cleanCandidateArtist(captured) {
                return artist
            }
        }

        // 其次处理纯属格写法：`马里奥的` / `孙燕姿的`
        if trimmed.hasSuffix("的") {
            let withoutDe = String(trimmed.dropLast())
            if let artist = cleanCandidateArtist(withoutDe) {
                return artist
            }
        }
        return nil
    }

    private static func firstClause(of raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // 遇到括注、引号、分隔符或句读即截断，避免吞进宣传语或歌词摘录。
        let stopTokens = ["-", "|", "【", "[", "(", "（", "「", "『", "《", "\"", "“", ",", "，", "。", "!", "?", "#"]
        for token in stopTokens {
            if let range = text.range(of: token), range.lowerBound != text.startIndex {
                text = String(text[..<range.lowerBound])
            }
        }
        return text
    }

    private static func strippingAllBracketBlocks(_ input: String) -> String {
        var text = input
        for (open, close) in [("【", "】"), ("[", "]"), ("(", ")"), ("（", "）"), ("〔", "〕")] {
            while let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.replaceSubrange(start.lowerBound..<end.upperBound, with: " ")
            }
        }
        return text
    }

    private static func cleanCandidateArtist(_ raw: String) -> String? {
        let stripped = trimEdges(stripNoiseWords(raw))
        guard !stripped.isEmpty else { return nil }
        guard let candidate = primaryArtist(stripped) else { return nil }
        let cleaned = trimEdges(candidate)
        guard cleaned.count >= 2, cleaned.count <= 24, isUsable(cleaned) else { return nil }
        let lowered = TextNormalizer.simplified(cleaned).lowercased()
        // 排除明显是动作/场景/画质描述短语而非歌手名的文字（如"在专业录音棚听"、"零基础学唱"、"百万豪装录音棚"）。
        let nonArtistCues = [
            "录音棚", "豪装", "百万", "学唱", "零基础", "教学", "教程", "翻唱", "试听",
            "专业", "音乐", "单曲", "歌曲", "精选", "经典", "金曲", "现场", "舞台",
            "主题曲", "片尾曲", "片头曲", "插曲", "影视", "电影", "动漫", "游戏",
            "全网", "爆火", "最美", "神仙", "好听", "循环", "听完", "感受", "开口",
            "版本", "专辑", "原声", "配乐", "伴奏", "纯享", "合集", "串烧",
        ]
        if nonArtistCues.contains(where: { lowered.contains($0) }) { return nil }
        // 中文动词/介词开头或结尾通常是句子前缀（例如"在...听"、"当..."、"用..."）。
        if cleaned.contains(where: isCJK) {
            if cleaned.count > 8 { return nil }
            let sentenceMarkers = ["在", "听", "唱", "看", "用", "把", "给", "被", "让", "从", "这", "那", "的", "了", "吗", "呢"]
            if let first = cleaned.first.map(String.init), sentenceMarkers.contains(first) { return nil }
            if let last = cleaned.last.map(String.init), ["听", "唱", "看", "的", "了", "版", "曲", "歌"].contains(last) { return nil }
        }
        return cleaned
    }

    /// 没有书名号时，按分隔符把标题拆成片段，逐段生成候选。
    private static func structuralCandidates(_ raw: String) -> [ParsedTitle] {
        var text = normalizePunctuation(raw
            .replacingOccurrences(of: "\u{201C}", with: "〔")
            .replacingOccurrences(of: "\u{201D}", with: "〕"))
        // 话题标签不是歌名。
        text = text.replacingOccurrences(of: #"#[^#\s|]+#?"#, with: " ", options: .regularExpression)

        // 括号里的内容单独收集，原位置换成分隔符，免得两侧文字粘到一起。
        var bracketed: [String] = []
        // 「」『』在日文标题里就是歌名的引号，里面的内容当正经候选并排在最前。
        var quoted: [String] = []
        let pairs: [(Character, Character)] = [
            ("【", "】"), ("[", "]"), ("(", ")"), ("「", "」"), ("『", "』"), ("〔", "〕"), ("\"", "\""),
        ]
        for (open, close) in pairs {
            while let start = text.firstIndex(of: open),
                  let end = text[text.index(after: start)...].firstIndex(of: close) {
                let inner = String(text[text.index(after: start)..<end])
                if open == "「" || open == "『" { quoted.append(inner) } else { bracketed.append(inner) }
                text.replaceSubrange(start...end, with: " | ")
            }
        }

        var normals: [ParsedTitle] = []
        var pairsWithArtist: [ParsedTitle] = []
        var guesses: [ParsedTitle] = []
        for inner in quoted where inner.count <= 30 && !isDecorationOnly(inner) {
            for segment in topLevelSegments(inner) {
                collect(segment: segment, asGuess: false, normals: &normals, pairs: &pairsWithArtist, guesses: &guesses)
            }
        }
        for segment in topLevelSegments(text) {
            collect(segment: segment, asGuess: false, normals: &normals, pairs: &pairsWithArtist, guesses: &guesses)
        }
        // 整个标题都在括号里（【珊瑚海】）时，括号内容就是正经候选；否则只算猜测。
        let bracketsAreGuesses = !normals.isEmpty
        for inner in bracketed where !isDecorationOnly(inner) {
            for segment in topLevelSegments(inner) {
                collect(segment: segment, asGuess: bracketsAreGuesses,
                        normals: &normals, pairs: &pairsWithArtist, guesses: &guesses)
            }
        }

        var ordered: [ParsedTitle] = []
        var seenTitles = Set<String>()
        var seenPairs = Set<String>()
        for candidate in normals + pairsWithArtist + guesses {
            let title = sanitizeDisplay(candidate.title)
            guard isUsable(title) else { continue }
            let key = normalize(title)
            if let artist = candidate.artist {
                guard !artist.isEmpty, normalize(artist) != key,
                      seenPairs.insert(key + "|" + normalize(artist)).inserted else { continue }
            } else {
                guard seenTitles.insert(key).inserted else { continue }
            }
            ordered.append(ParsedTitle(title: title, artist: candidate.artist, isGuess: candidate.isGuess))
        }
        return ordered
    }

    /// 顶层切分：竖线、连续空格、句读。切出来的每一段各自独立。
    private static func topLevelSegments(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"\s{2,}|[,。!?~;]|\.{2,}|\.(?=\s|$)"#, with: "|", options: .regularExpression)
            .split(separator: "|")
            .map { trimEdges(stripNoiseWords(String($0))) }
            .filter { !$0.isEmpty }
    }

    private enum Divider { case spacedDash, tightDash, colon }

    /// 一个片段里的「歌名 / 歌手」结构。
    private static func collect(segment: String,
                                asGuess: Bool,
                                normals: inout [ParsedTitle],
                                pairs: inout [ParsedTitle],
                                guesses: inout [ParsedTitle]) {
        func emit(_ rawTitle: String, artist: String?, guess: Bool) {
            // 斜线两侧常是同一首歌的两种写法（冬之花/冬の花），各算一个候选。
            for spaced in rawTitle.split(separator: "/").map({ trimEdges(String($0)) }) {
                let alternative = collapsingCJKGaps(spaced)
                guard isUsable(alternative) else { continue }
                let isGuess = guess || asGuess
                if isGuess {
                    let guessedArtist = guess ? primaryArtist(artist) : nil
                    guesses.append(ParsedTitle(title: alternative, artist: guessedArtist, isGuess: true))
                } else {
                    normals.append(ParsedTitle(title: alternative, artist: nil))
                    if let artist = primaryArtist(artist) {
                        pairs.append(ParsedTitle(title: alternative, artist: artist))
                    }
                }
                // 空格隔开的几个词可能是「歌名 歌手 说明」，也可能本来就是一个带空格的歌名：逐词列为猜测。
                let words = spaced.split(separator: " ").map(String.init)
                guard words.count > 1 else { continue }
                if spaced.contains(where: isCJK) {
                    for word in words.prefix(3) where isUsable(word) {
                        guesses.append(ParsedTitle(title: word, artist: nil, isGuess: true))
                    }
                } else if let head = words.first, isUsable(head) {
                    guesses.append(ParsedTitle(title: head, artist: nil, isGuess: true))
                }
            }
        }

        let (parts, divider) = splitOnDivider(segment)
        guard parts.count == 2, let divider else {
            for part in parts { emit(part, artist: nil, guess: false) }
            return
        }
        let (left, right) = (parts[0], parts[1])
        switch divider {
        case .colon:
            // 「光遇：冬之花」这类前缀:正题。
            emit(right, artist: nil, guess: false)
            emit(left, artist: nil, guess: true)
        case .spacedDash, .tightDash:
            // 两侧带空格的横线多是「歌手 - 歌名」，紧贴的多是「歌名-歌手」；一侧明显是多人署名时以它为准。
            var titleOnLeft = divider == .tightDash
            if looksLikeArtistCredit(left), !looksLikeArtistCredit(right) { titleOnLeft = false }
            if looksLikeArtistCredit(right), !looksLikeArtistCredit(left) { titleOnLeft = true }
            let (title, artist) = titleOnLeft ? (left, right) : (right, left)
            emit(title, artist: artist, guess: false)
            emit(artist, artist: title, guess: true)
        }
    }

    private static func splitOnDivider(_ segment: String) -> ([String], Divider?) {
        let cjk = #"\p{Han}\p{Hiragana}\p{Katakana}"#
        let pattern = #"\s+-\s+|\s+-|-\s+|(?<=[CJK])-|-(?=[CJK])|:\s+|(?<=[CJK]):|:(?=[CJK])"#
            .replacingOccurrences(of: "CJK", with: cjk)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([segment], nil) }
        let source = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return ([segment], nil) }
        var parts: [String] = []
        var cursor = 0
        for match in matches {
            parts.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        parts.append(source.substring(from: cursor))
        let cleaned = parts.map(trimEdges).filter { !$0.isEmpty }
        guard matches.count == 1, cleaned.count == 2 else { return (cleaned, nil) }
        let token = source.substring(with: matches[0].range)
        if token.contains(":") { return (cleaned, .colon) }
        let spacedBothSides = token.first?.isWhitespace == true && token.last?.isWhitespace == true
        return (cleaned, spacedBothSides ? .spacedDash : .tightDash)
    }

    private static func looksLikeArtistCredit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("&") || lowered.contains("/")
            || lowered.range(of: #"\b(feat|ft)\b|\sx\s"#, options: .regularExpression) != nil
    }

    /// 多人署名只取第一位去查：歌词库的歌手栏很少和视频标题的写法逐字一致。
    private static func primaryArtist(_ artist: String?) -> String? {
        guard let artist else { return nil }
        guard var first = artist.split(whereSeparator: { "/&".contains($0) }).first.map({ trimEdges(String($0)) }) else {
            return nil
        }
        // 「周杰伦 梁心颐」这种空格隔开的中文署名也只取第一位。
        if first.contains(where: isCJK), let head = first.split(separator: " ").first {
            first = String(head)
        }
        return first.count >= 2 ? first : nil
    }

    /// 括号里只有画质、版本这类说明，没有可当歌名的内容。
    private static func isDecorationOnly(_ inner: String) -> Bool {
        let stripped = stripNoiseWords(inner).replacingOccurrences(
            of: #"(?i)(?<![a-z])(live|cover|ver|version|full|remix|edit|inst|instrumental|karaoke)(?![a-z])"#,
            with: " ", options: .regularExpression)
        return !isUsable(trimAll(stripped))
    }

    private static func containsKanaOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value)
                || (0xAC00...0xD7A3).contains($0.value)
        }
    }

    private static func pairedContents(_ text: String, open: String, close: String) -> [String] {
        var results: [String] = []
        var cursor = text.startIndex
        while let start = text[cursor...].range(of: open),
              let end = text[start.upperBound...].range(of: close) {
            results.append(String(text[start.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }
        return results
    }

    static func displayInfo(title raw: String, fallbackArtist: String?) -> (title: String, artist: String?) {
        let parsed = parseTitle(raw)
        let title = parsed.title.isEmpty ? raw : parsed.title
        if let artist = parsed.artist, !artist.isEmpty, isPlausibleArtist(artist) {
            return (title, artist)
        }
        if let fallbackArtist, !fallbackArtist.isEmpty {
            return (title, fallbackArtist)
        }
        return (title, nil)
    }

    static func cleanTail(_ input: String) -> String {
        var text = input
        if let range = text.range(of: "[ \u{3000}]{2,}", options: .regularExpression) {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        if let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: "!?~")) {
            let head = trimAll(String(text[text.startIndex..<range.lowerBound]))
            if head.count >= 2 { text = head }
        }
        for token in ["|", "/", "「", "」", "『", "』"] {
            if let range = text.range(of: token), range.lowerBound != text.startIndex {
                let head = trimAll(String(text[text.startIndex..<range.lowerBound]))
                if head.count >= 2 { text = head }
            }
        }
        text = strippingDecorations(trimAll(text))
        text = trimAll(text)
        if text.contains(" "), !text.contains(where: { $0.isASCII && $0.isLetter }) {
            text = text.replacingOccurrences(of: " ", with: "")
        }
        return text
    }

    static func strippingDecorations(_ input: String) -> String {
        var text = input
        let pairs: [(open: Character, close: Character)] = [
            ("【", "】"), ("[", "]"), ("（", "）"), ("(", ")"), ("〔", "〕"),
        ]
        for (open, close) in pairs {
            while let start = text.firstIndex(of: open),
                  let end = text[start...].firstIndex(of: close),
                  start < end {
                let inner = String(text[text.index(after: start)..<end])
                    .trimmingCharacters(in: .whitespaces)
                let lowered = inner.lowercased()
                let latinDecoration = ["official", "mv", "m/v", "audio", "lyric", "video",
                                       "hd", "4k", "8k", "hi-res", "remaster", "color coded"]
                    .contains { lowered.hasPrefix($0) }
                let isDecoration = (inner.count <= 6 || latinDecoration)
                    && !inner.contains(" - ") && !inner.contains("|")
                guard isDecoration else { break }
                text.removeSubrange(start...end)
                text = trimAll(text)
            }
        }
        return text
    }

    // MARK: - 私有辅助

    private static func sanitizeDisplay(_ title: String) -> String {
        var text = title.trimmingCharacters(
            in: CharacterSet(charactersIn: " \u{3000}\"'“”‘’「」『』《》【】[]()（）"))
        text = collapsingCJKGaps(text)
        text = text.trimmingCharacters(
            in: CharacterSet(charactersIn: " \u{3000}-|/!?~:,。.！？、；;…"))
        return text.isEmpty ? title : text
    }

    private static func isPlausibleArtist(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        let brackets: Set<Character> = ["【", "】", "《", "》", "「", "」", "『", "』", "[", "]", "(", ")", "（", "）"]
        return !brackets.contains(first)
    }

    private static func isUsable(_ text: String, allowSingleCJK: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetsLength = trimmed.count >= 2 || (allowSingleCJK && trimmed.count == 1 && trimmed.contains(where: isCJK))
        guard meetsLength, trimmed.count <= 60 else { return false }
        let banned = CharacterSet(charactersIn: "『』「」【】[]（）()《》<>“”\"")
        if trimmed.unicodeScalars.contains(where: { banned.contains($0) }) { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 只修剪两端并把连续空白压成一个空格，不合并中文之间的空格（拆词还要用）。
    private static func trimEdges(_ input: String) -> String {
        input.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{3000}-|/!?~:,。.！？、；;…"))
    }

    private static func trimAll(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(
            in: CharacterSet(charactersIn: " \u{3000}-|/!?~:,。.！？、；;…"))
        return collapsingCJKGaps(trimmed)
    }

    private static func collapsingCJKGaps(_ input: String) -> String {
        let characters = Array(input)
        var result: [Character] = []
        for (index, character) in characters.enumerated() {
            let isSpace = character == " " || character == "\u{3000}"
            guard isSpace else { result.append(character); continue }
            let previous = result.last
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let previous, let next, isCJK(previous), isCJK(next) { continue }
            result.append(character)
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3041...0x30FA).contains(scalar.value)
    }

    private static func normalizePunctuation(_ input: String) -> String {
        // 兼容分解把全角符号、𝐇𝐢-𝐑𝐞𝐬 这类花体字母折回普通写法；表情和装饰符号换成空格。
        var text = String(String.UnicodeScalarView(
            input.precomposedStringWithCompatibilityMapping.unicodeScalars.map { scalar in
                let isDecoration = scalar.properties.isEmojiPresentation
                    || scalar.properties.generalCategory == .otherSymbol
                    || scalar.properties.isVariationSelector
                return isDecoration ? " " : scalar
            }))
        let table: [(String, String)] = [
            ("｜", "|"), ("—", "-"), ("–", "-"), ("－", "-"), ("﹣", "-"),
            ("！", "!"), ("？", "?"), ("～", "~"), ("：", ":"), ("、", " "),
            ("\u{3000}", " "), ("\u{201C}", " "), ("\u{201D}", " "),
        ]
        for (from, to) in table { text = text.replacingOccurrences(of: from, with: to) }
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        return text
    }

    private static func stripNoiseWords(_ input: String) -> String {
        // 拉丁文的画质/音质/版本标签：按整词去掉，不碰单词内部。
        let latin = #"(?i)(?<![a-z])(\d+\s?k|\d{3,4}p|\d+\s?fps|\d+\s?bit|\d+(\.\d+)?\s?khz|\d+/\d+|hi-?res|hdr|sdr|mv|m/v|pv|flac|dsd|sacd|lossless|official|audio|video|lyrics?|remaster(ed)?|drv|\d+d)(?![a-z])"#
        let phrases = #"(?i)(?<![a-z])(official\s+)?(music|lyrics?)\s+(video|audio)(?![a-z])"#
        var text = input.replacingOccurrences(of: phrases, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: latin, with: " ", options: .regularExpression)
        let noise = ["官方", "超高清", "高清", "无损音质", "无损", "完整版", "纯享版", "纯享", "字幕版",
                     "中文字幕", "中字", "修复版", "修复", "重制版", "重制", "升级版",
                     "舞台直拍", "直拍", "现场版", "动态歌词", "歌词版", "收藏级", "画质", "音质",
                     "伴奏", "环绕", "立体声", "顶级"]
        for word in noise { text = text.replacingOccurrences(of: word, with: " ") }
        return text
    }

    private struct BookTitleMatch {
        let title: String
        let openRange: Range<String.Index>
        let closeRange: Range<String.Index>
        let isWorkReference: Bool
    }

    private static func bookTitleMatches(_ raw: String) -> [BookTitleMatch] {
        var results: [BookTitleMatch] = []
        let text = normalizePunctuation(raw)
        var cursor = text.startIndex
        let workSuffixPattern = #"^(?i)(?:动画|动漫|番剧|国漫|电影|大电影|电视剧|网剧|剧集|连续剧|游戏|手游|端游|小说|漫画|舞台剧|音乐剧|第[一二三四五六七八九十百0-9]+[季部集期篇]|主题曲|片尾曲|片头曲|插曲|推广曲|宣传曲|角色曲|印象曲|概念曲|原声|ost|op|ed|专辑)"#
        let workPrefixTokens = ["电影", "大电影", "动画", "动漫", "番剧", "国漫", "电视剧", "网剧", "剧集", "游戏", "手游", "专辑", "出自", "来自"]

        while let start = text[cursor...].range(of: "《"),
              let end = text[start.upperBound...].range(of: "》") {
            let inner = cleanTail(stripNoiseWords(
                trimAll(String(text[start.upperBound..<end.lowerBound]))))
            if isUsable(inner, allowSingleCJK: true) {
                let before = String(text[..<start.lowerBound])
                let after = String(text[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                let inParens = isInsideUnclosedParentheses(before)
                let followedByWorkCue = after.range(of: workSuffixPattern, options: .regularExpression) != nil
                let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
                let precededByWorkCue = workPrefixTokens.contains { beforeTrimmed.hasSuffix($0) }
                // 括号内紧跟作品/OST说明，或明确标注为影视/动画/游戏/专辑的作品名，不是歌名本身。
                let isWorkRef = followedByWorkCue || precededByWorkCue || (inParens && !results.isEmpty)
                results.append(BookTitleMatch(
                    title: inner,
                    openRange: start,
                    closeRange: end,
                    isWorkReference: isWorkRef
                ))
            }
            cursor = end.upperBound
        }
        return results
    }

    private static func isInsideUnclosedParentheses(_ prefix: String) -> Bool {
        var depth = 0
        for ch in prefix {
            if ch == "(" || ch == "（" || ch == "【" || ch == "[" { depth += 1 }
            else if (ch == ")" || ch == "）" || ch == "】" || ch == "]") && depth > 0 { depth -= 1 }
        }
        return depth > 0
    }

    private static func bookTitleContents(_ raw: String) -> [String] {
        let matches = bookTitleMatches(raw)
        let primary = matches.filter { !$0.isWorkReference }.map(\.title)
        // 若标题里所有书名号都只是括号内/作品出处（如 `马里奥 - 主角（《斗破苍穹》动画第四季片尾曲）`），
        // 绝不能把作品名《斗破苍穹》冒充成唯一歌名，返回空数组交由 structuralCandidates 正常提取 `马里奥 - 主角`。
        return primary
    }

}
