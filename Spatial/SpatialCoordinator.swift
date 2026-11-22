import AppKit
import Foundation

/// 空间协调器：把系统事实（屏幕、前台应用、窗口几何、权限）变成一份快照，再交给求解器。
///
/// 职责边界：
/// - 只读几何，不读窗口标题、文档内容或任何文本；
/// - 未授权时返回空障碍物集合，让求解器退化为"安全区 + 边缘偏好"的基础模式；
/// - 不移动窗口，只产出 `PlacementDecision`，由悬浮控制器执行。
@MainActor
final class SpatialCoordinator {
    private let accessibility: AccessibilityManager
    private let reader = WindowGeometryReader()
    private(set) var solver: PlacementSolver
    private(set) var machine: SpatialStateMachine
    private(set) var permission: AccessibilityPermission = .unknown

    init(accessibility: AccessibilityManager,
         solver: PlacementSolver = PlacementSolver(),
         tuning: PlacementTuning = PlacementTuning()) {
        self.accessibility = accessibility
        self.solver = solver
        self.machine = SpatialStateMachine(tuning: tuning)
    }

    var tuning: PlacementTuning { machine.tuning }
    var isFullscreen: Bool { machine.isFullscreen }

    /// 事件统一入口。外部不改状态机内部，只把事件交进来、拿回结论。
    @discardableResult
    func handle(_ event: SpatialEvent, now: Instant = ContinuousClock().now) -> SpatialOutcome {
        machine.handle(event, now: now)
    }
    var isSuspended: Bool { machine.isAsleep }

    /// 当前前台应用是否处于全屏。用 CGWindowList 边界判定，无需任何权限。
    func detectFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let screen = NSScreen.main else { return false }
        return reader.isFrontmostFullscreen(pid: app.processIdentifier, screenFrame: screen.frame)
    }

    /// 前台应用的窗口几何（AppKit 坐标系），已做过滤。
    func obstacles(for geometry: ScreenGeometry) -> [CGRect] {
        // 节流查询：这里每次扫描都会被调到（约 2 秒一次），而权限状态是低频事实。
        permission = accessibility.refreshIfStale()
        guard permission.allowsWindowInspection else { return [] }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return []
        }

        return reader.windowFrames(forPID: app.processIdentifier)
            .filter { $0.intersects(geometry.frame) }
            .map { $0.clampedForObstacle(in: geometry.frame) }
    }

    /// 关闭自动避让后，求解器只考虑安全区，不再回避前台窗口。
    var autoAvoidEnabled = true

    func evaluate(screen: ScreenGeometry,
                  currentFrame: CGRect?,
                  shape: LyricsShape,
                  isLocked: Bool,
                  preferredOrigin: CGPoint?) -> PlacementDecision {
        let frames = autoAvoidEnabled ? obstacles(for: screen) : []
        let app = NSWorkspace.shared.frontmostApplication
        let frontmost = app.map {
            FrontmostAppInfo(
                bundleID: $0.bundleIdentifier,
                name: $0.localizedName ?? "",
                isFullscreen: reader.isFrontmostFullscreen(
                    pid: $0.processIdentifier,
                    screenFrame: screen.frame
                ) && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            )
        }

        let snapshot = SpatialSnapshot(
            displayID: screen.id,
            safeZone: screen.safeZone,
            screenFrame: screen.frame,
            obstacles: frames,
            frontmostApp: frontmost,
            floatingFrame: currentFrame,
            preferredSize: shape.preferredSize,
            currentShape: shape,
            userPreferredOrigin: preferredOrigin,
            isLocked: isLocked,
            permission: permission
        )

        return solver.solve(snapshot)
    }

    /// 归一化的用户偏好位置。安全区尺寸变化后仍能按比例恢复。
    nonisolated static func normalized(origin: CGPoint, shape: LyricsShape, in zone: CGRect) -> CGPoint {
        guard zone.width > 0, zone.height > 0 else { return CGPoint(x: 0.5, y: 0.9) }
        return CGPoint(
            x: min(max((origin.x - zone.minX) / zone.width, 0), 1),
            y: min(max((origin.y - zone.minY) / zone.height, 0), 1)
        )
    }

    nonisolated static func denormalized(_ point: CGPoint, shape: LyricsShape, in zone: CGRect) -> CGRect {
        let size = shape.preferredSize
        var frame = CGRect(
            x: zone.minX + point.x * zone.width,
            y: zone.minY + point.y * zone.height,
            width: size.width,
            height: size.height
        )
        frame = frame.clamped(into: zone)
        return frame
    }
}

private extension CGRect {
    /// 障碍物按屏幕裁剪：跨屏窗口只保留落在本屏内的部分。
    func clampedForObstacle(in screenFrame: CGRect) -> CGRect {
        let clipped = intersection(screenFrame)
        return clipped.isNull ? self : clipped
    }
}
