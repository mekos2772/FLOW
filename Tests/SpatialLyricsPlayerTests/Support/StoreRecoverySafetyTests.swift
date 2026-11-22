import Foundation
import SwiftData
import XCTest
@testable import SpatialLyricsPlayer

/// 只存在于测试里的模型：用来造一份"别的版本写下的库"。
@Model
final class FutureVersionRecord {
    var note: String
    init(note: String) { self.note = note }
}

/// 打不开 ≠ 坏了。
///
/// 旧实现把**任何**打开失败都当成损坏：隔离、拿备份顶上、下次启动再来一遍。
/// 隔离文件只留三组——连续四次启动之后，最初那份真正的用户数据就被自动删掉了。
/// 而"打不开"最常见的原因恰恰不是损坏，而是模型版本对不上。
@MainActor
final class StoreRecoverySafetyTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL { directory.appendingPathComponent("SpatialLyrics.store") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 一份完好的库，但出自"另一个版本的模型"——当前这版的迁移计划不认识它。
    /// 这正是真实世界里"打不开"最常见的原因（降级安装、模型改了却没加迁移）。
    private func writeStoreFromAnotherModelVersion() throws {
        let schema = Schema([FutureVersionRecord.self])
        let configuration = ModelConfiguration("SpatialLyrics", schema: schema, url: storeURL, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.insert(FutureVersionRecord(note: "用户的数据"))
        try context.save()
    }

    /// 用写它的那套模型再读一遍：数据还在不在。
    private func survivingNotes() throws -> [String] {
        let schema = Schema([FutureVersionRecord.self])
        let configuration = ModelConfiguration("SpatialLyrics", schema: schema, url: storeURL, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try ModelContext(container).fetch(FetchDescriptor<FutureVersionRecord>()).map(\.note)
    }

    private var quarantined: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.contains("-corrupt-") }
    }

    func testIntactFileIsNotReportedAsDamaged() throws {
        try writeStoreFromAnotherModelVersion()
        XCTAssertFalse(PersistenceController.isStructurallyDamaged(at: storeURL))
        XCTAssertEqual(try survivingNotes(), ["用户的数据"], "体检不能改动库里的内容")
    }

    func testGarbageIsReportedAsDamaged() throws {
        try Data("this is not a database".utf8).write(to: storeURL)
        XCTAssertTrue(PersistenceController.isStructurallyDamaged(at: storeURL))
        XCTAssertFalse(PersistenceController.isStructurallyDamaged(
            at: directory.appendingPathComponent("missing.store")), "文件不存在不算损坏")
    }

    func testUnreadableButIntactStoreIsLeftExactlyWhereItIs() throws {
        try writeStoreFromAnotherModelVersion()

        XCTAssertThrowsError(try PersistenceController(inMemory: false, storeURL: storeURL),
                             "当前模型读不了这份库：应当如实报错，由上层进入降级模式")

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "完好的库不能被挪走")
        XCTAssertTrue(quarantined.isEmpty, "没有损坏就不该出现隔离文件：\(quarantined)")
        XCTAssertEqual(try survivingNotes(), ["用户的数据"], "数据必须原样留在原地")
    }

    /// 反复启动也一样：不能靠"多试几次"把原始数据挤出隔离名额
    /// （旧实现里第四次启动会把最初那份真正的数据自动删掉）。
    func testRepeatedLaunchesNeverPruneTheOriginalData() throws {
        try writeStoreFromAnotherModelVersion()
        for _ in 0..<6 { _ = try? PersistenceController(inMemory: false, storeURL: storeURL) }

        XCTAssertTrue(quarantined.isEmpty)
        XCTAssertEqual(try survivingNotes(), ["用户的数据"])
    }

    /// 内容没变就不占备份名额：否则三份备份全是同一刻的内容，没有任何时间纵深。
    func testIdenticalContentDoesNotConsumeABackupSlot() throws {
        try Data("store-v1".utf8).write(to: storeURL)
        PersistenceController.writeBackupIfChanged(of: storeURL, at: Date(timeIntervalSince1970: 1_700_000_000))
        PersistenceController.writeBackupIfChanged(of: storeURL, at: Date(timeIntervalSince1970: 1_700_000_100))
        PersistenceController.writeBackupIfChanged(of: storeURL, at: Date(timeIntervalSince1970: 1_700_000_200))
        XCTAssertEqual(PersistenceController.backups(for: storeURL).count, 1)

        try Data("store-v2".utf8).write(to: storeURL)
        PersistenceController.writeBackupIfChanged(of: storeURL, at: Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(PersistenceController.backups(for: storeURL).count, 2, "内容变了才写新的一份")
    }
}
