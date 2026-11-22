import XCTest
@testable import SpatialLyricsPlayer

/// 形态状态机测试。
///
/// 这里断言的是规格 4.2 / 4.4 / 5.8 的硬规则：
/// 用户意图优先、锁定期间不动、动画可被打断、失焦后要稳定才收缩。
@MainActor
final class MorphologyStateMachineTests: XCTestCase {

    private let clock = ContinuousClock()
    private var now: ContinuousClock.Instant { clock.now }

    private func machine(current: PlayerMorphology = .expanded,
                         tuning: MorphologyTuning = .default) -> MorphologyStateMachine {
        var state = MorphologyState()
        state.current = current
        return MorphologyStateMachine(state: state, tuning: tuning)
    }

    // MARK: - 用户意图

    func testUserOpenedExpandsFromCapsule() {
        var machine = machine(current: .capsule)
        let decision = machine.handle(.userOpened, now: now)
        XCTAssertEqual(decision.state.current, .expanded)
        XCTAssertEqual(decision.state.phase, .transitioning)
        XCTAssertEqual(decision.reason, .userOpened)
        XCTAssertTrue(decision.actions.contains(.transition(from: .capsule, to: .expanded)))
        XCTAssertTrue(decision.actions.contains(.activateApplication), "展开完整播放器要申请前台激活")
    }

    func testUserOpenedClearsMorphologyLock() {
        // 锁定胶囊的用户点一下胶囊应当能展开，否则会陷入"点了没反应"。
        var machine = machine(current: .capsule)
        _ = machine.handle(.userLockChanged(true), now: now)
        let decision = machine.handle(.userOpened, now: now)
        XCTAssertFalse(decision.state.isLocked)
        XCTAssertEqual(decision.state.current, .expanded)
    }

    func testUserRequestedCollapseDoesNotActivateApp() {
        var machine = machine(current: .expanded)
        let decision = machine.handle(.userRequested(.capsule), now: now)
        XCTAssertEqual(decision.state.current, .capsule)
        XCTAssertFalse(decision.actions.contains(.activateApplication))
        XCTAssertTrue(decision.actions.contains(.resignKeyFocus))
    }

    func testRedundantRequestIsRejected() {
        var machine = machine(current: .capsule)
        let decision = machine.handle(.userRequested(.capsule), now: now)
        XCTAssertEqual(decision.rejection, .redundant)
        XCTAssertTrue(decision.actions.isEmpty)
    }

    // MARK: - 锁定

