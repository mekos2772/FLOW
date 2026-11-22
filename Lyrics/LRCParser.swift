import Foundation

/// LRC 解析器。纯函数，不抛异常——解析失败只返回 `nil`，绝不让播放器崩溃。
///
/// 需要容忍的真实世界脏数据：
/// - UTF-8 BOM、CRLF / CR / LF 三种换行；
/// - 一行多个时间标签 `[00:12.00][00:24.00]同一句歌词`；
/// - 元信息标签 `[ti:] [ar:] [al:] [by:] [offset:]`，以及未知标签；
/// - 重复时间戳（保留先出现的非空文本）；
/// - 非法时间戳（`[99:99]`、负值、乱码）直接丢弃该标签；
/// - 完全没有时间标签的纯文本 → 标记为 unsynced，不参与高亮。
enum LRCParser {
    struct Result: Sendable, Equatable {
        var lines: [LyricLine]
        var metadata: LyricsMetadata
        var synchronization: LyricsSynchronization
        var droppedTagCount: Int
    }

    /// 小数位放宽到 6 位（`[00:12.3456]` 这类高精度写法真实存在），换算时只取前三位。
    /// 之前上限是 3 位：多一位整行就匹配不上，被当成纯文本丢掉。
    private static let timePattern = try? NSRegularExpression(
        pattern: #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,6}))?\]"#
    )
    private static let metaPattern = try? NSRegularExpression(
        pattern: #"^\[(ti|ar|al|by|offset|length|re|ve):([^\]]*)\]"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> Result? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        // 繁→简只对中文做；日文歌词（含假名）原样保留。判定时跳过制作者等技术标签。
        let convert = TextNormalizer.converter(forDocument: TextNormalizer.lrcBodyAndTitles(normalized))
        var metadata = LyricsMetadata.empty
        var collected: [(time: TimeInterval, text: String, order: Int, segments: [LyricSegment])] = []
        var order = 0
        var plainLines: [String] = []
        var dropped = 0

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = String(rawLine).trimmingCharacters(in: .whitespaces)

            // 元信息标签可以出现在行首任意位置。
            while let match = firstMatch(metaPattern, in: remainder) {
                let key = match.key.lowercased()
                let value = match.value.trimmingCharacters(in: .whitespaces)
                switch key {
                // 元信息里的歌名/歌手也可能是繁体，同样归一。
                case "ti": metadata.title = value.isEmpty ? nil : convert(value)
                case "ar": metadata.artist = value.isEmpty ? nil : convert(value)
                case "al": metadata.album = value.isEmpty ? nil : convert(value)
                case "by": metadata.author = value.isEmpty ? nil : convert(value)
                case "offset": metadata.offsetMilliseconds = Int(value) ?? 0
                default: break
                }
                remainder = String(remainder[match.end...])
                    .trimmingCharacters(in: .whitespaces)
            }

            var times: [TimeInterval] = []
            while let match = firstMatch(timePattern, in: remainder) {
                if let seconds = seconds(from: match) {
                    times.append(seconds)
                } else {
                    dropped += 1
                }
                // 标签之间允许有空格（`[00:10.00] [00:20.00]副歌`）：
                // 不去掉的话第二个标签匹配不上，会被当成歌词正文显示出来。
                remainder = String(remainder[match.end...])
                    .trimmingCharacters(in: .whitespaces)
            }

            // 字幕/LRC 常常是繁体；统一转成简体，避免同一屏里"英雄主義"和"英雄主义"并存。
            // 增强版 LRC 用 `<mm:ss.xx>` 给行内每个词打点（AMLL / A2 格式）。
            // 先把它们拆出来，正文是各段拼接，段落保留各自时间。
            let parsed = Self.splitWordTags(remainder)
            let content = convert(parsed.text.trimmingCharacters(in: .whitespaces))
            let segments = parsed.segments.map {
                LyricSegment(start: $0.start, text: convert($0.text))
            }

            if times.isEmpty {
                if !content.isEmpty { plainLines.append(content) }
                continue
            }

            for time in times {
                // 逐字时间如果早于行首（脏数据），相对行首重新对齐，避免填充倒退。
                // 行首到第一个词标签之间的文字没有自己的时间（`NaN`）：它从行首开始。
                // 注意 `max(NaN, time)` 的结果是 NaN——必须显式判断，否则这一段的起点
                // 最后会被夹成 0，表现为"这句还没开始唱，前半句已经整段点亮"。
                let aligned = segments.map { segment in
                    LyricSegment(start: segment.start.isNaN ? time : max(segment.start, time),
                                 text: segment.text)
                }
                collected.append((time, content, order, aligned))
                order += 1
            }
        }

        // 重复时间戳：保留先出现的非空文本；若同时间戳紧跟一条含中文译文，保留作双语译文。
        var byTime: [TimeInterval: (text: String, order: Int, segments: [LyricSegment], translation: String?)] = [:]
        for entry in collected {
            let key = (entry.time * 1000).rounded() / 1000
            if var existing = byTime[key] {
                if existing.text.isEmpty, !entry.text.isEmpty {
                    existing.text = entry.text
                    existing.segments = entry.segments
                    byTime[key] = existing
                } else if existing.translation == nil,
                          !existing.text.isEmpty,
                          !entry.text.isEmpty,
                          existing.text != entry.text,
                          Self.isForeignOriginal(existing.text),
                          Self.isChineseTranslation(entry.text) {
                    existing.translation = TextNormalizer.simplifiedTranslation(entry.text)
                    byTime[key] = existing
                }
                continue
            }
            byTime[key] = (entry.text, entry.order, entry.segments, nil)
        }

