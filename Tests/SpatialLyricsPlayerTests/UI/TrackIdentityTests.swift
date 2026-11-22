import XCTest
@testable import SpatialLyricsPlayer

/// T12：文件路径不是身份。两条 Track 可以指向同一个文件，只要源内标识不同就是两首歌。
final class TrackIdentityTests: XCTestCase {

    func testSameFileDifferentExternalIDAreDifferentTracks() {
        let sharedPath = URL(fileURLWithPath: "/tmp/theme.flac")
        let a = Track(sourceID: .mock, externalID: "a", title: "A", artist: "X", duration: 100,
                      lyrics: LyricsReference(.file(sharedPath)))
        let b = Track(sourceID: .mock, externalID: "b", title: "B", artist: "X", duration: 100,
                      lyrics: LyricsReference(.file(sharedPath)))

        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(Set([a, b]).count, 2)
    }

    func testSameIdentityDifferentLocalIDsAreEqual() {
        let a = Track(id: UUID(), sourceID: .mock, externalID: "same", title: "A", artist: "X", duration: 100)
        let b = Track(id: UUID(), sourceID: .mock, externalID: "same", title: "A", artist: "X", duration: 100)

        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(a.identity, b.identity)
    }

    func testSameExternalIDDifferentSourcesAreDifferentTracks() {
        let a = Track(sourceID: SourceID("one"), externalID: "42", title: "T", artist: "X", duration: 10)
        let b = Track(sourceID: SourceID("two"), externalID: "42", title: "T", artist: "X", duration: 10)
        XCTAssertNotEqual(a, b)
    }
}
