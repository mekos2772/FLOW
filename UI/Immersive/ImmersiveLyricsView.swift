import AppKit
import SwiftUI

/// 沉浸模式里"此刻该显示哪几行"。纯逻辑，单测直接喂时间轴。
///
/// 只显示焦点附近四行：上一句（淡）、当前句（实）、下一句、再下一句（更淡）。
/// 不做整段滚动——沉浸模式是看画面的，歌词只是画面里的一块安静的字。
/// 间奏（前奏或句与句之间超过十秒的空白）时当前句的位置换成三颗渐亮的点，告诉你下一句还有多久。
struct ImmersiveLyricFocus: Equatable {
    enum Role: Int, Equatable {
        case previous = -1
        case current = 0
        case next = 1
        case later = 2
    }

    struct Row: Equatable, Identifiable {
        var index: Int
        var role: Role
        var id: Int { index }
    }

    struct Interlude: Equatable {
        /// 0…1：从间奏开始到下一句开唱。
        var progress: Double
        var remaining: TimeInterval
    }

    var rows: [Row]
    var interlude: Interlude?

    static let empty = ImmersiveLyricFocus(rows: [], interlude: nil)

    /// 一句大约什么时候唱完。
    ///
    /// 不能直接信 `end`：LRC 解析器把每句的结束时间填成**下一句的开始**，
    /// 照它算的话一句歌会一直"唱"到下一句，间奏永远不会出现（实机放歌才发现）。
    /// 所以先估一个"唱完"的时间——有逐字时间就取最后一个字开始后再留一点，
    /// 没有就按字数（每字 0.32 秒，夹在 2.5–7 秒）——再和 `end` 取较早的那个；
    /// TTML 这类带真实结束时间的来源仍然以它为准。
    static func estimatedEnd(of line: LyricLine) -> TimeInterval {
        let sung: TimeInterval
        if let last = line.segments.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            sung = last.start + min(max(Double(last.text.count) * 0.30, 0.6), 2.0)
        } else {
            sung = line.start + min(max(Double(line.text.count) * 0.32, 2.5), 7)
        }
        if let end = line.end, end > line.start { return min(end, sung) }
        return sung
    }

    static func make(lines: [LyricLine], currentIndex: Int?, time: TimeInterval) -> ImmersiveLyricFocus {
        guard !lines.isEmpty else { return .empty }
        let sung = lines.indices.filter { !lines[$0].isEmpty }
        guard let first = sung.first else { return .empty }

        func nextSung(after index: Int) -> Int? { sung.first { $0 > index } }
        func previousSung(before index: Int) -> Int? { sung.last { $0 < index } }

        // 前奏：还没唱到第一句。
        guard let raw = currentIndex, raw >= 0, raw < lines.count, time >= lines[first].start else {
            let start = lines[first].start
            var rows = [Row(index: first, role: .next)]
            if let later = nextSung(after: first) { rows.append(Row(index: later, role: .later)) }
            let interlude = start - time > 3
                ? Interlude(progress: min(max(time / max(start, 0.001), 0), 1), remaining: start - time)
                : nil
            return ImmersiveLyricFocus(rows: rows, interlude: interlude)
        }

        // 当前行是空行（LRC 里常用来标记间奏）时，回到最近唱过的那一句。
        let current = lines[raw].isEmpty ? (previousSung(before: raw) ?? first) : raw
        let following = nextSung(after: current)

        // 句间间奏：这一句已经唱完，而下一句还很远。
        if let following {
            let lineEnd = estimatedEnd(of: lines[current])
            let gap = lines[following].start - lineEnd
            if gap > 10, time > lineEnd + 0.6 {
                var rows = [Row(index: current, role: .previous), Row(index: following, role: .next)]
                if let later = nextSung(after: following) { rows.append(Row(index: later, role: .later)) }
                let progress = (time - lineEnd) / max(gap, 0.001)
                return ImmersiveLyricFocus(rows: rows,
                                           interlude: Interlude(progress: min(max(progress, 0), 1),
                                                                remaining: lines[following].start - time))
            }
        }

        var rows: [Row] = []
        if let previous = previousSung(before: current) { rows.append(Row(index: previous, role: .previous)) }
        rows.append(Row(index: current, role: .current))
        if let following {
            rows.append(Row(index: following, role: .next))
            if let later = nextSung(after: following) { rows.append(Row(index: later, role: .later)) }
        }
        return ImmersiveLyricFocus(rows: rows, interlude: nil)
    }
}

