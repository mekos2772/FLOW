import AppKit
import SwiftUI

/// 歌词偏移的键盘微调。
///
/// 为什么需要它：歌词校准抽屉在**悬浮面板**里也会用到，而那些形态不是 key window，
/// SwiftUI 的 `.onKeyPress` 收不到方向键。这里挂一个本地事件监听，
/// 只在抽屉存在期间生效，消失即摘除。
///
/// 键位：← → 调 10ms，↑ ↓ 调 100ms，Return 提交，Esc 撤销。
struct KeyboardOffsetMonitor: NSViewRepresentable {
    var onAdjust: (TimeInterval) -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onAdjust = onAdjust
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onAdjust = onAdjust
        view.onCommit = onCommit
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MonitorView)?.stop()
    }

    private final class MonitorView: NSView {
        var onAdjust: ((TimeInterval) -> Void)?
        var onCommit: (() -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // 只拦自己窗口的按键：local monitor 对**整个 app** 都触发，
                // 抽屉开着时别处（设置页、搜索框、文本框）的方向键/回车会被吃掉。
                guard event.window === self.window else { return event }
                // 正在文本框里打字时不抢（校准抽屉不是唯一内容）。
                if let responder = self.window?.firstResponder,
                   responder is NSText || responder is NSTextView { return event }
                switch event.keyCode {
                case 123: self.onAdjust?(-0.01); return nil   // ←
                case 124: self.onAdjust?(0.01); return nil    // →
                case 126: self.onAdjust?(0.1); return nil     // ↑
                case 125: self.onAdjust?(-0.1); return nil    // ↓
                case 36, 76: self.onCommit?(); return nil     // Return / Enter
                case 53: self.onCancel?(); return nil         // Esc
                default: return event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