        guard !byTime.isEmpty else {
            // 只有纯文本：转成 unsynced 文档，UI 可以展示但不做时间高亮。
            guard !plainLines.isEmpty else { return nil }
            let lines = plainLines.map { LyricLine(start: 0, text: $0) }
            return Result(lines: lines, metadata: metadata, synchronization: .unsynced, droppedTagCount: dropped)
        }

        let shift = -TimeInterval(metadata.offsetMilliseconds) / 1000

        struct Entry {
            var time: TimeInterval
            var text: String
            var order: Int
            var segments: [LyricSegment]
            var translation: String?
        }

        var entries: [Entry] = []
        entries.reserveCapacity(byTime.count)
        for (time, value) in byTime {
            entries.append(Entry(time: time, text: value.text, order: value.order,
                                 segments: value.segments, translation: value.translation))
        }
        entries.sort { lhs, rhs in
            lhs.time == rhs.time ? lhs.order < rhs.order : lhs.time < rhs.time
        }

        var lines: [LyricLine] = []
        lines.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let start = max(0, entry.time + shift)
            let shifted = entry.segments.map {
                LyricSegment(start: max(0, $0.start + shift), text: $0.text)
            }
            // 行尾时间：下一行的开始（没有下一行就交给引擎按"当前行"处理）。
            let end = index + 1 < entries.count ? max(0, entries[index + 1].time + shift) : nil
            lines.append(LyricLine(start: start, end: end, text: entry.text,
                                   segments: shifted, translation: entry.translation))
        }

        return Result(lines: lines, metadata: metadata, synchronization: .synced, droppedTagCount: dropped)
    }

    private static func isForeignOriginal(_ text: String) -> Bool {
        TextNormalizer.containsKana(text) || containsHangul(text) || !containsCJK(text)
    }

    private static func isChineseTranslation(_ text: String) -> Bool {
        containsCJK(text) && !TextNormalizer.containsKana(text) && !containsHangul(text)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value)
        }
    }


    /// 拆出增强版 LRC 的行内词标签 `<mm:ss.xx>`。
    ///
    /// 返回的正文把标签去掉；`segments` 按出现顺序给出（时间, 文本）。
    /// 没有词标签时 `segments` 为空，调用方按整行高亮处理。
    static func splitWordTags(_ input: String) -> (text: String, segments: [(start: TimeInterval, text: String)]) {
        guard input.contains("<") else { return (input, []) }
        var text = ""
        var segments: [(start: TimeInterval, text: String)] = []
        var rest = Substring(input)
        var pendingStart: TimeInterval?

        while let open = rest.firstIndex(of: "<") {
            // 标签之前的内容属于上一段。
            let chunk = String(rest[rest.startIndex..<open])
            if !chunk.isEmpty {
                text += chunk
                if let start = pendingStart {
                    segments.append((start, chunk))
                    pendingStart = nil
                } else {
                    // 行首到第一个词标签之间的文字：算作 0 相对位置的引导段。
                    segments.append((.nan, chunk))
                }
            }
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let inner = rest[rest.index(after: open)..<close]
            pendingStart = Self.wordTagSeconds(String(inner)) ?? pendingStart
            rest = rest[rest.index(after: close)...]
        }
        let tail = String(rest)
        if !tail.isEmpty {
            text += tail
            if let start = pendingStart { segments.append((start, tail)) }
            else { segments.append((.nan, tail)) }
        }
        return (text, segments)
    }

    /// `<00:12.34>` 里的 `00:12.34` → 12.34 秒。
    private static func wordTagSeconds(_ raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    // MARK: - 工具

    private static func normalize(_ text: String) -> String {
        var value = text
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        return value
    }

    private struct Match {
        /// 匹配结束的位置（`String.Index`）。
        ///
        /// **不能用长度**：`NSRange.length` 数的是 UTF-16 码元，而 `String.removeFirst(_:)`
        /// 数的是字符。标签里只要有一个 emoji 或组合字符（`[by:🌸小樱🌸]`、`[ar:ลิซ่า]`），
        /// 码元数就比字符数多，`removeFirst` 会越界直接让进程崩掉——
        /// 而歌词是**先落盘再解析**的，崩过一次之后每次启动恢复上一首歌都会再崩一次。
        var end: String.Index
        var groups: [String]
        var key: String { groups.first ?? "" }
        var value: String { groups.count > 1 ? groups[1] : "" }
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> Match? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [.anchored], range: range),
              let matched = Range(result.range, in: text) else { return nil }

        var groups: [String] = []
        for index in 1..<result.numberOfRanges {
            if let groupRange = Range(result.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append("")
            }
        }
        return Match(end: matched.upperBound, groups: groups)
    }

    private static func seconds(from match: Match) -> TimeInterval? {
        guard match.groups.count >= 2,
              let minutes = Int(match.groups[0]),
              let secs = Int(match.groups[1]),
              minutes >= 0, secs >= 0, secs < 60 else {
            return nil
        }
        let fractionText = match.groups.count > 2 ? match.groups[2] : ""
        let fraction: Double
        switch fractionText.count {
        case 0: fraction = 0
        case 1: fraction = (Double(fractionText) ?? 0) / 10
        case 2: fraction = (Double(fractionText) ?? 0) / 100
        default: fraction = (Double(fractionText.prefix(3)) ?? 0) / 1000
        }
        return TimeInterval(minutes * 60 + secs) + fraction
    }
}
