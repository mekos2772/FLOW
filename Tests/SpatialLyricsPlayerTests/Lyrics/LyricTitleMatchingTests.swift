import XCTest
@testable import SpatialLyricsPlayer

/// 视频标题 → 歌名候选 → 歌词源验证。
///
/// 使用者反馈"很多歌因为标题匹配不到歌词"。标题样本取自真实曲库：
/// 同一首歌能写成「音质标签｜歌名 -歌手」「歌名-歌手」「歌手｜歌名 伴奏」「乐器  歌名  （难度）」。
/// 旧实现只押第一段当歌名，押错就整首没歌词；后面的候选即使查到了，也因为按第一段比对而被丢掉。
final class LyricTitleMatchingTests: XCTestCase {

    override func setUp() {
        FakeBiliTransport.reset()
    }

    private func titles(_ raw: String, guesses: Bool) -> [String] {
        LyricQueryNormalizer.titleCandidates(raw).filter { $0.isGuess == guesses }.map(\.title)
    }

    // MARK: - 候选生成

    func testQualityTagBeforePipeIsNotTheTitle() {
        let raw = "4K HIRES 96/24｜冬の花 -宫本浩次 「冬之花」（DRV重制升级版）"
        let normal = titles(raw, guesses: false)
        XCTAssertFalse(normal.contains { $0.contains("HIRES") || $0.contains("96") }, "\(normal)")
        XCTAssertTrue(normal.contains("冬の花"), "\(normal)")
        XCTAssertTrue(normal.contains("冬之花"), "引号里的译名也要查：\(normal)")
        XCTAssertNotEqual(LyricQueryNormalizer.parseTitle(raw).title, "HIRES 96")
    }

    func testTightDashPutsTitleFirstAndCreditSideIsArtist() {
        let parsed = LyricQueryNormalizer.parseTitle("【4K Hi-Res】珊瑚海-周杰伦&梁心颐")
        XCTAssertEqual(parsed.title, "珊瑚海")
        XCTAssertEqual(parsed.artist, "周杰伦")
    }

    func testSpacedDashKeepsArtistFirstConvention() {
        let parsed = LyricQueryNormalizer.parseTitle("【4K修复】周杰伦 梁心颐 - 珊瑚海 MV 2160P修复版")
        XCTAssertEqual(parsed.title, "珊瑚海")
        XCTAssertEqual(parsed.artist, "周杰伦")
        let western = LyricQueryNormalizer.parseTitle("Ed Sheeran - Shape of You [Official Video]")
        XCTAssertEqual(western.title, "Shape of You")
        XCTAssertEqual(western.artist, "Ed Sheeran")
    }

    func testEverySegmentAroundPipeAndWideSpacesIsACandidate() {
        XCTAssertTrue(titles("周杰伦 Lara梁心颐｜珊瑚海 伴奏", guesses: false).contains("珊瑚海"))
        XCTAssertTrue(titles("架子鼓  珊瑚海  （难度4星）", guesses: false).contains("珊瑚海"))
        XCTAssertTrue(titles("逆转时间的公式就是珍惜当下.【8D环绕】珊瑚海 #戴上耳机 #音乐分享", guesses: false).contains("珊瑚海"))
    }

    func testSuffixNoiseAndSlashAlternatives() {
        XCTAssertEqual(LyricQueryNormalizer.parseTitle("珊瑚海伴奏").title, "珊瑚海")
        XCTAssertEqual(titles("【AI宵宫】冬之花/冬の花", guesses: false), ["冬之花", "冬の花"])
        XCTAssertEqual(LyricQueryNormalizer.parseTitle("光遇：冬之花").title, "冬之花")
    }

    func testOriginalLanguageNameNextToBookTitleIsAlsoQueried() {
        XCTAssertEqual(titles("零基础学唱《冬之花》宫本浩次（冬の花），假名+罗马音+拼音", guesses: false), ["冬之花", "冬の花"])
        XCTAssertEqual(titles("【8K】MV 宮本浩次 《冬之花》「冬の花」—— 收藏级画质", guesses: false), ["冬之花", "冬の花"])
        XCTAssertEqual(LyricQueryNormalizer.parseTitle("YOASOBI「アイドル」 Official Music Video").title, "アイドル")
    }

