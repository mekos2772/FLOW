import XCTest
@testable import SpatialLyricsPlayer

/// 备份不许留半成品。
///
/// `writeBackup` 是"先拷到 `.partial`，再改名"的两步操作。
/// 如果主库已经改名成正式名、侧车改名却失败，目录里就会留下一份
/// **看着完整、其实少了 WAL** 的备份；`latestBackup` 会选中它，
/// 恢复时静默丢掉最近写入的数据。
@MainActor
final class BackupAtomicityTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testBackupIncludesSidecars() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        try Data("main".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        PersistenceController.writeBackup(of: store, at: Date(timeIntervalSince1970: 1_700_000_000))

        let backups = PersistenceController.backups(for: store)
        let backup = try XCTUnwrap(backups.first, "应当写出 1 份备份")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path + "-wal"),
                      "侧车必须跟着备份走，否则恢复时会缺数据")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: backup.path + "-wal"), encoding: .utf8),
                       "wal")
    }

    /// 目录里不该残留 `.partial`。
    func testNoPartialLeftovers() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        try Data("main".utf8).write(to: store)
        PersistenceController.writeBackup(of: store, at: Date(timeIntervalSince1970: 1_700_000_001))

        let names = try FileManager.default.contentsOfDirectory(
            atPath: PersistenceController.backupDirectory(for: store).path)
        XCTAssertFalse(names.contains { $0.contains(".partial") },
                       "残留临时文件：\(names)")
    }

    /// 同一时间戳不会重复写（幂等）。
    func testSameTimestampIsIdempotent() throws {
        let store = dir.appendingPathComponent("SpatialLyrics.store")
        try Data("main".utf8).write(to: store)
        let date = Date(timeIntervalSince1970: 1_700_000_002)
        PersistenceController.writeBackup(of: store, at: date)
        PersistenceController.writeBackup(of: store, at: date)
        XCTAssertEqual(PersistenceController.backups(for: store).count, 1)
    }
}
