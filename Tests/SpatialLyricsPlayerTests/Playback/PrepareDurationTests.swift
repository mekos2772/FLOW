import XCTest
@testable import SpatialLyricsPlayer

/// `prepare()` 返回时时长必须已经可用。
///
/// `duration` 平时由 KVO 异步赋值，而调用方在 `prepare()` 之后**立刻**读它
/// （进度条、歌词时间轴、会话持久化）。KVO 的 `Task { @MainActor }` 可能还没跑到，
/// 于是出现"刚准备好时时长是 0"的一瞬。
///
/// 这条用例原来偶发失败（首次构建后时机偏移就会红），根因就是这个窗口。
@MainActor
final class PrepareDurationTests: XCTestCase {

    private func cachedAudio() -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLOW/Bili", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".m4a") }.sorted().first
            .map { directory.appendingPathComponent($0) }
    }

    func testDurationIsReadyRightAfterPrepare() async throws {
        guard let url = cachedAudio() else {
            throw XCTSkip("本机没有缓存音频样本，跳过")
        }
        let stream = AudioStreamDescriptor(cacheKey: "duration-probe",
                                           fileExtension: "m4a",
                                           qualityTier: .standard,
                                           qualityID: 30216,
                                           codec: "AAC",
                                           bandwidth: 64_000,
                                           sampleRate: 44_100,
                                           isLossless: false,
                                           url: url)
        let session = try HTTPStreamPlayerSession(stream: stream, localURL: url, title: "duration")

        try await session.prepare()
        // 不等待、不 sleep：prepare 返回的那一刻就要有值。
        XCTAssertGreaterThan(session.duration, 0,
                             "prepare 返回时时长必须已经同步好，否则调用方会看到 0")

        await session.invalidate()
    }
}
