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
}
