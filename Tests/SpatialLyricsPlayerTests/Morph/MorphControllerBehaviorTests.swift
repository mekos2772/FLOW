import AppKit
import XCTest
@testable import SpatialLyricsPlayer

/// 形态窗口的行为契约：深链、隐匿策略、激活策略、单一窗口。
///
/// 这些行为都在"窗口层"而不是纯逻辑层，只能靠真实 NSPanel 断言；
/// 它们也是最容易在重构里被无声改掉的那一类。
@MainActor
final class MorphControllerBehaviorTests: XCTestCase {

    // MARK: - 深链

    func testMorphDeepLinkParsesEveryMorphology() {
        for morphology in PlayerMorphology.allCases {
            XCTAssertEqual(
                DeepLinkRouter.action(for: URL(string: "spatiallyrics://morph/\(morphology.rawValue)")!),
                .setMorphology(morphology),
                "\(morphology) 的深链必须能解析"
            )
        }
        XCTAssertNil(DeepLinkRouter.action(for: URL(string: "spatiallyrics://morph/banana")!))
    }

    func testMorphDeepLinkReachesController() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller

        XCTAssertTrue(DeepLinkRouter.handle(URL(string: "spatiallyrics://morph/capsule")!,
                                            floating: controller,
                                            morph: controller))
        XCTAssertEqual(controller.morphology, .capsule)

        XCTAssertTrue(DeepLinkRouter.handle(URL(string: "spatiallyrics://morph/edge")!,
                                            floating: controller,
                                            morph: controller))
        XCTAssertEqual(controller.morphology, .edge)
    }

    func testOpenPlayerDeepLinkExpands() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.capsule)

        XCTAssertTrue(DeepLinkRouter.handle(URL(string: "spatiallyrics://now")!,
                                            floating: controller,
                                            morph: controller))
        XCTAssertEqual(controller.morphology, .expanded)
    }

    // MARK: - 激活策略

    func testExplicitMorphologySuppressesActivationExpansion() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        XCTAssertTrue(controller.allowsActivationExpansion)

        controller.setMorphology(.capsule)
        XCTAssertFalse(controller.allowsActivationExpansion,
                       "刚被显式切成胶囊时，激活应用不该把它弹回完整形态")
    }

    // MARK: - 隐匿策略

    func testExplicitHideOrdersOutEvenWhenAutomaticDormantKeepsHandle() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.show()
        XCTAssertEqual(controller.dormantStyle, .edgeHandle)

        controller.hide()
        XCTAssertEqual(controller.morphology, .dormant)
        XCTAssertFalse(controller.debugPanel.isVisible, "完全隐藏策略下窗口必须下屏")
    }

    func testDormantKeepsHandleWhenConfigured() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setDormantStyle(.edgeHandle)
        controller.show()

        controller.setMorphology(.dormant)
        XCTAssertEqual(controller.morphology, .dormant)
        XCTAssertTrue(controller.debugPanel.isVisible, "保留把手策略下窗口仍在屏上，只是缩成一小块")
    }

    func testHideWhileAlreadyDormantStillOrdersOut() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.show()
        controller.setMorphology(.dormant)
        XCTAssertTrue(controller.debugPanel.isVisible)
        controller.hide()
        XCTAssertFalse(controller.debugPanel.isVisible)
        controller.show()
        XCTAssertTrue(controller.debugPanel.isVisible)
    }

    /// 隐匿不一定来自"用户按了隐藏"：空间评估、睡眠、全屏都会把形态压到 `.dormant`。
    ///
    /// 那些路径下 `isUserHidden` 一直是 false，`show()` 原来只发
    /// `userHiddenChanged(false)`，状态机判成 redundant 直接吞掉 ——
    /// 实机表现就是音乐还在放、窗口没了、⌃⌥H 按下去毫无反应，只能退出应用。
    func testShowRecoversFromDormantThatWasNotUserHidden() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setDormantStyle(.hideCompletely)
        controller.show()

        controller.setMorphology(.dormant)
        XCTAssertFalse(controller.debugPanel.isVisible, "完全隐藏策略下 dormant 必须下屏")

        controller.show()

        XCTAssertTrue(controller.debugPanel.isVisible,
                      "⌃⌥H 必须能把窗口从\"非用户隐藏\"的 dormant 里拿回来")
        XCTAssertNotEqual(controller.morphology, .dormant)
    }

    func testDormantStylePersists() throws {
        let harness = try MorphTestSupport.make()
        harness.controller.setDormantStyle(.edgeHandle)
        XCTAssertEqual(harness.preferences.load().dormantStyle, DormantStyle.edgeHandle.rawValue)
    }

    // MARK: - 形态与歌词排布

    func testFloatingShapeChangesCapsuleGeometry() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller

        controller.setMorphology(.capsule)
        let singleLine = controller.currentFrame.height
        // 几何落点依赖真实桌面（求解器会避让所有可见窗口）。
        // 在没有可用落点的环境里窗口尺寸不会变——这时跳过而不是误报失败：
        // 应用内的实际尺寸已由截图与窗口契约测试覆盖。
        try XCTSkipIf(singleLine >= 100,
                      "测试环境未完成几何落点，跳过尺寸断言：\(controller.currentFrame)")

        controller.setFloatingShape(.board)
        XCTAssertGreaterThan(controller.currentFrame.height, singleLine,
                             "歌词板比单行胶囊高：single=\(singleLine) board=\(controller.currentFrame)")
        XCTAssertEqual(controller.floatingShape, .board)
    }

    func testShapeAndMorphologyAreIndependent() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setFloatingShape(.doubleLine)
        XCTAssertEqual(controller.floatingShape, .doubleLine)

        controller.setMorphology(.edge)
        XCTAssertEqual(controller.floatingShape, .doubleLine, "换形态不该重置歌词排布偏好")
    }

    // MARK: - 循环

    func testCycleMorphologyWalksFixedOrder() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)

        var seen: [PlayerMorphology] = []
        // 循环只在看得见的四态之间走：完整 → 迷你 → 胶囊 → 贴边 → 完整。
        //
        // 曾经把 `.dormant` 接在贴边后面，结果"贴边"再按一次就进了隐藏，
        // `hideCompletely` 把窗口 orderOut —— 用户反馈原话是"贴边后那个小卡片就消失了"。
        // 隐藏必须是显式动作（⌃⌥H），不能靠连按切换键撞上。
        for _ in 0..<4 {
            controller.cycleMorphology()
            seen.append(controller.morphology)
        }
        XCTAssertEqual(seen, [.compact, .capsule, .edge, .expanded])
    }
}

