import XCTest
@testable import SpatialLyricsPlayer

/// 退出时的快照状态。
///
/// 小组件时间线是 `.never`（只由主 App 触发刷新），
/// 所以 App 退出必须发一次"已停止"；否则桌面小组件会一直显示"正在播放"。
/// 这里只测纯变换，不碰共享存储（避免写入使用者的真实偏好）。
final class SnapshotStoppedStateTests: XCTestCase {

    private func snapshot(availability: PlaybackSnapshot.Availability,
                          title: String?) -> PlaybackSnapshot {
        PlaybackSnapshot(availability: availability, title: title, artist: "歌手", duration: 200, position: 42, lyricLine: "一句歌词",
                         upNext: ["下一首"], updatedAt: .now)
    }

    func testPlayingBecomesPaused() {
        let stopped = snapshot(availability: .playing, title: "夜曲").stopped()
        XCTAssertEqual(stopped.availability, .paused)
        // 内容保留：暂停态仍然显示这首歌
        XCTAssertEqual(stopped.title, "夜曲")
        XCTAssertEqual(stopped.position, 42, accuracy: 0.001)
    }

    func testNoTrackBecomesIdle() {
        let stopped = snapshot(availability: .playing, title: nil).stopped()
        XCTAssertEqual(stopped.availability, .idle)
    }

    /// 隐私态不能被"停止"这一步泄露内容。
    func testPrivacyHiddenStaysHidden() {
        let stopped = snapshot(availability: .privacyHidden, title: nil).stopped()
        XCTAssertEqual(stopped.availability, .privacyHidden,
                       "退出时不能把隐私态改回可识别状态")
    }

    func testAlreadyPausedStaysPaused() {
        let stopped = snapshot(availability: .paused, title: "夜曲").stopped()
        XCTAssertEqual(stopped.availability, .paused)
    }
}
