import XCTest
@testable import SpatialLyricsPlayer

/// Apple Music 风格歌词的布局契约。
///
/// 这套逻辑决定"哪一行在中心、多大、多亮"，是跃动手感的基础，
/// 所以必须能脱离 SwiftUI 说清楚。
final class LyricScrollLayoutTests: XCTestCase {
    private let base: Double = 36      // 上下文行高
    private let current: Double = 56   // 当前行高
    private let visible: Double = 400  // 可视区高度

    private func layout(_ count: Int, _ index: Int?) -> LyricScrollLayout.Layout {
        LyricScrollLayout.make(lineCount: count, currentIndex: index,
                               baseLineHeight: base, currentLineHeight: current,
                               visibleHeight: visible)
    }

    func testEmptyDocumentProducesEmptyLayout() {
        XCTAssertEqual(layout(0, nil), .empty)
    }

    func testCurrentLineIsCenteredInViewport() throws {
        let result = layout(40, 20)
        let center = try XCTUnwrap(result.center(at: 20))
        // 当前行中心相对可视区中心应接近 0（受 clamp 影响，中间行必须正好居中）。
        XCTAssertEqual(center, 0, accuracy: 0.5, "当前行必须落在可视区中心")
    }

    /// 恒定规则：当前行永远在正中，首行与末行也不例外。
    ///
    /// 不做边界钳制，是为了让"当前行居中"成为一条不随位置变化的条件——
    /// 一旦碰边界就改行为，动画会在这里突变。
    func testFirstAndLastLinesAreStillCentered() throws {
        let first = layout(40, 0)
        XCTAssertEqual(try XCTUnwrap(first.center(at: 0)), 0, accuracy: 0.5)
        let last = layout(40, 39)
        XCTAssertEqual(try XCTUnwrap(last.center(at: 39)), 0, accuracy: 0.5)
        XCTAssertLessThan(first.scrollOffset, 0, "首行居中需要把内容往下推")
    }

    func testCurrentLineIsLargestAndMostOpaque() throws {
        let result = layout(20, 10)
        let currentStyle = try XCTUnwrap(result.style(at: 10))
        XCTAssertTrue(currentStyle.isCurrent)
        XCTAssertEqual(currentStyle.opacity, 1.0)
        XCTAssertEqual(currentStyle.blur, 0)
        XCTAssertEqual(currentStyle.scale, LyricScrollLayout.currentScale)

        let neighbor = try XCTUnwrap(result.style(at: 11))
        XCTAssertFalse(neighbor.isCurrent)
        XCTAssertLessThan(neighbor.opacity, currentStyle.opacity, "相邻行必须比当前行暗")
        XCTAssertLessThan(neighbor.scale, currentStyle.scale, "相邻行必须比当前行小")
    }

    func testOpacityDecaysWithDistance() throws {
        let result = layout(20, 10)
        let opacities = [-3, -2, -1, 0, 1, 2, 3].map { result.style(at: 10 + $0)!.opacity }
        XCTAssertEqual(opacities[3], 1.0, "当前行最亮")
        XCTAssertGreaterThan(opacities[2], opacities[1], "越近越亮")
        XCTAssertGreaterThan(opacities[1], opacities[0], "越远越暗")
        XCTAssertEqual(opacities[0], 0, "三行之外完全隐去，避免满屏字抢注意力")
    }

