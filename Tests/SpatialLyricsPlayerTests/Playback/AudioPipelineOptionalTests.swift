import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

/// 播放链路的**可选**验证（默认跳过，永远静音）。
///
/// 背景：本项目长期在"不出声"约束下开发，`play()` 从未真机验证过——
/// 位置是否推进、暂停是否生效、淡变是否按 baseVolume 走，全都是靠单元测试推断。
///
/// 这个文件提供"随时可跑"的能力，但**默认不执行**：
///
///     SLP_AUDIO_TEST=1 xcodebuild test ... -only-testing:SpatialLyricsPlayerTests/AudioPipelineOptionalTests
///
/// 安全前提（三重）：
/// 1. `setVolume(0)` 先把 `baseVolume` 置 0，`play()` 的淡变目标就是 0，输出静音；
/// 2. 现场生成隔离样本，不读用户缓存、不联网；
/// 3. 整段不过 2 秒，结束立刻 `pause()` + `invalidate()`。
@MainActor
final class AudioPipelineOptionalTests: XCTestCase {

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SLP_AUDIO_TEST"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/slp-audio-test")
    }

    func testPlayAdvancesPositionSilently() async throws {
        try XCTSkipUnless(Self.isEnabled,
                          "默认跳过：设置 SLP_AUDIO_TEST=1 才会真正播放（静音）")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-audio-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestAudioFixture.makeM4A(in: directory)
        let stream = AudioStreamDescriptor(
            cacheKey: "probe::audio-gate",
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: url
        )
        let session = try HTTPStreamPlayerSession(stream: stream, localURL: url, title: "audio-gate")

        // 关键一步：先把目标音量压到 0，之后 play() 的淡变终点也是 0 —— 全程静音。
        await session.setVolume(0)
        try await session.prepare()
        try await session.play()

        let before = session.debugPlaybackPosition
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(session.debugPlaybackPosition, before + 0.1, "必须验证真实音频时钟推进")
        var sawPrepared = false
        for await event in session.events {
            if case .prepared = event { sawPrepared = true; break }
        }
        XCTAssertTrue(sawPrepared, "prepare 之后应当收到 .prepared 事件")

        await session.pause()
        let paused = session.debugPlaybackPosition
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.debugPlaybackPosition, paused, accuracy: 0.05, "暂停后真实音频时钟必须冻结")
        await session.invalidate()
    }
}
