import Foundation

/// 源标识。用类型包装 `String`，避免"源"与"源内曲目"两个概念在字段层混淆。
struct SourceID: RawRepresentable, Hashable, Codable, Sendable,
                ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    var description: String { rawValue }

    /// 开发验证用的模拟源。
    static let mock = SourceID("mock")
    /// 真实播放链路：用户授权的本地音频文件。
    static let localFile = SourceID("local-file")
}
