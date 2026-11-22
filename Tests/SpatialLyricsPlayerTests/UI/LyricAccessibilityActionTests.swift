import XCTest
@testable import SpatialLyricsPlayer

/// 歌词行点击的**无障碍等价物**。
///
/// 鼠标点歌词某一句会跳过去播放；VoiceOver 用户没有鼠标，
/// 如果这里不挂 `accessibilityAction`，这个能力对他们就不存在。
///
/// 歌词行不该变成一排按钮（读起来会很吵），所以用**自定义操作**补——
/// 元素仍是文本，聚焦后可以执行"从这一句开始播放"。
final class LyricAccessibilityActionTests: XCTestCase {

    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testLyricScrollViewLinesOfferSeekAction() throws {
        let text = try code("UI/Expanded/LyricScrollView.swift")
        let count = text.components(separatedBy: "accessibilityAction(named: Text(\"从这一句开始播放\"))").count - 1
        // 统一行容器 `row(...)` 内通过 `primaryRowText` 切换逐字高亮与静态行，共享外层无障碍跳转操作
        XCTAssertTrue(text.contains("primaryRowText(line: line, text: text, isCurrent: style.isCurrent"),
                      "逐字当前行与普通行应共用统一行渲染或各自声明自定义操作")
        XCTAssertEqual(count, 1, "主歌词统一行容器应挂载自定义跳转操作，实际 \(count) 处")
    }

    func testNeighborLinesOfferSeekAction() throws {
        let text = try code("UI/Expanded/LyricFieldView.swift")
        XCTAssertTrue(text.contains("accessibilityAction(named: Text(\"从这一句开始播放\"))"),
                      "相邻行可点击跳转，也要有无障碍等价物")
    }
}
