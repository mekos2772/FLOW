import CoreGraphics
import Metal
import simd
import XCTest
@testable import SpatialLyricsPlayer

/// 着色器参数的内存布局必须和 Metal 端逐字节一致：错了不会报错，只会悄悄读错参数。
final class ImmersiveUniformsLayoutTests: XCTestCase {
    func testStrideAndOffsetsMatchShaderStruct() {
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.stride, 176)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.palette4), 64)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.lyricZone), 80)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.resolution), 96)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.parallax), 104)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.time), 112)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.seed), 144)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.exposure), 156)
        XCTAssertEqual(MemoryLayout<ImmersiveUniforms>.offset(of: \.rhythm), 160)
    }

    /// 1× 外接屏上不能再按倍率打折，否则画面会糊成一片。
    @MainActor
    func testRenderResolutionIsDensityBased() {
        XCTAssertEqual(ImmersiveMetalView.pixelsPerPoint(renderScale: 0.5, backingScale: 1), 1)
        XCTAssertEqual(ImmersiveMetalView.pixelsPerPoint(renderScale: 0.5, backingScale: 2), 1)
        XCTAssertEqual(ImmersiveMetalView.pixelsPerPoint(renderScale: 0.75, backingScale: 2), 1.5)
        XCTAssertEqual(ImmersiveMetalView.pixelsPerPoint(renderScale: 0.75, backingScale: 1), 1)
    }

    func testShaderHeaderDeclaresSameFieldOrder() {
        let header = ImmersiveShaderSource.header
        let order = ["float4 p0;", "float4 lyricZone;", "float2 resolution;", "float2 parallax;",
                     "float time;", "float flow;", "float seed;", "float exposure;",
                     "float4 rhythm;"]
        var cursor = header.startIndex
        for field in order {
            guard let range = header.range(of: field, range: cursor..<header.endIndex) else {
                return XCTFail("着色器结构体里缺少或乱序：\(field)")
            }
            cursor = range.upperBound
        }
    }
}

/// 每个场景都要在真实 GPU 上编译、渲染，并满足"不是一片黑 / 一片白、歌词区确实被压暗、
/// 相邻两帧不闪"这几条底线。没有 Metal 设备的机器跳过。
@MainActor
final class ImmersiveShaderRenderTests: XCTestCase {
    private func makeRenderer(scene: ImmersiveSceneKind) throws -> ImmersiveRenderer {
        let library = ImmersiveShaderLibrary()
        guard library.device != nil else { throw XCTSkip("没有 Metal 设备") }
        let renderer = ImmersiveRenderer(library: library, meter: AudioFeatureMeter())
        var configuration = ImmersiveRenderer.Configuration()
        configuration.scene = scene
        renderer.update(configuration)
        renderer.settle()
        return renderer
    }

    private func uniforms(time: Float, zone: Bool, width: Int = 160, height: Int = 100) -> ImmersiveUniforms {
        var u = ImmersiveUniforms.neutral
        let colors = ImmersivePalette.dusk.colors
        u.palette0 = SIMD4(colors[0], 1); u.palette1 = SIMD4(colors[1], 1); u.palette2 = SIMD4(colors[2], 1)
        u.palette3 = SIMD4(colors[3], 1); u.palette4 = SIMD4(colors[4], 1)
        u.resolution = SIMD2(Float(width), Float(height))
        u.time = time
        u.flow = time * 0.9
        u.energy = 0.5; u.bass = 0.4; u.mid = 0.4; u.high = 0.3; u.lift = 0.5
        u.seed = 0.37
        if zone {
            u.lyricZone = SIMD4(0.075, 0.25, 0.47, 0.46)
            u.lyricShade = 0.55
        }
        return u
    }

