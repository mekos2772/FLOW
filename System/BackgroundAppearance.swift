import CoreGraphics
import Foundation

/// 自动只改变悬浮播放器；完整播放器与设置窗仍保持系统外观。
enum FloatingAppearanceMode: String, CaseIterable, Sendable {
    case background, system, light, dark

    var displayName: String {
        switch self {
        case .background: return "跟随背景"
        case .system: return "跟随系统"
        case .light: return "始终浅色"
        case .dark: return "始终深色"
        }
    }
}

/// 一个色调值，历史上被当成**两种含义**混用，这是"深色壁纸上卡片变黑"的根因：
///
/// 1. **背景色调**（`BackgroundAppearancePolicy.classification` 的产物）：这块壁纸本身亮还是暗；
/// 2. **卡片色调**（`MorphPresentationModel.floatingTone` 的语义）：悬浮底板按哪套外观渲染。
///
/// 两者**永远相反**——卡片要和壁纸拉开对比才看得见。深色壁纸配浅色卡片，浅色壁纸配深色卡片。
/// 之前自动判色把背景色调直接当成卡片色调应用，于是深色壁纸（luma 0.09）被判成 `.dark`，
/// 卡片也成了黑底白字，压在近乎纯黑的壁纸上等于消失（用户反馈"深色背景下转成黑色了"）。
///
/// 现在用 `contrastingCardTone` 显式表达这层关系；手动设置（"始终浅色/始终深色"）
/// 里的 `.light`/`.dark` 仍然直接表示**卡片**色调，不经过这个转换。
enum BackgroundTone: String, Sendable {
    case light, dark

    /// 卡片应当采用的外观：与背景相反。
    var contrastingCardTone: BackgroundTone {
        self == .light ? .dark : .light
    }
}

/// 一次背景采样：亮度均值 + 空间反差（标准差）。
struct BackgroundSample: Sendable, Equatable {
    var meanLuma: Double
    /// 0 = 均匀纯色；越大说明这块背景明暗混杂。
    var contrast: Double
}

/// 深浅判定。
///
/// 只做**有把握**的切换，其余跟随系统：
/// - 背景必须既够亮/够暗，又相对均匀，才算"看得准"；
/// - 明暗混杂（比如壁纸上有亮控件卡 + 深色照片）时平均亮度没有意义，
///   强行切换会得到一张与整机外观相反的白卡——这正是"颜色不统一"的来源；
/// - 采样源本身也可能不可信（`desktopImageURL` 指向系统默认航拍图的符号链接，
///   而屏幕上是另一张图），所以宁可不判。
struct BackgroundAppearancePolicy: Sendable {
    private(set) var tone: BackgroundTone?
    private var pending: BackgroundTone?
    private var since: ContinuousClock.Instant?
    let stability: Duration = .milliseconds(280)

    /// 判定为浅底的门槛：够亮 **且** 够均匀。
    static let lightMeanThreshold = 0.72
    static let lightMaximumContrast = 0.16
    /// 判定为深底的门槛。
    static let darkMeanThreshold = 0.35
    static let darkMaximumContrast = 0.22

    mutating func reset() { tone = nil; pending = nil; since = nil }

    /// 把一次采样解释成目标色调；证据不足时返回 nil（交给系统外观）。
    static func classification(of sample: BackgroundSample) -> BackgroundTone? {
        guard sample.meanLuma.isFinite, (0...1).contains(sample.meanLuma),
              sample.contrast.isFinite, sample.contrast >= 0 else { return nil }
        if sample.meanLuma >= lightMeanThreshold, sample.contrast <= lightMaximumContrast {
            return .light
        }
        if sample.meanLuma <= darkMeanThreshold, sample.contrast <= darkMaximumContrast {
            return .dark
        }
        return nil
    }

    /// 返回还需等待的时间；首次有效采样立刻应用，其后的反转要求稳定 280ms。
    mutating func observe(_ sample: BackgroundSample?, now: ContinuousClock.Instant) -> Duration? {
        guard let sample else { reset(); return nil }
        guard let proposed = Self.classification(of: sample) else {
            // 证据不足：不保持也不切换，交回系统外观。
            reset()
            return nil
        }
        guard let tone else {
            self.tone = proposed
            return nil
        }
        guard proposed != tone else { pending = nil; since = nil; return nil }
        if pending != proposed { pending = proposed; since = now }
        let deadline = (since ?? now).advanced(by: stability)
        if now >= deadline {
            self.tone = proposed
            pending = nil; since = nil
            return nil
        }
        return now.duration(to: deadline)
    }
}

/// 墙纸在屏幕上的铺放方式。坐标均为 AppKit 全局坐标，支持非零/负数副屏原点。
enum WallpaperLayout: Sendable, Equatable { case fill, fit, stretch, center }

struct WallpaperSampleRequest: Sendable, Equatable {
    var url: URL
    var screenFrame: CGRect
    var windowFrame: CGRect
    var layout: WallpaperLayout = .fill
    var fillRed: Double = 0
    var fillGreen: Double = 0
    var fillBlue: Double = 0

    func imageRect(imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        if layout == .stretch { return screenFrame }
        let x = screenFrame.width / imageSize.width
        let y = screenFrame.height / imageSize.height
        let scale: CGFloat
        switch layout {
        case .fill: scale = max(x, y)
        case .fit: scale = min(x, y)
        case .center: scale = 1
        case .stretch: scale = 1
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
