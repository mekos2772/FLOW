import XCTest
@testable import SpatialLyricsPlayer

/// 歌单：增删改、去重、身份键往返。
///
/// 两种实现（内存 / SwiftData）跑同一套断言——保证持久化实现与内存实现语义一致，
/// 否则测试通过但真机行为不同，是最难查的那类 bug。
@MainActor
final class PlaylistStoreTests: XCTestCase {

    private static let remoteSourceID = SourceID(rawValue: "remote")

    private func makeStores() throws -> [(name: String, store: any PlaylistStoring)] {
        let persistence = try PersistenceController(inMemory: true)
        return [
            ("inMemory", InMemoryPlaylistStore()),
            ("swiftData", SwiftDataPlaylistStore(modelContainer: persistence.container)),
        ]
    }

    func testEntryKeyRoundTrip() {
        let entry = PlaylistEntry(sourceID: Self.remoteSourceID, externalID: "track-001")
        XCTAssertEqual(entry.key, "remote|track-001")
        XCTAssertEqual(PlaylistEntry(key: entry.key), entry)
        XCTAssertNil(PlaylistEntry(key: "没有分隔符"))
    }

    func testEntryKeyHandlesPipeInPath() {
        // 本地文件路径里可能有 '|'：只按第一个分隔符切，剩下全归 externalID
        let entry = PlaylistEntry(key: "localFile|/Users/a|b/song.mp3")
        XCTAssertEqual(entry?.externalID, "/Users/a|b/song.mp3")
    }

    func testCreateRenameDelete() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "夜跑")
            XCTAssertEqual(playlist.name, "夜跑")
            XCTAssertEqual(store.playlists().count, 1, name)

            store.rename(id: playlist.id, to: "通勤")
            XCTAssertEqual(store.playlists().first?.name, "通勤", name)

            store.delete(id: playlist.id)
            XCTAssertTrue(store.playlists().isEmpty, name)
        }
    }

    func testBlankNameFallsBack() throws {
        for (_, store) in try makeStores() {
            let playlist = store.create(name: "   ")
            XCTAssertEqual(playlist.name, "未命名歌单")
        }
    }

    func testAddDeduplicatesAndPreservesOrder() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "顺序")
            let first = PlaylistEntry(sourceID: Self.remoteSourceID, externalID: "id-1")
            let second = PlaylistEntry(sourceID: Self.remoteSourceID, externalID: "id-2")

            XCTAssertTrue(store.add(first, to: playlist.id), name)
            XCTAssertTrue(store.add(second, to: playlist.id), name)
            XCTAssertFalse(store.add(first, to: playlist.id), name + "：重复添加必须返回 false")

            XCTAssertEqual(store.entries(in: playlist.id), [first, second], name + "：顺序必须保持")
        }
    }

    func testRemoveEntry() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "删条目")
            let entry = PlaylistEntry(sourceID: Self.remoteSourceID, externalID: "id-9")
            store.add(entry, to: playlist.id)
            store.remove(entry, from: playlist.id)
            XCTAssertTrue(store.entries(in: playlist.id).isEmpty, name)
        }
    }

    func testMissingPlaylistIsNoOp() throws {
        for (name, store) in try makeStores() {
            let ghost = UUID()
            XCTAssertFalse(store.add(PlaylistEntry(sourceID: Self.remoteSourceID, externalID: "ghost"),
                                     to: ghost), name)
            XCTAssertTrue(store.entries(in: ghost).isEmpty, name)
            store.rename(id: ghost, to: "x")   // 不应崩溃
            store.delete(id: ghost)
        }
    }
}

/// 歌单拖动排序。
@MainActor
final class PlaylistReorderTests: XCTestCase {

    private static let remoteSourceID = SourceID(rawValue: "remote")

    private func makeStores() throws -> [(name: String, store: any PlaylistStoring)] {
        let persistence = try PersistenceController(inMemory: true)
        return [
            ("inMemory", InMemoryPlaylistStore()),
            ("swiftData", SwiftDataPlaylistStore(modelContainer: persistence.container)),
        ]
    }

    private func entries(_ count: Int) -> [PlaylistEntry] {
        (0..<count).map { PlaylistEntry(sourceID: SourceID(rawValue: "remote"), externalID: "BV\($0)") }
    }

    func testMoveForward() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "排序")
            for entry in entries(3) { store.add(entry, to: playlist.id) }
            store.move(in: playlist.id, from: 0, to: 2)
            XCTAssertEqual(store.entries(in: playlist.id).map(\.externalID), ["BV1", "BV2", "BV0"], name)
        }
    }

    func testMoveBackward() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "排序2")
            for entry in entries(3) { store.add(entry, to: playlist.id) }
            store.move(in: playlist.id, from: 2, to: 0)
            XCTAssertEqual(store.entries(in: playlist.id).map(\.externalID), ["BV2", "BV0", "BV1"], name)
        }
    }

    func testMoveClampsOutOfRangeTarget() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "越界")
            for entry in entries(2) { store.add(entry, to: playlist.id) }
            store.move(in: playlist.id, from: 0, to: 99)
            XCTAssertEqual(store.entries(in: playlist.id).map(\.externalID), ["BV1", "BV0"],
                           "\(name)：目标越界应夹到末尾")
        }
    }

    func testMoveIgnoresInvalidSource() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "无效源")
            for entry in entries(2) { store.add(entry, to: playlist.id) }
            store.move(in: playlist.id, from: 9, to: 0)
            XCTAssertEqual(store.entries(in: playlist.id).map(\.externalID), ["BV0", "BV1"], name)
        }
    }

    func testMoveKeepsMembership() throws {
        for (name, store) in try makeStores() {
            let playlist = store.create(name: "成员不变")
            for entry in entries(4) { store.add(entry, to: playlist.id) }
            store.move(in: playlist.id, from: 1, to: 3)
            XCTAssertEqual(Set(store.entries(in: playlist.id)), Set(entries(4)),
                           "\(name)：排序不能增加或丢失条目")
        }
    }
}
