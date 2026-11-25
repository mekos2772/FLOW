import Foundation

/// 歌词与标题的文字归一化。
///
/// 起因：B 站的歌词（稿件字幕、部分 LRC）大量是**繁体**，而应用界面是简体——
/// 同一屏里"英雄主義"和"英雄主义"并存，看起来像两首歌。
///
/// 用系统的 `CFStringTransform` 做繁→简：这是 macOS 自带的能力，
/// 不需要引入任何第三方转换表。
enum TextNormalizer {
    /// 繁体转简体。已经简体或纯英文/数字的文本原样返回。
    static func simplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // 含 CJK（含兼容汉字区）才值得转换：纯英文/数字走一遍纯属浪费。
        guard text.unicodeScalars.contains(where: {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }) else {
            return text
        }
        let mutable = NSMutableString(string: text)
        // 这个常量在 Foundation 里没导出成 Swift 符号，用它的字面值（ICU 变换名）。
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return mutable as String
    }

    /// 简体转繁体。供外部歌词源（如 LRCLIB 收录的大量港台繁体条目）做双写检索。
    static func traditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard text.unicodeScalars.contains(where: {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }) else {
            return text
        }
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Simplified-Traditional" as CFString, false)
        return mutable as String
    }

    /// 这段文字是不是日文（含假名音节，排除中文排印常用间隔号 `・` 等非假名标点）。
    ///
    /// 繁→简转换**只能用在中文上**。日文汉字和繁体字大量共用码位，
    /// 对日文歌词做繁→简会得到「无敌の笑颜」「君の名は」里的「気」变「气」这种
    /// 既不是日文也不是中文的东西——而且是悄悄发生的，看起来就像歌词源本身写错了。
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKanaScalar($0) }
    }

    private static func isKanaScalar(_ scalar: UnicodeScalar) -> Bool {
        // 仅匹配平假名 (ぁ–ゖ) 与片假名音节 (ァ–ヺ / ㇰ–ㇿ)，排除 U+30FB (・) 等标点。
        (0x3041...0x3096).contains(scalar.value)
            || (0x30A1...0x30FA).contains(scalar.value)
            || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func isHanziScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// 判断整份文档是否属于日文歌词（存在实质性假名，而非整首中文里偶发单个点缀假名）。
    static func shouldPreserveJapanese(_ document: String) -> Bool {
        var kana = 0
        var hanzi = 0
        for scalar in document.unicodeScalars {
            if isKanaScalar(scalar) { kana += 1 }
            else if isHanziScalar(scalar) { hanzi += 1 }
        }
        guard kana > 0 else { return false }
        // 中文歌词里夹带极个别装饰性假名（例如「の」）时，假名占比极低（< 8%），仍按中文转简体；
        // 日文歌曲本身（包括短片段如「無敵の笑顔」20%）假名占比显著高于此阈值，保持原样。
        if hanzi >= 12, Double(kana) / Double(hanzi + kana) < 0.08 { return false }
        return true
    }

    /// 译文繁→简：保护日文译文与英文原文不被误改。
    static func simplifiedTranslation(_ text: String) -> String {
        shouldPreserveJapanese(text) ? text : simplified(text)
    }

    /// 按**整份文档**决定要不要转换，再逐段处理。
    ///
    /// 必须整份判断：逐词歌词里一个词就是一段，「無敵」单看没有假名，
    /// 逐段判断会把它转成「无敌」而旁边的「の」原样保留。
    /// - Parameter document: 整份歌词的全文（用来判断语言）。
    static func converter(forDocument document: String) -> @Sendable (String) -> String {
        if shouldPreserveJapanese(document) {
            return { text in text }
        }
        return { text in TextNormalizer.simplified(text) }
    }

    /// 把整份 LRC 原文里的中文行（非日文时）转为简体，保留 `[mm:ss.xx]` 与 `<mm:ss.xx>` 标签。
    static func simplifiedLRC(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let sample = lrcBodyAndTitles(raw)
        let convert = converter(forDocument: sample)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { convert(String($0)) }
            .joined(separator: "\n")
    }

    /// 提取 LRC 用于语言判定的主体文本，跳过 `[by:]` / `[re:]` / `[ve:]` 等制作署名标签。
    static func lrcBodyAndTitles(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !trimmed.hasPrefix("[by:")
                    && !trimmed.hasPrefix("[re:")
                    && !trimmed.hasPrefix("[ve:")
                    && !trimmed.hasPrefix("[offset:")
                    && !trimmed.hasPrefix("[length:")
            }
            .joined(separator: "\n")
    }

    /// 把歌词文档规范化为简体中文（日文文档原样保留）。
    static func simplified(document: LyricsDocument) -> LyricsDocument {
        let corpus = ([document.metadata.title, document.metadata.artist, document.metadata.album]
            .compactMap { $0 }
            + document.lines.map(\.text))
            .joined(separator: "\n")
        let convert = converter(forDocument: corpus)
        let lines = document.lines.map { line in
            LyricLine(
                id: line.id,
                start: line.start,
                end: line.end,
                text: convert(line.text),
                segments: line.segments.map { LyricSegment(start: $0.start, text: convert($0.text)) },
                translation: line.translation.map(simplifiedTranslation),
                romanization: line.romanization
            )
        }
        let meta = LyricsMetadata(
            title: document.metadata.title.map(convert),
            artist: document.metadata.artist.map(convert),
            album: document.metadata.album.map(convert),
            author: document.metadata.author.map(convert),
            offsetMilliseconds: document.metadata.offsetMilliseconds
        )
        return LyricsDocument(
            id: document.id,
            trackIdentity: document.trackIdentity,
            lines: lines,
            metadata: meta,
            source: document.source,
            synchronization: document.synchronization,
            embeddedOffset: document.embeddedOffset
        )
    }

    /// 批量处理歌词行。空白行原样保留，避免改变行数。
    static func simplified(lines: [String]) -> [String] {
        lines.map { $0.isEmpty ? $0 : simplified($0) }
    }
}
