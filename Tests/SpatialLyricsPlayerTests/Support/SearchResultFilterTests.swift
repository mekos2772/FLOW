import Foundation
import XCTest
@testable import SpatialLyricsPlayer

final class SearchResultFilterTests: XCTestCase {

    private let biliFetchID = SourceID(rawValue: "js-bilibili-fetch")

    private func track(_ id: String, title: String, artist: String, duration: TimeInterval) -> Track {
        Track(sourceID: biliFetchID, externalID: id, title: title, artist: artist, duration: duration)
    }

    func testIdentifiesNonMusicVideoNoiseAndRequestsSupplement() {
        let noisyTracks = [
            track("1", title: "我应该是最惨男主角了｜宅男的人间冒险（谷恒条野线结局）", artist: "中国BOY超级大猩猩", duration: 47 * 60 + 31),
            track("2", title: "使命召唤最好结局！亲手把传奇主角全部消灭！！", artist: "老李船长", duration: 12 * 60 + 20),
            track("3", title: "【崩坏星穹铁道】主角最强命途！星铁版本草行久！超击破核心！配队 光锥...", artist: "梦轩dada", duration: 17 * 60 + 55),
            track("4", title: "主角穿越后当场成为别人新娘！【阅片无数动漫篇 02】", artist: "凉风Kaze", duration: 13 * 60 + 4),
            track("5", title: "直击电影《珍珠奶茶去珍珠》女主角小pa采访现场（没有这个电影哈", artist: "papi酱", duration: 5 * 60 + 11),
            track("6", title: "【天才简史-王阳明】中国近500年来第一人，爽文主角也不敢这么写！", artist: "天才简史", duration: 16 * 60 + 46),
        ]

        let assessment = SearchResultFilter.assess(noisyTracks, query: "主角", isVideoPlatformSource: true)
        XCTAssertEqual(assessment.noisyCount, 6)
        XCTAssertEqual(assessment.cleanMusicCount, 0)
        XCTAssertTrue(assessment.needsMusicIntentSupplement)
        XCTAssertFalse(assessment.refined.isEmpty, "全部命中噪声时应保底返回，不出现真空列表")
    }

    func testKeepsRealSongsIncludingStudioRecordingsAboveNoise() {
        let mixed = [
            track("1", title: "使命召唤最好结局！亲手把传奇主角全部消灭！！", artist: "老李船长", duration: 12 * 60 + 20),
            track("2", title: "直击电影《珍珠奶茶去珍珠》女主角小pa采访现场", artist: "papi酱", duration: 5 * 60 + 11),
            track("3", title: "孙燕姿《逆光》百万豪装录音棚 Hi-Res无损", artist: "LRS-LeoFM", duration: 4 * 60 + 55),
            track("4", title: "林俊杰《主角》官方MV 完整版", artist: "华纳音乐", duration: 3 * 60 + 42),
        ]

        let refined = SearchResultFilter.refine(mixed, query: "主角", isVideoPlatformSource: true)
        XCTAssertEqual(refined.map(\.externalID), ["4", "3"])
    }

    func testPureMusicSourceOrderIsPreservedWithoutSupplement() {
        let cleanID = SourceID(rawValue: "js-clean-music")
        let tracks = [
            Track(sourceID: cleanID, externalID: "a", title: "夜曲", artist: "周杰伦", duration: 229),
            Track(sourceID: cleanID, externalID: "b", title: "夜曲 (Live)", artist: "周杰伦", duration: 250),
        ]
        let assessment = SearchResultFilter.assess(tracks, query: "夜曲", isVideoPlatformSource: false)
        XCTAssertEqual(assessment.noisyCount, 0)
        XCTAssertFalse(assessment.needsMusicIntentSupplement)
        XCTAssertEqual(assessment.refined.map(\.externalID), ["a", "b"])
    }

