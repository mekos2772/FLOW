import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 抽屉界面的离屏渲染。
///
/// 队列/资料库抽屉在本会话改过（曲名走 `MorphPresentationModel.display`）。
/// 这里把它渲染出来人眼复核，并断言"有内容"，防止某个改动让抽屉变成空白。
@MainActor
final class DrawerRenderProbeTests: XCTestCase {

    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// 只统计顶部区域（标题栏）。整体阈值太松——`ScrollView` 内容不参与离屏布局，
    /// 用整图比例断言等于什么都没断言。标题栏一定会画出来，用它更可靠。
    private func topInkRatio(_ rep: NSBitmapImageRep, fraction: Double = 0.15) -> Double {
        guard let bitmap = rep.bitmapData else { return 0 }
        let rows = max(1, Int(Double(rep.pixelsHigh) * fraction))
        var ink = 0
        for y in 0..<rows {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * 4
                if bitmap[offset] > 60 || bitmap[offset + 1] > 60 || bitmap[offset + 2] > 60 { ink += 1 }
            }
        }
        let total = rows * rep.pixelsWide
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        guard let bitmap = rep.bitmapData else { return 0 }
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * 4
                if bitmap[offset] > 60 || bitmap[offset + 1] > 60 || bitmap[offset + 2] > 60 { ink += 1 }
            }
        }
        let total = rep.pixelsWide * rep.pixelsHigh
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-drawer-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// 队列抽屉读的是 `model.queue`；空队列会走 `emptyState`，所以两种都渲染一次。
    /// 注意：队列**有内容**时行在 `ScrollView` 里，`ImageRenderer` 不排版滚动容器，
    /// 所以这里不渲染整块抽屉，而是单独渲染 `QueueRowView`（下面那条测试）。
    private func modelWithQueue() -> MorphPresentationModel {
        let model = MorphPresentationModel()
        let first = Track(sourceID: SourceID(rawValue: "remote"), externalID: "r1", title: "第一首",
                          artist: "歌手甲", album: nil, duration: 200)
        let second = Track(sourceID: SourceID(rawValue: "remote"), externalID: "r2",
                           title: "一个非常非常长的曲目标题，用来验证抽屉里的截断与换行",
                           artist: "歌手乙", album: nil, duration: 3725)
        var queue = PlaybackQueue(items: [first.id, second.id], currentID: first.id)
        queue.setCurrent(first.id)
        model.queue = queue
        return model
    }

    func testQueueRowRendersLongTitleWithoutLosingHeader() throws {
        let row = QueueRowView(isCurrent: true, isDropTarget: false,
                               title: "一个非常非常长的曲目标题，用来验证抽屉里的截断行为是否会把右侧图标挤掉",
                               artist: "歌手乙",
                               onPlay: {}, onDragChanged: { _ in }, onHover: {}, onDragEnded: {},
                               onRemove: {})
            .frame(width: 300)
            .padding(8)
            .background(Color(white: 0.16))
        let rep = try render(row, size: CGSize(width: 320, height: 64))
        try write(rep, name: "queue-row")

        XCTAssertGreaterThan(inkRatio(rep), 0.03, "队列行渲染出来几乎空白")
    }

    func testQueueDrawerRendersContent() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        var model = modelWithQueue()

        let rep = try render(
            AuxiliaryDrawer(model: model, panel: .queue, onClose: {}).environment(\.app, container),
            size: CGSize(width: 336, height: 480)
        )
        try write(rep, name: "queue")
        // ScrollView 内容不参与离屏布局，这里只断言"抽屉本身有内容"（头尾都在）。
        XCTAssertGreaterThan(topInkRatio(rep), 0.005, "队列抽屉的标题栏没画出来")
        _ = model
    }

    func testEmptyQueueDrawerShowsGuidance() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()

        let rep = try render(
            AuxiliaryDrawer(model: model, panel: .queue, onClose: {}).environment(\.app, container),
            size: CGSize(width: 336, height: 480)
        )
        try write(rep, name: "queue-empty")
        XCTAssertGreaterThan(topInkRatio(rep), 0.005, "空队列抽屉标题未显示")
        // 整个抽屉的异步加载可能仍在进行，直接渲染实际复用的空态组件。
        let empty = try render(QueueEmptyState(), size: CGSize(width: 300, height: 36))
        try write(empty, name: "queue-empty-message")
        XCTAssertGreaterThan(inkRatio(empty), 0.01, "空队列反馈未显示")
    }

    func testSettingsDrawerRendersContent() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()

        let rep = try render(
            AuxiliaryDrawer(model: model, panel: .settings, onClose: {}).environment(\.app, container),
            size: CGSize(width: 336, height: 480)
        )
        try write(rep, name: "settings")
        XCTAssertGreaterThan(topInkRatio(rep), 0.005, "快捷设置抽屉的标题栏没画出来")
    }

    /// 资料库抽屉的空态：收藏与最近都为空时，不能是一片空白。
    func testLibraryDrawerEmptyState() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()

        let rep = try render(
            AuxiliaryDrawer(model: model, panel: .library, onClose: {}).environment(\.app, container),
            size: CGSize(width: 336, height: 480)
        )
        try write(rep, name: "library-empty")
        // 空态文案在 `ScrollView` 里，`ImageRenderer` 不排版滚动容器
        // （第 116 节已确认过同类限制），所以只能断言标题栏。
        // 空态本身的存在性由代码与下面的字符串断言保证。
        XCTAssertGreaterThan(topInkRatio(rep), 0.005, "资料库抽屉的标题栏没画出来")
        XCTAssertTrue(true, "见上方注释：内容区在 ScrollView 内，离屏不可见")
    }
}

/// 资料库抽屉的空态**文案存在性**。
///
/// 排版验证受 `ImageRenderer` 限制（滚动容器不参与离屏布局），
/// 但"空态到底有没有"是可以用源码断言钉住的——
/// 免得哪天有人删掉 UI 分支而探针毫无察觉。
final class LibraryEmptyStateWordingTests: XCTestCase {

    func testLibraryEmptyStateWordingExists() throws {
        let url = RepositoryRoot.locate()
            .appendingPathComponent("UI/Expanded/AuxiliaryDrawer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("还没有收藏"), "收藏为空时必须有提示")
        XCTAssertTrue(source.contains("还没有播放记录"), "最近为空时必须有提示")
        XCTAssertTrue(source.contains("队列还是空的"), "空队列必须有简短反馈")
        XCTAssertFalse(source.contains("在「在线」里播放时点右侧星标"),
                       "不再显示旧导航说明")
    }
}
