import Foundation

/// 右上角三档：普通（完整播放器）/ 悬浮（桌面歌词胶囊）/ 沉浸（场景铺满）。
///
/// 不是新的窗口形态，而是用户能理解的三种用法到"形态 + 沉浸标志"的映射：
/// 迷你条、贴边这些悬浮形态都算「悬浮」。
enum PlayerMode: String, CaseIterable, Sendable, Equatable {
    case normal
    case floating
    case immersive

    var displayName: String {
        switch self {
        case .normal: return String(localized: "普通")
        case .floating: return String(localized: "悬浮")
        case .immersive: return String(localized: "沉浸")
        }
    }

    static func current(morphology: PlayerMorphology, isImmersive: Bool) -> PlayerMode {
        guard morphology == .expanded else { return .floating }
        return isImmersive ? .immersive : .normal
    }
}
