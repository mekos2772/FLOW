import XCTest
@testable import SpatialLyricsPlayer

/// LRC 解析器在真实脏数据上的行为。
final class LRCParserRobustnessTests: XCTestCase {

    /// 标签里有 emoji / 组合字符时不能崩。
    ///
    /// 旧实现用 `NSRange.length`（UTF-16 码元数）去 `removeFirst`（按字符数）：
    /// `[by:🌸小樱🌸]` 是 11 个码元、9 个字符，越界直接让进程崩掉。歌词是先落盘再解析的，
    /// 崩过一次之后每次启动恢复上一首歌都会再崩一次。
    func testMetadataWithEmojiOrCombiningCharactersDoesNotCrash() throws {
        let text = """
        [by:🌸小樱🌸]
        [ar:ลิซ่า]
        [ti:I ❤️ U]
        [00:10.00]第一句
        """
        let result = try XCTUnwrap(LRCParser.parse(text))
        XCTAssertEqual(result.metadata.author, "🌸小樱🌸")
        XCTAssertEqual(result.metadata.artist, "ลิซ่า")
        XCTAssertEqual(result.lines.map(\.text), ["第一句"])
    }

    func testTimeTagFollowedByEmojiLyric() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:01.00]🎵 前奏 🎵\n[00:05.50]👨‍👩‍👧 一家人"))
        XCTAssertEqual(result.lines.map(\.text), ["🎵 前奏 🎵", "👨‍👩‍👧 一家人"])
    }

    func testSpaceBetweenTimeTagsIsNotTreatedAsLyric() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:10.00] [00:20.00]副歌"))
        XCTAssertEqual(result.lines.map(\.start), [10, 20])
        XCTAssertEqual(result.lines.map(\.text), ["副歌", "副歌"], "第二个时间标签不能被当成歌词正文显示出来")
    }

    func testHighPrecisionFractionIsAccepted() throws {
        let result = try XCTUnwrap(LRCParser.parse("[00:12.3456]高精度"))
        XCTAssertEqual(result.synchronization, .synced)
        XCTAssertEqual(try XCTUnwrap(result.lines.first).start, 12.345, accuracy: 0.001)
    }

    /// 行首到第一个词标签之间的文字从**行首**开始计时，而不是从 0 秒。
    func testLeadingTextBeforeFirstWordTagStartsAtLineStart() throws {
        let result = try XCTUnwrap(LRCParser.parse("[01:00.00]啊<01:01.00>你<01:02.00>好"))
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.segments.map(\.start), [60, 61, 62])
        XCTAssertEqual(try XCTUnwrap(line.filledFraction(at: 60)), 0, accuracy: 0.001,
                       "这一行刚开始唱，不该已经点亮了一大截")
    }

    /// `[offset:]` 只生效一次：解析器已经把它折进了每行时间，文档不能再带一份。
    func testOffsetIsAppliedExactlyOnce() async throws {
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "offset001",
                          title: "偏移测试", artist: "", album: nil, duration: 100)
        let aggregator = ExternalLyricsAggregator(
            wordLevelLyrics: nil,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let chosen = LRCLIBSource.Candidate(id: 1, trackName: "偏移测试", artistName: "", albumName: "",
                                            duration: 100, syncedLyrics: "[offset:500]\n[00:10.00]第一句")

        let loaded = try await aggregator.resolve(for: track, chosen: chosen, allowNetwork: true)
        let document = try XCTUnwrap(loaded)

        XCTAssertEqual(try XCTUnwrap(document.lines.first).start, 9.5, accuracy: 0.001)
        XCTAssertEqual(document.embeddedOffset, 0,
                       "再带一份偏移，引擎会把它反方向加回去——正好抵消，等于 offset 没写")
    }
}

/// 逐词 TTML。
final class TTMLWordSpacingTests: XCTestCase {

    func testSpacesBetweenWordSpansArePreserved() throws {
        let xml = """
        <tt><body><div><p begin="00:00.820" end="00:03.546"><span begin="00:00.820">Couldn</span><span begin="00:00.914">'</span><span begin="00:00.929">t</span> <span begin="00:01.002">beat</span> <span begin="00:01.300">her</span> <span begin="00:01.600">smile</span></p></div></body></tt>
        """
        let line = try XCTUnwrap(AMLLTTMLParser.parse(xml).first)
        XCTAssertEqual(line.text, "Couldn't beat her smile", "词与词之间的空格不能丢")
        XCTAssertEqual(line.segments.map(\.text).joined(), line.text, "逐字段拼起来必须等于整行（填充按它算）")
    }

