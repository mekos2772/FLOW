import AppKit
import CoreImage
import Foundation

/// 通用的二维码图像生成器（CoreImage，不依赖第三方库）。
enum QRImageRenderer {
    nonisolated static func make(for text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: transformed.extent.width, height: transformed.extent.height)
        )
    }
}
