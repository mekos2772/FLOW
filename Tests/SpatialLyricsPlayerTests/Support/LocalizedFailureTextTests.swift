import XCTest
@testable import SpatialLyricsPlayer

/// 自定义错误必须是"人话"。
///
/// 设置页会把 `error.localizedDescription` 直接显示给用户
/// （`无法修改登录项：…`、`导出失败：…`）。
/// 自定义 `enum Failure: Error` 如果不实现 `LocalizedError`，
/// 显示出来的就是系统通用串：
/// `The operation couldn't be completed. (SpatialLyricsPlayer.LaunchAtLogin.Failure error 0.)`
final class LocalizedFailureTextTests: XCTestCase {

    func testLaunchAtLoginFailureIsHumanReadable() {
        let failure = LaunchAtLogin.Failure.registrationFailed("Operation not permitted")
        let text = failure.localizedDescription

        XCTAssertFalse(text.contains("couldn't be completed"),
                       "不能把系统通用串显示给用户：\(text)")
        XCTAssertFalse(text.contains("error 0"),
                       "不能把错误编号显示给用户：\(text)")
        XCTAssertTrue(text.contains("登录项") || text.contains("系统拒绝"),
                      "要说明发生了什么：\(text)")
        XCTAssertTrue(text.contains("Operation not permitted"),
                      "底层原因要保留，便于用户反馈：\(text)")
    }

    func testRestoreErrorIsHumanReadable() {
        let badVersion = SettingsBackup.RestoreError.unsupportedVersion(99)
        XCTAssertFalse(badVersion.localizedDescription.contains("couldn't be completed"))

        let malformed = SettingsBackup.RestoreError.malformed
        XCTAssertTrue(malformed.localizedDescription.contains("JSON"),
                      "要说明文件哪里不对：\(malformed.localizedDescription)")
    }
}
