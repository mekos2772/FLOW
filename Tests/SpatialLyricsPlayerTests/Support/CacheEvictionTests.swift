import XCTest
@testable import SpatialLyricsPlayer

/// 坏缓存必须能被淘汰。
///
/// 缓存命中只看"文件大于 64KB"。如果文件本身解不出来（下载被截断、磁盘写坏），
/// 这首就会**永远**播不出来——每次命中同一个坏文件，用户无从修复。
/// 解码失败时淘汰它，下次重新下载，属于自愈。
@MainActor
final class CacheEvictionTests: XCTestCase {

    private var dir: URL!
    private var cache: MediaAudioCache!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-evict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache = MediaAudioCache(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func stream(cacheKey: String) -> AudioStreamDescriptor {
        AudioStreamDescriptor(cacheKey: cacheKey,
                              fileExtension: "m4a",
                              qualityTier: .standard,
                              qualityID: 30216,
                              codec: "AAC",
                              bandwidth: 64_000,
                              sampleRate: 44_100,
                              isLossless: false,
                              url: URL(string: "https://example.invalid/a.m4a")!)
    }

    func testEvictsFileInsideCacheDirectory() throws {
        let file = cache.location(for: stream(cacheKey: "track-1"))
        try Data(repeating: 0, count: 100 * 1024).write(to: file)

        cache.evictIfCached(cacheKey: "track-1", url: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// **关键**：缓存目录之外的文件绝不能被删——本地导入的音频走的是同一段代码。
    func testDoesNotDeleteFilesOutsideCache() throws {
        let outside = dir.deletingLastPathComponent()
            .appendingPathComponent("user-music-\(UUID().uuidString).m4a")
        try Data("important".utf8).write(to: outside)

        cache.evictIfCached(cacheKey: "track-2", url: outside)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "缓存淘汰不能碰到缓存目录之外的文件")
        try? FileManager.default.removeItem(at: outside)
    }
}
