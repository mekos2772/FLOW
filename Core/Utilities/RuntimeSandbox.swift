import Foundation

/// 验收/截图用的**隔离运行**开关。
///
/// 设了 `SLP_DATA_DIR=/某个目录` 之后，这次运行的全部可写状态都落在那个目录里：
/// 曲目库、设置、封面与音频缓存；登录凭证只放内存（等同于游客，不读也不写系统钥匙串）。
///
/// 为什么需要：真机验收要把应用跑起来点一遍，而默认路径下它读写的是**使用者自己的**
/// 曲目库、偏好设置和登录状态。测试宿主早就改成内存库了，但"手动跑一遍看看"
/// 这条路一直是裸奔的——验收一次就可能把收藏、队列、音量设置改掉。
///
/// 只读环境变量，不写进任何偏好；正式使用时没有这个变量，行为完全不变。
enum RuntimeSandbox {
    /// 是不是单元测试的宿主进程。
    ///
    /// 测试是**寄宿在 App 里**跑的：同一个 bundle id、同一份偏好设置域、同一批缓存目录。
    /// 之前只有数据库做了隔离（测试宿主用内存库），其余全是裸奔——
    /// 跑一遍测试会 `BiliLyricsCache.shared.clear()` 清空使用者真实的歌词缓存、
    /// 往真实的偏好设置里写测试值、还可能去下 1.7MB 的歌词索引。
    static let isTestHost: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// 隔离目录。nil 表示正常运行。
    static let dataDirectory: URL? = {
        let url: URL
        if let raw = ProcessInfo.processInfo.environment["SLP_DATA_DIR"],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else if isTestHost {
            // 测试宿主：固定落在临时目录，并且**每次进程启动先清空**——
            // 上一轮测试留下的缓存与设置不能影响这一轮。
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("flow-test-host", isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        } else {
            return nil
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isActive: Bool { dataDirectory != nil }

    /// 隔离运行时用的偏好设置 suite 名（带目录摘要：不同隔离目录互不串）。
    private static let suiteName: String? = {
        guard let directory = dataDirectory else { return nil }
        if isTestHost, ProcessInfo.processInfo.environment["SLP_DATA_DIR"] == nil {
            // 固定名字 + 启动即清空：不会在 ~/Library/Preferences 里越攒越多。
            let name = "com.yg.spatiallyrics.test-host"
            UserDefaults.standard.removePersistentDomain(forName: name)
            return name
        }
        // 用稳定摘要而不是 `hashValue`：后者每次进程启动都会变，
        // 同一个隔离目录重启之后就读不回自己上次写的设置了。
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a
        for byte in directory.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "com.yg.spatiallyrics.sandbox." + String(hash, radix: 16)
    }()

    /// 这次运行用的偏好设置域。隔离时是独立 suite，否则是标准域。
    ///
    /// 计算属性而不是 `static let`：`UserDefaults` 不是 `Sendable`，不能放进全局常量；
    /// 同名 suite 的多个实例本来就共享同一份底层存储，每次新建没有额外代价。
    static var defaults: UserDefaults {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 缓存根目录（封面、音频、歌词、索引）。隔离时在隔离目录下。
    static func cachesDirectory() -> URL {
        if let directory = dataDirectory {
            let caches = directory.appendingPathComponent("Caches", isDirectory: true)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            return caches
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// 应用支持目录（HiFi 账本等小文件）。隔离时在隔离目录下。
    static func applicationSupportDirectory() -> URL? {
        if let directory = dataDirectory { return directory }
        return try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
    }
}