    func testLockedRejectsAutoCollapse() {
        var machine = machine(current: .capsule)
        _ = machine.handle(.userLockChanged(true), now: now)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .edge, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 300, height: 300))),
            now: now
        )
        XCTAssertEqual(decision.rejection, .locked)
        XCTAssertEqual(decision.state.current, .capsule, "锁定期间不得自动变形态")
    }

    // MARK: - 自动收缩

    func testAutoCollapseRequiresDeactivation() {
        var machine = machine(current: .expanded)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 800, height: 600))),
            now: now
        )
        XCTAssertEqual(decision.rejection, .appStillActive)
        XCTAssertEqual(decision.state.current, .expanded, "用户还在用完整播放器时不能自动收缩")
    }

    func testAutoCollapseAfterDeactivationAndDebounce() {
        var machine = machine(current: .expanded, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(600),
            interactionGrace: .milliseconds(100),
            morphologyCooldown: .milliseconds(0)))
        let start = now
        // 冷启动后必须"用起来"过：开始过播放（或有过用户交互）才允许自动收缩。
        _ = machine.handle(.playbackStarted, now: start)
        _ = machine.handle(.appDeactivated, now: start)
        _ = machine.handle(
            .environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 900, height: 700))),
            now: start
        )
        let decision = machine.handle(.tick, now: start.advanced(by: .milliseconds(700)))
        XCTAssertEqual(decision.state.current, .capsule)
        XCTAssertEqual(decision.reason, .spaceTightened)
    }

    func testColdStartNeverAutoCollapsesBeforeFirstPlayback() {
        // 刚打开应用、还没播放过也没操作过：别的应用在前台也不该把界面收掉。
        var machine = machine(current: .expanded, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(0),
            interactionGrace: .milliseconds(0),
            morphologyCooldown: .milliseconds(0)))
        let start = now
        _ = machine.handle(.appDeactivated, now: start)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 900, height: 700))),
            now: start.advanced(by: .seconds(2))
        )
        XCTAssertEqual(decision.rejection, .appStillActive)
        XCTAssertEqual(decision.state.current, .expanded)
    }

    func testInteractionGraceBlocksAutoCollapse() {
        var machine = machine(current: .expanded, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(0),
            interactionGrace: .seconds(5),
            morphologyCooldown: .milliseconds(0)))
        let start = now
        _ = machine.handle(.appDeactivated, now: start)
        // 用户刚点过播放控制（userRequested 会刷新交互时刻）。
        _ = machine.handle(.userRequested(.expanded), now: start)
        _ = machine.handle(
            .environmentEvaluated(.init(morphology: .edge, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 200, height: 200))),
            now: start
        )
        let decision = machine.handle(.tick, now: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(decision.rejection, .interactionGrace)
        XCTAssertEqual(decision.state.current, .expanded)
    }

    func testCooldownBlocksBackToBackMorphs() {
        var machine = machine(current: .capsule, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(0),
            interactionGrace: .milliseconds(0),
            morphologyCooldown: .seconds(1)))
        let start = now
        _ = machine.handle(.transitionCompleted, now: start)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .edge, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 220, height: 200))),
            now: start.advanced(by: .milliseconds(100))
        )
        XCTAssertEqual(decision.rejection, .coolingDown)
    }

    // MARK: - 打断

    func testInterruptingTransitionReplacesRatherThanQueues() {
        var machine = machine(current: .expanded)
        let first = machine.handle(.userRequested(.compact), now: now)
        XCTAssertEqual(first.state.current, .compact)
        XCTAssertEqual(first.state.previous, .expanded)

        let second = machine.handle(.userRequested(.capsule), now: now)
        XCTAssertEqual(second.state.current, .capsule)
        XCTAssertEqual(second.state.previous, .compact, "中断后新的起点是动画中的目标形态，不是最初的形态")
        XCTAssertEqual(second.actions.filter { if case .transition = $0 { return true } else { return false } }.count, 1,
                       "不允许积压动画：一次只保留一条变形动作")
    }

    func testTransitionInterruptedSettles() {
        var machine = machine(current: .expanded)
        _ = machine.handle(.userRequested(.compact), now: now)
        let decision = machine.handle(.transitionInterrupted, now: now)
        XCTAssertEqual(decision.state.phase, .settled)
        XCTAssertNil(decision.state.previous)
    }

    // MARK: - 系统状态

    func testFullscreenHidesFloatingButNotExpanded() {
        var floating = machine(current: .capsule)
        let hidden = floating.handle(.fullscreenChanged(true), now: now)
        XCTAssertEqual(hidden.state.current, .dormant)
        XCTAssertEqual(hidden.reason, .fullscreenEntered)

        var full = machine(current: .expanded)
        let untouched = full.handle(.fullscreenChanged(true), now: now)
        XCTAssertEqual(untouched.state.current, .expanded, "完整播放器是用户自己的窗口，全屏应用不改变它")
    }

    func testFullscreenExitRestoresPreviousMorphology() {
        var machine = machine(current: .capsule)
        _ = machine.handle(.fullscreenChanged(true), now: now)
        _ = machine.handle(.transitionCompleted, now: now)
        let restored = machine.handle(.fullscreenChanged(false), now: now)
        XCTAssertEqual(restored.state.current, .capsule)
        XCTAssertEqual(restored.reason, .fullscreenExited)
    }

    func testDormantOrdersOutOnCompletion() {
        var machine = machine(current: .capsule)
        _ = machine.handle(.userHiddenChanged(true), now: now)
        let decision = machine.handle(.transitionCompleted, now: now)
        XCTAssertEqual(decision.state.current, .dormant)
        XCTAssertTrue(decision.actions.contains(.orderOut), "隐匿形态动画结束后才把窗口移出屏幕")
    }

    func testSleepAndWakeRestore() {
        var machine = machine(current: .capsule)
        _ = machine.handle(.sleep, now: now)
        XCTAssertEqual(machine.state.suspendedBy, .sleep)
        let wake = machine.handle(.wake, now: now)
        XCTAssertEqual(wake.state.current, .capsule)
        XCTAssertNil(wake.state.suspendedBy)
    }

    func testAuxiliaryBrowsingBlocksAutoCollapse() {
        var machine = machine(current: .expanded, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(0),
            interactionGrace: .milliseconds(0),
            morphologyCooldown: .milliseconds(0)))
        let start = now
        // 先打开队列抽屉，再切走：抽屉开着的时候不允许自动收缩。
        _ = machine.handle(.auxiliaryActivityChanged(true), now: start)
        _ = machine.handle(.appDeactivated, now: start)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .edge, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 240, height: 200))),
            now: start.advanced(by: .seconds(3))
        )
        XCTAssertEqual(decision.rejection, .appStillActive)
        XCTAssertEqual(decision.state.current, .expanded, "用户正在浏览队列/设置时禁止自动收缩")
    }
}

