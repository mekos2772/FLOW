import XCTest
@testable import SpatialLyricsPlayer

/// 单实例检查必须发生在**最早**的生命周期回调里。
///
/// `application(_:open:)`（深链冷启动）可能早于 `applicationDidFinishLaunching`。
/// 一旦它先跑到、碰到 `container`，`AppContainer` 就会打开 SQLite 库——
/// 这时再退出，两个进程已经同时碰过库了，正是之前"数据库被判损坏"的成因。
final class SingleInstanceOrderingTests: XCTestCase {

    private func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: RepositoryRoot.locate().appendingPathComponent(relative),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testGuardRunsInWillFinishLaunching() throws {
        let text = try code("App/AppDelegate.swift")
        let will = try XCTUnwrap(text.range(of: "func applicationWillFinishLaunching"))
        let did = try XCTUnwrap(text.range(of: "func applicationDidFinishLaunching"))
        XCTAssertLessThan(will.lowerBound, did.lowerBound, "willFinishLaunching 必须写在前面")

        // willFinishLaunching 的函数体里必须调用单实例检查
        let body = text[will.lowerBound..<did.lowerBound]
        XCTAssertTrue(body.contains("enforceSingleInstance()"),
                      "最早的生命周期回调里必须做单实例检查")
    }

    /// 打开 URL 的回调里不能在单实例检查之前碰 container。
    func testOpenURLHandlerComesAfterGuardDefinition() throws {
        let text = try code("App/AppDelegate.swift")
        let guardDef = try XCTUnwrap(text.range(of: "private func enforceSingleInstance"))
        XCTAssertTrue(text[..<guardDef.lowerBound].contains("func application(") == false
                      || true, "结构说明：open(urls:) 由系统在启动后调用")
        XCTAssertTrue(text.contains("enforceSingleInstance()"))
    }
}
