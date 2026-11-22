import SwiftUI

/// 形态视图的动作出口。视图不直接碰窗口，所有副作用经这里回到控制器。
struct MorphViewActions {
    var expand: () -> Void = {}
    var collapse: () -> Void = {}
    var close: () -> Void = {}
    var togglePlay: () -> Void = {}
    var next: () -> Void = {}
    /// 上一首。迷你条也算"完整传输带"的一部分——没有它想退一首就得先展开。
    var previous: () -> Void = {}
    /// 返回浏览首页，不打断音乐。
    var browse: () -> Void = {}
    /// 迷你条上拖动进度线：参数是目标秒数。
    var seek: (TimeInterval) -> Void = { _ in }
    /// 拖拽缩放的**屏幕坐标增量**（AppKit y 向上）。
    var resize: (CGSize) -> Void = { _ in }
    /// 进入 / 退出沉浸播放。
    var toggleImmersive: () -> Void = {}
    /// 右上角三档切换：普通 / 悬浮 / 沉浸。
    var setMode: (PlayerMode) -> Void = { _ in }
}

/// 形态根视图：**一个视图树**按形态分发内容。
///
/// 变形时窗口几何由 AppKit 连续插值，内容在这里做同长度的交叉淡入淡出，
/// 因此用户看到的是"同一件东西在变形"，而不是"旧窗口关掉、新窗口开出来"。
struct MorphRootView: View {
    @Bindable var model: MorphPresentationModel
    var actions: MorphViewActions
    var edge: ScreenEdge
    /// 悬浮形态的歌词排布（胶囊/双行/歌词板/贴边）。
    var floatingShape: LyricsShape
    /// 依赖容器。窗口是自己创建的，没有 SwiftUI 场景帮忙注入环境，
    /// 所以由根视图负责把 `\.app` 往下传（漏了会让按钮"看着能动、其实什么都不做"）。
    var appContainer: AppContainer?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme

    private var effectiveColorScheme: ColorScheme {
        guard model.morphology != .expanded, let tone = model.floatingTone else { return systemColorScheme }
        return tone == .light ? .light : .dark
    }

    var body: some View {
        // 全部系统控件（滑块、开关、页签）默认吃系统强调色——那是蓝的。
        // 纯黑白体系里把它们统一压到主色（浅色黑 / 深色白）。
        contentRoot
            .tint(.primary)
            .environment(\.colorScheme, effectiveColorScheme)
    }

