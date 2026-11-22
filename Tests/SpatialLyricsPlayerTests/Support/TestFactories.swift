import Foundation
@testable import SpatialLyricsPlayer

/// 测试共用的装配工厂。
///
/// 与 `StubPlaybackController` 一样：只提供构造，不伪造业务行为。
/// 歌词偏移走内存实现，避免为了构造 `LyricEngine` 去读写磁盘。
@MainActor
func makeLyricEngine(_ persistence: PersistenceController) -> LyricEngine {
    LyricEngine(loader: FileLyricsLoader(),
                offsets: InMemoryLyricsOffsetStore())
}