/// 长句按短语折行。
///
/// 中文按字就能断行，系统折行只看排不排得下，会把「随手撕下这一页 (这一页)」拆成「(这 / 一页)」，
/// 括号里的和声被劈成两半，第二行只剩一个尾巴（用真实歌曲实机发现）。所以一句排不下时先在空格处断：
/// 括号前的空格优先（和声自成一行），否则挑让上下两行最接近等长的那个空格；每行都得排得下。
/// 没有合适的空格时交回系统按字折行。
enum ImmersiveLyricWrap {
    /// 要换成换行符的空格，按字符偏移给出，从前往后。
    static func breakOffsets(in text: String, width: CGFloat, measure: (Substring) -> CGFloat) -> [Int] {
        guard width > 0 else { return [] }
        var offsets: [Int] = []
        var start = text.startIndex
        while start < text.endIndex, measure(text[start...]) > width {
            func rest(after index: String.Index) -> Substring { text[text.index(after: index)...] }
            let fitting = text[start...].indices.filter {
                $0 > start && (text[$0] == " " || text[$0] == "\u{3000}") && measure(text[start..<$0]) <= width
            }
            guard let last = fitting.last else { break }
            let chosen: String.Index
            if let bracket = fitting.last(where: {
                "(（[【".contains(rest(after: $0).first ?? " ") && measure(rest(after: $0)) <= width
            }) {
                chosen = bracket
            } else if measure(rest(after: last)) > width {
                // 断在最后一个空格，剩下的仍排不下：这一行尽量排满，剩下的下一轮再断。
                chosen = last
            } else {
                func longer(_ index: String.Index) -> CGFloat {
                    max(measure(text[start..<index]), measure(rest(after: index)))
                }
                chosen = fitting.min { longer($0) < longer($1) } ?? last
            }
            offsets.append(text.distance(from: text.startIndex, to: chosen))
            start = text.index(after: chosen)
        }
        return offsets
    }

    static func apply(_ offsets: [Int], to text: String) -> String {
        var characters = Array(text)
        for offset in offsets where offset < characters.count { characters[offset] = "\n" }
        return String(characters)
    }

    static func apply(_ offsets: [Int], to text: AttributedString) -> AttributedString {
        var result = text
        for offset in offsets where offset < result.characters.count {
            let index = result.characters.index(result.characters.startIndex, offsetBy: offset)
            result.characters.replaceSubrange(index...index, with: "\n")
        }
        return result
    }

    static func wrapped(_ text: String, width: CGFloat, fontSize: CGFloat,
                        weight: NSFont.Weight = .semibold, tracking: CGFloat = -0.012) -> String {
        apply(breakOffsets(in: text, width: usable(width, fontSize),
                           measure: measure(fontSize: fontSize, weight: weight, tracking: tracking)), to: text)
    }

    static func wrapped(_ text: AttributedString, width: CGFloat, fontSize: CGFloat,
                        weight: NSFont.Weight = .semibold, tracking: CGFloat = -0.012) -> AttributedString {
        let plain = String(text.characters)
        return apply(breakOffsets(in: plain, width: usable(width, fontSize),
                                  measure: measure(fontSize: fontSize, weight: weight, tracking: tracking)), to: text)
    }

    /// 默认和 `ImmersiveLyricsView` 歌词行的字体、字距一致；播放页的滚动歌词传自己的字重。
    static func measure(fontSize: CGFloat, weight: NSFont.Weight = .semibold,
                        tracking: CGFloat = -0.012) -> (Substring) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .kern: fontSize * tracking,
        ]
        return { NSAttributedString(string: String($0), attributes: attributes).size().width }
    }

    /// 留半个字的余量：量出来刚好排得下、系统却把最后一个字挤到下一行，就又是一个孤字。
    private static func usable(_ width: CGFloat, _ fontSize: CGFloat) -> CGFloat {
        width - fontSize * 0.5
    }
}

