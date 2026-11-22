import AppKit
import Foundation
import SwiftUI

/// 形态窗口控制器：把"播放器"这件东西在桌面上的存在方式全部收在这里。
///
/// 一份状态、一个窗口、五种形态：
/// - 形态决策走 `MorphologyStateMachine`（纯逻辑，可测）；
/// - 几何走 `WindowGeometryResolver`（纯几何，可测）；
/// - 内容走 `MorphRootView`（一个视图树，按形态分发）；
/// - 本类只做"把三者接起来"以及 AppKit 部分：窗口层级、焦点、动画、事件订阅。
///
/// 环境变化由系统/AX 通知驱动；复用播放 tick 低频补查缺失通知，
/// 纯几何求解在后台单飞执行，主线程只读取快照与更新窗口。
@MainActor
final class MorphWindowController: NSObject, MorphControlling, FloatingLyricsControlling, NSWindowDelegate {
    /// 测试宿主里**绝不**把面板显示出来。
    ///
    /// 之前测试直接构造 `MorphWindowController`，初始化就 `orderFrontRegardless()`，
    /// 于是跑一遍 full suite 会在使用者屏幕上真的弹出 FLOW 面板（还会弹「未在播放」提示）。
    /// 单元测试不该有任何可见副作用——这里统一拦掉，几何与状态逻辑照常跑。
    static var isHeadlessHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 把面板上屏（离屏/影子可见的处理在 `MorphPanel` 覆写里）。
    ///
    /// 测试宿主里 `MorphPanel` 会把窗口挪到所有屏幕之外：直接"不 orderFront"会让
    /// `isVisible` 恒为 false、打挂一批可见性测试；不拦截又会在使用者屏幕上真弹窗。
    /// 这里只负责触发上屏，可见性语义由面板层统一决定。
    private func showPanel() {
        // 上屏是否真的可见由 `MorphPanel` 统一决定（测试宿主里是影子可见）。
        panel.orderFrontRegardless()
    }

    // MARK: 依赖

    private let playback: any PlaybackControlling
    private let lyricEngine: LyricEngine
    private let privacy: PrivacyState
    private let appearance: AppearanceSettings
    private let placements: any PlacementStoring
    private let trackRepository: any TrackRepository
    private let preferences: any MorphPreferenceStoring
    private let accessibility = AccessibilityManager()
    private let spatial: SpatialCoordinator
    /// 障碍物快照。扫描在后台，主线程只读缓存——同步枚举实测峰值 53ms。
    private let obstacleProvider: ObstacleProvider
    /// 时长规则：保证任何刷新率下都有足够帧数。
    private let motionTiming = MotionTiming()
    /// 逐帧弹簧驱动器：几何钳制 + 内容回弹。
    private let frameAnimator = WindowFrameAnimator()
    private let resolver: WindowGeometryResolver
    private var machine: MorphologyStateMachine

    // MARK: 界面

    let model = MorphPresentationModel()
    private let panel: MorphPanel
    private var hosting: MorphHostingView?
    /// 容器在自己构造完成之后才能反向注入（controller 是容器的依赖）。
    /// 视图树里大量地方读 `\.app`，漏注入会让按钮"看着能动、其实什么都不做"。
    weak var appContainer: AppContainer?

    // MARK: 运行时状态

    private let clock = ContinuousClock()
    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    /// 空间评估的事件序号。用来丢弃过期的计算结果（规格 §三：快照要带版本号）。
    private var spatialSeq: UInt64 = 0
    /// 上次补偿检查时间，用于限频。
    private var lastCompensationAt: ContinuousClock.Instant?
    /// 最近一次求解给出的目标矩形，供调试面板显示（面板不能拿当前 frame 冒充目标）。
    private var lastRelocationTarget: CGRect?
    /// 求解器给出的"形态 + 目标矩形"。执行器优先用它，保证决策与落点一致。
    private var pendingPlacement: PlacementCandidate?
    /// `pendingPlacement` 对应的空间快照版本。执行时版本不符就丢弃（规格 §八）。
    private var pendingPlacementVersion: UInt64 = 0
    /// 最近一份完整快照，空列表也有效：关闭最后一个窗口后必须释放旧障碍物。
    private var lastObstacles: [CGRect] = []
    private var userMorphUntil: ContinuousClock.Instant?
    /// 用户显式选过的形态。
    ///
    /// 自动评估此前会在用户切完 1.5 秒后把形态改回去：按一下键得到贴边，
    /// 两秒后自己弹回胶囊，再按又变回来——日志里就是 edge↔capsule 的来回。
    /// 现在自动决策**只能收紧**（空间不够时向更紧的形态降级），
    /// 想回到更宽松的形态必须由用户自己再选一次。
    private var userChosenMorphology: PlayerMorphology?
    /// 用户做出选择那一刻的桌面快照。环境没变就别推翻他的选择。
    private var userChosenSignature: EnvironmentSignature?

    /// 桌面环境的可比较指纹：安全区 + 前台窗口矩形。
    struct EnvironmentSignature: Equatable {
        var safeZone: CGRect
        var obstacles: [CGRect]
    }
    private var evaluationSchedule = SpatialEvaluationSchedule()
    private var evaluationInFlight = false
    private var evaluationRequested = false
    /// 过渡/几何动画期间进来的空间评估请求，动画结束后立即补触发，避免冷启动首拍或变形收尾丢检测。
    private var deferredEvaluationPending = false
    private var userIntentSeq: UInt64 = 0
    /// 记录上次已完成同形态避让评估时的现场指纹，防止桌面静止时无解重试空转，同时在环境或姿态改变后立刻解锁复测。
    private var lastAvoidanceRecorded = false
    private var lastAvoidanceFrame: CGRect = .zero
    private var lastAvoidanceMorphology: PlayerMorphology = .expanded
    private var lastAvoidanceObstacles: [CGRect] = []
    private var relocationGeneration: UInt64 = 0
    private var relocationTask: Task<Void, Never>?
    private var isRelocating = false
    /// 动画看门狗的代际票：每次 animateFrame 自增，过期看门狗直接作废（见 animateFrame）。
    private var watchdogGeneration: UInt64 = 0
    private var opportunityGate = SpatialOpportunityGate()
    private var wallpaperTask: Task<Void, Never>?
    private var backgroundPolicy = BackgroundAppearancePolicy()
    private var backgroundRequest: WallpaperSampleRequest?
    private var backgroundGeneration: UInt64 = 0
    private var lastBackgroundCheckAt: ContinuousClock.Instant?
    private var lastBackgroundSampleAt: ContinuousClock.Instant?
    /// 允许这一次自动决策展开成完整播放器。只有用户主动要求时才置位。
    private var allowExpandedOnce = false
    /// 全屏是不是沉浸模式自己打开的：是的话退出沉浸时顺手退出全屏；用户本来就全屏则不动。
    private var immersiveOwnsFullScreen = false
    /// 从全屏沉浸切到「悬浮」：先等全屏退完再收缩，免得在全屏桌面空间里变形。
    private var floatingAfterFullScreenExit = false
    private let axObserver = AXWindowObserver()
    /// 开发态空间决策面板（`SLP_DEBUG_SPATIAL=1` 才有内容）。
    private let spatialInspector = SpatialDebugPanel()
    /// 开发态矩形叠加层：红障碍 / 绿自由 / 黄候选 / 蓝目标。
    private let spatialOverlay = SpatialDebugOverlay()
    private var stateTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var artworkObserver: NSObjectProtocol?
    /// 空格键的本地事件监听。
    private var evaluationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var movePersistTask: Task<Void, Never>?
    private var loadedLyricsIdentity: TrackIdentity?
    /// 已经落库的曲目。队列/收藏抽屉靠 `TrackRepository` 把 `Track.ID` 还原成曲目，
    /// 而在这个属性存在之前，**全工程没有任何一处调用 `TrackRepository.save`**，
    /// 于是队列 23 行全是"未知曲目"、收藏点了星标也永远进不了列表。
    private var persistedTrackIdentity: TrackIdentity?
    private var currentDisplayID: String?
    private var currentEdge: ScreenEdge = .top
    private var isAppActive = true
    /// 用户刚刚显式指定过形态的时间点。
    /// 用来压住"应用被激活就自动展开"——否则一句深链/快捷键刚切成胶囊，
    /// 紧接着的激活通知又会把它拉回完整形态，用户会觉得"点了没用"。
    private var suppressAutoExpandUntil: ContinuousClock.Instant?
    private var lastDragPersistAt: ContinuousClock.Instant?
    /// 最近一次空间评估用到的输入，只用于日志与实测取证。
    /// 全局快捷键的用户绑定（独立于形态偏好）。
    /// 默认走 `.standard`；测试可以注入独立 suite 避免互相污染。
    var hotkeys = HotkeyPreferences()
    private var lastEnvironment: MorphologyEnvironment?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var allowsActivationExpansion: Bool { !isAutoExpandSuppressed }

    private var isAutoExpandSuppressed: Bool {
        guard let until = suppressAutoExpandUntil else { return false }
        return clock.now < until
    }

    /// 调参里时长全是 0 时表示"不要动画"（测试与减少动态效果共用这一条）。
    private var animatesTransitions: Bool {
        machine.tuning.expandDuration > .zero
    }

    // MARK: - 初始化

    init(playback: any PlaybackControlling,
         lyricEngine: LyricEngine,
         privacy: PrivacyState,
         appearance: AppearanceSettings,
         placements: any PlacementStoring,
         trackRepository: any TrackRepository,
         preferences: any MorphPreferenceStoring,
         tuning: MorphologyTuning = .default,
         obstacleProvider: ObstacleProvider = ObstacleProvider()) {
        self.playback = playback
        self.lyricEngine = lyricEngine
        self.privacy = privacy
        self.appearance = appearance
        self.placements = placements
        self.trackRepository = trackRepository
        self.preferences = preferences
        self.obstacleProvider = obstacleProvider
        self.resolver = WindowGeometryResolver(tuning: tuning)
        self.machine = MorphologyStateMachine(tuning: tuning)
        self.spatial = SpatialCoordinator(accessibility: accessibility, tuning: PlacementTuning(
            debounce: tuning.autoCollapseDelay,
            snapDistance: 12,
            minimumImprovement: tuning.minimumPromotionImprovement,
            morphologyCooldown: tuning.morphologyCooldown
        ))

        // 初始尺寸必须跟**状态机当前形态**一致，而不是一律按展开态建窗。
        // 初态若是胶囊（用户上次停在胶囊），窗口却按 1020×640 建出来，
        // 之后 setMorphology(.capsule) 会被判定为"形态没变"而空操作——
        // 窗口就永远停在错误尺寸上。测试里表现为 currentFrame 一直是 640 高。
        let initial = machine.state.current.geometry.preferredSize
        self.panel = MorphPanel(contentRect: NSRect(origin: .zero, size: initial))
        super.init()

        let actions = MorphViewActions(
            expand: { [weak self] in self?.expand() },
            collapse: { [weak self] in self?.collapse() },
            close: { [weak self] in self?.collapseToDock() },
            togglePlay: { [weak self] in self?.togglePlayback() },
            next: { [weak self] in self?.skipNext() },
            previous: { [weak self] in self?.skipPrevious() },
            browse: { [weak self] in self?.browseToHome() },
            seek: { [weak self] seconds in
                guard let self else { return }
                Task { await self.playback.seek(to: seconds) }
            },
            resize: { [weak self] delta in self?.resize(by: delta) },
            toggleImmersive: { [weak self] in self?.toggleImmersive() },
            setMode: { [weak self] mode in self?.setPlayerMode(mode) }
        )
        let root = MorphRootView(model: model,
                                 actions: actions,
                                 edge: currentEdge,
                                 floatingShape: floatingShape,
                                 appContainer: nil)
        let hosting = MorphHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        // 关键：不要让 NSHostingView 把内容的理想尺寸推给窗口。
        // 我们的窗口尺寸完全由形态系统控制（含手动拖拽缩放），
        // 一旦宿主视图也来插手，AppKit 会在 windowDidLayout 里反复要求更新约束，
        // 最终抛 "more Update Constraints passes than there are views" 崩溃（实测拖拽必崩）。
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting

        configureWindow(for: model.morphology)
        panel.delegate = self
        // Esc 退出沉浸：只依赖模型与面板，建窗即装好（不等 start() 里的其它监听）。
        panel.onEscapeKey = { [weak self] in
            guard let self, self.model.isImmersive else { return false }
            self.setImmersive(false)
            return true
        }
        model.showLyricTranslation = appearance.showLyricTranslation
        lyricEngine.onDocumentChanged = { [weak self] in
            guard let self else { return }
            self.refreshLyricSnapshot()
            self.refreshRootView()
        }
        refreshRootView()
    }

    // MARK: - MorphControlling

    var morphology: PlayerMorphology { machine.state.current }
    var isMorphologyLocked: Bool { machine.state.isLocked }
    /// 用户选择的「鼠标穿透」偏好，单独存：完整播放器下窗口必须能点，
    /// 不能从 `panel.ignoresMouseEvents` 反推，否则在完整形态里切换开关永远不生效。
    private var clickThroughPreferred = false
    var isInteractive: Bool { !machine.state.isUserHidden && !clickThroughPreferred }
    var isClickThroughEnabled: Bool { clickThroughPreferred }
    var isPositionLocked: Bool { positionLocked }
    var recommendedMorphology: PlayerMorphology { machine.state.recommendation.morphology }
    var floatingShape: LyricsShape { storedShape }
    var isVisible: Bool { panel.isVisible }
    /// 当前窗口 frame，供测试与调试断言。
    var currentFrame: NSRect { panel.frame }
    /// 真实窗口，供窗口契约测试。
    var debugPanel: NSWindow { panel }

    private var positionLocked: Bool {
        get { positionLockOverride ?? false }
        set { positionLockOverride = newValue }
    }
    private var positionLockOverride: Bool?
    private var storedShape: LyricsShape = .capsule
    /// 默认保留边缘把手："缩到最小"应该是**看得见**的一小块，而不是彻底消失。
    private(set) var dormantStyle: DormantStyle = .edgeHandle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        spatial.autoAvoidEnabled = appearance.autoAvoidEnabled
        warmUpObstacles()
        restorePreferences()
        observeEnvironment()
        observePlayback()
        observeArtworkStore()
        installSpaceKeyHandler()
        startTicker()
        registerHotkeys()

