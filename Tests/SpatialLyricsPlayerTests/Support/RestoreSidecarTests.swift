import XCTest
@testable import SpatialLyricsPlayer

/// 恢复备份时，目标位置的**残留侧车文件**必须先清掉。
///
/// 场景：上次隔离中途被打断——主库被移走，`-wal` 留在原地；
/// 而这份备份本身没有侧车（当时是 checkpoint 过的干净状态）。
/// 若不清，SQLite 打开恢复后的主库会把旧 WAL 重放上去，数据错乱。
@MainActor
final class RestoreSidecarTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStaleSidecarsAreRemovedBeforeRestore() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        let backup = dir.appendingPathComponent("SpatialLyrics-1.store")

        try Data("backup".utf8).write(to: backup)
        // 目标位置不存在主库，但有残留侧车
        try Data("stale-wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("stale-shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        XCTAssertTrue(PersistenceController.restore(backup: backup, to: store),
                      "目标位置没有主库，应当允许恢复")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-wal"),
                       "旧 WAL 必须被清掉，否则会被重放到恢复后的主库上")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-shm"))
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "backup")
    }

    /// 备份自带侧车时，要一起恢复过去。
    func testBackupSidecarsAreCopied() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        let backup = dir.appendingPathComponent("SpatialLyrics-2.store")
        try Data("main".utf8).write(to: backup)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: backup.path + "-wal"))

        XCTAssertTrue(PersistenceController.restore(backup: backup, to: store))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: store.path + "-wal"), encoding: .utf8),
                       "wal")
    }
}
