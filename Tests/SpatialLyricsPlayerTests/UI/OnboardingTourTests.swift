import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class OnboardingTourTests: XCTestCase {
    private var defaultsSuiteName: String?

    override func tearDown() {
        if let name = defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: name)
        }
        defaultsSuiteName = nil
        super.tearDown()
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let name = "flow.onboarding.tests.\(UUID().uuidString)"
        defaultsSuiteName = name
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// 主窗口这么大：和默认窗口一致（1020×640 的内容区）。
    private let windowSize = CGSize(width: 1020, height: 640)

    private var sampleAnchors: [OnboardingAnchor: CGRect] {
        [
            .search: CGRect(x: 204, y: 34, width: 380, height: 38),
            .sidebar: CGRect(x: 0, y: 84, width: 180, height: 470),
            .modeSwitch: CGRect(x: 752, y: 40, width: 150, height: 28),
            .content: CGRect(x: 181, y: 85, width: 839, height: 465),
            .transport: CGRect(x: 0, y: 550, width: 1020, height: 90)
        ]
    }

    // MARK: - 步骤

    func testStepsWalkThroughEveryMainAreaOnce() {
        let steps = Onboarding.steps
        XCTAssertEqual(steps.map(\.anchor), [.search, .sidebar, .modeSwitch, .content, .transport])
        // id 必须唯一：`ForEach` 与动画都以它为准。
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count)
    }

    func testEveryStepHasATitleAndADetail() {
        for step in Onboarding.steps {
            XCTAssertFalse(String(describing: step.title).isEmpty)
            XCTAssertFalse(String(describing: step.detail).isEmpty)
        }
    }

    // MARK: - 卡片位置

    func testCardStaysInsideWindowForEveryAnchor() {
        for (anchor, rect) in sampleAnchors {
            let origin = OnboardingOverlay.cardOrigin(anchorRect: rect, size: windowSize, cardHeight: 150)
            let card = CGRect(origin: origin, size: CGSize(width: OnboardingOverlay.cardWidth, height: 150))
            XCTAssertTrue(windowSize.width >= card.maxX,
                          "\(anchor) 的卡片右边超出窗口：\(card)")
            XCTAssertTrue(windowSize.height >= card.maxY,
                          "\(anchor) 的卡片底部超出窗口：\(card)")
            XCTAssertGreaterThanOrEqual(card.minX, 0, "\(anchor) 的卡片左边超出窗口")
            XCTAssertGreaterThanOrEqual(card.minY, 0, "\(anchor) 的卡片顶部超出窗口")
        }
    }

    func testCardSitsBelowTopAnchorsAndAboveBottomOnes() {
        let search = sampleAnchors[.search]!
        let searchOrigin = OnboardingOverlay.cardOrigin(anchorRect: search, size: windowSize, cardHeight: 150)
        XCTAssertGreaterThan(searchOrigin.y, search.maxY, "顶部目标下方才是空地方")

        let transport = sampleAnchors[.transport]!
        let transportOrigin = OnboardingOverlay.cardOrigin(anchorRect: transport, size: windowSize, cardHeight: 150)
        XCTAssertLessThan(transportOrigin.y + 150, transport.minY, "底栏上方才是空地方")
    }

    func testLargeContentAreaKeepsCardInsideItInsteadOfCoveringTheHeader() {
        let content = sampleAnchors[.content]!
        let origin = OnboardingOverlay.cardOrigin(anchorRect: content, size: windowSize, cardHeight: 150)
        // 内容区是一大片：卡片落在它内部靠下，不要跑到顶上去压搜索框。
        XCTAssertGreaterThan(origin.y, content.minY + content.height / 2)
        XCTAssertLessThanOrEqual(origin.y + 150, content.maxY)
    }

    func testTallNarrowSidebarGetsItsCardOnTheRight() {
        let sidebar = sampleAnchors[.sidebar]!
        let origin = OnboardingOverlay.cardOrigin(anchorRect: sidebar, size: windowSize, cardHeight: 150)
        XCTAssertGreaterThan(origin.x, sidebar.maxX, "侧栏的卡片放右边，别把导航项挡住")
        XCTAssertLessThanOrEqual(origin.y + 150, windowSize.height)
    }

    func testMissingAnchorFallsBackToCenteredCard() {
        let origin = OnboardingOverlay.cardOrigin(anchorRect: nil, size: windowSize, cardHeight: 150)
        XCTAssertEqual(origin.x, (windowSize.width - OnboardingOverlay.cardWidth) / 2, accuracy: 0.5)
        XCTAssertEqual(origin.y, (windowSize.height - 150) / 2, accuracy: 0.5)
    }

    func testTinyWindowStillKeepsCardInside() {
        let size = CGSize(width: 260, height: 180)
        let origin = OnboardingOverlay.cardOrigin(anchorRect: CGRect(x: 10, y: 10, width: 120, height: 30),
                                                  size: size,
                                                  cardHeight: 150)
        XCTAssertGreaterThanOrEqual(origin.x, 0)
        XCTAssertGreaterThanOrEqual(origin.y, 0)
    }

    // MARK: - 箭头

    func testArrowLeavesTheCardSideFacingTheTarget() {
        let card = CGRect(x: 300, y: 300, width: 292, height: 150)
        let target = CGRect(x: 400, y: 60, width: 200, height: 40)
        let points = OnboardingOverlay.arrowPoints(card: card, target: target)
        // 目标在上方：箭头从卡片上沿出发。
        XCTAssertEqual(points.start.y, card.minY - 2, accuracy: 0.5)
        XCTAssertLessThan(points.start.x, card.maxX)
        XCTAssertGreaterThan(points.start.x, card.minX)
        // 箭头停在目标外面一点，不盖住目标本身。
        XCTAssertLessThan(points.end.y, target.maxY)
        XCTAssertGreaterThan(points.end.y, target.minY)
    }

    func testArrowOnlyWhenCardSitsOutsideTheHighlightedArea() {
        for (anchor, rect) in sampleAnchors {
            let origin = OnboardingOverlay.cardOrigin(anchorRect: rect, size: windowSize, cardHeight: 150)
            let card = CGRect(origin: origin, size: CGSize(width: OnboardingOverlay.cardWidth, height: 150))
            let spotlight = rect.insetBy(dx: -8, dy: -8)
            // 内容区是一大片：卡片放在里面，不画箭头；其余几步都要有箭头指过去。
            XCTAssertEqual(OnboardingOverlay.showsArrow(card: card, spotlight: spotlight), anchor != .content,
                           "\(anchor) 的箭头显示不对")
        }
    }

    func testArrowPointsRightWhenTargetIsToTheRight() {
        let card = CGRect(x: 40, y: 300, width: 292, height: 150)
        let target = CGRect(x: 600, y: 340, width: 160, height: 60)
        let points = OnboardingOverlay.arrowPoints(card: card, target: target)
        XCTAssertEqual(points.start.x, card.maxX + 2, accuracy: 0.5)
        XCTAssertGreaterThan(points.end.x, points.start.x)
        XCTAssertLessThan(points.end.x, target.maxX)
    }

    // MARK: - 看过标记

    func testSeenFlagIsOffByDefaultInProductionAndCanBePersisted() async throws {
        let defaults = try makeIsolatedDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasSeenOnboarding, "全新安装应该弹一次引导")
        await store.setHasSeenOnboarding(true)
        XCTAssertTrue(store.hasSeenOnboarding)
        // 换一个实例读同一个 suite：确认真的落盘了。
        XCTAssertTrue(UserDefaultsSettingsStore(defaults: defaults).hasSeenOnboarding)
    }

    func testInMemoryStoreDefaultsToSeenSoRenderTestsAreNotCovered() async {
        let store = InMemorySettingsStore()
        XCTAssertTrue(store.hasSeenOnboarding)
        let fresh = InMemorySettingsStore(hasSeenOnboarding: false)
        XCTAssertFalse(fresh.hasSeenOnboarding)
        await fresh.setHasSeenOnboarding(true)
        XCTAssertTrue(fresh.hasSeenOnboarding)
    }

    // MARK: - 重看请求

    func testReplayRequestIsConsumedExactlyOnce() {
        _ = Onboarding.takeReplayRequest()
        Onboarding.markReplayPending()
        XCTAssertTrue(Onboarding.takeReplayRequest())
        XCTAssertFalse(Onboarding.takeReplayRequest(), "消费过的请求不该让引导反复弹出")
    }

    // MARK: - 何时开始

    func testStartsOnFirstOpenOnceTheContainerIsReady() {
        // 容器还没注入（窗口先用空容器建根视图）：先不弹，也不能当成看过。
        XCTAssertFalse(Onboarding.shouldStart(replayRequested: false, hasSeen: nil,
                                              finishedThisRun: false, isTestHost: false))
        // 容器到位、从没看过：弹。
        XCTAssertTrue(Onboarding.shouldStart(replayRequested: false, hasSeen: false,
                                             finishedThisRun: false, isTestHost: false))
        // 看过了 / 这次运行里已经看完：不再自动弹。
        XCTAssertFalse(Onboarding.shouldStart(replayRequested: false, hasSeen: true,
                                              finishedThisRun: false, isTestHost: false))
        XCTAssertFalse(Onboarding.shouldStart(replayRequested: false, hasSeen: false,
                                              finishedThisRun: true, isTestHost: false))
    }

    func testReplayAlwaysStartsAndTestHostNeverAutoStarts() {
        XCTAssertTrue(Onboarding.shouldStart(replayRequested: true, hasSeen: true,
                                             finishedThisRun: true, isTestHost: true))
        XCTAssertFalse(Onboarding.shouldStart(replayRequested: false, hasSeen: false,
                                              finishedThisRun: false, isTestHost: true))
    }

    // MARK: - 离屏渲染

    func testOverlayRendersOffscreenForEveryStep() throws {
        let steps = Onboarding.steps
        for index in steps.indices {
            let view = OnboardingOverlay(steps: steps,
                                         index: index,
                                         anchors: sampleAnchors,
                                         size: windowSize,
                                         onNext: {},
                                         onSkip: {},
                                         cardHeightOverride: 150)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(windowSize.width))
            XCTAssertEqual(image.height, Int(windowSize.height))
        }
    }
}