    /// 返回 (整体平均亮度, 标准差, 左侧歌词区平均亮度)，0…1。
    private func measure(_ image: CGImage) -> (mean: Double, deviation: Double, zone: Double, pixels: [UInt8]) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sumSq = 0.0, zoneSum = 0.0, zoneCount = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let l = (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255
                sum += l; sumSq += l * l
                // CGContext 原点在左下：歌词区（上方 25%–71%、左侧 7.5%–54.5%）换算到这里。
                let fy = 1 - Double(y) / Double(h), fx = Double(x) / Double(w)
                if fx > 0.12, fx < 0.50, fy > 0.32, fy < 0.64 { zoneSum += l; zoneCount += 1 }
            }
        }
        let n = Double(w * h)
        let mean = sum / n
        return (mean, sqrt(max(sumSq / n - mean * mean, 0)), zoneSum / max(zoneCount, 1), data)
    }

    func testEverySceneCompilesAndRendersAPlausibleFrame() throws {
        for scene in ImmersiveSceneKind.allCases {
            let renderer = try makeRenderer(scene: scene)
            let image = try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: uniforms(time: 12, zone: false)),
                                      "\(scene) 渲染失败：\(renderer.statistics.lastError ?? "-")")
            let m = measure(image)
            XCTAssertGreaterThan(m.mean, 0.03, "\(scene) 画面几乎全黑")
            XCTAssertLessThan(m.mean, 0.62, "\(scene) 画面过亮，白字会读不清")
            XCTAssertGreaterThan(m.deviation, 0.015, "\(scene) 画面没有层次（几乎是纯色）")
        }
    }

    func testLyricZoneIsShadedBehindText() throws {
        for scene in ImmersiveSceneKind.allCases {
            let renderer = try makeRenderer(scene: scene)
            let plain = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: uniforms(time: 12, zone: false))))
            let shaded = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: uniforms(time: 12, zone: true))))
            XCTAssertLessThan(shaded.zone, plain.zone * 0.92, "\(scene) 歌词区没有被压暗")
            // 白字对比度 ≥ 4.5:1 要求背景相对亮度 ≤ 0.183，换成 sRGB 灰度约 0.47。
            XCTAssertLessThan(shaded.zone, 0.46, "\(scene) 歌词区太亮，白字对比不够")
        }
    }

    func testConsecutiveFramesDoNotFlicker() throws {
        for scene in ImmersiveSceneKind.allCases {
            let renderer = try makeRenderer(scene: scene)
            let a = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: uniforms(time: 12.0, zone: false))))
            let b = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: uniforms(time: 12.0 + 1.0 / 60, zone: false))))
            var diff = 0.0
            for i in stride(from: 0, to: a.pixels.count, by: 4) {
                diff += abs(Double(a.pixels[i]) - Double(b.pixels[i])) + abs(Double(a.pixels[i + 1]) - Double(b.pixels[i + 1]))
            }
            let meanDiff = diff / Double(a.pixels.count / 2)
            XCTAssertLessThan(meanDiff, 3.0, "\(scene) 相邻两帧平均变化 \(meanDiff)/255，看起来会闪")
            XCTAssertLessThan(abs(a.mean - b.mean), 0.01, "\(scene) 相邻两帧整体亮度跳变")
        }
    }

    private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var diff = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            diff += abs(Double(a[i]) - Double(b[i])) + abs(Double(a[i + 1]) - Double(b[i + 1]))
        }
        return diff / Double(a.count / 2)
    }

    /// 128 BPM（画面不再减半的最快速度）、30 帧：节拍波是形状在动（缎子起伏、倒影晃、涟漪、树影被推），
    /// 允许像素大片变化，但整幅画的亮度不能一帧一跳、也不能整拍忽明忽暗——那就成了闪光。
    /// 默认的「适中」档卡得严；「明显」是用户自己选的大幅度，放宽一些。
    func testBeatWaveMovesWithoutStrobing() throws {
        let beatsPerFrame: Float = 128.0 / 60 / 30
        let levels: [(ImmersiveBeatSync, Double, Double)] = [(.standard, 0.02, 0.05), (.strong, 0.035, 0.08)]
        for scene in ImmersiveSceneKind.allCases {
            let renderer = try makeRenderer(scene: scene)
            for (sync, perFrame, perBeat) in levels {
                var means: [Double] = []
                for frame in 0...16 {
                    var u = uniforms(time: 12, zone: false)
                    let beats = 7.95 + Float(frame) * beatsPerFrame
                    u.rhythm = SIMD4(beats, (beats / 4).truncatingRemainder(dividingBy: 1), sync.barGain, sync.beatGain)
                    means.append(measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: u))).mean)
                }
                for (a, b) in zip(means, means.dropFirst()) {
                    XCTAssertLessThan(abs(a - b), perFrame, "\(scene)·\(sync) 整幅亮度一帧跳了 \(abs(a - b))，看起来像闪光")
                }
                XCTAssertLessThan((means.max() ?? 0) - (means.min() ?? 0), perBeat, "\(scene)·\(sync) 一拍之内整幅忽明忽暗")
            }
        }
    }

    /// 每拍那道波要一眼看得出来：拍后不久（波正扫过画面）和不跟节拍的同一帧相比，画面要有明显差别。
    func testBeatWaveIsClearlyVisible() throws {
        for scene in ImmersiveSceneKind.allCases {
            let renderer = try makeRenderer(scene: scene)
            var still = uniforms(time: 12, zone: true)
            // 小节第二拍（不是加强的第一拍）：普通的一拍也要看得出来。
            still.rhythm = SIMD4(9.3, 0.3, 0, 0)
            var moving = still
            moving.rhythm = SIMD4(9.3, 0.3, ImmersiveBeatSync.standard.barGain, ImmersiveBeatSync.standard.beatGain)
            let a = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: still)))
            let b = measure(try XCTUnwrap(renderer.renderOffscreen(width: 160, height: 100, uniforms: moving)))
            XCTAssertGreaterThan(meanDifference(a.pixels, b.pixels), 2.0, "\(scene) 适中档的节拍波动几乎看不出来")
            XCTAssertLessThan(b.zone, 0.46, "\(scene) 节拍波动让歌词区变亮，白字对比不够")
        }
    }
}

