import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 可点击列表行的无障碍契约。
///
/// `FlowRow` 原来只用 `.onTapGesture` —— 看着能点，但**没有按钮语义**：
/// VoiceOver 不会说"可点击"，键盘也聚焦不到。这是 SwiftUI 最典型的无障碍坑。
/// 改为 `Button` 后，语义与键盘操作都由系统接管。
///
/// 这里做静态结构断言（离屏渲染无法查询 AX 角色）。
@MainActor
final class RowAccessibilityTests: XCTestCase {

    /// 读源码并**剔除整行注释**。
    ///
    /// 直接扫原文会命中注释里的 `.onTapGesture`（本轮就发生了：
    /// 我在注释里解释"为什么不要用它"，结果被自己的测试判红）。
    /// 规则该管代码，不该管文档。
    private func source(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testFlowRowUsesButtonNotTapGesture() throws {
        let text = try source("DesignSystem/FlowComponents.swift")
        let rowStart = try XCTUnwrap(text.range(of: "struct FlowRow"))
        let slice = String(text[rowStart.lowerBound...].prefix(2000))

        XCTAssertTrue(slice.contains("Button(action: action)"),
                      "可点击行必须是 Button，才有按钮语义与键盘支持")
        XCTAssertFalse(slice.contains(".onTapGesture"),
                       "不要再退回 onTapGesture——辅助技术看不见它")
    }

    /// 其它可点击行也应如此（`SongRow` 播放区使用 Button）。
    func testTrackRowUsesButton() throws {
        let text = try source("UI/Expanded/SongRow.swift")
        XCTAssertTrue(text.contains("Button(action: onPlay)"))
        XCTAssertFalse(text.contains(".onTapGesture"))
    }
}
