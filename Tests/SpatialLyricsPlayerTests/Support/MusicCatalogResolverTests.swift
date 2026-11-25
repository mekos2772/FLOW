import Foundation
import XCTest
@testable import SpatialLyricsPlayer

final class MusicCatalogResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FakeBiliTransport.reset()
    }

    func testParsesITunesCatalogAndSimplifiesTraditionalChinese() {
        let json = #"""
        {
          "resultCount": 2,
          "results": [
            {
              "trackName": "主角 (《鬥破蒼穹》動畫第五季片尾曲)",
              "artistName": "馬里奧",
              "collectionName": "《鬥破蒼穹》動畫第五季原聲帶 - EP",
              "trackTimeMillis": 257600
            },
            {
              "trackName": "主角 (feat. 麻吉)",
              "artistName": "林俊傑",
              "collectionName": "JJ陸",
              "trackTimeMillis": 209300
            }
          ]
        }
        """#
        let entries = MusicCatalogResolver.parseITunesResponse(Data(json.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].artist, "马里奥")
        XCTAssertEqual(entries[0].canonicalTitle, "主角")
        XCTAssertEqual(entries[0].duration, 257.6, accuracy: 0.1)
        XCTAssertEqual(entries[1].artist, "林俊杰")
    }

    func testMatchesMessyColloquialBilibiliTitleAgainstAuthorityCatalog() {
        let entries = [
            MusicCatalogEntry(title: "主角 (《斗破苍穹》动画第五季片尾曲)", artist: "马里奥", album: "《斗破苍穹》动画第五季原声带", duration: 257.6, origin: .itunesPublic),
            MusicCatalogEntry(title: "主角", artist: "王诗安", album: "诗", duration: 270.9, origin: .itunesPublic),
            MusicCatalogEntry(title: "主角", artist: "林俊杰", album: "JJ陆", duration: 209.3, origin: .itunesPublic),
        ]

        // 既无书名号也无横线的口水话标题，纯靠权威目录双向正则/实体交叉即可精准识别。
        let matched = MusicCatalogResolver.matchTitleAgainstCatalog(
            rawTitle: "在百万豪装录音棚听一遍就爱上马里奥唱的斗破苍穹主角太好听了",
            rawArtist: "ISTE-音乐小铺",
            duration: 251,
            entries: entries
        )
        XCTAssertEqual(matched?.artist, "马里奥")
        XCTAssertEqual(matched?.canonicalTitle, "主角")

        // 非音乐游戏视频完全不命中权威目录。
        let nonMusic = MusicCatalogResolver.matchTitleAgainstCatalog(
            rawTitle: "我应该是最惨男主角了 宅男的人间冒险谷恒条野线结局",
            rawArtist: "中国BOY超级大猩猩",
            duration: 2851,
            entries: entries
        )
        XCTAssertNil(nonMusic)
    }

    func testPeerMusicPluginCatalogGuidesVideoPluginSearchAndTargetedSupplement() async throws {
        // 模拟用户导入的正规音乐插件（如 QQ 音乐插件）作为权威歌曲目录。
        struct StubQQMusicCatalog: PlaybackSourceProvider {
            let descriptor = SourceDescriptor(
                id: SourceID(rawValue: "js-qqmusic"),
                displayName: "QQ音乐",
                kind: .jsPlugin,
                requiresNetwork: true,
                supportsSearch: true,
                supportsLyrics: true
            )
            func search(_ request: SearchRequest) async throws -> [Track] {
                [
                    Track(sourceID: descriptor.id, externalID: "qq1", title: "主角", artist: "马里奥", album: "斗破苍穹原声带", duration: 257),
                    Track(sourceID: descriptor.id, externalID: "qq2", title: "主角", artist: "林俊杰", album: "JJ陆", duration: 209),
                ]
            }
            func makeSession(for track: Track) async throws -> any PlaybackSession { throw PlaybackError.sourceUnavailable }
            func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession { session }
            func artwork(for reference: ArtworkReference) async throws -> Data? { nil }
            func lyrics(for track: Track) async throws -> LyricsDocument? { nil }
            func map(_ error: any Error) -> PlaybackError { defaultMap(error) }
        }

        let registry = SourceRegistry()
        registry.register(StubQQMusicCatalog())
        let resolver = MusicCatalogResolver(allowsNetwork: true, registry: registry)

        let biliScript = #"""
        module.exports = {
          id: "bilibili-fetch",
          platform: "bilibili-fetch",
          version: "1.0.0",
          async search(query, page) {
            if (query === "主角") {
              return {
                isEnd: false,
                data: [
                  { id: "BV1bad1", title: "我应该是最惨男主角了｜宅男的人间冒险（谷恒条野线结局）", artist: "中国BOY", duration: 2851 },
                  { id: "BV1bad2", title: "【崩坏星穹铁道】主角最强命途！配队 光锥", artist: "梦轩dada", duration: 1075 }
                ]
              };
            }
            if (query === "主角 歌曲") {
              return {
                isEnd: true,
                data: [
                  { id: "BV1ok1", title: "王诗安《主角》现场版", artist: "音乐号", duration: 270 }
                ]
              };
            }
            if (query === "主角 马里奥") {
              return {
                isEnd: true,
                data: [
                  { id: "BV1mario", title: "在录音棚听马里奥的主角 斗破苍穹第四季", artist: "ISTE-音乐小铺", duration: 251 }
                ]
              };
            }
            if (query === "主角 林俊杰") {
              return {
                isEnd: true,
                data: [
                  { id: "BV1jj", title: "林俊杰《主角》官方MV", artist: "华纳音乐", duration: 210 }
                ]
              };
            }
            return { isEnd: true, data: [] };
          },
          async getMediaSource() { return null; }
        };
        """#

        let biliSource = try JSPluginSource(scriptSource: biliScript, fallbackID: "bilibili-fetch", catalogResolver: resolver)
        let hits = try await biliSource.search(SearchRequest(query: "主角", limit: 20))
        let ids = hits.map(\.externalID)
        XCTAssertTrue(ids.contains("BV1mario"), "应借 QQ 音乐目录自动补搜「主角 马里奥」：\(ids)")
        XCTAssertTrue(ids.contains("BV1jj"), "应借 QQ 音乐目录自动补搜「主角 林俊杰」：\(ids)")
        XCTAssertFalse(ids.contains("BV1bad1"))
        XCTAssertFalse(ids.contains("BV1bad2"))
    }

    func testCatalogReverseIdentificationUnlocksLyricsForColloquialBilibiliTitle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-catalog-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let itunesJSON = #"""
        {
          "resultCount": 1,
          "results": [
            {
              "trackName": "逆光",
              "artistName": "孫燕姿",
              "collectionName": "逆光",
              "trackTimeMillis": 294000
            }
          ]
        }
        """#

        FakeBiliTransport.routes = [
            ("itunes.apple.com/search", Data(itunesJSON.utf8)),
            ("lrclib.net/api/search", [
                [
                    "id": 8148836,
                    "trackName": "逆光",
                    "artistName": "坂本真綾",
                    "albumName": "JP",
                    "duration": 288.0,
                    "syncedLyrics": "[00:10.00]日文错歌词",
                ],
                [
                    "id": 29893399,
                    "trackName": "逆光",
                    "artistName": "孙燕姿",
                    "albumName": "逆光",
                    "duration": 294.0,
                    "syncedLyrics": "[00:10.00]也许我一直害怕有答案",
                ],
            ]),
        ]

        let resolver = MusicCatalogResolver(session: FakeBiliTransport.makeSession(), allowsNetwork: true)
        let aggregator = ExternalLyricsAggregator(
            cache: LyricDocumentCache(directory: dir),
            wordLevelLyrics: nil,
            lrclib: LRCLIBSource(session: FakeBiliTransport.makeSession()),
            catalogResolver: resolver
        )

        // 完全没有书名号与横线的口水话标题，且投稿人为 UP 主。
        let track = Track(
            sourceID: SourceID(rawValue: "js-bilibili-fetch"),
            externalID: "BV1sun999",
            title: "百万豪装录音棚听一遍就爱上孙燕姿逆光",
            artist: "LRS-LeoFM",
            duration: 295
        )
        let doc = try await aggregator.resolve(for: track, allowNetwork: true)
        XCTAssertEqual(doc?.lines.first?.text, "也许我一直害怕有答案",
                       "应借权威歌曲目录反推出孙燕姿《逆光》，不被时长接近的坂本真绫日文《逆光》错配")
    }
}