final class ImmersivePaletteTests: XCTestCase {
    private func lab(_ c: SIMD3<Float>) -> SIMD3<Float> { OKLab.fromLinear(c) }

    func testRolesAreOrderedByLightnessAndChromaIsCapped() {
        // 霓虹粉 + 青 + 深底：最容易刺眼的一类封面。
        var pixels: [SIMD3<Float>] = []
        pixels += Array(repeating: SIMD3(1.0, 0.02, 0.45), count: 300)
        pixels += Array(repeating: SIMD3(0.01, 0.8, 0.8), count: 200)
        pixels += Array(repeating: SIMD3(0.005, 0.004, 0.015), count: 500)
        let palette = ImmersivePalette.build(fromLinearPixels: pixels)
        let labs = palette.colors.map(lab)
        for i in 1..<labs.count {
            XCTAssertGreaterThan(labs[i].x, labs[i - 1].x - 0.01, "角色 \(i) 不该比前一个暗")
        }
        for (color, role) in zip(labs, ImmersivePalette.roles) {
            XCTAssertLessThanOrEqual(simd_length(SIMD2(color.y, color.z)), role.chromaCap + 0.005)
            XCTAssertEqual(color.x, role.lightness, accuracy: 0.03)
        }
    }

    /// 单色调封面（金棕一片）要补一点冷色作辅色，否则整个场景只剩一个色相。
    func testMonochromeWarmCoverGetsCoolCounterpoint() {
        var pixels: [SIMD3<Float>] = []
        for i in 0..<600 {
            let v = Float(i % 30) / 30
            pixels.append(SIMD3(0.05 + 0.75 * v, 0.03 + 0.45 * v, 0.005 + 0.12 * v))   // 深棕到金色
        }
        let labs = ImmersivePalette.build(fromLinearPixels: pixels).colors.map(lab)
        let hue = { (c: SIMD3<Float>) in atan2(c.z, c.y) }
        var diff = abs(hue(labs[2]) - hue(labs[3]))
        if diff > .pi { diff = 2 * .pi - diff }
        XCTAssertGreaterThan(diff, 2.0, "辅色应与点缀形成冷暖对比")
        XCTAssertLessThanOrEqual(simd_length(SIMD2(labs[2].y, labs[2].z)), ImmersivePalette.roles[2].chromaCap + 0.005)
    }

    func testGrayCoverStaysNeutral() {
        let pixels = (0..<400).map { i -> SIMD3<Float> in let v = Float(i % 20) / 20; return SIMD3(v, v, v) }
        let palette = ImmersivePalette.build(fromLinearPixels: pixels)
        for color in palette.colors.map(lab) {
            XCTAssertLessThan(simd_length(SIMD2(color.y, color.z)), 0.01, "灰阶封面不该被染上颜色")
        }
    }

