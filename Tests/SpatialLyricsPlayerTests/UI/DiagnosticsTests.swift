import XCTest
@testable import SpatialLyricsPlayer

// 诊断与错误：诊断报告、日志脱敏、错误文案映射。

@MainActor
final class DiagnosticsTests: XCTestCase {

    private func facts() -> DiagnosticsReport.Facts {
        DiagnosticsReport.Facts(appVersion: "0.1.0 (1)",
                                osVersion: "macOS 27.3",
                                schemaVersion: "v3",
                                accessibilityState: "已授权",
                                queueCount: 12,
                                floatingShape: "歌词板",
                                privacyModeEnabled: true,
                                sleepTimerArmed: false,
            storageState: "正常", runtimeMode: "正常", widgetShared: "可用")
    }

    func testRendersEveryField() {
        let text = DiagnosticsReport.render(facts())
        for expected in ["0.1.0 (1)", "macOS 27.3", "v3", "已授权", "12 首", "歌词板", "开启", "未设定"] {
            XCTAssertTrue(text.contains(expected), "诊断报告缺少字段：\(expected)")
        }
    }

    func testRedactsUserHomePath() {
        // 用户目录会随 Facts 之外的信息混进来（例如将来的日志），这里验证兜底规则真的生效。
        let sanitized = RedactingLog.sanitize("/Users/alice/Library/Containers/app/data.db")
        XCTAssertFalse(sanitized.contains("alice"), "导出内容不能带用户名")
    }

    func testRedactsLongTokens() {
        let sanitized = RedactingLog.sanitize("token=abcdefghijklmnopqrstuvwxyz012345")
        XCTAssertFalse(sanitized.contains("abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertTrue(sanitized.contains("abcd…"), "长 token 应折叠成前 4 位加省略号")
    }

    func testReportEndsWithSingleNewline() {
        let text = DiagnosticsReport.render(facts())
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"), "末尾只应有一个换行，追加写入时不会出现空行")
    }
}
/// 日志脱敏（规格 13.4）。
///
/// 断言的是「敏感内容不能出现在输出里」这个性质，而不是某种具体的替换写法——
/// 否则调整脱敏格式就会让一堆无关的测试变红。
final class RedactingLogTests: XCTestCase {

    func testQueryStringIsStripped() {
        let raw = "fetch https://example.com/track/123?token=SECRETVALUE&user=yg"
        let out = RedactingLog.sanitize(raw)
        XCTAssertFalse(out.contains("SECRETVALUE"), "查询参数里的令牌不能进日志")
        XCTAssertFalse(out.contains("user=yg"), "查询参数里的用户标识不能进日志")
    }

    func testUserPathIsRedacted() {
        let raw = "opening /Users/bob/Documents/private/secret-song.mp3"
        let out = RedactingLog.sanitize(raw)
        XCTAssertFalse(out.contains("yg"), "用户目录名不能进日志")
        XCTAssertFalse(out.contains("secret-song"), "文件名不能进日志")
    }

    func testBenignMessageSurvives() {
        let raw = "playback state -> playing"
        XCTAssertEqual(RedactingLog.sanitize(raw), raw, "普通日志不应被改写，否则排障时读不懂")
    }
}
final class ErrorMappingTests: XCTestCase {

    private let source = MockPlaybackSource(behavior: .healthy, clock: TestPlaybackClock())

    func testHintTable() {
        XCTAssertTrue(PlaybackError.sourceUnavailable.isRetryable)
        XCTAssertTrue(PlaybackError.decodeFailed(reason: "x").isRetryable)
        XCTAssertTrue(PlaybackError.unknown(reason: "x").isRetryable)

        XCTAssertFalse(PlaybackError.networkDisabled.isRetryable)
        XCTAssertFalse(PlaybackError.rightsRestricted.isRetryable)
        XCTAssertFalse(PlaybackError.cancelled.isRetryable)
        XCTAssertFalse(PlaybackError.unsupportedFormat(.ogg).isRetryable)

        XCTAssertEqual(PlaybackError.unsupportedFormat(.flac).hint, .advanceToNext)
        XCTAssertEqual(PlaybackError.networkDisabled.hint, .manual)
        XCTAssertEqual(PlaybackError.decodeFailed(reason: "x").maxRetryAttempts, 2)
        XCTAssertEqual(PlaybackError.decodeFailed(reason: "x").retryBackoff, .milliseconds(400))
    }

    func testMapPreservesPlaybackErrors() {
        XCTAssertEqual(source.map(PlaybackError.decodeFailed(reason: "y")), .decodeFailed(reason: "y"))
    }

    func testMapRecognizesCancellation() {
        XCTAssertEqual(source.map(CancellationError()), .cancelled)
        let urlCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(source.map(urlCancelled), .cancelled)
    }

    func testMapFallsBackToSourceUnavailable() {
        let weird = NSError(domain: "com.example.weird", code: 42)
        XCTAssertEqual(source.map(weird), .sourceUnavailable)
    }
}

/// 错误文案与"下一步"的契约（规格 8.4：不能静默吞异常）。
@MainActor
final class PlaybackErrorPresentationTests: XCTestCase {
    func testEveryCaseHasTitleAndDetail() {
        let cases: [PlaybackError] = [
            .sourceUnavailable,
            .decodeFailed(reason: "x"),
            .networkDisabled,
            .unsupportedFormat(.flac),
            .cancelled,
            .rightsRestricted,
            .unknown(reason: "y"),
        ]
        for error in cases {
            XCTAssertFalse(error.title.isEmpty, "\(error) 缺标题")
            XCTAssertFalse(error.detail.isEmpty, "\(error) 缺解释")
        }
    }

    func testUnsupportedFormatSuggestsSkipNotRetry() {
        let error = PlaybackError.unsupportedFormat(.ogg)
        XCTAssertTrue(error.suggestsSkip)
        XCTAssertFalse(error.offersRetry, "格式不支持重试也没用，不该给重试按钮")
    }

    func testSourceUnavailableOffersBoth() {
        let error = PlaybackError.sourceUnavailable
        XCTAssertTrue(error.offersRetry)
        XCTAssertTrue(error.suggestsSkip)
    }

    func testNetworkDisabledIsManualOnly() {
        let error = PlaybackError.networkDisabled
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(error.offersRetry, "用户打开联网后仍可手动重试")
    }
}
