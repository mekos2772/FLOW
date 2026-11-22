import Foundation

/// 歌词加载的统一策略。
///
/// 优先级顺序：
/// 1. 用户按 `TrackIdentity` 手动绑定的歌词版本（`LyricBindingStore`）；
/// 2. 数据源自身提供的原生歌词（本地 `.lrc` / 内嵌标签、OpenSubsonic、JS 插件或 B 站字幕）；
/// 3. 本地音频文件同目录 `.lrc` / 内嵌标签兜底（`FileLyricsLoader`）；
/// 4. 外部歌词聚合器（`ExternalLyricsAggregator`：磁盘缓存 → AMLL 逐字 TTML → LRCLIB）；
/// 5. 离线缓存歌词兜底（`offlineFallback`）。
struct SourceAwareLyricsLoader: LyricsLoading {
    let registry: SourceRegistry
    let local = FileLyricsLoader()
    var bindingStore: LyricBindingStore? = nil
    var externalAggregator: ExternalLyricsAggregator? = nil
    var networkAllowed: @Sendable () -> Bool = { true }
    var offlineFallback: (@Sendable (Track) async -> LyricsDocument?)? = nil

    func loadLyrics(for track: Track) async -> LyricsDocument? {
        if let bound = await bindingStore?.document(for: track), !bound.lines.isEmpty {
            return bound
        }
        if let provider = registry.provider(for: track.sourceID),
           let document = try? await provider.lyrics(for: track),
           !document.lines.isEmpty {
            return document
        }
        if let fileLyrics = await local.loadLyrics(for: track), !fileLyrics.lines.isEmpty {
            return fileLyrics
        }
        if track.sourceID != .mock,
           let externalAggregator,
           let external = try? await externalAggregator.resolve(for: track, allowNetwork: networkAllowed()),
           !external.lines.isEmpty {
            return external
        }
        if let offline = await offlineFallback?(track), !offline.lines.isEmpty {
            return offline
        }
        return nil
    }
}
