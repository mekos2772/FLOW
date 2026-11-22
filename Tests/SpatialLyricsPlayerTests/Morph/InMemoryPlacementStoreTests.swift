import XCTest
@testable import SpatialLyricsPlayer

/// 位置记忆的内存实现。语义必须和 SwiftData 版一致：
/// 未写入时返回 nil（而不是编造一个默认位置），clear 之后同样回到 nil。
final class InMemoryPlacementStoreTests: XCTestCase {

    private func sample(displayID: String = "TEST", x: Double = 100) -> PlacementSnapshot {
        PlacementSnapshot(
            displayID: displayID,
            originX: x, originY: 200, width: 380, height: 46,
            shape: .capsule, isLocked: false, isClickThrough: true,
            opacity: 0.95, showsBackground: false,
            preferredX: nil, preferredY: nil
        )
    }

    func testLoadReturnsNilBeforeAnySave() async {
        let store = InMemoryPlacementStore()
        let loaded = await store.load()
        XCTAssertNil(loaded, "没有任何记录时应返回 nil，调用方才知道要算默认位置")
    }

    func testSaveThenLoadRoundTrips() async {
        let store = InMemoryPlacementStore()
        let snapshot = sample()
        await store.save(snapshot)
        let loaded = await store.load()
        XCTAssertEqual(loaded, snapshot, "存进去什么就该读回什么")
    }

    func testSaveOverwritesPrevious() async {
        let store = InMemoryPlacementStore()
        await store.save(sample(x: 100))
        await store.save(sample(x: 500))
        let loaded = await store.load()
        XCTAssertEqual(loaded?.originX, 500, "后一次保存应覆盖前一次")
    }

    func testClearReturnsToEmptyState() async {
        let store = InMemoryPlacementStore()
        await store.save(sample())
        await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }
}
