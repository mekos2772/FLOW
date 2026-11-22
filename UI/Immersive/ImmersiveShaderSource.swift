/// 沉浸场景的 Metal 着色器源码。
///
/// 为什么是字符串而不是 `.metal` 文件：Xcode 27 把 Metal 离线编译器拆成了可选组件，
/// 没装组件的机器上 `.metal` 会让整个工程编译失败。运行时用 `MTLDevice.makeLibrary(source:)`
/// 编译只依赖系统自带的 Metal 框架；`ImmersiveShaderCompileTests` 在单测里把每个场景都编一遍，
/// 语法错误在测试阶段就会暴露，不会拖到用户点开沉浸模式时才发现。
///
/// 画面原则（详见 docs/IMMERSIVE_MODE.md）：
/// - 所有运动都低频、低幅：最快的大尺度运动也要十几秒才走完一屏；
/// - 音乐只改"光"和"风"，不改构图：能量调流速与亮度，起音只给一次轻微的呼吸；
/// - 颜色全部来自封面调色板，在线性空间里混合，再经柔和的胶片曲线与抖动输出，避免色带；
/// - 每个场景至少三层纵深（远景 / 中景 / 近景或玻璃），视差幅度按层递增。
enum ImmersiveShaderSource {
    static let vertexFunction = "immersive_vertex"

    static var library: String { header + silk + rain + ridge + light }

    // MARK: - 公共部分

