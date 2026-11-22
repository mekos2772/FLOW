import Foundation

/// 源无关的歌曲标题与歌手查询词清洗工具。
///
/// 统一用于 AMLL 索引、LRCLIB 检索/排序及长标题精简展示，
/// 同时去除视频站/网盘常见的装饰括号、分辨率与推广尾缀噪声。
enum LyricQueryNormalizer {

    struct ParsedTitle: Sendable, Equatable {
        var title: String
        var artist: String?
    }

    /// 归一化匹配键：繁转简、小写、剥离噪声括号与常见视频装饰后缀。
    static func normalize(_ title: String) -> String {
        var text = TextNormalizer.simplified(title).lowercased()
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

    /// 从可能带有歌手或装饰后缀的原始标题中解析「歌名 + 可选歌手」。
    static func parseTitle(_ raw: String) -> ParsedTitle {
        if let inner = trailingBookTitle(raw).first(where: { isUsable($0) }) {
            let split = splitArtistAndTitle(inner)
            let title = trimAll(split.0)
            if !title.isEmpty {
                return ParsedTitle(title: sanitizeDisplay(title),
                                   artist: split.1.map(trimAll))
            }
        }
        let candidates = titleCandidates(raw)
        guard let first = candidates.first else {
            return ParsedTitle(title: sanitizeDisplay(raw), artist: nil)
        }
        let artist = candidates.first(where: { $0.artist != nil && $0.title == first.title })?.artist
        return ParsedTitle(title: sanitizeDisplay(first.title), artist: artist)
    }

    /// 按命中率递进生成检索候选：纯歌名 → 带歌手 → 首个词。
    static func titleCandidates(_ raw: String) -> [ParsedTitle] {
        var variants: [(title: String, artist: String?)] = []
        let bases = normalizedBases(raw)
        for base in bases {
            let (title, artist) = splitArtistAndTitle(base)
            if isUsable(title) { variants.append((title, artist)) }
        }
        for inner in bracketedTitles(raw) {
            let (title, artist) = splitArtistAndTitle(inner)
            if isUsable(title) { variants.append((title, artist)) }
        }

        var ordered: [ParsedTitle] = []
        var seen = Set<String>()
        func append(_ title: String, _ artist: String?) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsable(trimmed) else { return }
            guard seen.insert(trimmed + "|" + (artist ?? "")).inserted else { return }
            ordered.append(ParsedTitle(title: trimmed, artist: artist))
        }

        for variant in variants { append(variant.title, nil) }
        for variant in variants {
            if let artist = variant.artist, !artist.isEmpty, artist != variant.title {
                append(variant.title, artist)
            }
        }
        for variant in variants {
            let head = variant.title.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init)
            if let head, head != variant.title { append(head, nil) }
        }
        return ordered
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

    private static func isUsable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 60 else { return false }
        let banned = CharacterSet(charactersIn: "『』「」【】[]（）()《》<>“”\"")
        if trimmed.unicodeScalars.contains(where: { banned.contains($0) }) { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func normalizedBases(_ raw: String) -> [String] {
        let unified = normalizePunctuation(raw)
        var stripped = unified
        for pair in [("【", "】"), ("[", "]"), ("（", "）"), ("(", ")"), ("『", "』"), ("「", "」")] {
            stripped = removePaired(stripped, open: pair.0, close: pair.1)
        }
        stripped = stripNoiseWords(stripped)
        var results = [trimAll(stripped)]
        let unwrapped = trimAll(unified
            .replacingOccurrences(of: "《", with: " ")
            .replacingOccurrences(of: "》", with: " ")
            .replacingOccurrences(of: "\u{201C}", with: " ")
            .replacingOccurrences(of: "\u{201D}", with: " "))
        let unwrappedStripped = trimAll(stripNoiseWords(unwrapped))
        if !unwrappedStripped.isEmpty, !results.contains(unwrappedStripped) { results.append(unwrappedStripped) }
        return results.filter { !$0.isEmpty }
    }

    private static func removePaired(_ input: String, open: String, close: String) -> String {
        var text = input
        while let startRange = text.range(of: open),
              let endRange = text.range(of: close, range: startRange.upperBound..<text.endIndex) {
            text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return text
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
    }

    private static func normalizePunctuation(_ input: String) -> String {
        var text = input
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
        var text = input
        let noise = ["MV", "mv", "官方", "高清", "无损", "完整版", "纯享", "字幕版",
                     "中文字幕", "2160P", "1080P", "4K", "8K", "Hi-Res", "修复版", "修复",
                     "舞台直拍", "直拍", "现场版", "动态歌词", "歌词版"]
        for word in noise { text = text.replacingOccurrences(of: word, with: " ") }
        return text
    }

    private static func bookTitleContents(_ raw: String) -> [String] {
        var results: [String] = []
        let text = normalizePunctuation(raw)
        var cursor = text.startIndex
        while let start = text[cursor...].range(of: "《"),
              let end = text[start.upperBound...].range(of: "》") {
            let inner = cleanTail(stripNoiseWords(
                trimAll(String(text[start.upperBound..<end.lowerBound]))))
            if inner.count >= 2, isUsable(inner) { results.append(inner) }
            cursor = end.upperBound
        }
        return results
    }

    private static func trailingBookTitle(_ raw: String) -> [String] {
        let text = normalizePunctuation(raw)
        guard let close = text.range(of: "》", options: .backwards) else { return [] }
        let tail = trimAll(String(text[close.upperBound...]))
        guard tail.allSatisfy({ " \t—-·、,，.。!！?？~～".contains($0) }) else { return [] }
        return bookTitleContents(raw)
    }

    private static func bracketedTitles(_ raw: String) -> [String] {
        var results: [String] = []
        let text = normalizePunctuation(raw)
        let pairs: [(String, String)] = [("《", "》"), ("【", "】"), ("「", "」"), ("『", "』"), ("(", ")")]
        for (open, close) in pairs {
            var cursor = text.startIndex
            while let start = text[cursor...].range(of: open),
                  let end = text[start.upperBound...].range(of: close) {
                let inner = cleanTail(stripNoiseWords(
                    trimAll(String(text[start.upperBound..<end.lowerBound]))))
                if inner.count >= 2, inner.count <= 30, isUsable(inner) { results.append(inner) }
                cursor = end.upperBound
            }
        }
        return results
    }

    private static func splitArtistAndTitle(_ input: String) -> (String, String?) {
        let text = trimAll(input)
        for separator in ["｜", "|"] {
            guard let range = text.range(of: separator) else { continue }
            let left = trimAll(String(text[text.startIndex..<range.lowerBound]))
            let right = trimAll(String(text[range.upperBound...]))
            guard !left.isEmpty, !right.isEmpty else { continue }
            let title = cleanTail(left)
            guard isUsable(title) else { continue }
            return (title, nil)
        }
        for separator in [" - ", "-"] {
            guard let range = text.range(of: separator) else { continue }
            let left = trimAll(String(text[text.startIndex..<range.lowerBound]))
            let right = trimAll(String(text[range.upperBound...]))
            guard !left.isEmpty, !right.isEmpty else { continue }
            return (cleanTail(right), cleanTail(left))
        }
        return (cleanTail(text), nil)
    }
}
