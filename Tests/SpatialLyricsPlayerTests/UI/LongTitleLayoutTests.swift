import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 超长标题/歌手的排版。
///
/// 真实内容里很常见：B 站标题动辄三四十个字（带「」《》与 emoji）。
/// 单测看不到排版，这里用离屏渲染检查**是否被截断**，而不是把容器撑破。
///
/// 判据：渲染宽度不能超过给定容器宽度——超了说明这一行把布局推开了。
@MainActor
final class LongTitleLayoutTests: XCTestCase {

    private let longTitle = String(repeating: "一个非常非常长的标题", count: 6)
    private let longArtist = String(repeating: "合唱歌手名单", count: 8)

    private func track() -> Track {
        Track(sourceID: SourceID(rawValue: "bili"), externalID: "BV1long",
              title: longTitle, artist: longArtist, album: nil, duration: 3725)
    }

    /// 复用抽屉里的行：它是超长文本最容易被撑开的地方。
    func testQueueRowDoesNotOverflowContainer() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()
        let track = track()
        model.track = track

        let width: CGFloat = 328
        let view = AuxiliaryDrawer(model: model, panel: .queue, onClose: {})
            .environment(\.app, container)
            .frame(width: width, height: 480)

        let renderer = ImageRenderer(content: view.background(Color(white: 0.12)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
        XCTAssertLessThanOrEqual(image.size.width, width + 1,
                                 "超长标题把容器撑宽了（\(image.size.width) > \(width)）")
    }
}
