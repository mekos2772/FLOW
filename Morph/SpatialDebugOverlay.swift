import AppKit

/// 空间调试叠加层（规格 §十一）。
///
/// 一块覆盖全屏、点击穿透的面板，把求解器看到的东西**画出来**：
/// 红 = 障碍物，绿 = 自由矩形，黄 = 其他候选位置，蓝 = 最终目标，虚线 = 当前播放器。
/// 只有 `SLP_DEBUG_SPATIAL=1` 时才会创建；正式界面里不存在。
@MainActor
final class SpatialDebugOverlay {
    struct Snapshot {
        var obstacles: [CGRect] = []
        var freeRects: [CGRect] = []
        var alternatives: [CGRect] = []
        var current: CGRect = .zero
        var target: CGRect = .zero
        var reason: String = ""
        var score: Double = 0
    }

    private var panel: NSPanel?
    private let view = OverlayView()

    var isEnabled: Bool { ProcessInfo.processInfo.environment["SLP_DEBUG_SPATIAL"] == "1" }

    func update(_ snapshot: Snapshot, in screenFrame: CGRect) {
        guard isEnabled, screenFrame.width > 1 else { return }
        view.snapshot = snapshot
        if panel == nil { makePanel(screenFrame) }
        if panel?.frame != screenFrame {
            panel?.setFrame(screenFrame, display: true)
        }
        view.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel(_ screenFrame: CGRect) {
        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private final class OverlayView: NSView {
        var snapshot = Snapshot()

        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.clear(bounds)

            drawRects(snapshot.freeRects, color: NSColor.systemGreen.withAlphaComponent(0.05),
                      stroke: NSColor.systemGreen.withAlphaComponent(0.55), in: ctx, label: "free")
            drawRects(snapshot.obstacles, color: NSColor.systemRed.withAlphaComponent(0.10),
                      stroke: NSColor.systemRed.withAlphaComponent(0.65), in: ctx, label: "obstacle")
            drawRects(snapshot.alternatives, color: NSColor.systemYellow.withAlphaComponent(0.10),
                      stroke: NSColor.systemYellow.withAlphaComponent(0.7), in: ctx, label: nil)
            drawRects([snapshot.target], color: NSColor.systemBlue.withAlphaComponent(0.22),
                      stroke: NSColor.systemBlue, in: ctx, label: "target")
            drawRects([snapshot.current], color: .clear,
                      stroke: NSColor.white.withAlphaComponent(0.9), in: ctx, label: "current", dashed: true)
            drawCaption(in: ctx)
        }

        private func drawRects(_ rects: [CGRect],
                               color: NSColor,
                               stroke: NSColor,
                               in ctx: CGContext,
                               label: String?,
                               dashed: Bool = false) {
            for rect in rects where rect.width > 1 && rect.height > 1 {
                let path = CGPath(rect: rect, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()

                ctx.addPath(path)
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(1.5)
                if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) } else { ctx.setLineDash(phase: 0, lengths: []) }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])

                if let label {
                    let text = "\(label) \(Int(rect.width))×\(Int(rect.height))"
                    draw(text: text, at: CGPoint(x: rect.minX + 4, y: rect.maxY - 14), color: stroke)
                }
            }
        }

        private func drawCaption(in ctx: CGContext) {
            let lines = [
                "FLOW spatial",
                "score \(String(format: "%.2f", snapshot.score))",
                snapshot.reason,
            ]
            let origin = CGPoint(x: 24, y: bounds.height - 24)
            for (index, line) in lines.enumerated() {
                draw(text: line,
                     at: CGPoint(x: origin.x, y: origin.y - CGFloat(index) * 16),
                     color: NSColor.systemBlue)
            }
        }

        private func draw(text: String, at point: CGPoint, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
            ]
            NSAttributedString(string: text, attributes: attributes)
                .draw(at: point)
        }
    }
}
