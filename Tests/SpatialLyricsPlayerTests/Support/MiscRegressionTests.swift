import XCTest
@testable import SpatialLyricsPlayer

/// 错误文案：这是一个在线播放器，没有"文件""导入"这些概念。
final class OnlineErrorCopyTests: XCTestCase {

    private let all: [PlaybackError] = [
        .sourceUnavailable, .decodeFailed(reason: "x"), .networkDisabled, .networkUnavailable,
        .unsupportedFormat(.flac), .cancelled, .rightsRestricted, .unknown(reason: "x"),
    ]

    func testNoLeftoverLocalFileWording() {
        for error in all {
            let text = error.title + error.detail
            for banned in ["导入", "文件被移动", "重新授权", "资料库里", ".lrc", "m4a / mp3"] {
                XCTAssertFalse(text.contains(banned), "\(error) 的文案还在说本地文件的事：\(text)")
            }
        }
    }

    func testEveryErrorTellsTheUserWhatToDo() {
        for error in all {
            XCTAssertFalse(error.title.isEmpty)
            XCTAssertGreaterThan(error.detail.count, 6, "\(error) 没有给出下一步")
        }
    }

    func testOnlyOurOwnReasonsReachTheScreen() {
        let friendly = PlaybackError.unknown(reason: "这首歌可能已下架或被设为私密，换一首试试。")
        XCTAssertEqual(friendly.detail, "这首歌可能已下架或被设为私密，换一首试试。")
        let technical = PlaybackError.unknown(reason: "The operation couldn’t be completed. (NSURLErrorDomain error -1001.)")
        XCTAssertFalse(technical.detail.contains("NSURLErrorDomain"))
    }

    func testConnectivityErrorsAreNotBlamedOnTheSong() {
        let source = MockPlaybackSource()
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            XCTAssertEqual(source.map(URLError(code)), .networkUnavailable,
                           "断网被说成「找不到音频」，自动恢复也就不会等网络")
        }
        XCTAssertEqual(source.map(URLError(.cancelled)), .cancelled)
        XCTAssertTrue(PlaybackError.networkUnavailable.isEnvironmental)
        XCTAssertFalse(PlaybackError.networkUnavailable.suggestsSkip, "断网时跳到下一首只会得到同一个错误")
    }
}

/// 清缓存与淘汰不能动正在播的那份文件。
@MainActor
final class AudioCacheSafetyTests: XCTestCase {

    private var directory: URL!
    private var cache: MediaAudioCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = MediaAudioCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: 100 * 1024).write(to: url)
        return url
    }

    func testClearKeepsTheFileThatIsPlaying() async throws {
        let playing = try makeFile("playing-30280-192000.m4a")
        let idle = try makeFile("idle-30280-192000.m4a")
        MediaAudioCache.pin(playing)
        defer { MediaAudioCache.unpin(playing) }

        await cache.clear()

        XCTAssertTrue(FileManager.default.fileExists(atPath: playing.path),
                      "清缓存把正在播的文件删了：下一次拖进度条就会断")
        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.path))
    }

    func testEvictRemovesEveryQualityOfOneTrackOnly() async throws {
        let low = try makeFile("broken-30216-64000.m4a")
        let high = try makeFile("broken-30280-192000.m4a")
        let other = try makeFile("brokenX-30280-192000.m4a")

        await cache.evict(cacheKey: "broken")

        XCTAssertFalse(FileManager.default.fileExists(atPath: low.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: high.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "前缀相近的别的稿件不能被误删")
    }
}

/// 淡变执行器：被新淡变顶掉的旧调用不能把"正在淡变"的标记清掉。
final class AudioFadeRunnerTests: XCTestCase {

    func testSupersededRunDoesNotClearTheFadingFlag() async {
        let runner = AudioFadeRunner()
        let first = Task {
            await runner.run(kind: .fadeOut, duration: 0.3, target: 1) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(60))
        let second = Task {
            await runner.run(kind: .fadeIn, duration: 0.5, target: 1) { _ in }
        }
        await first.value          // 被顶掉的那条先返回
        let stillFading = await runner.isFading
        XCTAssertTrue(stillFading, "新的淡变还在跑，标记却被旧调用清掉了：音量写入会和淡变打架")
        await second.value
        let done = await runner.isFading
        XCTAssertFalse(done)
    }

    func testVolumeChangeDuringFadeAppliesToRemainingSteps() async {
        let runner = AudioFadeRunner()
        let seen = FloatSink()
        let fade = Task {
            await runner.run(kind: .fadeIn, duration: 0.3, target: 1) { seen.append($0) }
        }
        try? await Task.sleep(for: .milliseconds(80))
        await runner.setBaseVolume(0.2)
        await fade.value
        XCTAssertEqual(seen.values.last ?? -1, 0.2, accuracy: 0.001,
                       "淡入途中把音量调小了，淡变结束时应该落在新音量上")
    }
}

private final class FloatSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    func append(_ value: Float) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Float] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// 测试宿主必须与使用者的数据隔离。
@MainActor
final class TestHostIsolationTests: XCTestCase {
    func testTestHostNeverUsesTheRealDataLocations() throws {
        XCTAssertTrue(RuntimeSandbox.isTestHost)
        let directory = try XCTUnwrap(RuntimeSandbox.dataDirectory, "测试宿主必须运行在隔离目录里")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        XCTAssertFalse(directory.path.hasPrefix(home), "隔离目录不能落在用户的 Library 里")
        XCTAssertTrue(RuntimeSandbox.cachesDirectory().path.hasPrefix(directory.path))
        XCTAssertTrue(try PersistenceController.storeURL().path.hasPrefix(directory.path))
    }
}
