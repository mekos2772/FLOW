import AVFoundation
import Foundation

/// 歌词来源协议。三层按顺序尝试：同目录 LRC → 音频内嵌 → 外部提供者。
protocol LyricsLoading: Sendable {
    func loadLyrics(for track: Track) async -> LyricsDocument?
}

/// 本地实现：只读用户已授权的文件，不联网。
struct FileLyricsLoader: LyricsLoading {
    func loadLyrics(for track: Track) async -> LyricsDocument? {
        if let document = await sidecarDocument(for: track) { return document }
        return await embeddedDocument(for: track)
    }

    private static let allowedSidecarExtensions: Set<String> = ["lrc", "txt"]
    private static let maxSidecarBytes = 2 * 1024 * 1024

    // MARK: - 同目录 .lrc

    private func sidecarDocument(for track: Track) async -> LyricsDocument? {
        if case let .file(url)? = track.lyrics?.media,
           Self.allowedSidecarExtensions.contains(url.pathExtension.lowercased()),
           let document = readDocument(at: url, track: track, source: .sidecar) {
            return document
        }

        guard let audioURL = resolveAudioURL(for: track) else { return nil }
        let lrcURL = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lrcURL.path) else { return nil }
        return readDocument(at: lrcURL, track: track, source: .sidecar)
    }

    private func readDocument(at url: URL, track: Track, source: LyricsSource) -> LyricsDocument? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxSidecarBytes,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maxSidecarBytes,
              !data.prefix(512).contains(0),
              let text = decode(data) else { return nil }
        return makeDocument(from: text, track: track, source: source)
    }

    /// 先试 UTF-8（含 BOM），失败再试 GB18030——中文 LRC 里大量是 GBK。
    private func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb18030)
    }

    // MARK: - 内嵌歌词

    private func embeddedDocument(for track: Track) async -> LyricsDocument? {
        guard let url = resolveAudioURL(for: track) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }

        for item in metadata {
            // 不同容器里歌词的标识不一样：ID3 是 USLT，iTunes 是 ©lyr，MP4 也有自己的键。
            // 统一按"标识里含 lyric"或 commonKey 命中来识别，避免依赖单一常量。
            let identifier = (item.identifier?.rawValue ?? "").lowercased()
            let commonKey = (item.commonKey?.rawValue ?? "").lowercased()
            let looksLikeLyrics = identifier.contains("lyric")
                || commonKey == "lyrics" || commonKey == "unsyncedlyrics"
            guard looksLikeLyrics else { continue }

            let loaded = try? await item.load(.stringValue)
            guard let text = loaded ?? nil else { continue }
            if let document = makeDocument(from: text, track: track, source: .embedded) {
                return document
            }
        }
        return nil
    }

    // MARK: - 工具

    private func makeDocument(from text: String, track: Track, source: LyricsSource) -> LyricsDocument? {
        guard let result = LRCParser.parse(text) else { return nil }
        return LyricsDocument(
            trackIdentity: track.identity,
            lines: result.lines,
            metadata: result.metadata,
            source: source,
            // `[offset:]` 已经由解析器折进每一行的时间里了，这里不能再传一次——
            // 之前两头各算一遍、方向相反，正好互相抵消：写了 offset 的歌词等于没写。
            synchronization: result.synchronization
        )
    }

    /// 同目录 `.lrc` 与内嵌歌词只在"曲目本身是文件"时有意义。
    /// 支持 `file://` URL 字符串以及本地普通文件路径。
    private func resolveAudioURL(for track: Track) -> URL? {
        if let url = URL(string: track.externalID), url.isFileURL { return url }
        if track.externalID.hasPrefix("/") { return URL(fileURLWithPath: track.externalID) }
        return nil
    }
}
