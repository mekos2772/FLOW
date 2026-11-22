import Foundation
import ServiceManagement

/// 开机启动（P1）。
///
/// 用 `SMAppService.mainApp`——这是 macOS 13+ 的公开接口，沙盒内可用。
/// 注意：注册是否成功**只有真机签名后才有意义**；未签名的开发构建会返回错误，
/// 所以这里把错误原样抛给调用方，由界面如实显示，而不是假装成功。
@MainActor
struct LaunchAtLogin {
    enum Failure: Error, Equatable, LocalizedError {
        case registrationFailed(String)

        /// 必须实现 `LocalizedError`。
        ///
        /// 否则 `error.localizedDescription` 给的是系统通用串
        /// （`The operation couldn't be completed. (…Failure error 0.)`），
        /// 而设置页正是把它显示给用户的——等于把技术串倒到界面上。
        var errorDescription: String? {
            switch self {
            case let .registrationFailed(reason):
                return String(localized: "系统拒绝了开机启动：\(reason)。可以到「系统设置 → 通用 → 登录项」里手动打开。")
            }
        }
    }

    /// 系统当前是否已登记本 App 为登录项。
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 用户在系统设置里关过本 App 的登录项后，注册会停在「待批准」，需要用户去系统设置里打开。
    var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func openSystemLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw Failure.registrationFailed(error.localizedDescription)
        }
    }
}
