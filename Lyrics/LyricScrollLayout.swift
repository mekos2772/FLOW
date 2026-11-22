import CoreGraphics
import Foundation

/// Apple Music 风格歌词的**纯布局逻辑**。
///
/// 与视图完全解耦，因此"第几行应该在什么位置、多大、多透明"这些判断
/// 可以脱离 SwiftUI 穷举测试。
///
/// 设计要点（对照 Apple Music 的滚动歌词）：
/// - 整段歌词是一条滚动列表，**当前行居中**，不是只显示三行；
/// - 当前行放大并提亮，其余行按与当前行的距离衰减；
/// - 行切换带弹簧跃动：当前行从略小"弹"到正常大小（这部分由视图层用弹簧动画消费）。
enum LyricScrollLayout {

    /// 单行的视觉规格。
    struct LineStyle: Sendable, Equatable {
        /// 相对基准字号的缩放。1 = 基准；当前行更大。
        var scale: Double
        /// 不透明度。
        var opacity: Double
        /// 模糊半径（pt）。远处的行轻微失焦，形成景深。
        var blur: Double
        /// 是否当前行。
        var isCurrent: Bool
    }

    /// 整份布局结果。
    struct Layout: Sendable, Equatable {
        /// 所有行中心点相对于"可视区中心"的纵向偏移（pt，向下为正）。
        var centers: [Double]
        /// 与 `centers` 一一对应的视觉规格。
        var styles: [LineStyle]
        /// 滚动内容的总高度。
        var contentHeight: Double
        /// 每一行的**权威高度**。视图必须按它排版（`.frame(height:)`），
        /// 否则视觉位置与这个模型会各算一套，点击就会错位。
        var heights: [Double] = []
        /// 需要滚动到多少偏移，当前行才居中。
        var scrollOffset: Double

        static let empty = Layout(centers: [], styles: [], contentHeight: 0, heights: [], scrollOffset: 0)

        func style(at index: Int) -> LineStyle? {
            styles.indices.contains(index) ? styles[index] : nil
        }

        func center(at index: Int) -> Double? {
            centers.indices.contains(index) ? centers[index] : nil
        }
    }

    /// 当前行的基准字号倍率。
    static let currentScale = 1.0
    /// 相邻行缩小到多少。
    static let neighborScale = 0.78
    /// 再远一些的行。
    static let distantScale = 0.72
    /// 当前行不透明度。
    static let currentOpacity = 1.0
    static let neighborOpacity = 0.55
    static let distantOpacity = 0.30
    /// 远处行的模糊。
    static let distantBlur = 0.6
    /// 单行推进相对字号的比例（折行时追加多少高度）。
    static let lineAdvance = 1.35

