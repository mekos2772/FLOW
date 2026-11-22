import SwiftUI

/// 细轨道滑杆（进度/音量共用）。
///
/// 为什么不用 `Slider`：系统滑杆轨道粗、滑块大且高亮，放在沉浸式播放器里过于抢眼。
/// 这里轨道 3pt、滑块 10pt，但**可点击区域仍是整条 20pt 高**——
/// 视觉上细，操作上不细（规格 9.1「拖动时增加可操作区域」）。
struct HairlineSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onEditingChanged: (Bool) -> Void = { _ in }
    var accessibilityLabel: String
    /// 把 2pt 轨道贴到可用高度的底部（迷你条用：线要压在卡片下沿）。
    var pinsTrackToBottom = false

    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // 更细的轨道 + 更小的滑块：进度线是"刻线"，不是控件条。
            let knob: CGFloat = isDragging || isHovering ? 10 : 8
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.10))
                    .frame(height: 2)
                Capsule()
                    // 已播部分是页面里第二处纯黑（第一处是播放键），对比要干净利落。
                    .fill(.primary.opacity(isDragging ? 1 : 0.88))
                    .frame(width: max(0, width * progress), height: 2)
                Circle()
                    .fill(.primary.opacity(0.9))
                    .frame(width: knob, height: knob)
                    .offset(x: max(0, width * progress - knob / 2))
                    .opacity(isHovering || isDragging ? 1 : 0)   // 静止时隐藏滑块，只留轨道
            }
            .frame(height: geo.size.height, alignment: pinsTrackToBottom ? .bottom : .center)
            .contentShape(Rectangle())
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.micro), reduceMotion: reduceMotion),
                       value: isHovering)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        apply(gesture.location.x, width: width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 20)
        // 交给系统滑杆去表达无障碍语义。
        //
        // 手写 `accessibilityElement()` + label + value 时，VoiceOver 拿到的是
        // `AXUnknown` + increment/decrement 两个动作：能读百分比，但**不认为它是滑杆**
        // （实测 `AXSubrole = nil`，也没有 AXValue 可写）。`accessibilityRepresentation`
        // 让一个真实的 `Slider` 顶替自定义外观，角色、值、可调动作都对了，
        // 而画面仍是细轨道那一套。
        .accessibilityRepresentation {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged) { Text(accessibilityLabel) }
        }
    }

    private func apply(_ x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let ratio = min(max(x / width, 0), 1)
        value = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
    }
}
