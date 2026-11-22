import AppKit
import SwiftUI

extension ImmersivePalette {
    /// 当前封面的角色色。隐私模式或没有封面时用默认的暮色；取色放在后台线程。
    static func forArtwork(_ image: NSImage?, masked: Bool) async -> ImmersivePalette {
        guard !masked, let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .dusk
        }
        let extracted = await Task.detached(priority: .utility) {
            ImmersivePalette.extract(from: cgImage)
        }.value
        return extracted ?? .dusk
    }

    /// 第 `index` 个角色色（0 底色 … 4 光色），从线性 RGB 编码回 sRGB 给 SwiftUI 用。
    func color(_ index: Int) -> Color {
        let c = colors[min(max(index, 0), colors.count - 1)]
        func encode(_ v: Float) -> Double {
            let x = Double(min(max(v, 0), 1))
            return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return Color(red: encode(c.x), green: encode(c.y), blue: encode(c.z))
    }
}