    /// 计算布局。
    ///
    /// - Parameters:
    ///   - lineCount: 总行数。
    ///   - currentIndex: 当前高亮行；nil 表示还没到第一句。
    ///   - baseLineHeight: 基准行高（视觉上"相邻行"占的高度）。
    ///   - currentLineHeight: 当前行占的高度（更大，因为它更大）。
    ///   - visibleHeight: 可视区高度，用于计算居中滚动偏移。
    /// - Parameter lineTexts: 各行文本。给了它就按**估算折行数**加高该行，
    ///   否则窄窗口下长句会被固定行高裁掉（这个 bug 是在把行高收归布局之后引入的）。
    /// - Parameter availableWidth: 可用宽度（pt），用于估算折行。
    static func make(lineCount: Int,
                     currentIndex: Int?,
                     baseLineHeight: Double,
                     currentLineHeight: Double,
                     visibleHeight: Double,
                     lineTexts: [String] = [],
                     availableWidth: Double = 0,
                     fontSize: Double = 17,
                     currentFontSize: Double = 0,
                     translationTexts: [String?] = [],
                     translationFontSize: Double = 0) -> Layout {
        guard lineCount > 0 else { return .empty }
        let current = currentIndex.map { min(max($0, 0), lineCount - 1) }

        // 逐行累加：当前行占当前行高，其余占基准行高。
        var contentCenters: [Double] = []
        contentCenters.reserveCapacity(lineCount)
        var heights: [Double] = []
        heights.reserveCapacity(lineCount)
        var cursor = 0.0
        for index in 0..<lineCount {
            let baseHeight = index == current ? currentLineHeight : baseLineHeight
            // 折行估算：只有同时给了文本和宽度才算，否则维持原来的固定行高。
            var height = baseHeight
            if lineTexts.indices.contains(index), availableWidth > 1, fontSize > 0 {
                // 当前行用的是**更大**的字号，折行估算必须跟着用大字号，
                // 否则会低估行数 → 行高不够 → 正在读的那句被截断（实测 640pt 下就截了）。
                let size = index == current && currentFontSize > 0 ? currentFontSize : fontSize
                let lines = Double(estimatedLines(lineTexts[index],
                                                  width: availableWidth,
                                                  fontSize: size))
                // 只追加"多出来的行推进"，**不**把整行留白一起乘。
                // 按 `baseHeight * lines` 算的话，折三行时上下留白也被放大三倍，
                // 当前行内部行距会明显比别处松（420pt/15pt 的对照图里看得到）。
                if lines > 1 {
                    height = baseHeight + (lines - 1) * size * Self.lineAdvance
                }
            }
            if translationTexts.indices.contains(index),
               let translation = translationTexts[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty {
                let resolvedTransSize = translationFontSize > 0 ? translationFontSize : max(12, fontSize * 0.85)
                let transLines: Double
                if availableWidth > 1 {
                    transLines = Double(estimatedLines(translation, width: availableWidth, fontSize: resolvedTransSize))
                } else {
                    transLines = 1
                }
                height += transLines * resolvedTransSize * Self.lineAdvance + 4
            }
            heights.append(height)
            contentCenters.append(cursor + height / 2)
            cursor += height
        }
        let contentHeight = cursor

        // 当前行中心在内容坐标系里的位置。
        //
        // 没有当前行（还没唱到第一句，常见于 10–20 秒的前奏）时必须对准**第一行**。
        // 之前取的是 `contentHeight / 2`——歌词中间！于是《珊瑚海》这种 13 秒前奏的歌，
        // 一开播就显示副歌/结尾的歌词，用户以为"歌词配对错了"。
        let focus = current.map { contentCenters[$0] } ?? (contentCenters.first ?? 0)
        // 让 focus 正好落在可视区中心。
        //
        // **不做边界钳制**：歌词列表允许首/尾行也居中（上下留白由视图补齐），
        // 这样"当前行永远在正中间"是一条恒定规则，动画不会因为碰到边界而突变。
        let scrollOffset = focus - visibleHeight / 2

        // 每行相对可视区中心的偏移。
        var relative: [Double] = []
        relative.reserveCapacity(lineCount)
        for center in contentCenters {
            relative.append(center - scrollOffset - visibleHeight / 2)
        }

        var styles: [LineStyle] = []
        styles.reserveCapacity(lineCount)
        for index in 0..<lineCount {
            guard let current else {
                styles.append(LineStyle(scale: distantScale, opacity: distantOpacity, blur: distantBlur, isCurrent: false))
                continue
            }
            let distance = abs(index - current)
            switch distance {
            case 0:
                styles.append(LineStyle(scale: currentScale, opacity: currentOpacity, blur: 0, isCurrent: true))
            case 1:
                styles.append(LineStyle(scale: neighborScale, opacity: neighborOpacity, blur: 0, isCurrent: false))
            case 2:
                styles.append(LineStyle(scale: distantScale, opacity: distantOpacity, blur: distantBlur, isCurrent: false))
            default:
                // 更远的行完全隐去内容，避免"满屏字"抢注意力。
                styles.append(LineStyle(scale: distantScale, opacity: 0, blur: distantBlur, isCurrent: false))
            }
        }

        return Layout(centers: relative, styles: styles, contentHeight: contentHeight,
                      heights: heights, scrollOffset: scrollOffset)
    }


    /// 估算一行文字在给定宽度下会折成几行。
    ///
    /// 只用"最宽单体字"的近似：CJK/全角按 1 个字号宽，ASCII 按 0.55 个字号宽。
    /// 不做真实排版测量——布局必须是纯函数，不能依赖 UIKit/AppKit 的文本引擎。
    static func estimatedLines(_ text: String, width: Double, fontSize: Double) -> Int {
        guard width > 1, fontSize > 0, !text.isEmpty else { return 1 }
        // 已经按短语折好的行（带换行符）逐段估算。
        if text.contains("\n") {
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + estimatedLines(String($1), width: width, fontSize: fontSize) }
        }
        var units = 0.0
        for scalar in text.unicodeScalars {
            units += scalar.value < 0x2E80 ? 0.55 : 1.0
        }
        let perLine = max(width / fontSize, 1)
        return max(1, Int((units / perLine).rounded(.up)))
    }

    /// 行切换时当前行的"跃动"起始缩放。
    ///
    /// 新行不是突然变大，而是从略小处弹上来（配合弹簧动画使用）。
    static let bounceStartScale = 0.86
    /// 跃动时额外的纵向位移（pt），让它"跳"一下再稳住。
    static let bounceRise = 10.0
}
