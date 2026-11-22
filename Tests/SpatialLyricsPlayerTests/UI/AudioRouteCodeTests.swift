import XCTest
@testable import SpatialLyricsPlayer

/// 四字码与耳机孔判定用的常量。
///
/// 这段之前完全没测过（`AudioRouteMonitor` 0/83 行）。字节序写反的话，
/// `source == fourCharCode("hdpn")` 永远不成立，表现为"拔耳机不暂停"，
/// 而 UI 上看不出任何异常。
@MainActor
final class AudioRouteCodeTests: XCTestCase {

    func testFourCharCodePacksBigEndian() {
        // 'h'=0x68 'd'=0x64 'p'=0x70 'n'=0x6E
        XCTAssertEqual(AudioRouteMonitor.fourCharCode("hdpn"), 0x6864_706E)
    }

    func testKnownCoreAudioConstants() {
        // 内置扬声器与耳机的常见 data source 值，用于确认拼装方向与 CoreAudio 一致。
        XCTAssertEqual(AudioRouteMonitor.fourCharCode("ispk"), 0x6973_706B)
        XCTAssertEqual(AudioRouteMonitor.fourCharCode("hdpn") == AudioRouteMonitor.fourCharCode("ispk"), false)
    }

    func testShorterStringDoesNotCollide() {
        XCTAssertNotEqual(AudioRouteMonitor.fourCharCode("hdp"),
                          AudioRouteMonitor.fourCharCode("hdpn"),
                          "少一个字符必须得到不同的码，否则判定会误命中")
    }
}
