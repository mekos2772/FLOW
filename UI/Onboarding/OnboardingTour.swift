import Foundation
import SwiftUI

// MARK: - 锚点

/// 新手引导指向的位置。
///
/// 引导层**不自己算版面**：每个视图用 `onboardingAnchor(_:)` 上报自己在引导坐标空间里的矩形，
/// 引导层只负责把箭头指过去。这样以后挪动搜索框或侧栏，箭头不会指到空气里。
enum OnboardingAnchor: String, CaseIterable {
    case search
    case sidebar
    case modeSwitch
    case content
    case transport
}

/// 一个引导步骤：一句标题 + 一句说明 + 一个箭头。
///
/// 刻意只有两句文字、没有截图：用户要的是"知道这块是干什么的"，
/// 不是看一本说明手册。每一步都能跳过，看完了也能在设置里重看。
struct OnboardingStep: Identifiable {
    let anchor: OnboardingAnchor
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var id: String { anchor.rawValue }
}

@MainActor
enum Onboarding {
    /// 上报锚点用的命名坐标空间。挂在主窗口内容层上。
    static let coordinateSpace = "flow.onboarding"
    /// 设置页「重新查看新手引导」发给主窗口的通知。
    static let didRequestReplay = Notification.Name("flow.onboarding.didRequestReplay")

    /// 设置窗是独立窗口，主窗口可能还没建出来（比如现在收在菜单栏里）。
    /// 所以「重看」既要发通知（窗口已经在的时候立刻响应），也要留一个待办标记
    /// （窗口还没建时，等它出现再消费）。和 `SettingsNavigation.pendingPane` 同一套思路。
    private static var replayPending = false

    static func requestReplay() {
        markReplayPending()
        NotificationCenter.default.post(name: didRequestReplay, object: nil)
    }

    /// 只记标记、不发通知。测试与"窗口还没建"的路径用得上。
    static func markReplayPending() {
        replayPending = true
    }

    static func takeReplayRequest() -> Bool {
        defer { replayPending = false }
        return replayPending
    }

    /// 要不要开始引导。
    ///
    /// `hasSeen == nil` 表示容器还没注入：窗口控制器先用空容器建根视图，此时**不能**当成"看过了"
    /// 直接放弃，调用方要在容器到位后再问一次。
    /// 测试宿主不自动弹：每轮测试都会重开主窗口，引导层盖住整窗会挡住别的用例；重看请求照样响应。
    static func shouldStart(replayRequested: Bool,
                            hasSeen: Bool?,
                            finishedThisRun: Bool,
                            isTestHost: Bool) -> Bool {
        if replayRequested { return true }
        guard !finishedThisRun, !isTestHost, let hasSeen else { return false }
        return !hasSeen
    }

    /// 步骤顺序就是用户第一次打开时**眼睛会走的路线**：
    /// 顶部搜索 → 左边导航 → 右上显示方式 → 中间内容区 → 底部播放栏。
    ///
    /// 用计算属性而不是 `static let`：`LocalizedStringKey` 不是 `Sendable`，
    /// 全局可变状态在 Swift 6 严格并发下过不了；每次读一遍这点开销可以忽略。
    static var steps: [OnboardingStep] {
        [
            OnboardingStep(anchor: .search,
                           title: "先搜一首歌",
                           detail: "在顶部输入歌名或歌手，按回车开始搜索。"),
            OnboardingStep(anchor: .sidebar,
                           title: "页面都在左边",
                           detail: "首页、收藏、最近播放、歌单、离线都在这里，设置在最下面。"),
            OnboardingStep(anchor: .modeSwitch,
                           title: "三种显示方式",
                           detail: "普通是完整窗口，悬浮是歌词小窗，沉浸是满屏画面，随时可以切回来。"),
            OnboardingStep(anchor: .content,
                           title: "音乐可以直接拖进来",
                           detail: "音频文件、整个文件夹、歌词文件都能拖进这个窗口。"),
            OnboardingStep(anchor: .transport,
                           title: "播放都在底栏",
                           detail: "播放、上下曲、进度和音量都在这里；点「音色」还能换成 AI 翻唱。")
        ]
    }
}

// MARK: - 锚点上报

struct OnboardingAnchorKey: PreferenceKey {
    static let defaultValue: [OnboardingAnchor: CGRect] = [:]

    static func reduce(value: inout [OnboardingAnchor: CGRect],
                       nextValue: () -> [OnboardingAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 把自己在引导坐标空间里的矩形报给引导层。
    func onboardingAnchor(_ anchor: OnboardingAnchor) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OnboardingAnchorKey.self,
                    value: [anchor: proxy.frame(in: .named(Onboarding.coordinateSpace))]
                )
            }
        }
    }
}

// MARK: - 卡片高度

/// 卡片高度要参与定位（往上放还是往下放），所以量一次自己。
private struct OnboardingCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 覆盖层