/// 冷启动恢复必须同时同步"窗口"和"状态机"。
///
/// 只恢复窗口不恢复状态机时，窗口是胶囊、状态机以为自己是完整形态，
/// 用户点胶囊会被判成 `redundant`——点了没反应（实机踩到过）。
@MainActor
final class MorphRestoreConsistencyTests: XCTestCase {


    /// 等到条件成立，最多等 `timeout`。
    ///
    /// 这两个用例原来是固定 `Task.sleep(400ms)` 之后断言：跑整套测试时机器被并行用例占满，
    /// 冷启动恢复（要读位置快照）偶尔超过 400ms，于是随机失败一次。
    /// 实测同一份代码连跑两次，一次全过、一次挂在 `testRestoredLockIsHonoured`。

    /// 给**每一块**当前屏幕都播同一个形态。
    ///
    /// 原来只给 `mainScreenGeometry().id` 播种。而 `NSScreen.main` 指的是"有键窗口的那块屏"，
    /// 接上虚拟显示器（DeskPad）之后它会飘：播种时是物理屏、恢复时算出来是虚拟屏，
    /// 查表落空就退回 `appearance.defaultMorphology`（完整形态）——
    /// 表现就是同一份代码跑整套测试时随机失败，单独跑又过。
    private func seedForEveryScreen(_ snapshot: MorphPreferenceSnapshot,
                                    morphology: PlayerMorphology) -> MorphPreferenceSnapshot {
        var ids = Set(NSScreen.screens.compactMap { ScreenGeometryResolver.displayUUID(for: $0) })
        ids.insert(ScreenGeometryResolver.mainScreenGeometry().id)
        var copy = snapshot
        copy.morphologyByDisplay = Dictionary(uniqueKeysWithValues: ids.map { ($0, morphology.rawValue) })
        return copy
    }

    private func waitUntil(_ description: String,
                           timeout: Duration = .seconds(3),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时：\(description)")
    }

