import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

final class GitHubSourceDiscoveryTests: XCTestCase {

    private final class MockGitHubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.recordedRequests.append(request)
            let result = Self.handler?(request) ?? (404, [:], Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.local")!,
                statusCode: result.0,
                httpVersion: "HTTP/1.1",
                headerFields: result.1
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.2)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class MutableFlag: @unchecked Sendable {
        var value = true
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        MockGitHubProtocol.handler = nil
        MockGitHubProtocol.recordedRequests = []
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-github-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockGitHubProtocol.handler = nil
        MockGitHubProtocol.recordedRequests = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockGitHubProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testParseDirectRepositoryTargetFormats() {
        let slug = GitHubSourceDiscovery.parseDirectRepositoryTarget("maotoumao/MusicFreePlugins")
        XCTAssertEqual(slug, GitHubDirectTarget(owner: "maotoumao", repo: "MusicFreePlugins", branchHint: nil, filePathHint: nil))

        let gitSuffix = GitHubSourceDiscovery.parseDirectRepositoryTarget("https://github.com/owner-a/repo_b.git")
        XCTAssertEqual(gitSuffix, GitHubDirectTarget(owner: "owner-a", repo: "repo_b", branchHint: nil, filePathHint: nil))

        let blob = GitHubSourceDiscovery.parseDirectRepositoryTarget("https://github.com/qwerwhr/musicfree-plugins/blob/main/CCTV%E5%90%AC%E9%9F%B3.js")
        XCTAssertEqual(blob, GitHubDirectTarget(owner: "qwerwhr", repo: "musicfree-plugins", branchHint: "main", filePathHint: "CCTV听音.js"))

        let raw = GitHubSourceDiscovery.parseDirectRepositoryTarget("https://raw.githubusercontent.com/maotoumao/MusicFreePlugins/v0.1/dist/navidrome/index.js")
        XCTAssertEqual(raw, GitHubDirectTarget(owner: "maotoumao", repo: "MusicFreePlugins", branchHint: "v0.1", filePathHint: "dist/navidrome/index.js"))

        XCTAssertNil(GitHubSourceDiscovery.parseDirectRepositoryTarget("musicfree plugin"))
        XCTAssertNil(GitHubSourceDiscovery.parseDirectRepositoryTarget("   "))
        XCTAssertNil(GitHubSourceDiscovery.parseDirectRepositoryTarget("https://example.com/owner/repo"))
    }

    func testRepositorySearchAndInspectFiltersNoiseAndPreservesUnicodePaths() async throws {
        MockGitHubProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "FLOW-SpatialLyricsPlayer")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))

            if url.contains("/search/repositories") {
                let body = #"""
                {
                  "items": [
                    {
                      "full_name": "demo-org/audio-plugins",
                      "name": "audio-plugins",
                      "owner": { "login": "demo-org" },
                      "description": "Open source audio source configs",
                      "stargazers_count": 1280,
                      "default_branch": "main",
                      "updated_at": "2026-11-20T08:00:00Z",
                      "html_url": "https://github.com/demo-org/audio-plugins",
                      "topics": ["music", "plugins"]
                    }
                  ]
                }
                """#
                return (200, ["Content-Type": "application/json"], Data(body.utf8))
            }

            if url.contains("/repos/demo-org/audio-plugins/git/trees/main") {
                let body = #"""
                {
                  "truncated": false,
                  "tree": [
                    { "path": "package.json", "type": "blob", "size": 500 },
                    { "path": "tsconfig.json", "type": "blob", "size": 300 },
                    { "path": "webpack.config.js", "type": "blob", "size": 900 },
                    { "path": "node_modules/pkg/index.js", "type": "blob", "size": 200 },
                    { "path": "src/navidrome/utils.js", "type": "blob", "size": 400 },
                    { "path": "dist/navidrome/index.js", "type": "blob", "size": 4096 },
                    { "path": "CCTV听音.js", "type": "blob", "size": 2048 },
                    { "path": "QQ Vip.js", "type": "blob", "size": 1024 },
                    { "path": "examples/audius.flow.json", "type": "blob", "size": 1200 },
                    { "path": "plugins.json", "type": "blob", "size": 512 }
                  ]
                }
                """#
                return (200, ["Content-Type": "application/json"], Data(body.utf8))
            }

            return (404, [:], Data())
        }

        let discovery = GitHubSourceDiscovery(session: makeSession(), secrets: InMemorySecretStore())
        let repos = try await discovery.searchRepositories(query: "audio plugins")
        XCTAssertEqual(repos.count, 1)
        let repo = try XCTUnwrap(repos.first)
        XCTAssertEqual(repo.fullName, "demo-org/audio-plugins")
        XCTAssertEqual(repo.stars, 1280)
        XCTAssertEqual(repo.updatedAt, "2026-11-20")

        let configs = try await discovery.inspectRepository(repo)
        XCTAssertEqual(configs.map(\.path), [
            "plugins.json",
            "examples/audius.flow.json",
            "CCTV听音.js",
            "dist/navidrome/index.js",
            "QQ Vip.js",
        ])
        XCTAssertEqual(configs[0].kind, .subscriptionManifest)
        XCTAssertEqual(configs[1].kind, .jsonTemplateOrConfig)
        XCTAssertEqual(configs[3].displayName, "navidrome (index.js)")
        XCTAssertEqual(
            configs[2].rawURL.absoluteString,
            "https://raw.githubusercontent.com/demo-org/audio-plugins/main/CCTV%E5%90%AC%E9%9F%B3.js"
        )
        XCTAssertEqual(
            configs[4].rawURL.absoluteString,
            "https://raw.githubusercontent.com/demo-org/audio-plugins/main/QQ%20Vip.js"
        )
    }

    func testTruncatedTreeFallsBackToContentsAndEmptyRepoReturnsEmpty() async throws {
        MockGitHubProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/repos/demo/truncated/git/trees/main") {
                return (200, [:], Data(#"{"truncated":true,"tree":[]}"#.utf8))
            }
            if url == "https://api.github.com/repos/demo/truncated/contents?ref=main" {
                let body = #"""
                [
                  { "name": "package.json", "path": "package.json", "type": "file", "size": 100 },
                  { "name": "plugins.json", "path": "plugins.json", "type": "file", "size": 320 }
                ]
                """#
                return (200, [:], Data(body.utf8))
            }
            if url.contains("/repos/demo/truncated/contents/") {
                return (404, [:], Data())
            }
            if url.contains("/repos/demo/empty/git/trees/main") {
                return (409, [:], Data(#"{"message":"Git Repository is empty."}"#.utf8))
            }
            return (404, [:], Data())
        }

        let discovery = GitHubSourceDiscovery(session: makeSession(), secrets: InMemorySecretStore())
        let truncatedRepo = GitHubRepoCandidate(
            id: "demo/truncated", owner: "demo", name: "truncated", fullName: "demo/truncated",
            description: "", stars: 1, defaultBranch: "main", updatedAt: "",
            htmlURL: URL(string: "https://github.com/demo/truncated")!, topics: []
        )
        let fallbackItems = try await discovery.inspectRepository(truncatedRepo)
        XCTAssertEqual(fallbackItems.map(\.path), ["plugins.json"])

        let emptyRepo = GitHubRepoCandidate(
            id: "demo/empty", owner: "demo", name: "empty", fullName: "demo/empty",
            description: "", stars: 0, defaultBranch: "main", updatedAt: "",
            htmlURL: URL(string: "https://github.com/demo/empty")!, topics: []
        )
        let emptyItems = try await discovery.inspectRepository(emptyRepo)
        XCTAssertTrue(emptyItems.isEmpty)
    }

    func testManifestPreviewSupportsBOMJSONPAndRelativePaths() async throws {
        MockGitHubProtocol.handler = { _ in
            let payload = "\u{FEFF}cb({\"plugins\":[{\"name\":\"Navi JS\",\"version\":\"0.1.0\",\"url\":\"./dist/navidrome/index.js\"},{\"title\":\"CCTV\",\"url\":\"https://github.com/demo/repo/blob/main/CCTV 听音.js\"}]});"
            return (200, ["Content-Type": "application/json"], Data(payload.utf8))
        }

        let discovery = GitHubSourceDiscovery(session: makeSession(), secrets: InMemorySecretStore())
        let manifestURL = URL(string: "https://raw.githubusercontent.com/demo/repo/main/plugins.json")!
        let entries = try await discovery.inspectManifest(at: manifestURL)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Navi JS")
        XCTAssertEqual(entries[0].version, "0.1.0")
        XCTAssertEqual(entries[0].url.absoluteString, "https://raw.githubusercontent.com/demo/repo/main/dist/navidrome/index.js")
        XCTAssertEqual(entries[1].name, "CCTV")
        XCTAssertEqual(entries[1].url.absoluteString, "https://raw.githubusercontent.com/demo/repo/main/CCTV%20%E5%90%AC%E9%9F%B3.js")
    }

    func testTokenIsolationCodeSearchAndErrorHandling() async throws {
        let secrets = InMemorySecretStore()
        let networkFlag = MutableFlag()
        let discovery = GitHubSourceDiscovery(
            session: makeSession(),
            secrets: secrets,
            networkAllowed: { networkFlag.value }
        )

        networkFlag.value = false
        do {
            _ = try await discovery.searchRepositories(query: "musicfree")
            XCTFail("关闭联网开关后不应发起 GitHub 请求")
        } catch let violation as SourceDomainPolicy.Violation {
            if case .networkDisabled = violation {} else { XCTFail("预期 networkDisabled，实际 \(violation)") }
        }
        XCTAssertTrue(MockGitHubProtocol.recordedRequests.isEmpty)

        networkFlag.value = true
        MockGitHubProtocol.handler = { req in
            let host = req.url?.host ?? ""
            if host == "raw.githubusercontent.com" {
                XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "Token 不得发往 raw.githubusercontent.com")
                return (200, [:], Data(#"["https://raw.githubusercontent.com/a/b/main/s.js"]"#.utf8))
            }
            if req.url?.path == "/search/code" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_test_secret")
                let body = #"""
                {
                  "items": [
                    {
                      "name": "audius.flow.json",
                      "path": "examples/audius.flow.json",
                      "html_url": "https://github.com/demo/hub/blob/main/examples/audius.flow.json",
                      "repository": { "full_name": "demo/hub" }
                    }
                  ]
                }
                """#
                return (200, [:], Data(body.utf8))
            }
            if req.url?.path == "/search/repositories" {
                return (403, ["X-RateLimit-Remaining": "0"], Data(#"{"message":"API rate limit exceeded"}"#.utf8))
            }
            if req.url?.path == "/repos/bad/missing" {
                return (404, [:], Data(#"{"message":"Not Found"}"#.utf8))
            }
            return (401, [:], Data())
        }

        try discovery.saveToken("ghp_test_secret")
        XCTAssertTrue(discovery.hasToken)

        let codeHits = try await discovery.searchFiles(query: "flow-source-v1")
        XCTAssertEqual(codeHits.count, 1)
        XCTAssertEqual(codeHits.first?.kind, .jsonTemplateOrConfig)
        XCTAssertEqual(codeHits.first?.rawURL.absoluteString, "https://raw.githubusercontent.com/demo/hub/main/examples/audius.flow.json")

        _ = try await discovery.inspectManifest(at: URL(string: "https://raw.githubusercontent.com/a/b/main/sub.json")!)

        do {
            _ = try await discovery.searchRepositories(query: "music")
            XCTFail("403 rate limit 应报错")
        } catch let err as GitHubDiscoveryError {
            XCTAssertEqual(err, .rateLimited(hasToken: true))
        }

        do {
            _ = try await discovery.searchRepositories(query: "bad/missing")
            XCTFail("404 应报 repositoryNotFound")
        } catch let err as GitHubDiscoveryError {
            XCTAssertEqual(err, .repositoryNotFound("bad/missing"))
        }

        discovery.clearToken()
        XCTAssertFalse(discovery.hasToken)
    }

    @MainActor
    func testSourceManagerGitHubSearchInspectAndImportEndToEnd() async throws {
        MockGitHubProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url == "https://api.github.com/repos/demo/music-hub" {
                let repoJSON = #"""
                {
                  "full_name": "demo/music-hub",
                  "name": "music-hub",
                  "owner": { "login": "demo" },
                  "description": "Direct target test",
                  "stargazers_count": 42,
                  "default_branch": "main",
                  "updated_at": "2026-11-22T01:00:00Z",
                  "html_url": "https://github.com/demo/music-hub"
                }
                """#
                return (200, [:], Data(repoJSON.utf8))
            }
            if url.contains("/repos/demo/music-hub/git/trees/main") {
                let treeJSON = #"""
                {
                  "truncated": false,
                  "tree": [
                    { "path": "demo-source.js", "type": "blob", "size": 512 }
                  ]
                }
                """#
                return (200, [:], Data(treeJSON.utf8))
            }
            if url == "https://raw.githubusercontent.com/demo/music-hub/main/demo-source.js" {
                let pluginJS = #"""
                module.exports = {
                    id: "gh-demo-source",
                    platform: "GitHub Demo Source",
                    allowedDomains: ["api.demo.test"],
                    async search(query) {
                        return { isEnd: true, data: [{ id: "1", title: query, artist: "Tester", duration: 120 }] };
                    },
                    async getMediaSource(item) {
                        return { url: "https://api.demo.test/" + item.id + ".mp3" };
                    }
                };
                """#
                return (200, [:], Data(pluginJS.utf8))
            }
            return (404, [:], Data())
        }

        let suite = "flow.github.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = SourceRegistry()
        let manager = SourceManager(
            registry: registry,
            networkEnabledProvider: { true },
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: tempDir,
            session: makeSession()
        )

        let repos = try await manager.searchGitHubRepositories(query: "https://github.com/demo/music-hub")
        XCTAssertEqual(repos.count, 1)
        let repo = try XCTUnwrap(repos.first)

        let configs = try await manager.inspectGitHubRepository(repo)
        XCTAssertEqual(configs.count, 1)
        let config = try XCTUnwrap(configs.first)

        let imported = try await manager.importSources(from: config.rawURL)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.descriptor.displayName, "GitHub Demo Source")
        XCTAssertTrue(manager.importedOriginURLs.contains(config.rawURL.absoluteString))

        let tracks = try await manager.search(query: "Nocturne", aggregate: false)
        XCTAssertEqual(tracks.first?.title, "Nocturne")
    }

    @MainActor
    func testGitHubSourceSearchSheetRendersOffscreen() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))
        let view = GitHubSourceSearchSheet()
            .environment(\.app, container)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(cgImage.width, 0)
        XCTAssertGreaterThan(cgImage.height, 0)
    }

    @MainActor
    func testMultiAPIPresetsDefaultDisabledAndOnlyOpenAPIs() async throws {
        let suite = "flow.presets.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = SourceManager(
            registry: SourceRegistry(),
            networkEnabledProvider: { true },
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: tempDir,
            externalPluginsDirectories: [],
            session: makeSession()
        )

        let presets = manager.availableAPIPresets
        XCTAssertEqual(Set(presets.map(\.id)), ["audius-open", "radiobrowser-open", "internet-archive-audio"])
        // 开源发布不收录抓取商业平台的脚本：预设里既不能有 B 站，也不能有任何需要从远端拉脚本的条目。
        XCTAssertFalse(presets.contains { $0.sourceID == SourceID("js-bilibili") })
        XCTAssertTrue(presets.allSatisfy { $0.remoteURL == nil && $0.fallbackTemplateJSON != nil })

        for preset in presets {
            XCTAssertFalse(manager.isPresetImported(preset), "默认干净启动不应预导入预设 \(preset.id)")
            XCTAssertFalse(manager.isPresetEnabled(preset), "默认干净启动预设应为未启用状态 \(preset.id)")
        }
    }

    @MainActor
    func testRemotePresetFetchesOnceAndRespectsNetworkGate() async throws {
        let suite = "flow.presets.remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let networkFlag = MutableFlag()
        networkFlag.value = false

        let remoteURL = URL(string: "https://raw.githubusercontent.com/example/flow-demo/main/demo-source.js")!
        let remotePreset = ExternalAPIPreset(
            id: "demo-remote",
            sourceID: SourceID(rawValue: "js-demo-remote"),
            displayName: "Demo Remote",
            summary: "测试用远端预设",
            originBadge: "GitHub",
            localRelativePath: "demo-source.js",
            remoteURL: remoteURL,
            fallbackTemplateJSON: nil
        )

        MockGitHubProtocol.handler = { req in
            if req.url == remoteURL {
                let script = #"""
                module.exports = {
                    platform: "demo-remote",
                    version: "0.1.0",
                    async search(query) {
                        return { isEnd: true, data: [{ id: "demo-1", title: query, artist: "Demo", duration: 180 }] };
                    },
                    async getMediaSource(item) {
                        return { url: "https://example.com/" + item.id + ".mp3" };
                    }
                };
                """#
                return (200, [:], Data(script.utf8))
            }
            return (404, [:], Data())
        }

        let manager = SourceManager(
            registry: SourceRegistry(),
            networkEnabledProvider: { networkFlag.value },
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: tempDir,
            externalPluginsDirectories: [],
            apiPresets: [remotePreset],
            session: makeSession()
        )
        let preset = try XCTUnwrap(manager.availableAPIPresets.first { $0.id == "demo-remote" })

        do {
            _ = try await manager.setPresetEnabled(preset, enabled: true)
            XCTFail("关网且无外置目录时开启远端预设应报错")
        } catch let err as PlaybackError {
            XCTAssertEqual(err, .networkDisabled)
        }
        XCTAssertTrue(MockGitHubProtocol.recordedRequests.isEmpty)

        networkFlag.value = true
        let enabledSource = try await manager.setPresetEnabled(preset, enabled: true)
        XCTAssertEqual(enabledSource?.id, SourceID("js-demo-remote"))
        XCTAssertTrue(manager.isPresetImported(preset))
        XCTAssertTrue(manager.isPresetEnabled(preset))
        XCTAssertEqual(MockGitHubProtocol.recordedRequests.count, 1)

        // 关闭后再打开应直接复用已落盘配置，不重复发网络请求。
        _ = try await manager.setPresetEnabled(preset, enabled: false)
        XCTAssertFalse(manager.isPresetEnabled(preset))
        XCTAssertTrue(manager.isPresetImported(preset))

        _ = try await manager.setPresetEnabled(preset, enabled: true)
        XCTAssertTrue(manager.isPresetEnabled(preset))
        XCTAssertEqual(MockGitHubProtocol.recordedRequests.count, 1)

        let hits = try await manager.search(query: "潮汐之间", aggregate: false)
        XCTAssertEqual(hits.first?.externalID, "demo-1")
    }

    @MainActor
    func testExternalDirectoryPresetAndPresetsManifest() async throws {
        let externalDir = RepositoryRoot.locate().appendingPathComponent("external-plugins", isDirectory: true)
        let presetsManifestURL = externalDir.appendingPathComponent("presets.json")
        let manifestData = try Data(contentsOf: presetsManifestURL)
        let entries = try GitHubSourceDiscovery.parseManifestEntries(data: manifestData, originURL: presetsManifestURL)
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries.contains { $0.url.lastPathComponent.hasSuffix(".js") }, "清单里只放开放接口模板")

        let suite = "flow.presets.ext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = SourceManager(
            registry: SourceRegistry(),
            networkEnabledProvider: { true },
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: tempDir,
            externalPluginsDirectories: [externalDir],
            session: makeSession()
        )
        let audius = try XCTUnwrap(manager.availableAPIPresets.first { $0.id == "audius-open" })
        XCTAssertNotNil(ExternalAPIPresetCatalog.resolveLocalPresetURL(audius, in: [externalDir]),
                        "外置目录里有同名模板时应优先用它")
        let source = try await manager.setPresetEnabled(audius, enabled: true)
        XCTAssertEqual(source?.id, audius.sourceID)
        XCTAssertTrue(source?.descriptor.supportsSearch == true)
        XCTAssertTrue(MockGitHubProtocol.recordedRequests.isEmpty, "命中外置目录时无需发起网络拉取")
    }

    @MainActor
    func testOpenAPIPresetsEnableAndToggleWithoutExternalDirectory() async throws {
        let suite = "flow.presets.open.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = SourceManager(
            registry: SourceRegistry(),
            networkEnabledProvider: { true },
            defaults: defaults,
            secrets: InMemorySecretStore(),
            importedSourcesDirectory: tempDir,
            externalPluginsDirectories: [],
            session: makeSession()
        )
        let audius = try XCTUnwrap(manager.availableAPIPresets.first { $0.id == "audius-open" })
        let enabled = try await manager.setPresetEnabled(audius, enabled: true)
        XCTAssertEqual(enabled?.id, audius.sourceID)
        XCTAssertTrue(manager.isPresetEnabled(audius))

        _ = try await manager.setPresetEnabled(audius, enabled: false)
        XCTAssertFalse(manager.isPresetEnabled(audius))
    }

    @MainActor
    func testLiveGitHubSearchAndInspectRealAPI() async throws {
        try LiveTestGate.skipUnlessLive("实网 GitHub 仓库搜索与配置探测测试，需设置 SLP_LIVE_TEST=1")
        let discovery = GitHubSourceDiscovery(session: .shared, secrets: InMemorySecretStore())
        let repos = try await discovery.searchRepositories(query: "maotoumao/MusicFreePlugins")
        let repo = try XCTUnwrap(repos.first)
        XCTAssertEqual(repo.fullName.lowercased(), "maotoumao/musicfreeplugins")

        let configs = try await discovery.inspectRepository(repo)
        XCTAssertTrue(configs.contains { $0.kind == .subscriptionManifest }, "应自动识别仓库内的订阅清单文件")
    }
}
