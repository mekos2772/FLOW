import SwiftUI

/// 播放错误条。
///
/// 规格 8.4：加载失败、文件不存在、无权限、地址失效、格式不支持都要有**明确提示 + 下一步**，
/// 不能静默吞掉。这里给出"发生了什么 + 为什么 + 能做什么"三段，
/// 并把重试/跳过做成两个文字按钮，不弹窗、不打断当前版面。
struct PlaybackErrorStrip: View {
    @Bindable var model: MorphPresentationModel
    /// 重试。
    var onRetry: () -> Void
    /// 跳到下一首。
    var onSkip: () -> Void
    /// 可选快捷修复动作标题（例如允许联网、前往设置检查音源）。
    var quickFixTitle: LocalizedStringKey? = nil
    /// 可选快捷修复动作。
    var onQuickFix: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let error = model.error {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                flowIcon(systemName: "exclamationmark.triangle.fill", size: 11)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(error.title)
                        .flowType(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(error.detail)
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: Spacing.s)

                HStack(spacing: Spacing.xs) {
                    if let quickFixTitle, let onQuickFix {
                        FlowTextButton(title: quickFixTitle, symbolName: "wrench.and.screwdriver", prominent: true, action: onQuickFix)
                    }
                    if error.offersRetry {
                        FlowTextButton(title: "重试", symbolName: "arrow.clockwise", action: onRetry)
                    }
                    if error.suggestsSkip || model.queue.items.count > 1 {
                        FlowTextButton(title: "跳过", symbolName: "forward.end", action: onSkip)
                    }
                }
            }
            .padding(.vertical, 6)
            .transition(.opacity)
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion),
                       value: model.error)
            // 用 .contain 而不是 .combine：合并会把"重试/跳过"也压成一个元素，
            // VoiceOver 就点不到这两个按钮了（实测 AX 树里整条变成一个 AXButton）。
            .accessibilityElement(children: .contain)
            .accessibilityLabel("播放出错")
        }
    }
}
