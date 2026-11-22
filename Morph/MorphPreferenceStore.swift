import Foundation

/// 形态偏好的持久化。
///
/// 刻意**没有**用 SwiftData：这里存的是"窗口上次长什么样"，
/// 属于用户偏好而不是领域数据，放 UserDefaults 与其它外观设置同源；
/// 也避免为三个字段再做一次数据库 schema 迁移。
@MainActor
protocol MorphPreferenceStoring: AnyObject {
    func load() -> MorphPreferenceSnapshot
    func save(_ snapshot: MorphPreferenceSnapshot)
}

struct MorphPreferenceSnapshot: Codable, Equatable, Sendable {
    /// 每块屏上次的形态（显示器 UUID → 形态）。
    var morphologyByDisplay: [String: String] = [:]
    /// 每块屏上次贴的边。
    var edgeByDisplay: [String: String] = [:]
    var isMorphologyLocked: Bool = false
    var isClickThrough: Bool = false
    var floatingShape: String = LyricsShape.capsule.rawValue
    // 与 MorphWindowController 的默认值保持一致（.edgeHandle：缩到最小还留一块可点的，
    // 不是彻底消失）。两边默认值各写一份时首装行为会和控制器声明矛盾。
    var dormantStyle: String = DormantStyle.edgeHandle.rawValue
}

/// UserDefaults 实现。
@MainActor
final class UserDefaultsMorphPreferenceStore: MorphPreferenceStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = RuntimeSandbox.defaults, key: String = "flow.morphology.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> MorphPreferenceSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(MorphPreferenceSnapshot.self, from: data) else {
            return MorphPreferenceSnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: MorphPreferenceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 测试与预览用的内存实现。
@MainActor
final class InMemoryMorphPreferenceStore: MorphPreferenceStoring {
    private var snapshot: MorphPreferenceSnapshot

    init(seed: MorphPreferenceSnapshot = MorphPreferenceSnapshot()) {
        self.snapshot = seed
    }

    func load() -> MorphPreferenceSnapshot { snapshot }
    func save(_ snapshot: MorphPreferenceSnapshot) { self.snapshot = snapshot }
}
