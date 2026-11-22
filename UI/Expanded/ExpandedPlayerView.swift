import SwiftUI

/// 主窗口使用固定导航与播放栏；切换内容不替换音频会话。
struct ExpandedPlayerView: View {
    @Bindable var model: MorphPresentationModel
    var onClose: () -> Void
    var onBrowse: () -> Void
    /// 进入沉浸播放（场景 + 歌词铺满全屏）。
    var onImmersive: () -> Void = {}
    /// 右上角三档：普通 / 悬浮 / 沉浸。
    var onMode: (PlayerMode) -> Void = { _ in }
    @Environment(\.app) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 封面取色：背景（封面取色、场景）和背景画廊的缩略图都用它。
    @State private var palette: ImmersivePalette = .dusk
    @State private var isDropTargeted = false
    @State private var dropFeedbackMessage: String?
    @State private var dropFeedbackTask: Task<Void, Never>?
    // 新手引导：锚点由各视图上报，引导层只负责画。
    @State private var onboardingAnchors: [OnboardingAnchor: CGRect] = [:]
    @State private var onboardingWanted = false
    @State private var onboardingActive = false
    @State private var onboardingSteps: [OnboardingStep] = []
    @State private var onboardingIndex = 0
    /// 这一次运行里已经看过：写盘是异步的，收起再展开的瞬间不该又弹一遍。
    @State private var onboardingFinished = false

    private var background: PlayerBackground { app?.appearance.playerBackground ?? .default }

