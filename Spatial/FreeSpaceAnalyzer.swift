import CoreGraphics

/// 可用矩形求解。
///
/// 坐标压缩 + 区间扫描：枚举 x 边界对，合并相交障碍物的 y 区间，
/// 再取其补集并剪掉横向包含项。保留精确极大矩形，不依赖像素栅格。
enum FreeSpaceAnalyzer {
    /// 返回所有极大可用矩形，按面积从大到小排序。
    static func maximalRects(in zone: CGRect, obstacles: [CGRect]) -> [CGRect] {
        guard zone.width > 0, zone.height > 0 else { return [] }

        let clipped = obstacles
            .map { $0.intersection(zone) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }

        guard !clipped.isEmpty else { return [zone] }

        var xs: [CGFloat] = [zone.minX, zone.maxX]
        for rect in clipped {
            xs.append(rect.minX); xs.append(rect.maxX)
        }
        xs = dedupeSorted(xs.filter { $0 >= zone.minX && $0 <= zone.maxX })

        // 对每个 x 区间只求 y 轴障碍物并集的补集，直接产出纵向极大矩形。
        // 原来的四重边界枚举还要逐个查障碍物，复杂度接近 O(n^5)；
        // 扫描线是 O(n^3 log n)，也不再创建海量随后被剪掉的子矩形。
        var results: [CGRect] = []
        for xi in 0..<(xs.count - 1) {
            for xj in (xi + 1)..<xs.count {
                let blocked = clipped.filter { $0.minX < xs[xj] && $0.maxX > xs[xi] }
                    .sorted { $0.minY < $1.minY }
                var bottom = zone.minY
                for obstacle in blocked {
                    if obstacle.minY > bottom {
                        results.append(CGRect(x: xs[xi], y: bottom,
                                              width: xs[xj] - xs[xi], height: obstacle.minY - bottom))
                    }
                    bottom = max(bottom, obstacle.maxY)
                    if bottom >= zone.maxY { break }
                }
                if bottom < zone.maxY {
                    results.append(CGRect(x: xs[xi], y: bottom,
                                          width: xs[xj] - xs[xi], height: zone.maxY - bottom))
                }
            }
        }

        // 规格 §三.6：删除被其他候选完全包含的冗余结果，只留**极大**矩形。
        // 坐标压缩会枚举出所有空矩形（含大量被包含的），留着会让候选生成变慢，
        // 调试面板里的"候选区"也读不出重点。
        return pruneContained(results)
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// 去掉被其它矩形完全包含的结果（按面积从大到小扫，已保留的矩形一定不比当前小）。
    static func pruneContained(_ rects: [CGRect]) -> [CGRect] {
        let sorted = rects.sorted { $0.width * $0.height > $1.width * $1.height }
        var kept: [CGRect] = []
        for rect in sorted {
            let contained = kept.contains { outer in
                outer.minX <= rect.minX + 0.01 && outer.minY <= rect.minY + 0.01
                    && outer.maxX >= rect.maxX - 0.01 && outer.maxY >= rect.maxY - 0.01
            }
            if !contained { kept.append(rect) }
        }
        return kept
    }

    /// 在可用矩形内为给定尺寸挑一个落点：优先靠四条边（贴近边缘不侵入工作区）。
    static func anchorPoints(in rect: CGRect, size: CGSize) -> [CGRect] {
        let w = min(size.width, rect.width)
        let h = min(size.height, rect.height)
        guard w > 0, h > 0 else { return [] }

        return [
            CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h),   // 左上
            CGRect(x: rect.maxX - w, y: rect.maxY - h, width: w, height: h), // 右上
            CGRect(x: rect.minX, y: rect.minY, width: w, height: h),       // 左下
            CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: h),   // 右下
            CGRect(x: rect.midX - w / 2, y: rect.maxY - h, width: w, height: h), // 上中
            CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), // 正中
            CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h), // 下中
        ].map { $0.integral }
    }

    private static func dedupeSorted(_ values: [CGFloat]) -> [CGFloat] {
        let sorted = values.sorted()
        var result: [CGFloat] = []
        for value in sorted where result.last.map({ abs($0 - value) > 0.001 }) ?? true {
            result.append(value)
        }
        return result
    }
}