    func testExtractionIsDeterministicAndFallsBack() {
        let pixels = (0..<300).map { i -> SIMD3<Float> in SIMD3(Float(i % 7) / 7, 0.2, Float(i % 3) / 3) }
        XCTAssertEqual(ImmersivePalette.build(fromLinearPixels: pixels), ImmersivePalette.build(fromLinearPixels: pixels))
        XCTAssertEqual(ImmersivePalette.build(fromLinearPixels: []), .dusk)
    }

    func testBlendEasesBetweenPalettes() {
        var blend = ImmersivePaletteBlend(.dusk)
        let target = ImmersivePalette(srgbHex: [0x101010, 0x303030, 0x505050, 0x909090, 0xF0F0F0])
        blend.retarget(target)
        XCTAssertEqual(blend.current, .dusk)
        blend.advance(ImmersivePaletteBlend.duration / 2)
        XCTAssertNotEqual(blend.current, .dusk)
        XCTAssertNotEqual(blend.current, target)
        blend.advance(ImmersivePaletteBlend.duration)
        XCTAssertEqual(blend.current, target)
        XCTAssertTrue(blend.isSettled)
    }
}

final class ImmersiveDriverTests: XCTestCase {
    private let dt = 1.0 / 60

    /// 生成一段"歌"：每 `beat` 秒一次低频冲击（持续 80ms），其余时间是底噪。
    private func run(_ driver: inout ImmersiveDriver, seconds: Double, beat: Double?, loud: Float = 0.3,
                     floor: Float = 0.02, playing: Bool = true, response: Float = 1,
                     reduceMotion: Bool = false) -> [ImmersiveDriver.Output] {
        var outputs: [ImmersiveDriver.Output] = []
        var t = 0.0
        while t < seconds {
            var low = floor
            if let beat, t.truncatingRemainder(dividingBy: beat) < 0.08 { low = loud }
            let levels = AudioBandLevels(low: low, mid: floor * 3, high: floor, full: max(low, floor * 3))
            outputs.append(driver.step(.init(dt: dt, levels: levels, isPlaying: playing, response: response,
                                             reduceMotion: reduceMotion, pointer: nil)))
            t += dt
        }
        return outputs
    }

    func testBeatsAreDetectedButRateLimited() {
        var driver = ImmersiveDriver()
        _ = run(&driver, seconds: 10, beat: 0.5)
        XCTAssertGreaterThanOrEqual(driver.onsetCount, 15, "120 BPM 十秒应检出大部分拍子")
        XCTAssertLessThanOrEqual(driver.onsetCount, 21)

        var fast = ImmersiveDriver()
        _ = run(&fast, seconds: 10, beat: 0.0625)
        XCTAssertLessThanOrEqual(fast.onsetCount, 41, "起音间隔至少 250ms，一秒最多四次")
    }

    func testQuietSongsStillMoveAfterAdaptation() {
        var driver = ImmersiveDriver()
        let outputs = run(&driver, seconds: 12, beat: 0.5, loud: 0.02, floor: 0.002)
        let late = outputs.suffix(120)
        XCTAssertGreaterThan(late.map(\.bass).max() ?? 0, 0.5, "安静的歌归一化后也要有起伏")
    }

    func testSilenceAndPauseDecay() {
        var driver = ImmersiveDriver()
        _ = run(&driver, seconds: 6, beat: 0.5)
        let paused = run(&driver, seconds: 4, beat: 0.5, playing: false)
        let last = paused.last!
        XCTAssertLessThan(last.bass, 0.05)
        XCTAssertLessThan(last.pulse, 0.05)
        XCTAssertEqual(last.lift, 0.5, accuracy: 0.15)
    }

