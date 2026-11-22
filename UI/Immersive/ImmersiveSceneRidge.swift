extension ImmersiveShaderSource {
    /// 远山：日落后的层峦，山脚有雾，近处一片林线，脚下一面静水。
    ///
    /// 层次靠"空气透视"而不是描边：越远的山越接近天光的颜色、对比越低；
    /// 每一层山脚沉进山谷雾里，层与层之间自然分开。视差按层递增（远山几乎不动，林线动得最多）。
    /// 音乐让日光的余晖随段落起落、让雾流得快一点慢一点、让水面的碎光跟着高频闪；构图永远不变。
    /// 节拍：每拍在湖面上荡开一圈清楚的涟漪，倒影被推得一晃；山谷里的雾随之从左往右涌起一道；
    /// 近景冷杉每拍被风推一下，小节第一拍推得更远。
    static let ridge = #"""

    inline float ridgeRange(float x, float sharp) {
        // 远处的山：脊状噪声叠加，尖峰被平方后变得"硬"，但只在远层使用。
        float sum = 0.0;
        float amp = 0.5;
        float fx = x;
        for (int i = 0; i < 4; i++) {
            float n = 1.0 - abs(noise1(fx));
            sum += amp * mix(n, n * n, sharp);
            fx = fx * 2.1 + 1.3;
            amp *= 0.45;
        }
        return sum;
    }

    inline float ridgeHills(float x) {
        float sum = 0.0;
        float amp = 0.5;
        float fx = x;
        for (int i = 0; i < 3; i++) {
            sum += amp * noise1(fx);
            fx = fx * 1.9 + 2.7;
            amp *= 0.42;
        }
        return sum;
    }

    inline float ridgeHeight(int i, float x, constant SceneUniforms& u) {
        float d = float(i) / 4.0;
        float px = x + u.parallax.x * mix(0.004, 0.06, d * d) + u.seed * 11.0 + float(i) * 19.3;
        if (i <= 1) {
            float base = mix(0.40, 0.33, d * 4.0);
            return base + mix(0.17, 0.13, d * 4.0) * (ridgeRange(px * mix(1.1, 1.6, d * 4.0), 0.6) - 0.35);
        }
        if (i <= 3) {
            float base = mix(0.27, 0.21, (d - 0.5) * 4.0);
            return base + 0.06 * ridgeHills(px * 1.8);
        }
        // 林线：起伏很缓的山坡 + 一排尖顶的针叶树冠（三角齿，高低不一）。
        float slope = 0.165 + 0.030 * ridgeHills(px * 0.9);
        float cell = px * 34.0;
        float id = floor(cell);
        float f = cell - id;
        float tall = 0.35 + 0.65 * hash11(id + 7.0);
        float tooth = pow(1.0 - abs(f - 0.5) * 2.0, 1.6) * tall;
        float cell2 = px * 71.0 + 0.5;
        float tooth2 = pow(1.0 - abs(fract(cell2) - 0.5) * 2.0, 1.6) * (0.3 + 0.7 * hash11(floor(cell2) + 3.0));
        float gaps = smoothstep(0.10, 0.60, noise1(px * 5.0) * 0.5 + 0.5);
        return slope + (0.022 * max(tooth, tooth2 * 0.7)) * (0.35 + 0.65 * gaps);
    }

    /// 近景：画面右缘三株失焦的针叶树剪影，视差最大，给整幅画一个"站在湖边"的前景。
    inline float ridgeForeground(float2 st, float aspect, constant SceneUniforms& u) {
        float cover = 0.0;
        float halfW = 0.5 * aspect;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float x0 = halfW - (0.215 - 0.082 * fi) + 0.018 * hash11(fi + 9.0) + u.parallax.x * 0.10;
            float top = fi == 1.0 ? 1.06 : (fi == 0.0 ? 0.74 : 0.90);
            float base = 0.02;
            float h = (st.y - base) / (top - base);
            if (h < 0.0 || h > 1.0) { continue; }
            // 失焦：越近越虚。
            float blur = 0.0035 + 0.0025 * fi;
            float width = pow(1.0 - h, 0.92) * (0.062 + 0.026 * (top - 0.74) / 0.32 + 0.008 * hash11(fi + 4.0));
            // 枝层：每层枝条在下沿最宽、往上收窄，层与层之间是一道斜的缺口——
            // 宽度在层的交界处连续（缺口在 10% 的高度里斜着收回），放大到全屏也不会出现水平的硬切边。
            float tiers = mix(11.0, 15.0, hash11(fi + 6.0));
            float tf = fract(h * tiers + hash11(fi));
            float droop = 1.0 + 0.50 * (1.0 - tf) * smoothstep(0.0, 0.10, tf);
            float jag = 0.85 + 0.15 * noise1(st.y * 90.0 + fi * 7.0);
            // 每拍被风推一下（近的树先动、远的晚一点），小节第一拍推得更远。
            float push = beatPush(fract(u.rhythm.x) - fi * 0.04) * beatStrength(u);
            float sway = sin(u.time * 0.32 * u.motion + fi * 2.1) * 0.0035 * h * h + push * 0.014 * h * h;
            float dx = abs(st.x - x0 - sway);
            float tree = smoothstep(width * droop * jag + blur, width * droop * jag - blur, dx);
            float trunk = smoothstep(0.007 + blur, 0.005 - blur * 0.3, dx) * step(h, 0.12);
            cover = max(cover, max(tree, trunk));
        }
        return cover;
    }

    inline float3 ridgeSky(float2 st, constant SceneUniforms& u, float2 sun) {
        float y = st.y;
        float3 zenith = u.p0.rgb * 0.85 + u.p2.rgb * 0.10;
        float3 mid = mix(u.p1.rgb, u.p2.rgb, 0.5) * 0.9;
        float3 horizon = u.p3.rgb * 0.56 + u.p4.rgb * 0.15;
        // 天光离太阳越远越暗：左侧天空自然沉下去，正好托住歌词。
        horizon *= mix(0.62, 1.0, exp(-abs(st.x - sun.x) * 0.9));
        float3 sky = mix(horizon, mid, smoothstep(0.36, 0.66, y));
        sky = mix(sky, zenith, smoothstep(0.58, 1.05, y));
        float glow = 0.80 + 0.30 * u.lift + 0.06 * u.bass;
        float2 ds = (st - sun) * float2(0.55, 1.0);
        float dist = length(ds);
        sky += u.p4.rgb * exp(-dist * 2.4) * 0.30 * glow;
        sky += u.p4.rgb * exp(-dist * 9.0) * 0.45 * glow;
        sky += u.p4.rgb * smoothstep(0.021, 0.018, length(st - sun)) * 1.6;
        // 低空的层云：底部被落日从下方照亮。
        float band = smoothstep(0.44, 0.54, y) * (1.0 - smoothstep(0.66, 0.86, y));
        float2 cq = float2(st.x * 0.9 + u.flow * 0.003, y * 6.0);
        cq += float2(fbm(cq * 1.7 + 4.0, 2) * 0.6, 0.0);
        float cl = fbm(cq * float2(1.0, 1.6), 5);
        float cloud = smoothstep(0.08, 0.50, cl) * band;
        float3 cloudCol = mix(mid * 0.85, u.p3.rgb * 0.9 + u.p4.rgb * 0.2, exp(-abs(st.x - sun.x) * 0.9) * 0.8);
        sky = mix(sky, cloudCol * (0.9 + 0.2 * u.mid), cloud * 0.55);
        // 星：只在足够暗的天顶。
        float dark = 1.0 - smoothstep(0.03, 0.12, luma(sky));
        float2 sg = st * 150.0;
        float2 sid = floor(sg);
        float sh = hash12(sid);
        if (sh > 0.988 && dark > 0.0) {
            float2 sp = sg - sid - hash22(sid + 2.0);
            float tw = 0.70 + 0.30 * sin(u.time * (0.5 + sh * 1.8) * u.motion + sh * 90.0) * (0.5 + 0.8 * u.high);
            sky += float3(0.85, 0.88, 1.0) * smoothstep(0.10, 0.0, length(sp)) * tw * dark * 0.5;
        }
        return sky;
    }

    inline float3 ridgeLand(float2 st, constant SceneUniforms& u, float2 sun) {
        float3 col = ridgeSky(st, u, sun);
        float3 haze = u.p3.rgb * 0.30 + u.p1.rgb * 0.34 + u.p4.rgb * 0.04;
        float3 nearTone = u.p0.rgb * 0.70 + u.p1.rgb * 0.12;
        float aa = 1.2 / u.resolution.y;
        for (int i = 0; i < 5; i++) {
            float d = float(i) / 4.0;
            float hgt = ridgeHeight(i, st.x, u);
            float cover = smoothstep(hgt + aa, hgt - aa, st.y);
            if (cover <= 0.0) { continue; }
            float atm = pow(1.0 - d, 1.4);
            float3 layer = mix(nearTone, haze, atm * 0.88);
            // 迎光坡：用相邻两点的高差估坡向，朝太阳的一面略亮。
            float slope = (ridgeHeight(i, st.x + 0.03, u) - ridgeHeight(i, st.x - 0.03, u)) / 0.06;
            float facing = saturate(slope * clamp((sun.x - st.x) * 3.0, -1.0, 1.0) * 0.8);
            layer += u.p4.rgb * facing * 0.05 * atm * (0.8 + 0.3 * u.lift);
            float rim = smoothstep(hgt - 0.010, hgt - 0.001, st.y) * exp(-abs(st.x - sun.x) * 1.2);
            layer += u.p4.rgb * rim * 0.10 * (0.6 + 0.4 * atm);
            // 山谷雾：越靠近山脚越白，雾带缓慢横移。
            float depthBelow = hgt - st.y;
            float mist = fbm(float2(st.x * 1.4 + u.flow * mix(0.010, 0.022, d), st.y * 7.0 + float(i) * 3.0), 3);
            // 节拍：山谷雾从左往右涌起一道（远层慢半拍）。
            float span = u.resolution.x / max(u.resolution.y, 1.0);
            float surge = beatFront(st.x + 0.5 * span + 0.15, fract(u.rhythm.x) - d * 0.12, span * 1.4, 0.35)
                        * beatStrength(u);
            float valley = smoothstep(0.02, 0.15, depthBelow) * mix(0.70, 0.30, d) * (1.0 + 0.9 * surge);
            layer = mix(layer, haze * 1.08, saturate(valley * (0.65 + 0.6 * mist)));
            layer *= 0.96 + 0.04 * gnoise(st * 90.0 + float(i) * 5.0);
            col = mix(col, layer, cover);
        }
        return col;
    }

    fragment float4 scene_ridge(VOut in [[stage_in]], constant SceneUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 st = float2((uv.x - 0.5) * aspect, 1.0 - uv.y);
        float2 sun = float2(0.27 * aspect, 0.455);
        float waterLine = 0.155;
        float3 col;
        if (st.y < waterLine) {
            // 湖面：倒影随距离变暗变散，起音让波纹稍微活一点。
            float k = waterLine - st.y;
            float wave = gnoise(float2(st.x * 2.5, k * 70.0 - u.flow * 0.05)) * (0.0025 + 0.010 * k + 0.004 * u.pulse)
                       + sin(k * 300.0 - u.time * 1.2 * u.motion) * 0.0010;
            // 节拍：每拍在湖面上荡开一圈涟漪（透视压扁成椭圆），倒影被推得一晃；
            // 上一拍的那圈还在外面慢慢散。环上带一丝天光，水面才像真的被拨动了。
            float strength = beatStrength(u);
            float ringLight = 0.0;
            for (int r = 0; r < 2; r++) {
                float beatId = floor(u.rhythm.x) - float(r);
                float age = fract(u.rhythm.x) + float(r);
                float2 c = float2((hash11(beatId * 1.31 + 3.0) * 0.7 - 0.05) * aspect * 0.5, waterLine - 0.035 - 0.07 * hash11(beatId * 2.7));
                float2 dv = (st - c) * float2(1.0, 3.6);
                float radius = 0.03 + age * 0.30;
                float fade = (1.0 - smoothstep(0.0, 1.7, age)) * smoothstep(0.0, 0.06, age);
                // 一圈涟漪是几道同心的波纹：包络宽、里面有三四道起伏，外圈先走、内圈跟着。
                float x = (length(dv) - radius) * 28.0;
                float ring = exp(-x * x * 0.35) * fade * strength;
                float ripple = sin(x * 3.2) * ring;
                wave += ripple * 0.016;
                ringLight += max(ripple, 0.0) * 0.6;
            }
            float2 rst = float2(st.x + wave * 1.5, waterLine + k * 1.15 + wave * 4.0);
            float3 refl = ridgeLand(rst, u, sun);
            float fres = mix(0.75, 0.40, saturate(k / waterLine));
            col = refl * fres + u.p0.rgb * 0.25 * (1.0 - fres);
            float glint = smoothstep(0.08 + k * 0.6, 0.0, abs(st.x - sun.x))
                        * smoothstep(0.55, 0.95, gnoise(float2(st.x * 36.0, k * 260.0 - u.time * 0.5 * u.motion)));
            col += u.p4.rgb * glint * (0.25 + 0.30 * u.high) * (1.0 - k / waterLine);
            col += mix(u.p3.rgb, u.p4.rgb, 0.6) * ringLight * 0.10 * (1.0 - k / waterLine * 0.5);
            col *= mix(1.0, 0.75, saturate(k / waterLine));
        } else {
            col = ridgeLand(st, u, sun);
        }
        float fg = ridgeForeground(st, aspect, u);
        float3 fgTone = u.p0.rgb * 0.45 + u.p3.rgb * 0.015;
        col = mix(col, fgTone, fg * 0.985);
        return finish(col, uv, in.position.xy, u, 0.34);
    }
    """#
}