    var body: some View {
        GeometryReader { geo in
            let sidebarWidth: CGFloat = geo.size.width >= 960 ? 180 : 156
            VStack(spacing: 0) {
                ExpandedHeader(model: model, sidebarWidth: sidebarWidth, palette: palette,
                               onClose: onClose, onMode: onMode)
                FlowDivider()
                HStack(spacing: 0) {
                    PlayerSidebar(model: model, onBrowse: onBrowse, isCompact: geo.size.height < 560)
                        .frame(width: sidebarWidth)
                        .onboardingAnchor(.sidebar)
                    Rectangle().fill(FlowColor.hairline).frame(width: 1)
                    ZStack(alignment: .trailing) {
                        Group {
                            if model.showsHome { OnlineHomeView(model: model) }
                            else { playerContent }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, geo.size.height < 560 ? 12 : 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .onboardingAnchor(.content)
                        drawerLayer
                    }
                }
                PlaybackErrorStrip(model: model,
                                   onRetry: { Task { await app?.playback.retryCurrentTrack() } },
                                   onSkip: { Task { await app?.playback.skip(.next) } },
                                   quickFixTitle: errorQuickFixTitle,
                                   onQuickFix: errorQuickFixAction)
                    .padding(.horizontal, 20)
                if let dropFeedbackMessage {
                    HStack(spacing: 6) {
                        flowIcon(systemName: "checkmark.circle.fill", size: 12)
                            .foregroundStyle(.secondary)
                        Text(verbatim: dropFeedbackMessage)
                            .flowType(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                }
                if model.track != nil {
                    TransportBand(model: model,
                                  isCompact: geo.size.width < 960,
                                  isNarrowSwitch: geo.size.width < 1120)
                        .onboardingAnchor(.transport)
                }
            }
            // 原生交通灯位于内容之上，保留标题栏空间。
            .padding(.top, 26)
        }
        .coordinateSpace(.named(Onboarding.coordinateSpace))
        .background(PlayerBackdropView(model: model, background: background, palette: palette))
        // 封面取色、场景背景都是深色画面：版面跟着切到深色（白字），纯色时照旧跟随系统。
        .environment(\.colorScheme, background == .solid ? colorScheme : .dark)
        .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
        .overlay { UniversalDropOverlay(isTargeted: isDropTargeted) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app, !urls.isEmpty else { return false }
            Task { @MainActor in
                let message = await UniversalDropRouter.handle(urls: urls, app: app, model: model)
                if let message {
                    showDropFeedback(message)
                }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onPreferenceChange(OnboardingAnchorKey.self) { anchors in
            onboardingAnchors = anchors
            beginOnboardingIfReady()
        }
        .overlay { onboardingLayer }
        // 不能用 onAppear：窗口控制器先用空容器建根视图、稍后才换上真容器，
        // onAppear 那一刻 `app` 还是 nil，引导就永远不弹（签名沙盒包实机踩到）。容器到位时再判一次。
        .task(id: app.map(ObjectIdentifier.init)) { requestOnboardingIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: Onboarding.didRequestReplay)) { _ in
            // 从设置里重看：先把抽屉收起来，否则卡片会盖在设置页上。
            model.auxiliary = nil
            _ = Onboarding.takeReplayRequest()
            onboardingWanted = true
            beginOnboardingIfReady()
        }
        .task(id: paletteKey) { palette = await ImmersivePalette.forArtwork(model.artwork, masked: model.isMasked) }
        .task(id: model.track?.identity) {
            guard let identity = model.track?.identity else { model.isFavorite = false; return }
            let favorite = await app?.library.isFavorite(identity) ?? false
            guard !Task.isCancelled, model.track?.identity == identity else { return }
            model.isFavorite = favorite
        }
    }

    /// 封面和歌词并排、整组居中：封面的中心和当前句在同一条水平线上（当前句本来就停在歌词区正中），
    /// 歌名、歌手挂在封面下面，不参与对齐。歌词工具条浮在右上角，不占歌词区的高度，
    /// 否则歌词区的中心会比封面低半个工具条。
    private var playerContent: some View {
        GeometryReader { geo in
            if geo.size.width >= 650 && geo.size.height >= 360 {
                // 封面、歌词区、字号都按版面比例走：1020×640 的默认窗口是基准，全屏时一起放大。
                let scale = Self.layoutScale(for: geo.size)
                let side = min(300 * scale, geo.size.width * 0.3, geo.size.height * 0.56)
                let lyricWidth = min(640 * scale, geo.size.width - side - 56 * scale)
                ZStack(alignment: .topTrailing) {
                    HStack(alignment: .center, spacing: 56 * scale) {
                        artwork(side: side)
                            .overlay(alignment: .bottomLeading) {
                                songInfo
                                    .frame(width: side, alignment: .leading)
                                    .alignmentGuide(.bottom) { d in d[.top] - 18 }
                            }
                        lyricBody(fontScale: scale)
                            .frame(width: lyricWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    lyricToolbar
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        artwork(side: 60)
                        songInfo
                        Spacer(minLength: 0)
                    }
                    lyricToolbar
                    lyricBody(fontScale: 1)
                }
            }
        }
        // 着色器在后台先编好，点进沉浸时不卡一下。
        .onAppear { ImmersiveShaderLibrary.shared.prewarm() }
    }

    private func artwork(side: CGFloat) -> some View {
        ArtworkSlab(image: model.isMasked ? nil : model.artwork, ambient: nil,
                    side: side, cornerRadius: 12, showsAmbientGlow: false)
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.displayTitle ?? String(localized: "正在播放"))
                .flowType(.trackTitleCompact).lineLimit(2)
            if let artist = model.displayArtist {
                Text(artist).flowType(.homeControl)
                    .foregroundStyle(FlowColor.secondaryText).lineLimit(1)
            }
        }
    }

    private var lyricToolbar: some View {
        HStack(spacing: 6) {
            Spacer()
            FlowIconButton(systemName: "text.magnifyingglass",
                           label: "换一版歌词",
                           isActive: model.showsLyricPicker, size: 32, symbolSize: 15,
                           prominent: true) {
                model.showsLyricPicker.toggle()
            }
            let showingTranslation = app?.appearance.showLyricTranslation ?? model.showLyricTranslation
            FlowIconButton(systemName: "captions.bubble",
                           label: showingTranslation ? "隐藏中文译文" : "显示中文译文",
                           isActive: showingTranslation, size: 32, symbolSize: 15,
                           prominent: true) {
                let next = !showingTranslation
                if let app {
                    app.setShowLyricTranslation(next)
                } else {
                    model.showLyricTranslation = next
                }
            }
            FlowIconButton(systemName: "arrow.left.and.right.square", label: "歌词偏移校准",
                           isActive: model.auxiliary == .calibrate, size: 32, symbolSize: 15,
                           prominent: true) {
                model.auxiliary = model.auxiliary == .calibrate ? nil : .calibrate
                app?.noteAuxiliaryActivity(model.auxiliary != nil)
            }
            FlowIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "沉浸播放",
                           size: 32, symbolSize: 15, prominent: true, action: onImmersive)
                .accessibilityIdentifier("player.immersive")
        }
    }

    @ViewBuilder
    private func lyricBody(fontScale: CGFloat) -> some View {
        switch app?.appearance.lyricLayout ?? .appleMusic {
        case .appleMusic: LyricScrollView(model: model, fontScale: fontScale)
        case .editorial: LyricFieldView(model: model)
        }
    }

    /// 版面比例：以默认窗口（内容区约 790×480）为 1，按宽高里更紧的那一边缩放，夹在 0.9–1.7。
    static func layoutScale(for size: CGSize) -> CGFloat {
        min(max(min(size.width / 790, size.height / 480), 0.9), 1.7)
    }

    @ViewBuilder
    private var drawerLayer: some View {
        if let panel = model.auxiliary {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.06).onTapGesture { closeDrawer() }
                AuxiliaryDrawer(model: model, panel: panel, onClose: closeDrawer)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .animation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion),
                       value: panel)
        }
    }

    private func closeDrawer() {
        model.auxiliary = nil
        app?.noteAuxiliaryActivity(false)
    }

    static func format(_ seconds: TimeInterval) -> String { DurationText.clock(seconds) }

    private var errorQuickFixTitle: LocalizedStringKey? {
        switch model.error {
        case .networkDisabled: return "允许联网并重试"
        case .rightsRestricted: return "前往检查音源"
        default: return nil
        }
    }

    private var errorQuickFixAction: (() -> Void)? {
        switch model.error {
        case .networkDisabled:
            return {
                Task {
                    await app?.setEnableNetwork(true)
                    await app?.playback.retryCurrentTrack()
                }
            }
        case .rightsRestricted:
            return {
                SettingsNavigation.request(SettingsNavigation.onlineMusicPane)
                openSettings()
            }
        default:
            return nil
        }
    }

    private func showDropFeedback(_ text: String) {
        dropFeedbackTask?.cancel()
        withAnimation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion)) {
            dropFeedbackMessage = text
        }
        dropFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion)) {
                dropFeedbackMessage = nil
            }
        }
    }

    private var paletteKey: String {
        "\(model.track.map { TrackIdentity.storageKey($0.identity) } ?? "-")|\(model.isMasked)|\(model.artwork.map { ObjectIdentifier($0).hashValue } ?? 0)"
    }

    // MARK: - 新手引导

    @ViewBuilder
    private var onboardingLayer: some View {
        if onboardingActive {
            GeometryReader { proxy in
                OnboardingOverlay(steps: onboardingSteps,
                                  index: onboardingIndex,
                                  anchors: onboardingAnchors,
                                  size: proxy.size,
                                  onNext: advanceOnboarding,
                                  onSkip: finishOnboarding)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /// 第一次打开自动弹一次；设置页点「重新查看」时也会走到这里。
    private func requestOnboardingIfNeeded() {
        let replay = Onboarding.takeReplayRequest()
        guard Onboarding.shouldStart(replayRequested: replay,
                                     hasSeen: app?.settings.hasSeenOnboarding,
                                     finishedThisRun: onboardingFinished,
                                     isTestHost: RuntimeSandbox.isTestHost) else { return }
        if replay { onboardingFinished = false }
        onboardingWanted = true
        beginOnboardingIfReady()
    }

    /// 等锚点报上来再开：第一帧还不知道搜索框在哪，箭头会指到角落。
    private func beginOnboardingIfReady() {
        guard onboardingWanted, !onboardingActive, !onboardingAnchors.isEmpty else { return }
        // 只保留当前版面里真实存在的步骤：没在放歌时底栏根本不在，不能指一片空白。
        let available = Onboarding.steps.filter { onboardingAnchors[$0.anchor] != nil }
        onboardingSteps = available.isEmpty ? Onboarding.steps : available
        onboardingIndex = 0
        withAnimation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion)) {
            onboardingActive = true
        }
    }

    private func advanceOnboarding() {
        guard onboardingIndex + 1 < onboardingSteps.count else {
            finishOnboarding()
            return
        }
        withAnimation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion)) {
            onboardingIndex += 1
        }
    }

    /// 看完和跳过都算看过：否则每次启动都弹一遍，比没有引导更烦。
    private func finishOnboarding() {
        withAnimation(Motion.respectingReduceMotion(Motion.fade(Motion.control), reduceMotion: reduceMotion)) {
            onboardingActive = false
        }
        onboardingWanted = false
        onboardingFinished = true
        guard let app, !app.settings.hasSeenOnboarding else { return }
        Task { await app.settings.setHasSeenOnboarding(true) }
    }
}

