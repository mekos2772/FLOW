import Foundation
import os

/// 日志门面。所有对外输出的日志都必须经过这里，保证脱敏规则只有一处。
///
/// 脱敏对象（对应规格 13.4）：
/// - URL 只保留 host 与 path，查询串整体抹掉（可能含令牌）；
/// - 文件路径折叠成 `<path>`，不暴露用户目录结构；
/// - 长 token（SESSDATA、bookmark base64）折叠成前 4 位 + 省略号。
enum RedactingLog {
    private static let logger = Logger(subsystem: "com.yg.spatiallyrics", category: "app")

    static func info(_ message: String) { logger.info("\(sanitize(message), privacy: .public)") }
    static func error(_ message: String) { logger.error("\(sanitize(message), privacy: .public)") }

    /// 纯函数形式的脱敏，方便单测。
    static func sanitize(_ message: String) -> String {
        var result = message

        // ① URL：抹掉查询串，保留 host 与 path（排障时要靠它认出是哪个接口）。
        if let regex = try? NSRegularExpression(pattern: #"(https?://[^\s?]+)\?[^\s]+"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1?<redacted>")
        }

        // 记录 URL 区段：下面的"路径折叠"要跳过它们，
        // 否则 `//api.bilibili.com/x/y` 会被整段折成 `<path>`，连 host 都没了。
        var urlSpans: [Range<String.Index>] = []
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://\S+"#) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in urlRegex.matches(in: result, range: nsRange) {
                if let range = Range(match.range, in: result) { urlSpans.append(range) }
            }
        }

        // ② 本地路径：折叠成 `<path>`，不暴露用户目录结构。
        if let regex = try? NSRegularExpression(pattern: #"(?:/[^\s/:]+){2,}"#) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in regex.matches(in: result, range: nsRange).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                if urlSpans.contains(where: { $0.overlaps(range) }) { continue }
                result.replaceSubrange(range, with: "<path>")
            }
        }

        // ③ 长令牌折叠。**跳过文件名**（`SpatialLyrics-1794745597.store` 这种
        //    是排障关键信息，截断成 `Spat…` 反而查不出问题）。
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{24,}"#) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in regex.matches(in: result, range: nsRange).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let token = String(result[range])
                // `token.contains(".")` 是死代码：上面的字符集 `[A-Za-z0-9_\-]` 不含 `.`，
                // 这段永远判不出来。文件名兜底靠后面的 `Name-12345` 形态。
                let looksLikeFile = token.range(of: #"^[A-Za-z]+-\d+$"#, options: .regularExpression) != nil
                if looksLikeFile { continue }
                result.replaceSubrange(range, with: String(token.prefix(4)) + "…")
            }
        }

        return result
    }
}
