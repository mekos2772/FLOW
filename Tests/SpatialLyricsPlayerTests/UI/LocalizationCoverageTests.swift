import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 字符串目录的**覆盖率门禁**。
///
/// 中文源码里 `Text("中文")` 天然可以当 key，所以中文模式永远正常——
/// 真正的坑在英文模式：没进目录的字面量会**原样露中文**。
/// 审阅时实测有 39 条漏网（扫码登录、刷新、显示更多……）。
///
/// 这条测试把"新增界面文案必须进目录"变成可检查的约束。
final class LocalizationCoverageTests: XCTestCase {

    private var catalogURL: URL {
        RepositoryRoot.locate().appendingPathComponent("Resources/Localizable.xcstrings")
    }

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = object["strings"] as? [String: Any] ?? [:]
        return Set(strings.keys)
    }

    private func chineseLiterals() throws -> [String: String] {
        let root = RepositoryRoot.locate()
        // 除系统控件外，自定义组件里接收 LocalizedStringKey 的参数同样会查表
        // （设置行的标题/摘要/说明、分区标题、文字按钮、图标按钮的无障碍名、确认框……）。
        // 之前只扫 Text/Button 等，设置页近百条文案漏网而门禁一直是绿的。
        let calls = "Text|Button|Label|Toggle|Picker|TextField|SecureField|FlowCaption|SectionLabel|FlowTextButton|SettingsGroup|SettingsRow|confirmationDialog|alert|help|sliderRow"
        let patterns = try [
            NSRegularExpression(pattern: #"(?:"# + calls + #")\(\s*"([^"\\]{2,})""#),
            NSRegularExpression(pattern: #"\b(?:title|detail|explanation|label|text|message):\s*"([^"\\]{2,})""#),
        ]
        var found: [String: String] = [:]
        for folder in ["UI", "Morph", "MenuBar"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in patterns.flatMap({ $0.matches(in: text, range: range) }) {
                    guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                    let literal = String(text[swiftRange])
                    guard literal.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil else { continue }
                    found[literal] = url.lastPathComponent
                }
            }
        }
        return found
    }

    func testEveryChineseLiteralIsInCatalog() throws {
        let keys = try catalogKeys()
        let literals = try chineseLiterals()
        XCTAssertFalse(literals.isEmpty, "扫描逻辑失效：一个中文字面量都没找到")

        let missing = literals.filter { !keys.contains($0.key) }
        let report = missing.map { "「\($0.key)」← \($0.value)" }.sorted().joined(separator: "\n")
        XCTAssertTrue(missing.isEmpty,
                      "以下界面文案没进字符串目录（英文模式下会露中文）：\n\(report)")
    }

    func testCatalogIsBilingual() throws {
        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = object["strings"] as? [String: Any] ?? [:]
        var missingEnglish: [String] = []
        for (key, value) in strings {
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            if localizations["en"] == nil { missingEnglish.append(key) }
        }
        XCTAssertTrue(missingEnglish.isEmpty,
                      "这些条目缺英文翻译：\(missingEnglish.prefix(10))")
    }
}
