import XCTest
@testable import SpatialLyricsPlayer

/// 歌词动画手感的契约。
///
/// 参考实现（HuangRunHua/Apple-Music-Lyric-Animation）用的是 `List` + `.linear`，
/// 没有可借鉴的弹簧数值；所以不抄数字，而是把**我们现在这套**量化并锁住，
/// 走的是已有的 `SpringSpec` 解析模型（不另写一套公式）。
final class LyricSpringFeelTests: XCTestCase {

    private var lineSpring: SpringSpec { .swiftUI(response: 0.34, bounce: 0.30) }
    private var scrollSpring: SpringSpec { .swiftUI(response: 0.44, bounce: 0.18) }

    /// 注意：`SpringSpec.settlingDuration` 用的是 **0.1% 误差带**（比常见的 2% 严格得多），
    /// 同一组参数在 2% 带下约 0.31s、在 0.1% 带下约 0.53s。阈值按 0.1% 带写。
    func testLineSpringHasVisibleButRestrainedBounce() {
        let overshoot = lineSpring.peakProgress - 1
        XCTAssertGreaterThan(overshoot, 0.02, "完全没有回弹会显得发木")
        XCTAssertLessThan(overshoot, 0.10, "回弹超过 10% 会让字明显越过位置")
        XCTAssertLessThan(lineSpring.settlingDuration, 0.80, "行切换要在一个乐句内稳定")
    }

    func testScrollSpringIsNearlyCriticallyDamped() {
        let overshoot = scrollSpring.peakProgress - 1
        XCTAssertLessThan(overshoot, 0.03, "整块滚动几乎不该弹，否则满屏字一起晃")
        XCTAssertGreaterThan(scrollSpring.settlingDuration, 0.40, "太快会显得生硬")
        XCTAssertLessThan(scrollSpring.settlingDuration, 1.20, "整块滚动拖太久会跟不上唱")
    }

    func testScrollIsCalmerThanLineSwitch() {
        XCTAssertGreaterThan(lineSpring.peakProgress, scrollSpring.peakProgress,
                             "行切换应当比整块滚动更有弹性")
    }

    /// SwiftUI 的 `bounce` 与阻尼比互补，映射错了整套手感都会跑偏。
    func testSwiftUISpringMapping() {
        XCTAssertEqual(SpringSpec.swiftUI(response: 0.5, bounce: 0).dampingRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(SpringSpec.swiftUI(response: 0.5, bounce: 0.2).dampingRatio, 0.8, accuracy: 1e-9)
        XCTAssertEqual(SpringSpec.swiftUI(response: 0.5, bounce: 0.2).response, 0.5, accuracy: 1e-9)
    }
}
