import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

// 歌词相关的**离屏渲染**探针。
//
// 三个文件合并而来（`LyricScrollRenderTests` / `LyricLayoutProbe` / `FloatingLyricFitProbe`）：
// 它们都在做同一件事——把视图渲染成位图，用亮度分布断言或导出 PNG 供人眼复核。
// 放在一起以后，"哪些是契约、哪些只是导出看图的"一眼能分出来：
// 带 `XCTAssert` 的是契约，其余是探针。


@testable import SpatialLyricsPlayer

/// Apple Music 风格歌词的实际渲染：截图级验证，而不只是布局数字。
@MainActor
final class LyricScrollRenderTests: XCTestCase {

    private let lines: [LyricLine] = [
        LyricLine(start: 0, text: "第一句歌词在这里"),
        LyricLine(start: 6, text: "第二句稍微长一点点"),
        LyricLine(start: 12, text: "第三句：这里是当前高亮的一行"),
        LyricLine(start: 18, text: "第四句"),
        LyricLine(start: 24, text: "第五句继续往下"),
        LyricLine(start: 30, text: "第六句也在这里"),
    ]

    private func model(currentIndex: Int) -> MorphPresentationModel {
        let model = MorphPresentationModel()
        model.lyricState = .loaded
        model.lyric = LyricEngine.Snapshot(
            current: lines[currentIndex],
            next: currentIndex + 1 < lines.count ? lines[currentIndex + 1] : nil,
            previous: currentIndex > 0 ? lines[currentIndex - 1] : nil,
            progressInLine: 0.4,
            index: currentIndex,
            totalLines: lines.count,
            unsyncedLines: [])
        return model
    }

    /// 渲染当前行居中、上下文淡出的滚动歌词。
    ///
    /// 这个视图直接用 `model.lyric.index` 驱动，不依赖 LyricEngine 文档，
    /// 所以可以在测试里注入确定的数据。
    func testRendersCurrentLineProminently() throws {
        // 给一个真实的深色底：ImageRenderer 默认透明，白字压透明会"看不见"，
        // 那样量出来的亮度和产品里看到的完全不是一回事。
        let view = LyricScrollView(model: model(currentIndex: 2), providedLines: lines)
            .frame(width: 700, height: 380)
            .background(Color(white: 0.09))
            .environment(\.colorScheme, .dark)
        let bitmap = try render(view)

        // 当前行比其余行更大更亮：统计"亮像素"的纵向分布，
        // 当前行所在的中段应该明显更亮。
        let rows = brightnessProfile(bitmap)
        XCTAssertFalse(rows.isEmpty)
        let middle = rows.dropFirst(rows.count / 3).prefix(rows.count / 3)
        let averageMiddle = middle.reduce(0, +) / Double(max(middle.count, 1))
        let averageAll = rows.reduce(0, +) / Double(rows.count)
        XCTAssertGreaterThan(averageMiddle, averageAll * 1.05,
                             "当前行区域应比整体更亮（放大 + 提亮）")

        if let dir = ProcessInfo.processInfo.environment["SLP_TEST_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("lyrics-apple-music.png"))
        }
    }

    func testDifferentCurrentLinesProduceDifferentRenders() throws {
        let a = try render(LyricScrollView(model: model(currentIndex: 1), providedLines: lines)
            .frame(width: 700, height: 380).background(Color(white: 0.09))
            .environment(\.colorScheme, .dark))
        let b = try render(LyricScrollView(model: model(currentIndex: 3), providedLines: lines)
            .frame(width: 700, height: 380).background(Color(white: 0.09))
            .environment(\.colorScheme, .dark))
        XCTAssertNotEqual(a.tiffRepresentation, b.tiffRepresentation,
                          "换行必须真的换画面，否则滚动/高亮没生效")
    }

    // MARK: - 工具

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// 每行像素的平均亮度（0…1）。
    private func brightnessProfile(_ bitmap: NSBitmapImageRep) -> [Double] {
        var rows: [Double] = []
        for y in 0..<bitmap.pixelsHigh {
            var sum = 0.0
            var count = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sum += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                count += 1
            }
            guard count > 0 else { continue }
            rows.append(sum / Double(count))
        }
        return rows
    }
}

@testable import SpatialLyricsPlayer

/// 歌词版式的离屏渲染探针（总是写盘，不需要环境变量）。
///
/// 重构点击命中之后，行高改由布局决定、视图强制按它排版——
/// 外观必须真的看一眼，确认没有变挤或变松。
@MainActor
final class LyricLayoutProbe: XCTestCase {

    private let lines: [LyricLine] = (0..<10).map {
        LyricLine(start: Double($0) * 6,
                  text: "第\($0 + 1)句歌词，长度略有不同 \(String(repeating: "啊", count: $0 % 3))")
    }

    /// 逐字时间轴的一行：用来核对"唱到一半"的遮罩位置对不对。
    private var karaokeLines: [LyricLine] {
        var copy = lines
        copy[4] = LyricLine(start: 24, end: 30, text: "逐字点亮的这一行歌词",
                            segments: [
                                LyricSegment(start: 24, text: "逐字"),
                                LyricSegment(start: 25, text: "点亮"),
                                LyricSegment(start: 26, text: "的这一行"),
                                LyricSegment(start: 28, text: "歌词"),
                            ])
        return copy
    }

