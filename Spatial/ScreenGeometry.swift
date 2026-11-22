import AppKit
import Foundation

/// 一个显示器的几何快照。
///
/// 坐标系约定：全部使用 AppKit 全局坐标系（原点在主屏左下角，Y 向上），
/// 这样窗口 frame 与屏幕矩形可以直接相减，不需要做翻转转换。
/// `visibleFrame` 已由系统扣除菜单栏与 Dock，**不要**再扣一次。
struct ScreenGeometry: Identifiable, Equatable, Sendable {
    /// 稳定标识。用的是 CGDisplay 的 UUID，而不是 NSScreen 的对象地址或数组下标——
    /// 后者在插拔显示器、改分辨率后都会变，拿来当记忆键会导致"位置记到别的屏幕上"。
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
    /// 刘海等内容的额外内缩。非刘海屏为 0。
    let safeAreaTopInset: CGFloat

    var safeZone: CGRect { ScreenGeometry.safeZone(frame: frame, visibleFrame: visibleFrame, topInset: safeAreaTopInset) }

    /// 安全区计算。
    ///
    /// 只有当可见区域顶到屏幕物理顶部（菜单栏被自动隐藏）时，才把刘海内缩再扣一次；
    /// 否则菜单栏已经覆盖了刘海区域，重复扣除会让歌词无谓地下移。
    static func safeZone(frame: CGRect, visibleFrame: CGRect, topInset: CGFloat) -> CGRect {
        var zone = visibleFrame
        let menuBarHidden = abs(visibleFrame.maxY - frame.maxY) < 0.5
        if menuBarHidden, topInset > 0, zone.height > topInset {
            zone.size.height -= topInset
        }
        return zone
    }
}

enum ScreenGeometryResolver {
    /// 每次调用都重新读系统状态，不缓存 `visibleFrame`——分辨率、Dock 位置、菜单栏自动隐藏都会让它过期。
    @MainActor
    static func current() -> [ScreenGeometry] {
        NSScreen.screens.map { geometry(for: $0) }
    }

    @MainActor
    static func geometry(for screen: NSScreen) -> ScreenGeometry {
        ScreenGeometry(
            id: displayUUID(for: screen) ?? fallbackID(for: screen),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top
        )
    }

    @MainActor
    static func screen(withID id: String) -> NSScreen? {
        NSScreen.screens.first { displayUUID(for: $0) == id }
    }

    @MainActor
    static func mainScreenGeometry() -> ScreenGeometry {
        if let screen = NSScreen.main { return geometry(for: screen) }
        return ScreenGeometry(id: "fallback", frame: .zero, visibleFrame: .zero, safeAreaTopInset: 0)
    }

    /// CGDisplay UUID 是跨启动稳定的显示器标识。
    @MainActor
    static func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    @MainActor
    private static func fallbackID(for screen: NSScreen) -> String {
        let origin = screen.frame.origin
        return "fallback-\(Int(origin.x))x\(Int(origin.y))"
    }
}

extension CGRect {
    /// 把窗口框钳制进安全区；框比安全区还大时贴安全区左上角，保证可见。
    func clamped(into zone: CGRect, margin: CGFloat = 4) -> CGRect {
        guard !zone.isEmpty else { return self }
        let inner = zone.insetBy(dx: margin, dy: margin)
        guard inner.width > 0, inner.height > 0 else { return self }

        var result = self
        if result.width > inner.width { result.size.width = inner.width }
        if result.height > inner.height { result.size.height = inner.height }
        if result.maxX > inner.maxX { result.origin.x = inner.maxX - result.width }
        if result.minX < inner.minX { result.origin.x = inner.minX }
        if result.maxY > inner.maxY { result.origin.y = inner.maxY - result.height }
        if result.minY < inner.minY { result.origin.y = inner.minY }
        return result
    }
}
