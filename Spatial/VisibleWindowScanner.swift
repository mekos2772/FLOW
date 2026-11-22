import AppKit
import CoreGraphics

/// 屏幕上所有可见窗口的几何扫描。
///
/// 为什么不用 Accessibility：AX 只能可靠地读**指定进程**的窗口，
/// 而"别挡着任何人的窗口"需要看到整块桌面。用户截图里的场景就是反例——
/// 前台是 Chrome，但中间还压着另一个应用的窗口，只看前台应用就会以为"没遮挡"。
///
/// `CGWindowListCopyWindowInfo` 是公开 API，**不需要辅助功能权限**就能拿到
/// 每个窗口的归属进程、层级与边框（标题需要屏幕录制权限，我们不用标题）。
/// 所以这里只取几何，不读任何窗口内容。
enum VisibleWindowScanner {

    /// 合并两路障碍物来源。
    ///
    /// 关键约束（规格 §十二 I）：**未授权时不得假装识别了外部窗口**——
    /// AX 那一路必须整段丢弃，只保留不需要权限的窗口扫描结果。
    static func merge(visible: [CGRect],
                      accessibilityRects: [CGRect],
                      permission: AccessibilityPermission) -> [CGRect] {
        permission.allowsWindowInspection ? visible + accessibilityRects : visible
    }

    /// 返回屏幕坐标系（AppKit，左下原点）下的窗口矩形，已排除：
    /// - 本应用自己的窗口
    /// - 非普通层级（菜单栏、Dock、悬浮面板、桌面背景）
    /// - 最小化 / 不在屏上 / 面积过小（状态条、阴影残片）
    static func obstacleRects(excludingPID pid: pid_t,
                              screenFrame: CGRect,
                              minimumArea: CGFloat = 120 * 80) -> [CGRect] {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        return scanObstacles(excludingPID: pid, screenFrame: screenFrame,
                             primaryMaxY: primaryMaxY, minimumArea: minimumArea)
    }

    /// 完整一次扫描。**不读 AppKit 状态**，可以安全地在后台线程调用——
    /// 主线程同步跑枚举时实测峰值 53ms，会直接吞掉动画的一帧。
    nonisolated static func scanObstacles(excludingPID pid: pid_t,
                                          screenFrame: CGRect,
                                          primaryMaxY: CGFloat,
                                          minimumArea: CGFloat = 120 * 80) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return obstacleRects(in: list, excludingPID: pid, screenFrame: screenFrame,
                             primaryMaxY: primaryMaxY, minimumArea: minimumArea)
    }

    /// 固定 WindowServer 快照可测：他人全屏是有效障碍，只有自己的 PID 应被排除。
    static func obstacleRects(in list: [[String: Any]], excludingPID pid: pid_t,
                              screenFrame: CGRect, primaryMaxY: CGFloat,
                              minimumArea: CGFloat = 120 * 80) -> [CGRect] {        var rects: [CGRect] = []
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != pid else { continue }
            // 只要普通窗口层（0）。菜单栏、悬浮面板、Dock 图标都在别的层。
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            // 明确标记为"不在屏上"的跳过。
            if let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, !onScreen { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            // CG 坐标（左上原点）→ AppKit 坐标（左下原点），以主屏高度为基准。
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            let rect = appKitRect(cgRect, primaryMaxY: primaryMaxY).intersection(screenFrame)
            guard rect.width > 1, rect.height > 1 else { continue }
            guard rect.width * rect.height >= minimumArea else { continue }
            rects.append(rect)
        }
        return FreeSpaceAnalyzer.pruneContained(rects).sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
    }

    /// 所有显示器共用主屏的左上原点，不按目标副屏翻转 y。
    static func appKitRect(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
