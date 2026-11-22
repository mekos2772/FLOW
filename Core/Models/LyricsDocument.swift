import Foundation

/// 行内的一段（逐字/逐词时间轴）。
///
/// AMLL（Apple Music Like Lyrics）那套"字一个个亮起来"依赖逐字时间。
/// 普通 LRC 只有整行时间，增强版 LRC 用 `<mm:ss.xx>` 给每个词打点，这里就承载它。
struct LyricSegment: Hashable, Codable, Sendable {
    /// 这一段开始的时间（秒）。
    let start: TimeInterval
    let text: String

    init(start: TimeInterval, text: String) {
        self.start = start
        self.text = text
    }
}

/// 逐字高亮的合并片段：`progress` 为 `1` 表示已点亮，`0` 表示未点亮，介于其间表示正在演唱当前字/词。
struct LyricWordRun: Equatable, Sendable {
    let text: String
    let progress: Double
}

/// 逐字高亮分段计算。与 `Text(AttributedString)` 配合，自然支持多行折行。
enum LyricWordHighlight {
    static func runs(for line: LyricLine, at time: TimeInterval) -> [LyricWordRun] {
        guard line.hasWordTiming else {
            return [LyricWordRun(text: line.text, progress: 1.0)]
        }
        var rawRuns: [LyricWordRun] = []
        rawRuns.reserveCapacity(4)

        for (index, segment) in line.segments.enumerated() {
            if segment.text.isEmpty { continue }
            let nextStart = line.segmentEnd(at: index, segment: segment)
            if time >= nextStart {
                append(LyricWordRun(text: segment.text, progress: 1.0), to: &rawRuns)
            } else if time <= segment.start {
                append(LyricWordRun(text: segment.text, progress: 0.0), to: &rawRuns)
            } else {
                let span = max(nextStart - segment.start, 0.0001)
                let segFrac = min(max((time - segment.start) / span, 0), 1)
                let chars = Array(segment.text)
                if chars.count <= 1 {
                    append(LyricWordRun(text: segment.text, progress: segFrac), to: &rawRuns)
                } else {
                    let pos = segFrac * Double(chars.count)
                    let fullCount = min(chars.count, max(0, Int(pos.rounded(.down))))
                    if fullCount > 0 {
                        append(LyricWordRun(text: String(chars[..<fullCount]), progress: 1.0), to: &rawRuns)
                    }
                    if fullCount < chars.count {
                        let activeFrac = min(max(pos - Double(fullCount), 0), 1)
                        append(LyricWordRun(text: String(chars[fullCount]), progress: activeFrac), to: &rawRuns)
                        let tailStart = fullCount + 1
                        if tailStart < chars.count {
                            append(LyricWordRun(text: String(chars[tailStart...]), progress: 0.0), to: &rawRuns)
                        }
                    }
                }
            }
        }

        if rawRuns.isEmpty {
            return [LyricWordRun(text: line.text, progress: 1.0)]
        }
        return rawRuns
    }

    private static func append(_ run: LyricWordRun, to result: inout [LyricWordRun]) {
        guard !run.text.isEmpty else { return }
        if let last = result.last, abs(last.progress - run.progress) < 0.001 {
            result[result.count - 1] = LyricWordRun(text: last.text + run.text, progress: last.progress)
        } else {
            result.append(run)
        }
    }
}

