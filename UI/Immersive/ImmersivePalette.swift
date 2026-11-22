import CoreGraphics
import Foundation
import simd

/// 沉浸场景的调色板：从封面里取五个"角色色"，再把每个角色压进固定的明度 / 彩度区间。
///
/// 为什么不直接用封面的平均色或最多的颜色：
/// - 平均色会把一张红蓝撞色的封面混成一团灰紫；
/// - 直接取原色会把荧光粉、正红原样搬上整面屏幕，几分钟就刺眼。
///
/// 做法：在 OKLab（感知均匀）里做 k-means 聚类，按"面积 + 彩度 + 明暗"分配角色，
/// 每个角色的目标明度固定（底色最暗、光色最亮），彩度设上限。这样任何封面出来的画面
/// 都落在同一个可读、耐看的亮度结构里，颜色只决定"是什么色调"，不决定"有多亮多艳"。
struct ImmersivePalette: Equatable, Sendable {
    /// 线性 sRGB。顺序与着色器 p0…p4 一致：底色 · 主体 · 辅色 · 点缀 · 光色。
    var colors: [SIMD3<Float>]

    init(colors: [SIMD3<Float>]) {
        precondition(colors.count == 5, "调色板固定五个角色")
        self.colors = colors
    }

    /// 没有封面时的默认色：暮色里的靛蓝、灰青与一点琥珀光。
    static let dusk = ImmersivePalette(srgbHex: [0x0B0D16, 0x1A2234, 0x2E3D52, 0xB0794E, 0xF0D9B5])

    init(srgbHex: [UInt32]) {
        self.init(colors: srgbHex.map { hex in
            SIMD3(Self.toLinear(Float((hex >> 16) & 0xFF) / 255),
                  Self.toLinear(Float((hex >> 8) & 0xFF) / 255),
                  Self.toLinear(Float(hex & 0xFF) / 255))
        })
    }

    // MARK: - 角色约束

    /// 每个角色的目标 OKLab 明度与彩度上限。底色到光色单调变亮，歌词白字压在
    /// 底色/主体上始终有足够对比；点缀色允许最高彩度，但也只到"看得出颜色"的程度。
    struct Role: Sendable {
        var lightness: Float
        var chromaCap: Float
    }

    static let roles: [Role] = [
        Role(lightness: 0.16, chromaCap: 0.040),
        Role(lightness: 0.29, chromaCap: 0.075),
        Role(lightness: 0.38, chromaCap: 0.090),
        Role(lightness: 0.64, chromaCap: 0.120),
        Role(lightness: 0.90, chromaCap: 0.055),
    ]

    // MARK: - 从封面取色

    /// 从图像构造调色板。图像会先缩到 40×40，计算量与原图大小无关。
    static func extract(from image: CGImage) -> ImmersivePalette? {
        guard let pixels = samplePixels(image, side: 40), pixels.count >= 16 else { return nil }
        return build(fromLinearPixels: pixels)
    }

    /// 纯函数版本，单测直接喂像素。
    static func build(fromLinearPixels pixels: [SIMD3<Float>]) -> ImmersivePalette {
        let lab = pixels.map(OKLab.fromLinear)
        let clusters = kMeans(lab, k: 6, iterations: 10)
        guard !clusters.isEmpty else { return .dusk }
        let total = Float(clusters.reduce(0) { $0 + $1.count })

        func chroma(_ c: SIMD3<Float>) -> Float { simd_length(SIMD2(c.y, c.z)) }
        func hue(_ c: SIMD3<Float>) -> Float { atan2(c.z, c.y) }
        func weight(_ c: Cluster) -> Float { Float(c.count) / total }

        // 主体：面积最大的簇。
        let body = clusters.max { weight($0) < weight($1) }!
        // 底色：偏暗且有一定面积的簇；没有暗簇就用主体的色相。
        let base = clusters.min { ($0.mean.x + (weight($0) < 0.06 ? 1 : 0)) < ($1.mean.x + (weight($1) < 0.06 ? 1 : 0)) } ?? body
        // 点缀：彩度 × √面积 最高的簇（小面积的高饱和点也能被选中，但不会被一两个像素带走）。
        let accent = clusters.max { chroma($0.mean) * sqrt(weight($0)) < chroma($1.mean) * sqrt(weight($1)) } ?? body
        // 辅色：与主体色相差得最远、且有面积的簇。
        let second = clusters
            .filter { $0.id != body.id }
            .max { lhs, rhs in
                let dl = abs(angleDifference(hue(lhs.mean), hue(body.mean))) * min(chroma(lhs.mean) * 12, 1) * sqrt(weight(lhs))
                let dr = abs(angleDifference(hue(rhs.mean), hue(body.mean))) * min(chroma(rhs.mean) * 12, 1) * sqrt(weight(rhs))
                return dl < dr
            } ?? body
        // 光色：最亮的簇，去掉大部分彩度后作为"光"。
        let light = clusters.max { $0.mean.x < $1.mean.x } ?? body

        // 单色调封面：主体、辅色、点缀几乎同一个色相时，整个画面会是一片深浅同色
        // （实机：《魔杰座》金棕封面让四个场景全成了金色）。这时按电影调色的老办法补一点冷暖对比：
        // 把点缀色相转 160° 作辅色，彩度压到很低，只出现在暗部、补光和天顶里。灰阶封面不补，保持中性。
        let chromatic = [body.mean, second.mean, accent.mean].filter { chroma($0) > 0.02 }
        let reference = accent.mean
        let spread = chromatic.map { abs(angleDifference(hue($0), hue(reference))) }.max() ?? 0
        var secondMean = second.mean
        if chroma(reference) > 0.03, spread < 0.7 {
            let h = hue(reference) + Float.pi * 0.89
            secondMean = SIMD3(secondMean.x, 0.05 * cos(h), 0.05 * sin(h))
        }

        let picks = [base.mean, body.mean, secondMean, accent.mean, light.mean]
        let colors = zip(picks, roles).map { OKLab.toLinearClamped(constrain($0, to: $1)) }
        return ImmersivePalette(colors: colors)
    }

