import Foundation

/// 小组件读取的播放快照。
///
/// 刻意做成极小的值类型：字段越少，App 与 Widget 的耦合面越小，
/// 也天然满足"小组件不做高频刷新"——快照只由主 App 在状态变化时写入。
struct PlaybackSnapshot: Codable, Sendable, Equatable {
    enum Availability: String, Codable, Sendable {
        case playing
        case paused
        case idle
        case privacyHidden
    }

    var availability: Availability
    var title: String?
    var artist: String?
    // `album` 已删除：小组件从未显示它，App 侧也没有别的读取方——
    // 留着只会让共享 JSON 里多一个永远没人看的字段。
    var duration: TimeInterval
    var position: TimeInterval
    /// 当前歌词一行（系统允许频率下的快照，不承诺实时）。
    var lyricLine: String?
    /// 接下来播放的曲目标题（最多三首）。
    var upNext: [String]
    var updatedAt: Date

    static let empty = PlaybackSnapshot(
        availability: .idle,
        title: nil,
        artist: nil,
        duration: 0,
        position: 0,
        lyricLine: nil,
        upNext: [],
        updatedAt: .distantPast
    )

    var isPlaying: Bool { availability == .playing }

    /// 隐私开关打开时抹掉一切可识别内容，只保留"正在播放"这一事实。
    func redacting() -> PlaybackSnapshot {
        var copy = self
        copy.availability = .privacyHidden
        copy.title = nil
        copy.artist = nil
        copy.lyricLine = nil
        copy.upNext = []
        return copy
    }

    /// 进程即将退出时的快照。
    ///
    /// 小组件用的是 `.never` 时间线策略（只由主 App 触发刷新），
    /// 所以 App 退出**必须**发布一次"已停止"，否则小组件会一直显示"正在播放"。
    /// 隐私态保持隐私态（不能因为退出就泄露内容）。
    func stopped() -> PlaybackSnapshot {
        var copy = self
        if copy.availability != .privacyHidden {
            copy.availability = copy.title == nil ? .idle : .paused
        }
        return copy
    }

    /// 陈旧修正：快照声称在播放，但更新时间太久远 → 视为已暂停。
    ///
    /// 为什么需要：小组件时间线是 `.never`，只在主 App 主动刷新时才更新。
    /// 正常退出我们会发一次"已停止"（第 131 节），但**崩溃**走不到那个钩子——
    /// 于是桌面小组件会一直显示"正在播放 + 冻结的进度"，可能持续好几天。
    ///
    /// - Parameter maxAge: 超过这个时长就认为快照不再可信。
    func freshnessAdjusted(now: Date = Date(), maxAge: TimeInterval = 5 * 60) -> PlaybackSnapshot {
        guard availability == .playing else { return self }
        guard updatedAt != .distantPast else { return self }   // 占位快照没有时间戳
        guard now.timeIntervalSince(updatedAt) > maxAge else { return self }
        var copy = self
        copy.availability = .paused
        return copy
    }

    /// 展示用标题。隐私态返回统一文案，空态返回置灰提示。
    var displayTitle: String {
        switch availability {
        case .privacyHidden: return "正在播放"
        case .idle: return "未在播放"
        default: return title ?? "未在播放"
        }
    }

    var displayArtist: String? {
        availability == .privacyHidden ? nil : artist
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// 小组件按钮下发的一次性命令。
///
/// 小组件进程不能直接操作播放器，所以只把"意图"写进共享存储；
/// 主 App 启动/激活时读取并交给真正的播放协调器执行。
enum PlaybackCommand: String, Codable, Sendable, CaseIterable {
    case play
    case pause
    case toggle
    case next
    case previous
}

/// App 与 Widget 之间的共享存储。
///
/// 优先用 App Group；未签名调试环境下 group container 可能拿不到，
/// 此时退回标准 UserDefaults（小组件读不到，但主 App 行为正常），并如实记录在 README。
enum SharedStateStore {
    private static let snapshotKey = "widget.snapshot"
    private static let commandsKey = "widget.commands"

    static var isSharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) != nil
    }

    private static var defaults: UserDefaults {
        // 隔离运行（App 侧见 `RuntimeSandbox`，同一个环境变量）：不碰真实的小组件共享域，
        // 否则验收时会把桌面小组件的内容换成测试曲目、还会吞掉排队中的小组件指令。
        // `Shared/` 进两个 target、不能引用 App 内类型，所以这里自己读一次变量。
        // 单元测试宿主同理（它和正式 App 是同一个 bundle id）。
        let environment = ProcessInfo.processInfo.environment
        let isIsolated = !(environment["SLP_DATA_DIR"] ?? "").isEmpty
            || environment["XCTestConfigurationFilePath"] != nil
        if isIsolated {
            return UserDefaults(suiteName: "com.yg.spatiallyrics.sandbox.widget") ?? .standard
        }
        return UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    static func write(_ snapshot: PlaybackSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func read() -> PlaybackSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func post(_ command: PlaybackCommand) {
        var queue = defaults.stringArray(forKey: commandsKey) ?? []
        queue.append(command.rawValue)
        defaults.set(queue, forKey: commandsKey)
    }

    static func drainCommands() -> [PlaybackCommand] {
        let raw = defaults.stringArray(forKey: commandsKey) ?? []
        defaults.removeObject(forKey: commandsKey)
        return raw.compactMap(PlaybackCommand.init(rawValue:))
    }
}
