import AppKit
import XCTest
@testable import SpatialLyricsPlayer

/// 形态窗口的窗口契约测试。
///
/// 这些属性决定"不抢焦点""跟随 Space""完整形态才吃键盘"这些用户可感知的行为，
/// 一旦被误改很难在手工测试里发现，因此固化在测试里。
@MainActor
final class MorphWindowContractTests: XCTestCase {

    func testExpandedIsAKeyCapableNormalWindow() throws {
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel

        harness.controller.setMorphology(.expanded)
        XCTAssertTrue(panel.canBecomeKey, "完整播放器必须能接收键盘输入")
        XCTAssertEqual(panel.level, .normal, "完整播放器是普通窗口，不压在别人上面")
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.hasShadow, "完整播放器需要阴影建立空间层级")
    }

    func testFloatingMorphologiesNeverBecomeKeyOrMain() throws {
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel

        for morphology in [PlayerMorphology.compact, .capsule, .edge] {
            harness.controller.setMorphology(morphology)
            XCTAssertEqual(harness.controller.morphology, morphology)
            XCTAssertFalse(panel.canBecomeKey, "\(morphology) 抢焦点会打断用户正在打的字")
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(panel.level, .floating, "使用公开层级，不碰私有/保护层级")
            XCTAssertFalse(panel.hasShadow, "透明背景上的系统阴影会画出矩形暗边")
        }
    }

    func testFloatingMorphologiesJoinAllSpaces() throws {
        let harness = try MorphTestSupport.make()
        harness.controller.setMorphology(.capsule)
        let panel = harness.controller.debugPanel

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle), "不应出现在 Cmd-Tab 与窗口循环里")
        XCTAssertFalse(panel.hidesOnDeactivate, "失活不应隐藏歌词")
    }

    func testFloatingMorphologiesAreBorderlessTransparent() throws {
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel
        harness.controller.setMorphology(.capsule)
        XCTAssertTrue(panel.styleMask.contains(.borderless), "悬浮形态没有标题栏")
        XCTAssertFalse(panel.isOpaque)
    }

    /// 主窗口必须是一个"正常窗口"：能拖、能关、能最小化、能全屏。
    ///
    /// 这条是为了钉住一个真实的倒退：完整形态曾经用无边框窗口 + 自绘拖动手柄，
    /// 结果用户既拖不动窗口，也没有关闭/最小化/全屏三个按钮。
    /// 现在用系统标题栏，四个能力全部由 AppKit 提供。
    func testExpandedBehavesLikeARealWindow() throws {
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel
        harness.controller.setMorphology(.expanded)

        XCTAssertTrue(panel.styleMask.contains(.titled), "要有标题栏才能拖动")
        XCTAssertTrue(panel.styleMask.contains(.closable), "要有关闭按钮")
        XCTAssertTrue(panel.styleMask.contains(.miniaturizable), "要有最小化按钮")
        XCTAssertTrue(panel.styleMask.contains(.resizable), "要有缩放入口（含全屏）")
        XCTAssertTrue(panel.isMovable, "窗口必须可移动")
        XCTAssertNotNil(panel.standardWindowButton(.closeButton))
        XCTAssertNotNil(panel.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(panel.standardWindowButton(.zoomButton))
        XCTAssertFalse(panel.standardWindowButton(.closeButton)?.isHidden ?? true,
                       "按钮不能是隐藏的")
        XCTAssertTrue(panel.titlebarAppearsTransparent, "标题栏透明，视觉上仍是一张版面")
        XCTAssertFalse(panel.isFloatingPanel, "主窗口不该是浮动面板，否则进不了全屏")
    }

    func testMinimumSizeOnlyConstrainsExpandedWindow() throws {
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel
        harness.controller.setMorphology(.expanded)
        XCTAssertEqual(panel.minSize, PlayerMorphology.expanded.geometry.minimumSize)
        XCTAssertEqual(harness.controller.windowWillResize(panel, to: NSSize(width: 600, height: 300)),
                       PlayerMorphology.expanded.geometry.minimumSize)
        harness.controller.setMorphology(.capsule)
        XCTAssertEqual(harness.controller.windowWillResize(panel, to: NSSize(width: 320, height: 56)),
                       NSSize(width: 320, height: 56))
        XCTAssertEqual(panel.minSize, .zero, "悬浮形态不能继承主窗口的最小尺寸")
        harness.controller.setMorphology(.expanded)
        XCTAssertEqual(panel.minSize, PlayerMorphology.expanded.geometry.minimumSize)
    }

    func testNonactivatingOnlyAppliesToFloatingMorphologies() throws {
        // 完整形态必须能被一次点击激活：`.nonactivatingPanel` 会让应用永远不激活，
        // 而 macOS 的 Button 在非激活应用里不响应点击（实测：完整形态按钮全点不动）。
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel

        harness.controller.setMorphology(.expanded)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel), "完整形态要能被激活")
        XCTAssertTrue(panel.canBecomeKey, "完整形态点一下就该成为 key")

        harness.controller.setMorphology(.capsule)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "悬浮形态不该抢激活")
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testSingleWindowCarriesAllMorphologies() throws {
        // 这条是"同一实体"的硬约束：五种形态永远是同一个 NSWindow 实例。
        let harness = try MorphTestSupport.make()
        let panel = harness.controller.debugPanel
        for morphology in PlayerMorphology.allCases {
            harness.controller.setMorphology(morphology)
            XCTAssertTrue(harness.controller.debugPanel === panel,
                          "\(morphology) 换成了别的窗口，连续变形就不成立了")
        }
    }

    func testTogglingInteractiveFlipsMouseTransparency() throws {
        let harness = try MorphTestSupport.make()
        harness.controller.setMorphology(.capsule)
        let panel = harness.controller.debugPanel

        XCTAssertFalse(panel.ignoresMouseEvents, "悬浮形态默认可以点，否则无法点击展开")

        harness.controller.toggleInteractive()
        XCTAssertTrue(panel.ignoresMouseEvents, "穿透模式必须真的放行鼠标事件")

        harness.controller.toggleInteractive()
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testVisibilityToggleOrdersPanelInAndOut() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        let panel = controller.debugPanel

        controller.setMorphology(.capsule)
        controller.show()
        XCTAssertTrue(panel.isVisible)

        controller.hide()
        XCTAssertEqual(controller.morphology, .dormant)
        XCTAssertFalse(panel.isVisible)

        controller.show()
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotEqual(controller.morphology, .dormant)
    }

    /// 断言的是**落定后**的位置：过渡动画中途的插值帧本来就在路上，
    /// 拿它判"越界"会把动画时长当成缺陷（这里等动画走完再看）。
    func testCollapseRespectsSafeZoneAtEveryShape() async throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        let zone = ScreenGeometryResolver.mainScreenGeometry().safeZone

        for shape in LyricsShape.allCases {
            controller.setFloatingShape(shape)
            // 先切到 mini 再切回胶囊：强制走一次真实过渡，
            // 否则"已经是胶囊"会被判成 redundant，窗口停在初始位置上没被动过。
            controller.setMorphology(.compact)
            try await Task.sleep(for: .milliseconds(700))
            controller.setMorphology(.capsule)
            try await Task.sleep(for: .milliseconds(900))
            XCTAssertTrue(zone.contains(controller.currentFrame.insetBy(dx: -1, dy: -1)),
                          "\(shape) 形态越出了安全区：\(controller.currentFrame) zone=\(zone)")
        }
    }

    func testResetPlacementMemoryClearsStoreAndUnlocks() async throws {
        let harness = try MorphTestSupport.make(seed: MorphPreferenceSnapshot(
            morphologyByDisplay: ["display-999": "edge"],
            edgeByDisplay: ["display-999": "left"],
            isMorphologyLocked: true,
            isClickThrough: true,
            floatingShape: LyricsShape.board.rawValue
        ))
        let controller = harness.controller

        await controller.resetPlacementMemory()

        XCTAssertFalse(controller.isMorphologyLocked, "恢复默认布局必须解除形态锁定")
        XCTAssertEqual(harness.preferences.load().morphologyByDisplay.isEmpty, true,
                       "记忆必须真的被清掉，否则下次启动又被覆盖")
    }

    func testMorphologyLockPersists() throws {
        let harness = try MorphTestSupport.make()
        harness.controller.setMorphology(.capsule)
        harness.controller.toggleMorphologyLock()

        XCTAssertTrue(harness.controller.isMorphologyLocked)
    }
}

