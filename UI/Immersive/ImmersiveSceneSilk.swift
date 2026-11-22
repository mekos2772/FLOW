extension ImmersiveShaderSource {
    /// 流光：一匹缎子在暗房里被一盏侧光照着，缓慢起伏。
    ///
    /// 不用"域扭曲大理石"那种高频纹理——那是炫技，看久了累。这里只有三道低频褶皱，
    /// 被一层更低频的扭曲推着慢慢改方向；材质感全部来自光：漫反射的明暗、褶皱脊上的柔高光、
    /// 掠射角的缎面光泽。颜色在画面上分成两大块冷暖，暗部沉到底色，光从右上来，
    /// 左侧自然更暗，歌词放在那里不用额外压暗太多。
    /// 节拍：每拍从右边（光来的方向）抖起一道波，顺着褶皱横扫过整匹缎子，高光跟着波峰一路滑过去；
    /// 小节第一拍那道更大，褶皱也随小节涌一次。
    static let silk = #"""

    inline float silkField(float2 p, float t, float amp) {
        float2 w = float2(fbm(p * 0.70 + float2(0.0, t * 0.55), 2),
                          fbm(p * 0.70 + float2(4.1, -t * 0.45), 2));
        float2 q = p + w * 0.24;
        float h = 0.0;
        h += 0.62 * sin(dot(q, float2(0.86, 0.50)) * 6.2 + t * 0.90);
        h += 0.16 * sin(dot(q, float2(0.66, 0.75)) * 9.8 - t * 0.70 + 1.3);
        h += 0.04 * sin(dot(q, float2(0.94, 0.34)) * 15.0 + t * 1.10 + 4.0);
        return h * amp;
    }

    /// 节拍波：每拍从画面右侧外面抖起一道波，沿褶皱的横向慢慢扫过整匹缎子（约一拍半走完，
    /// 上一拍的那道还在左边散）。走得慢、波长长：30 帧下每帧只走波长的一小段，看得清波在走，
    /// 扫过亮面时整幅亮度也只是缓缓起落，不会一抖一抖。
    inline float silkRipple(float2 p, float beats, float strength) {
        float dist = 1.25 - dot(p, float2(0.86, 0.50));
        float h = 0.0;
        for (int k = 0; k < 2; k++) {
            float age = fract(beats) + float(k);
            float x = (dist - age * 1.3) / 0.30;
            float life = smoothstep(0.0, 0.25, age) * (1.0 - smoothstep(1.1, 1.9, age));
            h += exp(-x * x) * sin(x * 2.0) * life;
        }
        return h * min(strength, 2.0) * 0.5;
    }


    fragment float4 scene_silk(VOut in [[stage_in]], constant SceneUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        // y 朝上，单位是屏幕高度。
        float2 p = (uv - 0.5) * float2(aspect, -1.0);
        float t = u.flow * 0.11 * u.motion + u.seed * 9.0;

        // 每小节一次涌动：褶皱加深再松开。
        float amp = 1.0 + 0.18 * u.rhythm.z * barGust(u.rhythm.y);
        float wave = beatStrength(u);

        float2 sp = p + u.parallax * 0.018;
        float h = silkField(sp, t, amp);
        float e = 0.004;
        float2 g = float2(silkField(sp + float2(e, 0.0), t, amp) - h, silkField(sp + float2(0.0, e), t, amp) - h) / e;
        float hw = silkRipple(sp, u.rhythm.x, wave);
        float2 gw = float2(silkRipple(sp + float2(e, 0.0), u.rhythm.x, wave) - hw,
                           silkRipple(sp + float2(0.0, e), u.rhythm.x, wave) - hw) / e;
        // 波主要改明暗（漫反射），高光只跟一点：尖锐的高光整条扫过时整幅亮度会跳。
        float3 n = normalize(float3(-(g + gw) * 0.24, 1.0));
        float3 nSpec = normalize(float3(-(g + 0.3 * gw) * 0.24, 1.0));

        // 主光：右上方的一盏柔光，画面上有明确的衰减方向。
        float2 lightPos = float2(0.42 * aspect, 0.42);
        float fall = exp(-dot(p - lightPos, p - lightPos) * 1.15);
        float key = (0.60 + 0.28 * u.lift + 0.06 * u.bass) * (0.30 + 0.95 * fall);

        float3 L = normalize(float3(0.50, 0.58, 0.64));
        float diff = saturate(dot(n, L) * 0.62 + 0.38);
        float3 H = normalize(L + float3(0.0, 0.0, 1.0));
        float nh = saturate(dot(nSpec, H));
        // 缎面的细纹：纱线顺着褶皱走，噪声沿褶皱方向慢、横跨褶皱快；只轻轻调制高光。
        float2 across = normalize(float2(0.86, 0.50));
        float2 crest = float2(-across.y, across.x);
        float weave = gnoise(float2(dot(p, across) * 300.0, dot(p, crest) * 7.0));
        float spec = (pow(nh, 9.0) * 0.50 + pow(nh, 36.0) * 0.38) * (0.97 + 0.035 * weave);
        float sheen = pow(1.0 - saturate(n.z), 2.0);

        // 两大块冷暖：主体色和辅色由一层极低频场分配，换歌后随种子换位置。
        float region = smoothstep(-0.35, 0.40, fbm(p * 0.42 + float2(u.seed * 3.0 + t * 0.05, 1.7), 3));
        float3 cloth = mix(u.p1.rgb, u.p2.rgb, region);
        float3 shadow = mix(u.p0.rgb, cloth * 0.35, 0.35);
        float3 col = mix(shadow, cloth, diff * diff) * (0.25 + 1.05 * key);
        float3 glint = mix(u.p3.rgb, u.p4.rgb, 0.55);

        col += glint * spec * key * (0.75 + 0.20 * u.lift + 0.10 * u.pulse);
        col += u.p3.rgb * sheen * key * (0.30 + 0.10 * u.pulse);

        // 补光：左下方一盏偏冷的辅色光，只照亮朝向它的褶皱侧面——两盏光的冷暖对比就是画面的色彩层次。
        float3 L2 = normalize(float3(-0.62, -0.42, 0.50));
        float2 fillPos = float2(-0.55 * aspect, -0.48);
        float fillFall = exp(-dot(p - fillPos, p - fillPos) * 1.4);
        float fill = pow(saturate(dot(n, L2)), 2.0) * fillFall * (0.55 + 0.25 * u.mid);
        col += mix(u.p2.rgb, u.p3.rgb, 0.25) * fill * 0.55;

        // 空气：光源方向一道极淡的体积光，近处一层几乎看不见的薄纱从镜头前飘过。
        float beam = exp(-pow(dot(p - lightPos, normalize(float2(0.78, -0.62))), 2.0) * 3.5) * fall;
        col += glint * beam * 0.035;
        float2 fp = p * 0.65 + float2(t * 0.20, -t * 0.08) + u.parallax * 0.06;
        float veil = smoothstep(0.0, 0.6, fbm(fp, 3));
        col = mix(col, col * 0.86 + u.p3.rgb * 0.012, veil * 0.5);

        col *= mix(0.80, 1.0, smoothstep(-0.55, 0.15, p.y));
        return finish(col, uv, in.position.xy, u, 0.40);
    }
    """#
}