/// 每一行的视觉样式：所有行都按当前行的字号排版，再整体缩放——
/// 换行时字号不跳，只是一行"从远处走近"：变大、变实、变清楚。
struct ImmersiveLyricStyle: Equatable {
    var scale: CGFloat
    var opacity: Double
    var blur: CGFloat

    static func style(for role: ImmersiveLyricFocus.Role) -> ImmersiveLyricStyle {
        switch role {
        case .previous: return ImmersiveLyricStyle(scale: 0.50, opacity: 0.30, blur: 1.4)
        case .current: return ImmersiveLyricStyle(scale: 1.00, opacity: 1.00, blur: 0)
        case .next: return ImmersiveLyricStyle(scale: 0.56, opacity: 0.58, blur: 0.3)
        case .later: return ImmersiveLyricStyle(scale: 0.50, opacity: 0.30, blur: 1.2)
        }
    }
}

private struct LyricRowScale: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

private struct LyricRowIsFocus: LayoutValueKey {
    static let defaultValue = false
}

/// 折行宽度的倍数。唱过的上一句不会再变回当前句，可以按缩放后的视觉宽度折行，
/// 不然半尺寸的字也按整宽折行，会留下"for / me"这种孤零零的尾巴。
private struct LyricRowWrapFactor: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// 竖排歌词的布局：每行按缩放后的高度依次排下去，焦点行（当前句或间奏点）的顶边固定在 `focusY`。
/// 所有行都用同一个宽度折行，行从"下一句"升为"当前句"时不会重新折行跳字。
struct ImmersiveLyricStackLayout: Layout {
    var spacing: CGFloat
    var focusY: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        func proposal(_ subview: LayoutSubview) -> ProposedViewSize {
            ProposedViewSize(width: width * subview[LyricRowWrapFactor.self], height: nil)
        }
        let heights = subviews.map { $0.sizeThatFits(proposal($0)).height * $0[LyricRowScale.self] }
        let focus = subviews.firstIndex { $0[LyricRowIsFocus.self] } ?? 0
        var y = bounds.minY + focusY
        for index in stride(from: focus - 1, through: 0, by: -1) {
            y -= heights[index] + spacing
        }
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal(subview))
            y += heights[index] + spacing
        }
    }
}

/// 沉浸模式的歌词层。
struct ImmersiveLyricsView: View {
    @Bindable var model: MorphPresentationModel
    var lines: [LyricLine]
    var showTranslation: Bool
    /// 当前行的字号（随窗口高度变化）。
    var fontSize: CGFloat
    /// 歌词栏宽度，长句按它在短语处折行。
    var columnWidth: CGFloat
    /// 光色（调色板里最亮的那个），当前句带一点它的光。
    var glow: Color
    /// 焦点行（当前句或间奏点）顶边在本视图里的位置；上一句排在它上方，仍在视图范围内。
    var focusY: CGFloat
    var reduceMotion: Bool

    var body: some View {
        let focus = model.isMasked ? .empty
            : ImmersiveLyricFocus.make(lines: lines, currentIndex: model.lyric.index, time: model.lyric.time)
        Group {
            if model.isMasked || lines.isEmpty {
                nowPlayingCard
            } else {
                stack(focus)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.22, 0.61, 0.24, 1, duration: 0.75),
                   value: focus.rows.map(\.index))
        .animation(Motion.respectingReduceMotion(.easeOut(duration: 0.6), reduceMotion: reduceMotion),
                   value: focus.interlude != nil)
        .accessibilityElement(children: .combine)
    }

