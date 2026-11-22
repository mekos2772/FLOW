import CoreGraphics
import Foundation

/// 遮挡面积计算。
///
/// 关键点：多个障碍物矩形**会互相重叠**（同一应用的多个窗口、窗口与其子面板）。
/// 直接把交集面积一个个加起来会算重复，实测出现过"实际只压住 69%，却报 100%"，
/// 于是播放器一直以为没躲开，反复重定位——就是规格 6.8 要防的"重复横跳"。
/// 这里先把裁到目标矩形内的所有片段求并，再算面积。
enum Coverage {
    /// `rect` 被 `obstacles` 覆盖的面积（0…1）。
    static func fraction(of rect: CGRect, by obstacles: [CGRect]) -> Double {
        let area = rect.width * rect.height
        guard area > 0.01, !obstacles.isEmpty else { return 0 }
        let clipped = obstacles.compactMap { obstacle -> CGRect? in
            let inter = obstacle.intersection(rect)
            return inter.isNull || inter.isEmpty ? nil : inter
        }
        guard !clipped.isEmpty else { return 0 }
        return Swift.min(unionArea(clipped) / area, 1)
    }

    /// 一组矩形的并集面积。矩形数量在个位到十几个，用"两两合并到不动点"足够快且好验证。
    static func unionArea(_ rects: [CGRect]) -> CGFloat {
        var merged: [CGRect] = []
        for rect in rects {
            var current = rect
            var index = 0
            while index < merged.count {
                let other = merged[index]
                if current.intersects(other) {
                    current = current.union(other)
                    merged.remove(at: index)
                    index = 0        // 合并后可能又和前面的重叠，重新扫
                } else {
                    index += 1
                }
            }
            merged.append(current)
        }
        return merged.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
    }
}
