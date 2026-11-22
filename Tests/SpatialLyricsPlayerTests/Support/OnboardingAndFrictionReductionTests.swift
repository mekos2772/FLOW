import Foundation
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

final class OnboardingAndFrictionReductionTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        MockOnboardingURLProtocol.reset()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockOnboardingURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - 1. 主窗口文件分类器

    func testUniversalFileClassifierHandlesAudioFoldersLyricsPluginsAndVoiceModels() throws {
        let dir = try makeTempDir()
        let folder = dir.appendingPathComponent("MusicFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("song.flac")),
            .audio(dir.appendingPathComponent("song.flac").standardizedFileURL)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(folder),
            .folder(folder.standardizedFileURL)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("track.lrc")),
            .lyric(dir.appendingPathComponent("track.lrc").standardizedFileURL)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("word.ttml")),
            .lyric(dir.appendingPathComponent("word.ttml").standardizedFileURL)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("plugin.js")),
            .sourcePlugin(dir.appendingPathComponent("plugin.js").standardizedFileURL)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("singer.voicepack")),
            .voicePackOrModel(dir.appendingPathComponent("singer.voicepack").standardizedFileURL, baseModelHint: nil)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("rmvpe.onnx")),
            .voicePackOrModel(dir.appendingPathComponent("rmvpe.onnx").standardizedFileURL, baseModelHint: .rmvpe)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("contentvec_768l12.onnx")),
            .voicePackOrModel(dir.appendingPathComponent("contentvec_768l12.onnx").standardizedFileURL, baseModelHint: .hubert)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("UVR-MDX-NET-Voc_FT.onnx")),
            .voicePackOrModel(dir.appendingPathComponent("UVR-MDX-NET-Voc_FT.onnx").standardizedFileURL, baseModelHint: .mdxSeparator)
        )
        XCTAssertEqual(
            UniversalFileClassifier.classify(dir.appendingPathComponent("readme.pdf")),
            .unsupported(dir.appendingPathComponent("readme.pdf").standardizedFileURL)
        )
    }

    // MARK: - 2. GitHub Raw -> jsDelivr CDN 回退与联网开关拦截

    func testGitHubRawMirrorCandidatesAndCDNImportFallback() async throws {
        let rawURL = URL(string: "https://raw.githubusercontent.com/maotoumao/MusicFreePlugins/v0.1/dist/bilibili/index.js")!
        let candidates = SourceDomainPolicy.rawGitHubMirrorCandidates(for: rawURL)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0], rawURL)
        XCTAssertEqual(
            candidates[1].absoluteString,
            "https://cdn.jsdelivr.net/gh/maotoumao/MusicFreePlugins@v0.1/dist/bilibili/index.js"
        )

        let templateJSON = #"""
        {
          "schema": "flow-source-v1",
          "id": "cdn-fallback-demo",
          "name": "CDN Fallback Demo",
          "allowedDomains": ["example.com"],
          "discover": {
            "method": "GET",
            "url": "https://example.com/list",
            "itemsPath": "items",
            "fields": { "id": "id", "title": "title", "artist": "artist", "streamUrl": "url" }
          },
          "search": {
            "method": "GET",
            "url": "https://example.com/search?q={{query}}",
            "itemsPath": "items",
            "fields": { "id": "id", "title": "title", "artist": "artist", "streamUrl": "url" }
          }
        }
        """#

        MockOnboardingURLProtocol.register { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "raw.githubusercontent.com" {
                return (HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil)!, Data())
            }
            if url.host == "cdn.jsdelivr.net" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(templateJSON.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let dir = try makeTempDir()
        let store = ImportedSourceStore(
            directory: dir,
            session: makeMockSession(),
            secrets: InMemorySecretStore(),
            networkAllowed: { true }
        )

        let target = URL(string: "https://raw.githubusercontent.com/demo/repo/main/source.flow.json")!
        let imported = try await store.importFromURL(target)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.sourceID, SourceID(rawValue: "json-cdn-fallback-demo"))

        let hosts = MockOnboardingURLProtocol.recordedURLs.compactMap(\.host)
        XCTAssertEqual(hosts, ["raw.githubusercontent.com", "cdn.jsdelivr.net"])

        let offlineStore = ImportedSourceStore(
            directory: try makeTempDir(),
            session: makeMockSession(),
            secrets: InMemorySecretStore(),
            networkAllowed: { false }
        )
        do {
            _ = try await offlineStore.importFromURL(target)
            XCTFail("关闭联网时不得尝试下载或走 CDN")
        } catch let err as PlaybackError {
            XCTAssertEqual(err, .networkDisabled)
        }
    }

    // MARK: - 3. 本地歌词文件导入（含多编码与繁转简）

    @MainActor
    func testLyricVariantCoordinatorAppliesLocalLRCAndGBKFiles() throws {
        let dir = try makeTempDir()
        let store = LyricBindingStore(directory: dir)
        let coordinator = LyricVariantCoordinator(
            bindingStore: store,
            lyricEngine: nil,
            networkAllowed: { false }
        )
        let track = Track(
            sourceID: .localFile,
            externalID: "demo-1",
            title: "夜曲",
            artist: "周杰伦",
            duration: 220
        )

        let lrcURL = dir.appendingPathComponent("utf8_trad.lrc")
        let lrcContent = "[00:05.00]為妳彈奏蕭邦的夜曲\n[00:12.00]紀念我死去的愛情\n"
        try lrcContent.write(to: lrcURL, atomically: true, encoding: .utf8)

        let doc = try XCTUnwrap(coordinator.applyLocalLyricFile(at: lrcURL, for: track))
        XCTAssertEqual(doc.synchronization, .synced)
        XCTAssertEqual(doc.lines.first?.text, "为妳弹奏萧邦的夜曲")
        XCTAssertEqual(doc.lines.last?.text, "纪念我死去的爱情")
        XCTAssertEqual(store.binding(for: track.identity)?.format, .lrc)

        // GB18030 编码支持
        let gbURL = dir.appendingPathComponent("gbk.lrc")
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        let gbData = try XCTUnwrap("[00:10.00]本地歌词测试中文解码\n".data(using: gbEncoding))
        try gbData.write(to: gbURL)

        let gbDoc = try XCTUnwrap(coordinator.applyLocalLyricFile(at: gbURL, for: track))
        XCTAssertEqual(gbDoc.lines.first?.text, "本地歌词测试中文解码")

        // 无时间轴纯文本歌词降级
        let plainURL = dir.appendingPathComponent("plain.lrc")
        try "第一句无时间歌词\n第二句无时间歌词\n".write(to: plainURL, atomically: true, encoding: .utf8)
        let plainDoc = try XCTUnwrap(coordinator.applyLocalLyricFile(at: plainURL, for: track))
        XCTAssertEqual(plainDoc.synchronization, .unsynced)
        XCTAssertEqual(plainDoc.lines.count, 2)
    }

    // MARK: - 4. 主窗口全局拖放端到端路由

    @MainActor
    func testUniversalDropRouterRoutesAudioLyricsPluginsAndVoice() async throws {
        let dir = try makeTempDir()
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()

        // 1) 拖入音频
        let audioURL = try TestAudioFixture.makeM4A(in: dir.appendingPathComponent("audio", isDirectory: true))
        let audioMsg = await UniversalDropRouter.handle(urls: [audioURL], app: app, model: model)
        XCTAssertNotNil(audioMsg)
        XCTAssertTrue(app.sourceManager.hasAnyConfiguredSource)

        // 2) 拖入歌词（已有 track）
        let sampleTrack = Track(sourceID: .localFile, externalID: audioURL.path, title: "TestAudio", artist: "Artist", duration: 2)
        model.track = sampleTrack
        let lrcURL = dir.appendingPathComponent("dropped.lrc")
        try "[00:01.00]拖入绑定的测试歌词\n".write(to: lrcURL, atomically: true, encoding: .utf8)
        let lyricMsg = await UniversalDropRouter.handle(urls: [lrcURL], app: app, model: model)
        XCTAssertTrue(lyricMsg?.contains("dropped.lrc") == true)
        XCTAssertNotNil(app.lyricBindings.binding(for: sampleTrack.identity))

        // 3) 拖入音源 JSON
        let sourceURL = dir.appendingPathComponent("dropped.flow.json")
        let sourceJSON = #"""
        {
          "schema": "flow-source-v1",
          "id": "dropped-demo-source",
          "name": "Dropped Source",
          "allowedDomains": ["example.com"],
          "discover": {
            "method": "GET",
            "url": "https://example.com/tracks",
            "itemsPath": "items",
            "fields": { "id": "id", "title": "title", "artist": "artist", "streamUrl": "url" }
          },
          "search": {
            "method": "GET",
            "url": "https://example.com/search?q={{query}}",
            "itemsPath": "items",
            "fields": { "id": "id", "title": "title", "artist": "artist", "streamUrl": "url" }
          }
        }
        """#
        try sourceJSON.write(to: sourceURL, atomically: true, encoding: .utf8)
        let sourceMsg = await UniversalDropRouter.handle(urls: [sourceURL], app: app, model: model)
        XCTAssertTrue(sourceMsg?.contains("Dropped Source") == true)

        // 4) 拖入 RVC .onnx 音色
        let voiceURL = dir.appendingPathComponent("singer_drop.onnx")
        let onnxBytes = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64))
        try onnxBytes.write(to: voiceURL)
        let voiceMsg = await UniversalDropRouter.handle(urls: [voiceURL], app: app, model: model)
        XCTAssertTrue(voiceMsg?.contains("音色") == true)
        XCTAssertTrue(app.voice?.packs.contains(where: { $0.displayName == "singer_drop" }) == true)
    }

    // MARK: - 5. 新 UI 组件离屏渲染覆盖

    @MainActor
    func testQuickActionsOnlineEmptyAndErrorStripRenderOffscreen() throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let model = MorphPresentationModel()
        model.track = Track(sourceID: .localFile, externalID: "render-1", title: "Demo", artist: "Singer", duration: 180)
        model.error = .networkDisabled

        let views: [AnyView] = [
            AnyView(OnlineHomeView(model: model).environment(\.app, app).frame(width: 780, height: 520)),
            AnyView(LyricQuickActionsBar(model: model).environment(\.app, app).padding()),
            AnyView(UniversalDropOverlay(isTargeted: true).frame(width: 500, height: 320)),
            AnyView(PlaybackErrorStrip(
                model: model,
                onRetry: {},
                onSkip: {},
                quickFixTitle: "允许联网并重试",
                onQuickFix: {}
            ).frame(width: 600, height: 48))
        ]

        for view in views {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
        }
    }
}

// MARK: - Isolated Mock Protocol

private final class MockOnboardingProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MockOnboardingURLProtocol.Handler?
    private var requests: [URL] = []

    var recordedURLs: [URL] {
        lock.withLock { requests }
    }

    func register(_ handler: @escaping MockOnboardingURLProtocol.Handler) {
        lock.withLock {
            self.handler = handler
            self.requests = []
        }
    }

    func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    func takeHandler(recording url: URL?) -> MockOnboardingURLProtocol.Handler? {
        lock.withLock {
            if let url { requests.append(url) }
            return handler
        }
    }
}

private final class MockOnboardingURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let state = MockOnboardingProtocolState()

    static var recordedURLs: [URL] { state.recordedURLs }
    static func register(_ handler: @escaping Handler) { state.register(handler) }
    static func reset() { state.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.state.takeHandler(recording: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
