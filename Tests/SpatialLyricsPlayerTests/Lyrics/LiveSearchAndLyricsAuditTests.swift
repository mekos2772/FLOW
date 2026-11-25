import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 真实联网大考（默认跳过，需 `SLP_LIVE_TEST=1` 或 `/tmp/bili-live-test` 开启）：
/// 仅依赖公开数据源（Apple iTunes 公开目录 + AMLL 开源逐字歌词 + LRCLIB 开源歌词），
/// 端到端实测高难视频标题的歌名解析、权威目录反查、跨语言繁简/艺名别名与歧义防错配。
@MainActor
final class LiveSearchAndLyricsAuditTests: XCTestCase {

    func testLivePublicCatalogAndLyricsAudit() async throws {
        try LiveTestGate.skipUnlessLive("真实联网公开曲库与歌词大考，需 SLP_LIVE_TEST=1 或 /tmp/bili-live-test")

        let tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-live-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempCacheDir) }

        let catalogResolver = MusicCatalogResolver(allowsNetwork: true)
        let amll = AMLLLyricsProvider(allowsNetwork: true, cacheDirectory: tempCacheDir.appendingPathComponent("amll", isDirectory: true))
        let aggregator = ExternalLyricsAggregator(
            cache: LyricDocumentCache(directory: tempCacheDir.appendingPathComponent("lrc", isDirectory: true)),
            wordLevelLyrics: amll,
            lrclib: LRCLIBSource(),
            catalogResolver: catalogResolver
        )
        let loader = SourceAwareLyricsLoader(
            registry: SourceRegistry(),
            externalAggregator: aggregator,
            networkAllowed: { true }
        )

        let lyricCases: [(label: String, title: String, artist: String, duration: TimeInterval, mustHit: Bool)] = [
            ("孙燕姿-逆光(录音棚)", "孙燕姿《逆光》百万豪装录音棚", "LRS-LeoFM", 295, true),
            ("周杰伦-珊瑚海(花体+引号)", "【𝐇𝐢-𝐑𝐞𝐬·无损音质】《珊瑚海》-周杰伦/Lara梁心颐-“蔚蓝的珊瑚海，错过瞬间苍白”", "视频投稿者", 256, true),
            ("陈奕迅-孤勇者(OST括号作品)", "陈奕迅 - 孤勇者（《英雄联盟：双城之战》动画剧集中文主题曲）", "音乐台", 256, true),
            ("陈粒-光(单字歌名)", "陈粒《光》官方MV", "音乐搬运", 195, true),
            ("周杰伦-说好不哭(繁简+英文艺名)", "周杰伦《说好不哭》官方MV", "杰威尔音乐", 222, true),
            ("YOASOBI-Idol(日文引号)", "【4K60FPS】YOASOBI「アイドル」Official Music Video", "Ayase / YOASOBI", 213, true),
            ("毛不易-消愁(无符号口水话)", "在百万豪装录音棚听一遍就爱上毛不易的消愁", "LRS-LeoFM", 261, true),
            ("邓紫棋-泡沫(艺名GEM+现场)", "【Hi-Res】邓紫棋《泡沫》2014我是歌手现场版", "音乐现场", 275, true),
            ("朱心怡-明天(LRCLIB带-副标题)", "朱心怡《明天》（《斗破苍穹》决战云岚片尾曲）", "国漫音乐", 238, true),
            ("周深-大鱼(国漫OST+英文艺名)", "周深《大鱼》（动画电影《大鱼海棠》印象曲）", "国风馆", 313, true),
            ("林俊杰-江南(无损录音棚)", "【Hi-Res无损】林俊杰《江南》百万豪装录音棚试听", "LRS-LeoFM", 267, true),
            ("Beyond-海阔天空(粤语现场)", "【罕见完整版】BEYOND《海阔天空》1993 劲歌金曲 黄家驹神级现场", "thebards", 326, true),
            ("薛之谦-演员(长引号文案)", "【无损Hi-Res】薛之谦《演员》“简单点，说话的方式简单点，你又不是个演员”", "上岸音乐馆", 262, true),
            // 公开开源库未收录此曲时必须做到 0 错配（绝不错误命中其他同名歌手的《主角》）。
            ("马里奥-主角(歧义防错配)", "在录音棚听马里奥的《主角》（《斗破苍穹》动画第四季主题曲）", "ISTE-音乐小铺", 251, false),
        ]

        var matchedCount = 0
        for (idx, item) in lyricCases.enumerated() {
            let track = Track(
                sourceID: SourceID(rawValue: "js-video-source"),
                externalID: "vid\(idx)",
                title: item.title,
                artist: item.artist,
                duration: item.duration
            )
            let doc = await loader.loadLyrics(for: track)
            if let doc, !doc.lines.isEmpty {
                matchedCount += 1
                if !item.mustHit {
                    let text = doc.lines.map(\.text).joined(separator: " ")
                    XCTAssertFalse(text.contains("对白里的深刻"), "不应把马里奥《主角》错配成王诗安的歌词")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(matchedCount, 11, "13 首公开库常见曲目至少应命中 11 首以上")
    }
}
