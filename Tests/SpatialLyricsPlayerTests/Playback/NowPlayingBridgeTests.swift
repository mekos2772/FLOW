import AppKit
import MediaPlayer
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class NowPlayingBridgeTests: XCTestCase {

    private func track() -> Track {
        Track(sourceID: SourceID("test"), externalID: "np", title: "标题", artist: "歌手",
              album: "专辑", duration: 180)
    }

    func testPublishesMetadataAndPlaybackState() {
        let bridge = MediaPlayerNowPlayingBridge()
        bridge.update(state: .playing(.emptyForTest), track: track(), position: 42)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "标题")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "歌手")
        XCTAssertEqual(info?[MPMediaItemPropertyAlbumTitle] as? String, "专辑")
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    func testPausedStatePublishesZeroRate() {
        let bridge = MediaPlayerNowPlayingBridge()
        bridge.update(state: .ready(.emptyForTest), track: track(), position: 10)
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }

    func testClearRemovesInfo() {
        let bridge = MediaPlayerNowPlayingBridge()
        bridge.update(state: .playing(.emptyForTest), track: track(), position: 0)
        bridge.clear()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    // MARK: - 封面（回归：带封面的曲目会 SIGTRAP）

    /// 一张真实可解码的 PNG（4×4 纯红）。
    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
    }

    /// 之前的写法把主线程隔离的 `NSImage` 捕获进 `MPMediaItemArtwork` 的回调闭包，
    /// 系统在 `accessQueue` 上回调时执行器断言直接 trap。这里走完整条路径并等系统真的去
    /// 编码封面——崩溃的话这条用例会连带进程一起挂掉。
    func testPublishingArtworkDoesNotTrapOffMainThread() {
        let bridge = MediaPlayerNowPlayingBridge()
        bridge.update(state: .playing(.emptyForTest), track: track(), position: 0,
                      artwork: pngData())
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])

        // 给 MediaPlayer 的 accessQueue 足够时间把 info 字典转成 MR 字典并请求封面。
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
    }

    /// 闭包本体必须能在后台线程跑：这正是崩溃时系统所在的线程。
    ///
    /// `Task.detached` 不继承 actor 隔离；如果 `render` 带主线程隔离，
    /// 这里就会在运行时被执行器断言拦下（和崩溃报告里同一处 trap）。
    func testArtworkRenderWorksOffMainThread() async {
        let data = pngData()
        let width = await Task.detached(priority: .userInitiated) { @Sendable in
            NowPlayingArtwork.render(data, size: CGSize(width: 64, height: 64)).size.width
        }.value
        XCTAssertEqual(width, 4)
    }

    /// 拿不到可解码数据时也不能返回 nil（系统会崩在取图那一步）。
    func testArtworkFallsBackToBlankImageOnBadData() {
        let image = NowPlayingArtwork.render(Data([0x00, 0x01]), size: CGSize(width: 32, height: 32))
        XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
    }
}

extension PlaybackContext {
    /// 测试用的最小上下文。
    static var emptyForTest: PlaybackContext { .empty(now: ContinuousClock().now) }
}