    func testIndentationBetweenCJKSpansAddsNoSpaces() throws {
        let xml = """
        <tt><body><div>
          <p begin="00:01.000" end="00:03.000">
            <span begin="00:01.000">你</span>
            <span begin="00:02.000">好</span>
          </p>
        </div></body></tt>
        """
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "你好", "排版缩进不是歌词")
    }

    func testRomanisationIsNotPartOfTheLyric() throws {
        let xml = """
        <tt><body><div><p begin="00:01.000" end="00:03.000"><span begin="00:01.000">無敵の笑顔</span><span ttm:role="x-roman">muteki no egao</span></p></div></body></tt>
        """
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "無敵の笑顔")
    }

    /// 日文歌词不能被"繁转简"：「無敵の笑顔」会变成「无敌の笑颜」。
    func testJapaneseLyricsAreNotConvertedToSimplifiedChinese() throws {
        let xml = """
        <tt><body><div><p begin="00:01.000" end="00:03.000"><span begin="00:01.000">無敵</span><span begin="00:01.500">の</span><span begin="00:02.000">笑顔</span></p></div></body></tt>
        """
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "無敵の笑顔",
                       "逐词歌词里「無敵」单独成段：必须按整份文档判断语言")
        let lrc = try XCTUnwrap(LRCParser.parse("[ti:アイドル]\n[00:01.00]無敵の笑顔で荒らすメディア\n[00:05.00]誰もが目を奪われていく"))
        XCTAssertEqual(lrc.lines.first?.text, "無敵の笑顔で荒らすメディア")
        // 中文繁体照常转。
        XCTAssertEqual(LRCParser.parse("[00:01.00]英雄主義")?.lines.first?.text, "英雄主义")
    }

    func testLineWithoutEndBorrowsTheNextLineStart() throws {
        let xml = """
        <tt><body><div><p begin="00:04.000"><span begin="00:04.000">第一句</span></p><p begin="00:09.000"><span begin="00:09.000">第二句</span></p></div></body></tt>
        """
        let lines = AMLLTTMLParser.parse(xml)
        XCTAssertEqual(try XCTUnwrap(lines.first?.end), 9, accuracy: 0.001,
                       "没写 end 时用下一行的开始，不能是自己的 start（行长为 0）")
    }

    /// 手写文件里 span 内可能带排版换行/tab——不能进歌词文本（逐字计长会偏）。
    /// span 内的普通空格是词内内容（英文单词），不能删。
    func testNewlineAndTabInsideSpanAreNotPartOfTheLyric() throws {
        let xml = """
        <tt><body><div><p begin="00:01.000" end="00:03.000"><span begin="00:01.000">你\n好</span><span begin="00:02.000">呀\t呀</span></p></div></body></tt>
        """
        XCTAssertEqual(AMLLTTMLParser.parse(xml).first?.text, "你好呀呀",
                       "span 内的换行与 tab 不是歌词内容")
    }
}

/// 同名不等于同一首。
final class WordLevelLyricMatchingTests: XCTestCase {

    private func index(_ rows: [(String, [String], String)]) -> AMLLLyricsIndex {
        AMLLLyricsIndex(entries: rows.map { .init(musicName: $0.0, artists: $0.1, file: $0.2) })
    }

    func testReliableArtistMismatchIsRejected() {
        let library = index([("我们", ["草东没有派对"], "caodong.ttml")])
        XCTAssertNil(library.match(title: "我们", artist: "陈奕迅", artistIsReliable: true),
                     "标题里写明了是陈奕迅，库里那首是别人的")
    }

    func testUnreliableArtistFallsBackToTitleOnlyAndIsMarkedUnconfirmed() throws {
        let library = index([("我们", ["草东没有派对"], "caodong.ttml")])
        let match = try XCTUnwrap(library.match(title: "我们", artist: "某个UP主", artistIsReliable: false))
        XCTAssertFalse(match.isArtistConfirmed, "只凭歌名对上的，调用方必须再核对时长")
    }

