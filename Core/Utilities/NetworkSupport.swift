import Foundation

/// 全工程网络请求超时的唯一基准。
enum NetworkTimeouts {
    static let api: TimeInterval = 20
    static let artwork: TimeInterval = 20
    static let subtitle: TimeInterval = 15
    static let lyricsIndex: TimeInterval = 15
    static let thirdPartyLyrics: TimeInterval = 12
    static let audioDownload: TimeInterval = 30
}

/// 源无关的 HTTP / 远端请求失败错误。
struct RemoteHTTPFailure: Error, LocalizedError, Equatable, Sendable {
    let code: Int
    let message: String
    let url: String

    init(code: Int, message: String, url: String) {
        self.code = code
        self.message = message
        self.url = url
    }

    var errorDescription: String? {
        code == -1 ? message : "\(message)（\(code)）"
    }
}
