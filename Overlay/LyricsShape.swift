import CoreGraphics
import Foundation

/// 悬浮歌词的四种形态。
///
/// 形态决定"占多大、像什么"，不决定"放哪儿"——放置由空间求解器决定，
/// 这样形态系统与避让引擎才能各自独立演进、独立测试。
enum LyricsShape: String, Codable, CaseIterable, Sendable {
    case capsule      // 胶囊：单行 + 细进度线，适合屏幕上方窄条
    case edge         // 贴边单行：最省空间，适合左右边缘
    case doubleLine   // 双行：当前行 + 下一行，无背景
    case board        // 歌词板：多行 + 磨砂底，适合大片空白

    /// 设置页与菜单里展示的名字。
    var displayName: String {
        switch self {
        case .capsule: return "胶囊"
        case .edge: return "贴边单行"
        case .doubleLine: return "双行"
        case .board: return "歌词板"
        }
    }

    var preferredSize: CGSize {
        switch self {
        case .capsule: return CGSize(width: 380, height: 46)
        case .edge: return CGSize(width: 340, height: 38)
        case .doubleLine: return CGSize(width: 440, height: 104)
        case .board: return CGSize(width: 460, height: 210)
        }
    }

    /// 该形态能压缩到的最小尺寸，用于空间不足时降级。
    var minimumSize: CGSize {
        switch self {
        case .capsule: return CGSize(width: 220, height: 40)
        case .edge: return CGSize(width: 180, height: 32)
        case .doubleLine: return CGSize(width: 260, height: 84)
        case .board: return CGSize(width: 300, height: 140)
        }
    }

    var next: LyricsShape {
        let all = LyricsShape.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