struct ExpandedHeader: View {
    @Bindable var model: MorphPresentationModel
    var sidebarWidth: CGFloat
    var palette: ImmersivePalette
    var onClose: () -> Void
    var onMode: (PlayerMode) -> Void
    @Environment(\.app) private var app
    @State private var showsBackgrounds = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                // 品牌位换成 Beadline 字标：谱线 + 声波 + 音珠，不再是裸文字。
                FlowMarkView(height: 15)
                if model.isMasked {
                    FlowIconView(glyph: .eyeSlash, size: 13).help("隐私模式")
                        .accessibilityLabel(Text("隐私模式"))
                }
            }
            .padding(.leading, 24)
            .frame(width: sidebarWidth, alignment: .leading)
            PlayerSearchField(model: model)
                .frame(maxWidth: 380)
                // 锚点要在留白之前取：否则高亮框会把左边 24pt 空白也框进去（实机截图里偏左）。
                .onboardingAnchor(.search)
                .padding(.leading, 24)
            Spacer(minLength: 12)
            FlowSegmentedSwitch(items: PlayerMode.allCases.map {
                .init(value: $0, title: $0.displayName, identifier: "player.mode.\($0.rawValue)")
            }, selection: .normal, onSelect: onMode)
            .onboardingAnchor(.modeSwitch)
            .padding(.trailing, 10)
            FlowIconButton(systemName: "photo.on.rectangle.angled", label: "背景", isActive: showsBackgrounds,
                           size: 36, symbolSize: 15, prominent: true) {
                showsBackgrounds.toggle()
            }
            .accessibilityIdentifier("player.background")
            .popover(isPresented: $showsBackgrounds, arrowEdge: .bottom) {
                BackgroundGalleryView(context: .player, palette: palette,
                                      selection: app?.appearance.playerBackground ?? .default) { option in
                    app?.appearance.setPlayerBackground(option)
                }
            }
            FlowIconButton(systemName: "minus", label: "收进菜单栏",
                           size: 36, symbolSize: 14, prominent: true, action: onClose)
        }
        .padding(.trailing, 16)
        .frame(height: 58)
    }
}
