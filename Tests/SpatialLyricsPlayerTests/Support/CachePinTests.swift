import XCTest
@testable import SpatialLyricsPlayer

/// 清理时不能删掉正在播放的文件。
///
/// 淘汰顺序是"最久未使用"，而正在播的那首往往就是最旧的：
/// 用户听一张很久以前的专辑、同时后台下了一首新的，清理会先删它。
/// POSIX 下已打开的 fd 还能读，但播放器 seek 时会重新按路径打开，于是中途断掉。
@MainActor
final class CachePinTests: XCTestCase {

    private var dir: URL!
    private var cache: MediaAudioCache!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache = MediaAudioCache(directory: dir)
    }

    override func tearDownWithError() throws {
        MediaAudioCache.unpin(dir.appendingPathComponent("playing.m4a"))
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, bytes: Int, modified: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testPinnedFileSurvivesTrim() async throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let playing = try makeFile("playing.m4a", bytes: 400 * 1024, modified: old)
        _ = try makeFile("newer.m4a", bytes: 400 * 1024, modified: Date())

        MediaAudioCache.pin(playing)
        // 上限设成 500KB、目标 0.5 → 必须删掉一些才达标
        let removed = await cache.trimIfNeeded(maxBytes: 500 * 1024, targetRatio: 0.5)

        XCTAssertGreaterThan(removed, 0, "总容量超限，应当删掉文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playing.path),
                      "正在播放的文件不能被清理掉")
    }

    func testUnpinnedFileCanBeTrimmed() async throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let stale = try makeFile("stale.m4a", bytes: 400 * 1024, modified: old)
        _ = try makeFile("newer.m4a", bytes: 400 * 1024, modified: Date())

        _ = await cache.trimIfNeeded(maxBytes: 500 * 1024, targetRatio: 0.5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "没有钉住的最旧文件应当被清掉")
    }

    /// 两份文件同时被钉住时都要保住（单值实现会漏掉先钉的那份）。
    func testMultiplePinsAreAllProtected() async throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let first = try makeFile("first.m4a", bytes: 400 * 1024, modified: old)
        let second = try makeFile("second.m4a", bytes: 400 * 1024, modified: old.addingTimeInterval(1))
        _ = try makeFile("third.m4a", bytes: 400 * 1024, modified: Date())

        MediaAudioCache.pin(first)
        MediaAudioCache.pin(second)
        defer { MediaAudioCache.unpin(first); MediaAudioCache.unpin(second) }

        _ = await cache.trimIfNeeded(maxBytes: 500 * 1024, targetRatio: 0.5)

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
