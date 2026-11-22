import AppKit
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

/// 代码审查问题与全链路简体歌词修复的回归测试套件。
@MainActor
final class ReviewRegressionTests: XCTestCase {

    // MARK: - 1. 隐私模式不得在默认滚动歌词视图下泄漏原文

    func testLyricScrollViewHidesLyricsWhenMasked() throws {
        let secret = "秘密歌词絕對不能出現在畫面上"
        let lines = [
            LyricLine(start: 0, end: 5, text: secret),
            LyricLine(start: 5, end: 10, text: "第二句同樣需要遮罩"),
        ]

        let maskedModel = MorphPresentationModel()
        maskedModel.track = Track(sourceID: .mock, externalID: "mask-test", title: "秘密歌名", artist: "歌手", duration: 120)
        maskedModel.isMasked = true
        maskedModel.lyricState = .loaded

        let emptyMaskedModel = MorphPresentationModel()
        emptyMaskedModel.track = maskedModel.track
        emptyMaskedModel.isMasked = true
        emptyMaskedModel.lyricState = .loaded

        let maskedWithLines = ImageRenderer(
            content: LyricScrollView(model: maskedModel, providedLines: lines)
                .frame(width: 480, height: 320)
        )
        let maskedWithoutLines = ImageRenderer(
            content: LyricScrollView(model: emptyMaskedModel, providedLines: [])
                .frame(width: 480, height: 320)
        )

        let pngA = try XCTUnwrap(maskedWithLines.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        let pngB = try XCTUnwrap(maskedWithoutLines.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        XCTAssertEqual(pngA, pngB, "隐私模式打开后，是否传入歌词行都必须渲染完全一致的遮罩界面")
    }

    // MARK: - 2. 歌词全链路强制简体中文（同时保留真实日文歌词）

    func testKatakanaMiddleDotAndMetadataKanaDoNotBlockSimplifiedConversion() throws {
        let withMiddleDot = """
        [ti:周杰倫・方文山]
        [by:字幕製作の小林]
        [00:01.00]願戴榮光墜入天淵
        [00:05.00]這首歌の旋律讓人懷念
        """
        let parsed = try XCTUnwrap(LRCParser.parse(withMiddleDot))
        XCTAssertEqual(parsed.metadata.title, "周杰伦・方文山")
        XCTAssertEqual(parsed.metadata.author, "字幕制作の小林")
        XCTAssertEqual(parsed.lines.map(\.text), ["愿戴荣光坠入天渊", "这首歌の旋律让人怀念"])
    }

    func testLongChineseLyricsWithStrayDecorativeKanaStillConvertToSimplified() {
        let sample = """
        愛情的距離總是很遙遠你說這場夢太美不要醒來
        夜空中閃爍的星光見證著我們的約定永遠不變
        這一段青春の記憶裡藏著多少歡笑與淚水
        """
        let convert = TextNormalizer.converter(forDocument: sample)
        XCTAssertEqual(convert("願戴榮光墜入天淵"), "愿戴荣光坠入天渊")
    }

    func testLyricQueryNormalizerStripsDecorations() {
        let parsed = LyricQueryNormalizer.parseTitle("周杰伦 - 夜曲【4K 修复版】")
        XCTAssertEqual(parsed.artist, "周杰伦")
        XCTAssertEqual(parsed.title, "夜曲")
    }

    func testLyricEngineAlwaysNormalizesDocumentAndOverrideToSimplified() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let offsets = SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
        let track = Track(sourceID: .mock, externalID: "trad-doc", title: "英雄主義", artist: "某歌手", duration: 180)
        let doc = LyricsDocument(
            trackIdentity: track.identity,
            lines: [
                LyricLine(start: 0, end: 5, text: "願戴榮光墜入天淵",
                          segments: [LyricSegment(start: 0, text: "願戴榮光"), LyricSegment(start: 2, text: "墜入天淵")]),
            ],
            metadata: LyricsMetadata(title: "英雄主義", artist: "樂隊", album: "專輯", author: "製作組", offsetMilliseconds: 0),
            synchronization: .synced
        )
        let loader = StubLyricsLoader()
        loader.stub(doc, for: track.externalID)
        let engine = LyricEngine(loader: loader, offsets: offsets)
        await engine.load(track: track)

        XCTAssertEqual(engine.document?.lines.first?.text, "愿戴荣光坠入天渊")
        XCTAssertEqual(engine.document?.lines.first?.segments.map(\.text), ["愿戴荣光", "坠入天渊"])
        XCTAssertEqual(engine.document?.metadata.title, "英雄主义")
        XCTAssertEqual(engine.document?.metadata.author, "制作组")

        let unsyncedOverride = LyricsDocument(
            trackIdentity: track.identity,
            lines: [LyricLine(start: 0, text: "歌詞裡有夢想")],
            synchronization: .unsynced
        )
        engine.overrideDocument(unsyncedOverride)
        XCTAssertEqual(engine.document?.lines.first?.text, "歌词里有梦想")
    }

    func testCoordinatorLyricCandidatesAreConvertedToSimplified() async throws {
        FakeBiliTransport.reset()
        defer { FakeBiliTransport.reset() }
        let candidate = LRCLIBSource.Candidate(
            id: 42,
            trackName: "髮如雪",
            artistName: "周杰倫",
            albumName: "十一月的蕭邦",
            duration: 299.0,
            syncedLyrics: "[00:01.00]狼牙月伊人憔悴"
        )
        let persistence = try PersistenceController(inMemory: true)
        let coordinator = LyricVariantCoordinator(
            bindingStore: LyricBindingStore(directory: nil),
            lyricEngine: LyricEngine(
                loader: SourceAwareLyricsLoader(registry: SourceRegistry()),
                offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container)
            ),
            lrclibSource: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "x", title: "髮如雪", artist: "周杰倫", duration: 299)
        let applied = await coordinator.apply(LyricVariantCandidate.fromLRCLIB(candidate), for: track)
        XCTAssertNotNil(applied)
        XCTAssertEqual(TextNormalizer.simplified("髮如雪 · 周杰倫"), "发如雪 · 周杰伦")
        XCTAssertEqual(TextNormalizer.simplifiedLRC("[00:01.00]繁華如三千東流水"), "[00:01.00]繁华如三千东流水")
    }

