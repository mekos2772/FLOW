import Foundation

/// 自动展开积极度（规格 规则 D："用户可以在设置中选择更积极的自动展开策略"）。
///
/// 语义只有一件事：**空间变多时，多快允许恢复到更丰富的形态**。
/// 它不改变"绝不自动打开完整播放器"这条硬规则——完整形态只能由用户意图进入。
enum AutoExpandPolicy: String, CaseIterable, Sendable, Equatable {
    /// 保守：只有在非常宽裕时才升级，适合长时间专注工作。
    case conservative
    /// 标准：默认值，留一点余量再升级，避免临界空间来回跳。
    case balanced
    /// 积极：一有空间就恢复，适合希望歌词更完整的场景。
    case eager

    /// 映射到引擎的 `minimumPromotionImprovement`（空间余量阈值）。
    var promotionImprovement: Double {
        switch self {
        case .conservative: return 0.32
        case .balanced: return 0.18
        case .eager: return 0.06
        }
    }

    var displayName: String {
        switch self {
        case .conservative: return "保守"
        case .balanced: return "标准"
        case .eager: return "积极"
        }
    }

    var detail: String {
        switch self {
        case .conservative: return "空间很宽裕才恢复，长期专注时更安静。"
        case .balanced: return "留一点余量再恢复，临界空间不会来回跳。"
        case .eager: return "有空间就恢复，歌词更完整但形态变化更频繁。"
        }
    }
}
