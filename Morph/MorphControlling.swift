import Foundation

/// 表现层操作"播放器这件东西"的唯一入口。
///
/// 菜单栏、快捷设置、快捷键、深链都只调这个协议：
/// 拿不到 NSPanel，也拿不到形态状态机，因此没有办法在外部把形态改坏。
@MainActor
protocol MorphControlling: AnyObject {
    var morphology: PlayerMorphology { get }
    var isMorphologyLocked: Bool { get }
    var isInteractive: Bool { get }
    /// 用户是否开了「鼠标穿透」（只在悬浮形态生效；完整播放器始终可点）。
    var isClickThroughEnabled: Bool { get }
    var isPositionLocked: Bool { get }
    var recommendedMorphology: PlayerMorphology { get }
    var floatingShape: LyricsShape { get }
    var isVisible: Bool { get }

    /// 全局快捷键的持久化绑定。设置页读写它。
    var hotkeyPreferences: HotkeyPreferences { get }
    /// 改完绑定后重注册。
    func reloadHotkeys()

    func start()
    /// 退出前释放系统资源（通知观察者、定时器等）。
    func shutdown()
    func expand()
    func openCalibration()
    func collapse()
    func setMorphology(_ morphology: PlayerMorphology)
    func cycleMorphology()
    func toggleMorphologyLock()
    func toggleInteractive()
    func togglePositionLock()
    func setAutoAvoid(_ enabled: Bool)
    func applyLyricFontSize(_ value: Double)
    func applyLyricLineSpacing(_ value: Double)
    func applyShowLyricTranslation(_ enabled: Bool)
    func applyFloatingOpacity(_ value: Double)
    func applyFloatingAppearance(_ mode: FloatingAppearanceMode)
    func setFloatingShape(_ shape: LyricsShape)
    /// 队列/曲目列表变化后刷新界面投影。
    func refreshQueue()
    /// 用户在浏览队列/设置等次级内容时通知形态系统"别自动收缩"。
    func noteAuxiliaryActivity(_ isActive: Bool)
    /// 用户在设置里改了默认形态：清掉记忆并回到该形态。
    func resetPlacementMemory() async
    var dormantStyle: DormantStyle { get }
    func setDormantStyle(_ style: DormantStyle)
    /// 激活应用时是否应该自动展开成完整播放器。
    /// 刚被显式指定过形态时返回 false，避免"点了胶囊又被弹回完整形态"。
    var allowsActivationExpansion: Bool { get }
}
