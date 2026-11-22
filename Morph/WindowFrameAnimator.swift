import AppKit
import QuartzCore

/// 过渡动画的驱动器：**窗口几何由系统插值，内容回弹由弹簧逐帧推进**。
///
/// 为什么这样分工（都是实测得出的）：
/// - 自己用 `CADisplayLink` 逐帧改窗口 frame 时，浮动面板在应用非激活状态下
///   会被系统节流，回调间隔掉到约 200ms，动画看起来是"走两步停一下"。
///   交给 `NSAnimationContext` 由系统调度就不会有这个问题。
/// - 但系统插值无法表达"几何过冲"（`animator().setFrame` 没有过冲语义，
///   几何过冲在业务上也不允许：目标框已贴着 10pt 安全余量）。
///   所以过冲改由**内容层**表达——那层没有边界约束，正是 iOS 那种"弹一下"的观感来源。
@MainActor
final class WindowFrameAnimator {
    private var link: CADisplayLink?
    private var beganAt: CFTimeInterval = 0
    private var to: CGRect = .zero
    private var recipe: TransitionRecipe?
    private var contentSpec: SpringSpec?
    private var contentDuration: Double = 0
    private var apply: ((CGRect) -> Void)?
    private var contentScale: ((Double) -> Void)?
    private var completion: (() -> Void)?
    /// 每次启动/取消都自增，用来丢弃上一次的残留回调。
    private var generation: UInt64 = 0

    var isRunning: Bool { completion != nil }

    /// 启动一次过渡。
    ///
    /// - Parameters:
    ///   - window: 要移动的窗口。由调用方传入，驱动器不自己去猜。
    ///   - inside: 几何可达范围的硬边界（安全区再内缩一个 edgeInset）。
    ///     虽然是系统插值，落点本身已由调用方钳制；这里只兜住极端情况。
    ///   - contentScale: 每帧的内容缩放（>1 表示回弹），由视图层消费。
    func animate(from: CGRect,
                 to: CGRect,
                 recipe: TransitionRecipe,
                 inside: CGRect?,
                 window: NSWindow,
                 hostView: NSView,
                 contentScale: @escaping (Double) -> Void,
                 completion: @escaping () -> Void) {
        cancel()
        self.to = to
        self.recipe = recipe
        self.contentScale = contentScale
        self.completion = completion
        generation &+= 1
        let ticket = generation

        guard from != to else {
            window.setFrame(to, display: true)
            contentScale(1)
            settle()
            return
        }

        // 几何：交给系统插值，过冲由控制点 y > 1 表达。
        let curve = recipe.geometryCurve
        let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1),
                                          Float(curve.x2), Float(curve.y2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = recipe.duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            // display: false 让系统合并绘制，避免每小步同步重绘。
            window.animator().setFrame(to, display: false)
        } completionHandler: { [weak self] in
            // 回调不带 actor 信息：显式跳回主 actor，不假设执行器上下文。
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                // 精确落到目标：下一次落点计算看到的是干净结果。
                window.setFrame(to, display: false)
                self.settle()
            }
        }

        // 内容回弹：用比几何略短的弹簧，落地前后轻微过冲。
        let spec = SpringSpec(response: recipe.geometry.response * recipe.contentResponseScale,
                              dampingRatio: recipe.geometry.dampingRatio)
        contentSpec = spec
        contentDuration = spec.settlingDuration
        beganAt = CACurrentMediaTime()
        let displayLink = hostView.displayLink(target: self, selector: #selector(stepContent(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    func cancel() {
        generation &+= 1
        link?.invalidate()
        link = nil
        apply = nil
        contentScale = nil
        completion = nil
        contentSpec = nil
    }

    // MARK: - 驱动

    /// 内容层回弹。窗口不在这里动，只推进内部缩放。
    @objc private func stepContent(_ displayLink: CADisplayLink) {
        guard let spec = contentSpec, let recipe else { return }
        let elapsed = CACurrentMediaTime() - beganAt
        guard elapsed < contentDuration else {
            contentScale?(1)
            displayLink.invalidate()
            link = nil
            return
        }
        let progress = spec.progress(at: elapsed)
        // 把"超过 1 的部分"按强度放大成可见回弹。
        contentScale?(1 + (progress - 1) * recipe.contentOvershoot * 4)
    }

    /// 精确落到目标再回调：别让动画残值污染下一次落点计算。
    private func settle() {
        let done = completion
        link?.invalidate()
        link = nil
        contentScale?(1)
        contentScale = nil
        completion = nil
        recipe = nil
        contentSpec = nil
        done?()
    }

    // MARK: - 纯几何

    nonisolated static func interpolate(_ from: CGRect, _ to: CGRect, progress: Double) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    /// 把矩形钳进边界：只移动、不缩放，避免"为了塞进去把内容压变形"。
    nonisolated static func clamp(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        var result = frame
        if result.width > bounds.width { result.size.width = bounds.width }
        if result.height > bounds.height { result.size.height = bounds.height }
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        return result
    }
}
