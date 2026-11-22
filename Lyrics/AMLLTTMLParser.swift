import Foundation

/// AMLL（Apple Music Like Lyrics）逐词 TTML 的解析器。
///
/// 格式要点（实测 `amll-dev/amll-ttml-db` 的真实文件）：
/// ```xml
/// <tt><body><div>
///   <p begin="00:00.820" end="00:03.546">
///     <span begin="00:00.820" end="00:00.914">Couldn</span>
///     <span begin="00:00.914" end="00:00.929">'</span>
///     …
///   </p>
/// </div></body></tt>
/// ```
/// `<p>` 是一行，`<span>` 是行内逐字段。行内可能有多组 `<span>` 包在 `<span>` 里（对唱/和声），
/// 这里一律按"叶子 span"展开，时间相对整首曲子。
///
/// 用 `XMLParser`（Foundation 自带），不引第三方 XML 库。
final class AMLLTTMLParser: NSObject, XMLParserDelegate {

    private struct RawLine {
        var start: TimeInterval
        var end: TimeInterval?
        var segments: [LyricSegment]
        var translation: String?
        var romanization: String?
    }

    private enum IgnoredRole {
        case translation
        case roman
        case other
    }

    private var lines: [RawLine] = []
    private var current: RawLine?
    private var spanStart: TimeInterval?
    private var buffer = ""
    private var insideSpan = 0
    /// 栈式跟踪非正文 span（翻译 / 罗马音 / 和声），同时保留译文与罗马音供双语对照开关使用。
    private var ignoredStack: [IgnoredRole] = []
    private var translationBuffer = ""
    private var romanBuffer = ""

    /// 这些 `ttm:role` 不是正文。
    ///
    /// 实测 TTML 里译文是这样写的：
    /// `<span ttm:role="x-translation" xml:lang="zh-CN">她露出笑容…</span>`
    /// 第一版把它们和原文摊在一起，结果一行变成
    /// `Couldn'tbeathersmile…她露出笑容吸引所有媒体的目光`。
    /// `x-roman` 是罗马音注音（日/韩语歌很常见），同样不是正文：
    /// 不排除的话一行会变成「君の名は kimi no na wa」。
    static let nonLyricRoles: Set<String> = ["x-translation", "x-roman", "x-bg", "x-bg-vocal"]