    func testRenderAppleMusicLyrics() throws {
        let model = MorphPresentationModel()
        model.lyricState = .loaded
        let karaoke = karaokeLines
        model.lyric = LyricEngine.Snapshot(
            current: karaoke[4], next: karaoke[5], previous: karaoke[3],
            progressInLine: 0.4, time: 25.5, index: 4, totalLines: karaoke.count, unsyncedLines: [])

        let view = LyricScrollView(model: model, providedLines: karaoke)
            .frame(width: 700, height: 380)
            .background(Color(white: 0.09))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-lyrics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("apple-music-lyrics.png"))
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    /// 宽度 × 字号的对照矩阵：同一份歌词在极端尺寸下的版式。
    ///
    /// 目的不是"好看"，而是找**真问题**：长句是否被裁、当前行是否仍居中、
    /// 窄窗口下内边距是否挤掉正文。
    func testRenderLayoutMatrix() throws {
        let longLine = "这一句特别特别长，长到在窄窗口里一定要折行才能放下，否则就被裁掉了"
        var texts: [LyricLine] = (0..<8).map {
            LyricLine(start: Double($0) * 6, text: "第\($0 + 1)句 常规长度歌词")
        }
        texts[3] = LyricLine(start: 18, text: longLine)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-lyrics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for width in [320.0, 420.0, 640.0, 900.0] {
            for fontSize in [15.0, 17.0, 22.0] {
                let model = MorphPresentationModel()
                model.lyricState = .loaded
                model.lyric = LyricEngine.Snapshot(
                    current: texts[3], next: texts[4], previous: texts[2],
                    progressInLine: 0.3, time: 18.5, index: 3,
                    totalLines: texts.count, unsyncedLines: [])
                let view = LyricScrollView(model: model, providedLines: texts)
                    .frame(width: width, height: 360)
                    .background(Color(white: 0.09))
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                // 探针也要有断言，否则"渲染出一张全黑图"照样通过。
                // 这里守住两件事：尺寸确实是请求的尺寸；画面不是纯色。
                XCTAssertEqual(rep.pixelsWide, Int(width), "宽度必须等于请求的宽度")
                XCTAssertEqual(rep.pixelsHigh, 360, "高度必须等于请求的高度")
                XCTAssertTrue(hasContent(rep), "\(Int(width))pt / \(Int(fontSize))pt 这一格渲染成了空白")
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(
                    "matrix-w\(Int(width))-f\(Int(fontSize)).png"))
            }
        }
    }

    /// 画面里是否有内容：统计"与背景色明显不同"的像素比例。
    private func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        let step = max(rep.pixelsWide / 40, 1)
        var differing = 0
        var total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if color.brightnessComponent > 0.35 { differing += 1 }
            }
        }
        guard total > 0 else { return false }
        return Double(differing) / Double(total) > 0.01
    }
}

@testable import SpatialLyricsPlayer

/// 渲染探针：把四种悬浮排布铺进真实尺寸矩阵，导出 PNG 到
/// `NSTemporaryDirectory()/flow-fit/` 供人眼复核。断言只保证"能渲染、不崩"。
@MainActor
final class FloatingLyricFitProbe: XCTestCase {

    private func model(line: String, next: String?, previous: String?) -> MorphPresentationModel {
        let model = MorphPresentationModel()
        model.morphology = .capsule
        model.track = Track(sourceID: SourceID("probe"), externalID: "x",
                            title: "夜曲", artist: "周杰伦", album: nil, duration: 231)
        model.lyric = LyricEngine.Snapshot(
            current: LyricLine(start: 10, text: line),
            next: next.map { LyricLine(start: 20, text: $0) },
            previous: previous.map { LyricLine(start: 0, text: $0) },
            progressInLine: 0.4, index: 3, totalLines: 40, unsyncedLines: [])
        return model
    }

    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    func testFloatingLyricsAcrossCardSizes() throws {
        let line = "用力到處扣扣 花掉所有摳摳 錢買不到絕活"
        let sizes: [(String, LyricsShape, CGSize)] = [
            ("capsule-min", .capsule, PlayerMorphology.capsule.geometry.minimumSize),
            ("capsule-preferred", .capsule, PlayerMorphology.capsule.geometry.preferredSize),
            ("capsule-wide", .capsule, CGSize(width: 640, height: 56)),
            ("doubleLine-preferred", .doubleLine, CGSize(width: 392, height: 76)),
            ("doubleLine-wide", .doubleLine, CGSize(width: 640, height: 76)),
            ("board-preferred", .board, CGSize(width: 392, height: 152)),
            ("board-wide", .board, CGSize(width: 640, height: 152)),
            ("board-tall", .board, CGSize(width: 392, height: 200)),
            ("edge-min", .edge, PlayerMorphology.edge.geometry.minimumSize),
            ("edge-wide", .edge, CGSize(width: 900, height: 34)),
            ("capsule-narrow-long", .capsule, CGSize(width: 240, height: 44)),
            ("board-narrow", .board, CGSize(width: 240, height: 152)),
        ]
        // 固定写进临时目录：`xcodebuild test` 的进程环境不会透传到测试宿主，
        // 走环境变量开关反而拿不到。这是开发探针，产物本来就不进仓库。
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("flow-fit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, shape, size) in sizes {
            let model = model(line: line, next: "請你 不要到處叩叩", previous: "我的念頭不太囉唆 限時間能入座")
            let view = Group {
                switch shape {
                case .capsule: CapsuleLyricsView(model: model) {}
                case .doubleLine: DoubleLineLyricsView(model: model) {}
                case .board: BoardLyricsView(model: model) {}
                case .edge: EdgeLyricsView(model: model, edge: .top) {}
                }
            }
            .environment(\.colorScheme, .dark)
            let bitmap = try render(view, size: size)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("fit-\(name).png"))
            }
        }
    }
}