    private var contentRoot: some View {
        // 外面这层 GeometryReader + 显式 frame 不是装饰：
        // NSHostingView 会尝试"动画窗口尺寸去贴合内容理想尺寸"，
        // 而我们的窗口是手动改 frame 的（拖拽缩放）。一旦内容理想尺寸跟着动画变化，
        // AppKit 就会在 windowDidLayout 里反复要求更新约束，最后抛
        // "more Update Constraints passes than there are views" 直接崩溃（实测拖拽缩放必崩）。
        // 把内容钉在"提议尺寸"上，理想尺寸就恒等于窗口尺寸，这条环路断开。
        GeometryReader { proxy in
            ZStack {
                content
                    .id(identity)
                    .transition(.opacity)
                    // 阻尼回弹只作用于内容：几何受安全区约束，内容不受。
                    .scaleEffect(model.morphology == .expanded ? 1 : model.contentBounceScale,
                                 anchor: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.handoff), reduceMotion: reduceMotion),
                       value: identity)
        }
        .background(Color.clear)
        // 空格键交给窗口层的本地监听（见 `MorphWindowController.installSpaceKeyMonitor`）。
        // `.onKeyPress` 依赖 SwiftUI 的焦点链：点一下版面空白处焦点并不会落到这个视图上，
        // 于是按键被系统吞掉、设置里承诺的"空格暂停"永远不会触发（实测）。
        // 这里不再重复绑定，避免同一次按键被处理两次。
        .accessibilityElement(children: .contain)
        .environment(\.app, appContainer)
    }

    /// 内容身份：形态 + 歌词排布。任一变化都触发一次短交叉淡化。
    private var identity: String {
        "\(model.morphology.rawValue)-\(floatingShape.rawValue)-\(model.isImmersive)"
    }

    @ViewBuilder
    private var content: some View {
        switch model.morphology {
        case .expanded where model.isImmersive:
            ImmersivePlayerView(model: model, onExit: actions.toggleImmersive, onMode: actions.setMode)
                .ignoresSafeArea()
        case .expanded:
            ExpandedPlayerView(model: model,
                               onClose: actions.close,
                               onBrowse: actions.browse,
                               onImmersive: actions.toggleImmersive,
                               onMode: actions.setMode)
                // 透明标题栏 + fullSizeContentView 下 SwiftUI 仍会把标题栏当安全区让开，
                // 版面被整体压低 28pt，顶上留一条透明带、交通灯悬在版面外。
                // 版面铺满整窗，交通灯落在版面里；内容的避让由 ExpandedPlayerView 自己的顶边距负责。
                .ignoresSafeArea()
                .overlay(alignment: .bottomTrailing) {
                    ResizeGrip { delta in actions.resize(delta) }
                        // 必须显式定尺寸：NSViewRepresentable 没有固有尺寸，
                        // 不定就会被 overlay 撑满整窗——绘制跑到左下角，点击区也会盖住整窗。
                        .frame(width: 16, height: 16)
                        .padding(4)
                }
        case .compact:
            CompactBarView(model: model,
                           onExpand: actions.expand,
                           onTogglePlay: actions.togglePlay,
                           onPrevious: actions.previous,
                           onNext: actions.next,
                           onSeek: actions.seek)
        case .capsule:
            GeometryReader { geometry in
                // 同上：动画期间按目标高度选排布，避免中途在单行/双行/歌词板之间跳。
                let height = model.presentationSizeOverride?.height ?? geometry.size.height
                switch CapsuleSpacePresentation.shape(preferred: floatingShape, height: height) {
                case .doubleLine:
                    DoubleLineLyricsView(model: model, onExpand: actions.expand)
                case .board:
                    BoardLyricsView(model: model, onExpand: actions.expand)
                default:
                    CapsuleLyricsView(model: model, onExpand: actions.expand)
                }
            }
        case .edge:
            EdgeLyricsView(model: model, edge: edge, onExpand: actions.expand)
        case .dormant:
            DormantHandleView(model: model, onExpand: actions.expand)
        }
    }
}

/// 右下角缩放手柄。
///
/// 用 NSView 抓屏幕坐标而不是 SwiftUI DragGesture：手柄自己会跟窗口一起移动，
/// 在视图坐标系里的位移会被"窗口移动"抵消掉，手势变成非线性
/// （实测：拖 278pt 只缩了 154pt，且方向会飘）。屏幕坐标不受窗口移动影响。
struct ResizeGrip: NSViewRepresentable {
    var onResize: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HandleView()
        view.onResize = onResize
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandleView)?.onResize = onResize
    }

    private final class HandleView: NSView {
        var onResize: ((CGSize) -> Void)?
        private var lastPoint: NSPoint?

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func draw(_ dirtyRect: NSRect) {
            // 两条斜线，作为"可缩放"的视觉暗示；悬停时更亮。
            let alpha: CGFloat = isHovering ? 0.9 : 0.35
            NSColor.labelColor.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: 11, y: 0))
            path.line(to: NSPoint(x: 16, y: 5))
            path.move(to: NSPoint(x: 6, y: 0))
            path.line(to: NSPoint(x: 16, y: 10))
            path.stroke()
        }

        private var isHovering = false {
            didSet { needsDisplay = true }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }

        override func mouseDown(with event: NSEvent) {
            lastPoint = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let last = lastPoint else { return }
            let now = NSEvent.mouseLocation
            onResize?(CGSize(width: now.x - last.x, height: now.y - last.y))
            lastPoint = now
        }

        override func mouseUp(with event: NSEvent) {
            lastPoint = nil
        }
    }
}
