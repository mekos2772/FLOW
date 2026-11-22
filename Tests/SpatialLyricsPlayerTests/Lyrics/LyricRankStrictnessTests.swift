import XCTest
@testable import SpatialLyricsPlayer

/// 歌词候选必须"真的像同一首"才采用。
///
/// 使用者反馈"歌词匹配错误"。`rank` 早就会过滤掉没有标题信号的候选，
/// 但当时的信号只是"包含关系"——短标题能蹭进不相干的歌里。
final class LyricRankStrictnessTests: XCTestCase {

    private func candidate(_ title: String, synced: Bool = true, duration: TimeInterval = 240) -> LRCLIBSource.Candidate {
        LRCLIBSource.Candidate(id: abs(title.hashValue), trackName: title, artistName: "某人",
                               albumName: "", duration: duration,
                               syncedLyrics: synced ? "[00:01.00]x" : nil)
    }

    func testGenericShortTitleNoLongerMatchesLongerSong() {
        // 「英雄」不该匹配到《英雄联盟 S16 主题曲》
        let ranked = LRCLIBSource.rank([candidate("英雄联盟S16主题曲")], title: "英雄",
                                       artist: nil, duration: nil)
        XCTAssertTrue(ranked.isEmpty, "包含关系但长度差太远，不该采用")
    }

    func testExactTitleStillMatches() {
        let ranked = LRCLIBSource.rank([candidate("夜曲")], title: "夜曲", artist: nil, duration: nil)
        XCTAssertEqual(ranked.count, 1)
    }

    func testParentheticalVariantStillMatches() {
        // normalize 会剥掉括号内容，「夜曲 (Live)」归一后就是「夜曲」
        let ranked = LRCLIBSource.rank([candidate("夜曲 (Live)")], title: "夜曲", artist: nil, duration: nil)
        XCTAssertEqual(ranked.count, 1, "同一首的 Live 版仍然要能配上")
    }
}
