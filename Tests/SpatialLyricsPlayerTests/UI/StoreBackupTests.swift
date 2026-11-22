import Foundation
import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

/// 滚动备份与自动恢复。
///
/// 起因：这个工程真的发生过**两次**收藏被清空（数据库损坏 → 建空库）。
/// 之前的处理只是"隔离损坏文件"，用户数据等于没了。这里补上备份与恢复。
@MainActor
final class StoreBackupTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("SpatialLyrics.store") }

    private func openStore() throws -> PersistenceController {
        try PersistenceController(inMemory: false, storeURL: storeURL)
    }

    func testBackupAfterSave() async throws {
        let controller = try openStore()
        // 打开瞬间 SQLite 文件可能还没创建，所以要等真正写一次数据之后才有备份。
        try await controller.makeTrackRepository().save(
            Track(sourceID: "local", externalID: "/tmp/a.mp3", title: "曲目",
                  artist: "某人", album: nil, duration: 200))
        // SwiftData 默认延迟落盘，必须显式保存后文件才存在。
        try controller.container.mainContext.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path),
                      "保存后库文件应当落在注入的临时路径上（不能是使用者的真实数据库）")
        PersistenceController.writeBackup(of: storeURL)

        // 注意：打开健康的库时**也会**写一份快照（`PersistenceController.init`），
        // 所以这里至少 1 份，具体份数取决于两次写入是否落在同一秒
        // （文件名精确到秒，同秒会去重）。断言"恰好 1 份"会随机失败。
        let backups = PersistenceController.backups(for: storeURL)
        XCTAssertGreaterThanOrEqual(backups.count, 1, "写盘之后至少应有一份快照")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups[0].path))
    }

    func testBackupsArePrunedToLimit() throws {
        for offset in 0..<6 {
            PersistenceController.writeBackup(of: storeURL, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
        }
        XCTAssertLessThanOrEqual(PersistenceController.backups(for: storeURL).count,
                                 PersistenceController.backupLimit,
                                 "备份不能无限增长")
    }

    func testLatestBackupIsNewestByTimestamp() throws {
        _ = try openStore()
        PersistenceController.writeBackup(of: storeURL, at: Date(timeIntervalSince1970: 1_800_000_000))
        let latest = try XCTUnwrap(PersistenceController.latestBackup(for: storeURL))
        XCTAssertTrue(latest.lastPathComponent.contains("1800000000"),
                      "最新备份应当按文件名时间戳判断，而不是目录顺序")
    }

    func testRestoreCopiesBackupBackIntoPlace() throws {
        _ = try openStore()
        let backup = try XCTUnwrap(PersistenceController.latestBackup(for: storeURL))
        // 模拟"库被隔离走了"的状态。
        try FileManager.default.removeItem(at: storeURL)
        XCTAssertTrue(PersistenceController.restore(backup: backup, to: storeURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    /// 端到端：写坏库 → 重新打开 → 隔离 + 从备份恢复，且**数据还在**。
    func testCorruptedStoreRestoresFromBackup() async throws {
        let first = try openStore()
        let repository = first.makeTrackRepository()
        let track = Track(sourceID: "local", externalID: "/tmp/a.mp3", title: "收藏曲目",
                          artist: "某人", album: nil, duration: 200)
        try await repository.save(track)

        // 让第一份数据落盘并留下健康快照。
        try? first.container.mainContext.save()
        // `init` 打开时已经写过一份（当时库还是空的），同一秒同名会被跳过；
        // 这里给一个更晚的时间戳，模拟"第二次启动时保存后再备份"。
        PersistenceController.writeBackup(of: storeURL, at: Date().addingTimeInterval(5))
        XCTAssertFalse(PersistenceController.backups(for: storeURL).isEmpty)

        // 诊断：备份文件本身必须能读出这条数据（否则恢复也没用）。
        let backup = try XCTUnwrap(PersistenceController.latestBackup(for: storeURL))
        let backupController = try PersistenceController(inMemory: false, storeURL: backup)
        let backedUp = try await backupController.makeTrackRepository().all()
        XCTAssertTrue(backedUp.contains { $0.title == "收藏曲目" },
                      "备份文件里就该有这条数据；没有说明写备份的时机或内容不对")

        // 写坏文件头（模拟真实损坏）。
        try Data("not a sqlite file at all".utf8).write(to: storeURL)

        let second = try openStore()
        XCTAssertTrue(second.recoveredFromCorruption, "应当识别为损坏并重建")
        XCTAssertTrue(second.restoredFromBackup, "必须从备份恢复，而不是直接建空库")
        XCTAssertNotNil(second.quarantinedFileName, "损坏文件要保留，方便人工抢救")

        let restored = try await second.makeTrackRepository().all()
        XCTAssertTrue(restored.contains { $0.title == "收藏曲目" },
                      "从备份恢复后，用户收藏必须还在——这正是重建空库会丢掉的东西")
    }
}
