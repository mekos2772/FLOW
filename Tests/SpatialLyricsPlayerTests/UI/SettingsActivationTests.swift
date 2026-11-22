import XCTest
@testable import SpatialLyricsPlayer

/// 打开设置前必须先激活 App。
///
/// 「隐藏 Dock 图标」把 App 变成 `.accessory` 策略。这种策略下直接调
/// `openSettings()`，设置窗口可能出现在其它窗口**后面**——用户看到的是
/// "点了设置但什么都没发生"。深链打开播放器时已经这么做过（先 `activate`），
/// 设置按钮漏了同一步。
final class SettingsActivationTests: XCTestCase {

    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testSettingsIsOpenedAfterActivation() throws {
        let text = try code("MenuBar/MenuBarView.swift")
        let activate = try XCTUnwrap(text.range(of: "NSApp.activate"),
                                     "打开设置前没有激活 App")
        let open = try XCTUnwrap(text.range(of: "openSettings()"),
                                 "找不到 openSettings 调用")
        XCTAssertLessThan(activate.lowerBound, open.lowerBound,
                          "必须先 activate 再 openSettings")
    }

    /// 深链那条路径也要保持同样的顺序。
    func testDeepLinkAlsoActivatesFirst() throws {
        let text = try code("Integration/DeepLinkRouter.swift")
        let activate = try XCTUnwrap(text.range(of: "NSApp.activate"))
        let expand = try XCTUnwrap(text.range(of: "morph?.expand()"))
        XCTAssertLessThan(activate.lowerBound, expand.lowerBound)
    }
}
