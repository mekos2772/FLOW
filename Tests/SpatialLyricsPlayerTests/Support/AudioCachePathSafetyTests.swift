import XCTest
@testable import SpatialLyricsPlayer

/// 音频缓存文件名里的 `bvid` 必须被约束。
///
/// `bvid` 直接来自接口响应，未经校验就拼进路径。
/// 一旦响应异常（或被中间人改写），`../../` 就能把文件写到缓存目录之外。
final class AudioCachePathSafetyTests: XCTestCase {

    func testNormalKeyIsUnchanged() {
        XCTAssertEqual(MediaAudioCache.safeKey("BV1xx411c7mD"), "BV1xx411c7mD")
    }

    func testSeparatorsAreNeutralized() {
        XCTAssertEqual(MediaAudioCache.safeKey("../../etc/passwd"), "______etc_passwd")
        XCTAssertFalse(MediaAudioCache.safeKey("../../evil").contains("/"))
    }

    func testColonsAndDotsAreNeutralized() {
        let name = MediaAudioCache.safeKey("BV1:xx..yy")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains(".."))
    }

    func testEmptyFallsBack() {
        XCTAssertEqual(MediaAudioCache.safeKey(""), "unknown")
    }

    /// 生成出来的路径必须仍在缓存目录里。
    @MainActor
    func testLocationStaysInsideDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MediaAudioCache(directory: dir)
        let stream = AudioStreamDescriptor(cacheKey: "../../escape",
                                           fileExtension: "m4a",
                                           qualityTier: .standard,
                                           qualityID: 30216,
                                           codec: "AAC",
                                           bandwidth: 64_000,
                                           sampleRate: 44_100,
                                           isLossless: false,
                                           url: URL(string: "https://example.invalid/a.m4a")!)
        let url = cache.location(for: stream)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL,
                       "文件名里带路径分隔符时，文件跑出了缓存目录")
    }
}
