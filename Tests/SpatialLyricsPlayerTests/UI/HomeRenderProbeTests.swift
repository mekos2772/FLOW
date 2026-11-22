import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 首页内容区的离屏渲染。搜索与导航属于 ExpandedPlayerView，
/// 这里分别检查页面标题和居中空态，避免整屏留白影响断言。
@MainActor
final class HomeRenderProbeTests: XCTestCase {

    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-home-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// 独立采样内容区域，标题或刷新按钮不能代替空态通过检查。
    private func inkRatio(_ rep: NSBitmapImageRep, rect: CGRect) -> Double {
        guard let bitmap = rep.bitmapData else { return 0 }
        var ink = 0
        let total = Int(rect.width * rect.height)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = y * rep.bytesPerRow + x * 4
                if bitmap[offset] > 60 || bitmap[offset + 1] > 60 || bitmap[offset + 2] > 60 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    func testHomeRendersWithVisibleContent() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()

        let rep = try render(
            OnlineHomeView(model: model).environment(\.app, container),
            size: CGSize(width: 720, height: 620)
        )
        try write(rep, name: "home")
        XCTAssertGreaterThan(inkRatio(rep, rect: CGRect(x: 0, y: 0, width: 240, height: 90)),
                             0.01, "首页标题未显示")
        XCTAssertGreaterThan(inkRatio(rep, rect: CGRect(x: 340, y: 560, width: 760, height: 240)),
                             0.01, "首页居中空态未显示")
    }
}