    func testAmbiguousTitleWithoutArtistIsRejected() {
        let library = index([("怪物", ["YOASOBI"], "a.ttml"), ("怪物", ["MC HotDog"], "b.ttml")])
        XCTAssertNil(library.match(title: "怪物", artist: nil, artistIsReliable: false),
                     "库里有两首同名的歌，不知道歌手就不能瞎选")
    }

    func testNearMissTitlesNeedAnArtistMatch() {
        let library = index([("Love", ["OK Go"], "love.ttml"), ("Monsters", ["Katie Sky"], "m.ttml")])
        XCTAssertNil(library.match(title: "Lover", artist: "Taylor Swift", artistIsReliable: true))
        XCTAssertNil(library.match(title: "Monster", artist: nil, artistIsReliable: false),
                     "差一个字母的歌名只有歌手也对上才算")
        XCTAssertNotNil(library.match(title: "Monster", artist: "Katie Sky", artistIsReliable: true))
    }

    func testArtistMatchIsConfirmed() throws {
        let library = index([("Idol", ["Someone"], "x.ttml"), ("Idol", ["YOASOBI"], "y.ttml")])
        let match = try XCTUnwrap(library.match(title: "Idol", artist: "YOASOBI", artistIsReliable: true))
        XCTAssertEqual(match.entry.file, "y.ttml")
        XCTAssertTrue(match.isArtistConfirmed)
    }

    @MainActor
    func testDurationPlausibilityGuardsTitleOnlyMatches() {
        let lines = [LyricLine(start: 10, end: 14, text: "a"), LyricLine(start: 200, end: 206, text: "b")]
        XCTAssertTrue(AMLLLyricsProvider.isPlausible(lines: lines, duration: 215))
        XCTAssertFalse(AMLLLyricsProvider.isPlausible(lines: lines, duration: 150),
                       "歌词最后一句在曲子结束之后才开始：不是这条音频的歌词")
        XCTAssertFalse(AMLLLyricsProvider.isPlausible(lines: lines, duration: 500),
                       "曲子还有一大半，歌词早就唱完了")
        XCTAssertFalse(AMLLLyricsProvider.isPlausible(lines: lines, duration: 0), "时长未知时无从旁证")
    }
}

/// 歌词引擎：换歌与手动换版本。
@MainActor
final class LyricEngineHandoffTests: XCTestCase {

    private func makeEngine(loader: StubLyricsLoader) throws -> (LyricEngine, PersistenceController) {
        let persistence = try PersistenceController(inMemory: true)
        return (LyricEngine(loader: loader, offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container)),
                persistence)
    }

    /// 换歌的那一刻上一首的歌词就要撤掉，不能挂着等新歌词回来。
    func testPreviousLyricsDisappearAsSoonAsTheTrackChanges() async throws {
        let loader = StubLyricsLoader()
        let a = LyricsTestFixtures.track(externalID: "a")
        let b = LyricsTestFixtures.track(externalID: "b")
        loader.stub(LyricsTestFixtures.document(for: a, starts: [0, 10]), for: "a")
        loader.stub(LyricsTestFixtures.document(for: b, starts: [0, 10]), for: "b", delay: .milliseconds(400))
        let (engine, _) = try makeEngine(loader: loader)
        await engine.load(track: a)
        XCTAssertEqual(engine.snapshot(at: 1).current?.text, "a-L0")

        let loading = Task { await engine.load(track: b) }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(engine.state, .loading)
        XCTAssertNil(engine.document, "B 的歌词还在路上，屏幕上不能还是 A 的")
        XCTAssertNil(engine.snapshot(at: 1).current)

        await loading.value
        XCTAssertEqual(engine.snapshot(at: 1).current?.text, "b-L0")
    }

    /// 手动挑的版本不能被还在路上的自动加载盖回去。
    func testManualChoiceIsNotOverwrittenByALateAutomaticLoad() async throws {
        let loader = StubLyricsLoader()
        let a = LyricsTestFixtures.track(externalID: "a")
        loader.stub(LyricsTestFixtures.document(for: a, starts: [0]), for: "a", delay: .milliseconds(300))
        let (engine, _) = try makeEngine(loader: loader)

        let loading = Task { await engine.load(track: a) }
        try await Task.sleep(for: .milliseconds(80))
        let chosen = LyricsDocument(trackIdentity: a.identity, lines: [LyricLine(start: 0, text: "我挑的这一版")])
        engine.overrideDocument(chosen)
        await loading.value

        XCTAssertEqual(engine.snapshot(at: 1).current?.text, "我挑的这一版")
    }
}

