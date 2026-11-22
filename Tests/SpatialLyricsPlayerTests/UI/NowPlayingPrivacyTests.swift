import XCTest
@testable import SpatialLyricsPlayer

/// 隐私模式下，系统"正在播放"也不能显示真实歌名。
///
/// App 自己的界面（完整播放器、胶囊、悬浮歌词、菜单栏、小组件）都会遮住标题，
/// 但锁屏 / 控制中心 / 菜单栏媒体区读的是 **MPNowPlayingInfoCenter**——
/// 如果那里不一起处理，用户开隐私模式的理由就落空了。
@MainActor
final class NowPlayingPrivacyTests: XCTestCase {

    private func makeIntegration(masked: Bool) throws -> SystemMediaIntegration {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let registry = SourceRegistry()
        let engine = PlaybackEngine(clock: SystemPlaybackClock(),
                                    coordinator: PlaybackCoordinator(registry: registry))
        let integration = SystemMediaIntegration(bridge: MediaPlayerNowPlayingBridge(),
                                                playback: engine,
                                                library: container.library)
        integration.isPrivacyMasked = { masked }
        return integration
    }

    private func track() -> Track {
        Track(sourceID: SourceID(rawValue: "bili"), externalID: "BV1privacy",
              title: "不能让别人看到的歌名", artist: "不能看到的歌手", album: "专辑",
              duration: 200)
    }

    /// 逻辑层：遮罩时下发给系统的标题必须是占位文案。
    func testPublishedTrackIsRedactedWhenMasked() throws {
        let integration = try makeIntegration(masked: true)
        let published = integration.publishedTrackForTesting(track())
        XCTAssertEqual(published?.title, "正在播放")
        XCTAssertEqual(published?.artist, "")
        XCTAssertNil(published?.artwork, "遮罩时不该再推封面")
    }

    func testPublishedTrackIsIntactWhenNotMasked() throws {
        let integration = try makeIntegration(masked: false)
        let published = integration.publishedTrackForTesting(track())
        XCTAssertEqual(published?.title, "不能让别人看到的歌名")
        XCTAssertEqual(published?.artist, "不能看到的歌手")
    }

    func testNilTrackStaysNil() throws {
        let integration = try makeIntegration(masked: true)
        XCTAssertNil(integration.publishedTrackForTesting(nil))
    }
}
