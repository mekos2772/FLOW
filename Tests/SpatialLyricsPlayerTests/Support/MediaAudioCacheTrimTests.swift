import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证通用 `MediaAudioCache` 临时缓存目录的 LRU 容量淘汰与边界安全。
final class MediaAudioCacheTrimTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-mediacache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFakeFile(_ name: String, bytes: Int, usedAt date: Date) throws {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeCache() -> MediaAudioCache {
        MediaAudioCache(directory: directory)
    }

    func testNoTrimUnderLimit() async throws {
        try writeFakeFile("a.m4a", bytes: 1000, usedAt: Date())
        let removed = await makeCache().trimIfNeeded(maxBytes: 10_000)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.m4a").path))
    }

    func testTrimRemovesOldestFirstUntilUnderTarget() async throws {
        let now = Date()
        try writeFakeFile("old.m4a", bytes: 600, usedAt: now.addingTimeInterval(-3000))
        try writeFakeFile("middle.m4a", bytes: 600, usedAt: now.addingTimeInterval(-2000))
        try writeFakeFile("new.m4a", bytes: 600, usedAt: now.addingTimeInterval(-1000))

        let removed = await makeCache().trimIfNeeded(maxBytes: 1000, targetRatio: 0.8)
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("middle.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.m4a").path))
    }

    func testTrimIgnoresNonCacheFiles() async throws {
        try writeFakeFile("keep.txt", bytes: 5000, usedAt: Date())
        try writeFakeFile("a.m4a", bytes: 800, usedAt: Date())
        try writeFakeFile("b.m4a", bytes: 800, usedAt: Date())
        _ = await makeCache().trimIfNeeded(maxBytes: 900, targetRatio: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep.txt").path))
    }

    func testTrimIsIdempotent() async throws {
        try writeFakeFile("a.m4a", bytes: 800, usedAt: Date().addingTimeInterval(-100))
        let cache = makeCache()
        _ = await cache.trimIfNeeded(maxBytes: 100, targetRatio: 0.5)
        let second = await cache.trimIfNeeded(maxBytes: 100, targetRatio: 0.5)
        XCTAssertEqual(second, 0)
    }
}