    private func stack(_ focus: ImmersiveLyricFocus) -> some View {
        ImmersiveLyricStackLayout(spacing: fontSize * 0.42, focusY: focusY) {
            ForEach(focus.rows) { row in
                if row.role == .next, let interlude = focus.interlude {
                    InterludeDots(progress: interlude.progress, size: fontSize * 0.22, reduceMotion: reduceMotion)
                        .layoutValue(key: LyricRowIsFocus.self, value: true)
                        .layoutValue(key: LyricRowScale.self, value: 1)
                        .id("interlude-\(row.index)")
                        .transition(.opacity)
                }
                lineView(row)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ row: ImmersiveLyricFocus.Row) -> some View {
        let line = lines[row.index]
        let style = ImmersiveLyricStyle.style(for: row.role)
        let isCurrent = row.role == .current
        let wrapFactor = row.role == .previous ? 1 / style.scale : 1
        let wrapWidth = columnWidth * wrapFactor
        VStack(alignment: .leading, spacing: fontSize * 0.22) {
            Group {
                if isCurrent, line.hasWordTiming {
                    Text(ImmersiveLyricWrap.wrapped(
                        LyricWordHighlight.attributedString(for: line, at: model.lyric.time, baseAlpha: 0.46),
                        width: wrapWidth, fontSize: fontSize))
                } else {
                    Text(ImmersiveLyricWrap.wrapped(line.text, width: wrapWidth, fontSize: fontSize))
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .tracking(-fontSize * 0.012)
            .lineSpacing(fontSize * 0.10)
            // 译文只跟着当前句：上下文行缩小后译文只剩八九号字，读不清，只是噪点。
            if isCurrent, let translation = line.translationText(showingTranslation: showTranslation) {
                Text(translation)
                    .font(.system(size: fontSize * 0.46, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
        .foregroundStyle(Color.white)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 可读性主要靠着色器在歌词区按背景亮度压暗；当前句再加一层很淡、带一点调色板光色的暗影托住字。
        // 上下文行不加：它们本来就暗、还带模糊，再叠阴影几乎看不出，却要随逐字点亮每秒重画八次
        // （Release 全屏实测：去掉大半径阴影后主线程占用明显下降）。
        .shadow(color: shadowTone.opacity(isCurrent ? 0.45 : 0), radius: isCurrent ? fontSize * 0.22 : 0,
                y: fontSize * 0.03)
        .scaleEffect(style.scale, anchor: .topLeading)
        .opacity(style.opacity)
        .blur(radius: reduceMotion ? 0 : style.blur)
        .layoutValue(key: LyricRowScale.self, value: style.scale)
        .layoutValue(key: LyricRowWrapFactor.self, value: wrapFactor)
        .layoutValue(key: LyricRowIsFocus.self, value: isCurrent)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: fontSize * 0.4)),
                                removal: .opacity.combined(with: .offset(y: -fontSize * 0.3))))
        .accessibilityHidden(!isCurrent)
    }

    /// 托字的暗影：主体是黑，掺一成调色板光色，暗影边缘带一点场景里的光，而不是死黑。
    private var shadowTone: Color {
        Color(NSColor.black.blended(withFraction: 0.12, of: NSColor(glow)) ?? .black)
    }

    /// 没有歌词（或隐私模式）时，这块位置写歌名与歌手，安安静静地放在画面里。
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.28) {
            Text(model.displayTitle ?? String(localized: "正在播放"))
                .font(.system(size: fontSize * 0.95, weight: .semibold))
                .tracking(-fontSize * 0.012)
                .lineLimit(2)
            if let artist = model.displayArtist {
                Text(artist)
                    .font(.system(size: fontSize * 0.42, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.35), radius: fontSize * 0.5, y: fontSize * 0.04)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 间奏的三颗点：随间奏进度依次亮起。
///
/// 不做逐帧呼吸：那需要每秒重画三十次 SwiftUI，全屏下光这三颗点就让主线程多忙一截（Time Profiler 实测）。
/// 进度跟着歌词节拍（约每秒八次）变化，亮度过渡由一段短动画抹平，看起来是连续变亮的。
private struct InterludeDots: View {
    var progress: Double
    var size: CGFloat
    var reduceMotion: Bool

    var body: some View {
        HStack(spacing: size * 0.9) {
            ForEach(0..<3, id: \.self) { i in
                let fill = min(max(progress * 3 - Double(i), 0), 1)
                Circle()
                    .fill(Color.white.opacity(0.22 + 0.70 * fill))
                    .frame(width: size, height: size)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: progress)
        .frame(height: size * 2.4, alignment: .leading)
        .accessibilityLabel(Text("间奏"))
    }
}
