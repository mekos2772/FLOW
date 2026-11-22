import XCTest
@testable import SpatialLyricsPlayer

/// 封面磁盘缓存的上限。
///
/// 内存侧本来就有 `countLimit = 32`，磁盘侧**没有任何上限**：
/// 搜过的每首歌封面都会永久留在 Application Support 里。
/// 单张不大，但"只增不减"不是上线该有的样子——这是最后手段的兜底。
@MainActor
final class ArtworkDiskCapTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 用假数据写一批 .img，确认最旧的会被删掉。
    func testOldestArtworkIsEvictedWhenOverCap() throws {
        let store = ArtworkStore(directory: dir)
        // 写入 6 张（内容不同 → 哈希不同）
        var names: [String] = []
        for i in 0..<6 {
            let data = Data(repeating: UInt8(i), count: 200 * 1024)
            let name = try XCTUnwrap(store.store(data))
            names.append(name)
        }
        // 造出 mtime 先后（第 0 张最旧）
        for (i, name) in names.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(i) - 100)],
                ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }
        // 直接调用内部淘汰（把上限压到 400KB 以便触发）
        store.performTrimForTesting(maxBytes: 400 * 1024)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".img") }
        XCTAssertLessThan(remaining.count, 6, "超出上限时应当淘汰掉一些封面")
        XCTAssertGreaterThan(remaining.count, 0, "不能把封面全删光")
    }
}
