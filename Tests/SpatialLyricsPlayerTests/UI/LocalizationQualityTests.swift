import XCTest
@testable import SpatialLyricsPlayer

/// 字符串目录的**质量**门禁（不只是"键存在"）。
///
/// 第 92 节只保证"界面文案在目录里有键"。但有三件事它管不到：
/// 1. 有键但**没有英文译文** → 英文模式下显示空或回落中文；
/// 2. 英文译文里**仍是中文**（复制过去忘了翻）；
/// 3. 键本身是空串。
final class LocalizationQualityTests: XCTestCase {

    private func catalog() throws -> [String: [String: Any]] {
        let url = RepositoryRoot.locate().appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func value(_ entry: [String: Any], _ language: String) -> String? {
        guard let locals = entry["localizations"] as? [String: Any],
              let lang = locals[language] as? [String: Any],
              let unit = lang["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    func testEveryKeyHasEnglishTranslation() throws {
        var missing: [String] = []
        for (key, entry) in try catalog() where value(entry, "en") == nil {
            missing.append(key)
        }
        XCTAssertTrue(missing.isEmpty,
                      "以下键没有英文译文：\n" + missing.sorted().prefix(20).joined(separator: "\n"))
    }

    func testEnglishValuesContainNoChinese() throws {
        var leaked: [String] = []
        for (key, entry) in try catalog() {
            guard let english = value(entry, "en") else { continue }
            if english.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil {
                leaked.append("\(key) → \(english)")
            }
        }
        XCTAssertTrue(leaked.isEmpty, "英文译文里仍有中文：\n" + leaked.sorted().prefix(20).joined(separator: "\n"))
    }

    func testNoEmptyKeysOrValues() throws {
        for (key, entry) in try catalog() {
            XCTAssertFalse(key.trimmingCharacters(in: .whitespaces).isEmpty, "存在空键")
            XCTAssertFalse((value(entry, "en") ?? "").isEmpty, "英文译文为空：\(key)")
        }
    }
}
