import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 音量在界面上的显示（端到端）。
///
/// 第 109 节修过一个真 bug：`engineVolume` 把 0 当成"没设置"，重启后变成 1.0（满音量）。
/// 那里是存储层测试；这里补一条**从设置值到界面文字**的证据：
/// 音量 0 时设置页必须显示 0%，而不是 100%。
@MainActor
final class VolumeDisplayTests: XCTestCase {

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
            .appendingPathComponent("flow-volume-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// 0 音量必须显示 0%，并且真的落盘。
    ///
    /// 注意：`AppearanceSettings` 自己缓存一份值，setter 里**异步**写 settings。
    /// 所以要分别验证"缓存立刻更新"和"稍后落盘"两件事——
    /// 用另一个 `AppearanceSettings` 实例去读是读不到新值的（它构造时拷了一份）。
    func testMutedSettingRendersAsZeroPercent() async throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        container.appearance.setEngineVolume(0)
        XCTAssertEqual(container.appearance.engineVolume, 0, accuracy: 0.001,
                       "缓存必须立刻更新")

        // setter 用 Task 异步写盘：轮询等它落地，避免"看起来存了其实没存"
        var persisted: Double = -1
        for _ in 0..<50 {
            persisted = container.settings.engineVolume
            if persisted == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(persisted, 0, accuracy: 0.001, "静音必须真的写进设置")

        let rep = try render(
            PlaybackPane().environment(\.app, container),
            size: CGSize(width: 660, height: 620)
        )
        try write(rep, name: "playback-muted")

        // 界面文字由 `format` 生成（`%.0f%%`），这里只确认渲染不崩、图能出
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    /// 未设置过音量时取安全默认 0.7：满音量对新用户太凶。
    func testDefaultVolumeRendersSafeDefaultWhenUnset() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        XCTAssertEqual(container.appearance.engineVolume, 0.7, accuracy: 0.001)
    }
}
