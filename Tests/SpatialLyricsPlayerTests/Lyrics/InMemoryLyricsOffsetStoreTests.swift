import XCTest
@testable import SpatialLyricsPlayer

/// 偏移记忆的内存实现。核心性质：每首歌互相独立、默认 0、删除后回到 0。
/// 规格 5.4 要求「避免仅使用歌名匹配」，所以这里用两个同名的不同 identity 验证隔离性。
final class InMemoryLyricsOffsetStoreTests: XCTestCase {

    private func identity(_ id: String, source: String = "local") -> TrackIdentity {
        TrackIdentity(sourceID: SourceID(rawValue: source), externalID: id)
    }

    func testDefaultOffsetIsZero() async {
        let store = InMemoryLyricsOffsetStore()
        let value = await store.offset(for: identity("a"))
        XCTAssertEqual(value, 0, "没有记录时应为 0，而不是某个编造的默认偏移")
    }

    func testSameTitleDifferentTrackDoesNotShareOffset() async {
        let store = InMemoryLyricsOffsetStore()
        await store.save(0.35, for: identity("track-1"))
        let other = await store.offset(for: identity("track-2"))
        XCTAssertEqual(other, 0, "不同曲目不能共用偏移，即使歌名相同")
        let saved = await store.offset(for: identity("track-1"))
        XCTAssertEqual(saved, 0.35, accuracy: 0.0001)
    }

    func testRemoveResetsToZero() async {
        let store = InMemoryLyricsOffsetStore()
        await store.save(-0.2, for: identity("a"))
        await store.remove(for: identity("a"))
        let value = await store.offset(for: identity("a"))
        XCTAssertEqual(value, 0)
    }

    func testAllReturnsEverythingSaved() async {
        let store = InMemoryLyricsOffsetStore()
        await store.save(0.1, for: identity("a"))
        await store.save(-0.3, for: identity("b"))
        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[identity("b")] ?? 0, -0.3, accuracy: 0.0001)
    }
}