/// 主窗口的生命周期：红点/⌘W 收进菜单栏、全屏期间不自动摆位置。
@MainActor
final class MainWindowLifecycleTests: XCTestCase {

    func testCloseButtonCollapsesInsteadOfClosing() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)

        // 必须走**代理**这条真实路径：旧的无参 windowShouldClose() 注册不上代理，
        // 直接调用会产生"测试全绿、红点仍然关窗"的假通过。
        let panel = controller.debugPanel
        let delegate = try XCTUnwrap(panel.delegate, "面板必须有代理，否则红点不受控")
        let shouldClose = delegate.windowShouldClose?(panel)
        XCTAssertEqual(shouldClose, false, "主窗口关闭应走「收进菜单栏」")
        XCTAssertNotEqual(controller.morphology, .expanded,
                          "收起后不该还停在完整形态")
        XCTAssertEqual(controller.morphology, .dormant,
                       "悬浮模式默认关闭时，点关闭应直接收进菜单栏而非弹出悬浮胶囊")
        XCTAssertFalse(panel.isVisible)
    }

    func testCloseButtonCollapsesToCapsuleWhenFloatingModeEnabled() async throws {
        let settings = InMemorySettingsStore()
        await settings.setAutoCollapseOnDeactivate(true)
        let harness = try MorphTestSupport.make(settings: settings)
        let controller = harness.controller
        controller.setMorphology(.expanded)

        let panel = controller.debugPanel
        let delegate = try XCTUnwrap(panel.delegate)
        let shouldClose = delegate.windowShouldClose?(panel)
        XCTAssertEqual(shouldClose, false)
        XCTAssertEqual(controller.morphology, .capsule)
        controller.hide()
    }

    func testFullscreenEnterAndExitAreHandled() throws {
        let harness = try MorphTestSupport.make()
        let controller = harness.controller
        controller.setMorphology(.expanded)

        // 不该崩，也不该在退出后落到非法状态。
        controller.windowWillEnterFullScreen()
        controller.windowDidExitFullScreen()
        XCTAssertTrue(PlayerMorphology.allCases.contains(controller.morphology))
    }

    func testWindowHasDelegateForLifecycle() throws {
        let harness = try MorphTestSupport.make()
        XCTAssertNotNil(harness.controller.debugPanel.delegate,
                        "必须有 window delegate，否则红点/全屏回调不会被调用")
    }
}
