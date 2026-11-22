import AppKit
import ApplicationServices
import Foundation

/// AX 只提供事件；窗口几何从 WindowServer 获取，不在拖动热路径同步读取外部属性。
@MainActor
final class AXWindowObserver {
    var onGeometryChanged: (() -> Void)?
    private var observer: AXObserver?
    private var trackedPID: pid_t = 0
    private var trackedWindows: [AXUIElement] = []

    private static let windowNotifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    @discardableResult
    func start(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if pid == trackedPID { return observer != nil }
        stop()
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &newObserver) == .success,
              let newObserver else { return false }
        observer = newObserver
        trackedPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(newObserver, app, notification as CFString, refcon)
        }
        refreshWindows()
        // 拖窗处于 eventTracking 模式，defaultMode 会把回调拖到鼠标松开之后。
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        return true
    }

    private func refreshWindows() {
        guard let observer else { return }
        let app = AXUIElementCreateApplication(trackedPID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in trackedWindows where !windows.contains(where: { CFEqual($0, window) }) {
            for notification in Self.windowNotifications {
                AXObserverRemoveNotification(observer, window, notification as CFString)
            }
        }
        for window in windows where !trackedWindows.contains(where: { CFEqual($0, window) }) {
            AXUIElementSetMessagingTimeout(window, 0.05)
            for notification in Self.windowNotifications {
                AXObserverAddNotification(observer, window, notification as CFString, refcon)
            }
        }
        trackedWindows = windows
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        trackedWindows = []
        trackedPID = 0
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<AXWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        Task { @MainActor [weak watcher] in
            guard let watcher else { return }
            if name == kAXWindowCreatedNotification || name == kAXFocusedWindowChangedNotification
                || name == kAXUIElementDestroyedNotification {
                watcher.refreshWindows()
            }
            watcher.onGeometryChanged?()
        }
    }
}
