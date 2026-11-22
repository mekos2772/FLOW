import SwiftUI

private struct AppContainerEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppContainer? = nil
}

extension EnvironmentValues {
    /// 依赖容器。表现层通过它取协议，不取实现。
    var app: AppContainer? {
        get { self[AppContainerEnvironmentKey.self] }
        set { self[AppContainerEnvironmentKey.self] = newValue }
    }
}
