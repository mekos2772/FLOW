import AppKit
import SwiftUI

/// 自适应调试面板的数据源。
///
/// 只放"决策用到的原始事实 + 决策结果"，不放任何业务对象：
/// 这样面板永远不会因为读不到某个模块而失真，也不会反向影响决策。
@Observable
@MainActor
final class SpatialDebugModel {
    var frontApp: String = "—"
    var permission: String = "—"
    var safeZone: CGRect = .zero
    var frontWindows: [CGRect] = []
    var playerFrame: CGRect = .zero
    var candidates: [CGRect] = []
    var currentMorphology: String = "—"
    var recommendedMorphology: String = "—"
    var targetFrame: CGRect = .zero
    var note: String = "—"
    var isLocked = false
    var isCooldown = false
    var overlap: Double = 0
    var sequence: UInt64 = 0
    var isFrontmost = false
}

/// 开发态调试面板。只有 `SLP_DEBUG_SPATIAL=1` 时才创建，正式界面里不存在。
@MainActor
final class SpatialDebugPanel {
    private let model = SpatialDebugModel()
    private var panel: NSPanel?

    var isEnabled: Bool { ProcessInfo.processInfo.environment["SLP_DEBUG_SPATIAL"] == "1" }

    func update(_ mutate: (SpatialDebugModel) -> Void) {
        guard isEnabled else { return }
        mutate(model)
        if panel == nil { makePanel() }
    }

    private func makePanel() {
        let hosting = NSHostingView(rootView: SpatialDebugView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 336,
                                        y: screen.visibleFrame.maxY - 436))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct SpatialDebugView: View {
    @Bindable var model: SpatialDebugModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("FLOW · 空间决策")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            row("seq", "\(model.sequence)")
            row("前台", model.frontApp)
            row("我在前台", model.isFrontmost ? "是" : "否")
            row("AX", model.permission)
            row("锁定", model.isLocked ? "位置/形态已锁" : "未锁")
            row("冷却", model.isCooldown ? "动画中/冷却" : "可切换")
            row("形态", "\(model.currentMorphology) → \(model.recommendedMorphology)")
            row("遮挡", "\(Int(model.overlap * 100))%")
            row("屏幕", rect(model.safeZone))
            row("播放器", rect(model.playerFrame))
            row("目标", rect(model.targetFrame))
            row("前台窗口", model.frontWindows.isEmpty ? "无" : "\(model.frontWindows.count) 个")
            ForEach(Array(model.frontWindows.prefix(3).enumerated()), id: \.offset) { _, r in
                Text("  " + rect(r))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            row("候选区", "\(model.candidates.count) 个")
            ForEach(Array(model.candidates.prefix(3).enumerated()), id: \.offset) { _, r in
                Text("  " + rect(r))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            Text(model.note)
                .font(.system(size: 9, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
        }
    }

    private func rect(_ r: CGRect) -> String {
        String(format: "%.0f,%.0f %.0f×%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }
}
