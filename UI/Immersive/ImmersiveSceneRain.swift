extension ImmersiveShaderSource {
    /// 雨窗：夜里隔着带雨的玻璃看街口。
    ///
    /// 层次从远到近：远处的街（大小接近一致的散景光斑——对焦在玻璃上时，远处光点的弥散圈
    /// 几乎一样大，这一点做对了画面才"像镜头拍的"）→ 玻璃上的薄雾 → 静止水珠 → 滑落的水滴与水痕。
    /// 水珠里看到的是**倒过来、更清楚**的街景：水珠本身是一枚小透镜。
    /// 音乐只让街灯呼吸、让雨势跟着能量变大变小；起音不闪光。
    /// 节拍：每拍从画面下沿扫上来一道波，玻璃外的街景被震得荡一下（灯影左右晃、波前略亮）；
    /// 滑落的水滴踩着拍子起步（各自每 1/2/4 拍滑一段）。
    static let rain = #"""

    inline float3 rainStreet(float2 uv, float focus, constant SceneUniforms& u, float aspect) {
        float y = uv.y;
        // 夜色底：上方是楼影，中段被街灯烘暖，下方是湿路面。
        float3 col = mix(u.p0.rgb, u.p1.rgb * 0.75, smoothstep(0.10, 0.62, y));
        col = mix(col, u.p0.rgb * 0.85, smoothstep(0.80, 1.05, y));
        float2 sp = float2((uv.x - 0.5) * aspect, y);
        // 两团大面积的环境光：右下暖、左上冷，给夜色一个空间方向。
        col += u.p3.rgb * 0.16 * exp(-dot(sp - float2(0.45 * aspect, 0.70), sp - float2(0.45 * aspect, 0.70)) * 2.2);
        col += u.p2.rgb * 0.10 * exp(-dot(sp - float2(-0.40 * aspect, 0.30), sp - float2(-0.40 * aspect, 0.30)) * 2.6);

        float3 acc = float3(0.0);
        float breathe = 0.86 + 0.20 * u.lift;
        for (int layer = 0; layer < 2; layer++) {
            float fl = float(layer);
            // 远层：小而多；近层：大而少，更柔。
            float scale = mix(9.0, 4.6, fl);
            float2 g = float2(uv.x * aspect, uv.y) * scale + u.parallax * mix(0.010, 0.030, fl) * scale
                     + float2(u.seed * 17.0 + fl * 7.1, fl * 3.3);
            float2 id = floor(g);
            float2 f = g - id;
            for (int oy = -1; oy <= 1; oy++) {
                for (int ox = -1; ox <= 1; ox++) {
                    float2 o = float2(ox, oy);
                    float2 cid = id + o;
                    float h = hash12(cid + fl * 31.0);
                    float cy = (cid.y + 0.5 - fl * 3.3) / scale;
                    // 光点集中在"街"的高度，越往上越稀，像楼上零星亮着的窗。
                    float street = smoothstep(0.32, 0.55, cy) * (1.0 - smoothstep(0.86, 1.0, cy));
                    float windows = (1.0 - smoothstep(0.15, 0.45, cy)) * 0.25;
                    if (h > 0.62 * street + windows + 0.03) { continue; }
                    float2 pos = o + 0.2 + hash22(cid * 1.7 + fl) * 0.6;
                    float rad = mix(0.30, 0.40, hash12(cid + 5.0)) * mix(1.0, 1.25, fl);
                    float d = length(f - pos);
                    float soft = mix(0.05, 0.30, focus) * rad * mix(1.0, 1.5, fl);
                    float disc = smoothstep(rad + soft * 0.5, rad - soft, d);
                    float halo = exp(-max(d - rad * 0.6, 0.0) * mix(9.0, 6.0, focus)) * 0.10;
                    if (disc <= 0.0 && halo < 0.004) { continue; }
                    // 镜头光斑边缘略亮、中心略有起伏（"洋葱圈"），幅度很小。
                    float rim = smoothstep(rad - soft * 1.8, rad - soft * 0.2, d) * disc;
                    float onion = 0.97 + 0.03 * sin(d / rad * 9.0 + h * 9.0);
                    float pick = hash12(cid + 11.0);
                    float3 c = pick < 0.55 ? u.p4.rgb * float3(1.0, 0.92, 0.78)
                             : (pick < 0.85 ? u.p3.rgb : u.p2.rgb * 1.6);
                    float which = hash12(cid + 23.0);
                    float react = which < 0.45 ? u.bass : (which < 0.8 ? u.mid : u.high);
                    float slow = 0.80 + 0.20 * sin(u.time * (0.10 + 0.15 * h) * u.motion + h * 40.0);
                    // 亮度分布要"少数很亮、多数很暗"，否则就是一屏均匀的圆点。
                    float level = pow(hash12(cid + 3.0), 2.2) * 0.9 + 0.08;
                    level *= slow * (0.85 + 0.30 * react) * breathe * mix(1.0, 0.75, fl);
                    acc += c * (disc * onion * 0.30 + rim * 0.12 + halo) * level;
                }
            }
        }
        // 湿路面上被拉长的倒影：只在下方一窄条。
        float streak = exp(-pow((y - 0.86) * 14.0, 2.0)) * (0.55 + 0.45 * gnoise(float2(uv.x * aspect * 2.2 + u.seed, 5.0)));
        acc += u.p3.rgb * streak * 0.07 * breathe;
        // 构图：歌词背后的灯少一些、暗一些，像摄影师把光点让出文字的位置。
        acc *= 1.0 - 0.55 * u.lyricShade * lyricMask(uv, u);
        return col + acc;
    }

    struct Drops {
        float2 normal;
        float cover;
        float wiped;
    };

    inline void addDrop(thread Drops& d, float2 delta, float radius, float strength) {
        float r = length(delta);
        float m = smoothstep(radius, radius * 0.80, r) * strength;
        if (m <= 0.0) { return; }
        float2 n = delta / max(radius, 1e-4);
        d.normal = mix(d.normal, n, m);
        d.cover = max(d.cover, m);
    }

    inline Drops rainDrops(float2 uv, float aspect, float t, float density, float seed,
                           float beats, float groove, float motion) {
        Drops d;
        d.normal = float2(0.0);
        d.cover = 0.0;
        d.wiped = 0.0;
        float2 st = float2(uv.x * aspect, uv.y);

        // 两档静止水珠：细密的雾珠 + 少量大水珠，都缓慢凝结、蒸发。
        for (int layer = 0; layer < 2; layer++) {
            float fl = float(layer);
            float scale = mix(34.0, 13.0, fl);
            float2 g = st * scale + seed * (3.0 + fl);
            float2 id = floor(g);
            float2 f = g - id - 0.5;
            float h = hash12(id + fl * 13.0);
            float chance = mix(0.42, 0.34, fl);
            if (h < chance) {
                float2 c = (hash22(id + 3.0 + fl) - 0.5) * 0.55;
                float life = sin(fract(t * mix(0.015, 0.008, fl) + h * 7.0) * 3.14159);
                float r = mix(0.12, 0.36, hash12(id + 9.0)) * smoothstep(0.0, 0.3, life);
                addDrop(d, f - c, r, 1.0);
            }
        }

        // 滑落的水滴：每列一颗，走走停停；身后留下一道擦掉雾气的水痕和一串小珠。
        float cols = 9.0;
        float cx = st.x * cols / aspect + seed * 3.0;
        float colId = floor(cx);
        float hc = hash11(colId + 41.0);
        float active = smoothstep(hc - 0.10, hc, density);
        if (active > 0.0) {
            float speed = mix(0.035, 0.08, hash11(colId + 7.0));
            // 走走停停，而且踩着拍子：每颗水滴各自每 1、2 或 4 拍滑一段（被表面张力卡住，拍点上突然滑下），
            // 节拍不稳时退回到不对拍的自由滑动。拍数时钟一直在走（没锁定时按默认速度），所以两种走法可以平滑混合。
            float every = hc < 0.35 ? 1.0 : (hc < 0.75 ? 2.0 : 4.0);
            float cyc = beats / every + hc * 3.0;
            float slipPh = fract(cyc);
            float slip = floor(cyc) + mix(slipPh, smoothstep(0.0, 0.38, slipPh), groove);
            float phase = slip * speed * every * 0.42 * motion + t * speed * 0.18 + hc * 13.0;
            float y = fract(phase) * 1.25 - 0.12;
            float xOff = 0.06 * sin(uv.y * 9.0 + hc * 9.0) + 0.03 * sin(uv.y * 23.0 + hc * 3.0);
            float colCenter = (colId + 0.5 + xOff - seed * 3.0) * aspect / cols;
            float2 delta = float2(st.x - colCenter, uv.y - y);
            float r = mix(0.018, 0.028, hc);
            // 水滴下沿圆、上沿拖尖。
            float2 shaped = delta * float2(1.0, delta.y > 0.0 ? 1.0 : 0.62);
            addDrop(d, shaped, r, active);
            float above = smoothstep(0.0, -0.015, delta.y) * smoothstep(-0.55, -0.03, delta.y);
            float trail = smoothstep(r * 0.75, r * 0.25, abs(delta.x)) * above * active;
            d.wiped = max(d.wiped, trail);
            float k = 52.0;
            float row = floor(uv.y * k + hc * 5.0);
            float by = (fract(uv.y * k + hc * 5.0) - 0.5) / k;
            float br = r * 0.30 * hash12(float2(colId, row)) * smoothstep(-0.50, -0.04, delta.y);
            addDrop(d, float2(delta.x, by), br, above * active * step(0.45, hash12(float2(row, colId + 3.0))));
        }
        return d;
    }

    fragment float4 scene_rain(VOut in [[stage_in]], constant SceneUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float t = u.time * u.motion + u.seed * 50.0;
        float density = 0.30 + 0.45 * u.energy;
        float groove = saturate(u.rhythm.z * 0.5 + u.rhythm.w);
        Drops drops = rainDrops(uv + u.parallax * 0.003, aspect, t, density, u.seed,
                                u.rhythm.x, groove, u.motion);

        // 节拍波：从画面下沿外面往上扫，玻璃外的街景被震得左右荡一下，波前那一条略亮。
        float wave = beatStrength(u);
        float age = fract(u.rhythm.x);
        float dist = 1.2 - uv.y;
        // 波长比光斑大得多：灯影是被整体推着左右荡，而不是被扭成怪形状。
        float2 shake = float2(0.030, 0.008) * wave * beatWave(dist, age, 2.0, 0.34);
        float lift = 1.0 + 0.20 * wave * beatFront(dist, age, 2.0, 0.34);
        float3 blurred = rainStreet(uv + shake, 1.0, u, aspect) * lift;
        // 雾：玻璃内侧一层很淡的水汽，把远处压得更灰更软；水痕处被擦薄。
        float3 fog = mix(u.p1.rgb, u.p2.rgb, 0.35) * 0.30 + u.p4.rgb * 0.012;
        float fogAmount = 0.26 * (1.0 - drops.wiped * 0.8);
        float3 glass = mix(blurred, fog, fogAmount);

        float3 col = glass;
        if (drops.cover > 0.0) {
            // 水珠是一枚短焦透镜：里面是整条街倒过来的缩影，比玻璃外更清楚。
            float2 refr = -drops.normal * 0.22;
            float3 inside = rainStreet(uv + refr + shake * 0.5, 0.15, u, aspect) * 1.12 * lift;
            float edge = smoothstep(0.70, 1.0, length(drops.normal));
            // 下沿暗、上沿亮：光从上方街灯来，水珠底部是全反射的暗边。
            float lower = smoothstep(-0.2, 0.9, drops.normal.y);
            inside *= 1.0 - edge * (0.25 + 0.45 * lower);
            float2 nrm = drops.normal;
            float spot = smoothstep(0.82, 0.98, dot(normalize(nrm + 1e-4), normalize(float2(-0.55, -0.83))))
                       * smoothstep(0.40, 0.80, length(nrm));
            inside += u.p4.rgb * spot * 0.22;
            // 一半是折射进来的缩影，一半是水珠背后那块玻璃本身的颜色——否则水珠会像一颗颗黑珠子。
            inside = mix(inside, glass * 1.06, 0.42);
            col = mix(glass, inside, drops.cover);
        }
        return finish(col, uv, in.position.xy, u, 0.46);
    }
    """#
}
