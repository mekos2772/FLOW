import Foundation

/// 播放错误的面向用户表述。
///
/// 规格 8.4 要求"不能静默吞掉异常"：错误必须有**明确的文案**和**可执行的下一步**。
/// 文案放在 Core 里而不是视图里，是因为同一句话要给完整播放器、胶囊、菜单栏三处用，
/// 各写一份迟早会出现"同一个错误三种说法"。
///
/// 措辞以**在线音乐**为准：音源只有 B 站，没有"文件""导入""授权文件"这些概念。
/// （早期版本支持本地文件，文案里一度还在让用户"重新导入这个文件"。）
extension PlaybackError {
    /// 一句话标题，短到能塞进胶囊。
    var title: String {
        switch self {
        case .sourceUnavailable: return String(localized: "暂时播不了")
        case .decodeFailed: return String(localized: "音频解不开")
        case .networkDisabled: return String(localized: "联网已关闭")
        case .networkUnavailable: return String(localized: "网络不可用")
        case .unsupportedFormat(let format):
            return String(localized: "不支持的格式（\(format.rawValue.uppercased())）")
        case .cancelled: return String(localized: "已取消")
        case .rightsRestricted: return String(localized: "没有播放权限")
        case .songNotVerified: return String(localized: "歌曲尚未确认")
        case .unknown: return String(localized: "播放失败")
        }
    }

    /// 一句解释：用户能看懂的原因 + 下一步，不带内部术语。
    var detail: String {
        switch self {
        case .sourceUnavailable:
            return String(localized: "没能取到这首歌的音频。可以重试，或者换一首。")
        case .decodeFailed:
            // 不把 `reason` 拼进来：它来自 AVFoundation，长这样——
            // "The operation couldn't be completed. (AVFoundationErrorDomain error -11800.)"
            // 用户看不懂，还显得 App 很粗糙。原因仍保留在 `PlaybackError.decodeFailed(reason:)`
            // 里供日志与诊断使用，只是不直接显示。
            return String(localized: "下载下来的音频读不出来。重试会重新下载，也可以换一首。")
        case .networkDisabled:
            return String(localized: "到 设置 → 通用 打开「允许联网」后就能播放。")
        case .networkUnavailable:
            return String(localized: "检查一下网络连接，恢复后会自动接着播。")
        case .unsupportedFormat:
            return String(localized: "这条音频的格式解不了，跳过它听下一首。")
        case .cancelled:
            return String(localized: "播放被取消了，可以直接重试。")
        case .rightsRestricted:
            return String(localized: "当前音源需要登录或更高权限才能播放该曲目，请到 设置 → 音源 中检查账号状态。")
        case .songNotVerified:
            return String(localized: "未能确认这是歌曲。请稍后重试，或选择已确认的歌曲。")
        case .unknown(let reason):
            // 只有**我们自己写的中文原因**才给用户看（风控、稿件下架…）；
            // 系统框架吐出来的英文错误串一律不上屏。
            return Self.isPresentable(reason) ? reason : String(localized: "可以重试，或者跳过这一首。")
        }
    }

    /// `reason` 是否是一句可以直接给用户看的话。
    ///
    /// 判据很朴素：含汉字、不长、不带错误域/错误码的痕迹。
    static func isPresentable(_ reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return false }
        guard !trimmed.contains("Domain"), !trimmed.contains("error -") else { return false }
        return trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 是否值得给一个"重试"按钮。
    var offersRetry: Bool {
        switch self {
        // 这三种状态机不会自己重试，但用户处理完（联网、登录、再点一次）之后
        // 需要一个就地重来的入口。
        case .cancelled, .networkUnavailable, .networkDisabled, .rightsRestricted, .songNotVerified: return true
        default: return isRetryable
        }
    }

    /// 是否建议直接跳到下一首。
    var suggestsSkip: Bool {
        switch self {
        case .unsupportedFormat, .decodeFailed, .sourceUnavailable, .rightsRestricted, .unknown, .songNotVerified: return true
        // 断网/关联网时跳到下一首只会得到同一个错误。
        case .networkDisabled, .networkUnavailable, .cancelled: return false
        }
    }

    /// 这个错误是不是"换一首也一样"的全局问题。自动跳过在这种时候必须停手。
    var isEnvironmental: Bool {
        switch self {
        case .networkDisabled, .networkUnavailable: return true
        default: return false
        }
    }
}
