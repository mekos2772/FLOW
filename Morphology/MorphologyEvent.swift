import CoreGraphics
import Foundation

// MARK: - 事件

/// 形态系统接收的全部事件。
///
/// 事件名用的是"发生了什么事"，不是"把窗口设成什么样"：
/// 这样形态状态机可以独立于 AppKit 演进，并且能被穷举测试。
enum MorphologyEvent: Sendable, Equatable {
    /// 用户主动要完整播放器（点击胶囊、菜单栏「打开播放器」、Dock 激活）。
    case userOpened
    /// 用户明确指定某个形态（菜单/设置/快捷键循环）。
    case userRequested(PlayerMorphology)
    /// 用户收缩到某个悬浮形态。
    case userCollapsed(to: PlayerMorphology)
    /// 用户锁定/解除锁定形态。锁定后只有"显式隐藏"与"系统全屏"能改变形态。
    case userLockChanged(Bool)
    /// 用户显式隐藏 / 恢复。
    case userHiddenChanged(Bool)
    /// 本应用被激活（成为前台）。
    case appActivated
    /// 本应用失去前台。
    case appDeactivated
    case playbackStarted
    case playbackStopped
    /// 空间评估完成，带回空间上可行的形态建议。
    case environmentEvaluated(MorphologyRecommendation)
    /// 进入 / 退出全屏应用。
    case fullscreenChanged(Bool)
    case sleep
    case wake
    /// 一次变形动画正常结束。
    case transitionCompleted
    /// 一次变形动画被新的请求打断（此时内容已经切到新目标）。
    case transitionInterrupted
    /// 用户正在浏览队列/设置等次级内容。为 true 时禁止自动收缩。
    case auxiliaryActivityChanged(Bool)
    /// 设置里开关"自动变形"。关闭后只有用户操作能改形态。
    case autoMorphChanged(Bool)
    /// 时间推进。防抖与冷却都靠它，不额外起定时器轮询。
    case tick
}

/// 空间评估给出的形态建议。
struct MorphologyRecommendation: Sendable, Equatable {
    /// 空间上推荐的形态（只会在 compact / capsule / edge / dormant 之间）。
    var morphology: PlayerMorphology
    /// 推荐形态能否以"期望尺寸"放下；false 表示只够最小尺寸。
    var fitsPreferred: Bool
    /// 当前形态是否仍然放得下（用于滞回：能不动就不动）。
    var currentStillFits: Bool
    /// 评估时用到的最大可用矩形，仅用于日志与测试断言。
    var availableSize: CGSize

    static let unknown = MorphologyRecommendation(
        morphology: .capsule,
        fitsPreferred: false,
        currentStillFits: true,
        availableSize: .zero
    )
}

// MARK: - 状态

/// 形态状态机的完整状态。
///
/// `current` 表示"内容现在画的是哪个形态"。过渡一旦开始，内容立刻切到目标形态，
/// 窗口几何随后用动画追上去——这样不会出现"新内容等窗口"的空窗期。
struct MorphologyState: Sendable, Equatable {
    enum Phase: String, Sendable, Equatable {
        case settled
        case transitioning
    }

    /// 当前内容形态。
    var current: PlayerMorphology = .expanded
    /// 过渡起点形态；`settled` 时为 nil。
    var previous: PlayerMorphology?
    var phase: Phase = .settled
    /// 用户锁定形态。锁定期间自动决策全部失效。
    var isLocked = false
    /// 用户显式隐藏（口令是"我不想看到它"，比空间优化优先级高）。
    var isUserHidden = false
    /// 被系统原因挂起（全屏应用、睡眠）。恢复时回到先前形态。
    var suspendedBy: SuspensionReason?
    /// 挂起前的形态，用于恢复。
    var morphologyBeforeSuspension: PlayerMorphology?
    /// 最近一次用户主动操作的时刻，用于免打扰期。
    var lastUserInteraction: ContinuousClock.Instant?
    /// 本应用失去前台的时刻，用于自动收缩防抖。
    var deactivatedAt: ContinuousClock.Instant?
    /// 最近一次形态切换完成的时刻，用于冷却。
    var lastSettledAt: ContinuousClock.Instant?
    /// 最近一次空间建议。
    var recommendation: MorphologyRecommendation = .unknown
    var recommendationSince: ContinuousClock.Instant?
    /// 用户正在浏览队列/设置次级内容。规格 4.2 第 7 条：此时禁止自动收缩。
    var isBrowsingAuxiliary = false
    /// 是否允许按空间自动变形。默认允许。
    var isAutoMorphEnabled = true
    /// 本次会话是否真正开始过播放。
    /// 冷启动后用户还没碰过播放器时，不该因为别的应用在前台就把界面收掉。
    var hasStartedPlayback = false

    var isSuspended: Bool { suspendedBy != nil }

    enum SuspensionReason: String, Sendable, Equatable {
        case fullscreen
        case sleep
    }
}

// MARK: - 决策输出

/// 状态机对外的动作。窗口层只执行这些动作，不自己猜形态。
enum MorphologyAction: Sendable, Equatable {
    /// 执行一次变形：窗口层负责几何插值与内容交接。
    case transition(from: PlayerMorphology, to: PlayerMorphology)
    /// 完全隐藏窗口。
    case orderOut
    /// 显示窗口（隐匿恢复）。
    case orderFront(PlayerMorphology)
    /// 申请前台激活（只有进完整播放器时才有意义）。
    case activateApplication
    /// 解除前台激活归属（回到悬浮形态时让出焦点）。
    case resignKeyFocus
}

/// 一次事件处理后得到的结果。
struct MorphologyDecision: Sendable, Equatable {
    var state: MorphologyState
    var actions: [MorphologyAction]
    var reason: MorphologyChangeReason?
    /// 事件被拒绝时的原因，便于日志与测试断言"不该发生的事确实没发生"。
    var rejection: MorphologyRejection?
}

/// 形态为什么会变。全部进入日志，实测证据直接引用这里的字符串。
enum MorphologyChangeReason: String, Sendable, Equatable {
    case userOpened
    case userSpecified
    case userCollapsed
    case userLocked
    case userHidden
    case userRestored
    case appDeactivated
    case spaceTightened
    case spaceRestored
    case fullscreenEntered
    case fullscreenExited
    case sleep
    case wake
}

enum MorphologyRejection: String, Sendable, Equatable {
    /// 用户锁定期间收到自动决策。
    case locked
    /// 用户显式隐藏期间收到自动决策。
    case userHidden
    /// 系统挂起期间收到自动决策。
    case suspended
    /// 冷却期内。
    case coolingDown
    /// 免打扰期内（用户刚操作过）。
    case interactionGrace
    /// 前台仍稳定，不该收缩。
    case appStillActive
    /// 目标与当前一致。
    case redundant
    /// 空间建议与当前形态相同，无需动作。
    case noBetterOption
    /// 用户关掉了自动变形。
    case autoMorphDisabled
}
