import AppKit
import ImageIO

/// 只读系统提供的壁纸文件，不截取屏幕或其他应用内容。
/// 主线程只取 URL/铺放选项；缩略解码与局部亮度采样由后台 actor 缓存执行。
enum WallpaperLuminance {
    @MainActor
    static func request(for screen: NSScreen, windowFrame: CGRect) -> WallpaperSampleRequest? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber)?.uintValue
            ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let layout: WallpaperLayout
        switch scaling {
        case NSImageScaling.scaleAxesIndependently.rawValue: layout = .stretch
        case NSImageScaling.scaleNone.rawValue: layout = .center
        default: layout = clipping ? .fill : .fit
        }
        let fill = fillComponents(options[.fillColor] as? NSColor)
        return WallpaperSampleRequest(url: url, screenFrame: screen.frame, windowFrame: windowFrame,
                                      layout: layout, fillRed: fill.red,
                                      fillGreen: fill.green, fillBlue: fill.blue)
    }

    /// 默认 .black 是灰度色空间，直接取 redComponent 会抛 Objective-C 异常。
    @MainActor
    static func fillComponents(_ color: NSColor?) -> (red: Double, green: Double, blue: Double) {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

}

actor WallpaperLuminanceSampler {
    static let shared = WallpaperLuminanceSampler()

    private struct Raster {
        let image: CGImage
        let originalSize: CGSize
        let modified: Date?
    }
    private var cache: [URL: Raster] = [:]

    func invalidate() { cache.removeAll() }

    func sample(for request: WallpaperSampleRequest) -> BackgroundSample? {
        // URL.resourceValues 会缓存文件属性；同一路径换壁纸后必须读最新 stat。
        let attributes = try? FileManager.default.attributesOfItem(atPath: request.url.path)
        let modified = attributes?[.modificationDate] as? Date
        let raster: Raster
        if let cached = cache[request.url], cached.modified == modified {
            raster = cached
        } else {
            guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
                  // 动态/多帧文件的首帧不等于当前桌面，不拿它伪装实时颜色。
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let size = orientation >= 5
                ? CGSize(width: height.doubleValue, height: width.doubleValue)
                : CGSize(width: width.doubleValue, height: height.doubleValue)
            raster = Raster(image: image, originalSize: size, modified: modified)
            if cache.count >= 3 { cache.removeAll() }
            cache[request.url] = raster
        }
        return Self.sample(image: raster.image, originalSize: raster.originalSize, request: request)
    }

    /// 纯图像路径供确定性测试复用：按真实屏幕铺放后，仅采窗口覆盖区域。
    /// 采样窗口覆盖的背景：返回亮度均值与空间反差。
    ///
    /// 反差是必要的第二个指标：壁纸上一半是亮控件卡、一半是深色照片时，
    /// 平均值落在中间，但观感既不是亮也不是暗——这时不该判深浅。
    nonisolated static func sample(image: CGImage, originalSize: CGSize,
                                   request: WallpaperSampleRequest) -> BackgroundSample? {
        let region = request.windowFrame.intersection(request.screenFrame)
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        let width = 24, height = 16
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red: request.fillRed, green: request.fillGreen,
                                 blue: request.fillBlue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / region.width, y: CGFloat(height) / region.height)
            context.translateBy(x: -region.minX, y: -region.minY)
            context.interpolationQuality = .medium
            context.draw(image, in: request.imageRect(imageSize: originalSize))
            return true
        }
        guard rendered else { return nil }
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let luma = (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
                        + 0.0722 * Double(bytes[index + 2])) / 255.0
            lumas.append(luma)
        }
        guard !lumas.isEmpty else { return nil }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        return BackgroundSample(meanLuma: mean, contrast: variance.squareRoot())
    }
}
