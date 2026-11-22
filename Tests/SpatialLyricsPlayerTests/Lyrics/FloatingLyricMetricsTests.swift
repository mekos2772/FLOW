import CoreGraphics
import XCTest
@testable import SpatialLyricsPlayer

/// 悬浮歌词的尺寸自适应。
///
/// 用户反馈"歌词对卡片的不同尺寸适配得很差"。修之前四种排布的字号全是写死的
/// （胶囊 15、双行 16/13、歌词板 19、贴边 12），卡片从 240 拉到 640 字一个都不变；
/// 双行的第二行还被底部进度线整段裁掉。
@MainActor
final class FloatingLyricMetricsTests: XCTestCase {

    private let inset: CGFloat = 16

    // MARK: 胶囊

    func testCapsuleFontGrowsWithWidthButStaysInReadableBand() {
        let narrow = FloatingLyricMetrics.capsule(CGSize(width: 240, height: 44), horizontalInset: inset)
        let design = FloatingLyricMetrics.capsule(CGSize(width: 392, height: 56), horizontalInset: inset)
        let wide = FloatingLyricMetrics.capsule(CGSize(width: 640, height: 56), horizontalInset: inset)

        XCTAssertLessThan(narrow.primarySize, design.primarySize, "窄卡片必须用更小的字")
        XCTAssertLessThanOrEqual(wide.primarySize, 16.5, "再宽也不该继续放大")
        XCTAssertGreaterThanOrEqual(narrow.primarySize, 11, "低于 11pt 就看不清了")
        XCTAssertEqual(design.primarySize, 15.7, accuracy: 0.1, "设计基准宽度上应与原令牌（15×1.08≈16.2）同档")
    }

    /// 进度线占的下沿高度必须被算进去，否则文字会压在线上。
    func testEveryLayoutReservesSpaceForTheProgressLine() {
        let sizes = [CGSize(width: 240, height: 44), CGSize(width: 392, height: 56), CGSize(width: 640, height: 56)]
        for size in sizes {
            XCTAssertGreaterThanOrEqual(
                FloatingLyricMetrics.capsule(size, horizontalInset: inset).bottomInset,
                FloatingLyricMetrics.progressHeight + FloatingLyricMetrics.progressGap)
        }
    }

    // MARK: 双行（原来第二行被裁掉）

    func testDoubleLineReservesRoomForTheSecondLine() {
        let fit = FloatingLyricMetrics.doubleLine(CGSize(width: 392, height: 76), horizontalInset: inset)
        // 底部预留必须容得下一整行次行文字（含行高），否则第二行会被裁。
        XCTAssertGreaterThan(fit.bottomInset, fit.secondarySize * 1.4,
                             "底部预留 \(fit.bottomInset) 容不下次行 \(fit.secondarySize)pt")
    }

    func testDoubleLineSecondaryIsSmallerThanPrimary() {
        let fit = FloatingLyricMetrics.doubleLine(CGSize(width: 392, height: 76), horizontalInset: inset)
        XCTAssertLessThan(fit.secondarySize, fit.primarySize)
        XCTAssertGreaterThanOrEqual(fit.secondarySize, 11, "次行也不该低于可读下限")
    }

    // MARK: 歌词板（行数跟高度走）

    func testBoardLineCountFollowsHeight() {
        let short = FloatingLyricMetrics.board(CGSize(width: 392, height: 96), horizontalInset: inset)
        let standard = FloatingLyricMetrics.board(CGSize(width: 392, height: 152), horizontalInset: inset)
        let tall = FloatingLyricMetrics.board(CGSize(width: 392, height: 240), horizontalInset: inset)

        XCTAssertLessThanOrEqual(short.primaryLineLimit, standard.primaryLineLimit)
        XCTAssertLessThan(standard.primaryLineLimit, tall.primaryLineLimit, "更高的卡片应给更多行")
        XCTAssertGreaterThanOrEqual(short.primaryLineLimit, 1, "至少要能显示一行")
        XCTAssertLessThanOrEqual(tall.primaryLineLimit, 4, "行数要有上限，否则字号被行高拖垮")
    }

    func testBoardPreviousLineOnlyWhenThereIsRoom() {
        let tight = FloatingLyricMetrics.board(CGSize(width: 392, height: 72), horizontalInset: inset)
        let roomy = FloatingLyricMetrics.board(CGSize(width: 392, height: 152), horizontalInset: inset)
        XCTAssertFalse(tight.showsPrevious, "挤的时候不该再塞上一句")
        XCTAssertTrue(roomy.showsPrevious)
    }

    func testBoardFontGrowsWithWidth() {
        let narrow = FloatingLyricMetrics.board(CGSize(width: 300, height: 152), horizontalInset: inset)
        let wide = FloatingLyricMetrics.board(CGSize(width: 640, height: 152), horizontalInset: inset)
        XCTAssertLessThan(narrow.primarySize, wide.primarySize)
        XCTAssertLessThanOrEqual(wide.primarySize, 20)
    }

    // MARK: 贴边（最窄只有 168×26）

    func testEdgeStaysReadableAtMinimumWidth() {
        let fit = FloatingLyricMetrics.edge(CGSize(width: 168, height: 26), horizontalInset: 10)
        XCTAssertGreaterThanOrEqual(fit.primarySize, 10)
        XCTAssertLessThanOrEqual(fit.primarySize, 13)
        XCTAssertEqual(fit.primaryLineLimit, 1)
    }

    // MARK: 迷你条

    func testCompactFontGrowsWithWidthAndContext() {
        let narrow = FloatingLyricMetrics.compact(CGSize(width: 320, height: 80),
                                                  horizontalInset: 12, showsContext: false)
        let wide = FloatingLyricMetrics.compact(CGSize(width: 640, height: 80),
                                                horizontalInset: 12, showsContext: false)
        let withContext = FloatingLyricMetrics.compact(CGSize(width: 420, height: 240),
                                                       horizontalInset: 18, showsContext: true)
        XCTAssertLessThanOrEqual(narrow.primarySize, wide.primarySize, "宽迷你条不该更小")
        XCTAssertEqual(narrow.primaryLineLimit, 1)
        XCTAssertEqual(withContext.primaryLineLimit, 2)
        XCTAssertLessThanOrEqual(wide.primarySize, 21)
        // 设计宽度 420pt 上必须还原旧版字号层级，否则"适配"变成了"缩水"。
        let design = FloatingLyricMetrics.compact(CGSize(width: 420, height: 80),
                                                   horizontalInset: 12, showsContext: false)
        XCTAssertEqual(design.primarySize, 17, accuracy: 0.5)
    }

    // MARK: 边界

    func testDegenerateSizesFallBackToTheLowerBound() {
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 56), CGSize(width: CGFloat.infinity, height: 56)] {
            let fit = FloatingLyricMetrics.capsule(size, horizontalInset: inset)
            XCTAssertTrue(fit.primarySize.isFinite, "\(size) 产出了非有限字号")
            XCTAssertGreaterThanOrEqual(fit.primarySize, 11)
        }
    }

    func testClampedFontRejectsNonFinite() {
        XCTAssertEqual(FloatingLyricMetrics.clampedFont(.nan, lower: 10, upper: 20), 10)
        XCTAssertEqual(FloatingLyricMetrics.clampedFont(.infinity, lower: 10, upper: 20), 10)
        XCTAssertEqual(FloatingLyricMetrics.clampedFont(5, lower: 10, upper: 20), 10)
        XCTAssertEqual(FloatingLyricMetrics.clampedFont(99, lower: 10, upper: 20), 20)
    }
}
