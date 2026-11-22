import SwiftUI

/// 胶囊形分段切换：几段文字并排，选中的那段垫一块底色，切换时底色滑过去。
///
/// 两种外观：`standard` 跟随黑白版面（浅色黑字 / 深色白字）；`glass` 用在沉浸页这种
/// 动态画面上——半透明深色底、白字，和沉浸页的圆形按钮同一套语言。
struct FlowSegmentedSwitch<Value: Hashable>: View {
    enum Style {
        case standard
        case glass
    }

    struct Item {
        let value: Value
        let title: String
        /// 无障碍标识：自动化与验收按它找按钮。
        let identifier: String
    }

    let items: [Item]
    let selection: Value
    var style: Style = .standard
    let onSelect: (Value) -> Void

    @Namespace private var namespace
    @State private var hovering: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button { onSelect(item.value) } label: {
                    Text(item.title)
                        .flowType(.homeSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(foreground(selected: selected, hovering: hovering == item.value))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(selectionFill)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovering = inside ? item.value : (hovering == item.value ? nil : hovering) }
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(item.identifier)
            }
        }
        .padding(3)
        .background(Capsule().fill(trackFill))
        .animation(Motion.respectingReduceMotion(Motion.spring(response: 0.32, bounce: 0.12), reduceMotion: reduceMotion),
                   value: selection)
    }

    private var trackFill: Color {
        switch style {
        case .standard: return FlowColor.hover
        case .glass: return Color.black.opacity(0.30)
        }
    }

    private var selectionFill: Color {
        switch style {
        case .standard: return Color.primary.opacity(0.12)
        case .glass: return Color.white.opacity(0.22)
        }
    }

    private func foreground(selected: Bool, hovering: Bool) -> Color {
        switch style {
        case .standard:
            return selected || hovering ? Color.primary : FlowColor.secondaryText
        case .glass:
            return Color.white.opacity(selected ? 1 : (hovering ? 0.9 : 0.68))
        }
    }
}
