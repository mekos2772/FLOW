import simd

/// 沉浸场景每帧传给着色器的参数。
///
/// 内存布局必须与 `ImmersiveShaderSource.header` 里的 `SceneUniforms` **逐字段一致**：
/// 先放 16 字节对齐的 `float4`，再放 `float2`，再是标量，最后追加一个节拍 `float4`，
/// 总长 176 字节（`ImmersiveUniformsLayoutTests` 锁住这个数）。不用 `float3`——它在 Metal 里按 16 字节对齐，
/// 两边很容易差出几个字节，画面不会报错，只会悄悄读错参数。
struct ImmersiveUniforms {
    /// 封面调色板（线性 RGB）：0 底色（最暗）· 1 主体 · 2 辅色 · 3 点缀 · 4 光色（最亮）。
    var palette0: SIMD4<Float>
    var palette1: SIMD4<Float>
    var palette2: SIMD4<Float>
    var palette3: SIMD4<Float>
    var palette4: SIMD4<Float>
    /// 歌词所在区域（0…1，原点左上）：着色器在这里把背景轻轻压暗，保证字的对比度。
    var lyricZone: SIMD4<Float>
    /// 渲染目标像素尺寸。
    var resolution: SIMD2<Float>
    /// 视差偏移（-1…1）：镜头缓慢漂移 + 鼠标位置。
    var parallax: SIMD2<Float>
    /// 场景时钟（秒），匀速。
    var time: Float
    /// 流动时钟（秒）：随音乐能量变快变慢，但始终单调递增，画面不会倒退或跳帧。
    var flow: Float
    /// 慢速整体能量（0…1，约 1.5 秒时间常数）。
    var energy: Float
    /// 低频包络（0…1，快起慢落）。
    var bass: Float
    /// 中频包络（0…1）。
    var mid: Float
    /// 高频包络（0…1）。
    var high: Float
    /// 起音脉冲（0…1，触发后指数衰减）。
    var pulse: Float
    /// 段落起伏（0…1）：副歌比主歌高，时间常数数秒，用来换"光线"，不用来闪。
    var lift: Float
    /// 每首歌一个种子，换歌时场景布局随之改变。
    var seed: Float
    /// 歌词区压暗强度（0…1）。
    var lyricShade: Float
    /// 动态幅度：1 正常，0 为"减少动态效果"。
    var motion: Float
    /// 曝光倍率。
    var exposure: Float
    /// 节拍：x 拍数（单调递增，小数部分是拍内相位，0 在拍点上）· y 小节相位（0 在第一拍）·
    /// z 小节级动作幅度 · w 每拍那道波的幅度。幅度已乘上节拍可信度与设置，节拍不稳时为 0。
    var rhythm: SIMD4<Float>

    static let neutral = ImmersiveUniforms(
        palette0: SIMD4(0.012, 0.014, 0.020, 1),
        palette1: SIMD4(0.060, 0.070, 0.095, 1),
        palette2: SIMD4(0.120, 0.110, 0.140, 1),
        palette3: SIMD4(0.420, 0.300, 0.220, 1),
        palette4: SIMD4(0.900, 0.820, 0.700, 1),
        lyricZone: SIMD4(0, 0, 0, 0),
        resolution: SIMD2(1, 1),
        parallax: SIMD2(0, 0),
        time: 0, flow: 0, energy: 0, bass: 0, mid: 0, high: 0,
        pulse: 0, lift: 0.5, seed: 0, lyricShade: 0, motion: 1, exposure: 1,
        rhythm: SIMD4(0, 0, 0, 0)
    )
}
