import Foundation
@testable import SpatialLyricsPlayer

/// 可编程歌词加载器：按 externalID 预置文档，可选延迟，用来复现
/// 「快速连续切歌时旧歌词不能覆盖新歌词」这类竞态。
@MainActor
final class StubLyricsLoader: LyricsLoading {

    enum State: Equatable {
        case empty      // 未预置任何文档
        case loaded     // 至少预置了一条
    }

    private var stubs: [String: (LyricsDocument?, Duration)] = [:]

    var state: State { stubs.isEmpty ? .empty : .loaded }

    func stub(_ document: LyricsDocument?, for externalID: String, delay: Duration = .zero) {
        stubs[externalID] = (document, delay)
    }

    func loadLyrics(for track: Track) async -> LyricsDocument? {
        guard let entry = stubs[track.externalID] else { return nil }
        if entry.1 > .zero {
            try? await Task.sleep(for: entry.1)
        }
        return entry.0
    }
}

/// 歌词测试数据工厂。时间点由调用方给出，避免测试里散落魔法数字。
enum LyricsTestFixtures {

    static func track(externalID: String, title: String = "测试曲目") -> Track {
        Track.mock(externalID: externalID, title: title)
    }

    /// 按给定起点生成等间隔歌词行，每行持续到下一行开始。
    static func document(for track: Track, starts: [TimeInterval]) -> LyricsDocument {
        let lines = starts.enumerated().map { index, start -> LyricLine in
            let end = index + 1 < starts.count ? starts[index + 1] : start + 5
            return LyricLine(start: start, end: end, text: "\(track.externalID)-L\(index)")
        }
        return LyricsDocument(trackIdentity: TrackIdentity(sourceID: track.sourceID,
                                                          externalID: track.externalID),
                              lines: lines)
    }
}
