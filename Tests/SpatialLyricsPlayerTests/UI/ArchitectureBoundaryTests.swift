import XCTest
@testable import SpatialLyricsPlayer

/// 分层边界的可执行断言。
///
/// 单 App Target 无法用模块系统强制分层，因此把 `Scripts/architecture-lint.sh`
/// 的规则在测试里再跑一遍，保证 CI 与本地开发同一套标准。
final class ArchitectureBoundaryTests: XCTestCase {

    private static let repositoryRoot = RepositoryRoot.locate()

    private func swiftFiles(in relativePath: String) throws -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    func testPresentationLayersNeverReferenceConcreteSources() throws {
        let forbidden = ["MockPlaybackSource", "MockPlaybackSession", "AVPlayer", "URLSession"]
        for layer in ["UI", "Overlay", "MenuBar", "Privacy"] {
            for file in try swiftFiles(in: layer) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    XCTAssertFalse(source.contains(token), "\(layer)/\(file.lastPathComponent) 出现 \(token)")
                }
            }
        }
    }

    func testNoBareDispatchQueueInProductionCode() throws {
        for layer in ["App", "Core", "Sources", "Playback", "Lyrics", "Persistence", "DI", "Shared"] {
            for file in try swiftFiles(in: layer) {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    source.contains("DispatchQueue"),
                    "\(file.lastPathComponent) 使用了裸 DispatchQueue"
                )
            }
        }
    }

    /// macOS 27.3 的原生通知回调在 MainActor.assumeIsolated 的执行器检查中崩溃；
    /// 系统回调必须显式 hop 到 actor，单纯在主线程并不构成 actor 上下文。
    func testNativeCallbacksDoNotAssumeActorExecutor() throws {
        for layer in ["Morph", "Spatial", "Integration"] {
            for file in try swiftFiles(in: layer) {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(source.contains("MainActor." + "assumeIsolated"),
                               "\(file.lastPathComponent) 系统回调应使用 Task { @MainActor in ... }")
            }
        }
    }

    func testPlaybackCoreHasNoConcreteSourceTypes() throws {
        for file in try swiftFiles(in: "Playback") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("MockPlaybackSource"))
            XCTAssertFalse(source.contains("ScriptedSourceProvider"))
        }
    }

    func testWidgetSourceNeverImportsPlaybackModuleFiles() throws {
        for file in try swiftFiles(in: "SpatialLyricsWidgets") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("PlaybackEngine"), "小组件不得直接持有播放引擎")
            XCTAssertFalse(source.contains("SourceRegistry"), "小组件不得持有源注册表")
        }
    }

    func testSharedFolderHasNoAppOnlyDependencies() throws {
        for file in try swiftFiles(in: "Shared") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("import AppKit"))
            XCTAssertFalse(source.contains("import SwiftData"))
        }
    }
}
