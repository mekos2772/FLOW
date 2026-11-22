import AppKit
import MetalKit
import os
import QuartzCore
import simd

/// 全应用共享的着色器库。第一次需要前在后台编译好（约百毫秒级），进入沉浸模式时不卡主线程。
final class ImmersiveShaderLibrary: @unchecked Sendable {
    static let shared = ImmersiveShaderLibrary()

    enum Failure: Error, Equatable {
        case noDevice
        case compile(String)
    }

    let device: MTLDevice?
    private let lock = NSLock()
    private var compiled: MTLLibrary?
    private var failure: Failure?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    /// 在后台线程预编译；重复调用无副作用。
    func prewarm() {
        Thread.detachNewThread { [self] in _ = try? library() }
    }

    func library() throws -> MTLLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let compiled { return compiled }
        if let failure { throw failure }
        guard let device else {
            failure = .noDevice
            throw Failure.noDevice
        }
        do {
            let library = try device.makeLibrary(source: ImmersiveShaderSource.library, options: nil)
            compiled = library
            return library
        } catch {
            let reason = Failure.compile(String(describing: error))
            failure = reason
            throw reason
        }
    }

    /// 为某个场景建一条渲染管线。混合因子用 blend color 的 alpha，
    /// 换场景 / 换歌时把新画面按比例叠在旧画面上，就是一次真正的交叉淡化。
    func pipeline(for scene: ImmersiveSceneKind, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let library = try library()
        guard let device else { throw Failure.noDevice }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "immersive.\(scene.rawValue)"
        descriptor.vertexFunction = library.makeFunction(name: ImmersiveShaderSource.vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: scene.fragmentFunction)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .blendAlpha
        attachment.destinationRGBBlendFactor = .oneMinusBlendAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .zero
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// 场景渲染器：每帧读取音频电平、推进驱动器、把参数交给着色器。
///
/// 只负责背景这一层；歌词、按钮都是 SwiftUI，按屏幕分辨率绘制，不受渲染缩放影响。
@MainActor
final class ImmersiveRenderer: NSObject, MTKViewDelegate {
    struct Configuration: Equatable {
        var scene: ImmersiveSceneKind = .default
        var palette: ImmersivePalette = .dusk
        var seed: Float = 0
        var isPlaying = false
        var response: ImmersiveResponse = .default
        var reduceMotion = false
        var powerSaving = false
        /// 歌词区（0…1，原点左上），着色器在这块区域轻轻压暗背景。
        var lyricZone: CGRect = .zero
        var beatSync: ImmersiveBeatSync = .default
        /// 歌曲时间在走（播放中，静音也算）：节拍跟踪看的是它；`isPlaying` 是画面要不要跟着动。
        var isAdvancing = false
    }

    struct Statistics: Equatable {
        var frames = 0
        var averageGPUMilliseconds: Double = 0
        var averageCPUMilliseconds: Double = 0
        var lastError: String?
    }

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private let library: ImmersiveShaderLibrary
    private let meter: AudioFeatureMeter
    private var queue: MTLCommandQueue?
    private var pipelines: [ImmersiveSceneKind: MTLRenderPipelineState] = [:]

    private(set) var configuration = Configuration()
    private var driver = ImmersiveDriver()
    private var beatTracker = ImmersiveBeatTracker()
    private var onsetSequence: UInt64 = 0
    private var onsetBuffer: [AudioOnsetFrame] = []
    private var rhythmShaper = ImmersiveRhythm()
    private(set) var lastBeat: ImmersiveBeatTracker.Output?
    private var palette: ImmersivePaletteBlend
    private var lastFrame: CFTimeInterval?
    private var lastSequence: UInt64 = 0
    private var exposure: Float = 0

    /// 交叉淡化：旧场景 + 旧种子垫底，新的按 `fade` 叠上去。
    private var outgoing: (scene: ImmersiveSceneKind, seed: Float)?
    private var fade: Double = 1
    private var fadeDuration: Double = 1.2

    private(set) var lastOutput: ImmersiveDriver.Output?
    /// 节拍（见 `ImmersiveUniforms.rhythm`）。
    private(set) var rhythm = SIMD4<Float>(0, 0, 0, 0)
    private let gpuStats = OSAllocatedUnfairLock(initialState: (count: 0, total: 0.0))
    private(set) var statistics = Statistics()

    /// 每 4 帧回调一次驱动器输出，歌词层用它做极轻的呼吸（不必每帧刷新 SwiftUI）。
    var onFrame: ((ImmersiveDriver.Output) -> Void)?
    var pointer: SIMD2<Float>?
    /// 当前播放位置（歌曲时间）。节拍跟踪器的网格钉在歌曲时间上，拖动进度后不用重新对齐。
    var mediaClock: (@MainActor () -> TimeInterval?)?
    weak var view: ImmersiveMetalView?

    /// 最近创建的渲染器（验收驱动器读帧率与 GPU 耗时用；只读，不进业务逻辑）。
    private(set) static weak var active: ImmersiveRenderer?

    init(library: ImmersiveShaderLibrary = .shared, meter: AudioFeatureMeter = .shared) {
        self.library = library
        self.meter = meter
        self.palette = ImmersivePaletteBlend(.dusk)
        super.init()
        queue = library.device?.makeCommandQueue()
        Self.active = self
    }

    /// 一行可读的运行状态，验收时用来确认"真的在渲染、在跟音乐"。
    var debugSummary: String {
        let o = lastOutput
        let size = view.map { "\(Int($0.drawableSize.width))x\(Int($0.drawableSize.height))" } ?? "-"
        let b = lastBeat
        return String(format: "scene=%@ frames=%d gpu=%.2fms cpu=%.2fms drawable=%@ fps=%d paused=%@ energy=%.2f bass=%.2f mid=%.2f high=%.2f pulse=%.2f lift=%.2f onsets=%d seq=%llu tempo=%.1f beatConf=%.2f beat=%.2f bar=%.2f barConf=%.2f groove=%.2f half=%@ sync=%@ error=%@",
                      configuration.scene.rawValue, statistics.frames, statistics.averageGPUMilliseconds,
                      statistics.averageCPUMilliseconds, size, view?.preferredFramesPerSecond ?? 0,
                      (view?.isPaused ?? true) ? "yes" : "no",
                      o?.energy ?? 0, o?.bass ?? 0, o?.mid ?? 0, o?.high ?? 0, o?.pulse ?? 0, o?.lift ?? 0,
                      driver.onsetCount, lastSequence, b?.tempo ?? 0, b?.confidence ?? 0, b?.beatTime ?? 0,
                      b?.barPhase ?? 0, b?.barConfidence ?? 0, rhythmShaper.groove, rhythmShaper.halfTime ? "yes" : "no",
                      configuration.beatSync.rawValue,
                      statistics.lastError ?? "-")
    }

    var isAvailable: Bool { queue != nil && (try? library.library()) != nil }

    func update(_ new: Configuration) {
        let old = configuration
        configuration = new
        if new.palette != old.palette {
            palette.retarget(new.palette)
        }
        if new.seed != old.seed {
            // 换歌：节拍从头听起（画面的拍数时钟接着走，不归零）。
            beatTracker.reset()
            rhythmShaper.trackChanged()
        }
        if new.scene != old.scene {
            beginTransition(from: (old.scene, old.seed), duration: 1.2)
        } else if new.seed != old.seed {
            // 换歌：同一个场景换一种布局，和调色板一起慢慢过渡。
            beginTransition(from: (old.scene, old.seed), duration: ImmersivePaletteBlend.duration)
        }
    }

    /// 第一次显示时直接落在目标调色板上，不从默认色"变"过来。
    func settle() {
        palette = ImmersivePaletteBlend(configuration.palette)
        outgoing = nil
        fade = 1
    }

    private func beginTransition(from previous: (ImmersiveSceneKind, Float), duration: Double) {
        guard exposure > 0.01 else { return }
        outgoing = (previous.0, previous.1)
        fade = 0
        fadeDuration = configuration.reduceMotion ? 0.3 : duration
    }

    private func pipeline(for scene: ImmersiveSceneKind) -> MTLRenderPipelineState? {
        if let cached = pipelines[scene] { return cached }
        do {
            let state = try library.pipeline(for: scene, pixelFormat: Self.pixelFormat)
            pipelines[scene] = state
            return state
        } catch {
            statistics.lastError = String(describing: error)
            return nil
        }
    }

    // MARK: - 每帧

    /// 推进一帧并返回着色器参数。拆出来是为了让测试与离屏快照走同一条路。
    func advance(now: CFTimeInterval, resolution: SIMD2<Float>) -> ImmersiveUniforms {
        let dt = lastFrame.map { now - $0 } ?? (1.0 / 60)
        lastFrame = now
        let reading = meter.latest()
        let levels: AudioBandLevels? = reading.sequence != lastSequence ? reading.levels : nil
        lastSequence = reading.sequence
        let output = driver.step(.init(dt: dt,
                                       levels: levels,
                                       isPlaying: configuration.isPlaying,
                                       response: configuration.response.gain,
                                       reduceMotion: configuration.reduceMotion,
                                       pointer: pointer))
        lastOutput = output
        advanceRhythm(dt: dt)
        palette.advance(dt, instant: configuration.reduceMotion)
        exposure = min(1, exposure + Float(dt / 0.9))
        if fade < 1 { fade = min(1, fade + dt / fadeDuration) }
        if fade >= 1 { outgoing = nil }
        if statistics.frames % 4 == 0 { onFrame?(output) }
        return uniforms(output: output, resolution: resolution, seed: configuration.seed)
    }

    /// 节拍：从电平表取新的起音格子交给跟踪器，按当前播放位置算出拍数与小节相位，
    /// 幅度 = 可信度 × 节拍联动档位 × 随音乐变化。没在放（暂停、静音）时幅度一秒内淡出。
    private func advanceRhythm(dt: Double) {
        onsetBuffer.removeAll(keepingCapacity: true)
        onsetSequence = meter.onsets(after: onsetSequence, into: &onsetBuffer)
        beatTracker.ingest(onsetBuffer)
        let beat = beatTracker.step(mediaTime: mediaClock?(), dt: dt, isPlaying: configuration.isAdvancing)
        lastBeat = beat
        rhythm = rhythmShaper.step(beat, dt: dt,
                                   active: configuration.isPlaying && !configuration.reduceMotion,
                                   response: configuration.response.gain, sync: configuration.beatSync)
    }

    /// 验收用：最近 20 秒强起音与预测拍点的对齐情况。
    var beatDiagnostics: ImmersiveBeatTracker.Diagnostics { beatTracker.diagnostics() }

    func uniforms(output: ImmersiveDriver.Output, resolution: SIMD2<Float>, seed: Float) -> ImmersiveUniforms {
        let colors = palette.current.colors.map { SIMD4<Float>($0, 1) }
        let zone = configuration.lyricZone
        let eased = 1 - pow(1 - exposure, 3)
        return ImmersiveUniforms(
            palette0: colors[0], palette1: colors[1], palette2: colors[2], palette3: colors[3], palette4: colors[4],
            lyricZone: SIMD4(Float(zone.minX), Float(zone.minY), Float(zone.width), Float(zone.height)),
            resolution: resolution,
            parallax: output.parallax,
            time: output.time,
            flow: output.flow,
            energy: output.energy,
            bass: output.bass,
            mid: output.mid,
            high: output.high,
            pulse: output.pulse,
            lift: output.lift,
            seed: seed,
            lyricShade: zone.isEmpty ? 0 : 0.62,
            motion: output.motion,
            exposure: eased,
            rhythm: rhythm
        )
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let queue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let current = pipeline(for: configuration.scene)
        else { return }
        let cpuStart = CACurrentMediaTime()
        let size = view.drawableSize
        var u = advance(now: cpuStart, resolution: SIMD2(Float(size.width), Float(size.height)))
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "immersive"
        if let outgoing, fade < 1, let previous = pipeline(for: outgoing.scene) {
            var old = u
            old.seed = outgoing.seed
            draw(previous, uniforms: &old, alpha: 1, encoder: encoder)
            let t = fade
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            draw(current, uniforms: &u, alpha: Float(eased), encoder: encoder)
        } else {
            draw(current, uniforms: &u, alpha: 1, encoder: encoder)
        }
        encoder.endEncoding()
        let stats = gpuStats
        buffer.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard ms.isFinite, ms > 0 else { return }
            stats.withLock { $0 = ($0.count + 1, $0.total + ms) }
        }
        buffer.present(drawable)
        buffer.commit()
        statistics.frames += 1
        let cpu = (CACurrentMediaTime() - cpuStart) * 1000
        statistics.averageCPUMilliseconds += (cpu - statistics.averageCPUMilliseconds) * 0.05
        if statistics.frames % 30 == 0 {
            let sample = stats.withLock { value -> (Int, Double) in
                let out = value
                value = (0, 0)
                return out
            }
            if sample.0 > 0 { statistics.averageGPUMilliseconds = sample.1 / Double(sample.0) }
        }
    }

    private func draw(_ state: MTLRenderPipelineState, uniforms: inout ImmersiveUniforms, alpha: Float,
                      encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(state)
        encoder.setBlendColor(red: 0, green: 0, blue: 0, alpha: alpha)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImmersiveUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - 离屏渲染（单测与验收截图）

    /// 用当前配置离屏渲染一帧。`uniforms` 不传时按当前驱动器状态取参数。
    func renderOffscreen(width: Int, height: Int, uniforms override: ImmersiveUniforms? = nil) -> CGImage? {
        guard let device = library.device, let queue,
              let state = pipeline(for: configuration.scene) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var u = override ?? uniforms(output: lastOutput ?? driver.step(.init(dt: 0, levels: nil, isPlaying: false,
                                                                                     response: 0, reduceMotion: false,
                                                                                     pointer: nil)),
                                     resolution: SIMD2(Float(width), Float(height)), seed: configuration.seed)
        u.resolution = SIMD2(Float(width), Float(height))
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw(state, uniforms: &u, alpha: 1, encoder: encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // bgra8Unorm：小端下按 32 位读就是 BGRA，配 byteOrder32Little + 跳过 alpha。
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    var gpuMilliseconds: Double { statistics.averageGPUMilliseconds }
}

/// 承载场景的 Metal 视图：处理鼠标视差、窗口被遮挡时暂停、按场景设置内部分辨率与帧率。
final class ImmersiveMetalView: MTKView {
    var renderScale: Double = 0.66 {
        didSet { if renderScale != oldValue { updateDrawableSize() } }
    }
    var onPointer: ((SIMD2<Float>?) -> Void)?
    private var occlusionObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        colorPixelFormat = ImmersiveRenderer.pixelFormat
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 30
        layer?.isOpaque = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// 内部分辨率按"每个点多少像素"算，而不是简单地乘屏幕倍率：
    /// `renderScale` 是相对视网膜屏（2×）的比例，非视网膜屏上同样的画面细节需要的像素一样多。
    /// 之前直接乘倍率，1× 外接屏上流光只剩 0.5 像素/点，放大后整片糊掉（实机 510×320 发现）。
    static func pixelsPerPoint(renderScale: Double, backingScale: CGFloat) -> CGFloat {
        min(backingScale, CGFloat(renderScale) * 2)
    }

    private func updateDrawableSize() {
        let scale = Self.pixelsPerPoint(renderScale: renderScale, backingScale: window?.backingScaleFactor ?? 2)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { isPaused = true; return }
        updateDrawableSize()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPause() }
        }
        refreshPause()
    }

    /// 窗口完全被挡住、最小化或不在当前桌面时不渲染——和 Wallpaper Engine 的"被遮挡即暂停"一致。
    func refreshPause() {
        guard let window else { isPaused = true; return }
        isPaused = !window.occlusionState.contains(.visible)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onPointer?(SIMD2(Float(p.x / bounds.width) * 2 - 1, Float(p.y / bounds.height) * 2 - 1))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    // 不写 deinit：视图离开窗口时 `viewDidMoveToWindow` 已经注销了观察者。
}
