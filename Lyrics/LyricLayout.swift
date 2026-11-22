import Foundation

/// 完整播放器的歌词版式。
enum LyricLayout: String, CaseIterable, Sendable {
    /// Apple Music 风格：整段滚动、当前行居中放大、切换带弹簧跃动。
    case appleMusic
    /// 编辑式版面：只显示当前行与前后行，左侧有度量线。
    case editorial

    var displayName: String {
        switch self {
        case .appleMusic: return "滚动歌词"
        case .editorial: return "编辑式"
        }
    }
}
