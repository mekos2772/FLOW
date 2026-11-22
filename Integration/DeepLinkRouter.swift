import AppKit
import Foundation

/// 深链路由。
///
/// `spatiallyrics://now` —— 打开主窗口并把播放器带到前台；
/// `spatiallyrics://toggle-floating` —— 切换悬浮歌词（小组件/快捷指令可用）。
/// 不接受未知 scheme，也不做任何"猜意图"的兜底动作。
@MainActor
enum DeepLinkRouter {
    enum Action: Equatable {
        case openPlayer
        case toggleFloating
        /// 指定形态。`spatiallyrics://morph/capsule`
        case setMorphology(PlayerMorphology)
        /// 指定悬浮歌词排布。`spatiallyrics://shape/doubleLine`
        case setShape(LyricsShape)
    }

    static let scheme = DeepLinkScheme.value

    /// 小组件点空白处应当打开播放器。**小组件与 App 共用这一处构造**，
    /// 免得 scheme / host 两处各写一遍。
    static var openPlayerURL: URL? { DeepLinkScheme.openPlayer }

    static func action(for url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "now", "open", nil: return .openPlayer
        case "toggle-floating": return .toggleFloating
        case "morph":
            let name = url.pathComponents.dropFirst().first?.lowercased()
            return name.flatMap(PlayerMorphology.init(rawValue:)).map(Action.setMorphology)
        case "shape":
            let name = url.pathComponents.dropFirst().first?.lowercased()
            // 排布的 rawValue 是驼峰（doubleLine），URL 里常写成小写；
            // 这里按小写比较，避免 "spatiallyrics://shape/doubleline" 静默失效。
            return name
                .flatMap { value in LyricsShape.allCases.first { $0.rawValue.lowercased() == value } }
                .map(Action.setShape)
        default: return nil
        }
    }

    static func handle(_ url: URL,
                       floating: (any FloatingLyricsControlling)?,
                       morph: (any MorphControlling)? = nil) -> Bool {
        guard let action = action(for: url) else { return false }
        switch action {
        case .openPlayer:
            NSApp.activate(ignoringOtherApps: true)
            morph?.expand()
        case .toggleFloating:
            floating?.toggleVisibility()
        case .setMorphology(let morphology):
            morph?.setMorphology(morphology)
        case .setShape(let shape):
            morph?.setFloatingShape(shape)
        }
        return true
    }
}
