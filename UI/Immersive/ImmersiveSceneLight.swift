extension ImmersiveShaderSource {
    /// 光影：午后的阳光穿过窗外的树，落在一面灰泥墙上。
    ///
    /// 真实感的关键是"树影不是色块"：离墙远的叶团投下的是很虚的影子，叶缝里漏下来的是
    /// 一个个椭圆形的小太阳（小孔成像，日光透过叶隙都会成椭圆）。风吹时叶团整体缓慢挪动，
    /// 叶隙光斑各自轻轻闪。灰泥墙的起伏只在被光扫到的地方显出来。
    /// 右缘是一幅被窗光透亮的纱帘（近景、失焦），左侧墙面在阴影里，歌词放在那里。
    /// 音乐：能量越高风越大，起音像一阵轻风，段落起伏让日光时强时弱。
    /// 节拍：每拍一阵风从窗的一边推到另一边，叶影整团被推出去再慢慢荡回来，纱帘跟着鼓一下；
    /// 小节第一拍那阵风更大。浮尘随速度漂。
    static let light = #"""

    inline float lightPane(float2 w, float soft) {
        float2 d = abs(w) - float2(0.29, 0.33);
        float sd = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        float pane = 1.0 - smoothstep(-soft, soft, sd);
        float mullV = 1.0 - smoothstep(0.007, 0.007 + soft * 1.3, abs(w.x));
        float mullH = 1.0 - smoothstep(0.007, 0.007 + soft * 1.3, abs(w.y + 0.04));
        return pane * (1.0 - max(mullV, mullH) * 0.94);
    }

    /// 墙面坐标 → 窗光坐标：窗在右上方的画外，光斜着落下来，窗形被拉成平行四边形。
    inline float2 lightWindowSpace(float2 p, float aspect, float2 parallax) {
        float2 w = p - float2(0.18 * aspect, -0.02) + parallax * 0.008;
        w.x += w.y * 0.48;
        return rot(-0.05) * w;
    }

    fragment float4 scene_light(VOut in [[stage_in]], constant SceneUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float t = u.time * u.motion;

        // ---- 墙 ----
        float2 wp = p + u.parallax * 0.006;
        float relief = fbm(wp * 7.0, 4) * 0.70 + gnoise(wp * 42.0) * 0.24 + gnoise(wp * 120.0) * 0.06;
        float3 wallTone = desat(mix(u.p1.rgb, u.p2.rgb, 0.4), 0.55) * 1.05 + float3(0.018, 0.016, 0.014);
        // 房间里的环境光：上亮下暗，靠窗一侧略亮。
        float roomFill = mix(0.42, 0.26, uv.y) * (0.85 + 0.25 * smoothstep(-0.6, 0.8, p.x));
        float3 col = wallTone * roomFill * (0.97 + 0.03 * relief);

        // ---- 窗光与树影 ----
        float2 w = lightWindowSpace(p, aspect, u.parallax);
        float soft = 0.010 + 0.020 * smoothstep(-0.4, 0.4, w.y);
        float pane = lightPane(w, soft);

        float wind = (0.50 + 0.65 * u.energy + 0.30 * u.pulse) * u.motion;
        float2 lp = w * 2.6 + float2(u.seed * 5.0, u.seed * 2.0);
        // 叶团整体随风缓慢挪动（低频），小枝再叠一层更快的颤动。
        float2 drift = float2(sin(t * 0.21) + 0.5 * sin(t * 0.47 + 1.3), cos(t * 0.17) + 0.4 * sin(t * 0.39)) * 0.035 * wind;
        float2 flutter = float2(fbm(lp * 1.1 + t * 0.35, 2), fbm(lp * 1.1 - t * 0.31 + 4.0, 2)) * 0.05 * wind;
        // 每拍一阵风：从窗的右边推到左边（右边先动），叶团顺风推出去，再慢慢荡回来。
        float gustAge = fract(u.rhythm.x) - (0.35 - w.x) * 0.30;
        float2 gust = float2(0.85, -0.30) * (0.26 * beatPush(gustAge) * beatStrength(u)
                                             + 0.05 * u.rhythm.z * barGust(u.rhythm.y)) * u.motion;
        float2 q = lp + drift + flutter + gust;
        float masses = fbm(q * 1.15, 4) + 0.18 * fbm(q * 3.4 + 8.0, 3);
        float leafShadow = smoothstep(-0.16, 0.20, masses);

        // 叶隙光斑：叶团里漏下的椭圆小太阳，顺光线方向拉长；风大时各自轻闪。
        float spots = 0.0;
        float2 sq = rot(0.55) * (q * float2(3.4, 3.4));
        float2 sid = floor(sq);
        for (int oy = -1; oy <= 1; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
                float2 cid = sid + float2(ox, oy);
                float h = hash12(cid);
                if (h > 0.42) { continue; }
                float2 c = cid + 0.2 + 0.6 * hash22(cid + 3.0);
                float2 d = (sq - c) * float2(1.0, 1.55);
                float r = mix(0.16, 0.40, hash12(cid + 7.0));
                float blink = 0.65 + 0.35 * sin(t * (1.5 + 2.5 * h) * (0.4 + wind) + h * 40.0) * (0.4 + 0.6 * u.high);
                spots = max(spots, smoothstep(r, r * 0.05, length(d)) * blink);
            }
        }
        float lit = pane * mix(1.0, spots * 0.55 * (1.0 - smoothstep(0.55, 1.0, leafShadow) * 0.6), leafShadow);
        // 一根斜穿过窗的树枝，影子边缘比叶团清楚一点。
        float branchY = 0.20 * sin(w.x * 2.1 + 0.9 + drift.x * 2.0) - 0.08 + drift.y;
        float branch = 1.0 - smoothstep(0.006, 0.020, abs(w.y - branchY) - 0.010 * (0.6 - w.x));
        lit *= 1.0 - branch * smoothstep(-0.42, 0.05, w.x) * 0.9;

        float3 sunCol = mix(float3(1.0, 0.86, 0.66), u.p4.rgb * float3(1.08, 0.98, 0.86), 0.45);
        float intensity = 0.95 + 0.35 * u.lift + 0.06 * u.bass;
        float grazing = 0.80 + 0.42 * relief;
        col += sunCol * lit * intensity * grazing * 0.68;
        // 影子里不是黑的：叶片透过来的一点绿与天光的冷色。
        float3 shadowTint = mix(float3(0.30, 0.38, 0.48), u.p2.rgb * 2.2, 0.35);
        col += shadowTint * pane * (1.0 - lit) * 0.035;
        // 被照亮的墙把光反回房间，整面墙偏一点暖。
        col += sunCol * 0.035 * pane * 0.5 + sunCol * 0.028 * exp(-dot(w, w) * 2.2);

        // ---- 浮尘：只在光柱里看得见 ----
        // 光从右上照向左下；一个点在光柱里，当且仅当顺着光的方向（左下）走能落到窗光上。
        float beam = 0.0;
        for (int k = 0; k < 4; k++) {
            float s = float(k) * 0.07;
            beam += lightPane(lightWindowSpace(p + float2(-0.62, 0.74) * s, aspect, u.parallax), 0.08);
        }
        beam *= 0.25;
        float3 dust = float3(0.0);
        for (int layer = 0; layer < 2; layer++) {
            float fl = float(layer);
            float scale = mix(16.0, 8.0, fl);
            // 浮尘的漂移叠一份按拍数走的分量：歌越快，尘漂得越快。
            float2 dp = p * scale + float2(t * (0.03 + 0.04 * u.mid), -t * 0.022) * (1.0 + fl * 0.6)
                      + float2(u.rhythm.x * 0.010, -u.rhythm.x * 0.004) * (1.0 + fl * 0.6) * u.motion
                      + u.parallax * (0.04 + fl * 0.10) * scale;
            float2 id = floor(dp);
            float2 f = dp - id;
            float h = hash12(id + fl * 19.0);
            if (h < 0.10) {
                float2 pos = 0.25 + 0.5 * hash22(id + 4.0 + fl) + 0.10 * float2(sin(t * 0.25 + h * 20.0), cos(t * 0.19 + h * 30.0));
                float r = mix(0.030, 0.085, fl);
                float s = smoothstep(r, r * mix(0.25, 0.70, fl), length(f - pos));
                dust += sunCol * s * mix(0.55, 0.20, fl) * (0.6 + 0.4 * sin(t * 0.8 + h * 50.0));
            }
        }
        col += dust * beam * 0.5;

        // ---- 右缘的纱帘：被窗光透亮，竖向褶皱，随风极轻地鼓起 ----
        float edge = 1.0 - uv.x;
        float billow = 0.010 * sin(t * 0.30 + uv.y * 2.2) * wind + 0.006 * sin(t * 0.53 + uv.y * 4.0) * wind
                     + 0.014 * beatPush(fract(u.rhythm.x) - 0.12) * beatStrength(u) * (0.6 + 0.4 * uv.y);
        float cx = edge + billow + u.parallax.x * 0.012;
        float curtain = 1.0 - smoothstep(0.075, 0.145, cx + 0.012 * sin(uv.y * 5.0 + 1.0));
        if (curtain > 0.0) {
            float folds = 0.5 + 0.5 * sin(cx * 150.0 + 6.0 * fbm(float2(cx * 9.0, uv.y * 0.8 + t * 0.02), 3));
            float3 sheer = mix(wallTone * 0.6, sunCol * 0.62, 0.55 + 0.35 * folds) * mix(1.05, 0.70, uv.y);
            col = mix(col, sheer, curtain * 0.88);
        }

        return finish(col, uv, in.position.xy, u, 0.42);
    }
    """#
}
