import Foundation
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

final class ManualLyricSearchAndBindingTests: XCTestCase {

    private struct StubAutoSource: PlaybackSourceProvider {
        let id: SourceID
        let autoDocument: LyricsDocument?

        var descriptor: SourceDescriptor {
            SourceDescriptor(id: id, displayName: "stub", requiresNetwork: false,
                             supportsSearch: false, supportsLyrics: autoDocument != nil)
        }
        func search(_ request: SearchRequest) async throws -> [Track] { [] }
        func makeSession(for track: Track) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }
        func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
            throw PlaybackError.sourceUnavailable
        }
        func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
        func lyrics(for track: Track) async throws -> LyricsDocument? {
            guard let autoDocument, autoDocument.trackIdentity == track.identity else { return nil }
            return autoDocument
        }
        func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        func completed(_ track: Track) async {}
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-manual-lyric-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func amllTTMLSample() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="00:01.000" end="00:04.000"><span begin="00:01.000" end="00:02.500">夢の</span><span begin="00:02.500" end="00:04.000">灯り</span><span ttm:role="x-translation">夢境的光</span></p>
            </div>
          </body>
        </tt>
        """
    }

    // MARK: - 1. AMLL 索引多模式检索与离线读取

    @MainActor
    func testAMLLIndexAndProviderSearchSupportsMixedKeywordsAndOfflineIndex() async throws {
        let jsonl = """
        {"metadata":[["musicName",["夜曲"]],["artists",["周杰伦"]]],"rawLyricFile":"jay-nocturne.ttml"}
        {"metadata":[["musicName",["夜曲 (Live)"]],["artists",["周杰伦"]]],"rawLyricFile":"jay-nocturne-live.ttml"}
        {"metadata":[["musicName",["夜曲"]],["artists",["林俊杰"]]],"rawLyricFile":"jj-nocturne.ttml"}
        {"metadata":[["musicName",["君の名は。"]],["artists",["RADWIMPS"]]],"rawLyricFile":"your-name.ttml"}
        """
        let index = AMLLLyricsIndex.parse(Data(jsonl.utf8))

        XCTAssertEqual(index.search(query: "夜曲", artist: "周杰伦").map(\.file),
                       ["jay-nocturne.ttml", "jay-nocturne-live.ttml"])
        XCTAssertEqual(index.search(query: "周杰伦 夜曲").first?.file, "jay-nocturne.ttml")
        XCTAssertEqual(index.search(query: "夜曲", artist: nil, limit: 2).count, 2)

        // 本地已有索引文件时，离线模式（allowNetwork: false）仍可搜索并与已缓存 TTML 配合绑定
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try Data(jsonl.utf8).write(to: cacheDir.appendingPathComponent("amll-index.jsonl"))

        let provider = AMLLLyricsProvider(session: FakeBiliTransport.makeSession(),
                                          allowsNetwork: true,
                                          cacheDirectory: cacheDir)
        let offlineEntries = await provider.search(title: "夜曲", artist: "周杰伦", allowNetwork: false)
        XCTAssertEqual(offlineEntries.count, 2)

        // 先离线时 TTML 未落盘应返回 nil；联网拉取一次后，即使断网也能再次加载原文 TTML
        FakeBiliTransport.reset()
        defer { FakeBiliTransport.reset() }
        FakeBiliTransport.routes = [("jay-nocturne.ttml", amllTTMLSample())]

        let missOffline = await provider.loadTTML(for: offlineEntries[0], allowNetwork: false)
        XCTAssertNil(missOffline)

        let onlineLoaded = await provider.loadTTML(for: offlineEntries[0], allowNetwork: true)
        XCTAssertEqual(onlineLoaded?.lines.first?.text, "夢の灯り")
        XCTAssertEqual(onlineLoaded?.lines.first?.segments.count, 2)

        FakeBiliTransport.reset()
        let hitOffline = await provider.loadTTML(for: offlineEntries[0], allowNetwork: false)
        XCTAssertEqual(hitOffline?.lines.first?.text, "夢の灯り")
    }

    // MARK: - 2. LRCLIB 自由关键词检索与手动排序

    func testLRCLIBKeywordSearchAndManualRankingPreferEnhancedAndIgnoreAutoGates() async throws {
        FakeBiliTransport.reset()
        defer { FakeBiliTransport.reset() }
        FakeBiliTransport.routes = [
            ("lrclib.net/api/search", [
                ["id": 10, "trackName": "夜曲", "artistName": "其他歌手", "albumName": "翻唱集",
                 "duration": 229.0, "syncedLyrics": "[00:01.00]普通时间轴"],
                ["id": 11, "trackName": "夜曲", "artistName": "周杰伦", "albumName": "十一月的萧邦",
                 "duration": 310.0, "syncedLyrics": "[00:01.00]<00:01.00>为<00:01.40>你弹奏"],
                ["id": 12, "trackName": "夜曲（无轴版）", "artistName": "周杰伦", "albumName": "",
                 "duration": 229.0],
            ])
        ]

        let source = LRCLIBSource(session: FakeBiliTransport.makeSession())
        let raw = try await source.search(keyword: "周杰伦 夜曲")
        XCTAssertTrue(FakeBiliTransport.requested.contains { $0.contains("?q=") || $0.contains("&q=") })
        XCTAssertEqual(raw.count, 3)

        let ranked = LRCLIBSource.rankManual(raw, query: "周杰伦 夜曲", artist: "周杰伦", duration: 229, limit: 10)
        // 无同步歌词的 id 12 被过滤；时长差超过 30 秒的增强 LRC (id 11) 在手动模式下仍保留且排第一
        XCTAssertEqual(ranked.map(\.id), [11, 10])
        XCTAssertTrue(ranked[0].hasEnhancedWordTiming)
        XCTAssertFalse(ranked[1].hasEnhancedWordTiming)
    }

    // MARK: - 3. 绑定持久化存储：跨实例恢复 & 高于源/字幕优先级

    @MainActor
    func testLyricBindingStorePersistsAcrossReloadsAndBeatsAutoSource() async throws {
        let bindingDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: bindingDir) }

        let stubSourceID = SourceID(rawValue: "manual-stub")
        let track = Track(sourceID: stubSourceID, externalID: "song::001",
                          title: "夢の灯り", artist: "Artist", duration: 210)
        let autoDoc = LyricsDocument(trackIdentity: track.identity,
                                     lines: [LyricLine(start: 0, text: "自动匹配的旧歌词")],
                                     source: .embedded,
                                     synchronization: .synced)

        let store1 = LyricBindingStore(directory: bindingDir)
        let loader1 = SourceAwareLyricsLoader(registry: SourceRegistry().with(StubAutoSource(id: stubSourceID, autoDocument: autoDoc)),
                                              bindingStore: store1)

        // 绑定前应回落到自动源歌词
        let beforeBind = await loader1.loadLyrics(for: track)
        XCTAssertEqual(beforeBind?.lines.first?.text, "自动匹配的旧歌词")

        store1.save(BoundLyricRecord(
            version: 1,
            identity: track.identity,
            providerName: "AMLL",
            trackName: "夢の灯り",
            artistName: "Artist",
            albumName: "",
            format: .ttml,
            payload: amllTTMLSample(),
            boundAt: Date()
        ))

        // 重建新的 store 实例模拟重启 App：仍应直接命中手动绑定且保留日文原文+简体中文译文
        let store2 = LyricBindingStore(directory: bindingDir)
        let loader2 = SourceAwareLyricsLoader(registry: SourceRegistry().with(StubAutoSource(id: stubSourceID, autoDocument: autoDoc)),
                                              bindingStore: store2)
        let boundDoc = await loader2.loadLyrics(for: track)
        XCTAssertEqual(boundDoc?.lines.first?.text, "夢の灯り")
        XCTAssertEqual(boundDoc?.lines.first?.segments.count, 2)
        XCTAssertEqual(boundDoc?.lines.first?.translation, "梦境的光")
        XCTAssertEqual(store2.binding(for: track.identity)?.providerName, "AMLL")

        // 移除绑定并重建：恢复自动源
        store2.remove(for: track.identity)
        let store3 = LyricBindingStore(directory: bindingDir)
        let loader3 = SourceAwareLyricsLoader(registry: SourceRegistry().with(StubAutoSource(id: stubSourceID, autoDocument: autoDoc)),
                                              bindingStore: store3)
        let restored = await loader3.loadLyrics(for: track)
        XCTAssertEqual(restored?.lines.first?.text, "自动匹配的旧歌词")
    }

    // MARK: - 4. Coordinator 跨源搜词、立即应用绑定、切歌回切命中与恢复自动

    @MainActor
    func testCoordinatorSearchesDualSourcesAppliesBindingAndClearsBackToAuto() async throws {
        FakeBiliTransport.reset()
        defer { FakeBiliTransport.reset() }

        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let bindingDir = tempRoot.appendingPathComponent("bindings", isDirectory: true)
        let amllCacheDir = tempRoot.appendingPathComponent("amll", isDirectory: true)
        let lrcCacheDir = tempRoot.appendingPathComponent("lrc-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: amllCacheDir, withIntermediateDirectories: true)

        let amllIndex = """
        {"metadata":[["musicName",["夢の灯り"]],["artists",["TestBand"]]],"rawLyricFile":"dream-light.ttml"}
        """
        try Data(amllIndex.utf8).write(to: amllCacheDir.appendingPathComponent("amll-index.jsonl"))

        FakeBiliTransport.routes = [
            ("lrclib.net/api/search", [
                ["id": 88, "trackName": "夢の灯り (Acoustic)", "artistName": "TestBand",
                 "albumName": "EP", "duration": 180.0, "syncedLyrics": "[00:02.00]LRCLIB 旧版"]
            ]),
            ("dream-light.ttml", amllTTMLSample()),
        ]

        let amllProvider = AMLLLyricsProvider(session: FakeBiliTransport.makeSession(),
                                              allowsNetwork: true,
                                              cacheDirectory: amllCacheDir)
        let lrclib = LRCLIBSource(session: FakeBiliTransport.makeSession())
        let bindingStore = LyricBindingStore(directory: bindingDir)
        let remoteID = SourceID(rawValue: "remote")

        let track = Track(sourceID: remoteID, externalID: "dual001",
                          title: "TestBand - 夢の灯り【Hi-Res】", artist: "Other", duration: 180)
        let otherTrack = Track(sourceID: remoteID, externalID: "other002",
                               title: "另一首歌", artist: "Other", duration: 200)
        let autoDoc = LyricsDocument(trackIdentity: track.identity,
                                     lines: [LyricLine(start: 0, text: "自动默认歌词")],
                                     source: .external,
                                     synchronization: .synced)

        let registry = SourceRegistry().with(StubAutoSource(id: remoteID, autoDocument: autoDoc))
        let loader = SourceAwareLyricsLoader(registry: registry, bindingStore: bindingStore)
        let persistence = try PersistenceController(inMemory: true)
        let engine = LyricEngine(loader: loader,
                                 offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container))

        let coordinator = LyricVariantCoordinator(
            bindingStore: bindingStore,
            lyricEngine: engine,
            amllProvider: amllProvider,
            lrclibSource: lrclib,
            networkAllowed: { true }
        )

        let suggested = coordinator.suggestedQuery(for: track)
        XCTAssertEqual(suggested.keyword, "夢の灯り")
        XCTAssertEqual(suggested.artist, "TestBand")

        // 无分隔符标题保留原 track.artist
        let simpleTrack = Track(sourceID: remoteID, externalID: "up001",
                                title: "晴天【4K】", artist: "周杰伦", duration: 269)
        XCTAssertEqual(coordinator.suggestedQuery(for: simpleTrack).keyword, "晴天")
        XCTAssertEqual(coordinator.suggestedQuery(for: simpleTrack).artist, "周杰伦")

        await engine.load(track: track)
        XCTAssertEqual(engine.document?.lines.first?.text, "自动默认歌词")

        // 1) 手动同时搜索 AMLL + LRCLIB
        let results = await coordinator.search(keyword: "夢の灯り", artist: "", for: track)
        XCTAssertEqual(results.map(\.source), [.amll, .lrclib])
        XCTAssertEqual(results[0].sourceBadge, String(localized: "AMLL 逐字"))
        XCTAssertEqual(results[1].sourceBadge, "LRCLIB")

        // 2) 应用 LRCLIB 也会自动简体化并持久化绑定，切到 AMLL 再切回歌曲仍保持绑定
        let appliedAMLL = await coordinator.apply(results[0], for: track)
        XCTAssertEqual(appliedAMLL?.lines.first?.text, "夢の灯り")
        XCTAssertEqual(appliedAMLL?.lines.first?.translation, "梦境的光")
        XCTAssertEqual(engine.document?.lines.first?.text, "夢の灯り")

        await engine.load(track: otherTrack)
        XCTAssertNil(engine.document)
        await engine.load(track: track)
        XCTAssertEqual(engine.document?.lines.first?.segments.count, 2, "切回同一首应直接读取持久化绑定的 AMLL 逐字歌词")

        // 3) 恢复自动匹配：解除绑定并重新载入自动歌词
        await coordinator.clearBinding(for: track)
        XCTAssertNil(bindingStore.binding(for: track.identity))
        XCTAssertEqual(engine.document?.lines.first?.text, "自动默认歌词")
        _ = lrcCacheDir
    }

    // MARK: - 5. 容器 lyricVariants 绑定 & 菜单视图离屏渲染

    @MainActor
    func testContainerCoordinatorAppliesSyncBindingsAndRenderMenuView() async throws {
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "legacy99",
                          title: "夜曲", artist: "周杰伦", duration: 229)

        await app.lyricEngine.load(track: track)

        let candidate = LRCLIBSource.Candidate(
            id: 42,
            trackName: "夜曲",
            artistName: "周杰倫",
            albumName: "十一月的蕭邦",
            duration: 229,
            syncedLyrics: "[00:01.00]為你彈奏蕭邦的夜曲"
        )
        let applied = await app.lyricVariants.apply(LyricVariantCandidate.fromLRCLIB(candidate), for: track)
        XCTAssertEqual(applied?.lines.count, 1)
        XCTAssertEqual(app.lyricEngine.document?.lines.first?.text, "为你弹奏萧邦的夜曲")
        XCTAssertEqual(app.lyricBindings.binding(for: track.identity)?.artistName, "周杰伦")
        XCTAssertEqual(app.lyricBindings.binding(for: track.identity)?.sourceIdentifier, "lrclib:42")
        XCTAssertEqual(app.lyricBindings.binding(for: track.identity)?.format, .lrc)

        // 视图挂上 lyricVariantMenu 后可正常离屏渲染
        let model = MorphPresentationModel()
        model.track = track
        let renderer = ImageRenderer(
            content: Text("歌詞")
                .lyricVariantMenu(model: model)
                .environment(\.app, app)
                .frame(width: 200, height: 120)
        )
        XCTAssertNotNil(renderer.nsImage)
    }

    // MARK: - 6. 审查回归：文档更新即时通知与任务取消隔离

    @MainActor
    func testReviewFixesEngineDocumentCallbackAndCancelledApply() async throws {
        FakeBiliTransport.reset()
        defer { FakeBiliTransport.reset() }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let amllDir = tempDir.appendingPathComponent("amll", isDirectory: true)
        try FileManager.default.createDirectory(at: amllDir, withIntermediateDirectories: true)
        let amllIndex = """
        {"metadata":[["musicName",["夜曲"]],["artists",["周杰伦"]]],"rawLyricFile":"nocturne-jay.ttml"}
        """
        try Data(amllIndex.utf8).write(to: amllDir.appendingPathComponent("amll-index.jsonl"))

        FakeBiliTransport.routes = [
            ("lrclib.net/api/search", [
                ["id": 9, "trackName": "夜曲", "artistName": "周杰伦", "albumName": "十一月的萧邦",
                 "duration": 229.0, "syncedLyrics": "[00:01.00]为你弹奏萧邦的夜曲"]
            ]),
            ("nocturne-jay.ttml", amllTTMLSample()),
        ]

        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "rev001",
                          title: "周杰伦 - 夜曲", artist: "周杰伦", duration: 229)

        let persistence = try PersistenceController(inMemory: true)
        let bindings = LyricBindingStore(directory: nil)
        let engine = LyricEngine(
            loader: SourceAwareLyricsLoader(registry: SourceRegistry(), bindingStore: bindings),
            offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
        )
        var callbackCount = 0
        engine.onDocumentChanged = { callbackCount += 1 }

        let coordinator = LyricVariantCoordinator(
            bindingStore: bindings,
            lyricEngine: engine,
            amllProvider: AMLLLyricsProvider(session: FakeBiliTransport.makeSession(), allowsNetwork: true, cacheDirectory: amllDir),
            lrclibSource: LRCLIBSource(session: FakeBiliTransport.makeSession()),
            networkAllowed: { true }
        )

        let suggested = coordinator.suggestedQuery(for: track)
        XCTAssertEqual(suggested.keyword, "夜曲")
        XCTAssertEqual(suggested.artist, "周杰伦")

        // 反序"歌名 - 歌手"混合写法仍可搜到 AMLL 与 LRCLIB
        let reversedHits = await coordinator.search(keyword: "夜曲 - 周杰伦", artist: "", for: track)
        XCTAssertTrue(reversedHits.contains { $0.source == .amll && $0.trackName == "夜曲" })

        // 取消中的 apply 任务不得污染绑定仓库或覆盖引擎文档
        await engine.load(track: track)
        let countAfterLoad = callbackCount
        let cancelledTask = Task {
            await coordinator.apply(reversedHits[0], for: track)
        }
        cancelledTask.cancel()
        _ = await cancelledTask.value
        XCTAssertNil(bindings.binding(for: track.identity))
        XCTAssertEqual(callbackCount, countAfterLoad)

        // 正常应用后立即触发 onDocumentChanged 回调
        let lrcCandidate = reversedHits.first { $0.source == .lrclib }!
        let doc = await coordinator.apply(lrcCandidate, for: track)
        XCTAssertNotNil(doc)
        XCTAssertGreaterThan(callbackCount, countAfterLoad)
        XCTAssertEqual(bindings.binding(for: track.identity)?.sourceIdentifier, lrcCandidate.id)

        // defaultCandidates 按当前歌名/歌手精确检索，不把其他歌手混进来
        let unrelatedDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: unrelatedDir) }
        try Data("""
        {"metadata":[["musicName",["流星小夜曲"]],["artists",["岑宁儿"]]],"rawLyricFile":"meteor.ttml"}
        """.utf8).write(to: unrelatedDir.appendingPathComponent("amll-index.jsonl"))
        let strictCoordinator = LyricVariantCoordinator(
            bindingStore: bindings,
            lyricEngine: engine,
            amllProvider: AMLLLyricsProvider(session: FakeBiliTransport.makeSession(), allowsNetwork: true, cacheDirectory: unrelatedDir),
            lrclibSource: LRCLIBSource(session: FakeBiliTransport.makeSession()),
            networkAllowed: { true }
        )
        let defaultHits = await strictCoordinator.defaultCandidates(for: track)
        XCTAssertFalse(defaultHits.contains { $0.source == .amll }, "有明确歌手时不应推荐其他歌手同名/包含歌曲")
        XCTAssertEqual(defaultHits.first?.trackName, "夜曲")
        XCTAssertEqual(defaultHits.first?.artistName, "周杰伦")
    }
}

private extension SourceRegistry {
    func with(_ provider: any PlaybackSourceProvider) -> SourceRegistry {
        register(provider)
        return self
    }
}
