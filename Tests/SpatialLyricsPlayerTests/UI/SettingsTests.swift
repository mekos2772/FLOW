import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

// 设置：备份导入导出与渲染探针。

@MainActor
final class SettingsTests: XCTestCase {

    private func backup() -> SettingsBackup {
        SettingsBackup(enableNetwork: true,
                       privacyMode: true,
                       lyricFontSize: 22,
                       lyricLineSpacing: 12,
                       floatingOpacity: 0.7,
                       defaultShape: LyricsShape.board.rawValue,
                       autoAvoidEnabled: false,
                       engineVolume: 0.4,
                       fadeOutMillis: 300)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let original = backup()
        let data = try SettingsBackup.encode(original)
        let decoded = try SettingsBackup.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testSnapshotReflectsLiveSettings() {
        let settings = InMemorySettingsStore(privacyMode: true, lyricFontSize: 19)
        let snapshot = SettingsBackup.snapshot(from: settings)

        XCTAssertTrue(snapshot.privacyMode)
        XCTAssertEqual(snapshot.lyricFontSize, 19)
        XCTAssertEqual(snapshot.version, SettingsBackup.currentVersion)
    }

    func testDecodeRejectsFutureVersion() throws {
        var future = backup()
        future.version = SettingsBackup.currentVersion + 1
        let data = try SettingsBackup.encode(future)

        XCTAssertThrowsError(try SettingsBackup.decode(data)) { error in
            XCTAssertEqual(error as? SettingsBackup.RestoreError, .unsupportedVersion(future.version))
        }
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try SettingsBackup.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? SettingsBackup.RestoreError, .malformed)
        }
    }

    func testApplyClampsOutOfRangeValues() async {
        var rogue = backup()
        rogue.lyricFontSize = 999       // 备份文件被手工改过
        rogue.floatingOpacity = 5
        rogue.fadeOutMillis = -30

        let settings = InMemorySettingsStore()
        await rogue.apply(to: settings)

        XCTAssertEqual(settings.lyricFontSize, 30, "字号必须夹到 30")
        XCTAssertEqual(settings.floatingOpacity, 1, "透明度必须夹到 1")
        XCTAssertEqual(settings.fadeOutMillis, 0, "淡出时长不能为负")
    }

    func testApplyKeepsShapeWhenUnknown() async {
        var rogue = backup()
        rogue.defaultShape = "hexagon"  // 不存在的形态
        let settings = InMemorySettingsStore()
        let before = settings.defaultShape

        await rogue.apply(to: settings)

        XCTAssertEqual(settings.defaultShape, before, "未知形态应保留原值，而不是写入脏数据")
    }
}
/// 设置页的**离屏**渲染探针。
///
/// 目的：不打开任何窗口、不移动鼠标，也能看到分区真实排版。
/// 产物在 `NSTemporaryDirectory()/flow-settings/`，供人眼复核。
///
/// 起因为"设置页那几行只读文字长得像控件"的改造：布局必须在改完之后真的看一眼，
/// 但开发机上只有一块屏，开窗口会打断使用者。
@MainActor
final class SettingsRenderProbe: XCTestCase {

    private func render(_ view: some View, size: CGSize, dark: Bool = true) throws -> NSBitmapImageRep {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(dark ? Color(white: 0.13) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func write(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderGeneralAndPlaybackPanes() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let size = CGSize(width: 660, height: 620)

        let general = try render(GeneralPane().environment(\.app, container), size: size)
        try write(general, name: "general")

        let playback = try render(PlaybackPane().environment(\.app, container), size: size)
        try write(playback, name: "playback")

        XCTAssertGreaterThan(general.pixelsHigh, 0)
        XCTAssertGreaterThan(playback.pixelsHigh, 0)
    }
}