/// 新手引导覆盖层：压暗整窗、高亮当前区域、用箭头把一句话指过去。
///
/// 点任意空白处等于「下一步」，底部按钮可以「跳过」，所以不会把人困住。
struct OnboardingOverlay: View {
    var steps: [OnboardingStep]
    var index: Int
    var anchors: [OnboardingAnchor: CGRect]
    var size: CGSize
    var onNext: () -> Void
    var onSkip: () -> Void
    /// 离屏渲染与预览量不到真实高度，直接给一个值；正常运行保持 nil 走自动测量。
    var cardHeightOverride: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 0

    static let cardWidth: CGFloat = 292
    private static let edgeInset: CGFloat = 20
    /// 卡片与高亮区之间留给箭头的距离。
    private static let arrowGap: CGFloat = 42
    /// 高亮框比目标区域外扩的边距。
    private static let spotlightInset: CGFloat = 8

    private var safeIndex: Int {
        guard !steps.isEmpty else { return 0 }
        return min(max(index, 0), steps.count - 1)
    }

    private var step: OnboardingStep? {
        steps.isEmpty ? nil : steps[safeIndex]
    }

    private var isLast: Bool { safeIndex + 1 >= steps.count }

    private var spotlight: CGRect? {
        guard let step, let rect = anchors[step.anchor], rect.width > 1, rect.height > 1 else { return nil }
        // 贴边的目标（底栏、侧栏）外扩后会超出窗口，先裁回窗口里，否则高亮框会被切掉一条。
        let expanded = rect.insetBy(dx: -Self.spotlightInset, dy: -Self.spotlightInset)
        let clipped = expanded.intersection(CGRect(origin: .zero, size: size))
        return clipped.isNull || clipped.isEmpty ? expanded : clipped
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrim
            if let spotlight {
                ring(spotlight)
            }
            if let step {
                card(step)
                if let spotlight, Self.showsArrow(card: cardRect(for: step), spotlight: spotlight) {
                    arrow(for: step, spotlight: spotlight)
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .onPreferenceChange(OnboardingCardHeightKey.self) { height in
            guard height > 0, abs(height - cardHeight) > 0.5 else { return }
            cardHeight = height
        }
        .accessibilityIdentifier("onboarding.overlay")
    }

    // MARK: 压暗 + 高亮

    /// 用 even-odd 填充挖一个洞：整窗压暗，只有当前区域是亮的。
    private var scrim: some View {
        Canvas { context, canvasSize in
            var path = Path(CGRect(origin: .zero, size: canvasSize))
            if let spotlight {
                path.addRoundedRect(in: spotlight, cornerSize: CGSize(width: 14, height: 14))
            }
            context.fill(path, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onNext)
        .accessibilityHidden(true)
    }

    private func ring(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: 卡片

    private func card(_ step: OnboardingStep) -> some View {
        let origin = cardOrigin(for: step)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(step.title)
                .flowType(.homeTitle)
                .foregroundStyle(.primary)
            Text(step.detail)
                .flowType(.body)
                .foregroundStyle(FlowColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.xxs) {
                Text(verbatim: "\(safeIndex + 1) / \(steps.count)")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                Spacer(minLength: Spacing.s)
                FlowTextButton(title: "跳过", action: onSkip)
                FlowTextButton(title: isLast ? "开始使用" : "下一步",
                               symbolName: isLast ? nil : "arrow.right",
                               prominent: true,
                               action: onNext)
            }
            .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.m)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background { cardSizeProbe }
        .background(Surface.overlay, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .offset(x: origin.x, y: origin.y)
        .opacity(isCardHeightKnown ? 1 : 0)
        .animation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion),
                   value: safeIndex)
    }

    private var cardSizeProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: OnboardingCardHeightKey.self, value: proxy.size.height)
        }
    }

    /// 卡片放哪：默认在目标**上方或下方**（哪边地方大放哪边），
    /// 目标本身就是一大片区域时（内容区），卡片放到它里面靠下，免得压住顶部搜索框。
    private func cardOrigin(for step: OnboardingStep) -> CGPoint {
        Self.cardOrigin(anchorRect: anchors[step.anchor], size: size, cardHeight: measuredCardHeight)
    }

    /// 纯几何：给定目标矩形和窗口大小算卡片左上角。抽成静态函数是为了能直接测边界情况。
    static func cardOrigin(anchorRect: CGRect?, size: CGSize, cardHeight: CGFloat) -> CGPoint {
        let width = cardWidth
        let height = max(cardHeight, 1)
        let inset = edgeInset
        guard let rect = anchorRect else {
            return CGPoint(x: max((size.width - width) / 2, inset),
                           y: max((size.height - height) / 2, inset))
        }

        var x = rect.midX - width / 2
        x = clamp(x, inset, max(size.width - width - inset, inset))

        // 又窄又高（左侧栏）把卡片放到它右边：卡片压在侧栏上会把导航项挡住。
        let isTallNarrow = rect.width < size.width * 0.35 && rect.height > size.height * 0.3
        if isTallNarrow {
            let rightX = rect.maxX + spotlightInset + arrowGap
            let leftX = rect.minX - spotlightInset - arrowGap - width
            let x2 = rightX + width + inset <= size.width ? rightX : max(leftX, inset)
            let y2 = clamp(rect.midY - height / 2, inset, max(size.height - height - inset, inset))
            return CGPoint(x: x2, y: y2)
        }

        // 只看高度：整宽的底栏又宽又矮，它不是"一大片区域"，不能把卡片塞进它里面。
        let isLargeArea = rect.height > size.height * 0.4
        var y: CGFloat
        if isLargeArea {
            y = rect.maxY - height - Spacing.l
        } else if rect.midY < size.height / 2 {
            y = rect.maxY + spotlightInset + arrowGap
        } else {
            y = rect.minY - spotlightInset - arrowGap - height
        }
        y = clamp(y, inset, max(size.height - height - inset, inset))
        return CGPoint(x: x, y: y)
    }

    private var isCardHeightKnown: Bool { cardHeightOverride != nil || cardHeight > 0 }

    /// 还没量到高度时先按两行字估一个，避免第一帧卡片跑到窗外。
    private var measuredCardHeight: CGFloat {
        cardHeightOverride ?? (cardHeight > 0 ? cardHeight : 136)
    }

    // MARK: 箭头

    private func cardRect(for step: OnboardingStep) -> CGRect {
        CGRect(origin: cardOrigin(for: step), size: CGSize(width: Self.cardWidth, height: measuredCardHeight))
    }

    /// 卡片本身就落在高亮区里（内容区这种一大片）时不画箭头：
    /// 箭头只能在区域内部乱指，还会压住空态文字（实机截图里压到了「从 GitHub 搜索音源」）；
    /// 高亮框已经说明了"就是这一块"。
    static func showsArrow(card: CGRect, spotlight: CGRect) -> Bool {
        !card.intersects(spotlight)
    }

    private func arrow(for step: OnboardingStep, spotlight: CGRect) -> some View {
        let points = Self.arrowPoints(card: cardRect(for: step), target: spotlight)
        return ZStack {
            OnboardingArrowLine(from: points.start, to: points.end)
                .stroke(Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            OnboardingArrowHead(from: points.start, to: points.end)
                .fill(Color.white.opacity(0.85))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(isCardHeightKnown ? 1 : 0)
    }

    /// 箭头从卡片**离目标最近的那条边**出发，停在目标边缘外一点，不盖住目标本身。
    static func arrowPoints(card: CGRect, target: CGRect) -> (start: CGPoint, end: CGPoint) {
        let center = CGPoint(x: target.midX, y: target.midY)
        let start: CGPoint
        if card.maxY <= target.minY {
            start = CGPoint(x: clamp(center.x, card.minX + 24, card.maxX - 24), y: card.maxY + 2)
        } else if card.minY >= target.maxY {
            start = CGPoint(x: clamp(center.x, card.minX + 24, card.maxX - 24), y: card.minY - 2)
        } else if card.maxX <= target.minX {
            start = CGPoint(x: card.maxX + 2, y: clamp(center.y, card.minY + 20, card.maxY - 20))
        } else if card.minX >= target.maxX {
            start = CGPoint(x: card.minX - 2, y: clamp(center.y, card.minY + 20, card.maxY - 20))
        } else {
            // 卡片压在高亮区上（大区域里靠下放置时可能发生）：从卡片上沿出去，至少还看得出指向。
            start = CGPoint(x: card.midX, y: card.minY - 2)
        }
        let dx = center.x - start.x
        let dy = center.y - start.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let stop = CGPoint(x: center.x - dx / length * 18, y: center.y - dy / length * 18)
        return (start, stop)
    }

    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}

// MARK: - 箭头形状

/// 箭头的杆。头部单独画成实心三角，描边三角形看着像"空心箭头"，不干脆。
struct OnboardingArrowLine: Shape {
    var from: CGPoint
    var to: CGPoint
    var headLength: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        path.move(to: from)
        path.addLine(to: CGPoint(x: to.x - dx / length * headLength,
                                 y: to.y - dy / length * headLength))
        return path
    }
}

struct OnboardingArrowHead: Shape {
    var from: CGPoint
    var to: CGPoint
    var length: CGFloat = 10
    var halfWidth: CGFloat = 5.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / distance
        let uy = dy / distance
        let base = CGPoint(x: to.x - ux * length, y: to.y - uy * length)
        path.move(to: to)
        path.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        path.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        path.closeSubpath()
        return path
    }
}
