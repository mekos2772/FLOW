import XCTest
import SwiftData
@testable import SpatialLyricsPlayer

/// 歌词偏移的两个实现必须共享边界。
///
/// 非有限值（NaN / ±∞）一旦存进去，歌词时间轴的比较会全部失效
/// （`time > NaN` 永远为假），表现为"歌词卡住不动"——很难联想到偏移量。
/// 两个实现都要：写入时拒绝、读出时回落 0。
@MainActor
final class LyricsOffsetParityTests: XCTestCase {

    private let identity = TrackIdentity(sourceID: SourceID(rawValue: "bili"), externalID: "BV1off")

    private func stores() throws -> [(String, any LyricsOffsetStoring)] {
        let container = try PersistenceController(inMemory: true).container
        return [("swiftdata", SwiftDataLyricsOffsetStore(modelContainer: container)),
                ("memory", InMemoryLyricsOffsetStore())]
    }

    func testNonFiniteOffsetIsRejectedOnWrite() async throws {
        for (name, store) in try stores() {
            await store.save(.nan, for: identity)
            let value = await store.offset(for: identity)
            XCTAssertTrue(value.isFinite, "\(name) 存进了 NaN")
            XCTAssertEqual(value, 0, accuracy: 0.0001, "\(name) 读出来应当是 0")
        }
    }

    func testInfinityIsRejectedToo() async throws {
        for (name, store) in try stores() {
            await store.save(.infinity, for: identity)
            let value = await store.offset(for: identity)
            XCTAssertTrue(value.isFinite, "\(name) 存进了 ∞")
        }
    }

    /// 正常值必须原样保存（护栏不能把正常功能也拦掉）。
    func testNormalOffsetRoundTrips() async throws {
        for (name, store) in try stores() {
            await store.save(-0.35, for: identity)
            let value = await store.offset(for: identity)
            XCTAssertEqual(value, -0.35, accuracy: 0.0001, name)
        }
    }
}
