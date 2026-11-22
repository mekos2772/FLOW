import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 扩展播放器整屏的离屏渲染。
///
/// 之前只单独验证过歌词列（`LyricRenderProbes`）。这里把**整块播放器**画出来，
/// 检查标题/歌手/走带/歌词四块拼在一起时排版是否成立。
///
/// 两处已知限制（都不是 bug，已在第 116/117 节写明）：
/// 1. `ImageRenderer` 不排版 `ScrollView` 内容 → 断言只针对顶部信息区；
/// 2. 歌词**行列表**取自 `app.lyricEngine.document`（引擎是唯一真相），
///    探针驱动不了引擎，所以这里会显示"没有找到同步歌词"的空态。
///    歌词列本身的排版由 `LyricRenderProbes` 用 `providedLines` 覆盖。
@MainActor
final class PlayerRenderProbeTests: XCTestCase {

    private func render(_ view: some View, size: CGSize, scheme: ColorScheme = .dark) throws -> NSBitmapImageRep {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Surface.windowBase(scheme))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func topInkRatio(_ rep: NSBitmapImageRep, fraction: Double) -> Double {
        guard let bitmap = rep.bitmapData else { return 0 }
        let rows = max(1, Int(Double(rep.pixelsHigh) * fraction))
        var ink = 0
        for y in 0..<rows {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * 4
                if bitmap[offset] > 60 || bitmap[offset + 1] > 60 || bitmap[offset + 2] > 60 { ink += 1 }
            }
        }
        let total = rows * rep.pixelsWide
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-player-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func model(withLyrics: Bool) -> MorphPresentationModel {
        let model = MorphPresentationModel()
        let track = Track(sourceID: .mock, externalID: "player-render",
                          title: "夜曲", artist: "周杰伦", album: nil, duration: 227)
        model.track = track
        model.position = 32
        model.duration = track.duration
        model.state = .playing(PlaybackContext(trackID: track.id,
                                               duration: track.duration,
                                               anchor: PositionAnchor.anchored(at: 32, now: ContinuousClock().now, rate: 1),
                                               retryCount: 0,
                                               pauseReason: nil,
                                               pendingAutoplay: false))
        if withLyrics {
            let lines = [
                LyricLine(start: 0, text: "一群嗜血的蚂蚁被腐肉所吸引"),
                LyricLine(start: 5, text: "我面无表情看孤独的风景"),
                LyricLine(start: 10, text: "失去你爱恨开始分明"),
            ]
            model.lyricState = .loaded
            model.lyric = LyricEngine.Snapshot(current: lines[0], next: lines[1], previous: nil,
                                               progressInLine: 0.3, index: 0,
                                               totalLines: lines.count, unsyncedLines: [])
        }
        return model
    }

    func testPlayerRendersHeaderAndTransport() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let rep = try render(
            ExpandedPlayerView(model: model(withLyrics: true), onClose: {}, onBrowse: {})
                .environment(\.app, container),
            size: CGSize(width: 520, height: 420)
        )
        try write(rep, name: "player")
        XCTAssertGreaterThan(topInkRatio(rep, fraction: 0.35), 0.01,
                             "播放器上半部分（标题/歌手/走带）没有渲染出内容")
    }

    func testHomeAcrossWidthsWithAndWithoutPlayback() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        for width in [520.0, 780.0, 1020.0] {
            for playing in [false, true] {
                let snapshot = playing ? model(withLyrics: true) : MorphPresentationModel()
                snapshot.showHome()
                let rep = try render(
                    ExpandedPlayerView(model: snapshot, onClose: {}, onBrowse: {})
                        .environment(\.app, container),
                    size: CGSize(width: width, height: 640)
                )
                try write(rep, name: "home-\(Int(width))-\(playing)")
                XCTAssertGreaterThan(topInkRatio(rep, fraction: 0.3), 0.01)
            }
        }
    }

    func testMinimumWindowAcrossPagesAndAppearances() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        for scheme in [ColorScheme.light, .dark] {
            for section in [OnlineHomeState.Section.recommendations, .favorites, .recent, .playlists] {
                let snapshot = model(withLyrics: true)
                snapshot.track = Track(sourceID: .mock, externalID: "long-title",
                                       title: "一首很长很长的歌曲标题，用来检查最小窗口中的排版与截断",
                                       artist: "测试歌手", duration: 227)
                snapshot.browse(section, app: nil)
                let rep = try render(
                    ExpandedPlayerView(model: snapshot, onClose: {}, onBrowse: {})
                        .environment(\.app, container),
                    size: CGSize(width: 780, height: 480), scheme: scheme
                )
                try write(rep, name: "minimum-\(section)-\(scheme)")
                XCTAssertEqual(rep.pixelsWide, 1560)
                XCTAssertEqual(rep.pixelsHigh, 960)
                // 最底部的进度轨道必须存在，不能被侧栏的最小高度挤出视口。
                let bitmap = try XCTUnwrap(rep.bitmapData)
                var progressInk = 0
                for y in 905..<945 {
                    for x in 620..<650 {
                        let offset = y * rep.bytesPerRow + x * 4
                        let value = bitmap[offset]
                        if scheme == .dark ? value > 80 : value < 180 { progressInk += 1 }
                    }
                }
                XCTAssertGreaterThan(progressInk, 20, "最小窗口的进度条未显示：\(section)、\(scheme)")
            }
        }
    }

    func testPlayerWithoutTrackStillRendersChrome() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let empty = MorphPresentationModel()
        let rep = try render(
            ExpandedPlayerView(model: empty, onClose: {}, onBrowse: {})
                .environment(\.app, container),
            size: CGSize(width: 520, height: 420)
        )
        try write(rep, name: "player-idle")
        XCTAssertGreaterThan(topInkRatio(rep, fraction: 0.25), 0.005,
                             "空闲态播放器什么都没有渲染")
    }
}