    /// 解析 TTML 文本。失败返回空数组（调用方据此退回其它歌词源）。
    ///
    /// 只认**逐词 TTML**：`<p>` 里的正文必须包在 `<span>` 里（AMLL 库全是这种格式）。
    /// `<p>` 直接含文本的普通 TTML 会被丢成空行——调用方会退回 LRCLIB，
    /// 不会去展示一份没有时间轴的歌词。
    static func parse(_ xml: String) -> [LyricLine] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = AMLLTTMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.finish()
    }

    private func finish() -> [LyricLine] {
        closeCurrent()
        // 日文歌词不做繁→简（见 `TextNormalizer.containsKana`）；整份判断一次。
        let convert = TextNormalizer.converter(
            forDocument: lines.flatMap { $0.segments.map(\.text) }.joined())
        return lines.enumerated().map { index, raw in
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : nil
            // 行尾不留空格（最后一个词后面的词间空格没有意义）。
            var segments = raw.segments
            if let last = segments.last, last.text.hasSuffix(" ") {
                segments[segments.count - 1] = LyricSegment(
                    start: last.start, text: String(last.text.dropLast()))
            }
            let text = segments.map(\.text).joined()
            let translation = raw.translation.map(TextNormalizer.simplifiedTranslation)
            return LyricLine(start: raw.start,
                             end: raw.end ?? nextStart,
                             text: convert(text),
                             segments: segments.map {
                                 LyricSegment(start: $0.start, text: convert($0.text))
                             },
                             translation: translation,
                             romanization: raw.romanization)
        }
        .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func closeCurrent() {
        guard current != nil else { return }
        flushBuffer()
        flushRoleBuffers()
        guard let line = current else { return }
        guard !line.segments.isEmpty else {
            current = nil
            ignoredStack.removeAll()
            return
        }
        // 没写 `end` 就留空：`finish()` 会用下一行的开始时间兜底。
        // 之前这里把 end 设成了**自己的 start**——行长为 0，进度恒为 100%，
        // 最后一个词在这一行刚出现的瞬间就整个点亮。
        lines.append(line)
        current = nil
        ignoredStack.removeAll()
    }

    private func flushRoleBuffers() {
        let trans = translationBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trans.isEmpty, current?.translation == nil {
            current?.translation = trans
        }
        let roman = romanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !roman.isEmpty, current?.romanization == nil {
            current?.romanization = roman
        }
        translationBuffer = ""
        romanBuffer = ""
    }

    private func flushBuffer() {
        guard let start = spanStart, !buffer.isEmpty, current != nil else { buffer = ""; return }
        current?.segments.append(LyricSegment(start: start, text: buffer))
        buffer = ""
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = (qName ?? elementName).lowercased()
        switch name {
        case "p", "div":
            // div 也可能带 begin/end，但行以 p 为准；div 只用来兜底断行。
            if name == "p" {
                closeCurrent()
                let begin = Self.seconds(attributeDict["begin"]) ?? 0
                current = RawLine(start: begin, end: Self.seconds(attributeDict["end"]), segments: [])
            }
        case "span":
            let role = attributeDict["ttm:role"] ?? attributeDict["role"] ?? ""
            if Self.nonLyricRoles.contains(role) {
                let kind: IgnoredRole
                if ignoredStack.isEmpty {
                    kind = role == "x-translation" ? .translation : (role == "x-roman" ? .roman : .other)
                } else {
                    kind = .other
                }
                ignoredStack.append(kind)
                return
            }
            guard ignoredStack.isEmpty else {
                ignoredStack.append(.other)
                return
            }
            insideSpan += 1
            flushBuffer()
            spanStart = Self.seconds(attributeDict["begin"]) ?? current?.start
        case "br":
            // 行内换行：在当前行结束，下一段另起一行。
            closeCurrent()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        if let activeRole = ignoredStack.first {
            // 顶层译文 / 罗马音（允许内嵌子 span）写入各自辅助字段；和声（x-bg）全部忽略。
            let cleaned = string.filter { !$0.isNewline && $0 != "\t" }
            switch activeRole {
            case .translation: translationBuffer += cleaned
            case .roman: romanBuffer += cleaned
            case .other: break
            }
            return
        }
        guard ignoredStack.isEmpty else { return }
        if insideSpan > 0 {
            // span 内的排版换行/缩进不能进歌词文本：手写文件里 `<span>词\n  词</span>`
            // 这类内容会把缩进空白原样带进逐字计长，填充比例全偏。
            buffer += string.filter { !$0.isNewline && $0 != "\t" }
            return
        }
        // 两个 `<span>` **之间**的文字。
        //
        // 逐词 TTML 里英文单词各占一个 span，词与词之间的空格是 span 外面的文本节点：
        // `<span>beat</span> <span>her</span> <span>smile</span>`。
        // 之前 span 外的字符一律丢弃，于是整行粘成 `beathersmile`。
        // 只认**纯空格**：带换行的是排版缩进（中文逐字 span 之间不该凭空多出空格）。
        guard !string.isEmpty, string.allSatisfy({ $0 == " " || $0 == "\u{00A0}" }),
              var line = current, let last = line.segments.last, !last.text.hasSuffix(" ") else { return }
        line.segments[line.segments.count - 1] = LyricSegment(start: last.start, text: last.text + " ")
        current = line
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        switch name {
        case "span":
            if let closed = ignoredStack.popLast() {
                if ignoredStack.isEmpty {
                    switch closed {
                    case .translation:
                        let trans = translationBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trans.isEmpty, current?.translation == nil { current?.translation = trans }
                        translationBuffer = ""
                    case .roman:
                        let roman = romanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !roman.isEmpty, current?.romanization == nil { current?.romanization = roman }
                        romanBuffer = ""
                    case .other:
                        break
                    }
                }
                return
            }
            flushBuffer()
            insideSpan = max(0, insideSpan - 1)
            if insideSpan == 0 { spanStart = nil }
        case "p":
            closeCurrent()
        default:
            break
        }
    }

    /// `00:00.820` / `01:23:45.678` → 秒。
    static func seconds(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return parts.isEmpty ? nil : total
    }
}
