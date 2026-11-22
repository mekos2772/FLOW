import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// `BiliTrackRow` 的离屏渲染检查。
///
/// 抽这个组件是为了让资料库与发现页的列表行**永远长得一样**（第 107 节）。
/// 抽出后必须确认：超长标题不会把时长挤出去，一小时以上的时长不会换行。
@MainActor
final class TrackRowRenderTests: XCTestCase {

    private func track(title: String, artist: String, duration: TimeInterval) -> Track {
        Track(sourceID: SourceID(rawValue: "remote"), externalID: "track-sample-1",
              title: title, artist: artist, album: nil, duration: duration)
    }

    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-row-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private var sampleRows: some View {
        VStack(spacing: 0) {
            SongRow(track: track(title: "短标题", artist: "歌手", duration: 252)) {}
            SongRow(track: track(
                title: "【4K60p·Hi-Res】这是一个非常非常长的标题用来测试截断行为，看看它会不会把右侧的时长挤出去",
                artist: "一个同样很长很长的歌手名字用来测试第二行截断",
                duration: 3725)) {}
            SongRow(track: track(title: "十分钟的播客", artist: "作者", duration: 600)) {}
        }
        .padding(.horizontal, 16)
    }

    func testRendersWithoutLosingTheDurationColumn() throws {
        let rep = try render(sampleRows, size: CGSize(width: 360, height: 200))
        _ = try write(rep, name: "rows")

        // 结构化断言：右侧一列必须有内容（时长）；做法是比较右边缘区域与纯背景的亮度差。
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var brightInRightColumn = 0
        if let bitmap = rep.bitmapData {
            for y in 0..<height {
                for x in (width * 4 / 5)..<width {
                    let offset = y * rep.bytesPerRow + x * 4
                    if bitmap[offset] > 80 || bitmap[offset + 1] > 80 || bitmap[offset + 2] > 80 {
                        brightInRightColumn += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(brightInRightColumn, 100,
                             "右侧时长列没有渲染出内容——超长标题可能把它挤掉了")
    }
}
