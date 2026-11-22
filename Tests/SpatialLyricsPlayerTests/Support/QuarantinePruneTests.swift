import XCTest
@testable import SpatialLyricsPlayer

/// 隔离文件的数量控制。
///
/// 真机演练（第 119 节）之后，应用支持目录里已经堆了 **9 个** `-corrupt-` 文件。
/// 每损坏一次就多一组（store + wal + shm），只增不减——和音频缓存同一个问题。
@MainActor
final class QuarantinePruneTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("SpatialLyrics.store") }

    private func makeQuarantine(_ stamp: Int) throws {
        for suffix in [".store", ".store-wal", ".store-shm"] {
            let url = directory.appendingPathComponent("SpatialLyrics-corrupt-\(stamp)\(suffix)")
            try Data("x".utf8).write(to: url)
        }
    }

    private func remainingStamps() throws -> [Int] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let stamps = names.compactMap { name -> Int? in
            guard let range = name.range(of: "-corrupt-") else { return nil }
            return Int(name[range.upperBound...].prefix(while: { $0.isNumber }))
        }
        return Array(Set(stamps)).sorted()
    }

    func testPruneKeepsOnlyNewestGroups() throws {
        for stamp in [100, 200, 300, 400, 500] {
            try makeQuarantine(stamp)
        }
        PersistenceController.pruneQuarantinedFiles(near: storeURL)

        XCTAssertEqual(try remainingStamps(), [300, 400, 500], "应当只留最新的 3 组")
        // 三个伴生文件要一起清掉，不能只剩孤零零的 -wal
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left.count, 9, "5 组清掉 2 组后应当剩 9 个文件，实际 \(left.count)")
    }

    /// 健康启动就该顺手清掉历史遗留，而不是等"下次再损坏"。
    func testOpeningStorePrunesOldQuarantines() throws {
        for stamp in [100, 200, 300, 400, 500] {
            try makeQuarantine(stamp)
        }
        _ = try PersistenceController(inMemory: false, storeURL: storeURL)
        XCTAssertEqual(try remainingStamps(), [300, 400, 500],
                       "健康启动后应当只留最新 3 组隔离文件")
    }

    func testPruneDoesNothingWhenUnderLimit() throws {
        try makeQuarantine(100)
        try makeQuarantine(200)
        PersistenceController.pruneQuarantinedFiles(near: storeURL)
        XCTAssertEqual(try remainingStamps(), [100, 200])
    }
}
