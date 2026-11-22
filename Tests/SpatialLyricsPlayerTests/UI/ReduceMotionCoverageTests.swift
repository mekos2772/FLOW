import XCTest
@testable import SpatialLyricsPlayer

/// 界面里的动画都要尊重"减弱动态效果"。
///
/// 系统打开这个开关的用户，对位移/缩放/弹簧特别敏感。
/// 项目里统一用 `Motion.respectingReduceMotion`，但有几次漏了——
/// 换曲时的封面/标题/艺人三级淡入就是漏的三处。
final class ReduceMotionCoverageTests: XCTestCase {

    /// 允许不带缩放的纯透明度动画直接使用，但要**显式登记**。
    private var allowlist: [(file: String, snippet: String)] { [] }

    func testEveryAnimationRespectsReduceMotion() throws {
        var offenders: [String] = []
        for path in pathlibSwiftFiles(under: "UI") + pathlibSwiftFiles(under: "MenuBar") {
            let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
            for (index, line) in lines.enumerated() {
                let text = String(line)
                guard text.contains(".animation(") else { continue }
                guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                // 两种写法都算合规：`Motion.respectingReduceMotion(...)` 与
                // 三元 `reduceMotion ? nil : ...`（后者在歌词滚动里更直观）。
                if text.contains("respectingReduceMotion") || text.contains("reduceMotion ?") { continue }
                // 跨行写法：属性名在上一行
                if index > 0, String(lines[index - 1]).contains("respectingReduceMotion") { continue }
                offenders.append("\(path.lastPathComponent):\(index + 1)  \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "以下动画没有经过 respectingReduceMotion：\n" + offenders.joined(separator: "\n"))
    }

    private func pathlibSwiftFiles(under directory: String) -> [URL] {
        let root = RepositoryRoot.locate().appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