    /// 把一个 OKLab 颜色放到角色的明度上，彩度不超过上限；几乎无彩的颜色保持中性。
    static func constrain(_ lab: SIMD3<Float>, to role: Role) -> SIMD3<Float> {
        let ab = SIMD2(lab.y, lab.z)
        let c = simd_length(ab)
        guard c > 1e-5 else { return SIMD3(role.lightness, 0, 0) }
        let scaled = ab * (min(c, role.chromaCap) / c)
        return SIMD3(role.lightness, scaled.x, scaled.y)
    }

    /// 两个调色板之间按比例插值（线性空间），换歌时着色器参数由它平滑过渡。
    func mixed(with other: ImmersivePalette, amount: Float) -> ImmersivePalette {
        let t = min(max(amount, 0), 1)
        return ImmersivePalette(colors: zip(colors, other.colors).map { simd_mix($0, $1, SIMD3(repeating: t)) })
    }

    // MARK: - 采样与聚类

    private static func samplePixels(_ image: CGImage, side: Int) -> [SIMD3<Float>]? {
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &raw, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: raw.count, by: 4) where raw[i + 3] > 200 {
            pixels.append(SIMD3(toLinear(Float(raw[i]) / 255),
                                toLinear(Float(raw[i + 1]) / 255),
                                toLinear(Float(raw[i + 2]) / 255)))
        }
        return pixels
    }

    struct Cluster {
        var id: Int
        var mean: SIMD3<Float>
        var count: Int
    }

    /// 确定性的 k-means：按明度分位数取初值，同一张图每次结果一致（换歌回来画面不会变）。
    static func kMeans(_ points: [SIMD3<Float>], k: Int, iterations: Int) -> [Cluster] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { $0.x < $1.x }
        var centers = (0..<k).map { sorted[min(sorted.count - 1, (sorted.count * (2 * $0 + 1)) / (2 * k))] }
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<iterations {
            for (i, p) in points.enumerated() {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (j, c) in centers.enumerated() {
                    // 明度权重减半：同一色相的明暗变化不该被拆成好几簇。
                    let d = p - c
                    let distance = d.x * d.x * 0.5 + d.y * d.y + d.z * d.z
                    if distance < bestDistance { bestDistance = distance; best = j }
                }
                assignment[i] = best
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, p) in points.enumerated() {
                sums[assignment[i]] += p
                counts[assignment[i]] += 1
            }
            for j in 0..<k where counts[j] > 0 {
                centers[j] = sums[j] / Float(counts[j])
            }
        }
        var counts = [Int](repeating: 0, count: k)
        for a in assignment { counts[a] += 1 }
        return (0..<k).compactMap { counts[$0] > 0 ? Cluster(id: $0, mean: centers[$0], count: counts[$0]) : nil }
    }

    private static func angleDifference(_ a: Float, _ b: Float) -> Float {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

/// OKLab 换算（Björn Ottosson, 2020）。只在取色时用，不进渲染循环。
enum OKLab {
    static func fromLinear(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z
        let m = 0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z
        let s = 0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z
        let l3 = cbrt(max(l, 0)), m3 = cbrt(max(m, 0)), s3 = cbrt(max(s, 0))
        return SIMD3(0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
                     1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
                     0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3)
    }

    static func toLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l3 = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m3 = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s3 = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// 超出 sRGB 色域时保持明度、逐步收彩度，直到落回色域。
    static func toLinearClamped(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        var current = lab
        for _ in 0..<12 {
            let rgb = toLinear(current)
            if rgb.min() >= -0.0005 && rgb.max() <= 1.0005 {
                return simd_clamp(rgb, .zero, SIMD3(repeating: 1))
            }
            current.y *= 0.85
            current.z *= 0.85
        }
        return simd_clamp(toLinear(SIMD3(lab.x, 0, 0)), .zero, SIMD3(repeating: 1))
    }
}
