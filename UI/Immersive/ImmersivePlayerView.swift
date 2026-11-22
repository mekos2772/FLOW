import AppKit
import SwiftUI

/// 沉浸播放模式：整窗（通常是全屏）只有场景、歌词和一枚会自己隐去的播放胶囊。
///
/// 版式：歌词放在画面左侧的负空间（四个场景都把主光、主体放在右侧），
/// 鼠标三秒不动，胶囊与按钮淡出、光标隐藏；动一下就回来。
struct ImmersivePlayerView: View {
    @Bindable var model: MorphPresentationModel
    var onExit: () -> Void
    /// 右上角三档：普通 / 悬浮 / 沉浸。
    var onMode: (PlayerMode) -> Void = { _ in }

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var palette: ImmersivePalette = .dusk
    @State private var chromeVisible = true
    @State private var lastActivity = Date()
    @State private var showsBackgrounds = false
    @State private var showsVoice = false
    @State private var scrubPosition: Double?

    /// 歌词区占画面的比例（0…1，原点左上）。同一组数既用来排版，也传给着色器做局部压暗。
    static let lyricZone = CGRect(x: 0.075, y: 0.25, width: 0.47, height: 0.46)

    private var scene: ImmersiveSceneKind { app?.appearance.immersiveScene ?? .default }
    private var response: ImmersiveResponse { app?.appearance.immersiveResponse ?? .default }
    private var powerSaving: Bool { app?.appearance.immersivePowerSaving ?? false }
    private var beatSync: ImmersiveBeatSync { app?.appearance.immersiveBeatSync ?? .default }
    private var showTranslation: Bool { app?.appearance.showLyricTranslation ?? model.showLyricTranslation }
    private var lines: [LyricLine] {
        guard app?.lyricEngine.document?.isSynced ?? false else { return [] }
        return app?.lyricEngine.document?.lines ?? []
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let fontSize = min(max(size.height * 0.058, 28), 66)
            ZStack(alignment: .topLeading) {
                // 音乐只驱动背景这一层（GPU）；歌词层不随能量逐帧刷新——
                // 实测带光晕的大字每秒重排十几次，整个应用 CPU 翻倍，长时间开着不划算。
                ImmersiveSceneView(configuration: configuration,
                                   mediaClock: { [weak playback = app?.playback] in playback?.currentPosition })
                .ignoresSafeArea()
                .accessibilityHidden(true)

                ImmersiveLyricsView(model: model, lines: lines, showTranslation: showTranslation,
                                    fontSize: fontSize, columnWidth: size.width * Self.lyricZone.width,
                                    glow: glowColor, focusY: size.height * Self.lyricZone.height * 0.30,
                                    reduceMotion: reduceMotion)
                    .frame(width: size.width * Self.lyricZone.width, height: size.height * Self.lyricZone.height,
                           alignment: .topLeading)
                    .offset(x: size.width * Self.lyricZone.minX, y: size.height * Self.lyricZone.minY)
                    .allowsHitTesting(false)

                // 隐去时整块移出视图树：留着透明的胶囊，进度条仍会每秒刷新八次，白白重画。
                if chromeVisible {
                    chrome(size: size)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { noteActivity() }
            }
            .onTapGesture { noteActivity() }
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .task(id: paletteKey) { await refreshPalette() }
        .task { await autoHideLoop() }
        .onAppear {
            AudioFeatureMeter.shared.acquire()
            ImmersiveShaderLibrary.shared.prewarm()
        }
        .onDisappear {
            AudioFeatureMeter.shared.release()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("沉浸播放"))
    }

    // MARK: - 场景参数

    private var configuration: ImmersiveRenderer.Configuration {
        ImmersiveRenderer.Configuration(
            scene: scene,
            palette: palette,
            seed: Self.seed(for: model.track),
            // 电平取自播放抽头，音量与静音在它之后才生效：静音时按"没在放"处理，画面不该还跟着鼓点动。
            isPlaying: model.isPlaying && !model.isMuted && model.volume > 0.001,
            response: response,
            reduceMotion: reduceMotion,
            powerSaving: powerSaving,
            lyricZone: lines.isEmpty && !model.isMasked ? Self.lyricZone.insetBy(dx: 0, dy: 0.08) : Self.lyricZone,
            beatSync: beatSync,
            isAdvancing: model.isPlaying
        )
    }


    private var glowColor: Color {
        let light = palette.colors[4]
        func encode(_ c: Float) -> Double {
            let v = Double(min(max(c, 0), 1))
            return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(red: encode(light.x), green: encode(light.y), blue: encode(light.z))
    }

    /// 每首歌一个稳定的种子（不用 `hashValue`——它每次启动都会变，同一首歌回来画面就不一样了）。
    static func seed(for track: Track?) -> Float {
        guard let track else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in TrackIdentity.storageKey(track.identity).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Float(hash % 10_000) / 10_000
    }

    private var paletteKey: String {
        "\(model.track.map { TrackIdentity.storageKey($0.identity) } ?? "-")|\(model.isMasked)|\(model.artwork.map { ObjectIdentifier($0).hashValue } ?? 0)"
    }

    private func refreshPalette() async {
        let extracted = await ImmersivePalette.forArtwork(model.artwork, masked: model.isMasked)
        guard !Task.isCancelled else { return }
        palette = extracted
    }

    // MARK: - 胶囊与按钮

    private func chrome(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                Spacer()
                FlowSegmentedSwitch(items: PlayerMode.allCases.map {
                    .init(value: $0, title: $0.displayName, identifier: "immersive.mode.\($0.rawValue)")
                }, selection: .immersive, style: .glass, onSelect: onMode)
                ImmersiveChromeButton(systemName: "photo.on.rectangle.angled", label: "背景") {
                    showsBackgrounds.toggle()
                    noteActivity()
                }
                .accessibilityIdentifier("immersive.background")
                .popover(isPresented: $showsBackgrounds, arrowEdge: .bottom) {
                    BackgroundGalleryView(context: .immersive, palette: palette,
                                          selection: PlayerBackground(scene: scene)) { option in
                        selectScene(option)
                    }
                }
                ImmersiveChromeButton(systemName: "arrow.down.right.and.arrow.up.left", label: "退出沉浸（Esc）", action: onExit)
                    .accessibilityIdentifier("immersive.exit")
            }
            .padding(.top, 22)
            .padding(.trailing, 26)
            .frame(width: size.width, alignment: .trailing)

            capsule
                .frame(width: min(560, size.width - 80))
                .position(x: size.width / 2, y: size.height - 64)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var capsule: some View {
        HStack(spacing: 14) {
            ArtworkSlab(image: model.isMasked ? nil : model.artwork, ambient: nil,
                        side: 40, cornerRadius: 8, showsAmbientGlow: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayTitle ?? String(localized: "正在播放"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let artist = model.displayArtist {
                    Text(artist).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                }
                HairlineSlider(value: Binding(get: { scrubPosition ?? model.position }, set: { scrubPosition = $0 }),
                               range: 0...max(model.duration, 1), onEditingChanged: { editing in
                    guard !editing, let target = scrubPosition else { return }
                    Task { await app?.playback.seek(to: target) }
                    scrubPosition = nil
                }, accessibilityLabel: "播放进度")
                    .disabled(model.track == nil || model.duration <= 0)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                FlowIconButton(systemName: "backward.fill", label: "上一首", isEnabled: model.track != nil,
                               size: 32, symbolSize: 14, prominent: true) { skip(.previous) }
                FlowPlayButton(isPlaying: model.isPlaying, size: 34, isEnabled: model.track != nil) {
                    Task { await app?.playback.togglePlayback() }
                }
                FlowIconButton(systemName: "forward.fill", label: "下一首", isEnabled: model.track != nil,
                               size: 32, symbolSize: 14, prominent: true) { skip(.next) }
                VoiceVersionSwitch(track: model.track, model: model, style: .glass, compact: true)
                    .padding(.leading, 2)
                VoiceControl(track: model.track) { presented in
                    showsVoice = presented
                    noteActivity()
                }
                .padding(.leading, 2)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 和场景同色调的一层深色半透明，不用系统材质（那会把桌面颜色透进来）。
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersive.capsule")
    }

    private func skip(_ direction: SkipDirection) {
        Task { await app?.playback.skip(direction) }
    }

    /// 沉浸页里换场景。播放页的背景本来就是场景时也一起换，回到普通还是同一幅画。
    private func selectScene(_ option: PlayerBackground) {
        guard let next = option.scene, let appearance = app?.appearance else { return }
        appearance.setImmersiveScene(next)
        if appearance.playerBackground.scene != nil { appearance.setPlayerBackground(option) }
        noteActivity()
    }

    // MARK: - 自动隐藏

    private func noteActivity() {
        lastActivity = Date()
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
    }

    private func autoHideLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            let idle = Date().timeIntervalSince(lastActivity)
            // 旁白开着时不隐藏：控件一旦淡出就会从无障碍树里消失，旁白用户会找不到退出与播放键。
            // 背景画廊开着时也不隐藏：按钮一移出视图树，挂在它上面的浮层就跟着没了。
            if chromeVisible, idle > 3, model.isPlaying, model.track != nil, !showsBackgrounds, !showsVoice,
               !NSWorkspace.shared.isVoiceOverEnabled {
                withAnimation(.easeOut(duration: 0.9)) { chromeVisible = false }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

/// 右上角的圆形图标按钮：深色半透明底，悬停时提亮。
private struct ImmersiveChromeButton: View {
    var systemName: String
    var label: LocalizedStringKey
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.78))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.42 : 0.28)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// 把渲染器包成 SwiftUI 视图。
struct ImmersiveSceneView: NSViewRepresentable {
    var configuration: ImmersiveRenderer.Configuration
    /// 当前播放位置（歌曲时间，秒）。节拍网格钉在歌曲时间上，每帧按它取拍子相位。
    var mediaClock: (@MainActor () -> TimeInterval?)?
    var onFrame: ((ImmersiveDriver.Output) -> Void)?

    func makeCoordinator() -> ImmersiveRenderer { ImmersiveRenderer() }

    func makeNSView(context: Context) -> ImmersiveMetalView {
        let renderer = context.coordinator
        let view = ImmersiveMetalView(frame: .zero, device: ImmersiveShaderLibrary.shared.device)
        view.delegate = renderer
        renderer.view = view
        renderer.update(configuration)
        renderer.settle()
        renderer.onFrame = onFrame
        renderer.mediaClock = mediaClock
        view.onPointer = { [weak renderer] point in renderer?.pointer = point }
        apply(configuration, to: view)
        return view
    }

    func updateNSView(_ view: ImmersiveMetalView, context: Context) {
        context.coordinator.update(configuration)
        context.coordinator.onFrame = onFrame
        context.coordinator.mediaClock = mediaClock
        apply(configuration, to: view)
    }

    private func apply(_ configuration: ImmersiveRenderer.Configuration, to view: ImmersiveMetalView) {
        // 背景里最快的东西（滑落的水滴）每秒也只走几十个像素，30 帧已经顺滑；
        // 60 帧在全屏下让整机 CPU 多花一倍却看不出差别（实测 1080p：60 帧约 22–34%）。
        // 歌词与按钮的动画是 SwiftUI 自己按屏幕刷新率画的，不受这里影响。
        let lowPower = configuration.powerSaving || ProcessInfo.processInfo.isLowPowerModeEnabled
        view.renderScale = configuration.scene.renderScale * (lowPower ? 0.75 : 1)
        // 只在真的变化时才写：SwiftUI 每次刷新都会调这里，反复写帧率会重置 MTKView 的显示链接。
        let fps = lowPower ? 24 : 30
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    }

    static func dismantleNSView(_ view: ImmersiveMetalView, coordinator: ImmersiveRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}
