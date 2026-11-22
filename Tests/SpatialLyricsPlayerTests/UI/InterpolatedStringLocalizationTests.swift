import XCTest
@testable import SpatialLyricsPlayer

/// 带插值的中文文案也必须可翻译。
///
/// 第 92 节的覆盖测试只查**不带插值**的字面量。
/// SwiftUI 把 `Text("正在播放：\(title)")` 当成 `LocalizedStringKey`，
/// 生成的键是 `正在播放：%@`——目录里没有这个键，英文模式下就仍是中文。
///
/// 判定方式：把源码里的 `\(…)` 依次替换成 `%@` / `%lld`，
/// 只要**任意一种**在 `Localizable.xcstrings` 里存在就算已覆盖。
/// 剩下的（运行期拼 `String` 再交给 `Text(String)` 的）登记在 `known` 里。
final class InterpolatedStringLocalizationTests: XCTestCase {

    /// 运行期拼好的 String，目录覆盖不到；要改文案结构才能翻译，留作后续。
    private let known: Set<String> = []

    func testInterpolatedStringsAreEitherLocalizedOrKnown() throws {
        let root = RepositoryRoot.locate()
        let catalogURL = root.appendingPathComponent("Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])?["strings"] as? [String: Any])

        var uncovered: [String] = []
        for literal in try interpolatedLiterals(in: root) where !known.contains(literal) {
            let candidates = templateCandidates(for: literal)
            if candidates.contains(where: { catalog[$0] != nil }) { continue }
            uncovered.append(literal)
        }
        XCTAssertTrue(uncovered.isEmpty,
                      "以下带插值文案既没有目录模板键、也没登记：\n" + uncovered.sorted().joined(separator: "\n"))
    }

    /// 把 `\(…)` 换成 SwiftUI 会生成的占位符，给出所有候选键。
    private func templateCandidates(for literal: String) -> [String] {
        var results: [String] = []
        for placeholder in ["%@", "%lld"] {
            var template = ""
            var rest = Substring(literal)
            while let start = rest.range(of: "\\(") {
                template += rest[rest.startIndex..<start.lowerBound]
                template += placeholder
                var depth = 1
                var index = start.upperBound
                while index < rest.endIndex, depth > 0 {
                    if rest[index] == "(" { depth += 1 }
                    if rest[index] == ")" { depth -= 1 }
                    index = rest.index(after: index)
                }
                rest = rest[index...]
            }
            template += rest
            results.append(template)
        }
        return results
    }

    private func interpolatedLiterals(in root: URL) throws -> Set<String> {
        var found: Set<String> = []
        for directory in ["UI", "MenuBar"] {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base,
                                                                 includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    for match in line.matches(of: /"([^"]*[\u4e00-\u9fff][^"]*\\\([^"]*)"/) {
                        found.insert(String(match.output.1))
                    }
                }
            }
        }
        return found
    }
}