    func testFlowIsMonotonicAndFasterWhenLoud() {
        var quiet = ImmersiveDriver()
        let q = run(&quiet, seconds: 8, beat: nil, loud: 0, floor: 0.0)
        var loud = ImmersiveDriver()
        let l = run(&loud, seconds: 8, beat: 0.25, loud: 0.5, floor: 0.2)
        for pair in zip(l, l.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1.flow, pair.0.flow) }
        XCTAssertGreaterThan(l.last!.flow, q.last!.flow)
        // 每帧的流速增量很小：音乐只改变速度，不制造跳变。
        let maxStep = zip(l, l.dropFirst()).map { $0.1.flow - $0.0.flow }.max() ?? 0
        XCTAssertLessThan(maxStep, Float(dt * 1.4))
    }

    func testResponseOffAndReduceMotion() {
        var off = ImmersiveDriver()
        let o = run(&off, seconds: 4, beat: 0.5, response: 0)
        XCTAssertEqual(o.map(\.pulse).max(), 0)
        XCTAssertEqual(o.last!.energy, 0.35, accuracy: 0.001)
        XCTAssertEqual(o.last!.lift, 0.5, accuracy: 0.001)

        var calm = ImmersiveDriver()
        let c = run(&calm, seconds: 4, beat: 0.5, reduceMotion: true)
        XCTAssertEqual(c.last!.parallax, SIMD2(0, 0))
        XCTAssertEqual(c.last!.motion, 0.15)
    }
}

final class ImmersiveLyricFocusTests: XCTestCase {
    private let lines = [
        LyricLine(start: 10, text: "第一句"),
        LyricLine(start: 15, text: "第二句"),
        LyricLine(start: 20, text: ""),
        LyricLine(start: 45, text: "第三句"),
        LyricLine(start: 50, text: "第四句"),
    ]

    func testIntroShowsCountdownAndUpcomingLines() {
        let focus = ImmersiveLyricFocus.make(lines: lines, currentIndex: nil, time: 3)
        XCTAssertEqual(focus.rows.map(\.role), [.next, .later])
        XCTAssertEqual(focus.rows.first?.index, 0)
        XCTAssertEqual(focus.interlude?.progress ?? -1, 0.3, accuracy: 0.001)
    }

    func testCurrentLineHasContextAroundIt() {
        let focus = ImmersiveLyricFocus.make(lines: lines, currentIndex: 1, time: 16)
        XCTAssertNil(focus.interlude)
        XCTAssertEqual(focus.rows.map(\.index), [0, 1, 3, 4], "空行不该占一个位置")
        XCTAssertEqual(focus.rows.map(\.role), [.previous, .current, .next, .later])
    }

    func testLongGapBecomesInterlude() {
        // 第二句 15s 开始、估计 2.5s 唱完，下一句在 45s：中间是间奏。
        let focus = ImmersiveLyricFocus.make(lines: lines, currentIndex: 2, time: 30)
        let interlude = try? XCTUnwrap(focus.interlude)
        XCTAssertNotNil(interlude)
        XCTAssertEqual(focus.rows.map(\.role), [.previous, .next, .later])
        XCTAssertEqual(focus.rows.first?.index, 1, "间奏时上一句是最近唱过的那句")
        XCTAssertEqual(interlude?.remaining ?? 0, 15, accuracy: 0.001)
    }

    /// LRC 解析器会把 `end` 填成下一句的开始：间奏判断不能被它骗过。
    func testInterludeDetectedWhenEndIsNextLineStart() {
        let lrcStyle = [
            LyricLine(start: 10, end: 14, text: "第一句"),
            LyricLine(start: 14, end: 40, text: "最后一句唱完是间奏",
                      segments: [LyricSegment(start: 14, text: "最后一句"), LyricSegment(start: 16, text: "唱完是间奏")]),
            LyricLine(start: 40, text: "间奏后"),
        ]
        let during = ImmersiveLyricFocus.make(lines: lrcStyle, currentIndex: 1, time: 17)
        XCTAssertNil(during.interlude, "还在唱的时候不是间奏")
        let gap = ImmersiveLyricFocus.make(lines: lrcStyle, currentIndex: 1, time: 25)
        XCTAssertNotNil(gap.interlude, "唱完以后到下一句还有十几秒，应当显示间奏")
        XCTAssertEqual(gap.interlude?.remaining ?? 0, 15, accuracy: 0.001)
    }