    func testJSPluginAutomaticallySupplementsMusicIntentWhenVideoPluginReturnsNoise() async throws {
        let script = #"""
        module.exports = {
          id: "bilibili-fetch",
          platform: "bilibili-fetch",
          version: "1.0.0",
          async search(query, page) {
            if (query === "主角") {
              return {
                isEnd: false,
                data: [
                  { id: "BV1game00001", title: "我应该是最惨男主角了｜宅男的人间冒险（谷恒条野线结局）", artist: "中国BOY", duration: 2851 },
                  { id: "BV1game00002", title: "【崩坏星穹铁道】主角最强命途！配队 光锥", artist: "梦轩dada", duration: 1075 },
                  { id: "BV1cine00003", title: "直击电影《珍珠奶茶去珍珠》女主角采访现场", artist: "papi酱", duration: 311 }
                ]
              };
            }
            if (query === "主角 歌曲") {
              return {
                isEnd: true,
                data: [
                  { id: "BV1song00001", title: "林俊杰《主角》官方MV 完整版", artist: "音乐搬运", duration: 222 },
                  { id: "BV1song00002", title: "主角 - 林俊杰 现场版 Live", artist: "Live档案馆", duration: 235 },
                  { id: "BV1song00003", title: "【Hi-Res无损】《主角》纯享版", artist: "无损音乐", duration: 224 },
                  { id: "BV1song00004", title: "《主角》翻唱 Cover 完整版", artist: "翻唱UP", duration: 218 },
                  { id: "BV1song00005", title: "主角 - 录音棚试听版", artist: "LRS-LeoFM", duration: 226 }
                ]
              };
            }
            return { isEnd: true, data: [] };
          },
          async getMediaSource() { return null; }
        };
        """#

        let source = try JSPluginSource(scriptSource: script, fallbackID: "bilibili-fetch")
        let hits = try await source.search(SearchRequest(query: "主角", limit: 20))
        XCTAssertEqual(hits.count, 5)
        XCTAssertTrue(hits.allSatisfy { $0.externalID.hasPrefix("BV1song") }, "非音乐长视频应被滤掉并由音乐补搜替换：\(hits.map(\.title))")
        XCTAssertEqual(hits.first?.externalID, "BV1song00001")
    }

    func testMultiTokenQueryScoresNaturalLanguageSongTitleAboveMarioGames() {
        let items = [
            track("g1", title: "超级马里奥制造2 全结局速通攻略", artist: "游戏UP", duration: 840),
            track("s2", title: "林俊杰《主角》官方MV", artist: "华纳音乐", duration: 222),
            track("s1", title: "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季主题曲）", artist: "ISTE-音乐小铺", duration: 251),
        ]
        let refined = SearchResultFilter.refine(items, query: "马里奥 主角", isVideoPlatformSource: true)
        XCTAssertEqual(refined.map(\.externalID), ["s1", "s2"])
    }

    func testGenericNonMusicVideosWithoutBlacklistWordsStillTriggerSupplementAndGetEvicted() async throws {
        // 模拟搜「十年」时 B 站全站返回一堆没撞黑名单词、时长也在 4 分钟左右的泛生活视频。
        let script = #"""
        module.exports = {
          id: "bilibili-fetch",
          platform: "bilibili-fetch",
          version: "1.0.0",
          async search(query, page) {
            if (query === "十年") {
              return {
                isEnd: false,
                data: [
                  { id: "BV1vlog01", title: "十年后的中国会变成什么样", artist: "财经观察", duration: 260 },
                  { id: "BV1vlog02", title: "我在上海打拼十年的真实感悟", artist: "都市记录", duration: 240 },
                  { id: "BV1vlog03", title: "结婚十年夫妻的真实生活变化", artist: "情感日记", duration: 215 },
                  { id: "BV1vlog04", title: "十年老车翻新全过程记录", artist: "修车阿强", duration: 300 }
                ]
              };
            }
            if (query === "十年 歌曲") {
              return {
                isEnd: true,
                data: [
                  { id: "BV1song01", title: "陈奕迅《十年》官方MV 4K修复", artist: "环球音乐", duration: 206 },
                  { id: "BV1song02", title: "十年 - 陈奕迅 演唱会现场Live", artist: "Live档案馆", duration: 225 },
                  { id: "BV1song03", title: "【Hi-Res无损】陈奕迅《十年》纯享版", artist: "无损音乐馆", duration: 205 },
                  { id: "BV1song04", title: "《十年》翻唱 Cover 完整版", artist: "独立歌手", duration: 210 },
                  { id: "BV1song05", title: "陈奕迅 - 十年 录音棚试听", artist: "LRS-LeoFM", duration: 208 }
                ]
              };
            }
            return { isEnd: true, data: [] };
          },
          async getMediaSource() { return null; }
        };
        """#

        let source = try JSPluginSource(scriptSource: script, fallbackID: "bilibili-fetch")
        let hits = try await source.search(SearchRequest(query: "十年", limit: 20))
        XCTAssertEqual(hits.count, 5)
        XCTAssertTrue(hits.allSatisfy { $0.externalID.hasPrefix("BV1song") },
                      "无黑名单词的泛生活视频也应被主动音乐补搜并清退：\(hits.map(\.title))")
    }

    func testEvictsZeroRelevanceSplitTokenHitsAndRanksOriginalAboveAICover() {
        let catalog = [
            MusicCatalogEntry(title: "十年", artist: "陈奕迅", album: "黑白灰", duration: 205, origin: .itunesPublic)
        ]
        let items = [
            track("ai", title: "【AI林俊杰】《十年》（原唱：陈奕迅）", artist: "bibilil_lzr", duration: 208),
            track("off", title: "《我是你的小狗》~翻唱~ 虽然只能陪你十几个年头", artist: "翻唱UP", duration: 189),
            track("orig", title: "【Hi-Res无损】陈奕迅《十年》纯享版", artist: "无损音乐馆", duration: 205),
            track("mv", title: "陈奕迅 - 十年 官方MV 完整版", artist: "环球音乐", duration: 206),
            track("live", title: "十年 - 陈奕迅 演唱会现场Live", artist: "Live档案馆", duration: 225),
            track("studio", title: "在录音棚听陈奕迅《十年》", artist: "LRS-LeoFM", duration: 207),
        ]
        let assessment = SearchResultFilter.assess(
            items,
            query: "十年",
            isVideoPlatformSource: true,
            catalogEntries: catalog
        )
        let ids = assessment.refined.map(\.externalID)
        XCTAssertFalse(ids.contains("off"), "搜索词完全未出现的拆字翻唱应被清退：\(ids)")
        XCTAssertNotEqual(ids.first, "ai", "陈奕迅原唱应排在 AI 翻唱前面：\(ids)")
        XCTAssertTrue(["orig", "mv", "live", "studio"].contains(ids[0]))
    }
}