    static let header = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct SceneUniforms {
        float4 p0;
        float4 p1;
        float4 p2;
        float4 p3;
        float4 p4;
        float4 lyricZone;
        float2 resolution;
        float2 parallax;
        float time;
        float flow;
        float energy;
        float bass;
        float mid;
        float high;
        float pulse;
        float lift;
        float seed;
        float lyricShade;
        float motion;
        float exposure;
        float4 rhythm;   // 拍数 · 小节相位 · 小节幅度 · 每拍波的幅度
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut immersive_vertex(uint vid [[vertex_id]]) {
        float2 q = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(q.x, 1.0 - q.y);
        return o;
    }

    // ---- 哈希与噪声（整数哈希，避免 fract(sin) 在大坐标下的精度条纹）----
    // hashu 的常数与写法参考 David Hoskins「Hash without Sine」。

    inline uint hashu(uint2 q) {
        q = q * uint2(1597334673u, 3812015801u);
        uint n = (q.x ^ q.y) * 1597334673u;
        return n ^ (n >> 16);
    }

    inline float hash12(float2 p) {
        return float(hashu(uint2(int2(floor(p))))) * (1.0 / 4294967295.0);
    }

    inline float2 hash22(float2 p) {
        uint2 q = uint2(int2(floor(p)));
        uint a = hashu(q);
        uint b = hashu(q + uint2(0x9E3779B9u, 0x7F4A7C15u));
        return float2(float(a), float(b)) * (1.0 / 4294967295.0);
    }

    inline float hash11(float x) {
        return hash12(float2(x, 17.0));
    }

    inline float2 grad2(float2 i) {
        float a = hash12(i) * 6.2831853;
        return float2(cos(a), sin(a));
    }

    inline float gnoise(float2 p) {
        float2 i = floor(p);
        float2 f = p - i;
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = dot(grad2(i), f);
        float b = dot(grad2(i + float2(1, 0)), f - float2(1, 0));
        float c = dot(grad2(i + float2(0, 1)), f - float2(0, 1));
        float d = dot(grad2(i + float2(1, 1)), f - float2(1, 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
    }

    inline float fbm(float2 p, int octaves) {
        float sum = 0.0;
        float amp = 0.5;
        const float2x2 m = float2x2(float2(1.62, 1.18), float2(-1.18, 1.62));
        for (int i = 0; i < octaves; i++) {
            sum += amp * gnoise(p);
            p = m * p + float2(3.1, 1.7);
            amp *= 0.5;
        }
        return sum;
    }

    inline float noise1(float x) {
        float i = floor(x);
        float f = x - i;
        float u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float g0 = hash11(i) * 2.0 - 1.0;
        float g1 = hash11(i + 1.0) * 2.0 - 1.0;
        return mix(g0 * f, g1 * (f - 1.0), u) * 2.0;
    }

    inline float2x2 rot(float a) {
        float c = cos(a), s = sin(a);
        return float2x2(float2(c, s), float2(-s, c));
    }

    inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    inline float3 desat(float3 c, float amount) { return mix(c, float3(luma(c)), amount); }

    // ---- 节拍 ----
    // 每一拍从画面边上（或水面上的一点）发出一道波，在大约半拍到一拍的时间里扫过画面再消散：
    // 缎子被抖起一道波纹、倒影被震得荡一下、湖面荡开一圈涟漪、树影被风推一下。
    // 动的是形状和位置，不是整屏亮度——看得出在踩拍，又不是闪光。
    // 幅度（rhythm.w 每拍、rhythm.z 小节第一拍加强）已经乘过节拍可信度和设置，节拍不稳时自然为 0。

    /// 最近一拍发出的那道波：`dist` 是到波源的距离，`age` 是拍内相位（0 刚打在拍上），
    /// 前沿每拍走 `speed`，波包宽 `width`。返回带符号的位移（约 -1…1），下一拍之前已经散尽。
    inline float beatWave(float dist, float age, float speed, float width) {
        float x = (dist - age * speed) / width;
        float life = smoothstep(0.0, 0.22, age) * (1.0 - smoothstep(0.50, 0.95, age));
        return exp(-x * x) * sin(x * 2.6) * life;
    }

    /// 这道波的包络（不带符号），用来给波前加一点亮度或让物体被推一下。
    inline float beatFront(float dist, float age, float speed, float width) {
        float x = (dist - age * speed) / width;
        float life = smoothstep(0.0, 0.22, age) * (1.0 - smoothstep(0.50, 0.95, age));
        return exp(-x * x) * life;
    }

    /// 这一拍的波有多强：每拍的幅度，小节第一拍再加强。
    inline float beatStrength(constant SceneUniforms& u) {
        float downbeat = 1.0 - step(0.25, fract(u.rhythm.y));
        return u.rhythm.w + u.rhythm.z * 0.6 * downbeat;
    }

    /// 被推一下再慢慢回来：拍后约 0.12 拍推到最远，余下的时间缓缓回位。
    inline float beatPush(float age) {
        return smoothstep(0.0, 0.12, age) * (1.0 - smoothstep(0.12, 0.95, age));
    }

    /// 小节里的一阵风：第一拍推出去（约三成小节），再用剩下的时间缓缓回来。
    inline float barGust(float bar) {
        float ph = fract(bar);
        return ph < 0.3 ? smoothstep(0.0, 0.3, ph) : 1.0 - smoothstep(0.3, 1.0, ph);
    }

    // ---- 输出：歌词区压暗 → 暗角 → 胶片曲线 → sRGB → 颗粒与抖动 ----

    inline float lyricMask(float2 uv, constant SceneUniforms& u) {
        float4 z = u.lyricZone;
        if (z.z <= 0.0 || z.w <= 0.0) { return 0.0; }
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 c = z.xy + z.zw * 0.5;
        float2 d = abs((uv - c) * float2(aspect, 1.0)) - z.zw * 0.5 * float2(aspect, 1.0);
        float sd = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        float feather = 0.26;
        return 1.0 - smoothstep(-0.04, feather, sd);
    }

    inline float3 filmic(float3 x) {
        x = max(x, 0.0);
        float3 a = x * (2.51 * x + 0.03);
        float3 b = x * (2.43 * x + 0.59) + 0.14;
        return clamp(a / b, 0.0, 1.0);
    }

    inline float3 encodeSRGB(float3 c) {
        c = clamp(c, 0.0, 1.0);
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
        return select(hi, lo, c <= 0.0031308);
    }

    inline float4 finish(float3 hdr, float2 uv, float2 frag, constant SceneUniforms& u, float vignette) {
        // 歌词区压暗按背景亮度自适应：暗处只压一点，亮的天空压得多一些（像渐变灰镜），白字始终读得清。
        float bright = smoothstep(0.06, 0.45, luma(hdr * u.exposure));
        hdr *= 1.0 - u.lyricShade * (0.30 + 0.58 * bright) * lyricMask(uv, u);
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 d = (uv - 0.5) * float2(aspect / max(aspect, 1.0), 1.0);
        float v = 1.0 - smoothstep(0.35, 1.05, length(d * float2(1.0, 1.15)));
        hdr *= mix(1.0 - vignette, 1.0, v);
        float3 c = encodeSRGB(filmic(hdr * u.exposure * 1.25));
        // 颗粒按 24 帧换一次，像胶片而不是电视雪花；中间调最明显，暗部和高光都收着。
        float frame = floor(u.time * 24.0);
        float g = hash12(frag + float2(frame * 37.0, frame * 11.0)) - 0.5;
        float l = luma(c);
        c += g * 0.028 * (0.35 + 0.65 * (1.0 - abs(l * 2.0 - 1.0)));
        // 抖动：三角分布，消掉暗部渐变的色带。
        float dn = hash12(frag * 1.37 + 91.0) + hash12(frag * 0.73 + 17.0) - 1.0;
        c += dn / 255.0;
        return float4(c, 1.0);
    }
    """#
}