    /// 最后一个词后面是长间奏（LRC 的 end = 下一句开始）时，最后一个字也要在唱完后亮起来。
    func testLastWordLightsUpBeforeLongInterlude() {
        let line = LyricLine(start: 49.6, end: 70, text: "and let go",
                             segments: [LyricSegment(start: 49.6, text: "and "), LyricSegment(start: 50.2, text: "let "),
                                        LyricSegment(start: 50.8, text: "go")])
        XCTAssertEqual(line.filledFraction(at: 53) ?? 0, 1, accuracy: 0.001, "go 唱完两秒后应当全亮")
        let shortTail = LyricLine(start: 10, end: 14, text: "长音",
                                  segments: [LyricSegment(start: 10, text: "长"), LyricSegment(start: 11, text: "音")])
        XCTAssertLessThan(shortTail.filledFraction(at: 12.5) ?? 1, 1, "六秒以内的尾音仍按行尾时间慢慢扫完")
    }

    func testEmptyDocument() {
        XCTAssertEqual(ImmersiveLyricFocus.make(lines: [], currentIndex: nil, time: 0), .empty)
        XCTAssertEqual(ImmersiveLyricFocus.make(lines: [LyricLine(start: 0, text: " ")], currentIndex: 0, time: 1), .empty)
    }

    @MainActor
    func testSeedIsStablePerTrack() {
        let a = Track(sourceID: SourceID("local"), externalID: "a.m4a", title: "A", artist: "", album: nil, duration: 0)
        let b = Track(sourceID: SourceID("local"), externalID: "b.m4a", title: "B", artist: "", album: nil, duration: 0)
        XCTAssertEqual(ImmersivePlayerView.seed(for: a), ImmersivePlayerView.seed(for: a))
        XCTAssertNotEqual(ImmersivePlayerView.seed(for: a), ImmersivePlayerView.seed(for: b))
        XCTAssertEqual(ImmersivePlayerView.seed(for: nil), 0)
    }
}

/// 长句折行：在短语之间断，不把括号里的和声劈成两半。每个字按 10 宽度计。
final class ImmersiveLyricWrapTests: XCTestCase {
    private let measure: (Substring) -> CGFloat = { CGFloat($0.count) * 10 }

    func testBreaksBeforeBracketedBackingVocal() {
        // 《我落泪情绪零碎》实机：系统折行成「…这一页 (这 / 一页)」。
        let text = "我不想再写 随手撕下这一页 (这一页)"
        let offsets = ImmersiveLyricWrap.breakOffsets(in: text, width: 140, measure: measure)
        XCTAssertEqual(ImmersiveLyricWrap.apply(offsets, to: text), "我不想再写 随手撕下这一页\n(这一页)")
    }

    func testPicksTheMostBalancedSpace() {
        let text = "地上断了翅的蝶 雾散之后的满月 原来爱跟心碎"
        let offsets = ImmersiveLyricWrap.breakOffsets(in: text, width: 160, measure: measure)
        XCTAssertEqual(ImmersiveLyricWrap.apply(offsets, to: text), "地上断了翅的蝶\n雾散之后的满月 原来爱跟心碎")
    }

    func testLeavesLinesThatFitOrHaveNoSpaceAlone() {
        XCTAssertEqual(ImmersiveLyricWrap.breakOffsets(in: "窗外的麻雀 在电线杆上", width: 140, measure: measure), [])
        XCTAssertEqual(ImmersiveLyricWrap.breakOffsets(in: "一二三四五六七八九十一二三四五六", width: 100, measure: measure), [],
                       "没有空格就交回系统按字折行")
        XCTAssertEqual(ImmersiveLyricWrap.breakOffsets(in: "一二 三", width: 0, measure: measure), [])
    }

    func testVeryLongLineFillsEachRowThenBalancesTheLastTwo() {
        let text = "一二三四 五六七八 九十一二 三四五六"
        XCTAssertEqual(ImmersiveLyricWrap.breakOffsets(in: text, width: 60, measure: measure), [4, 9, 14])
        XCTAssertEqual(ImmersiveLyricWrap.apply(ImmersiveLyricWrap.breakOffsets(in: text, width: 90, measure: measure), to: text),
                       "一二三四 五六七八\n九十一二 三四五六")
    }

