import XCTest
@testable import SpatialLyricsPlayer

/// 换源不改播放层。
///
/// 同一段场景脚本分别跑在 Mock 源与 Scripted 源上，播放内核必须给出结构一致的状态序列。
/// 两个源没有共享任何实现代码。
@MainActor
final class SourceSubstitutionTests: XCTestCase {

    private func runScenario(on harness: EngineHarness) async -> [String] {
        var trace: [String] = []

        await harness.engine.load(harness.tracks[0], autoplay: true)
        trace.append(harness.engine.state.debugLabel)

        harness.clock.advance(by: .seconds(7))
        await harness.engine.pause()
        trace.append(harness.engine.state.debugLabel)

        await harness.engine.play()
        trace.append(harness.engine.state.debugLabel)

        await harness.engine.skip(.next)
        trace.append(harness.engine.state.debugLabel)

        await harness.engine.stop()
        trace.append(harness.engine.state.debugLabel)

        return trace
    }

    func testScriptedProviderProducesIdenticalTrace() async {
        let mockHarness = EngineHarness()
        let scriptedHarness = EngineHarness(provider: ScriptedSourceProvider())

        let mockTrace = await runScenario(on: mockHarness)
        let scriptedTrace = await runScenario(on: scriptedHarness)

        XCTAssertEqual(mockTrace, ["playing", "paused(user)", "playing", "playing", "idle"])
        XCTAssertEqual(mockTrace, scriptedTrace)
        XCTAssertEqual(mockHarness.coordinator.activeSourceID, .mock)
        XCTAssertEqual(scriptedHarness.coordinator.activeSourceID, SourceID("scripted"))
    }

    /// 结构性证据：分层规则由 `Scripts/architecture-lint.sh` 检查。
    ///
    /// 以前这里自己维护了一份"禁用词清单"，脚本里另有一份——两份迟早漂移
    /// （实测：测试禁 `Playback/` 用 `AVPlayer`，脚本却没禁）。
    /// 现在**只认脚本**：规则一处维护，测试只验证它确实通过。
    func testArchitectureLintPasses() throws {
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/architecture-lint.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "架构扫描脚本不见了")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0,
                       "架构扫描未通过：\n\(output)")
    }

    static var repositoryRoot: URL {
        RepositoryRoot.locate()
    }
}
