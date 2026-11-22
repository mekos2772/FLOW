import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 前台窗口几何读取。
///
/// 两条来源，职责不同：
/// - **AX**（需授权）：读取前台应用的窗口列表与位置尺寸，用于障碍物建模。
/// - **CGWindowList**（无需授权）：只用窗口边界判断是否全屏，不读取任何窗口内容或标题。
///
/// AX 的全局坐标以主屏左上角为原点、Y 向下；AppKit 以主屏左下角为原点、Y 向上。
/// 转换公式 `appKitY = primaryHeight - axY - height` 只在这里做一次，避免坐标含义在层间扩散。
@MainActor
struct WindowGeometryReader {
    private var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // MARK: - AX

    func windowFrames(forPID pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }

        var frames: [CGRect] = []
        for window in windows {
            if isMinimized(window) { continue }
            // 桌面本身也是 Finder 的一个"窗口"（role=AXScrollArea / subrole=AXDesktop），
            // 它铺满整块屏幕。把它当障碍物会得出"桌面上没有任何空隙"，
            // 于是播放器只要一切走就立刻隐匿——这是实测抓到的真实缺陷。
            guard Self.isObstacleCandidate(role: Self.stringValue(window, kAXRoleAttribute),
                                           subrole: Self.stringValue(window, kAXSubroleAttribute))
            else { continue }

            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                continue
            }
            guard let origin = Self.point(from: positionRef),
                  let size = Self.size(from: sizeRef) else { continue }

            // 明显无效的几何数据直接丢弃，避免污染障碍物集合。
            guard size.width >= 80, size.height >= 60, size.width.isFinite, size.height.isFinite else { continue }

            frames.append(CGRect(x: origin.x, y: primaryHeight - origin.y - size.height,
                                 width: size.width, height: size.height))
        }
        return frames
    }

    /// 只有真正的窗口才算障碍物。
    ///
    /// 规则：role 必须是 `AXWindow`；subrole 是 `AXDesktop` 的一律排除。
    /// 抽成纯函数是为了能对着字符串单测，不必真的把 Finder 拉起来。
    static func isObstacleCandidate(role: String?, subrole: String?) -> Bool {
        guard role == "AXWindow" else { return false }
        if subrole == "AXDesktop" { return false }
        return true
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success else {
            return false
        }
        return (minimizedRef as? Bool) ?? false
    }

    private static func point(from ref: CFTypeRef?) -> CGPoint? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard let axValue = unsafeDowncast(ref, to: AXValue.self) as AXValue? else { return nil }
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(from ref: CFTypeRef?) -> CGSize? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard let axValue = unsafeDowncast(ref, to: AXValue.self) as AXValue? else { return nil }
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - CGWindowList（无需授权）

    struct WindowServerWindow: Sendable, Equatable {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    func onScreenWindows() -> [WindowServerWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let height = primaryHeight
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            guard w > 0, h > 0 else { return nil }
            return WindowServerWindow(
                pid: pid,
                layer: layer,
                bounds: CGRect(x: x, y: height - y - h, width: w, height: h)
            )
        }
    }

    /// 全屏判定：前台应用存在一个覆盖整块屏幕、层级为 0 的窗口。
    /// 这里只用边界，不需要任何权限，也不读取窗口标题。
    func isFrontmostFullscreen(pid: pid_t, screenFrame: CGRect, tolerance: CGFloat = 2) -> Bool {
        onScreenWindows().contains { window in
            guard window.pid == pid, window.layer == 0 else { return false }
            return abs(window.bounds.minX - screenFrame.minX) <= tolerance
                && abs(window.bounds.minY - screenFrame.minY) <= tolerance
                && abs(window.bounds.width - screenFrame.width) <= tolerance
                && abs(window.bounds.height - screenFrame.height) <= tolerance
        }
    }
}
