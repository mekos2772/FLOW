import AppKit
import SwiftUI

/// 从封面取"氛围色"（规格 8.3）：代表性颜色 → 降饱和 → 调亮度 → 供背景渐变使用。
///
/// 取色在 CPU 上做：把封面缩到 1×1 再读像素，等价于面积平均，比逐像素遍历便宜得多，
/// 也不会因为一两块高饱和区域而跑偏。
enum ArtworkPalette {

    struct Color: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        var swiftUIColor: SwiftUI.Color {
            SwiftUI.Color(red: red, green: green, blue: blue)
        }
    }

    /// - Parameters:
    ///   - image: 封面图
    ///   - saturation: 目标饱和度上限（0…1）。默认 0.35，够有颜色又不刺眼。
    ///   - brightness: 目标亮度上限。默认 0.62，保证压在它上面的浅色文字仍可读。
    static func ambient(from image: NSImage?,
                        saturation: Double = 0.0,
                        brightness: Double = 0.55) -> Color? {
        guard let image, let average = averageColor(of: image) else { return nil }
        return adjusted(average, saturation: saturation, brightness: brightness)
    }

    /// 面积平均色。失败返回 nil，调用方回退到系统强调色。
    static func averageColor(of image: NSImage) -> Color? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixel,
                                      width: 1, height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Color(red: Double(pixel[0]) / 255,
                     green: Double(pixel[1]) / 255,
                     blue: Double(pixel[2]) / 255)
    }

    /// 降饱和 + 夹亮度。用 HSB 而不是直接缩放 RGB，才能保住色相不偏。
    static func adjusted(_ color: Color,
                         saturation: Double,
                         brightness: Double) -> Color {
        let hsb = rgbToHSB(color)
        let s = min(hsb.s, saturation)
        let b = min(hsb.b, brightness)
        return hsbToRGB(h: hsb.h, s: s, b: b)
    }

    // MARK: - 色彩空间换算（纯函数，可单测）

    static func rgbToHSB(_ color: Color) -> (h: Double, s: Double, b: Double) {
        let maxV = max(color.red, color.green, color.blue)
        let minV = min(color.red, color.green, color.blue)
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0 {
            if maxV == color.red {
                hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let sat = maxV == 0 ? 0 : delta / maxV
        return (hue, sat, maxV)
    }

    static func hsbToRGB(h: Double, s: Double, b: Double) -> Color {
        let c = b * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r, g, bl): (Double, Double, Double)
        switch h * 6 {
        case ..<1: (r, g, bl) = (c, x, 0)
        case ..<2: (r, g, bl) = (x, c, 0)
        case ..<3: (r, g, bl) = (0, c, x)
        case ..<4: (r, g, bl) = (0, x, c)
        case ..<5: (r, g, bl) = (x, 0, c)
        default:   (r, g, bl) = (c, 0, x)
        }
        return Color(red: r + m, green: g + m, blue: bl + m)
    }
}
