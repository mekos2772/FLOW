import Foundation

/// 位置快照的内存实现。
///
/// 存在的理由：`PlacementStoring` 原本只有 SwiftData 实现，
/// 想在测试或预览里构造 `FloatingPanelController` 就得先拉起整个数据库。
/// 这个实现让「位置记忆」这条链路可以被独立验证，也让预览不必碰磁盘。
actor InMemoryPlacementStore: PlacementStoring {
    private var snapshot: PlacementSnapshot?

    init(seed: PlacementSnapshot? = nil) {
        self.snapshot = seed
    }

    func load() async -> PlacementSnapshot? { snapshot?.sanitized() }

    func save(_ snapshot: PlacementSnapshot) async { self.snapshot = snapshot }

    func clear() async { snapshot = nil }
}