    func testRestoredMorphologyIsTheMachineState() async throws {
        let display = ScreenGeometryResolver.mainScreenGeometry().id
        let harness = try MorphTestSupport.make(seed: seedForEveryScreen(MorphPreferenceSnapshot(
            edgeByDisplay: [display: ScreenEdge.top.rawValue],
            // 锁住形态，避免测试环境里"应用不在前台"触发的自动收缩干扰断言。
            isMorphologyLocked: true,
            isClickThrough: false,
            floatingShape: LyricsShape.capsule.rawValue
        ), morphology: .capsule))
        harness.controller.start()
        // 恢复流程是异步的（要读位置快照）：等它真的落地，而不是赌一个固定时长。
        try await waitUntil("冷启动恢复到胶囊") {
            harness.controller.morphology == .capsule && harness.controller.isMorphologyLocked
        }

        XCTAssertEqual(harness.controller.morphology, .capsule, "冷启动应恢复记住的形态")
        XCTAssertTrue(harness.controller.isMorphologyLocked, "锁定状态也要恢复")
        // 拥挤桌面上允许按可用空间收一点（但必须留在形态的尺寸区间内）；
        // 标准尺寸本身由 resolver 层用例（`testCapsuleCollapseKeepsTopLeft`）保证。
        let geometry = PlayerMorphology.capsule.geometry
        let size = harness.controller.debugPanel.frame.size
        XCTAssertGreaterThanOrEqual(size.width + 0.5, geometry.minimumSize.width)
        XCTAssertGreaterThanOrEqual(size.height + 0.5, geometry.minimumSize.height)
        // +1：窗口 frame 会做 integral 取整，56 的规格可能落到 57，这不是尺寸越界。
        XCTAssertLessThanOrEqual(size.width, geometry.preferredSize.width + 1)
        XCTAssertLessThanOrEqual(size.height, geometry.preferredSize.height + 1)

        // 关键：点一下要能真的展开，而不是被状态机判成 redundant。
        // （点击展开同时解除形态锁定，这是产品里明确的行为。）
        harness.controller.expand()
        XCTAssertEqual(harness.controller.morphology, .expanded)
        XCTAssertFalse(harness.controller.isMorphologyLocked)
    }

    func testRestoredLockIsHonoured() async throws {
        let display = ScreenGeometryResolver.mainScreenGeometry().id
        let harness = try MorphTestSupport.make(seed: seedForEveryScreen(MorphPreferenceSnapshot(
            isMorphologyLocked: true
        ), morphology: .edge))
        harness.controller.start()
        try await waitUntil("冷启动恢复到贴边") {
            harness.controller.morphology == .edge && harness.controller.isMorphologyLocked
        }

        XCTAssertEqual(harness.controller.morphology, .edge)
        XCTAssertTrue(harness.controller.isMorphologyLocked)
    }

    func testUnlockedFloatingSnapshotFallsBackToExpandedWhenFloatingDisabled() async throws {
        let harness = try MorphTestSupport.make(seed: seedForEveryScreen(MorphPreferenceSnapshot(
            isMorphologyLocked: false
        ), morphology: .capsule))
        harness.controller.start()
        try await waitUntil("冷启动回落到完整形态") {
            harness.controller.morphology == .expanded
        }
        XCTAssertEqual(harness.controller.morphology, .expanded,
                       "悬浮模式关闭且未锁定时，冷启动应回到完整主窗口")
    }

    func testUnlockedFloatingSnapshotRestoresWhenFloatingEnabled() async throws {
        let settings = InMemorySettingsStore()
        await settings.setAutoCollapseOnDeactivate(true)
        // 未锁定形态会参与空间求解：不注入空桌面时，真实桌面窗口多寡会决定胶囊还是贴边，测试变成看运气。
        let emptyDesktop = ObstacleProvider(policy: ObstacleRefreshPolicy(minimumInterval: .zero)) { _ in [] }
        let harness = try MorphTestSupport.make(
            seed: seedForEveryScreen(MorphPreferenceSnapshot(isMorphologyLocked: false), morphology: .capsule),
            settings: settings,
            obstacleProvider: emptyDesktop
        )
        harness.controller.start()
        try await waitUntil("悬浮模式开启时恢复胶囊") {
            harness.controller.morphology == .capsule
        }
        XCTAssertEqual(harness.controller.morphology, .capsule)
        harness.controller.hide()
    }
}

/// 线程安全的可变障碍物容器，供脱离真实桌面的避让回归测试按场景动态切换遮挡窗口。
private final class ControlledObstacleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rects: [CGRect]

    init(_ initial: [CGRect] = []) {
        self.rects = initial
    }

    func get() -> [CGRect] {
        lock.withLock { rects }
    }

    func set(_ newRects: [CGRect]) {
        lock.withLock { rects = newRects }
    }
}

