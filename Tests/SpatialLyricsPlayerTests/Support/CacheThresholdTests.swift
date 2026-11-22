import XCTest
@testable import SpatialLyricsPlayer

/// 缓存"命中"与"写入"必须用同一个下限。
///
/// 曾经命中判 >64KB、写入只要求 >8KB：落在中间的文件写得进去却永远不算缓存，
/// 每次播放都重新下载——用户感知是"这首歌总是很慢"，很难联想到缓存判断。
final class CacheThresholdTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                   encoding: .utf8)
    }

    func testThresholdIsReferencedNotDuplicated() throws {
        let text = try source("Sources/Audio/MediaAudioCache.swift")
        let definitions = text.components(separatedBy: "minimumUsefulBytes = ").count - 1
        XCTAssertEqual(definitions, 1, "阈值只能定义一次")

        let references = text.components(separatedBy: "Self.minimumUsefulBytes").count - 1
        XCTAssertGreaterThanOrEqual(references, 2, "命中与写入两处都要引用同一个常量")
    }
}
