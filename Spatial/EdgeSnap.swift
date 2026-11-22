import Foundation

/// 边缘吸附。
///
/// 只在四条边各自距离小于阈值时吸附，且**四条边独立判断**：
/// 窗口停在左下角时两侧都应吸住，而不是只吸最近的一条。
enum EdgeSnap {
    static let defaultDistance: CGFloat = 12

    static func snap(_ frame: CGRect, in zone: CGRect, distance: CGFloat = defaultDistance) -> CGRect {
        guard distance > 0, !zone.isEmpty else { return frame }
        var result = frame

        if abs(result.minX - zone.minX) <= distance { result.origin.x = zone.minX }
        if abs(result.maxX - zone.maxX) <= distance { result.origin.x = zone.maxX - result.width }
        if abs(result.minY - zone.minY) <= distance { result.origin.y = zone.minY }
        if abs(result.maxY - zone.maxY) <= distance { result.origin.y = zone.maxY - result.height }

        return result
    }
}
