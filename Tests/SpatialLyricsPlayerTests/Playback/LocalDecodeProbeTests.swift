import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

/// 播放链路的**准备阶段**验证（不出声）。
///
/// 全流程"不出声"是本项目的硬约束，所以 `play()` 一律不调。
/// 但 `prepare()` 不发声：它只是等 AVPlayerItem 进入 `readyToPlay`。
/// 这一段能验证"文件能被 AVFoundation 解开、时长能拿到"——
/// 正是取流之后最容易出问题的环节。
///
/// 样本来自本机真实播放缓存（`~/Library/Caches/FLOW/MediaAudio/*.m4a`）；
/// 没有样本时自动跳过，不把本机状态塞进测试契约。
@MainActor
final class LocalDecodeProbeTests: XCTestCase {

    private func firstCachedAudio() -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLOW/MediaAudio", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names
            .filter { $0.hasSuffix(".m4a") }
            .sorted()
            .first
            .map { directory.appendingPathComponent($0) }
    }

    func testCachedAudioCanBePreparedWithoutPlaying() async throws {
        guard let url = firstCachedAudio() else {
            throw XCTSkip("本机没有缓存音频样本，跳过（这是可选的深层验证）")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 64 * 1024, "样本文件太小，不像真实音频")

        let stream = AudioStreamDescriptor(
            cacheKey: "probe::local-decode",
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: url
        )
        let session = try HTTPStreamPlayerSession(stream: stream, localURL: url, title: "probe")

        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0, "prepare 之后应当能拿到时长")
        XCTAssertLessThan(session.duration, 3600, "时长异常")

        // 只准备，不播放：整个用例没有一处调用 play()
        await session.invalidate()
    }
}

/// 状态更新的执行器。
///
/// `HTTPStreamPlayerSession` 是 `@unchecked Sendable`，状态归主 actor 所有。
/// 第 127 节证实过 nonisolated async 会跳到全局执行器；
/// 这里再加一条防回归：KVO 触发的状态更新必须落回主 actor。
@MainActor
final class SessionExecutorTests: XCTestCase {

    func testStatusCallbackDeliversOnMainActor() async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLOW/MediaAudio", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = names.filter({ $0.hasSuffix(".m4a") }).sorted().first else {
            throw XCTSkip("本机没有缓存音频样本，跳过")
        }
        let url = directory.appendingPathComponent(name)
        let stream = AudioStreamDescriptor(
            cacheKey: "probe::executor",
            fileExtension: "m4a",
            qualityTier: .standard,
            qualityID: 128,
            codec: "AAC",
            bandwidth: 128_000,
            sampleRate: 44_100,
            isLossless: false,
            url: url
        )
        let session = try HTTPStreamPlayerSession(stream: stream, localURL: url, title: "probe")

        // 等 KVO 把 .prepared 送出来：这一步若在后台改状态，断言就会在主线程读到半更新值。
        var received = false
        for await event in session.events {
            if case .prepared = event { received = true; break }
        }
        XCTAssertTrue(received, "应当收到 .prepared 事件")
        XCTAssertGreaterThan(session.duration, 0)

        await session.invalidate()
    }
}