    func testDistantLinesAreBlurredButCurrentIsSharp() throws {
        let result = layout(20, 10)
        XCTAssertEqual(try XCTUnwrap(result.style(at: 10)).blur, 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.style(at: 12)).blur, 0, "远处行轻微失焦形成景深")
    }

    func testContentHeightAccountsForTallerCurrentLine() {
        let result = layout(10, 3)
        // 9 行基准 + 1 行当前行
        XCTAssertEqual(result.contentHeight, base * 9 + current, accuracy: 0.001)
    }

    func testScrollOffsetOnlyMovesByLineHeight() {
        let a = layout(40, 10).scrollOffset
        let b = layout(40, 11).scrollOffset
        XCTAssertEqual(b - a, base, accuracy: 0.5, "相邻行滚动量差正好是一个行高")
    }

    func testNoCurrentIndexShowsEverythingDim() {
        let result = layout(8, nil)
        for index in 0..<8 {
            let style = result.style(at: index)!
            XCTAssertFalse(style.isCurrent)
            XCTAssertEqual(style.opacity, LyricScrollLayout.distantOpacity)
        }
    }

    func testCurrentIndexOutOfRangeIsClamped() throws {
        let result = layout(5, 99)
        XCTAssertTrue(try XCTUnwrap(result.style(at: 4)).isCurrent, "越界的行号应夹到最后一行")
    }

    func testBounceParametersAreSubtleButVisible() {
        // 起始缩放要明显小于 1（看得见），但不能小到像"缩没了"。
        XCTAssertLessThan(LyricScrollLayout.bounceStartScale, 0.95)
        XCTAssertGreaterThan(LyricScrollLayout.bounceStartScale, 0.75)
        XCTAssertGreaterThan(LyricScrollLayout.bounceRise, 0)
        XCTAssertLessThanOrEqual(LyricScrollLayout.bounceRise, 16, "跃动位移别大到影响阅读")
    }

    // MARK: - 行高与命中（原 LyricHitTestTests）
    //
    // 与上面的样式/偏移断言同属"布局契约"：布局给出每行权威高度，
    // 视图按它排版，于是"看到的那一行"就是"点得到的那一行"。

    private func layout(lineCount: Int, current: Int?,
                        base: Double = 36, currentHeight: Double = 60,
                        visible: Double = 400) -> LyricScrollLayout.Layout {
        LyricScrollLayout.make(lineCount: lineCount, currentIndex: current,
                               baseLineHeight: base, currentLineHeight: currentHeight,
                               visibleHeight: visible)
    }

    func testHeightsSumMatchesContentHeight() {
        let l = layout(lineCount: 10, current: 4)
        XCTAssertEqual(l.heights.count, 10)
        XCTAssertEqual(l.heights.reduce(0, +), l.contentHeight, accuracy: 0.001,
                       "视图按 heights 排版，它们必须与内容总高一致，否则偏移会漂")
    }

    func testOnlyTheCurrentRowUsesTheCurrentHeight() {
        let l = layout(lineCount: 5, current: 2)
        XCTAssertEqual(l.heights[2], 60)
        XCTAssertEqual(l.heights[0], 36)
        XCTAssertEqual(l.heights[4], 36)
    }

    /// 布局说"第 i 行在可视区中心"，那么把 heights 从 0 累加到第 i 行、
    /// 再减去 scrollOffset，应当正好等于可视区中心。这是点击命中的前提。
    func testCurrentRowCenterLandsOnVisibleCenter() {
        let visible = 400.0
        let l = layout(lineCount: 12, current: 5, visible: visible)
        var cursor = 0.0
        for index in 0..<5 { cursor += l.heights[index] }
        let centerInContent = cursor + l.heights[5] / 2
        let centerInView = centerInContent - l.scrollOffset
        XCTAssertEqual(centerInView, visible / 2, accuracy: 0.001,
                       "当前行必须正好落在可视区中心；差一点就会点到相邻行")
    }

    /// 没有当前行（前奏阶段）时必须对准第一行。
    ///
    /// 这条原来断言的是"对准歌词中间"——那正是 bug：13 秒前奏的《珊瑚海》
    /// 一开播就显示副歌歌词，看起来像歌词配对错了。
    func testNoCurrentLineAlignsToFirstLine() {
        let visible = 300.0
        let l = layout(lineCount: 6, current: nil, visible: visible)
        let firstCenterInContent = l.heights[0] / 2
        XCTAssertEqual(l.scrollOffset, firstCenterInContent - visible / 2, accuracy: 0.001)
    }

    /// 窄窗口下长句会折行，行高必须跟着变高，否则文字被固定行高裁掉。
    /// （这是把行高收归布局之后引入的回归，必须锁住。）
    func testWrappedLineGetsTallerRow() {
        let short = LyricScrollLayout.estimatedLines("短句", width: 200, fontSize: 17)
        let long = LyricScrollLayout.estimatedLines(String(repeating: "长", count: 60),
                                                    width: 200, fontSize: 17)
        XCTAssertEqual(short, 1)
        XCTAssertGreaterThan(long, 1, "60 个汉字在 200pt 宽里必须折行")
    }

    func testLayoutUsesEstimatedLinesForHeights() {
        let texts = ["短", String(repeating: "长", count: 60)]
        let l = LyricScrollLayout.make(lineCount: 2, currentIndex: nil,
                                       baseLineHeight: 36, currentLineHeight: 60,
                                       visibleHeight: 400,
                                       lineTexts: texts, availableWidth: 200, fontSize: 17)
        XCTAssertGreaterThan(l.heights[1], l.heights[0],
                             "长句那一行要比短句高，否则会被裁掉")
        XCTAssertEqual(l.heights.reduce(0, +), l.contentHeight, accuracy: 0.001)
    }

    func testWithoutTextsHeightsStayUniform() {
        let l = LyricScrollLayout.make(lineCount: 3, currentIndex: 1,
                                       baseLineHeight: 36, currentLineHeight: 60,
                                       visibleHeight: 400)
        XCTAssertEqual(l.heights, [36, 60, 36], "没给文本时保持原来的固定行高")
    }

    /// 当前行用的是更大字号，折行估算必须跟着放大，否则低估行数 → 行高不够 → 被截断。
    func testCurrentRowUsesItsOwnFontSizeForWrapping() {
        let long = String(repeating: "长", count: 40)
        let small = LyricScrollLayout.make(lineCount: 1, currentIndex: 0,
                                           baseLineHeight: 36, currentLineHeight: 60,
                                           visibleHeight: 400,
                                           lineTexts: [long], availableWidth: 576,
                                           fontSize: 17, currentFontSize: 32)
        let ignored = LyricScrollLayout.make(lineCount: 1, currentIndex: 0,
                                            baseLineHeight: 36, currentLineHeight: 60,
                                            visibleHeight: 400,
                                            lineTexts: [long], availableWidth: 576,
                                            fontSize: 17, currentFontSize: 0)
        XCTAssertGreaterThanOrEqual(small.heights[0], ignored.heights[0],
                                    "用大字号估算出来的行高不能比小字号更低")
        XCTAssertGreaterThan(small.heights[0], 60, "40 个汉字 × 32pt 在 576pt 宽里必然折行，行高要放大")
    }

    /// 折行只追加"多出来的行推进"，不能把整行留白一起乘。
    func testWrappedRowAddsAdvanceOnly() {
        let long = String(repeating: "长", count: 40)
        let l = LyricScrollLayout.make(lineCount: 1, currentIndex: 0,
                                       baseLineHeight: 36, currentLineHeight: 60,
                                       visibleHeight: 400,
                                       lineTexts: [long], availableWidth: 300,
                                       fontSize: 17, currentFontSize: 32)
        // 手算，而不是把生产公式再抄一遍（抄一遍等于没测）：
        //   每行容纳 300 / 32 ≈ 9.375 个全角字
        //   40 个字 → ⌈40 / 9.375⌉ = 5 行
        //   高度 = 单行 60 + (5 - 1) × 32 × 1.35 = 232.8
        XCTAssertEqual(l.heights[0], 232.8, accuracy: 0.05,
                       "折行高度 = 单行高度 + (行数-1)×行推进，不是 单行高度×行数")
    }

    /// 单行时高度必须与旧行为完全一致，避免改这里把正常版式带偏。
    func testSingleLineRowKeepsBaseHeight() {
        let l = LyricScrollLayout.make(lineCount: 2, currentIndex: 0,
                                       baseLineHeight: 36, currentLineHeight: 60,
                                       visibleHeight: 400,
                                       lineTexts: ["短句", "也短"], availableWidth: 600,
                                       fontSize: 17, currentFontSize: 32)
        XCTAssertEqual(l.heights, [60, 36])
    }

    /// 还没唱到第一句时（前奏），视图必须对准**第一行**，不能跳到歌词中间。
    ///
    /// 之前取的是 `contentHeight / 2`：播《珊瑚海》到 0:04（前奏 13 秒）时，
    /// 屏幕上是 1:44 之后的副歌歌词——看起来像"歌词配对错了"，其实只是滚动位置错了。
    func testBeforeFirstLineAlignsToFirstLine() {
        let l = LyricScrollLayout.make(lineCount: 20, currentIndex: nil,
                                       baseLineHeight: 36, currentLineHeight: 56,
                                       visibleHeight: 400)
        XCTAssertEqual(l.centers[0], 0, accuracy: 0.001,
                       "没有当前行时，第一行应当正好在可视区中心")
        XCTAssertGreaterThan(l.centers[19], 0, "后面的行应当排在下方（相对中心为正）")
    }
}
