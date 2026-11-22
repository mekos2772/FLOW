import XCTest
@testable import SpatialLyricsPlayer

/// App Group 标识的**一致性**。
///
/// 代码里的 `AppGroup.identifier` 与两个 entitlements 文件必须完全一致：
/// 一旦不一致，`containerURL` 返回 nil → 小组件读不到数据，
/// 而主 App 一切正常，看不出任何异常（只能靠诊断里那行"共享不可用"察觉）。
final class AppGroupConsistencyTests: XCTestCase {

    private var repoRoot: URL { RepositoryRoot.locate() }

    private func groupIdentifiers(inEntitlements path: String) throws -> [String] {
        let url = repoRoot.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try XCTUnwrap(object as? [String: Any], "entitlements 不是字典")
        return plist["com.apple.security.application-groups"] as? [String] ?? []
    }

    func testAppEntitlementsDeclareTheSameGroup() throws {
        let groups = try groupIdentifiers(inEntitlements: "Config/App.entitlements")
        XCTAssertTrue(groups.contains(AppGroup.identifier),
                      "App.entitlements 缺少 \(AppGroup.identifier)，实际：\(groups)")
    }

    func testWidgetEntitlementsDeclareTheSameGroup() throws {
        let groups = try groupIdentifiers(inEntitlements: "Config/Widget.entitlements")
        XCTAssertTrue(groups.contains(AppGroup.identifier),
                      "Widget.entitlements 缺少 \(AppGroup.identifier)，实际：\(groups)")
    }

    func testSnapshotFileNameIsShared() {
        XCTAssertEqual(AppGroup.snapshotFileName, "playback-snapshot.json",
                       "文件名两端共用，改动会同时影响 App 与小组件")
    }
}