/// 单行歌词。时间统一用秒（Double），不依赖文本排版推算位置。
struct LyricLine: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval?
    let text: String
    /// 逐字时间轴。为空表示只有整行时间——视图要能优雅退回"整行高亮"。
    let segments: [LyricSegment]
    /// 译文（来自 TTML `ttm:role="x-translation"` 或双语 LRC 同时间戳第二行）。
    let translation: String?
    /// 罗马音/注音（来自 TTML `ttm:role="x-roman"`）。
    let romanization: String?

    init(id: UUID = UUID(),
         start: TimeInterval,
         end: TimeInterval? = nil,
         text: String,
         segments: [LyricSegment] = [],
         translation: String? = nil,
         romanization: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.segments = segments
        self.translation = translation
        self.romanization = romanization
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, text, segments, translation, romanization
    }

    /// 手动解码：新增字段均通过 `decodeIfPresent` 兼容旧缓存。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decodeIfPresent(TimeInterval.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        segments = try c.decodeIfPresent([LyricSegment].self, forKey: .segments) ?? []
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        romanization = try c.decodeIfPresent(String.self, forKey: .romanization)
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 这一行是否支持逐字高亮。
    var hasWordTiming: Bool { !segments.isEmpty }

    func translationText(showingTranslation: Bool) -> String? {
        guard showingTranslation, let translation else { return nil }
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return trimmed
    }

    func segmentEnd(at index: Int, segment: LyricSegment) -> TimeInterval {
        let isLast = index + 1 >= segments.count
        let rawEnd: TimeInterval = !isLast
            ? segments[index + 1].start
            : (end ?? (segment.start + max(0.35, Double(segment.text.count) * 0.25)))
        var resolved = max(segment.start, rawEnd)
        // LRC 的行尾就是"下一句的开始"：最后一个词后面跟着长间奏时，照它扫光，
        // 最后一个字会拖十几秒都不亮（沉浸模式实机放歌发现）。超过 6 秒的尾段按字数估一个正常的唱完时间；
        // 6 秒以内仍以 `end` 为准，TTML 里真正的长音不受影响。
        if isLast, resolved - segment.start > 6 {
            resolved = segment.start + min(max(Double(segment.text.count) * 0.45, 1.2), 6)
        }
        return resolved
    }

    /// 在 `time`（已含偏移的歌词时间）时，逐字填充到第几个字符。
    ///
    /// 返回 0…1 的比例，供视图做"从左到右点亮"的遮罩。没有逐字时间时返回 nil，
    /// 调用方退回整行高亮。
    func filledFraction(at time: TimeInterval) -> Double? {
        guard hasWordTiming, !text.isEmpty else { return nil }
        let total = Double(text.count)
        guard total > 0 else { return nil }
        var consumed = 0.0
        for (index, segment) in segments.enumerated() {
            let length = Double(segment.text.count)
            let nextStart = segmentEnd(at: index, segment: segment)
            if time >= nextStart {
                consumed += length
                continue
            }
            if time <= segment.start { break }
            let span = max(nextStart - segment.start, 0.0001)
            let progress = min(max((time - segment.start) / span, 0), 1)
            consumed += length * progress
            break
        }
        return min(max(consumed / total, 0), 1)
    }
}

/// LRC 元信息标签。只保留对用户可见或对时间轴有影响的部分。
struct LyricsMetadata: Hashable, Codable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var author: String?
    /// LRC `[offset:]`，单位毫秒。正数表示歌词应提前出现。
    var offsetMilliseconds: Int

    static let empty = LyricsMetadata(offsetMilliseconds: 0)
}

enum LyricsSource: String, Codable, Sendable {
    case embedded      // 音频内嵌
    case sidecar       // 同目录 .lrc
    case external      // 外部提供者（本期未接入网络）
    case unsynced      // 有时间轴之外的纯文本
}

enum LyricsSynchronization: String, Codable, Sendable {
    case synced
    case unsynced
}

/// 歌词文档。所有来源解析后统一收敛成这个结构。
struct LyricsDocument: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let trackIdentity: TrackIdentity
    let lines: [LyricLine]
    let metadata: LyricsMetadata
    let source: LyricsSource
    let synchronization: LyricsSynchronization
    /// 文档自带、且**尚未体现在 `lines` 里**的偏移。
    ///
    /// LRC 的 `[offset:]` 由解析器直接折进每行时间，所以 LRC 文档这里恒为 0；
    /// 只有时间轴未经调整的来源才需要填它。与用户偏移分开保存，互不覆盖。
    let embeddedOffset: TimeInterval

    init(id: UUID = UUID(),
         trackIdentity: TrackIdentity,
         lines: [LyricLine],
         metadata: LyricsMetadata = .empty,
         source: LyricsSource = .sidecar,
         synchronization: LyricsSynchronization = .synced,
         embeddedOffset: TimeInterval = 0) {
        self.id = id
        self.trackIdentity = trackIdentity
        self.lines = lines
        self.metadata = metadata
        self.source = source
        self.synchronization = synchronization
        self.embeddedOffset = embeddedOffset
    }

    var isSynced: Bool { synchronization == .synced }

    var isEmpty: Bool { lines.allSatisfy(\.isEmpty) }
}