/// 手动「换一版」必须真的换。
@MainActor
final class ManualLyricChoiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FakeBiliTransport.reset()
    }

    private func makeAggregator() -> ExternalLyricsAggregator {
        ExternalLyricsAggregator(
            cache: .shared,
            wordLevelLyrics: nil,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
    }

    func testChosenVariantBeatsTheCachedAutomaticMatch() async throws {
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "choose001",
                          title: "夜曲", artist: "周杰伦", album: nil, duration: 229)
        LyricDocumentCache.shared.store(
            identity: TrackIdentity.storageKey(track.identity),
            title: "夜曲",
            lrc: "[00:01.00]自动匹配的那一版"
        )
        let chosen = LRCLIBSource.Candidate(id: 7, trackName: "夜曲", artistName: "周杰伦", albumName: "",
                                            duration: 229, syncedLyrics: "[00:01.00]我手动挑的那一版")

        let document = try await makeAggregator().resolve(for: track, chosen: chosen, allowNetwork: true)
        XCTAssertEqual(document?.lines.first?.text, "我手动挑的那一版",
                       "缓存里有自动匹配的结果时，手动挑的版本被无视了")

        // 而且要记住：下次加载拿到的还是手动挑的那一版。
        let reloaded = try await makeAggregator().resolve(for: track, allowNetwork: true)
        XCTAssertEqual(reloaded?.lines.first?.text, "我手动挑的那一版")
    }

    func testCoordinatorAppliesTheChoiceToTheLyricEngine() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let track = Track(sourceID: SourceID(rawValue: "remote"), externalID: "apply0001",
                          title: "夜曲", artist: "周杰伦", album: nil, duration: 229)
        let loader = StubLyricsLoader()
        loader.stub(LyricsDocument(trackIdentity: track.identity,
                                   lines: [LyricLine(start: 0, text: "原来的")]), for: track.externalID)
        let engine = LyricEngine(loader: loader,
                                 offsets: SwiftDataLyricsOffsetStore(modelContainer: persistence.container))
        await engine.load(track: track)

        let coordinator = LyricVariantCoordinator(
            bindingStore: LyricBindingStore(directory: nil),
            lyricEngine: engine,
            lrclibSource: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let chosen = LRCLIBSource.Candidate(id: 7, trackName: "夜曲", artistName: "周杰伦", albumName: "",
                                            duration: 229, syncedLyrics: "[00:00.00]换上来的")

        let applied = await coordinator.apply(LyricVariantCandidate.fromLRCLIB(chosen), for: track)

        XCTAssertEqual(applied?.lines.count, 1)
        XCTAssertEqual(engine.snapshot(at: 1).current?.text, "换上来的")
    }

    /// 音源内置歌词失败时，外部歌词库（SourceAwareLyricsLoader → ExternalLyricsAggregator）仍必须兜底。
    func testSourceFailureStillFallsBackToTheExternalLibrary() async throws {
        struct FailingSource: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(id: SourceID(rawValue: "failing-sub"), displayName: "Failing")
            func search(_ request: SearchRequest) async throws -> [Track] { [] }
            func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { throw PlaybackError.sourceUnavailable }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }

        let source = FailingSource()
        let track = Track(sourceID: source.descriptor.id, externalID: "fallback1",
                          title: "夜曲", artist: "周杰伦", album: nil, duration: 229)
        LyricDocumentCache.shared.clear()
        FakeBiliTransport.routes = [
            ("lrclib.net", [["id": 1, "trackName": "夜曲", "artistName": "周杰伦", "albumName": "",
                             "duration": 229.0, "syncedLyrics": "[00:10.00]为你弹奏萧邦的夜曲"]]),
        ]

        let registry = SourceRegistry()
        registry.register(source)
        let loader = SourceAwareLyricsLoader(
            registry: registry,
            externalAggregator: makeAggregator(),
            networkAllowed: { true }
        )
        let document = await loader.loadLyrics(for: track)
        XCTAssertEqual(document?.lines.first?.text, "为你弹奏萧邦的夜曲")
    }
}