    func testSpaceSeparatedWordsAndBracketContentsAreOnlyGuesses() {
        let spaced = "【sky光遇】珊瑚海 周杰伦 完整版高度还原 语瞳原创sky studio"
        XCTAssertTrue(titles(spaced, guesses: true).contains("珊瑚海"))
        XCTAssertFalse(titles(spaced, guesses: false).contains("周杰伦"))

        let bracket = "【珊瑚海 | 周杰伦&梁心颐 】转身离开 分手说不出来 -【年度MV展映厅】"
        XCTAssertTrue(titles(bracket, guesses: true).contains("珊瑚海"))
        XCTAssertEqual(titles("Long Song With Many Words", guesses: false), ["Long Song With Many Words"])
    }

    func testWholeTitleInsideBracketsIsARealCandidate() {
        XCTAssertEqual(titles("【珊瑚海】", guesses: false), ["珊瑚海"])
    }

    // MARK: - 歌手旁证

    func testMatchContextFindsArtistInTitleAcrossScripts() {
        let context = LyricQueryNormalizer.MatchContext("4K HIRES｜冬の花 -宫本浩次", "某投稿人")
        XCTAssertTrue(context.mentions(artist: "宮本浩次"), "日文汉字与简体写法应视为同一人")
        XCTAssertFalse(context.mentions(artist: "Hiroji Miyamoto"))
        XCTAssertTrue(LyricQueryNormalizer.MatchContext("珊瑚海 周杰伦").mentions(artist: "周杰伦/Lara梁心颐"))
        XCTAssertTrue(LyricQueryNormalizer.MatchContext("IU - Blueming").mentions(artist: "IU"))
        XCTAssertFalse(LyricQueryNormalizer.MatchContext("sky studio 琴谱").mentions(artist: "IU"), "短名字只认整词")
    }

    private func candidate(_ id: Int, _ title: String, _ artist: String, duration: TimeInterval = 255) -> [String: Any] {
        ["id": id, "trackName": title, "artistName": artist, "duration": duration, "syncedLyrics": "[00:01.00]\(title)"]
    }