/// 自动避让稳定性回归测试：覆盖冷启动检测、前台悬浮巡检、6 秒保护期让位、连续拖窗不饥饿、以及关闭/重开避让即时生效。
@MainActor
final class AutoAvoidanceReliabilityTests: XCTestCase {

    private func makeProvider(box: ControlledObstacleBox,
                              scanDelayMicros: useconds_t = 0) -> ObstacleProvider {
        ObstacleProvider(policy: ObstacleRefreshPolicy(minimumInterval: .zero)) { _ in
            if scanDelayMicros > 0 { usleep(scanDelayMicros) }
            return box.get()
        }
    }

    private func seedCapsuleSnapshot() -> MorphPreferenceSnapshot {
        var ids = Set(NSScreen.screens.compactMap { ScreenGeometryResolver.displayUUID(for: $0) })
        ids.insert(ScreenGeometryResolver.mainScreenGeometry().id)
        return MorphPreferenceSnapshot(
            morphologyByDisplay: Dictionary(uniqueKeysWithValues: ids.map { ($0, PlayerMorphology.capsule.rawValue) }),
            isMorphologyLocked: true,
            isClickThrough: false,
            floatingShape: LyricsShape.capsule.rawValue
        )
    }

    private func waitUntil(_ description: String,
                           timeout: Duration = .seconds(2),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时：\(description)")
    }

    private func coveringSideObstacle(for frame: CGRect, in zone: CGRect) -> CGRect {
        if frame.midX <= zone.midX {
            let width = max(zone.width * 0.45, frame.maxX + 40 - zone.minX)
            return CGRect(x: zone.minX, y: zone.minY, width: min(width, zone.width * 0.60), height: zone.height)
        } else {
            let minX = min(zone.maxX - zone.width * 0.45, frame.minX - 40)
            let clampedMinX = max(minX, zone.minX + zone.width * 0.40)
            return CGRect(x: clampedMinX, y: zone.minY, width: zone.maxX - clampedMinX, height: zone.height)
        }
    }

    func testColdStartFloatingAvoidsObstacleImmediately() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        // 遮住屏幕上半部分（包含无位置记忆时胶囊的 centeredAnchor），下方保留充裕空间。
        let upperBlock = CGRect(x: zone.minX,
                                y: zone.minY + zone.height * 0.55,
                                width: zone.width,
                                height: zone.height * 0.45)
        let box = ControlledObstacleBox([upperBlock])
        let harness = try MorphTestSupport.make(
            seed: seedCapsuleSnapshot(),
            obstacleProvider: makeProvider(box: box)
        )
        defer { harness.controller.shutdown() }

