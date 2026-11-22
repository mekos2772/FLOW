import XCTest
@testable import SpatialLyricsPlayer

/// 深链 scheme：**代码常量**与 **Info.plist 声明**必须一致。
///
/// 不一致的后果是静默的：系统不会把 `spatialrics://…` 交给 App，
/// 于是小组件点击（第 136 节）什么都不发生，而 App 一切正常。
/// 这类"两处必须一致"的配置，靠人眼比对不可靠——用测试钉住。
final class URLSchemeConsistencyTests: XCTestCase {

    private var repoRoot: URL { RepositoryRoot.locate() }

    private func declaredSchemes() throws -> [String] {
        let url = repoRoot.appendingPathComponent("Config/App-Info.plist")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    func testInfoPlistDeclaresTheSharedScheme() throws {
        let schemes = try declaredSchemes()
        XCTAssertTrue(schemes.contains(DeepLinkScheme.value),
                      "Info.plist 未声明 \(DeepLinkScheme.value)，实际：\(schemes)。"
                      + "缺了它，小组件点击与所有深链都不会被系统转交给 App。")
    }

    /// 构建产物里的 Info.plist 也要有（防止只改了源文件却没进 bundle）。
    func testBuiltAppDeclaresItToo() throws {
        let built = URL(fileURLWithPath: "/tmp/slp-dd/Build/Products/Debug/SpatialLyricsPlayer.app/Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw XCTSkip("尚未构建 Debug 产物，跳过（CI 里先构建再跑即可）")
        }
        let data = try Data(contentsOf: built)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(DeepLinkScheme.value),
                      "构建产物缺少 scheme \(DeepLinkScheme.value)，实际：\(schemes)")
    }
}
