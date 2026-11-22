import XCTest
@testable import SpatialLyricsPlayer

/// 小组件必须真的被**打包进 App**。
///
/// 工程里有 "Embed Foundation Extensions" 阶段，但阶段存在不等于产物正确：
/// 漏掉、路径写错、Info.plist 少 `NSExtension` 字典，都会让小组件在系统画廊里不出现，
/// 而 App 本身一切正常——这类问题只有检查**构建产物**才能发现。
final class WidgetPackagingTests: XCTestCase {

    /// 被测的那一份 App 里的扩展。
    ///
    /// 测试寄宿在 App 进程里，`Bundle.main` 就是刚构建出来、正在被测的那个 App。
    /// 之前这里写死了 `/tmp/slp-dd` 与 `/tmp/slp-release` 两个路径：
    /// 换一个构建目录就 4 条全红；更糟的是那两个目录里若留着**上一次**的产物，
    /// 测试验的就是旧包——这一版把扩展打坏了它也照样绿。
    private var builtExtension: URL? {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
        let url = plugIns.appendingPathComponent("SpatialLyricsWidgets.appex")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func plist() throws -> [String: Any] {
        let url = try XCTUnwrap(builtExtension, "被测 App 的 PlugIns 里没有小组件扩展")
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any])
    }

    func testExtensionIsEmbedded() throws {
        _ = try plist()   // 不存在就会在 XCTUnwrap 处失败
    }

    func testExtensionDeclaresWidgetKitPoint() throws {
        let nested = try XCTUnwrap(try plist()["NSExtension"] as? [String: Any],
                                   "缺少 NSExtension 字典，系统不会把它当扩展")
        XCTAssertEqual(nested["NSExtensionPointIdentifier"] as? String,
                       "com.apple.widgetkit-extension")
    }

    func testExtensionBundleTypeIsXPC() throws {
        XCTAssertEqual(try plist()["CFBundlePackageType"] as? String, "XPC!")
    }

    func testExtensionIdentifierMatchesExpectation() throws {
        XCTAssertEqual(try plist()["CFBundleIdentifier"] as? String,
                       "com.yg.spatiallyrics.widgets")
    }
}
