import XCTest
@testable import SpatialLyricsPlayer

/// 复合键的编码/解码。
///
/// 审阅发现同样的 `"::"` 逻辑在三个仓储里各写了一遍，
/// 而且都用 `components(separatedBy:).count == 2`——
/// `externalID` 只要含 `::`（本地路径、带协议前缀的 ID）就会解析失败，
/// 表现为"数据莫名其妙读不回来"，且不会有任何报错。
final class TrackIdentityStorageKeyTests: XCTestCase {

    func testRoundTripForOrdinaryIdentity() {
        let identity = TrackIdentity(sourceID: SourceID("bilibili"), externalID: "BV1xx411c7mD")
        let key = TrackIdentity.storageKey(identity)
        XCTAssertEqual(key, "bilibili::BV1xx411c7mD")
        XCTAssertEqual(TrackIdentity.fromStorageKey(key), identity)
    }

    /// 这条是旧实现的真 bug：含 `::` 的外部 ID 直接返回 nil。
    func testExternalIDContainingSeparatorStillRoundTrips() {
        let identity = TrackIdentity(sourceID: SourceID("local"),
                                     externalID: "file:///Users/me/a::b.mp3")
        let key = TrackIdentity.storageKey(identity)
        XCTAssertEqual(TrackIdentity.fromStorageKey(key), identity,
                       "externalID 里的 :: 不能被当成分隔符")
    }

    func testMalformedKeysAreRejected() {
        XCTAssertNil(TrackIdentity.fromStorageKey(""))
        XCTAssertNil(TrackIdentity.fromStorageKey("没有分隔符"))
        XCTAssertNil(TrackIdentity.fromStorageKey("::onlyExternal"))
        XCTAssertNil(TrackIdentity.fromStorageKey("onlySource::"))
    }

    /// 三个仓储都必须走同一份实现（而不是各自再写一遍）。
    @MainActor
    func testAllRepositoriesAgreeWithCanonicalImplementation() {
        let identity = TrackIdentity(sourceID: SourceID("local"), externalID: "a::b")
        let key = TrackIdentity.storageKey(identity)

        XCTAssertEqual(SwiftDataLibraryStore.identity(from: key), identity)
        XCTAssertEqual(SwiftDataLyricsOffsetStore.identity(from: key), identity)
        XCTAssertEqual(PlaybackSessionPersistence.identity(from: key), identity)
    }
}