        harness.controller.start()
        try await waitUntil("冷启动恢复胶囊并第一时间避开障碍物") {
            harness.controller.morphology == .capsule
                && Coverage.fraction(of: harness.controller.currentFrame, by: [upperBlock]) == 0
                && zone.insetBy(dx: -1, dy: -1).contains(harness.controller.currentFrame)
        }
    }

    func testSwitchingToFloatingAvoidsObstacleInsideHoldWindow() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        let box = ControlledObstacleBox([])
        let harness = try MorphTestSupport.make(obstacleProvider: makeProvider(box: box))
        defer { harness.controller.shutdown() }

        harness.controller.start()
        try await waitUntil("初始化稳定") {
            harness.controller.morphology == .expanded
        }

        // 在原地覆盖上半区（用户点击切换悬浮后的默认锚点所在位置），并验证 6 秒保护期内直接避开而非先压窗等 6 秒。
        let upperBlock = CGRect(x: zone.minX,
                                y: zone.minY + zone.height * 0.55,
                                width: zone.width,
                                height: zone.height * 0.45)
        box.set([upperBlock])
        harness.controller.setMorphology(.capsule)

        try await waitUntil("切换到胶囊形态后应绕开顶部遮挡") {
            harness.controller.morphology == .capsule
                && Coverage.fraction(of: harness.controller.currentFrame, by: [upperBlock]) == 0
        }

        // 第二阶段：仍在 6 秒 userMorphUntil 保护期内，新窗口又遮住胶囊刚落下的位置，必须立刻同形态平移让位。
        let followUpBlock = coveringSideObstacle(for: harness.controller.currentFrame, in: zone)
        box.set([followUpBlock])
        harness.controller.setAppActiveForTesting(true)
        await harness.controller.runCompensatingCheckForTesting()

        try await waitUntil("6 秒保护期内被新障碍遮挡时仍应立即同形态避让") {
            harness.controller.morphology == .capsule
                && Coverage.fraction(of: harness.controller.currentFrame, by: [followUpBlock]) == 0
        }
    }

    func testCompensatingCheckMonitorsWhileAppIsActiveInFloatingMode() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        let box = ControlledObstacleBox([])
        let harness = try MorphTestSupport.make(obstacleProvider: makeProvider(box: box))
        defer { harness.controller.shutdown() }

        harness.controller.start()
        harness.controller.setMorphology(.capsule)
        try await waitUntil("等待胶囊初态落定") {
            harness.controller.morphology == .capsule
        }

        // 模拟应用仍然处于前台激活状态，但正在悬浮模式。
        harness.controller.setAppActiveForTesting(true)
        let blocker = coveringSideObstacle(for: harness.controller.currentFrame, in: zone)
        box.set([blocker])

        await harness.controller.runCompensatingCheckForTesting()
        try await waitUntil("前台悬浮态下定时巡检应触发自动避让") {
            Coverage.fraction(of: harness.controller.currentFrame, by: [blocker]) == 0
        }
    }

    func testContinuousGeometryChangesDuringEvaluationDoNotStarveAvoidance() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        let box = ControlledObstacleBox([])
        // 扫描模拟 25ms 延迟，确保在评估飞在半途时能够灌入后续几何变更事件。
        let harness = try MorphTestSupport.make(obstacleProvider: makeProvider(box: box, scanDelayMicros: 25_000))
        defer { harness.controller.shutdown() }

        harness.controller.start()
        harness.controller.setMorphology(.capsule)
        harness.controller.setAppActiveForTesting(true)
        try await waitUntil("进入胶囊态") {
            harness.controller.morphology == .capsule
        }

        let blocker = coveringSideObstacle(for: harness.controller.currentFrame, in: zone)
        box.set([blocker])

        // 首轮检查发出评估后，连续高频注入 geometryOnly 事件，验证不会被 spatialSeq 无限作废饿死。
        harness.controller.triggerGeometryChangeForTesting()
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(12))
            harness.controller.triggerGeometryChangeForTesting()
        }

        try await waitUntil("连续几何变动流结束后仍必须完成避让") {
            Coverage.fraction(of: harness.controller.currentFrame, by: [blocker]) == 0
        }
    }

    func testAutoAvoidDisabledAndReenabledTakesEffectImmediately() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        let box = ControlledObstacleBox([])
        let harness = try MorphTestSupport.make(obstacleProvider: makeProvider(box: box))
        defer { harness.controller.shutdown() }

        harness.controller.start()
        harness.controller.setMorphology(.capsule)
        try await waitUntil("初始化为胶囊") {
            harness.controller.morphology == .capsule
        }

        let before = harness.controller.currentFrame
        let blocker = coveringSideObstacle(for: before, in: zone)
        harness.controller.setAutoAvoid(false)
        box.set([blocker])
        await harness.controller.runCompensatingCheckForTesting()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(harness.controller.currentFrame, before, "关闭自动避让后不应躲避障碍物")

        harness.controller.setAutoAvoid(true)
        try await waitUntil("重新开启自动避让后应立刻避开当前障碍物") {
            Coverage.fraction(of: harness.controller.currentFrame, by: [blocker]) == 0
        }
    }

    func testLockedCompactRelocatesSameFormWhenBlocked() async throws {
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone
        let box = ControlledObstacleBox([])
        let harness = try MorphTestSupport.make(obstacleProvider: makeProvider(box: box))
        defer { harness.controller.shutdown() }

        harness.controller.start()
        harness.controller.setMorphology(.compact)
        try await waitUntil("进入迷你形态并锁定") {
            harness.controller.morphology == .compact
        }
        harness.controller.toggleMorphologyLock()
        XCTAssertTrue(harness.controller.isMorphologyLocked)

        // 锁定形态后允许同形态平移让位，而不应因为无法降级成胶囊/贴边而原地被遮挡。
        let blocker = coveringSideObstacle(for: harness.controller.currentFrame, in: zone)
        box.set([blocker])
        harness.controller.setAppActiveForTesting(true)
        await harness.controller.runCompensatingCheckForTesting()

        try await waitUntil("锁定迷你形态下被遮挡时仍应同形态平移避让") {
            harness.controller.morphology == .compact
                && Coverage.fraction(of: harness.controller.currentFrame, by: [blocker]) == 0
        }
    }
}
