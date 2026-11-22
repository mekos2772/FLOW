import XCTest
@testable import SpatialLyricsPlayer

final class WidgetSnapshotTests: XCTestCase {

    private func snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            availability: .playing,
            title: "标题",
            artist: "歌手",
            duration: 200,
            position: 50,
            lyricLine: "一句歌词",
            upNext: ["下一首 A", "下一首 B"],
            updatedAt: .now
        )
    }

    func testProgressIsClampedToUnitRange() {
        var value = snapshot()
        XCTAssertEqual(value.progress, 0.25, accuracy: 0.001)

        value.position = 999
        XCTAssertEqual(value.progress, 1.0, accuracy: 0.001)

        value.duration = 0
        XCTAssertEqual(value.progress, 0, "时长未知时不得除零")
    }

    func testRedactionRemovesEverythingIdentifiable() {
        let redacted = snapshot().redacting()

        XCTAssertEqual(redacted.availability, .privacyHidden)
        XCTAssertNil(redacted.title)
        XCTAssertNil(redacted.artist)
        XCTAssertNil(redacted.lyricLine)
        XCTAssertTrue(redacted.upNext.isEmpty, "队列在隐私态下不得泄露标题")
        XCTAssertEqual(redacted.displayTitle, "正在播放")
        XCTAssertNil(redacted.displayArtist)
    }

    func testDisplayTitleFallsBackToIdleText() {
        var value = snapshot()
        value.availability = .idle
        value.title = nil
        XCTAssertEqual(value.displayTitle, "未在播放")
    }

    func testSnapshotRoundTripsThroughCodable() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCommandQueueDrainsOnce() {
        SharedStateStore.post(.toggle)
        SharedStateStore.post(.next)

        let first = SharedStateStore.drainCommands()
        XCTAssertEqual(first, [.toggle, .next])

        let second = SharedStateStore.drainCommands()
        XCTAssertTrue(second.isEmpty, "命令只能被执行一次，避免重复触发")
    }

    func testSharedStoreRoundTripsSnapshot() {
        SharedStateStore.write(snapshot())
        let read = SharedStateStore.read()
        XCTAssertEqual(read.title, "标题")
        XCTAssertEqual(read.availability, .playing)
    }

    /// 隐私脱敏必须在**序列化层面**也成立。
    ///
    /// 上面那条逐字段断言只覆盖"当前存在的字段"——将来给快照加一个字段
    /// 却忘了在 `redacting()` 里清掉，它照样是绿的。
    /// 而真正写进共享存储、被桌面小组件显示出来的，是这份 JSON。
    func testRedactedJSONContainsNoIdentifiableText() throws {
        // 注意：`album` 字段已删除（小组件从未显示它），所以这里不再包含"专辑"。
        let secrets = ["标题", "歌手", "一句歌词", "下一首"]

        let redactedJSON = String(decoding: try JSONEncoder().encode(snapshot().redacting()),
                                  as: UTF8.self)
        for secret in secrets {
            XCTAssertFalse(redactedJSON.contains(secret),
                           "隐私态序列化后仍包含「\(secret)」——小组件会把内容显示在桌面上")
        }

        // 反过来确认这条测试不是空跑：未脱敏时这些内容本来就在。
        let plainJSON = String(decoding: try JSONEncoder().encode(snapshot()), as: UTF8.self)
        for secret in secrets {
            XCTAssertTrue(plainJSON.contains(secret))
        }
    }

    /// 隐私态仍然保留"正在播放"这个事实与进度（不泄露内容，但组件不该显示成空白）。
    func testRedactionKeepsProgressAndState() {
        let redacted = snapshot().redacting()
        XCTAssertEqual(redacted.availability, .privacyHidden)
        XCTAssertEqual(redacted.progress, 0.25, accuracy: 0.001)
    }
}
