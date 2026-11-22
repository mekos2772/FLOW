import Foundation

/// App 与 Widget 共享容器的常量。
/// 这个文件是唯一同时进入两个 Target 的成员，只允许放常量与值类型。
enum AppGroup {
    static let identifier = "group.com.yg.spatiallyrics"
    static let snapshotFileName = "playback-snapshot.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// 深链 scheme 与"打开播放器"入口。**App 与小组件共用**。
/// 小组件是独立 target，不能引用 App 里的类型，所以常量放在 `Shared/`。
enum DeepLinkScheme {
    static let value = "spatiallyrics"
    /// 点小组件空白处打开播放器。
    static var openPlayer: URL? { URL(string: "\(value)://open") }
}
