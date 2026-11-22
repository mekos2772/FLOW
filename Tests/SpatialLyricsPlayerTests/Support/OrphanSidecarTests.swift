import XCTest
@testable import SpatialLyricsPlayer

/// 主库不存在时，残留的侧车文件必须被清掉。
///
/// SQLite 打开**新建**的空库时，如果旁边躺着旧的 `-wal`，会把里面的帧重放进去——
/// 等于让已经隔离掉的坏数据通过侧车回到新库。
/// 隔离时侧车用 `try?` 移动，失败就会留下这种孤儿。
@MainActor
final class OrphanSidecarTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSidecarsRemovedWhenStoreMissing() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        try Data("stale".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        PersistenceController.removeOrphanSidecars(for: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-shm"))
    }

    /// 主库**存在**时不该动侧车——那里面可能有尚未 checkpoint 的真实数据。
    func testSidecarsKeptWhenStoreExists() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        try Data("main".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        PersistenceController.removeOrphanSidecars(for: store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path + "-wal"),
                      "主库在的时候，WAL 里可能是没落盘的真实数据，不能删")
    }
}
