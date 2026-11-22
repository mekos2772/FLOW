import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 歌单弹层的离屏渲染探针。
///
/// 这个弹层原来没有标题、顶部空 200pt、关闭按钮吊在右下角。
/// 改为"标题行 + 右上角 ×"后，这里渲染一张图供人眼复核——
/// 不需要打开弹层，也不影响使用者当前桌面。
@MainActor
final class PlaylistSheetRenderProbe: XCTestCase {

    func testRenderEmptyPlaylistSheet() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let view = PlaylistView(isPresented: .constant(true))
            .environment(\.app, container)
            .background(Color(white: 0.15))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("playlist-sheet.png"))

        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }
}