        accessibility.refresh()
        startAccessibilityTracking()
        // 冷启动先把前台状态同步一次：不能等第一次通知，
        // 否则启动时"我在前台"这个事实没人记，后面所有收缩都会被判成 appStillActive。
        syncFrontmostState()

        panel.alphaValue = reduceMotion ? targetAlpha() : 0
        showPanel()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                panel.animator().alphaValue = targetAlpha()
            }
        }
        model.isTransitioning = false
        if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil {
            let screen = NSScreen.main?.frame ?? .zero
            let visible = NSScreen.main?.visibleFrame ?? .zero
            let line = "START panel=\(panel.frame) screen=\(screen) visible=\(visible) "
                + "morph=\(machine.state.current.rawValue) content=\(panel.contentLayoutRect)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        evaluateSpace(immediate: true)
    }

    func expand() {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        resetAvoidanceAttempt()
        apply(machine.handle(.userOpened, now: clock.now))
    }

    func openCalibration() {
        expand()
        model.showPlayer()
        model.auxiliary = .calibrate
        noteAuxiliaryActivity(true)
        refreshRootView()
    }

    func collapse() {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        resetAvoidanceAttempt()
        suppressAutoExpandUntil = clock.now.advanced(by: .seconds(2))
        // 收缩目标由当前空间决定：空间够就迷你，不够就直接胶囊。
        let target = machine.state.recommendation.morphology.participatesInAutoMorph
            ? machine.state.recommendation.morphology
            : PlayerMorphology.compact
        apply(machine.handle(.userCollapsed(to: target), now: clock.now))
    }

    func setMorphology(_ morphology: PlayerMorphology) {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        resetAvoidanceAttempt()
        userMorphUntil = clock.now.advanced(by: .milliseconds(6000))
        _ = morphology
        if morphology == .expanded { allowExpandedOnce = true }
        suppressAutoExpandUntil = clock.now.advanced(by: .seconds(2))
        apply(machine.handle(.userRequested(morphology), now: clock.now))
    }

    func cycleMorphology() {
        // 只在**看得见**的四种形态之间循环：完整 → 迷你 → 胶囊 → 贴边 → 完整。
        //
        // 曾经把 `.dormant` 也塞进这条链（因为它出现在文案里），结果"贴边"再按一次
        // 就进了隐藏——`hideCompletely` 会把窗口 orderOut，用户看到的是
        // "贴边之后那张小卡片就消失了"。隐藏是一次**有意的动作**，由 ⌃⌥H 负责，
        // 不该在"切换形态"时被顺带撞上。
        let order: [PlayerMorphology] = [.expanded, .compact, .capsule, .edge]
        let index = order.firstIndex(of: machine.state.current) ?? 0
        setMorphology(order[(index + 1) % order.count])
    }

    func toggleMorphologyLock() {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        resetAvoidanceAttempt()
        apply(machine.handle(.userLockChanged(!machine.state.isLocked), now: clock.now))
        evaluateSpace(immediate: true)
    }

    func toggleInteractive() {
        debugTrace("HOTKEY toggleInteractive")
        clickThroughPreferred.toggle()
        let isExpanded = machine.state.current == .expanded
        model.isInteractive = isExpanded || !clickThroughPreferred
        panel.ignoresMouseEvents = clickThroughPreferred && !isExpanded
        persistPreferences()
        updateAccessibilityExposure()
    }

    func togglePositionLock() {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        positionLocked.toggle()
        model.isPositionLocked = positionLocked
        applyMovability()
        persistPlacement()
        if !positionLocked {
            resetAvoidanceAttempt()
            evaluateSpace(immediate: true)
        }
    }

    /// 锁定位置时，标题栏和悬浮形态的整块拖动都不能挪窗口（自动避让同样跳过，见 `positionLocked` 守卫）。
    private func applyMovability() {
        let isExpanded = machine.state.current == .expanded
        panel.isMovable = !positionLocked
        panel.isMovableByWindowBackground = !isExpanded && !positionLocked
    }

    func setAutoAvoid(_ enabled: Bool) {
        userIntentSeq &+= 1
        spatial.autoAvoidEnabled = enabled
        appearance.setAutoAvoidEnabled(enabled)
        resetAvoidanceAttempt()
        evaluateSpace(immediate: true)
    }

    func applyLyricFontSize(_ value: Double) {
        // 视图直接读 `AppearanceSettings`，这里只负责把设置落到存储并让界面刷新。
        appearance.setLyricFontSize(min(max(value, 11), 30))
        refreshRootView()
    }

    func applyLyricLineSpacing(_ value: Double) {
        appearance.setLyricLineSpacing(min(max(value, 0), 24))
        refreshRootView()
    }

    func applyShowLyricTranslation(_ enabled: Bool) {
        appearance.setShowLyricTranslation(enabled)
        model.showLyricTranslation = enabled
        refreshRootView()
    }

    private func targetAlpha(for morphology: PlayerMorphology? = nil) -> CGFloat {
        let current = morphology ?? machine.state.current
        return current == .expanded ? 1 : CGFloat(LyricsOpacity.clamp(appearance.floatingOpacity))
    }

    func applyFloatingOpacity(_ value: Double) {
        panel.alphaValue = targetAlpha()
    }

    func applyFloatingAppearance(_ mode: FloatingAppearanceMode) {
        appearance.setFloatingAppearance(mode)
        backgroundPolicy.reset()
        updateBackgroundAppearance(force: true)
    }

    func setDormantStyle(_ style: DormantStyle) {
        dormantStyle = style
        persistPreferences()
        // 双向都要即时生效：edgeHandle→hideCompletely 在 dormant 中也要下屏，
        // 否则把手会残留到下一次 apply 才消失。
        if machine.state.current == .dormant {
            switch style {
            case .edgeHandle: showPanel()
            case .hideCompletely: panel.orderOut(nil)
            }
        }
    }

    func setFloatingShape(_ shape: LyricsShape) {
        guard shape != storedShape else { return }
        // 换歌词排布是"同一个窗口换个内容尺寸"，不该触发重新选址。
        userMorphUntil = clock.now.advanced(by: .milliseconds(6000))
        spatialSeq &+= 1
        storedShape = shape
        persistPreferences()
        refreshRootView()
        if machine.state.current == .capsule || machine.state.current == .edge {
            // 歌词排布变了，窗口高度也要跟着变。
            resizedForShapeChange()
        }
    }

    func refreshQueue() {
        let queue = playback.queueSnapshot
        model.queue = queue
        reloadTrackTitles()
        model.repeatMode = queue.repeatMode
        model.isShuffling = queue.isShuffling
        model.track = playback.currentTrack
        model.volume = playback.volume
        model.isMuted = playback.isMuted
    }

    func noteAuxiliaryActivity(_ isActive: Bool) {
        apply(machine.handle(.auxiliaryActivityChanged(isActive), now: clock.now))
        evaluateSpace(immediate: true)
    }

    func resetPlacementMemory() async {
        await placements.clear()
        var snapshot = preferences.load()
        snapshot.morphologyByDisplay.removeAll()
        snapshot.edgeByDisplay.removeAll()
        snapshot.isMorphologyLocked = false
        preferences.save(snapshot)
        positionLocked = false
        storedShape = appearance.defaultShape
        machine = MorphologyStateMachine(state: MorphologyState(), tuning: machine.tuning)
        model.morphology = machine.state.current
        model.isMorphologyLocked = false

        let target = appearance.defaultMorphology
        if target == .expanded {
            let geometry = screen(containing: panel.frame)
                ?? ScreenGeometryResolver.mainScreenGeometry()
            currentDisplayID = geometry.id
            let size = PlayerMorphology.expanded.geometry.preferredSize
            var frame = NSRect(origin: .zero, size: size)
            frame.origin.x = geometry.safeZone.midX - size.width / 2
            frame.origin.y = geometry.safeZone.midY - size.height / 2
            frame = frame.clamped(into: geometry.safeZone)
            configureWindow(for: .expanded)
            panel.setFrame(frame, display: true)
            refreshRootView()
            evaluateSpace(immediate: true)
        } else {
            moveToDefaultPosition(for: storedShape)
            apply(machine.handle(.userRequested(target), now: clock.now))
        }
    }

    // MARK: - FloatingLyricsControlling

    var shape: LyricsShape { storedShape }
    var isLocked: Bool { positionLocked }

    func applyAutoAvoid(_ enabled: Bool) {
        setAutoAvoid(enabled)
    }

    func show() {
        if machine.state.isUserHidden {
            apply(machine.handle(.userHiddenChanged(false), now: clock.now))
        }
        // 藏起来的来源不止"用户按了隐藏"：空间评估、睡眠、全屏都会把形态压到 `.dormant`。
        // 那些路径下 `isUserHidden` 一直是 false，`userHiddenChanged(false)` 会被状态机判成
        // redundant 直接吞掉 —— 表现就是 ⌃⌥H 按下去毫无反应，应用只剩一个还在出声的后台进程。
        // 所以只要还停在 `.dormant`，就用一条"用户指定形态"把它拉回可见。
        // 注意：这会把 `.compact` 记进 userChosenMorphology 并抑制一小段自动放宽——
        // 唤醒后短时间内形态被"钉"在紧凑条，是有意取舍（避免刚唤醒就被自动决策再挪走）。
        if machine.state.current == .dormant {
            setMorphology(.compact)
        }
        if !panel.isVisible { showPanel() }
    }

    func hide() {
        userIntentSeq &+= 1
        spatialSeq &+= 1
        apply(machine.handle(.userHiddenChanged(true), now: clock.now))
        if machine.state.phase == .settled { panel.orderOut(nil) }
    }

    func toggleVisibility() {
        debugTrace("HOTKEY toggleVisibility")
        if panel.isVisible && machine.state.current != .dormant {
            hide()
        } else {
            show()
        }
    }

    func setShape(_ shape: LyricsShape) {
        setFloatingShape(shape)
    }

    func cycleShape() {
        setFloatingShape(storedShape.next)
    }

    func toggleLock() {
        togglePositionLock()
    }

    func resetToDefaultPosition() {
        moveToDefaultPosition(for: storedShape)
        evaluateSpace(immediate: true)
    }

    func requestAccessibilityPermission() {
        accessibility.requestIfNeeded()
        startAccessibilityTracking()
        evaluateSpace(immediate: true)
    }

    func refreshAccessibilityPermission() {
        accessibility.refresh()
        startAccessibilityTracking()
        evaluateSpace(immediate: true)
    }

    var accessibilityPermission: AccessibilityPermission { accessibility.permission }
    var isHiddenForFullscreen: Bool { machine.state.suspendedBy == .fullscreen }

    // MARK: - 状态机动作执行

    private func apply(_ decision: MorphologyDecision) {
        guard !decision.actions.isEmpty || decision.state != machine.state else {
            log(decision)
            return
        }
        log(decision)
        for action in decision.actions {
            if case .transition(let from, let to) = action, from != to {
                // 规格与用户预期一致：**绝不自动展开**。
                // 实测出现过"空间变大 → 自己弹出完整播放器 → 立刻又缩回去"的自动展开循环。
                //
                // 但**用户点开的**必须放行：这条规则原本不分来源，
                // 把"点胶囊展开"也当自动展开拦掉了——用户看到的是"点了没反应"（实测）。
                let userInitiated = decision.reason?.rawValue.hasPrefix("user") ?? false
                // 沉浸播放中不接受任何自动收缩（实机：全屏沉浸时失去焦点，被空间评估收成了迷你条）。
                if Self.suppressesDuringImmersive(from: from, to: to, userInitiated: userInitiated,
                                                  isImmersive: model.isImmersive) {
                    debugTrace("SUPPRESSED auto-collapse during immersive \(from.rawValue) -> \(to.rawValue)")
                    machine.assumeMorphology(from)
                    continue
                }
                if userInitiated && to == .expanded { allowExpandedOnce = true }
                if to == .expanded && !allowExpandedOnce && !userInitiated {
                    debugTrace("SUPPRESSED auto-expand \(from.rawValue) -> expanded")
                    // 状态机已经走到 expanded 了，窗口没动：必须拉回来，否则两边不一致。
                    machine.assumeMorphology(from)
                    continue
                }
                allowExpandedOnce = false
            }
            let fromUser = decision.reason?.rawValue.hasPrefix("user") ?? false
            if fromUser, case let .transition(_, to) = action {
                userChosenMorphology = to
                userChosenSignature = lastEnvironment.map {
                    EnvironmentSignature(safeZone: $0.safeZone, obstacles: $0.obstacles)
                }
            }
            perform(action, userInitiated: fromUser)
        }
        model.isMorphologyLocked = decision.state.isLocked
        model.recommendedMorphology = decision.state.recommendation.morphology
    }

    private func perform(_ action: MorphologyAction, userInitiated: Bool = false) {
        switch action {
        case let .transition(from, to):
            if to != .expanded, model.isImmersive { setImmersive(false) }
            beginTransition(from: from, to: to, userInitiated: userInitiated)
        case .orderOut:
            // 隐匿策略：完全隐藏才真的下屏；保留把手时窗口留在屏上但只剩一小块。
            if machine.state.isUserHidden || dormantStyle == .hideCompletely { panel.orderOut(nil) }
        case .orderFront:
            panel.alphaValue = targetAlpha()
            showPanel()
        case .activateApplication:
            guard !Self.isHeadlessHost else { break }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        case .resignKeyFocus:
            if panel.isKeyWindow { panel.resignKey() }
        }
    }

    /// 按窗口所在壁纸区域选择深浅；后台缩略采样，不读取其他应用像素。
    /// 独立于自动避让运行：锁定位置/形态、关闭避让后仍应更新颜色。
    private func updateBackgroundAppearance(force: Bool = false) {
        guard force || isStarted else { return }
        let now = clock.now
        if !force, let lastBackgroundCheckAt, now < lastBackgroundCheckAt.advanced(by: .milliseconds(350)) { return }
        lastBackgroundCheckAt = now
        if !force, !panel.isVisible || model.isTransitioning || isRelocating
            || model.isAnimatingGeometry { return }
        guard model.morphology != .expanded else {
            cancelBackgroundSample()
            applyBackgroundTone(nil)
            return
        }
        if let forced = ProcessInfo.processInfo.environment["SLP_DEBUG_APPEARANCE"],
           let tone = BackgroundTone(rawValue: forced) {
            useFixedBackgroundTone(tone)
            return
        }
        // 注入一次合成采样，绕开"真实壁纸恰好证据不足"的情况。
        // 与 `SLP_DEBUG_APPEARANCE` 的区别：后者直接指定**卡片**色调、跳过判色；
        // 这里走完整的 `classification → contrastingCardTone` 链路，
        // 所以能在真机上复现"深色背景到底出浅卡片还是黑卡片"这类极性 bug。
        if let forcedLuma = ProcessInfo.processInfo.environment["SLP_DEBUG_WALLPAPER_LUMA"],
           let luma = Double(forcedLuma) {
            let contrast = ProcessInfo.processInfo.environment["SLP_DEBUG_WALLPAPER_CONTRAST"]
                .flatMap(Double.init) ?? 0.02
            consumeBackgroundSample(BackgroundSample(meanLuma: luma, contrast: contrast),
                                    now: clock.now)
            return
        }
        switch appearance.floatingAppearance {
        case .system:
            useFixedBackgroundTone(nil); return
        case .light:
            useFixedBackgroundTone(.light); return
        case .dark:
            useFixedBackgroundTone(.dark); return
        case .background: break
        }
        let frame = panel.frame
        let nsScreen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            ?? panel.screen
        guard let nsScreen else { useUnknownBackground(); return }
        // 自动避让可关闭，但判读壁纸前仍要确认身后没有普通窗口。
        // 复用后台缓存：这里每次 tick 都会走，不能再同步枚举一遍 WindowServer。
        if let request = obstacleRequest(for: frame) { obstacleProvider.requestRefresh(request) }
        let covered = obstacleProvider.snapshot(in: nsScreen.frame).contains { $0.intersects(frame) }
        model.floatingOverlapsWindow = covered
        guard !covered, let request = WallpaperLuminance.request(for: nsScreen, windowFrame: frame) else {
            useUnknownBackground(); return
        }
        if backgroundRequest == request {
            if wallpaperTask != nil { return }
            if !force, let lastBackgroundSampleAt,
               now < lastBackgroundSampleAt.advanced(by: .seconds(2)) { return }
        }
        cancelBackgroundSample()
        backgroundRequest = request
        let generation = backgroundGeneration
        wallpaperTask = Task { [weak self] in
            let sample = await WallpaperLuminanceSampler.shared.sample(for: request)
            guard !Task.isCancelled, let self, generation == self.backgroundGeneration else { return }
            self.wallpaperTask = nil
            guard self.panel.frame == request.windowFrame, self.model.morphology != .expanded else {
                self.backgroundRequest = nil
                return
            }
            let retry = self.consumeBackgroundSample(sample, now: self.clock.now)
            self.wallpaperTask = nil
            if let retry {
                self.wallpaperTask = Task { [weak self] in
                    try? await Task.sleep(for: retry)
                    guard !Task.isCancelled, let self, generation == self.backgroundGeneration else { return }
                    self.wallpaperTask = nil
                    self.updateBackgroundAppearance(force: true)
                }
            }
        }
    }

    /// 消化一次壁纸采样。**生产与测试走同一条路径。**
    ///
    /// 这里最关键的一行是 `policy.tone?.contrastingCardTone`：
    /// `policy.tone` 说的是"壁纸亮还是暗"，而 `applyBackgroundTone` 要的是"卡片亮还是暗"。
    /// 早先把前者直接传给后者，于是深色壁纸得到深色卡片（黑压黑，等于没有卡片）。
    @discardableResult
    func consumeBackgroundSample(_ sample: BackgroundSample?, now: ContinuousClock.Instant) -> Duration? {
        lastBackgroundSampleAt = now
        model.backgroundSampleUnavailable = sample == nil
        model.wallpaperIsBright = sample.map { $0.meanLuma >= 0.62 } ?? false
        let retry = backgroundPolicy.observe(sample, now: now)
        let wallpaperTone = backgroundPolicy.tone
        applyBackgroundTone(wallpaperTone?.contrastingCardTone)
        if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil {
            let luma = sample.map { String(format: "%.3f", $0.meanLuma) } ?? "nil"
            let contrast = sample.map { String(format: "%.3f", $0.contrast) } ?? "nil"
            debugTrace("BACKGROUND source=wallpaper luma=\(luma) contrast=\(contrast) "
                       + "wallpaper=\(wallpaperTone?.rawValue ?? "system") "
                       + "card=\(model.floatingTone?.rawValue ?? "system")")
        }
        return retry
    }

    private func cancelBackgroundSample() {
        backgroundGeneration &+= 1
        wallpaperTask?.cancel()
        wallpaperTask = nil
        backgroundRequest = nil
    }

    private func useFixedBackgroundTone(_ tone: BackgroundTone?) {
        cancelBackgroundSample()
        backgroundPolicy.reset()
        model.backgroundSampleUnavailable = true
        model.wallpaperIsBright = false
        applyBackgroundTone(tone)
    }

    private func useUnknownBackground() {
        cancelBackgroundSample()
        backgroundPolicy.reset()
        model.backgroundSampleUnavailable = true
        model.wallpaperIsBright = false
        applyBackgroundTone(nil)
    }

    /// 只改本面板，不改 NSApp：设置窗/菜单和完整形态继续跟随系统。
    private func applyBackgroundTone(_ tone: BackgroundTone?) {
        model.floatingTone = tone
        let target: NSAppearance?
        switch tone {
        case .light: target = NSAppearance(named: .aqua)
        case .dark: target = NSAppearance(named: .darkAqua)
        case nil: target = nil
        }
        if panel.appearance?.name != target?.name { panel.appearance = target }
    }

    private func beginTransition(from: PlayerMorphology, to: PlayerMorphology, userInitiated: Bool) {
        cancelRelocation()
        cancelBackgroundSample()
        resetAvoidanceAttempt()
        let zone = safeZone(for: panel.frame)
        // 自动决策直接消费同一快照；用户手动切换才重新获取当前几何。
        let hasPlacement = pendingPlacement?.morphology == to && pendingPlacementVersion == spatialSeq
        let obstacles = hasPlacement ? lastObstacles : cachedObstacles(for: panel.frame, ignoringSelf: true)
        // 落点**一律**来自求解器：决策与执行必须用同一套几何，
        // 否则会出现"决定变成 edge、却按旧锚点逻辑摆成 420 宽的贴边条"（实测踩到）。
        var target: MorphologyTarget
        // 标准尺寸优先：目标形态的窗口尺寸是设计规格，只要它不压到别的窗口就用它。
        // 挤压/换位置只在标准尺寸真的放不下时才发生（否则恢复记忆形态会被挤成 391×53）。
        let canonicalSize = to.geometry.fitted(into: zone.size)
        let canonical = CGRect(x: panel.frame.minX,
                               y: panel.frame.maxY - canonicalSize.height,
                               width: canonicalSize.width,
                               height: canonicalSize.height)
            .integral
            .clamped(into: zone, margin: 0)
        let canonicalOK = to != .expanded && to != .dormant
            && zoneContains(canonical, in: zone)
            && Coverage.fraction(of: canonical, by: obstacles) == 0
        if to == .expanded {
            // 主窗口**不避让**别的应用窗口。
            //
            // 避让是给悬浮歌词定的规矩：它不该压在别人窗口上。
            // 但主窗口是用户主动打开的"正常窗口"，桌面再挤也必须能开出来——
            // 实测踩到过：桌面窗口一多，求解器判定"放不下"，主窗口直接退化成 26×72 的把手，
            // 用户看到的是"主页面打不开了"。
            // 这里只做两件事：按设计尺寸、钳进安全区（不压菜单栏/Dock）。
            target = MorphologyTarget(frame: canonical, didPreserveAnchor: true, edge: nil,
                                      note: "主窗口标准尺寸，不避让其他窗口")
            lastRelocationTarget = canonical
            pendingPlacement = nil
        } else if to == .dormant {
            // 无空间时只把把手留在屏幕边缘，不把它摆到工作区中央。
            target = resolver.resolve(to, currentFrame: panel.frame, in: zone, obstacles: [])
        } else if let pending = pendingPlacement, hasPlacement {
            target = MorphologyTarget(frame: pending.frame, didPreserveAnchor: false,
                                      edge: nil, note: "同一快照的形态与落点")
        } else if canonicalOK {
            target = MorphologyTarget(frame: canonical, didPreserveAnchor: true, edge: nil,
                                      note: "标准尺寸 + 当前锚点")
            lastRelocationTarget = canonical
            pendingPlacement = nil
        } else {
            let solved = ContinuousPlacementSolver(edgeInset: resolver.edgeInset).solve(
                zone: zone,
                obstacles: obstacles,
                currentFrame: panel.frame,
                current: to,
                preferredOrigin: nil,
                allowed: [to],
                snapshotVersion: spatialSeq
            )
            if let best = solved.best {
                target = MorphologyTarget(frame: best.frame, didPreserveAnchor: false,
                                          edge: nil, note: "补算落点：" + solved.reason)
            } else {
                target = resolver.resolve(to, currentFrame: panel.frame, in: zone,
                                          obstacles: obstacles,
                                          edge: to == .edge ? currentEdge : nil)
            }
        }
        // 用户显式切换形态时，**几何必须真的跟着换**（不能残留上一形态的 1020×640 大框）。
        // 但如果求解器在目标形态自身规格 [minimumSize, preferred/maximum] 内通过微缩尺寸已经避开了障碍物，
        // 应保留该合法避让位置，而不是强行拉回标准尺寸压到别人的窗口上。
        let targetGeometry = to.geometry
        let targetMaximum = targetGeometry.maximumSize ?? targetGeometry.preferredSize
        let sizeBelongsToTarget = to == .expanded || to == .dormant
            || (target.frame.width + 0.5 >= targetGeometry.minimumSize.width
                && target.frame.height + 0.5 >= targetGeometry.minimumSize.height
                && target.frame.width <= targetMaximum.width + 0.5
                && target.frame.height <= targetMaximum.height + 0.5)
        if userInitiated, to != .expanded, to != .dormant, !sizeBelongsToTarget {
            debugTrace("USER-FORCED size \(target.frame.size) -> \(canonicalSize) for \(to.rawValue)")
            target = MorphologyTarget(frame: canonical, didPreserveAnchor: true, edge: target.edge,
                                      note: "用户指定形态：按标准尺寸落位")
            lastRelocationTarget = canonical
            pendingPlacement = nil
        }

        // 兜底校验：任何来源（含用户点击悬浮）的目标矩形若压到别的窗口或出界，
        // 只要同形态内还能找到无遮挡/更少遮挡的合法位置，就应第一时间避开，
        // 避免先盖住别的窗口；仅当桌面全被占满时才保留原位置并配合实底保证可读。
        if to != .expanded, to != .dormant,
           !legalAgainstObstacles(target.frame, obstacles: obstacles, zone: zone) {
            let currentOverlap = Coverage.fraction(of: target.frame, by: obstacles)
            let retry = ContinuousPlacementSolver(edgeInset: resolver.edgeInset).solve(
                zone: zone,
                obstacles: obstacles,
                currentFrame: panel.frame,
                current: to,
                preferredOrigin: nil,
                allowed: [to],
                snapshotVersion: spatialSeq
            )
            if let best = retry.best,
               legalAgainstObstacles(best.frame, obstacles: obstacles, zone: zone)
                || Coverage.fraction(of: best.frame, by: obstacles) + 0.01 < currentOverlap {
                debugTrace("TARGET rejected (\(target.frame)), re-solved to \(best.frame)")
                target = MorphologyTarget(frame: best.frame, didPreserveAnchor: false,
                                          edge: nil, note: "重算落点：" + retry.reason)
            }
        }

        if to.isFloating {
            // 悬浮形态压在别人窗口上时用实底：透明胶囊在白底窗口上等于没有字。
            model.floatingOverlapsWindow = Coverage.fraction(of: target.frame, by: obstacles) > 0
        }
        lastRelocationTarget = target.frame
        if to == .edge {
            currentEdge = resolver.nearestEdge(to: target.frame, in: zone)
        }
        if let edge = target.edge { currentEdge = edge }
        debugTrace("TRANSITION to=\(to.rawValue) pending=\(pendingPlacement?.morphology.rawValue ?? "nil") "
                   + "obstacles=\(obstacles.count) frame=\(panel.frame) target=\(target.frame) note=\(target.note)")

        var plan = MorphTransitionPlan.make(
            from: from, to: to,
            fromFrame: panel.frame, toFrame: target.frame,
            screenDiagonal: hypot(zone.width, zone.height),
            tuning: machine.tuning,
            reduceMotion: reduceMotion
        )
        // 设置里的"过渡速度"直接乘在时长上：1 = 令牌默认，0.5 = 慢一倍，1.5 = 快。
        plan.duration = scaledDuration(plan.duration, by: appearance.morphTransitionSpeed)
        // 再按帧数下限抬一次：0.18s 在 60Hz 上只有 11 帧，观感就是"帧太少"。
        // 240Hz 屏上这条几乎不生效（本身帧数就够），所以不会显得拖沓。
        plan.duration = motionTiming.resolve(base: plan.duration, refreshRate: currentRefreshRate)

        transitionTask?.cancel()
        traceTransition(plan)
        configureWindow(for: to)

        // 内容先切：交叉淡化与窗口几何动画同时进行，用户看到的是"折叠"而不是"换页"。
        model.morphology = to
        model.isTransitioning = true
        if to == .expanded {
            cancelBackgroundSample()
            applyBackgroundTone(nil)
        }
        refreshRootView()

        // 无论有没有动画，落位都走**同一个入口**：
        // `animateFrame` 在即时模式里同步落位并立刻回调，动画模式里逐帧推进。
        // 这样"减少动态效果 / 测试"与正常动画的落点必定一致——
        // 之前零时长分支直接 setFrame，绕过了边界钳制，窗口会贴死在屏幕边缘。
        transitionTask = nil
        let recipe = MotionCatalog.recipe(from: plan.from, to: plan.to)
        animateFrame(target.frame, recipe: recipe) { [weak self] in
            guard let self else { return }
            self.finishTransition(plan)
        }
    }

    /// 调试用：以 60ms 采样窗口 frame，日志里能看到一串中间态。
    /// 这是"连续变形"的实测证据——如果只有起点和终点两行，说明退化成了瞬切。
    private func traceTransition(_ plan: MorphTransitionPlan) {
        guard ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil,
              seconds(plan.duration) > 0 else { return }
        let samples = max(2, Int(seconds(plan.duration) / 0.06))
        Task { [weak self] in
            for _ in 0..<samples {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self else { return }
                FileHandle.standardError.write(Data(
                    "TRACE t frame=\(self.panel.frame) alpha=\(self.panel.alphaValue)\n".utf8))
            }
        }
    }

    private func finishTransition(_ plan: MorphTransitionPlan) {
        transitionTask = nil
        if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil {
            let line = "MORPH-DONE \(plan.from.rawValue)->\(plan.to.rawValue) frame=\(panel.frame) "
                + "note=\(plan.note)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        model.isTransitioning = false
        model.lastMorphologyNote = plan.note
        // 收尾自己也可能产生动作（隐匿形态在这一步才真正 orderOut），必须执行。
        let completion = machine.handle(.transitionCompleted, now: clock.now)
        for action in completion.actions { perform(action) }
        persistPlacement()
        persistPreferences()
        updateBackgroundAppearance(force: true)
        resetAvoidanceAttempt()
        deferredEvaluationPending = false
        evaluateSpace(immediate: true)
        // 这里**不再**重建根视图：`model` 是可观察的，形态变化已由 SwiftUI 自己跟上；
        // 重建整棵根视图会把最后一帧顶掉（实测动画末尾出现约 65ms 的空隙）。
    }

    /// 动画期间用 `display: false`：让 AppKit/WindowServer 把绘制合并到显示器刷新，
    /// 而不是每一小步都同步重绘一次（那是逐帧卡顿的主要来源）。
    /// 把窗口送到既定落点。
    ///
    /// "既定落点"由决策层算好后传进来，本函数**只负责呈现**：
    /// 不重新求解、不读几何，因此动画过程中不会反向影响下一次落点。
    /// 尺寸在起点一次定好，动画期间只动原点，内容因此完全不重排。
    /// 把窗口送到既定落点，**按弹簧配方逐帧推进**。
    ///
    /// 落点由决策层算好，本函数只负责呈现：
    /// - 几何每帧钳进安全区（配方声明可过冲时也一样，安全区是硬边界）；
    /// - 内容层的回弹通过 `model.contentBounceScale` 交给视图，不触碰窗口 frame。
    private func animateFrame(_ frame: CGRect,
                              recipe: TransitionRecipe,
                              finished: (@MainActor @Sendable () -> Void)? = nil) {
        // 硬边界 = 安全区再内缩一个 edgeInset：求解器本来就预留了这点呼吸。
        let bounds = safeZone(for: panel.frame)
            .insetBy(dx: resolver.edgeInset, dy: resolver.edgeInset)
        let landing = WindowFrameAnimator.clamp(frame, inside: bounds)

        // 即时模式：减少动态效果，或测试里把所有时长归零。
        // 这条路径必须**真的落位**，否则调用方拿到的还是旧 frame；
        // 而且落点要和动画路径完全一致（同样钳进边界），否则两条路会给出不同结果。
        guard !reduceMotion, animatesTransitions, let host = hosting else {
            frameAnimator.cancel()
            panel.setFrame(landing, display: true)
            model.presentationSizeOverride = nil
            model.isAnimatingGeometry = false
            model.contentBounceScale = 1
            finished?()
            return
        }
        // 尺寸不变时冻结排版：那种情况下内容本来就不用重排，还能省掉逐帧布局。
        let sizeChanges = panel.frame.size != frame.size
        // 看门狗票据在投递 animate 之前先推进，确保完成回调延迟一帧执行的 Task 同样受代次保护。
        watchdogGeneration &+= 1
        let ticket = watchdogGeneration
        model.presentationSizeOverride = sizeChanges ? nil : frame.size
        model.isAnimatingGeometry = true
        frameAnimator.animate(from: panel.frame, to: landing, recipe: recipe, inside: bounds,
                              window: panel, hostView: host,
                              contentScale: { [weak self] scale in
                                  self?.model.contentBounceScale = scale
                              },
                              completion: { [weak self] in
                                  guard let self, self.watchdogGeneration == ticket else { return }
                                  self.model.presentationSizeOverride = nil
                                  self.model.isAnimatingGeometry = false
                                  self.model.contentBounceScale = 1
                                  // 收尾会占主线程几十毫秒：推迟一个 runloop，让最后一帧先上屏。
                                  Task { @MainActor [weak self] in
                                      guard let self, self.watchdogGeneration == ticket else { return }
                                      if let finished {
                                          finished()
                                      } else if self.deferredEvaluationPending {
                                          self.deferredEvaluationPending = false
                                          self.evaluateSpace(immediate: true, geometryOnly: true)
                                      }
                                  }
                              })

        // 看门狗：borderless 面板上 `window.animator().setFrame` 偶尔**静默不落地**。
        //
        // 实测现象：内容已经切到迷你条，窗口还停在 1020×640，一整张空白大卡片；
        // 要再按一次形态热键、"下一次"过渡才追上。日志里 TRANSITION 有正确的目标矩形，
        // 但窗口没动 —— 系统动画的完成回调也没来，于是 `isAnimatingGeometry` 一直挂着。
        // 无论系统是否已把坐标送达 `landing`，只要看门狗到期且 `isAnimatingGeometry` 仍挂起，
        // 就必须收尾复位并执行 `finished`，防止状态永远卡在动画中进而导致后续避让彻底失灵。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(recipe.duration * 1000) + 150))
            guard let self, self.watchdogGeneration == ticket, self.model.isAnimatingGeometry else { return }
            let now = self.panel.frame
            let needsSnap = abs(now.minX - landing.minX) > 0.5 || abs(now.minY - landing.minY) > 0.5
                || abs(now.width - landing.width) > 0.5 || abs(now.height - landing.height) > 0.5
            self.debugTrace("WATCHDOG 动画超时收尾 \(now) -> \(landing) snap=\(needsSnap)")
            // `cancel()` 会推进 generation：系统那条迟到的完成回调随之失效，不会二次收尾。
            self.frameAnimator.cancel()
            if needsSnap {
                self.panel.setFrame(landing, display: true)
            }
            self.model.presentationSizeOverride = nil
            self.model.isAnimatingGeometry = false
            self.model.contentBounceScale = 1
            if let finished {
                finished()
            } else if self.deferredEvaluationPending {
                self.deferredEvaluationPending = false
                self.evaluateSpace(immediate: true, geometryOnly: true)
            }
        }
    }


    /// 窗口层：形态决定层级、焦点能力、阴影与 Space 行为。
    /// 窗口生命周期回调（AppKit 直接调）。
    ///
    /// 三件事：
    /// - 红点/⌘W 不真关窗：走"收进菜单栏"，和界面里的 × 一致，避免留下一个关不掉的空壳；
    /// - 进全屏时告诉形态机，并让它别再自动摆位置；
    /// - 退出全屏后恢复一次摆放。
    /// 必须带 `sender`：`NSWindowDelegate` 只认 `windowShouldClose(_:)`。
    /// 旧的无参版本注册不上代理，红点会真的关窗，应用随后无窗口可回。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        collapseToDock()
        return false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard machine.state.current == .expanded else { return frameSize }
        let minimum = PlayerMorphology.expanded.geometry.minimumSize
        return NSSize(width: max(frameSize.width, minimum.width),
                      height: max(frameSize.height, minimum.height))
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        windowWillEnterFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        windowDidExitFullScreen()
    }

    func windowWillEnterFullScreen() {
        apply(machine.handle(.fullscreenChanged(true), now: clock.now))
    }

    func windowDidExitFullScreen() {
        apply(machine.handle(.fullscreenChanged(false), now: clock.now))
        // 用户用绿灯 / 菜单退出了沉浸模式打开的全屏：沉浸也跟着结束，不留一个窗口化的沉浸页。
        if model.isImmersive, immersiveOwnsFullScreen {
            immersiveOwnsFullScreen = false
            setImmersive(false)
        }
        if floatingAfterFullScreenExit {
            floatingAfterFullScreenExit = false
            setMorphology(.capsule)
        }
        evaluateSpace(immediate: true)
    }

    // MARK: - 三档

    var playerMode: PlayerMode { PlayerMode.current(morphology: machine.state.current, isImmersive: model.isImmersive) }

    /// 右上角三档。普通 = 完整播放器；悬浮 = 桌面歌词胶囊（点一下回到普通）；沉浸 = 场景铺满。
    func setPlayerMode(_ mode: PlayerMode) {
        guard mode != playerMode else { return }
        switch mode {
        case .normal:
            if model.isImmersive { setImmersive(false) } else { expand() }
        case .immersive:
            if machine.state.current != .expanded { expand() }
            setImmersive(true)
        case .floating:
            let waitsForFullScreen = model.isImmersive && immersiveOwnsFullScreen && panel.styleMask.contains(.fullScreen)
            if model.isImmersive { setImmersive(false) }
            if waitsForFullScreen {
                floatingAfterFullScreenExit = true
            } else {
                setMorphology(.capsule)
            }
        }
    }

    // MARK: - 沉浸播放

    func toggleImmersive() {
        setImmersive(!model.isImmersive)
    }

    /// 沉浸中只有用户自己能把播放器收起来；空间评估、失焦这类自动决策一律让路。
    static func suppressesDuringImmersive(from: PlayerMorphology, to: PlayerMorphology,
                                          userInitiated: Bool, isImmersive: Bool) -> Bool {
        isImmersive && from == .expanded && to != .expanded && !userInitiated
    }

    /// 进入 / 退出沉浸播放。只在完整形态下可进入；需要时顺带进出全屏。
    func setImmersive(_ on: Bool) {
        guard model.isImmersive != on else { return }
        if on {
            guard machine.state.current == .expanded else { return }
            model.auxiliary = nil
            noteAuxiliaryActivity(false)
            model.isImmersive = true
            setTrafficLightsHidden(true)
            if appearance.immersiveEntersFullScreen, !panel.styleMask.contains(.fullScreen), !Self.isHeadlessHost {
                immersiveOwnsFullScreen = true
                // 从菜单栏、悬浮胶囊等不激活应用的入口过来时，主窗口未必是 key、应用也未必在前台。
                // 这是用户点按钮触发的，先把应用带到前台再全屏，和 `.activateApplication` 一致。
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.toggleFullScreen(nil)
            }
        } else {
            model.isImmersive = false
            setTrafficLightsHidden(false)
            if immersiveOwnsFullScreen {
                immersiveOwnsFullScreen = false
                if panel.styleMask.contains(.fullScreen) { panel.toggleFullScreen(nil) }
            }
        }
        refreshRootView()
    }

    /// 窗口化的沉浸页不显示交通灯：画面里只留场景与歌词（退出靠 Esc 或右上角按钮）。
    private func setTrafficLightsHidden(_ hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    private func configureWindow(for morphology: PlayerMorphology) {
        let isExpanded = morphology == .expanded
        panel.level = isExpanded ? .normal : .floating
        // 完整形态要显式声明 `.fullScreenPrimary`：NSPanel 默认不参与全屏，
        // 不声明的话 `toggleFullScreen` 静默无效（沉浸模式实机发现：点了进入、窗口纹丝不动）。
        panel.collectionBehavior = isExpanded
            ? [.managed, .participatesInCycle, .fullScreenPrimary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // 悬浮形态**不能**成为 key：那会抢走用户正在别处打的字。
        // 首击不丢失靠 `MorphHostingView.acceptsFirstMouse`（那条路径已有测试）。
        panel.allowsKeyFocus = isExpanded
        // `becomesKeyOnlyIfNeeded = true` 会让面板"除非有文本框否则永不成为 key"，
        // 结果是完整形态里点击既不给焦点、SwiftUI 又把控件点击当成"非活跃窗口点击"忽略掉
        // （实测：日志里有 mouseDown/mouseUp，按钮就是不动）。完整形态必须能自己成为 key。
        panel.becomesKeyOnlyIfNeeded = !isExpanded
        // 完整形态必须能从"非激活"状态用一次点击就激活：
        // `.nonactivatingPanel` 会让应用永远不激活，而 macOS 的 Button 在非激活应用里
        // 不响应点击（手势可以，控件不行）——实测：胶囊能点开、完整形态里按钮全都点不动。
        //
        // 完整形态用**真标题栏**：
        // 之前是无边框 + 自绘拖动手柄，结果是"拖不动、也没有关闭/最小化/全屏"——
        // 用户对主窗口的预期就是这三个按钮加标题栏拖动，自绘方案再漂亮也补不上。
        // 标题栏透明、标题隐藏，视觉上仍然是一张无边框版面；悬浮形态保持无边框。
        panel.styleMask = isExpanded
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless, .nonactivatingPanel]
        // 原生拖拽也要遵守主窗口下限；悬浮形态解除限制以允许连续收缩。
        panel.minSize = isExpanded ? PlayerMorphology.expanded.geometry.minimumSize : .zero
        panel.titlebarAppearsTransparent = isExpanded
        panel.titleVisibility = isExpanded ? .hidden : .visible
        panel.title = "FLOW"
        // 面板层级：完整形态是普通窗口（能进全屏、能进窗口列表），悬浮形态才是浮动层。
        panel.isFloatingPanel = !isExpanded
        panel.hasShadow = isExpanded
        // 完整形态**不能**用 isMovableByWindowBackground：SwiftUI 的全部内容都在同一个
        // NSHostingView 里，AppKit 会把它整块当成"背景"从而吞掉所有点击（实测：按钮点不动）。
        // 拖动改由顶栏的显式拖动手柄负责；悬浮形态没有按钮，整块拖动正合适。
        applyMovability()
        panel.ignoresMouseEvents = isExpanded ? false : clickThroughPreferred
        // 完整播放器是一张正经的版面，不参与"悬浮不透明度"；
        // 半透明的材质底下透出桌面，文字对比度会直接崩掉。
        panel.alphaValue = targetAlpha(for: morphology)
        model.isInteractive = isExpanded ? true : isInteractive
        updateAccessibilityExposure()
    }

    /// 穿透形态不该在无障碍树里留下可聚焦但点不到的控件。
    private func updateAccessibilityExposure() {
        let passive = machine.state.current != .expanded && !isInteractive
        panel.setAccessibilityHidden(passive)
        panel.setAccessibilityValue(model.floatingLine)
        panel.setAccessibilityHelp(machine.state.current.displayName)
    }

    // MARK: - 初始化与恢复

    private func restorePreferences() {
        spatial.autoAvoidEnabled = appearance.autoAvoidEnabled
        let snapshot = preferences.load()
        storedShape = LyricsShape(rawValue: snapshot.floatingShape) ?? .capsule
        dormantStyle = DormantStyle(rawValue: snapshot.dormantStyle) ?? .edgeHandle
        clickThroughPreferred = snapshot.isClickThrough
        model.isInteractive = !snapshot.isClickThrough
        positionLockOverride = false
        model.isPositionLocked = false
        model.isMorphologyLocked = snapshot.isMorphologyLocked
        if snapshot.isMorphologyLocked {
            _ = machine.handle(.userLockChanged(true), now: clock.now)
        }
        panel.ignoresMouseEvents = snapshot.isClickThrough && machine.state.current != .expanded
        model.lyricState = lyricEngine.state

        let initialUserIntentSeq = userIntentSeq
        Task { [weak self] in
            guard let self else { return }
            var restoredFrame: NSRect?
            if let placement = await self.placements.load() {
                restoredFrame = self.restore(placement)
            }
            guard self.isStarted, self.userIntentSeq == initialUserIntentSeq else { return }
            let displayID = restoredFrame.flatMap { self.screen(containing: $0)?.id }
                ?? ScreenGeometryResolver.mainScreenGeometry().id
            self.currentDisplayID = displayID
            let savedMorphology = snapshot.morphologyByDisplay[displayID]
                .flatMap(PlayerMorphology.init(rawValue:))
            let restoredMorphology: PlayerMorphology
            if let savedMorphology,
               self.appearance.autoCollapseOnDeactivate || snapshot.isMorphologyLocked || savedMorphology == .expanded {
                restoredMorphology = savedMorphology
            } else {
                restoredMorphology = self.appearance.defaultMorphology
            }
            let edge = snapshot.edgeByDisplay[displayID].flatMap(ScreenEdge.init(rawValue:)) ?? .top
            self.currentEdge = edge

            let zone = self.safeZone(for: restoredFrame ?? .zero)
            let anchor = restoredFrame ?? self.centeredAnchor(for: restoredMorphology, in: zone)
            // 冷启动若是悬浮形态：立刻带着实时障碍物快照求解初始落位，避免第一帧压在别人的窗口上。
            let initialObstacles: [CGRect]
            if restoredMorphology != .expanded, restoredMorphology != .dormant,
               !self.positionLocked, self.spatial.autoAvoidEnabled, self.appearance.autoAvoidEnabled {
                initialObstacles = await self.refreshedObstacles(for: anchor)
            } else {
                initialObstacles = []
            }
            guard self.isStarted, self.userIntentSeq == initialUserIntentSeq else { return }

            // 恢复形态：直接落到目标几何，不做动画（冷启动不该有"变形秀"）。
            // **状态机必须一起同步**：只改窗口不改状态机会造成
            // "窗口是胶囊、状态机以为自己是完整形态"，于是点胶囊展开被判定成 redundant，
            // 用户点了没反应（实测踩到）。
            // 只落"当前形态"，运行时事实（失焦时间、是否用起来过、锁定）一概不动。
            self.machine.adoptRestoredMorphology(restoredMorphology)
            self.model.isMorphologyLocked = self.machine.state.isLocked

            self.model.morphology = restoredMorphology
            self.configureWindow(for: restoredMorphology)
            let target = self.resolver.resolve(restoredMorphology,
                                               currentFrame: anchor,
                                               in: zone,
                                               obstacles: initialObstacles,
                                               edge: restoredMorphology == .edge ? edge : nil)
            self.panel.setFrame(target.frame, display: true)
            if let edge = target.edge { self.currentEdge = edge }
            if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil {
                FileHandle.standardError.write(Data(
                    "RESTORED morph=\(restoredMorphology.rawValue) frame=\(self.panel.frame)\n".utf8))
            }
            self.refreshRootView()
            self.applyDebugHooks()
            self.resetAvoidanceAttempt()
            self.evaluateSpace(immediate: true)
        }
    }

    /// 没有位置记忆时的落点：完整形态略高于正中，悬浮形态靠上——都和"第一次打开"的直觉一致。
    private func centeredAnchor(for morphology: PlayerMorphology, in zone: CGRect) -> NSRect {
        let size = morphology.geometry.fitted(into: zone.size)
        let verticalBias: CGFloat = morphology == .expanded ? 0.54 : 0.78
        return NSRect(x: zone.midX - size.width / 2,
                      y: zone.minY + zone.height * verticalBias - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    @discardableResult
    /// 测试用：走一遍位置恢复，返回实际设置的 frame。
    func restoreForTesting(_ snapshot: PlacementSnapshot) -> NSRect { restore(snapshot) }

    private func restore(_ snapshot: PlacementSnapshot) -> NSRect {
        storedShape = snapshot.shape
        // 界面显示与实际锁定状态必须一致（之前只改了显示，实际仍未锁）。
        positionLockOverride = snapshot.isLocked
        model.isPositionLocked = snapshot.isLocked
        clickThroughPreferred = snapshot.isClickThrough
        model.isInteractive = !snapshot.isClickThrough
        panel.ignoresMouseEvents = snapshot.isClickThrough && machine.state.current != .expanded
        applyMovability()
        let screens = ScreenGeometryResolver.current()
        guard let screen = screens.first(where: { $0.id == snapshot.displayID }) else {
            return .zero
        }
        currentDisplayID = screen.id
        let size = snapshot.shape.preferredSize
        let frame = NSRect(x: snapshot.originX, y: snapshot.originY,
                           width: size.width, height: size.height)
            .clamped(into: screen.safeZone)
        panel.setFrame(frame, display: true)
        return frame
    }

    private func moveToDefaultPosition(for shape: LyricsShape) {
        let geometry = screen(containing: panel.frame)
            ?? ScreenGeometryResolver.mainScreenGeometry()
        currentDisplayID = geometry.id
        let size = shape.preferredSize
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = geometry.safeZone.midX - size.width / 2
        frame.origin.y = geometry.safeZone.maxY - size.height - 28
        frame = frame.clamped(into: geometry.safeZone)
        panel.setFrame(frame, display: true)
        persistPlacement()
    }

    /// 换歌词排布（单行/双行/歌词板）时的高度变化。
    private func resizedForShapeChange() {
        guard machine.state.current == .capsule else { return }
        let zone = safeZone(for: panel.frame)
        // 窗口高度跟着歌词行数走，横坐标与宽度**保持不变**：
        // 换歌词排布是"同一个窗口换内容"，不该顺手换个位置（实测会横移 126pt）。
        let height = floatingHeight(for: storedShape)
        // 长高之后必须再夹回安全区——原来贴着下沿时，长高会直接顶到屏幕外（实测 y=-6）。
        let frame = NSRect(x: panel.frame.minX,
                           y: panel.frame.maxY - height,
                           width: panel.frame.width,
                           height: height)
            .clamped(into: zone, margin: 0)
        animateFrame(frame, recipe: MotionCatalog.restore) { [weak self] in
            self?.resetAvoidanceAttempt()
            self?.evaluateSpace(immediate: true, geometryOnly: true)
        }
        persistPlacement()
    }

    private func floatingHeight(for shape: LyricsShape) -> CGFloat {
        switch shape {
        case .capsule: return PlayerMorphology.capsule.geometry.preferredSize.height
        case .doubleLine: return 76
        case .board: return 152
        case .edge: return PlayerMorphology.edge.geometry.preferredSize.height
        }
    }

    /// 队列标题映射。队列只存 Track.ID，标题从仓库一次性取回。
    private func reloadTrackTitles() {
        Task { [weak self] in
            guard let self else { return }
            let all = (try? await self.trackRepository.all()) ?? []
            var titles: [Track.ID: String] = [:]
            // "接下来"三行也用解析后的歌名：原始视频标题会把这三行撑成一堆推广文案。
            for track in all { titles[track.id] = MorphPresentationModel.display(track).title }
            // 引擎内存里那一份是权威快照（刚排进队列、还没落库的曲目只有它知道）。
            let queue = self.playback.queueSnapshot
            for id in queue.items + queue.nextUp + queue.later {
                if let live = self.playback.track(for: id) {
                    titles[id] = MorphPresentationModel.display(live).title
                }
            }
            self.model.trackTitles = titles
        }
    }

    /// 把当前曲目落库。
    ///
    /// 队列（`PlaybackQueue`）只存 `Track.ID`，抽屉与"接下来"列表都靠
    /// `TrackRepository` 把 ID 还原成曲目。**没有这一步，那些映射全是空的**：
    /// 队列会显示一整列「未知曲目」，收藏也只点亮星标、永远出现在不了收藏列表。
    /// 曲目元信息还会被 `metadataRefreshed` 补全成正式歌名，所以不能用 ID 做去重键，
    /// 否则补全后的标题不会写回库；这里按 identity 去重、每次播放写一次。
    private func persistTrackIfNeeded(_ track: Track) {
        guard persistedTrackIdentity != track.identity else { return }
        persistedTrackIdentity = track.identity
        let repository = trackRepository
        Task { [weak self] in
            try? await repository.save(track)
            guard let self else { return }
            self.reloadTrackTitles()
        }
    }

    // MARK: - 播放投影

    /// 播放恢复正常时清掉错误提示：错误条不该一直挂着。
    private func clearErrorIfRecovered(_ state: PlaybackState) {
        switch state {
        case .playing, .ready, .preparing:
            model.error = nil
        default:
            break
        }
    }

    /// 设置里的"自动变形"与"自动避让"开关要真的进状态机，而不是只存进 UserDefaults。
    private func syncAutoMorphSetting() {
        spatial.autoAvoidEnabled = appearance.autoAvoidEnabled
        let enabled = appearance.autoMorphEnabled
        guard machine.state.isAutoMorphEnabled != enabled else { return }
        _ = machine.handle(.autoMorphChanged(enabled), now: clock.now)
    }

    private func observePlayback() {
        stateTask = Task { [weak self] in
            guard let self else { return }
            // 元信息补全回来：把模型上的曲目换掉，界面标题/封面立即跟上。
            // 只有具体引擎才有这个回调——协议层不需要知道"补全"这件事。
            (self.playback as? PlaybackEngine)?.metadataRefreshed = { [weak self] track in
                guard let self, self.model.track?.id == track.id else { return }
                // BV 占位曲在 applyPlayback 时拿的是占位标题去搜歌词，大概率 .empty；
                // 后台 resolve 出正式歌名后这里只更新 model——loadedLyricsIdentity 没变、
                // 引擎也不重载，这首歌直到换歌都没有歌词。标题变了且引擎空手而归时重试。
                let titleChanged = self.model.track?.title != track.title
                self.model.track = track
                // 补全后的正式歌名要**写回库**。之前"这首已经存过"就不再存，
                // 库里留下的永远是补全之前的占位标题。
                self.persistedTrackIdentity = nil
                self.persistTrackIfNeeded(track)
                if titleChanged, self.lyricEngine.state == .empty {
                    self.loadedLyricsIdentity = nil
                    self.loadLyricsIfNeeded(for: track)
                }
                self.refreshArtwork(for: track)
                self.refreshRootView()
            }
            for await state in self.playback.stateUpdates() {
                self.applyPlayback(state)
            }
        }
        refreshQueue()
    }

    private func applyPlayback(_ state: PlaybackState) {
        if ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil {
            FileHandle.standardError.write(Data("STATE \(state.debugLabel)\n".utf8))
        }
        model.state = state
        model.error = state.error
        clearErrorIfRecovered(state)
        model.track = playback.currentTrack
        model.isPlayingVoiceAI = playback.isPlayingVoiceAI
        model.duration = playback.duration
        model.isMasked = privacy.isMasking
        model.volume = playback.volume
        model.isMuted = playback.isMuted
        // 队列也跟着状态流走：引擎里每一次队列改动都会广播，
        // 界面不再需要各处手动"刷新一下队列"。
        if model.queue != playback.queueSnapshot {
            model.queue = playback.queueSnapshot
            reloadTrackTitles()
        }
        // 播放模式/随机是"队列属性"，但按钮在播放条上；不在这里同步的话，
        // 改完只有打开一次队列抽屉才会刷新（因为只有那里调 refreshQueue）。
        let queue = playback.queueSnapshot
        model.repeatMode = queue.repeatMode
        model.isShuffling = queue.isShuffling
        if let track = playback.currentTrack {
            loadLyricsIfNeeded(for: track)
            refreshArtwork(for: track)
            persistTrackIfNeeded(track)
        } else {
            // 回到空闲态：歌词引擎也要一起归位。
            // 只清 `model.lyric` 会让顶栏一直挂着上一次的「同步歌词」，
            // 而屏幕上根本没有歌——这是"回到浏览首页"之后最容易露馅的一处不一致。
            model.lyric = .empty
            model.lyricState = .idle
            model.artwork = nil
            model.ambient = nil
            loadedLyricsIdentity = nil
            Task { [lyricEngine] in await lyricEngine.load(track: nil) }
        }
        refreshLyricSnapshot()
        refreshRootView()
        // 开始播放后自动离开浏览页：用户在列表点了一首歌，主区域就该去正在播放视图，
        // 不能让用户还停留在原来的页面（甚至是错误页）找"正在播放"入口。
        // 只有 idle→playing（新曲目开始播放）这条转换才切；暂停/恢复/缓冲/seek 不打扰浏览。
        let wasInPlaybackFlow = previousStateWasInPlaybackFlow
        previousStateWasInPlaybackFlow = isInPlaybackFlow(state)
        if state.isPlaying, model.isBrowsing, !wasInPlaybackFlow {
            model.showPlayer()
        }
        apply(machine.handle(state.isPlaying ? .playbackStarted : .playbackStopped, now: clock.now))
        evaluateSpace(immediate: false, geometryOnly: true)
    }

    /// 上一帧是否处在播放流（playing/buffering/seeking/paused/ready）：
    /// idle→playing 的新播放里，preparing/ready 会先把标志翻成 true，
    /// 到 .playing 时 wasInPlaybackFlow 已为 true，不会再触发 showPlayer —— 这是错的。
    /// 真正该识别的是「从 .idle 出发的第一次 .playing」。
    private var previousStateWasInPlaybackFlow = false

    private func isInPlaybackFlow(_ state: PlaybackState) -> Bool {
        switch state {
        case .playing, .buffering, .seeking, .paused:
            return true
        case .idle, .preparing, .ready, .ended, .failed:
            return false
        }
    }

    private func startTicker() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval: Duration = self.playback.state.isPlaying ? .milliseconds(125) : .milliseconds(400)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.model.position = self.playback.currentPosition
                self.model.duration = self.playback.duration
                self.refreshLyricSnapshot()
                // 每次 tick 顺带看一眼"通知是不是断了"，需要时补算一次空间。
                // 频率由 compensatingCheck 自己限流（≥240ms），这里不额外加权。
                await self.compensatingCheck()
                self.updateBackgroundAppearance()
            }
        }
    }

    private func loadLyricsIfNeeded(for track: Track) {
        guard loadedLyricsIdentity != track.identity else { return }
        loadedLyricsIdentity = track.identity
        Task { [weak self] in
            await self?.lyricEngine.load(track: track)
            self?.refreshLyricSnapshot()
        }
    }

    private func refreshLyricSnapshot() {
        model.showLyricTranslation = appearance.showLyricTranslation
        model.lyricState = lyricEngine.state
        model.lyricOffset = lyricEngine.userOffset
        guard playback.currentTrack != nil else {
            model.lyricState = .idle
            model.lyric = .empty
            return
        }
        // 认 `isMasking` 而不是 `isEnabled`：会议应用在前台时也要遮。
        // 之前只认手动开关——"会议时隐藏歌名与歌词"打开之后，悬浮歌词照常显示。
        if privacy.isMasking {
            model.lyric = .empty
            return
        }
        model.lyric = lyricEngine.snapshot(at: playback.currentPosition)
    }

    /// 隐私遮罩变了（手动开关，或会议应用进出前台）：立刻反映到所有形态上。
    func privacyDidChange() {
        model.isMasked = privacy.isMasking
        refreshLyricSnapshot()
        updateAccessibilityExposure()
    }

    /// 封面解析顺序：曲目自带的引用（内嵌/本地/opaque）→ 按曲目身份缓存的远程封面。
    ///
    /// 远程封面是异步下载的，第一次播放时两张都拿不到；`SystemMediaIntegration`
    /// 下完之后会写进 `ArtworkStore` 并发出通知（见 `observeArtworkStore`），
    /// 那时再刷一遍，用户不会一直看到灰音符。
    private func refreshArtwork(for track: Track) {
        let image = ArtworkStore.shared.image(for: track.artwork)
            ?? ArtworkStore.shared.image(forIdentity: track.identity)
        guard let image else {
            if model.artwork != nil {
                model.artwork = nil
                model.ambient = ArtworkPalette.ambient(from: nil)
            }
            return
        }
        if model.artwork !== image {
            model.artwork = image
            model.ambient = ArtworkPalette.ambient(from: image)
        }
    }

    /// 封面落盘后回调：只有当前曲目自己那张才需要重刷。
    private func observeArtworkStore() {
        artworkObserver = NotificationCenter.default.addObserver(
            forName: ArtworkStore.didStoreNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let identity = notification.userInfo?[ArtworkStore.identityKey] as? TrackIdentity else { return }
            // C 回调可能来自任意线程；统一跳回主线程，绝不在回调里假设执行器。
            Task { @MainActor [weak self] in
                guard let self, let track = self.playback.currentTrack,
                      track.identity == identity else { return }
                self.refreshArtwork(for: track)
                self.refreshRootView()
            }
        }
    }

    // MARK: - 空间评估

    /// 固定截止时间合并通知；只有状态或用户意图变化才推进版本，纯外部窗口几何事件仅请求补算，
    /// 防止连续拖窗时高频事件把正在后台求出的当前帧避让结果不断作废（饥饿）。
    private func evaluateSpace(immediate: Bool, geometryOnly: Bool = false) {
        guard isStarted else { return }
        // 沉浸播放是用户选定的全屏体验：不做避让评估（也省下每个节拍的窗口扫描）。
        guard !model.isImmersive else { return }
        if !geometryOnly {
            spatialSeq &+= 1
        } else if evaluationInFlight {
            evaluationRequested = true
        }
        scheduleEvaluation(after: immediate ? .zero : .milliseconds(80))
    }

    private func scheduleEvaluation(after delay: Duration) {
        guard evaluationSchedule.request(now: clock.now, delay: delay) else { return }
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.evaluationSchedule.consume()
            self.evaluationTask = nil
            await self.performEvaluation()
        }
    }

    /// 通知缺失时只扫描窗口几何；桌面未变且当前安全时不重复求解。
    /// 当应用失焦、或本应用处于前台但窗口正处在非完整形态（悬浮/贴边/隐匿）时均参与巡检：
    /// 刚打开为悬浮态或刚手动切为悬浮但尚未离开本应用时，同样需要及时避让桌面上的其他窗口。
    private func compensatingCheck() async {
        let monitoringNeeded = !isAppActive || machine.state.current != .expanded
        guard isStarted, !model.isImmersive, monitoringNeeded, !positionLocked,
              !machine.state.isUserHidden, !machine.state.isSuspended,
              !panel.isHandlingPointer, !panel.inLiveResize,
              // 动画进行中不判定几何：此时 panel.frame 是中间值，用它算出的落点会被动画污染。
              !model.isAnimatingGeometry, !isRelocating, !model.isTransitioning else { return }
        let now = clock.now
        if let last = lastCompensationAt, now < last.advanced(by: .milliseconds(240)) { return }
        lastCompensationAt = now
        // 后台扫描：这条路径在每次 tick 上跑，正是最不能阻塞主线程的地方。
        let latest = await refreshedObstacles(for: panel.frame)
        guard isStarted, !model.isImmersive,
              !positionLocked, !machine.state.isUserHidden, !machine.state.isSuspended,
              !panel.isHandlingPointer, !panel.inLiveResize,
              !model.isAnimatingGeometry, !isRelocating, !model.isTransitioning else { return }
        let activeObstacles = (appearance.autoAvoidEnabled && spatial.autoAvoidEnabled) ? latest : []
        if activeObstacles != lastObstacles || lastEnvironment == nil {
            evaluateSpace(immediate: true, geometryOnly: true)
            return
        }
        // 障碍物列表本身没再变化，但若悬浮窗仍压在障碍物/安全区外（如刚切换/刚冷启动/刚结束拖拽动画），
        // 且尚未对当前 (frame, morphology, obstacles) 完成避让尝试，补触发一次避让评估。
        if machine.state.current.isFloating, machine.state.current != .dormant,
           appearance.autoAvoidEnabled, spatial.autoAvoidEnabled,
           let screen = screen(containing: panel.frame) {
            let frame = panel.frame
            let stillConflicted = !zoneContains(frame, in: screen.safeZone)
                || Coverage.fraction(of: frame, by: activeObstacles) > 0.02
            if stillConflicted,
               !hasAttemptedAvoidance(frame: frame, morphology: machine.state.current, obstacles: activeObstacles) {
                evaluateSpace(immediate: true, geometryOnly: true)
            }
        }
    }

    private func performEvaluation() async {
        guard !evaluationInFlight else { evaluationRequested = true; return }
        if panel.isHandlingPointer || panel.inLiveResize {
            scheduleEvaluation(after: .milliseconds(120))
            return
        }
        guard !panel.styleMask.contains(.fullScreen),
              !positionLocked, !machine.state.isUserHidden, !machine.state.isSuspended,
              let screen = screen(containing: panel.frame) else { return }
        if model.isTransitioning || isRelocating || model.isAnimatingGeometry {
            // 过渡或几何动画期间不可直接读中间 frame，记下挂起并在动画结束立即补测，避免首拍丢失。
            deferredEvaluationPending = true
            return
        }
        deferredEvaluationPending = false
        evaluationInFlight = true
        defer {
            evaluationInFlight = false
            if evaluationRequested {
                evaluationRequested = false
                scheduleEvaluation(after: .zero)
            }
        }
        syncAutoMorphSetting()
        let started = clock.now
        let version = spatialSeq
        let environment = MorphologyEnvironment(
            safeZone: screen.safeZone, obstacles: await refreshedObstacles(for: panel.frame),
            currentFrame: panel.frame, current: machine.state.current)
        lastEnvironment = environment
        lastObstacles = environment.obstacles
        let holdUntil = userMorphUntil
        let holding = holdUntil.map { clock.now < $0 } ?? false
        let permitsMorphing = !holding && !machine.state.isLocked && machine.state.isAutoMorphEnabled
        let policy = AutoExpandPolicy(rawValue: appearance.autoExpandPolicyRaw) ?? .balanced
        let planner = AdaptivePlacementPlanner(solver: ContinuousPlacementSolver(edgeInset: resolver.edgeInset))
        let result = await Task.detached(priority: .userInitiated) {
            planner.evaluate(environment, permitsMorphing: permitsMorphing,
                             promotionImprovement: policy.promotionImprovement, version: version)
        }.value
        guard version == spatialSeq, machine.state.current == environment.current,
              panel.frame == environment.currentFrame, !model.isTransitioning, !isRelocating,
              !model.isAnimatingGeometry, !panel.isHandlingPointer, !panel.inLiveResize,
              !positionLocked, !machine.state.isUserHidden, !machine.state.isSuspended else {
            evaluationRequested = true
            return
        }
        let evaluation = result.evaluation
        let solution = result.solution
        pendingPlacement = solution.best
        pendingPlacementVersion = version
        lastRelocationTarget = solution.best?.frame
        model.recommendedMorphology = evaluation.recommendation.morphology
        model.lastMorphologyNote = evaluation.note
        model.floatingOverlapsWindow = Coverage.fraction(of: panel.frame, by: environment.obstacles) > 0
        spatialInspector.update { debug in
            debug.sequence = version
            debug.frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "—"
            debug.isFrontmost = self.isReallyFrontmost
            debug.permission = "\(self.accessibility.permission)"
            debug.safeZone = screen.safeZone
            debug.frontWindows = environment.obstacles
            debug.playerFrame = self.panel.frame
            debug.currentMorphology = environment.current.rawValue
            debug.recommendedMorphology = evaluation.recommendation.morphology.rawValue
            debug.targetFrame = solution.best?.frame ?? self.panel.frame
            debug.note = evaluation.note
            debug.isLocked = self.machine.state.isLocked || self.positionLocked
            debug.isCooldown = self.machine.state.phase != .settled
            debug.overlap = Coverage.fraction(of: self.panel.frame, by: environment.obstacles)
            debug.candidates = solution.freeRects
        }
        if spatialOverlay.isEnabled {
            var overlay = SpatialDebugOverlay.Snapshot()
            overlay.obstacles = environment.obstacles
            overlay.freeRects = solution.freeRects
            overlay.alternatives = solution.alternatives.map(\.frame)
            overlay.current = panel.frame
            overlay.target = solution.best?.frame ?? panel.frame
            overlay.reason = evaluation.note
            overlay.score = solution.best?.score ?? 0
            spatialOverlay.update(overlay, in: screen.frame)
        }
        logLayoutDecision(obstacles: environment.obstacles, free: solution.freeRects, evaluation: evaluation)
        apply(machine.handle(.environmentEvaluated(autoEvaluated(evaluation.recommendation)),
                             now: clock.now))
        if let deadline = machine.nextAutomaticEvaluation(after: clock.now) {
            scheduleEvaluation(after: clock.now.duration(to: deadline))
        }
        if holding, let holdUntil {
            scheduleEvaluation(after: clock.now.duration(to: holdUntil))
        }
        // 受遮挡/越界的同形态紧急让位不受 `!holding`、`opportunityGate` 500ms 延迟与跨形态推荐的限制；
        // 只要本次未切换到别的形态、当前不是完整窗口或隐匿状态，就应立刻找同形态无遮挡（或遮挡显著更少）空位避让。
        if machine.state.current == environment.current, !model.isTransitioning,
           environment.current != .expanded, environment.current != .dormant {
            let frame = panel.frame
            let overlap = Coverage.fraction(of: frame, by: environment.obstacles)
            let displaced = !zoneContains(frame, in: screen.safeZone) || overlap > 0.02
            let targetFrame = resolveSameMorphologyTarget(
                for: environment,
                solution: solution,
                displaced: displaced,
                overlap: overlap,
                safeZone: screen.safeZone,
                version: version
            )
            if displaced {
                _ = opportunityGate.observe(nil, now: clock.now)
                if let targetFrame {
                    let sizeChanged = abs(frame.width - targetFrame.width) > 2 || abs(frame.height - targetFrame.height) > 2
                    let distance = hypot(targetFrame.minX - frame.minX, targetFrame.minY - frame.minY)
                    debugTrace("GATE displaced=true distance=\(Int(distance)) sizeChanged=\(sizeChanged) target=\(targetFrame)")
                    if targetFrame != frame, distance > 2 || sizeChanged {
                        moveWithContinuity(to: targetFrame, note: "随空间变化让位", dodging: true)
                    } else {
                        recordAvoidanceAttempt(frame: frame, morphology: environment.current, obstacles: environment.obstacles)
                    }
                } else {
                    recordAvoidanceAttempt(frame: frame, morphology: environment.current, obstacles: environment.obstacles)
                }
            } else if !holding, machine.state.phase == .settled,
                      let bestFrame = targetFrame, result.improvesUseOfSpace {
                let deadline = opportunityGate.observe(bestFrame, now: clock.now)
                let opportunityReady = deadline.map { clock.now >= $0 } ?? false
                if let deadline, deadline > clock.now {
                    scheduleEvaluation(after: clock.now.duration(to: deadline))
                }
                let sizeChanged = abs(frame.width - bestFrame.width) > 2 || abs(frame.height - bestFrame.height) > 2
                let distance = hypot(bestFrame.minX - frame.minX, bestFrame.minY - frame.minY)
                debugTrace("GATE improves=\(result.improvesUseOfSpace) displaced=false "
                           + "ready=\(opportunityReady) deadlineIn=\(deadline.map { Int(seconds(clock.now.duration(to: $0)) * 1000) } ?? -1)ms "
                           + "distance=\(Int(distance)) sizeChanged=\(sizeChanged) target=\(bestFrame)")
                if bestFrame != frame, opportunityReady, distance > 2 || sizeChanged {
                    _ = opportunityGate.observe(nil, now: clock.now)
                    moveWithContinuity(to: bestFrame, note: "利用空白舒展内容", dodging: false)
                } else {
                    recordAvoidanceAttempt(frame: frame, morphology: environment.current, obstacles: environment.obstacles)
                }
            } else {
                _ = opportunityGate.observe(nil, now: clock.now)
                recordAvoidanceAttempt(frame: frame, morphology: environment.current, obstacles: environment.obstacles)
            }
        } else {
            _ = opportunityGate.observe(nil, now: clock.now)
        }
        if ProcessInfo.processInfo.environment["SLP_DEBUG_TIMING"] != nil {
            let ms = seconds(started.duration(to: clock.now)) * 1000
            debugTrace(String(format: "TIMING eval=%.2fms obstacles=%d", ms, environment.obstacles.count))
        }
    }

    private func resolveSameMorphologyTarget(for environment: MorphologyEnvironment,
                                             solution: PlacementSolution,
                                             displaced: Bool,
                                             overlap: Double,
                                             safeZone: CGRect,
                                             version: UInt64) -> CGRect? {
        guard displaced else {
            guard let best = solution.best, best.morphology == environment.current else { return nil }
            return best.frame
        }
        var candidateFrame: CGRect?
        if let best = solution.best, best.morphology == environment.current {
            candidateFrame = best.frame
        } else if let clearAlt = solution.alternatives.first(where: { alt in
            alt.morphology == environment.current
                && !environment.obstacles.contains(where: { $0.intersects(alt.frame) })
        }) {
            candidateFrame = clearAlt.frame
        } else {
            let solved = ContinuousPlacementSolver(edgeInset: resolver.edgeInset).solve(
                zone: environment.safeZone,
                obstacles: environment.obstacles,
                currentFrame: environment.currentFrame,
                current: environment.current,
                preferredOrigin: nil,
                allowed: [environment.current],
                snapshotVersion: version,
                freeRects: solution.freeRects
            )
            candidateFrame = solved.best?.frame
                ?? solution.alternatives.first(where: { $0.morphology == environment.current })?.frame
        }
        guard let candidate = candidateFrame, let currentFrame = environment.currentFrame else { return nil }
        let candidateInZone = zoneContains(candidate, in: safeZone)
        let candidateOverlap = Coverage.fraction(of: candidate, by: environment.obstacles)
        let wasOutOfZone = !zoneContains(currentFrame, in: safeZone)
        if candidateInZone && candidateOverlap == 0 {
            return candidate
        }
        if candidateInZone && (wasOutOfZone || candidateOverlap + 0.05 < overlap) {
            return candidate
        }
        return nil
    }

    private func resetAvoidanceAttempt() {
        lastAvoidanceRecorded = false
        lastAvoidanceFrame = .zero
        lastAvoidanceObstacles = []
    }

    private func hasAttemptedAvoidance(frame: CGRect,
                                       morphology: PlayerMorphology,
                                       obstacles: [CGRect]) -> Bool {
        guard lastAvoidanceRecorded else { return false }
        return lastAvoidanceFrame == frame
            && lastAvoidanceMorphology == morphology
            && lastAvoidanceObstacles == obstacles
    }

    private func recordAvoidanceAttempt(frame: CGRect,
                                        morphology: PlayerMorphology,
                                        obstacles: [CGRect]) {
        lastAvoidanceRecorded = true
        lastAvoidanceFrame = frame
        lastAvoidanceMorphology = morphology
        lastAvoidanceObstacles = obstacles
    }

    /// 新的用户意图使旧重定位收尾失效，避免过期回调把窗口拉回旧落点。
    private func cancelRelocation() {
        relocationGeneration &+= 1
        relocationTask?.cancel()
        relocationTask = nil
        isRelocating = false
    }

    /// 同形态迁移：**始终连续滑动**。
    ///
    /// 旧实现在远距离时做"淡出 → 瞬间换位置 → 淡入"（80ms + 瞬移 + 120ms）。
    /// 实测追踪里那一步只采到 1 帧——用户看到的是卡片凭空跳走，
    /// 这正是反馈里"卡片移动躲避时有点卡"的来源。窗口是同一个，
    /// 连续插值才是对"同一件东西在动"的正确表达；时长按距离缩放，
    /// 远距离也不会慢成拖影。
    /// 同形态迁移。`dodging` 区分"被挤走的让位"与"主动舒展"：
    /// 让位是被动动作，用过阻尼（绝不越过）；舒展是主动动作，用轻阻尼。
    private func moveWithContinuity(to frame: CGRect, note: String, dodging: Bool) {
        debugTrace("RELOCATE from=\(panel.frame) to=\(frame) note=\(note)")
        cancelRelocation()
        resetAvoidanceAttempt()
        let generation = relocationGeneration
        isRelocating = true
        model.lastMorphologyNote = note
        relocationTask = nil
        // 躲避让位用 E（绝不越过），其余移动用 B（1% 轻回弹）。
        let recipe = dodging ? MotionCatalog.dodge : MotionCatalog.move
        animateFrame(frame, recipe: recipe) { [weak self] in
            guard let self, self.relocationGeneration == generation else { return }
            self.isRelocating = false
            self.relocationTask = nil
            self.persistPlacement()
            self.updateBackgroundAppearance(force: true)
            self.resetAvoidanceAttempt()
            self.deferredEvaluationPending = false
            self.evaluateSpace(immediate: true)
        }
    }

    /// 一个矩形被障碍物覆盖的面积比例（0…1）。重叠障碍物按并集算，见 `Coverage`。

    // MARK: - 环境事件

    /// 移除所有通知观察者。
    ///
    /// 控制器是"随 App 存活"的对象，生产里几乎不会走到这里；
    /// 但**测试会反复创建**它，没有清理就会留下成批的僵尸观察者
    /// （每个都持有 `[weak self]`，不崩但会累积）。退出时也应显式清理。
    /// 退出前清理。协议入口，供 AppDelegate 调用而不认识具体类型。
    func shutdown() { invalidateObservers() }

    func invalidateObservers() {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        if let artworkObserver {
            center.removeObserver(artworkObserver)
            self.artworkObserver = nil
        }
        // 刷新循环与动画驱动一并停止：否则退出/测试结束后还会继续执行回调。
        watchdogGeneration &+= 1
        frameAnimator.cancel()
        tickerTask?.cancel()
        tickerTask = nil
    }

    /// 测试用：还有多少个观察者没清。
    var observerCountForTesting: Int { observers.count + (artworkObserver == nil ? 0 : 1) }

    /// 测试用：刷新循环是否还在跑。
    var tickerIsRunningForTesting: Bool { tickerTask != nil }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenChange() }
        })
        // 只把 NSApplication 的激活通知当作**触发器**，不用它判定状态。
        //
        // 之前直接在 didBecomeActive 里记 `.appActivated`：面板 orderFront 也会触发它，
        // 而那时真正的前台应用是别人 —— 刚记下的 deactivatedAt 被冲成 nil，
        // 自动收缩永远被拒（实测：状态机一直报 appStillActive）。
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFrontmostState() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFrontmostState() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFrontmostState() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFrontmostState() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(self.machine.handle(.sleep, now: self.clock.now))
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(self.machine.handle(.wake, now: self.clock.now))
                self.evaluateSpace(immediate: true)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.backgroundPolicy.reset()
                self?.updateBackgroundAppearance(force: true)
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWindowMoved() }
        })

        axObserver.onGeometryChanged = { [weak self] in
            self?.evaluateSpace(immediate: false, geometryOnly: true)
        }
    }

    /// 唯一可信的"我在前台吗"判断：拿 NSWorkspace 的前台应用和自己比。
    private var isReallyFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// 前台状态的唯一入口：**边沿触发**。
    ///
    /// 所有通知（NSApplication 的激活/失焦、NSWorkspace 的应用切换）都只调用它，
    /// 由它拿 `NSWorkspace.frontmostApplication` 自己判断"现在到底是不是我"，
    /// 并且在状态**真的变化**时才向状态机投事件。
    /// 这样一次面板 orderFront 引发的伪激活不会重复投递 `.appActivated`。
    private func syncFrontmostState() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isSelf = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let wasActive = isAppActive
        debugTrace("FRONT frontmost=\(frontmost?.bundleIdentifier ?? "-") isSelf=\(isSelf) "
                   + "was=\(wasActive) ax=\(accessibility.permission)")

        let fullscreen = !isSelf && spatial.detectFullscreen()
        apply(machine.handle(.fullscreenChanged(fullscreen), now: clock.now))

        guard isSelf != wasActive else {
            // 前台没变（只是别的应用之间互切）：仍然要重算空间，
            // 因为障碍物换了一批。仅外部窗口环境变动，不打断正在飞的同状态评估。
            if !isSelf { startAccessibilityTracking() }
            evaluateSpace(immediate: false, geometryOnly: true)
            return
        }

        if isSelf {
            debugTrace("FRONT -> appActivated")
            isAppActive = true
            apply(machine.handle(.appActivated, now: clock.now))
            // 用户主动把 FLOW 切回前台就是要用完整播放器；刚显式指定过形态时不反悔。
            if machine.state.current.isFloating, !isAutoExpandSuppressed { expand() }
            evaluateSpace(immediate: true)
        } else {
            debugTrace("FRONT -> appDeactivated")
            isAppActive = false
            // 用户明确关掉"失焦收缩"时，失去焦点只更新前台标记，不驱动状态机降级。
            // 否则一边听歌一边在别处工作的人，切走就再也看不到完整版面——
            // 而且当时这个行为没有任何设置入口。
            // 沉浸播放是用户主动选的全屏体验，切到别的应用看一眼不该把它收掉。
            if appearance.autoCollapseOnDeactivate, !model.isImmersive {
                apply(machine.handle(.appDeactivated, now: clock.now))
                debugTrace("FRONT deact record=\(machine.state.deactivatedAt != nil)")
            } else {
                debugTrace("FRONT deact suppressed (autoCollapseOnDeactivate=false)")
            }
            startAccessibilityTracking()
            evaluateSpace(immediate: false)
        }
    }

    private func handleScreenChange() {
        let screens = ScreenGeometryResolver.current()
        guard let screen = screens.first(where: { $0.id == currentDisplayID }) ?? screens.first else { return }
        currentDisplayID = screen.id
        let landing = Self.frameAfterScreenChange(panel.frame, safeZone: screen.safeZone,
                                                  isFullScreen: panel.styleMask.contains(.fullScreen))
        if landing != panel.frame { panel.setFrame(landing, display: true) }
        persistPlacement()
        evaluateSpace(immediate: true)
    }

    /// 屏幕参数变化后窗口该落在哪。
    ///
    /// 全屏窗口由系统摆放，不能钳：进全屏时系统会发一次屏幕参数变化，安全区还按带菜单栏的桌面算，
    /// 钳完 1920×1080 的沉浸页变成四周各留 4pt 的 1912×1042（真实歌曲实机复核时发现，偶发）。
    static func frameAfterScreenChange(_ frame: CGRect, safeZone: CGRect, isFullScreen: Bool) -> CGRect {
        isFullScreen ? frame : frame.clamped(into: safeZone)
    }

    private func handleWindowMoved() {
        guard isStarted, !model.isTransitioning, !isRelocating, !model.isAnimatingGeometry else { return }
        updateBackgroundAppearance()
        let now = clock.now
        if let last = lastDragPersistAt, now < last.advanced(by: .milliseconds(220)) { return }
        lastDragPersistAt = now
        movePersistTask?.cancel()
        movePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            self.currentDisplayID = self.screen(containing: self.panel.frame)?.id ?? self.currentDisplayID
            self.persistPlacement()
            self.persistPreferences()
            self.resetAvoidanceAttempt()
            self.evaluateSpace(immediate: false, geometryOnly: true)
        }
    }

    private func startAccessibilityTracking() {
        guard accessibility.refresh() == .granted else {
            axObserver.stop()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            axObserver.stop()
            return
        }
        axObserver.start(pid: app.processIdentifier)
    }

    // MARK: - 几何工具

    /// 当前窗口所在屏幕的刷新率；拿不到就返回 0（由 MotionTiming 兜底）。
    private var currentRefreshRate: Double {
        MotionTiming.refreshRate(for: panel.screen ?? NSScreen.main)
    }

    private func safeZone(for rect: NSRect) -> CGRect {
        screen(containing: rect)?.safeZone ?? ScreenGeometryResolver.mainScreenGeometry().safeZone
    }

    private func screen(containing rect: NSRect) -> ScreenGeometry? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let screens = ScreenGeometryResolver.current()
        return screens.first { $0.frame.contains(center) }
            ?? screens.first { $0.frame.intersects(rect) }
            ?? screens.first
    }

    /// 障碍物 = **屏幕上所有可见的普通窗口**（不含自己）。
    ///
    /// 早期只取"前台应用的窗口"，理由是规格 §四.3 说"不得把所有后台窗口当作障碍物"。
    /// 但实际使用里，用户常常在两三个窗口之间的缝隙里放歌词——只看前台应用就会
    /// 把别的窗口当成不存在，于是歌词停在人家窗口上面（用户截图反馈的场景）。
    ///
    /// 改为扫描全部可见窗口：只取 layer == 0 的普通窗口，排除自己、排除最小化，
    /// 不需要额外权限（几何信息不需要屏幕录制权限）。
    /// 组装一次扫描请求。主屏高度用于把 CG 左上坐标换成 AppKit 左下坐标，
    /// 必须在这里（主 actor）取，扫描本身在后台跑。
    /// 主线程非阻塞预热首份桌面障碍物快照，让冷启动与异步偏好恢复并行完成扫描。
    private func warmUpObstacles() {
        guard let request = obstacleRequest(for: panel.frame) else { return }
        obstacleProvider.requestRefresh(request)
    }

    private func obstacleRequest(for rect: NSRect) -> ObstacleScanRequest? {
        guard appearance.autoAvoidEnabled, spatial.autoAvoidEnabled else { return nil }
        let screen = screen(containing: rect) ?? ScreenGeometryResolver.mainScreenGeometry()
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return ObstacleScanRequest(excludingPID: ProcessInfo.processInfo.processIdentifier,
                                   screenFrame: screen.frame, primaryMaxY: primaryMaxY)
    }

    /// 主线程只读：返回缓存快照，顺手排一次后台刷新，**不等待**。
    /// 走这条路径的调用点（例如开始过渡时的兜底校验）不会拖慢动画。
    private func cachedObstacles(for rect: NSRect, ignoringSelf: Bool) -> [CGRect] {
        guard let request = obstacleRequest(for: rect) else {
            debugTrace("OBSTACLE skipped: autoAvoid off")
            return []
        }
        obstacleProvider.requestRefresh(request)
        return obstacleProvider.snapshot(in: request.screenFrame)
    }

    /// 后台扫描并等待。只有真正要做空间决策的地方才用，动画路径不用。
    private func refreshedObstacles(for rect: NSRect) async -> [CGRect] {
        guard let request = obstacleRequest(for: rect) else { return [] }
        return await obstacleProvider.refresh(request)
    }

    // MARK: - 缩放与关闭

    /// 右下角手柄缩放（屏幕坐标增量，y 向上）。
    /// 左上角固定：右下角跟手，符合"从右下角往里拖"的直觉。
    private func resize(by delta: CGSize) {
        guard machine.state.current == .expanded else { return }
        let geometry = PlayerMorphology.expanded.geometry
        let zone = safeZone(for: panel.frame)
        let top = panel.frame.maxY
        var frame = panel.frame
        frame.size.width = min(max(frame.width + delta.width, geometry.minimumSize.width), zone.width)
        // 手柄在右下角、顶边固定：往上拖（AppKit dy > 0）意味着"底边跟上"，高度要减。
        frame.size.height = min(max(frame.height - delta.height, geometry.minimumSize.height), zone.height)
        frame.origin.y = top - frame.size.height
        guard frame != panel.frame else { return }
        panel.setFrame(frame.integral, display: true)
        persistPlacement()
    }

    /// 关闭按钮的语义：把播放器收进菜单栏，而不是退出应用。
    private func collapseToDock() {
        if appearance.autoCollapseOnDeactivate {
            apply(machine.handle(.userCollapsed(to: .capsule), now: clock.now))
        } else {
            hide()
        }
    }

    private func togglePlayback() {
        // 语义集中在 PlaybackControlling.togglePlayback()：失败态=重试、
        // 空当前曲目=从队首开始。这里不再各写一份（曾导致 .failed 时按键失灵）。
        Task { await playback.togglePlayback() }
    }

    private func skipNext() {
        Task { await playback.skip(.next) }
    }

    private func skipPrevious() {
        Task { await playback.skip(.previous) }
    }

    /// 页面导航不改变播放会话，首页仍能暂停、切歌和返回歌词。
    func browseToHome() {
        model.showHome()
        noteAuxiliaryActivity(false)
    }

    /// 空格 = 播放/暂停。
    ///
    /// 用 `MorphPanel.keyDown` 而不是 SwiftUI 的 `.onKeyPress`：后者靠焦点链，
    /// 点版面上的空白处不会把焦点交给根视图，按键就被系统吞掉——
    /// 设置页里写着的「空格：播放/暂停」因此一直是坏的（实测）。
    /// 面板本身在键盘事件链上，`keyDown` 一定被调用；它也是 MainActor 隔离的，
    /// 不需要任何 `assumeIsolated`（那条路径在 macOS 27 会直接崩）。
    private func installSpaceKeyHandler() {
        panel.onSpaceKey = { [weak self] in
            guard let self else { return false }
            guard self.machine.state.current == .expanded else { return false }
            // 正在文本框里打字时不抢。
            if let responder = self.panel.firstResponder,
               responder is NSText || responder is NSTextView { return false }
            self.togglePlayback()
            return true
        }
        // ←→ 方向键：完整形态下 ±10s 快进快退（Apple Music 同款）。
        // 校准抽屉开着时这两个键被 `KeyboardOffsetMonitor` 吃掉（返回 nil），
        // 这条回调根本不会触发——所以这里不用判 isCalibrating。
        panel.onArrowKey = { [weak self] delta in
            guard let self else { return false }
            guard self.machine.state.current == .expanded else { return false }
            if let responder = self.panel.firstResponder,
               responder is NSText || responder is NSTextView { return false }
            guard self.model.track != nil, self.model.duration > 0 else { return false }
            let target = max(0, min(self.model.duration, self.model.position + delta))
            Task { await self.playback.seek(to: target) }
            return true
        }
    }

    // MARK: - 持久化

    private func persistPlacement() {
        // 全屏时的 frame 是整块屏幕：记下来的话，下次启动窗口会是一整屏大的普通窗口。
        guard !panel.styleMask.contains(.fullScreen) else { return }
        guard let displayID = screen(containing: panel.frame)?.id ?? currentDisplayID else { return }
        currentDisplayID = displayID
        let snapshot = PlacementSnapshot(
            displayID: displayID,
            originX: panel.frame.origin.x,
            originY: panel.frame.origin.y,
            width: panel.frame.width,
            height: panel.frame.height,
            shape: storedShape,
            isLocked: positionLocked,
            isClickThrough: clickThroughPreferred,
            opacity: Double(panel.alphaValue),
            showsBackground: machine.state.current != .edge,
            preferredX: Double(panel.frame.origin.x),
            preferredY: Double(panel.frame.origin.y)
        )
        let store = placements
        Task { await store.save(snapshot) }
    }

    private func persistPreferences() {
        var snapshot = preferences.load()
        if let displayID = currentDisplayID {
            snapshot.morphologyByDisplay[displayID] = machine.state.current.rawValue
            snapshot.edgeByDisplay[displayID] = currentEdge.rawValue
        }
        snapshot.isMorphologyLocked = machine.state.isLocked
        snapshot.isClickThrough = clickThroughPreferred
        snapshot.floatingShape = storedShape.rawValue
        snapshot.dormantStyle = dormantStyle.rawValue
        preferences.save(snapshot)
    }

    // MARK: - 快捷键

    /// 注册三个全局快捷键。组合来自 `HotkeyPreferences`，没存过就用内置默认。
    func registerHotkeys() {
        let center = HotkeyCenter.shared
        let preferences = hotkeys
        for action in HotkeyCenter.Action.allCases {
            let combo = preferences.combo(for: action)
            center.register(action,
                            keyCode: combo.keyCode,
                            carbonModifiers: combo.carbonModifiers) { [weak self] in
                switch action {
                case .toggleInteractive: self?.toggleInteractive()
                case .cycleShape: self?.cycleMorphology()
                case .toggleVisibility: self?.toggleVisibility()
                }
            }
        }
    }

    /// 设置页改完绑定后调用：先用新组合重注册，再把结果告诉界面。
    func reloadHotkeys() {
        registerHotkeys()
    }

    var hotkeyPreferences: HotkeyPreferences { hotkeys }

    // MARK: - 视图刷新

    /// 调试钩子（只读环境变量，不进任何业务判断）：
    /// `SLP_DEBUG_MORPH=expanded|compact|capsule|edge|dormant` 启动后切到指定形态。
    /// 走的是真实用户意图事件，不绕过状态机。
    private func applyDebugHooks() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SLP_DEBUG_DORMANT_HANDLE"] == "1" {
            setDormantStyle(.edgeHandle)
        }
        if let raw = environment["SLP_DEBUG_MORPH"],
           let morphology = PlayerMorphology(rawValue: raw),
           morphology != machine.state.current {
            setMorphology(morphology)
        }
    }

    private func refreshRootView() {
        guard let hosting else { return }
        let actions = MorphViewActions(
            expand: { [weak self] in self?.expand() },
            collapse: { [weak self] in self?.collapse() },
            close: { [weak self] in self?.collapseToDock() },
            togglePlay: { [weak self] in self?.togglePlayback() },
            next: { [weak self] in self?.skipNext() },
            previous: { [weak self] in self?.skipPrevious() },
            browse: { [weak self] in self?.browseToHome() },
            seek: { [weak self] seconds in
                guard let self else { return }
                Task { await self.playback.seek(to: seconds) }
            },
            resize: { [weak self] delta in self?.resize(by: delta) },
            toggleImmersive: { [weak self] in self?.toggleImmersive() },
            setMode: { [weak self] mode in self?.setPlayerMode(mode) }
        )
        hosting.rootView = MorphRootView(model: model,
                                         actions: actions,
                                         edge: currentEdge,
                                         floatingShape: storedShape,
                                         appContainer: appContainer)

    }

    // MARK: - 日志

    private func legalAgainstObstacles(_ frame: CGRect, obstacles: [CGRect], zone: CGRect) -> Bool {
        guard zoneContains(frame, in: zone) else { return false }
        return Coverage.fraction(of: frame, by: obstacles) == 0
    }

    private func zoneContains(_ rect: CGRect, in zone: CGRect) -> Bool {
        zone.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    }

    /// 结构化布局日志（规格 §十三要求的字段）。
    /// 把求解器的"几何建议"过一遍产品策略再交给状态机。
    ///
    /// 求解器在**哪儿都放不下**时会建议 `.dormant`（一个边缘把手）。这个建议只在
    /// `dormantStyle == .edgeHandle` 时成立 —— 那种样式下屏幕上还留着可点的一小块。
    /// 而默认的 `hideCompletely` 会直接 `orderOut`：音乐还在放，窗口没了，
    /// 而且这种隐藏的 `isUserHidden` 是 false，`⌃⌥H` 会被判 redundant 吞掉，
    /// 只能退出应用才能看见它。所以这种样式下把建议降级成最紧的可见形态。
    private func autoEvaluated(_ recommendation: MorphologyRecommendation) -> MorphologyRecommendation {
        // 用户显式选过形态、而且**桌面还没变**时，自动决策一律让路。
        //
        // 之前只有"不许放宽"这一条，收紧仍然放行：用户点开完整播放器，
        // 6 秒后空间评估判"桌面被占满"，又把他降级回胶囊 —— 手动展开等于没用。
        // 现在把选择那一刻的桌面拍成指纹，指纹没变就不动形态；
        // 真的多开/关掉了窗口（obstacles 变了）才重新交给自动决策。
        if let chosen = userChosenMorphology,
           machine.state.current == chosen,
           let signature = userChosenSignature,
           let environment = lastEnvironment,
           signature == EnvironmentSignature(safeZone: environment.safeZone,
                                             obstacles: environment.obstacles) {
            var held = recommendation
            held.morphology = chosen
            return held
        }

        // 用户选过的形态不许被自动决策**放宽**：他明确要贴边，就别替他换回胶囊。
        // 收紧（空间真的不够）仍然放行，否则窗口会压在别人的窗口上。
        if let chosen = userChosenMorphology,
           recommendation.morphology.tightness < chosen.tightness {
            var held = recommendation
            held.morphology = machine.state.current
            return held
        }
        guard recommendation.morphology == .dormant, dormantStyle == .hideCompletely else {
            return recommendation
        }
        var adjusted = recommendation
        adjusted.morphology = .edge
        return adjusted
    }

    private func logLayoutDecision(obstacles: [CGRect],
                                   free: [CGRect],
                                   evaluation: MorphologyEvaluation) {
        guard ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil else { return }
        let line = "LAYOUT obstacles=\(obstacles) free=\(free) current=\(panel.frame) "
            + "morph=\(evaluation.recommendation.morphology.rawValue) "
            + "target=\(lastRelocationTarget ?? panel.frame) "
            + "reason=\(evaluation.note)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// 调试踪迹：只在 `SLP_SPATIAL_DEBUG` 下输出，用来核对"这个动作到底有没有跑"。
    private func debugTrace(_ message: String) {
        guard ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func log(_ decision: MorphologyDecision) {
        guard ProcessInfo.processInfo.environment["SLP_SPATIAL_DEBUG"] != nil else { return }
        let reason = decision.reason?.rawValue ?? "-"
        let rejection = decision.rejection?.rawValue ?? "-"
        let zone = lastEnvironment.map { "\($0.safeZone)" } ?? "-"
        let obstacles = lastEnvironment.map { "\($0.obstacles)" } ?? "-"
        let line = "MORPH current=\(decision.state.current.rawValue) phase=\(decision.state.phase.rawValue) "
            + "recommend=\(decision.state.recommendation.morphology.rawValue) "
            + "reason=\(reason) rejected=\(rejection) deact=\(decision.state.deactivatedAt != nil) "
            + "interact=\(decision.state.lastUserInteraction != nil) played=\(decision.state.hasStartedPlayback) "
            + "note=\(model.lastMorphologyNote) "
            + "zone=\(zone) obstacles=\(obstacles)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func scaledDuration(_ duration: Duration, by speed: Double) -> Duration {
        guard speed > 0.001, speed != 1 else { return duration }
        return .seconds(seconds(duration) / speed)
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: - 测试辅助

    func setAppActiveForTesting(_ active: Bool) {
        isAppActive = active
    }

    func runCompensatingCheckForTesting() async {
        lastCompensationAt = nil
        await compensatingCheck()
    }

    func triggerGeometryChangeForTesting() {
        evaluateSpace(immediate: false, geometryOnly: true)
    }
}