    func testAttributedTextKeepsItsRuns() {
        var sung = AttributedString("我不想再写 随手")
        sung.inlinePresentationIntent = .stronglyEmphasized
        let text = sung + AttributedString("撕下这一页 (这一页)")
        let offsets = ImmersiveLyricWrap.breakOffsets(in: String(text.characters), width: 140, measure: measure)
        let wrapped = ImmersiveLyricWrap.apply(offsets, to: text)
        XCTAssertEqual(String(wrapped.characters), "我不想再写 随手撕下这一页\n(这一页)")
        XCTAssertEqual(wrapped.runs.first?.inlinePresentationIntent, .stronglyEmphasized, "逐字点亮的进度不受折行影响")
        XCTAssertNil(wrapped.runs.last?.inlinePresentationIntent)
    }

    func testRealFontAtFullScreenSize() {
        // 1920×1080 全屏：字号 62.6，歌词栏 0.47 屏宽。
        let wrapped = ImmersiveLyricWrap.wrapped("我不想再写 随手撕下这一页 (这一页)", width: 1920 * 0.47, fontSize: 1080 * 0.058)
        XCTAssertTrue(wrapped.hasSuffix("\n(这一页)"), wrapped)
        XCTAssertEqual(ImmersiveLyricWrap.wrapped("妳的世界 一幕幕纷飞", width: 1920 * 0.47, fontSize: 1080 * 0.058),
                       "妳的世界 一幕幕纷飞")
    }
}

/// 沉浸播放挂在完整形态上：只能从完整形态进入，收缩、Esc 都会退出。
@MainActor
final class ImmersiveWindowTests: XCTestCase {
    func testEnterOnlyFromExpandedAndExitOnCollapse() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)
        controller.setImmersive(true)
        XCTAssertFalse(controller.model.isImmersive, "悬浮形态下不能进入沉浸")

        controller.setMorphology(.expanded)
        controller.setImmersive(true)
        XCTAssertTrue(controller.model.isImmersive)
        XCTAssertNil(controller.model.auxiliary, "进入沉浸时收起抽屉")

        controller.collapse()
        XCTAssertFalse(controller.model.isImmersive, "收缩到悬浮形态前必须先退出沉浸")
        controller.hide()
    }

    /// 完整形态必须能进全屏：沉浸模式默认会请求全屏，NSPanel 不声明 fullScreenPrimary 时请求被静默忽略。
    func testExpandedWindowParticipatesInFullScreen() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)
        XCTAssertTrue(controller.debugPanel.collectionBehavior.contains(.fullScreenPrimary))
        controller.setMorphology(.capsule)
        XCTAssertFalse(controller.debugPanel.collectionBehavior.contains(.fullScreenPrimary), "悬浮形态不参与全屏")
        controller.hide()
    }

    func testAutomaticCollapseIsSuppressedOnlyWhileImmersive() {
        XCTAssertTrue(MorphWindowController.suppressesDuringImmersive(from: .expanded, to: .compact,
                                                                      userInitiated: false, isImmersive: true))
        XCTAssertFalse(MorphWindowController.suppressesDuringImmersive(from: .expanded, to: .compact,
                                                                       userInitiated: true, isImmersive: true),
                       "用户自己收起时照常执行（先退出沉浸）")
        XCTAssertFalse(MorphWindowController.suppressesDuringImmersive(from: .expanded, to: .capsule,
                                                                       userInitiated: false, isImmersive: false))
    }

    func testScreenChangeDoesNotClampFullScreenWindow() {
        // 进全屏时系统发一次屏幕参数变化，安全区仍按带菜单栏的桌面算。
        let desktop = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let fullScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(MorphWindowController.frameAfterScreenChange(fullScreen, safeZone: desktop, isFullScreen: true),
                       fullScreen, "实机：被钳成 (4, 4, 1912, 1042)")
        let window = CGRect(x: 1500, y: 600, width: 1020, height: 640)
        XCTAssertEqual(MorphWindowController.frameAfterScreenChange(window, safeZone: desktop, isFullScreen: false),
                       window.clamped(into: desktop), "普通窗口照旧钳回安全区")
    }

    func testEscapeLeavesImmersive() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)
        let panel = try XCTUnwrap(controller.debugPanel as? MorphPanel)
        XCTAssertEqual(panel.onEscapeKey?(), false, "不在沉浸时 Esc 不该被吃掉")
        controller.toggleImmersive()
        XCTAssertTrue(controller.model.isImmersive)
        XCTAssertEqual(panel.onEscapeKey?(), true)
        XCTAssertFalse(controller.model.isImmersive)
        controller.hide()
    }
}
