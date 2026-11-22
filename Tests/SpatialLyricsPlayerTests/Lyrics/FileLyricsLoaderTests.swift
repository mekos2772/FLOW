import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 同目录 `.lrc` 的读取。
///
/// 这块之前**零覆盖**（`LyricsLoading.swift` 0/98 行）：真正决定"本地曲目有没有歌词"
/// 的代码，一条测试都没有。用真实临时文件测，不 mock 文件系统。
final class FileLyricsLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTrack(audio: URL) -> Track {
        Track(sourceID: "local", externalID: audio.absoluteString,
              title: "测试曲目", artist: "测试歌手", album: nil, duration: 200)
    }

    private func writeLRC(_ text: String, encoding: String.Encoding, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(text.data(using: encoding)).write(to: url)
        return url
    }

    func testReadsSidecarLRCNamedLikeTheAudioFile() async throws {
        let audio = directory.appendingPathComponent("song.mp3")
        try Data().write(to: audio)
        _ = try writeLRC("[00:10.00]第一句\n[00:15.00]第二句", encoding: .utf8, as: "song.lrc")

        let document = await FileLyricsLoader().loadLyrics(for: makeTrack(audio: audio))
        let loaded = try XCTUnwrap(document, "同目录 .lrc 必须被读到")
        XCTAssertEqual(loaded.lines.count, 2)
        XCTAssertEqual(loaded.lines.first?.text, "第一句")
        XCTAssertEqual(try XCTUnwrap(loaded.lines.first).start, 10, accuracy: 0.001)
        XCTAssertEqual(loaded.source, .sidecar)
        XCTAssertTrue(loaded.isSynced)
    }

    func testDecodesGB18030Sidecar() async throws {
        // 中文 LRC 里大量是 GBK；只试 UTF-8 会让这些文件读不出来。
        let audio = directory.appendingPathComponent("gbk.mp3")
        try Data().write(to: audio)
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        _ = try writeLRC("[00:05.00]繁体與简体都能读", encoding: gb18030, as: "gbk.lrc")

        let document = await FileLyricsLoader().loadLyrics(for: makeTrack(audio: audio))
        let loaded = try XCTUnwrap(document, "GB18030 编码的 .lrc 必须能解码")
        // 注意：加载路径会统一做繁转简（`TextNormalizer`），所以「與」会变成「与」。
        XCTAssertEqual(loaded.lines.first?.text, "繁体与简体都能读")
    }

    func testNoSidecarAndNoEmbeddedReturnsNil() async throws {
        let audio = directory.appendingPathComponent("silent.mp3")
        try Data([0x00, 0x01]).write(to: audio)   // 不是有效音频，也没有 .lrc
        let document = await FileLyricsLoader().loadLyrics(for: makeTrack(audio: audio))
        XCTAssertNil(document)
    }

    func testNonFileTrackIsIgnored() async {
        let track = Track(sourceID: "bilibili", externalID: "BV1xx411c7mD",
                          title: "在线曲目", artist: "", album: nil, duration: 100)
        let document = await FileLyricsLoader().loadLyrics(for: track)
        XCTAssertNil(document, "在线曲目不该走本地文件加载器")
    }
}
