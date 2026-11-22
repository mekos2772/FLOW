import XCTest
@testable import SpatialLyricsPlayer

/// 快照陈旧修正。
///
/// 小组件时间线是 `.never`：正常退出我们会发"已停止"（第 131 节），
/// 但**崩溃**走不到那个钩子，桌面小组件会一直显示"正在播放"。
/// 这里把"太久没更新就不再声称在播放"固定成契约。
final class SnapshotFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(availability: PlaybackSnapshot.Availability,
                          updatedAgo: TimeInterval?) -> PlaybackSnapshot {
        PlaybackSnapshot(availability: availability, title: "夜曲", artist: "周杰伦", duration: 200, position: 42, lyricLine: nil,
                         upNext: [], updatedAt: updatedAgo.map { now.addingTimeInterval(-$0) } ?? .distantPast)
    }

    func testFreshPlayingStaysPlaying() {
        let s = snapshot(availability: .playing, updatedAgo: 30)
            .freshnessAdjusted(now: now, maxAge: 300)
        XCTAssertEqual(s.availability, .playing)
    }

    func testStalePlayingBecomesPaused() {
        let s = snapshot(availability: .playing, updatedAgo: 3600)
            .freshnessAdjusted(now: now, maxAge: 300)
        XCTAssertEqual(s.availability, .paused, "一小时没更新就不该再声称在播放")
        XCTAssertEqual(s.title, "夜曲", "曲目信息保留，只是不再说在播")
    }

    func testPausedIsNotTouched() {
        let s = snapshot(availability: .paused, updatedAgo: 3600)
            .freshnessAdjusted(now: now, maxAge: 300)
        XCTAssertEqual(s.availability, .paused)
    }

    func testPrivacyHiddenIsNotTouched() {
        let s = snapshot(availability: .privacyHidden, updatedAgo: 3600)
            .freshnessAdjusted(now: now, maxAge: 300)
        XCTAssertEqual(s.availability, .privacyHidden, "隐私态不能被陈旧修正改回可识别状态")
    }

    /// 占位快照（`updatedAt == .distantPast`）不能被当成"很久没更新"而降级。
    func testPlaceholderSnapshotIsLeftAlone() {
        let s = PlaybackSnapshot.empty.freshnessAdjusted(now: now)
        XCTAssertEqual(s.availability, .idle)
    }
}
