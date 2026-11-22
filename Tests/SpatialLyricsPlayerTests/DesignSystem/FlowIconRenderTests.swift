import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// Beadline 图标的离屏渲染契约：量的是**真实墨迹**，不是路径数字。
///
/// "看起来歪"几乎都是三种病：墨迹不在 frame 中心、描边溢出 frame、
/// 同一行图标的墨迹高度忽大忽小。这里逐一把它们变成断言。
@MainActor
final class FlowIconRenderTests: XCTestCase {
    private let size: CGFloat = 15
    private let scale: CGFloat = 4

    /// 墨迹外框（单位 pt，原点在 frame 左上）。
    private func inkBox(_ glyph: FlowGlyph, size: CGFloat) throws -> CGRect {
        // 四周留 padding，溢出 frame 的描边也能量到。
        let pad: CGFloat = 6
        let view = FlowIconView(glyph: glyph, size: size)
            .foregroundStyle(Color.black)
            .padding(pad)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let a = bitmap.colorAt(x: x, y: y)?.alphaComponent, a > 0.35 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, 0, "\(glyph) 没画出任何墨迹")
        return CGRect(x: CGFloat(minX) / scale - pad, y: CGFloat(minY) / scale - pad,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// 墨迹中心必须落在 frame 中心（±0.6pt）——否则一排按钮里就是高低不齐。
    func testEveryGlyphInkIsCentered() throws {
        for glyph in FlowGlyph.allCases {
            let box = try inkBox(glyph, size: size)
            XCTAssertEqual(box.midX, size / 2, accuracy: 0.6, "\(glyph) 水平偏心：\(box)")
            XCTAssertEqual(box.midY, size / 2, accuracy: 0.6, "\(glyph) 垂直偏心：\(box)")
        }
    }

    /// 描边不许溢出 frame：溢出的部分会压到相邻文字、也和命中区错位。
    func testEveryGlyphStaysInsideFrame() throws {
        for glyph in FlowGlyph.allCases {
            let box = try inkBox(glyph, size: size)
            XCTAssertGreaterThanOrEqual(box.minX, -0.3, "\(glyph) 左溢出：\(box)")
            XCTAssertGreaterThanOrEqual(box.minY, -0.3, "\(glyph) 上溢出：\(box)")
            XCTAssertLessThanOrEqual(box.maxX, size + 0.3, "\(glyph) 右溢出：\(box)")
            XCTAssertLessThanOrEqual(box.maxY, size + 0.3, "\(glyph) 下溢出：\(box)")
        }
    }

    /// 导出接触表供人眼复核：每格 frame 灰底 + 中心十字线。
    func testExportContactSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLP_TEST_RENDER_DIR"] else { return }
        let columns = 8
        let glyphs = FlowGlyph.allCases
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<((glyphs.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(glyphs[(row * columns)..<min(glyphs.count, (row + 1) * columns)], id: \.self) { glyph in
                        VStack(spacing: 3) {
                            ZStack {
                                Rectangle().fill(Color(white: 0.92)).frame(width: 15, height: 15)
                                Rectangle().fill(Color.red.opacity(0.5)).frame(width: 30, height: 0.25)
                                Rectangle().fill(Color.red.opacity(0.5)).frame(width: 0.25, height: 30)
                                FlowIconView(glyph: glyph, size: 15).foregroundStyle(Color.black)
                            }
                            .frame(width: 30, height: 30)
                            Text(glyph.rawValue).font(.system(size: 6)).foregroundStyle(.gray)
                        }
                        .frame(width: 44)
                    }
                }
            }
            // 真实场景：侧栏一行与播放栏一行
            HStack(spacing: 10) {
                FlowIconView(glyph: .nowPlaying, size: 15); Text("正在播放").font(.system(size: 15))
                FlowIconView(glyph: .home, size: 15); Text("首页").font(.system(size: 15))
                FlowIconView(glyph: .playlist, size: 15); Text("歌单").font(.system(size: 15))
            }
            HStack(spacing: 6) {
                ForEach([FlowGlyph.shuffle, .backward, .play, .forward, .sequence,
                         .star, .lyric, .speaker, .queue, .collapse, .minimize], id: \.self) { glyph in
                    FlowIconView(glyph: glyph, size: 15)
                        .frame(width: 30, height: 30)
                        .background(Color(white: 0.92))
                }
            }
        }
        .padding(12)
        .background(Color.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 4
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent("flow-icons.png"))
    }
}