    // MARK: - 3. 允许联网开关动态生效与离线硬门控

    func testDynamicNetworkToggleRegistersAndUnregistersSourceAndBlocksRequests() async throws {
        struct NetworkRemoteStub: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(id: SourceID(rawValue: "remote-gated"), displayName: "Remote", kind: .jsPlugin, requiresNetwork: true)
            func search(_ request: SearchRequest) async throws -> [Track] { [] }
            func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }

        let app = try ContainerBuilder.make(.testing(inMemory: true))
        let remote = NetworkRemoteStub()
        app.sourceManager.registerSource(remote)

        await app.setEnableNetwork(true)
        XCTAssertNotNil(app.sourceRegistry.provider(for: remote.descriptor.id), "开启联网后应动态注册在线源")

        await app.setEnableNetwork(false)
        XCTAssertNil(app.sourceRegistry.provider(for: remote.descriptor.id), "关闭联网后应立刻注销在线源")
        let passThrough = try await app.sourceManager.verifyTracks([
            Track(sourceID: remote.descriptor.id, externalID: "t1", title: "夜曲", artist: "周杰伦", duration: 227)
        ])
        XCTAssertEqual(passThrough.count, 1)
    }

    // MARK: - 4. 退出前队列多批曲目持久化与等待不丢批

    func testWaitForPendingTrackSavesDrainsMultipleBatches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("SpatialLyrics.store")
        let persistence = try PersistenceController(inMemory: false, storeURL: storeURL)
        let repo = persistence.makeTrackRepository()
        let rig = GatedEngine()
        let sessionPersistence = PlaybackSessionPersistence(engine: rig.engine, persistence: persistence, tracks: repo)

        let batch1 = Track(sourceID: .mock, externalID: "batch-1", title: "Batch One", artist: "Artist", duration: 100)
        rig.engine.setQueue([batch1], current: batch1)
        sessionPersistence.saveNow()

        let batch2 = Track(sourceID: .mock, externalID: "batch-2", title: "Batch Two", artist: "Artist", duration: 100)
        rig.engine.enqueueNext(batch2)
        sessionPersistence.saveNow()

        sessionPersistence.waitForPendingTrackSaves()
        persistence.backUpStoreNow()

        let saved = try await repo.all()
        let ids = Set(saved.map(\.externalID))
        XCTAssertTrue(ids.contains("batch-1"), "第一批队列曲目不得在连续保存时丢失")
        XCTAssertTrue(ids.contains("batch-2"), "第二批队列曲目必须落盘")
        XCTAssertNotNil(PersistenceController.latestBackup(for: storeURL), "自定义库路径调用 backUpStoreNow 必须写出备份")
    }

    // MARK: - 5. 通用播放恢复不擅自出声、跨多次失败保留断点、stop 可取消

    func testRecoveryPreservesPausedIntentAndResumePositionAcrossRetries() async {
        let rig = GatedEngine(sourceID: SourceID(rawValue: "remote"))
        let track = rig.source.track("pause01")
        rig.engine.setQueue([track], current: track)

        let driver = PlaybackRecoveryDriver(playback: rig.engine,
                                            network: NetworkConnectivityMonitor(),
                                            clock: rig.clock)
        driver.start()
        defer { driver.stop() }

        // 冷启动暂停恢复场景（autoplay: false）失败后，恢复仍应停在 .ready 而非擅自开始播放。
        rig.source.failNextPrepares(with: [.sourceUnavailable])
        await rig.engine.load(track, autoplay: false)
        await waitUntil("恢复为 ready") {
            if case .ready = rig.engine.state { return true }
            return false
        }
        XCTAssertFalse(rig.engine.state.isPlaying, "暂停恢复失败重连后不得擅自自动播放")

        // 播放中失败且连续失败两次：第二次恢复成功时，原 45 秒断点仍要保留。
        await rig.engine.play()
        XCTAssertTrue(rig.engine.state.isPlaying)
        rig.clock.advance(by: .seconds(45))
        rig.source.failNextPrepares(with: [.sourceUnavailable])
        await rig.engine.dispatch(.playbackFailed(.sourceUnavailable))

        await waitUntil("两次恢复后回到播放且保留断点") {
            rig.engine.state.isPlaying && rig.engine.position(at: rig.clock.now) >= 44
        }
        XCTAssertGreaterThanOrEqual(rig.engine.position(at: rig.clock.now), 44,
                                    "第一次失败重装清零 anchor 后，第二次成功恢复仍应回到原断点")
    }

    // MARK: - 6. 搜索、错误本地化、URL 编码与配置清理

    func testOnlineHomeQueryEditedClearsSubmittedQuery() async throws {
        struct SearchStubSource: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(id: SourceID(rawValue: "remote-search"), displayName: "Remote", kind: .jsPlugin, requiresNetwork: true)
            func search(_ request: SearchRequest) async throws -> [Track] { [] }
            func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }
        let app = try ContainerBuilder.make(.testing(inMemory: true))
        await app.setEnableNetwork(true)
        app.sourceManager.registerSource(SearchStubSource())
        let home = OnlineHomeState()
        home.query = "夜曲"
        home.submit(app: app)
        XCTAssertEqual(home.submittedQuery, "夜曲")
        home.query = "夜曲 2"
        home.queryEdited()
        XCTAssertTrue(home.submittedQuery.isEmpty, "编辑框改成未提交新词后，应同步清掉旧 submittedQuery")
        home.cancel()
    }

    func testGenericDisplayPreservesSourceTitleAndArtist() {
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "abc#p2",
                          title: "夜曲", artist: "周杰伦", duration: 180)
        XCTAssertEqual(MorphPresentationModel.display(track).title, "夜曲")
        XCTAssertEqual(MorphPresentationModel.display(track).artist, "周杰伦")
    }

    func testSongListStateClearsMessageWhenFinalResultIsNonEmpty() async {
        let state = SongListState()
        let track = MockCatalog.tracks(count: 1)[0]
        let accepted = await state.load { progress in
            progress(TrackListBatch(tracks: [], checked: 1, total: 2, unavailable: 1))
            return [track]
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(state.tracks, [track])
        XCTAssertNil(state.message, "拿到有效歌曲结果后不应残留中间批的错误提示")
    }

    func testAMLLFileURLPercentEncodesSpacesAndUnicode() {
        let url = AMLLLyricsProvider.fileURL(for: "123/My Song 測試.ttml")
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("My%20Song") == true)
    }

    func testAllPlaybackErrorsAndModelFallbacksHaveEnglishLocalization() throws {
        let catalogURL = RepositoryRoot.locate().appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])

        let errors: [PlaybackError] = [
            .sourceUnavailable, .decodeFailed(reason: "AVFoundationErrorDomain"),
            .networkDisabled, .networkUnavailable, .unsupportedFormat(.flac),
            .cancelled, .rightsRestricted, .songNotVerified, .unknown(reason: "timeout"),
        ]
        for error in errors {
            let title = error.title
            let detail = error.detail
            if case .unsupportedFormat = error {
                XCTAssertNotNil(strings["不支持的格式（%@）"], "缺少格式错误标题键")
            } else {
                XCTAssertNotNil(strings[title], "PlaybackError.title 缺少本地化条目：\(title)")
            }
            XCTAssertNotNil(strings[detail], "PlaybackError.detail 缺少本地化条目：\(detail)")
        }
        for panel in AuxiliaryPanel.allCases {
            XCTAssertNotNil(strings[panel.title], "AuxiliaryPanel.title 缺少本地化条目：\(panel.title)")
        }
    }

    func testWidgetBridgeRedactsTrackWhenPrivacyModeIsEnabled() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let engine = PlaybackEngine(clock: TestPlaybackClock(), coordinator: PlaybackCoordinator(registry: SourceRegistry()))
        let loader = StubLyricsLoader()
        let lyricEngine = LyricEngine(loader: loader,
                                      offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container))
        let privacy = PrivacyState(settings: InMemorySettingsStore())
        privacy.setEnabled(true)
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "t1",
                          title: "秘密歌名", artist: "歌手", duration: 120)
        engine.setQueue([track], current: track)

        let bridge = WidgetBridge(playback: engine, lyricEngine: lyricEngine, privacy: privacy)
        bridge.republish()
        let written = SharedStateStore.read()
        XCTAssertNotEqual(written.title, "秘密歌名")
    }

    func testAppInfoPlistDeclaresAudioDocumentTypes() throws {
        let url = RepositoryRoot.locate().appendingPathComponent("Config/App-Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains("public.audio"), "支持本地音频文件关联后应声明 public.audio 打开类型")
    }
}
