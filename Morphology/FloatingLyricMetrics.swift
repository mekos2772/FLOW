import CoreGraphics

/// 悬浮歌词在**不同卡片尺寸**下的自适应参数。
///
/// 之前四种排布都把字号写死（胶囊 15、双行 16/13、歌词板 19、贴边 12），
/// 卡片从 240pt 宽拉到 640pt 宽，字一个都不变：
/// - 窄卡片（最小 240×44）上 16.2pt 只能放下十来个字，剩下全靠省略号；
/// - 宽卡片（640pt）上同一句话只占中间一小段，右边一整片空白。
/// 就更不用说双行卡片里第二行被底部进度线压住直接裁掉（`bottomInset` 之前是 0）。
///
/// 这里把"多大卡片用多大字、留多少给进度线"变成纯函数，视图只负责取值。
/// 所有返回值都夹在可读区间内——小到看不清的字号和糊成一片的大字号都不算自适应。
///
/// 横向内边距由调用方传入（`Spacing.lyricInset`）：本文件在 `Morphology/` 纯逻辑层，
/// 不该反向依赖 `DesignSystem/` 的 UI 令牌。
enum FloatingLyricMetrics {

    /// 卡片的最小可用尺寸（240×44）。
    ///
    /// 文档里一直写着这个下限（"窄卡片最小 240×44"），
    /// 但从来没有以常量形式存在过。位置快照的清洗需要它——
    /// **不能凭空另编一个**（本轮第一次就编成 120×60，把真实的 46pt 高度顶成了 60）。
    static let minCardSize = CGSize(width: 240, height: 44)

    /// 进度线本体高度 + 它离卡片下沿的间距。文字必须让开这一段。
    static let progressHeight: CGFloat = 2
    static let progressGap: CGFloat = 2

    /// 一个排布在给定卡片尺寸下的排版参数。
    struct Fit: Sendable, Equatable {
        /// 主行字号。
        var primarySize: CGFloat
        /// 次要行字号（上/下一句、贴边的辅助信息）。
        var secondarySize: CGFloat
        /// 主行最多几行。
        var primaryLineLimit: Int
        /// 次要行最多几行。
        var secondaryLineLimit: Int
        /// 左右内边距。
        var horizontalInset: CGFloat
        /// 底部为进度线预留的高度。**0 会让文字被进度线压住。**
        var bottomInset: CGFloat
        /// 是否显示上一句。
        var showsPrevious: Bool
    }

    // MARK: - 胶囊（单行）

    /// 单行胶囊：字号跟着**宽度**走。
    ///
    /// 240pt 宽 → 11pt（多放下几个字，宁可小一点也别一上来就省略号）；
    /// 392pt（设计基准）→ 15.7pt；640pt → 封顶 16.5pt。
    /// 再宽也不继续放大：一条横贯屏幕的大字在桌面陪伴场景里是噪音。
    static func capsule(_ size: CGSize, horizontalInset inset: CGFloat) -> Fit {
        let size = clampedFont(size.width / 25, lower: 11, upper: 16.5)
        return Fit(primarySize: size,
                   secondarySize: size,
                   primaryLineLimit: 1,
                   secondaryLineLimit: 1,
                   horizontalInset: inset,
                   bottomInset: progressHeight + progressGap + 2,
                   showsPrevious: false)
    }

    // MARK: - 双行

    /// 双行：主行跟着宽度走，次行按比例缩一档但保底 11pt。
    ///
    /// `bottomInset` 必须够：两行摞起来之后，第二行的基线会正好落在进度线的位置上。
    /// 之前这里是 0，实测截图里第二行被切掉下半截。
    static func doubleLine(_ size: CGSize, horizontalInset inset: CGFloat) -> Fit {
        let primary = clampedFont(size.width / 25, lower: 12, upper: 17)
        let secondary = max(11, primary * 0.8)
        return Fit(primarySize: primary,
                   secondarySize: secondary,
                   primaryLineLimit: 1,
                   secondaryLineLimit: 1,
                   horizontalInset: inset,
                   bottomInset: progressHeight + progressGap + secondary * 1.45,
                   showsPrevious: false)
    }

    // MARK: - 歌词板

    /// 歌词板：字号看宽度，**行数看高度**。
    ///
    /// 卡片越高就该给越多上下文，而不是永远 2～3 行、下半张空着。
    static func board(_ size: CGSize, horizontalInset inset: CGFloat) -> Fit {
        let primary = clampedFont(size.width / 22, lower: 15, upper: 20)
        let secondary = max(11, primary * 0.68)
        // 高度预算：上下内边距 + 上一句 + 进度线之后，还能容下几行主歌词。
        let lineHeight = primary * 1.5
        let reserved = 16 * 2 + secondary * 1.6 + progressHeight + progressGap
        let available = max(0, size.height - reserved)
        let lines = Int((available / lineHeight).rounded(.down))
        return Fit(primarySize: primary,
                   secondarySize: secondary,
                   primaryLineLimit: max(1, min(4, lines)),
                   secondaryLineLimit: max(1, min(2, lines / 2)),
                   horizontalInset: inset,
                   bottomInset: progressHeight + progressGap + 4,
                   showsPrevious: size.height >= 88 && available >= secondary * 1.6)
    }

    // MARK: - 迷你条

    /// 迷你条：内容层随高度分级（见 `CompactSpacePresentation`），
    /// 字号再跟着**宽度**微调一档——否则 320pt 和 640pt 的迷你条主歌词一样大，
    /// 宽卡右侧会空出半个屏。
    /// 基准：设计宽度（420pt）→ 17pt；有上一句时抬到 21pt（与旧实现一致）。
    static func compact(_ size: CGSize, horizontalInset inset: CGFloat, showsContext: Bool) -> Fit {
        let base = clampedFont(size.width / 24.5, lower: 15, upper: 21)
        let showsPrevious = showsContext && size.height >= 200
        let primary = showsPrevious ? min(base * 1.25, 21) : base
        let secondary = max(11, base * 0.62)
        return Fit(primarySize: primary,
                   secondarySize: secondary,
                   primaryLineLimit: showsContext ? 2 : 1,
                   secondaryLineLimit: 1,
                   horizontalInset: inset,
                   bottomInset: progressHeight + 1,
                   showsPrevious: showsPrevious)
    }

    // MARK: - 贴边

    /// 贴边：最窄只有 168×26，字号必须先让位给"看得见"这件事。
    static func edge(_ size: CGSize, horizontalInset inset: CGFloat) -> Fit {
        let primary = clampedFont(size.width / 28, lower: 10, upper: 13)
        return Fit(primarySize: primary,
                   secondarySize: primary,
                   primaryLineLimit: 1,
                   secondaryLineLimit: 1,
                   horizontalInset: inset,
                   bottomInset: 1 + 1 + 1,
                   showsPrevious: false)
    }

    // MARK: - 工具

    /// 夹到可读区间；输入是 NaN/无穷时退回下限（宁可小，不要炸）。
    static func clampedFont(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
