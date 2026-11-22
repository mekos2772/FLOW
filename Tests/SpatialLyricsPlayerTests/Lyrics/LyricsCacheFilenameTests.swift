import XCTest
@testable import SpatialLyricsPlayer

/// 歌词缓存文件名的安全性与长度。
///
/// 标题来自远端：既要防"当成路径"，也要防"太长写不进去"。
/// 后者是静默的——`store` 用 `try?`，写失败就等于永远缓存不上。
final class LyricsCacheFilenameTests: XCTestCase {

    func testPathSeparatorsAreRemoved() {
        let name = LyricDocumentCache.safeComponent("../../etc/passwd")
        XCTAssertFalse(name.contains("/"), "标题不能被当成路径：\(name)")
        XCTAssertFalse(name.contains(".." + "/"))
    }

    func testColonsAndHashesAreNeutralized() {
        let name = LyricDocumentCache.safeComponent("a:b#c")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("#"))
    }

    func testControlCharactersAreStripped() {
        let name = LyricDocumentCache.safeComponent("标题\u{0}带换行\n结尾")
        XCTAssertFalse(name.contains("\u{0}"))
        XCTAssertFalse(name.contains("\n"))
    }

    /// 85 个中文字 = 255 字节，正好触到 APFS 上限。
    func testLongChineseTitleStaysUnderByteLimit() {
        let title = String(repeating: "夜", count: 120)
        let name = LyricDocumentCache.safeComponent(title)
        XCTAssertLessThanOrEqual(name.utf8.count, 80, "文件名必须受字节数限制")
        XCTAssertFalse(name.isEmpty)
    }

    /// 截断后不能撞名。
    func testTruncatedTitlesDiffer() {
        let a = LyricDocumentCache.safeComponent(String(repeating: "夜", count: 100) + "A")
        let b = LyricDocumentCache.safeComponent(String(repeating: "夜", count: 100) + "B")
        XCTAssertNotEqual(a, b, "截断后要靠摘要区分，否则两首歌会共用一个缓存文件")
    }

    /// 真的能写进去再读出来（这是那条静默失效的直接验证）。
    func testLongTitleRoundTripsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LyricDocumentCache(directory: dir)

        let title = String(repeating: "很长的中文歌名", count: 20)
        cache.store(identity: "bili::BV1xx", title: title, lrc: "[00:00.00]一句歌词")
        XCTAssertEqual(cache.load(identity: "bili::BV1xx", title: title), "[00:00.00]一句歌词",
                       "超长标题也必须能正常缓存")
    }
}