    private func route(trackName: String, _ rows: [[String: Any]]) -> (match: String, body: Any?) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return ("track_name=" + trackName.addingPercentEncoding(withAllowedCharacters: allowed)!, rows)
    }

    private func aggregator() -> ExternalLyricsAggregator {
        ExternalLyricsAggregator(wordLevelLyrics: nil, lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession()))
    }

    func testLaterCandidateIsJudgedAgainstItsOwnTitle() async throws {
        // 第一个候选（引号里的译名）歌词库里没有；第二个候选查到了，必须按它自己的歌名比对。
        FakeBiliTransport.routes = [
            route(trackName: "冬の花", [candidate(1, "冬の花", "宮本浩次", duration: 241)]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(
            title: "4K HIRES 96/24｜冬の花 -宫本浩次 「冬之花」（DRV重制升级版）", artist: "投稿人", duration: 256)
        XCTAssertEqual(found.first?.trackName, "冬の花")
    }

    func testGuessIsAcceptedOnlyWhenArtistAppearsInTitle() async throws {
        FakeBiliTransport.routes = [
            route(trackName: "珊瑚海", [candidate(1, "珊瑚海", "周杰伦")]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let withArtist = try await aggregator().searchRelaxed(
            title: "【sky光遇】珊瑚海 周杰伦 完整版高度还原 语瞳原创sky studio", artist: "投稿人", duration: 256)
        XCTAssertEqual(withArtist.first?.trackName, "珊瑚海")

        FakeBiliTransport.requested = []
        let unrelated = try await aggregator().searchRelaxed(
            title: "得力 珊瑚海 A4 打印纸 70g 500张×8包 整箱4000张", artist: "投稿人", duration: 256)
        XCTAssertTrue(unrelated.isEmpty, "标题里碰巧有歌名、却没有歌手旁证的，不能配歌词")
    }

    func testArtistNameGuessCannotBecomeTheSong() async throws {
        // 「歌名-歌手」调换后的猜测是歌手名；歌词库里恰好有一首叫这个名字的歌，时长也接近。
        FakeBiliTransport.routes = [
            route(trackName: "周杰伦", [candidate(9, "周杰伦", "反方向的钟", duration: 256)]),
            route(trackName: "珊瑚海", [candidate(1, "珊瑚海", "周杰伦", duration: 255)]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(title: "周杰伦-珊瑚海", artist: "投稿人", duration: 256)
        XCTAssertEqual(found.first?.trackName, "珊瑚海", "有歌手旁证的结果优先于只是同名的结果")
    }

    func testCandidateWithArtistEvidenceBeatsEarlierUnconfirmedOne() async throws {
        // 「架子鼓」先查到一首同名歌（无旁证），「珊瑚海」没有歌手旁证也只是兜底；两者都无旁证时用先查到的。
        FakeBiliTransport.routes = [
            route(trackName: "珊瑚海", [candidate(1, "珊瑚海", "周杰伦", duration: 255)]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(title: "架子鼓  珊瑚海  （难度4星）", artist: "投稿人", duration: 259)
        XCTAssertEqual(found.first?.trackName, "珊瑚海")
    }

    func testOneFailedRequestDoesNotAbortTheWholeSearch() async throws {
        // 没有兜底路由：除「珊瑚海」外的请求都返回 404。
        FakeBiliTransport.routes = [route(trackName: "珊瑚海", [candidate(1, "珊瑚海", "周杰伦")])]
        let found = try await aggregator().searchRelaxed(title: "周杰伦 Lara梁心颐｜珊瑚海 伴奏", artist: "投稿人", duration: 256)
        XCTAssertEqual(found.first?.trackName, "珊瑚海")
        XCTAssertGreaterThan(FakeBiliTransport.requested.count, 1)
    }

    // MARK: - 书名号歌手提取、别名、单字歌名、视频源 UP 主隔离与繁体/镜像兜底

    func testExtractsArtistNextToBookTitleWithoutPollutingTitleCandidates() {
        let studio = LyricQueryNormalizer.parseTitle("孙燕姿《逆光》百万豪装录音棚")
        XCTAssertEqual(studio.title, "逆光")
        XCTAssertEqual(studio.artist, "孙燕姿")

        let coral = LyricQueryNormalizer.parseTitle("【4K顶级修复】《珊瑚海》—周杰伦 梁心颐 无损音质")
        XCTAssertEqual(coral.title, "珊瑚海")
        XCTAssertEqual(coral.artist, "周杰伦")

        let english = LyricQueryNormalizer.parseTitle("《Anti-Hero》-Taylor Swift【Official Audio】")
        XCTAssertEqual(english.title, "Anti-Hero")
        XCTAssertEqual(english.artist, "Taylor Swift")

        let phraseBefore = LyricQueryNormalizer.parseTitle("在专业录音棚听《珊瑚海》 - 周杰伦")
        XCTAssertEqual(phraseBefore.title, "珊瑚海")
        XCTAssertEqual(phraseBefore.artist, "周杰伦")
    }

    func testSingleCharacterBookTitleIsPreservedAndMatched() async throws {
        let parsed = LyricQueryNormalizer.parseTitle("陈粒《光》官方MV")
        XCTAssertEqual(parsed.title, "光")
        XCTAssertEqual(parsed.artist, "陈粒")

        FakeBiliTransport.routes = [
            route(trackName: "光", [candidate(1, "光", "陈粒", duration: 195)]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(title: "陈粒《光》官方MV", artist: "UP主", duration: 195)
        XCTAssertEqual(found.first?.trackName, "光")
        XCTAssertEqual(found.first?.artistName, "陈粒")
    }

    func testMatchContextRecognizesChineseEnglishArtistAliases() {
        let sun = LyricQueryNormalizer.MatchContext("孙燕姿《逆光》百万豪装录音棚", "LRS-LeoFM")
        XCTAssertTrue(sun.mentions(artist: "Stefanie Sun"))
        let jay = LyricQueryNormalizer.MatchContext("周杰伦《七里香》", "UP主")
        XCTAssertTrue(jay.mentions(artist: "Jay Chou"))
        let jj = LyricQueryNormalizer.MatchContext("林俊杰《主角》", "UP主")
        XCTAssertTrue(jj.mentions(artist: "JJ Lin"))
    }

    @MainActor
    func testBilibiliFetchUploaderDoesNotBlockAMLLMatchForSameTitledSongs() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-amll-bili-fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let indexJSONL = [
            #"{"metadata":[["musicName",["逆光"]],["artists",["其他歌手"]]],"rawLyricFile":"other.ttml"}"#,
            #"{"metadata":[["musicName",["逆光"]],["artists",["Stefanie Sun"]]],"rawLyricFile":"sun.ttml"}"#,
        ].joined(separator: "\n")
        try Data(indexJSONL.utf8).write(to: cacheDir.appendingPathComponent("amll-index.jsonl"))

        let sampleTTML = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="00:01.000" end="00:04.000"><span begin="00:01.000">也许我一直害怕有答案</span></p>
        </div></body></tt>
        """
        // 模拟 raw.githubusercontent.com 不可达，自动切 jsDelivr 镜像成功拉取 TTML。
        FakeBiliTransport.routes = [
            ("cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main/raw-lyrics/sun.ttml", Data(sampleTTML.utf8)),
        ]
        let amll = AMLLLyricsProvider(session: FakeBiliTransport.makeSession(), allowsNetwork: true, cacheDirectory: cacheDir)
        let agg = ExternalLyricsAggregator(
            cache: LyricDocumentCache(directory: cacheDir.appendingPathComponent("lrc", isDirectory: true)),
            wordLevelLyrics: amll,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let track = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1sun00001",
            title: "孙燕姿《逆光》百万豪装录音棚",
            artist: "LRS-LeoFM",
            duration: 295
        )
        let doc = try await agg.resolve(for: track, allowNetwork: true)
        XCTAssertEqual(doc?.lines.first?.text, "也许我一直害怕有答案")
    }

    @MainActor
    func testSuggestedQueryOmitsUntrustedVideoUploaderWhenTitleHasNoArtist() {
        let store = LyricBindingStore(directory: nil)
        let coordinator = LyricVariantCoordinator(bindingStore: store)
        let withoutArtist = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1x",
            title: "《逆光》无损纯享版",
            artist: "LRS-LeoFM",
            duration: 295
        )
        let suggested1 = coordinator.suggestedQuery(for: withoutArtist)
        XCTAssertEqual(suggested1.keyword, "逆光")
        XCTAssertEqual(suggested1.artist, "")

        let withArtist = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1y",
            title: "孙燕姿《逆光》百万豪装录音棚",
            artist: "LRS-LeoFM",
            duration: 295
        )
        let suggested2 = coordinator.suggestedQuery(for: withArtist)
        XCTAssertEqual(suggested2.keyword, "逆光")
        XCTAssertEqual(suggested2.artist, "孙燕姿")
    }

    func testTraditionalFallbackFindsTraditionalLRCLIBEntryWhenSimplifiedReturnsEmpty() async throws {
        FakeBiliTransport.routes = [
            route(trackName: "說好不哭", [candidate(10, "說好不哭", "Jay Chou", duration: 222)]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(
            title: "周杰伦《说好不哭》官方MV",
            artist: "UP主",
            duration: 262 // MV 前奏多 40 秒，因歌名精确且歌手别名命中而放行
        )
        XCTAssertEqual(found.first?.id, 10)
    }

    func testNaturalLanguagePrefixAndWorkReferenceBookTitleParsing() {
        let mario = "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季片尾曲）"
        let parsedMario = LyricQueryNormalizer.parseTitle(mario)
        XCTAssertEqual(parsedMario.title, "主角")
        XCTAssertEqual(parsedMario.artist, "马里奥")
        XCTAssertEqual(LyricQueryNormalizer.titleCandidates(mario).map(\.title), ["主角"],
                       "括号里的动画作品名《斗破苍穹》不应混入歌名候选")
        XCTAssertEqual(LyricQueryNormalizer.workHints(mario), ["斗破苍穹"])

        let ostOrder = "《斗破苍穹》动画第四季主题曲《主角》 - 马里奥"
        XCTAssertEqual(LyricQueryNormalizer.parseTitle(ostOrder).title, "主角")
        XCTAssertEqual(LyricQueryNormalizer.parseTitle(ostOrder).artist, "马里奥")
        XCTAssertEqual(LyricQueryNormalizer.workHints(ostOrder), ["斗破苍穹"])

        let movieOST = "电影《你的名字》主题曲《前前前世》RADWIMPS"
        XCTAssertEqual(LyricQueryNormalizer.parseTitle(movieOST).title, "前前前世")
        XCTAssertEqual(LyricQueryNormalizer.parseTitle(movieOST).artist, "RADWIMPS")

        XCTAssertEqual(LyricQueryNormalizer.parseTitle("戴上耳机听周杰伦的《晴天》").artist, "周杰伦")
        XCTAssertEqual(LyricQueryNormalizer.parseTitle("单曲循环陈奕迅的《孤勇者》").artist, "陈奕迅")
    }

    func testDifferentArtistSameShortTitleIsRejectedInsteadOfShowingWrongLyrics() async throws {
        // 复现真实截图：标题写明马里奥的《主角》，LRCLIB 只返回别歌手的同名《主角》，不能强行错配。
        FakeBiliTransport.routes = [
            route(trackName: "主角", [
                [
                    "id": 9001,
                    "trackName": "主角",
                    "artistName": "其他歌手",
                    "albumName": "某专辑",
                    "duration": 250.0,
                    "syncedLyrics": "[01:01.00]对白里的深刻 永远我都记得",
                ]
            ]),
            ("lrclib.net", [[String: Any]]()),
        ]
        let found = try await aggregator().searchRelaxed(
            title: "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季主题曲）",
            artist: "ISTE-音乐小铺",
            duration: 251
        )
        XCTAssertTrue(found.isEmpty, "明确歌手为马里奥时，不能把其他歌手的同名《主角》错配上来")
    }

    func testAmbiguousLRCLIBSameTitleWithoutArtistEvidenceIsRejected() {
        let candidates = [
            LRCLIBSource.Candidate(id: 1, trackName: "主角", artistName: "歌手甲", albumName: "", duration: 250, syncedLyrics: "[00:01.00]甲"),
            LRCLIBSource.Candidate(id: 2, trackName: "主角", artistName: "歌手乙", albumName: "", duration: 251, syncedLyrics: "[00:01.00]乙"),
        ]
        let context = LyricQueryNormalizer.MatchContext("《主角》纯享版", "某UP主")
        let ranked = LRCLIBSource.rank(candidates, title: "主角", artist: nil, duration: 251, context: context)
        XCTAssertTrue(ranked.isEmpty, "曲库存在多位不同歌手的同名歌且无歌手旁证时，不能盲选")
    }

    func testAlbumWorkContextAndStaleCacheEvictionMatchCorrectOSTLyrics() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-ost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = LyricDocumentCache(directory: dir)
        let track = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1mario0001",
            title: "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季主题曲）",
            artist: "ISTE-音乐小铺",
            duration: 251
        )
        // 预先写入一份历史错配的旧缓存（带不同歌手 [ar:]）。
        cache.store(
            identity: TrackIdentity.storageKey(track.identity),
            title: "主角",
            lrc: "[ar:其他歌手]\n[01:01.00]对白里的深刻 永远我都记得"
        )

        FakeBiliTransport.routes = [
            route(trackName: "主角", [
                [
                    "id": 9001,
                    "trackName": "主角",
                    "artistName": "其他歌手",
                    "albumName": "别的专辑",
                    "duration": 250.0,
                    "syncedLyrics": "[01:01.00]对白里的深刻 永远我都记得",
                ],
                [
                    "id": 9002,
                    "trackName": "主角",
                    "artistName": "马里奥",
                    "albumName": "斗破苍穹动画第四季原声带",
                    "duration": 251.0,
                    "syncedLyrics": "[00:10.00]我才是自己的主角",
                ],
            ]),
            ("lrclib.net", [[String: Any]]()),
        ]

        let agg = ExternalLyricsAggregator(
            cache: cache,
            wordLevelLyrics: nil,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession())
        )
        let doc = try await agg.resolve(for: track, allowNetwork: true)
        XCTAssertEqual(doc?.lines.first?.text, "我才是自己的主角", "应淘汰带矛盾歌手的旧缓存并命中马里奥版本")
    }

    func testParentheticalWorkBookTitleDoesNotSwallowUnbracketedSongTitle() {
        let cases: [(raw: String, expectedTitle: String, expectedArtist: String)] = [
            ("马里奥 - 主角（《斗破苍穹》动画第四季片尾曲）", "主角", "马里奥"),
            ("陈奕迅 - 孤勇者（《英雄联盟：双城之战》主题曲）", "孤勇者", "陈奕迅"),
            ("周深 - 大鱼（动画电影《大鱼海棠》印象曲）", "大鱼", "周深"),
        ]
        for item in cases {
            let parsed = LyricQueryNormalizer.parseTitle(item.raw)
            XCTAssertEqual(parsed.title, item.expectedTitle, item.raw)
            XCTAssertEqual(parsed.artist, item.expectedArtist, item.raw)
        }
    }

    func testHyphenatedOSTSubtitleAndInstrumentalPenaltyInLRCLIBRank() {
        let ost = LRCLIBSource.Candidate(
            id: 10363218,
            trackName: "明天 - 《斗破苍穹》决战云岚片尾曲",
            artistName: "朱心怡",
            albumName: "明天",
            duration: 238,
            syncedLyrics: "[00:10.00]第一句\n[00:15.00]第二句"
        )
        let context = LyricQueryNormalizer.MatchContext("朱心怡《明天》（《斗破苍穹》决战云岚片尾曲）", "UP主")
        let ostRanked = LRCLIBSource.rank([ost], title: "明天", artist: "朱心怡", duration: 238, context: context, artistIsReliable: true)
        XCTAssertEqual(ostRanked.first?.id, 10363218, "带 `- 《作品名》片尾曲` 副标题的官方歌名应精确匹配")

        let instPlaceholder = LRCLIBSource.Candidate(
            id: 30485747,
            trackName: "逆光",
            artistName: "孙燕姿",
            albumName: "伴奏",
            duration: 294,
            syncedLyrics: "[00:00.00]纯音乐，请欣赏"
        )
        let fullLyrics = (1...10).map { "[\(String(format: "00:%02d.00", $0 * 5))]第\($0)句" }.joined(separator: "\n")
        let realSong = LRCLIBSource.Candidate(
            id: 29893399,
            trackName: "逆光",
            artistName: "孙燕姿",
            albumName: "逆光",
            duration: 294,
            syncedLyrics: fullLyrics
        )
        let sunContext = LyricQueryNormalizer.MatchContext("孙燕姿《逆光》百万豪装录音棚", "LRS-LeoFM")
        let sunRanked = LRCLIBSource.rank([instPlaceholder, realSong], title: "逆光", artist: "孙燕姿", duration: 295, context: sunContext, artistIsReliable: true)
        XCTAssertEqual(sunRanked.map(\.id), [29893399], "纯音乐占位和伴奏条目不应击败完整人声歌词")
    }

    func testCrossSourceLyricProviderFallbackFetchesVerifiedLyricsWhenAMLLAndLRCLIBMiss() async {
        struct PeerLyricsProvider: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(
                id: SourceID(rawValue: "js-peer-lyrics"),
                displayName: "PeerLyrics",
                kind: .jsPlugin,
                requiresNetwork: true,
                supportsSearch: true,
                supportsLyrics: true
            )
            let items: [Track]
            let lyricsByExternalID: [String: LyricsDocument]

            func search(_ request: SearchRequest) async throws -> [Track] { items }
            func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { lyricsByExternalID[track.externalID] }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }

        let registry = SourceRegistry()
        let peerID = SourceID(rawValue: "js-peer-lyrics")
        let wrongTrack = Track(sourceID: peerID, externalID: "p-wrong", title: "主角", artist: "王诗安", duration: 251)
        let rightTrack = Track(sourceID: peerID, externalID: "p-right", title: "主角 - 《斗破苍穹》第四季片尾曲", artist: "马里奥", duration: 251)
        let rightDoc = LyricsDocument(
            trackIdentity: rightTrack.identity,
            lines: [LyricLine(start: 10, text: "马里奥正版歌词")],
            source: .external,
            synchronization: .synced
        )
        let wrongDoc = LyricsDocument(
            trackIdentity: wrongTrack.identity,
            lines: [LyricLine(start: 10, text: "王诗安错误歌词")],
            source: .external,
            synchronization: .synced
        )
        registry.register(PeerLyricsProvider(
            items: [wrongTrack, rightTrack],
            lyricsByExternalID: ["p-wrong": wrongDoc, "p-right": rightDoc]
        ))

        let loader = SourceAwareLyricsLoader(registry: registry, externalAggregator: nil, networkAllowed: { true })
        let biliTrack = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1mario999",
            title: "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季片尾曲）",
            artist: "ISTE-音乐小铺",
            duration: 251
        )
        let loaded = await loader.loadLyrics(for: biliTrack)
        XCTAssertEqual(loaded?.lines.first?.text, "马里奥正版歌词")
        XCTAssertEqual(loaded?.trackIdentity, biliTrack.identity)
    }
}