/// 设置项"自动变形"的行为契约（规格 16：设置项必须真实生效）。
@MainActor
final class AutoMorphSettingTests: XCTestCase {

    private let clock = ContinuousClock()
    private var now: ContinuousClock.Instant { clock.now }

    private func machine() -> MorphologyStateMachine {
        var state = MorphologyState()
        state.current = .expanded
        state.hasStartedPlayback = true
        return MorphologyStateMachine(state: state, tuning: MorphologyTuning(
            autoCollapseDelay: .milliseconds(0),
            interactionGrace: .milliseconds(0),
            morphologyCooldown: .milliseconds(0)))
    }

    func testDisabledAutoMorphRejectsSpatialDecision() {
        var machine = machine()
        _ = machine.handle(.autoMorphChanged(false), now: now)
        let start = now
        _ = machine.handle(.appDeactivated, now: start)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 900, height: 700))),
            now: start.advanced(by: .seconds(2))
        )
        XCTAssertEqual(decision.rejection, .autoMorphDisabled)
        XCTAssertEqual(decision.state.current, .expanded, "关掉自动变形后，空间变化不得改变形态")
    }

    func testEnabledAutoMorphStillCollapses() {
        var machine = machine()
        _ = machine.handle(.autoMorphChanged(true), now: now)
        let start = now
        _ = machine.handle(.appDeactivated, now: start)
        let decision = machine.handle(
            .environmentEvaluated(.init(morphology: .capsule, fitsPreferred: true,
                                        currentStillFits: false, availableSize: CGSize(width: 900, height: 700))),
            now: start.advanced(by: .seconds(2))
        )
        XCTAssertEqual(decision.state.current, .capsule)
    }

    func testUserRequestStillWorksWhenAutoMorphDisabled() {
        // 自动变形关闭只挡"系统自动"，不挡用户自己点。
        var machine = machine()
        _ = machine.handle(.autoMorphChanged(false), now: now)
        let decision = machine.handle(.userRequested(.edge), now: now)
        XCTAssertEqual(decision.state.current, .edge)
    }
}

/// 快捷键注册簿记。Carbon 的 `RegisterEventHotKey` 在测试宿主里不保证成功，
/// 所以这里只验证"按 action 分开持有引用"的语义——也就是那个把三个快捷键
/// 打成只剩一个的 bug 的核心。
@MainActor
final class HotkeyBookkeepingTests: XCTestCase {

    func testRegisteringMultipleActionsKeepsPreviousOnes() throws {
        let center = HotkeyCenter.shared
        center.unregisterAll()
        defer { center.unregisterAll() }

        let first = center.register(.toggleInteractive, keyCode: 37, carbonModifiers: 0) {}
        let second = center.register(.cycleShape, keyCode: 40, carbonModifiers: 0) {}
        let third = center.register(.toggleVisibility, keyCode: 4, carbonModifiers: 0) {}

        // 至少不会出现"注册后一个就把前一个注销"——那是最坏的那个 bug。
        // 若宿主环境里 Carbon 注册整体不可用（三个都 false），则跳过断言。
        guard first || second || third else {
            throw XCTSkip("当前环境不允许注册 Carbon 全局快捷键")
        }
        XCTAssertEqual(center.registeredActionCount,
                       [first, second, third].filter { $0 }.count,
                       "注册成功几个就应该记几个，不能互相踢掉")
    }

    func testUnregisteringOneActionLeavesOthers() throws {
        let center = HotkeyCenter.shared
        center.unregisterAll()
        defer { center.unregisterAll() }

        let a = center.register(.toggleInteractive, keyCode: 37, carbonModifiers: 0) {}
        let b = center.register(.cycleShape, keyCode: 40, carbonModifiers: 0) {}
        guard a, b else { throw XCTSkip("当前环境不允许注册 Carbon 全局快捷键") }

        center.unregister(.toggleInteractive)
        XCTAssertEqual(center.registeredActionCount, 1, "只该少一个")
    }
}
