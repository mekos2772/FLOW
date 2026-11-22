import XCTest
@testable import SpatialLyricsPlayer

/// 到点淡出时长的存储范围。
///
/// 界面只提供 0 / 300 / 600 / 1000 四档，但**存储范围是 0…3000**：
/// 导入的备份、旧版本写下的值都可能落在中间。
/// 之前这个 3000 在读写两处各写了一遍，没有进 `SettingsLimits`——
/// 和另外五项设置的处理方式不一致，迟早会漂。
final class FadeOutLimitTests: XCTestCase {

    func testRangeIsDeclaredOnce() {
        XCTAssertEqual(SettingsLimits.fadeOutMillis, 0...3000)
    }

    /// 界面能选的每一档都必须落在存储范围内。
    func testUIOptionsAreWithinStorageRange() {
        for option in [0, 300, 600, 1000] {
            XCTAssertTrue(SettingsLimits.fadeOutMillis.contains(option),
                          "界面选项 \(option) 超出了存储范围")
        }
    }

    /// 越界的写入要被夹紧（含备份导入路径）。
    func testOutOfRangeWriteIsClamped() async {
        let store = InMemorySettingsStore()
        await store.setFadeOutMillis(99_999)
        XCTAssertEqual(store.fadeOutMillis, 3000)
        await store.setFadeOutMillis(-5)
        XCTAssertGreaterThanOrEqual(store.fadeOutMillis, 0)
    }
}
