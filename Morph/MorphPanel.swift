import AppKit
import QuartzCore
import SwiftUI

/// 承载全部五种形态的**唯一窗口**。
///
/// 为什么坚持一个窗口（规格 5.5 允许双窗口，但要求"同一实体"的连续感）：
/// 双窗口方案在任何一次交叠里都可能出现重影、闪白、抢焦点，
/// 而这些恰恰是规格明确列为"重点排查"的问题。一个窗口从根上没有这些可能。
///
/// 完整形态用**系统标题栏**（透明、无标题），所以拖动、关闭、最小化、全屏
/// 全部是 AppKit 原生行为——用户对主窗口的预期不该由自绘去赌。
/// 悬浮形态保持无边框：它们没有控件，整块 `isMovableByWindowBackground` 拖动正合适。
final class MorphPanel: NSPanel {
    /// 测试宿主里绝不真的上屏。
    ///
    /// 只拦 `MorphWindowController` 里的调用点不够：几何/恢复路径会用别的顺序把窗口
    /// 重新推上屏（实测跑一遍 full suite，屏上会冒出 5–6 个窗口）。
    /// 在**面板这一层**收口，所有路径一并覆盖。
    ///
    /// 做法是**不移动窗框**（否则几何相关的断言全乱），只把"可见"这件事变成影子状态：
    /// `isVisible` 读的是影子值，`orderFront*` 不真的上屏，`orderOut` 清影子。
    private var headlessVisible = false

    private static var isHeadlessHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override var isVisible: Bool {
        Self.isHeadlessHost ? headlessVisible : super.isVisible
    }

    override func orderFront(_ sender: Any?) {
        if Self.isHeadlessHost { headlessVisible = true; return }
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        if Self.isHeadlessHost { headlessVisible = true; return }
        super.orderFrontRegardless()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        if Self.isHeadlessHost { headlessVisible = true; return }
        super.makeKeyAndOrderFront(sender)
    }

    override func orderOut(_ sender: Any?) {
        if Self.isHeadlessHost { headlessVisible = false; return }
        super.orderOut(sender)
    }

    /// 只有完整形态允许成为 key window。悬浮形态一旦拿焦点，
    /// 用户正在别的应用里打的字就会断掉。
    var allowsKeyFocus = false
    /// 空格键的落点。返回 true 表示"这次按键已消费"。
    ///
    /// 由 `MorphWindowController` 注入：是否响应取决于当前形态、第一响应者是否是文本框。
    /// 放在面板层是因为它一定在键盘事件链上——SwiftUI 的 `.onKeyPress` 要焦点，
    /// 而点一下版面空白处并不会把焦点交给根视图。
    var onSpaceKey: (() -> Bool)?

    private var pointerDown = false
    var isHandlingPointer: Bool { pointerDown && NSEvent.pressedMouseButtons != 0 }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .normal
        collectionBehavior = [.managed, .participatesInCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // 初始是完整形态：背景拖动必须关掉，否则 SwiftUI 的控件收不到点击。
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // 整窗作为一个可朗读元素暴露给 VoiceOver；内部控件另有自己的标签。
        setAccessibilityElement(false)
        setAccessibilityLabel("FLOW 播放器")
    }

    /// 空格键：面板在完整形态下是 key window，按键先到这里。
    ///
    /// 只拦裸空格（49）。带修饰键的组合交给系统（⌘Space 是聚焦搜索），
    /// 其余按键继续走默认实现，不影响输入。
    /// ←→ 方向键同上：在完整形态下做 ±10s 快进快退（Apple Music 同款）。
    /// 歌词校准模式下这两个键另有含义——先问校准面板，再回落到 seek。
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isBare = mods.isEmpty
        if isBare {
            switch event.keyCode {
            case 49: // space
                if onSpaceKey?() == true { return }
            case 123: // ←
                if onArrowKey?(-10) == true { return }
            case 124: // →
                if onArrowKey?(10) == true { return }
            case 53: // esc
                if onEscapeKey?() == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// ←→ 方向键回调：完整形态下做 ±10s 快进快退。返回 true 表示已消费。
    /// 校准模式优先级更高——那里 ←→ 是微调歌词偏移的，不该抢。
    var onArrowKey: ((TimeInterval) -> Bool)?

    /// Esc：沉浸播放时退出沉浸。其余时候不消费，交给系统（关闭弹层、退出全屏等）。
    var onEscapeKey: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { pointerDown = true }
        if event.type == .leftMouseUp { pointerDown = false }
        if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil,
           event.type == .leftMouseDown || event.type == .leftMouseUp {
            let p = event.locationInWindow
            FileHandle.standardError.write(Data("PANEL event=\(event.type.rawValue) at=\(p) key=\(isKeyWindow) frame=\(frame)\n".utf8))
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { allowsKeyFocus }
}

/// 承载 SwiftUI 内容的宿主视图。
///
/// 两个必须覆盖的行为：
/// 1. `acceptsFirstMouse`：面板是 `.nonactivatingPanel`，应用没激活时默认的
///    "第一次点击只用来激活窗口"永远不会发生，结果是**任何一次点击都被吞掉**（实测）。
///    音乐控件应当第一下就响应——这也是悬浮播放器该有的手感。
/// 2. `mouseDown`：完整形态点击时顺手把应用与窗口激活，否则键盘（空格/方向键）拿不到事件。
final class MorphHostingView: NSHostingView<MorphRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 逐帧计时（仅 `SLP_DEBUG_FRAME=1`）。
    ///
    /// 窗口几何在动 ≠ 内容跟得上：WindowServer 会自己把窗口挪到中间位置，
    /// 但 SwiftUI 的排版重绘要真跑一遍。用户说的"帧率低"指的是后者，
    /// 所以这里量的是 `layout()` 的真实节拍。
    private static let logsFrames = ProcessInfo.processInfo.environment["SLP_DEBUG_FRAME"] == "1"
    private var lastLayoutAt: CFTimeInterval?

    override func layout() {
        super.layout()
        guard Self.logsFrames else { return }
        let now = CACurrentMediaTime()
        if let last = lastLayoutAt {
            let gap = (now - last) * 1000
            guard gap > 0.5 else { return }
            FileHandle.standardError.write(Data(String(format: "FRAME gap=%.1fms\n", gap).utf8))
        }
        lastLayoutAt = now
    }

    // 注意：这里**不要**在 mouseDown 里 activate + makeKey。
    // 在事件分发过程中激活应用会打断 SwiftUI 正在跟踪的手势，导致按钮点了没反应（实测）。
    // 焦点交给窗口层的 activateApplication 动作处理。
}
