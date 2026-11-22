import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 逐字高亮多行折行（`LyricWordHighlight` + `LyricScrollView`）与外文歌双语对照译文测试。
final class BilingualAndWrapLyricsTests: XCTestCase {

    // MARK: - Word-by-Word Highlighting for Wrapped Lines

    func testWordHighlightRunsCoalesceAndInterpolateSubWordAcrossWrappedLines() {
        let line = LyricLine(
            start: 10,
            end: 16,
            text: "Couldn't beat her smile across the crowded room tonight",
            segments: [
                LyricSegment(start: 10, text: "Couldn't "),
                LyricSegment(start: 12, text: "beat "),
                LyricSegment(start: 14, text: "her smile across the crowded room tonight"),
            ]
        )

        let before = LyricWordHighlight.runs(for: line, at: 9.5)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].text, line.text)
        XCTAssertEqual(before[0].progress, 0.0, accuracy: 0.001)

        // 第 2 个词进行到一半（beat = 4 个字母，progress = 0.5 -> "be" 全亮，"a" 半亮，"t..." 未亮）。
        let mid = LyricWordHighlight.runs(for: line, at: 13.0)
        XCTAssertEqual(mid.map(\.text).joined(), line.text)
        XCTAssertEqual(mid.first?.text, "Couldn't be")
        XCTAssertEqual(mid.first?.progress ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(mid.last?.progress ?? -1, 0.0, accuracy: 0.001)

        let after = LyricWordHighlight.runs(for: line, at: 16.5)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].text, line.text)
        XCTAssertEqual(after[0].progress, 1.0, accuracy: 0.001)

        let attr = LyricWordHighlight.attributedString(for: line, at: 13.0)
        XCTAssertEqual(String(attr.characters), line.text)
    }

    // MARK: - AMLL TTML & LRC Bilingual Preservation

    func testAMLLParserPreservesTranslationAndRomanizationWhileKeepingTextPure() throws {
        let xml = """
        <tt><body><div>
          <p begin="00:01.000" end="00:05.000">
            <span begin="00:01.000" end="00:02.500">無敵</span><span begin="00:02.500" end="00:03.200">の</span><span begin="00:03.200" end="00:04.500">笑顔</span>
            <span ttm:role="x-translation" xml:lang="zh-TW">無敵的笑容</span>
            <span ttm:role="x-roman">muteki no egao</span>
            <span ttm:role="x-bg"><span begin="00:04.500">yeah</span></span>
          </p>
        </div></body></tt>
        """
        let lines = AMLLTTMLParser.parse(xml)
        let line = try XCTUnwrap(lines.first)

        XCTAssertEqual(line.text, "無敵の笑顔", "日文正文原样保留")
        XCTAssertEqual(line.translation, "无敌的笑容", "中文译文即便是繁中来源也应在日文歌里转为简体")
        XCTAssertEqual(line.romanization, "muteki no egao")
        XCTAssertEqual(line.segments.map(\.text).joined(), "無敵の笑顔")

        // 旧缓存（无 translation/romanization 字段）向后兼容解码，新版全字段往返保留。
        let encoded = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(LyricLine.self, from: encoded)
        XCTAssertEqual(decoded.translation, "无敌的笑容")
        XCTAssertEqual(decoded.romanization, "muteki no egao")

        let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","start":1,"text":"hello"}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(LyricLine.self, from: legacyJSON)
        XCTAssertNil(legacyDecoded.translation)
        XCTAssertNil(legacyDecoded.romanization)
    }

    func testLRCParserAttachesBilingualTranslationAndNormalizesDocument() throws {
        let lrc = """
        [00:12.00]Walking through the neon rain
        [00:12.00]穿過霓虹雨夜
        [00:18.00]Same text line
        [00:18.00]Same text line
        """
        let parsed = try XCTUnwrap(LRCParser.parse(lrc))
        XCTAssertEqual(parsed.lines.count, 2)
        XCTAssertEqual(parsed.lines[0].text, "Walking through the neon rain")
        XCTAssertEqual(parsed.lines[0].translation, "穿过霓虹雨夜")
        XCTAssertNil(parsed.lines[1].translation, "相同文本不应重复挂为译文")

        let doc = LyricsDocument(trackIdentity: TrackIdentity(sourceID: .mock, externalID: "b1"),
                                 lines: parsed.lines)
        let normalized = TextNormalizer.simplified(document: doc)
        XCTAssertEqual(normalized.lines[0].translation, "穿过霓虹雨夜")
    }

    // MARK: - Layout & Appearance Integration

    func testLyricScrollLayoutAccountsForTranslationHeight() {
        let texts = [
            "Never gonna give you up when the night gets cold and long",
            "Second line",
        ]
        let noTrans = LyricScrollLayout.make(
            lineCount: 2,
            currentIndex: 0,
            baseLineHeight: 36,
            currentLineHeight: 54,
            visibleHeight: 400,
            lineTexts: texts,
            availableWidth: 260,
            fontSize: 17,
            currentFontSize: 32,
            translationTexts: []
        )
        let withTrans = LyricScrollLayout.make(
            lineCount: 2,
            currentIndex: 0,
            baseLineHeight: 36,
            currentLineHeight: 54,
            visibleHeight: 400,
            lineTexts: texts,
            availableWidth: 260,
            fontSize: 17,
            currentFontSize: 32,
            translationTexts: ["绝不会在你寒冷漫长的夜晚放弃你", "第二句"],
            translationFontSize: 15
        )
        XCTAssertGreaterThan(withTrans.heights[0], noTrans.heights[0])
        XCTAssertGreaterThan(withTrans.heights[1], noTrans.heights[1])
        XCTAssertGreaterThan(withTrans.contentHeight, noTrans.contentHeight)
    }

    @MainActor
    func testAppearanceSettingsAndRenderProbesForWrappedKaraokeAndBilingualViews() async {
        let store = InMemorySettingsStore()
        let appearance = AppearanceSettings(settings: store)
        XCTAssertTrue(appearance.showLyricTranslation)

        appearance.setShowLyricTranslation(false)
        for _ in 0..<50 where store.showLyricTranslation {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.showLyricTranslation)

        let line = LyricLine(
            start: 0,
            end: 8,
            text: "This long word-timed sentence wraps cleanly across multiple lines without truncation",
            segments: [
                LyricSegment(start: 0, text: "This long "),
                LyricSegment(start: 2, text: "word-timed sentence "),
                LyricSegment(start: 4, text: "wraps cleanly across "),
                LyricSegment(start: 6, text: "multiple lines without truncation"),
            ],
            translation: "这句很长的逐字歌词会自动折成多行而不会被截断"
        )
        let model = MorphPresentationModel()
        model.track = .mock(externalID: "wrap-1", title: "Wrap Song", artist: "Artist")
        model.lyricState = .loaded
        model.showLyricTranslation = true
        model.lyric = LyricEngine.Snapshot(
            current: line,
            next: LyricLine(start: 8, end: 12, text: "Next line", translation: "下一句译文"),
            previous: nil,
            progressInLine: 0.45,
            time: 3.5,
            index: 0,
            totalLines: 2,
            unsyncedLines: []
        )
        XCTAssertEqual(model.currentLyricTranslation, "这句很长的逐字歌词会自动折成多行而不会被截断")

        func renderBytes(_ view: some View, width: CGFloat, height: CGFloat) -> Data? {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, .dark))
            renderer.scale = 1
            return renderer.nsImage?.tiffRepresentation
        }

        let scrollImg = renderBytes(LyricScrollView(model: model, providedLines: [line]), width: 320, height: 340)
        let fieldImg = renderBytes(LyricFieldView(model: model), width: 360, height: 280)
        let doubleWithTrans = renderBytes(DoubleLineLyricsView(model: model, onExpand: {}), width: 360, height: 64)
        let boardWithTrans = renderBytes(BoardLyricsView(model: model, onExpand: {}), width: 320, height: 180)

        XCTAssertNotNil(scrollImg)
        XCTAssertNotNil(fieldImg)
        XCTAssertNotNil(doubleWithTrans)
        XCTAssertNotNil(boardWithTrans)

        model.showLyricTranslation = false
        XCTAssertNil(model.currentLyricTranslation)
        let doubleWithoutTrans = renderBytes(DoubleLineLyricsView(model: model, onExpand: {}), width: 360, height: 64)
        XCTAssertNotEqual(doubleWithTrans, doubleWithoutTrans, "开关译文后双行悬浮歌词渲染结果必须产生可观测差异")
    }

    func testLastLineWithoutEndTimeDoesNotIlluminatePrematurelyAndJapaneseKanjiLRCPreservesTranslation() {
        // 1) 末行 end == nil 时，未唱到的段绝不能因为 nextStart == time 而提前点亮
        let tailLine = LyricLine(
            start: 100,
            end: nil,
            text: "尾声",
            segments: [
                LyricSegment(start: 100, text: "尾"),
                LyricSegment(start: 101, text: "声"),
            ]
        )
        let earlyRuns = LyricWordHighlight.runs(for: tailLine, at: 100.4)
        XCTAssertEqual(earlyRuns.count, 2)
        XCTAssertEqual(earlyRuns[0].text, "尾")
        XCTAssertGreaterThan(earlyRuns[0].progress, 0.0)
        XCTAssertEqual(earlyRuns[1].text, "声")
        XCTAssertEqual(earlyRuns[1].progress, 0.0, accuracy: 0.001, "未到达最后字起始时间前 progress 必须为 0")
        XCTAssertLessThan(tailLine.filledFraction(at: 100.4) ?? 1.0, 0.6)

        // 2) 日文（含汉字）与韩文同时间戳中文译文均应被正确识别并转简体，同时保留原句假名/汉字
        let jaLRC = """
        [00:10.00]夢の灯りが見えた
        [00:10.00]看見了夢境的光芒
        [00:15.00]사랑해요
        [00:15.00]我愛你
        """
        let parsed = LRCParser.parse(jaLRC)
        XCTAssertEqual(parsed?.lines.count, 2)
        XCTAssertEqual(parsed?.lines[0].text, "夢の灯りが見えた")
        XCTAssertEqual(parsed?.lines[0].translation, "看见了梦境的光芒")
        XCTAssertEqual(parsed?.lines[1].text, "사랑해요")
        XCTAssertEqual(parsed?.lines[1].translation, "我爱你")

        // 3) 日文译文不得被繁转简损坏
        let doc = LyricsDocument(
            trackIdentity: TrackIdentity(sourceID: .mock, externalID: "ja-trans"),
            lines: [LyricLine(start: 0, text: "夢", translation: "君の笑顔と気が")]
        )
        let normalized = TextNormalizer.simplified(document: doc)
        XCTAssertEqual(normalized.lines.first?.translation, "君の笑顔と気が")
    }
}
