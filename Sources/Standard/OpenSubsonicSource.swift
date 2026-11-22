import CryptoKit
import Foundation
import Observation

/// 标准 OpenSubsonic / Subsonic / Navidrome 自建音乐服务器音源。
final class OpenSubsonicSource:
    PlaybackSourceProvider,
    OfflineStreamDescriptorProviding,
    DiscoverableSourceProvider,
    RelatedRadioSourceProvider,
    @unchecked Sendable
{
    let config: ServerSourceConfig
    private let secrets: any SecretStoring
    private let session: URLSession
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let lock = NSLock()
    private var preferredQuality: AudioQualityTier = .auto
    private var lastActualQuality: String?

    init(config: ServerSourceConfig,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         session: URLSession = .shared,
         streamingAssetBuilder: StreamingAssetBuilder? = nil) {
        self.config = config
        self.secrets = secrets
        self.session = session
        self.streamingAssetBuilder = streamingAssetBuilder
    }

    var descriptor: SourceDescriptor {
        SourceDescriptor(
            id: config.sourceID,
            displayName: config.displayName,
            kind: .standardServer,
            requiresNetwork: true,
            supportsSearch: true,
            supportsLyrics: true,
            supportsDiscover: true,
            supportsAccount: false,
            supportsRelatedRadio: true,
            supportsQualitySelection: true,
            allowedDomains: config.allowedDomains
        )
    }

    var currentQuality: AudioQualityTier {
        lock.withLock { preferredQuality }
    }

    var actualQualityDescription: String? {
        lock.withLock { lastActualQuality }
    }

    func updateQuality(_ tier: AudioQualityTier) {
        lock.withLock { preferredQuality = tier }
    }

    func testConnection() async throws {
        _ = try await requestEnvelope(endpoint: "ping.view")
    }

    // MARK: - PlaybackSourceProvider

    func search(_ request: SearchRequest) async throws -> [Track] {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await discoverTracks(limit: request.limit, progress: nil)
        }
        let response = try await requestEnvelope(
            endpoint: "search3.view",
            extraQuery: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "songCount", value: String(max(1, request.limit))),
                URLQueryItem(name: "songOffset", value: String(max(0, request.offset))),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
            ]
        )
        return (response.searchResult3?.song ?? []).map { makeTrack($0) }
    }

    func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
        let response = try await requestEnvelope(
            endpoint: "getRandomSongs.view",
            extraQuery: [URLQueryItem(name: "size", value: String(max(1, min(limit, 100))))]
        )
        let tracks = (response.randomSongs?.song ?? []).map { makeTrack($0) }
        progress?(TrackListBatch(tracks: tracks, checked: tracks.count, total: tracks.count))
        return tracks
    }

    func relatedTracks(for track: Track, limit: Int) async throws -> [Track] {
        guard track.sourceID == config.sourceID else { return [] }
        let response = try await requestEnvelope(
            endpoint: "getSimilarSongs2.view",
            extraQuery: [
                URLQueryItem(name: "id", value: track.externalID),
                URLQueryItem(name: "count", value: String(max(1, limit))),
            ]
        )
        return (response.similarSongs2?.song ?? []).map { makeTrack($0) }
    }

    var supportsGaplessPrewarm: Bool { true }

    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        guard track.sourceID == config.sourceID else { return nil }
        return try makeStreamDescriptor(for: track, quality: quality)
    }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let quality = lock.withLock { preferredQuality }
        let descriptor = try makeStreamDescriptor(for: track, quality: quality)
        let created = try await RemoteStreamSessionFactory.makeSession(
            track: track,
            stream: descriptor,
            streamingAssetBuilder: streamingAssetBuilder
        )
        noteActualQuality(for: descriptor)
        return created
    }

    func makePrewarmSession(for track: Track) async throws -> any PlaybackSession {
        guard track.sourceID == config.sourceID else {
            throw PlaybackError.sourceUnavailable
        }
        let quality = lock.withLock { preferredQuality }
        let descriptor = try makeStreamDescriptor(for: track, quality: quality)
        return try await RemoteStreamSessionFactory.makeSession(
            track: track,
            stream: descriptor,
            streamingAssetBuilder: streamingAssetBuilder
        )
    }

    func noteSessionPromoted(_ session: any PlaybackSession) {
        guard let httpSession = session as? HTTPStreamPlayerSession else { return }
        noteActualQuality(for: httpSession.stream)
    }

    private func makeStreamDescriptor(for track: Track,
                                      quality: AudioQualityTier) throws -> AudioStreamDescriptor {
        guard track.sourceID == config.sourceID else { throw PlaybackError.sourceUnavailable }
        var items = [URLQueryItem(name: "id", value: track.externalID)]
        switch quality {
        case .standard:
            items.append(URLQueryItem(name: "maxBitRate", value: "128"))
        case .high:
            items.append(URLQueryItem(name: "maxBitRate", value: "320"))
        case .auto, .hifi, .lossless, .hiRes:
            items.append(URLQueryItem(name: "format", value: "raw"))
        }
        guard let url = buildURL(endpoint: "stream.view", extraQuery: items) else {
            throw PlaybackError.sourceUnavailable
        }
        let (fileExt, qualityID, bandwidth): (String, Int, Int) = switch quality {
        case .standard: ("mp3", 128, 128_000)
        case .high: ("mp3", 320, 320_000)
        case .auto: ("flac", 990, 0)
        case .lossless, .hifi: ("flac", 995, 900_000)
        case .hiRes: ("flac", 999, 1_500_000)
        }
        return AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: fileExt,
            qualityTier: quality,
            qualityID: qualityID,
            codec: quality == .auto || quality.prefersLossless ? "RAW" : "MP3",
            bandwidth: bandwidth,
            isLossless: quality.prefersLossless,
            url: url
        )
    }

    private func noteActualQuality(for descriptor: AudioStreamDescriptor) {
        lock.withLock {
            lastActualQuality = descriptor.describe.isEmpty ? descriptor.qualityTier.displayName : descriptor.describe
        }
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        session
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        let coverID: String
        switch reference.media {
        case .embedded(let data):
            return data
        case .opaque(let id):
            coverID = id
        case .remote(let url):
            let (data, _) = try await session.data(from: url)
            return data.isEmpty ? nil : data
        case .file(let url):
            return try? Data(contentsOf: url)
        }
        guard let url = buildURL(
            endpoint: "getCoverArt.view",
            extraQuery: [
                URLQueryItem(name: "id", value: coverID),
                URLQueryItem(name: "size", value: "600"),
            ]
        ) else {
            return nil
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return data
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        if let structured = try? await requestEnvelope(
            endpoint: "getLyricsBySongId.view",
            extraQuery: [URLQueryItem(name: "id", value: track.externalID)]
        ),
           let doc = buildStructuredLyrics(structured.lyricsList?.structuredLyrics ?? [], identity: track.identity) {
            return doc
        }
        if let legacy = try? await requestEnvelope(
            endpoint: "getLyrics.view",
            extraQuery: [
                URLQueryItem(name: "artist", value: track.artist),
                URLQueryItem(name: "title", value: track.title),
            ]
        ),
           let value = legacy.lyrics?.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let lrc = LRCParser.parse(value), !lrc.lines.isEmpty {
                return LyricsDocument(
                    trackIdentity: track.identity,
                    lines: lrc.lines,
                    metadata: lrc.metadata,
                    source: .external,
                    synchronization: lrc.synchronization
                )
            }
            let lines = value
                .split(separator: "\n", omittingEmptySubsequences: true)
                .enumerated()
                .map { idx, text in LyricLine(start: TimeInterval(idx), text: String(text)) }
            return LyricsDocument(
                trackIdentity: track.identity,
                lines: lines,
                source: .external,
                synchronization: .unsynced
            )
        }
        return nil
    }

    func map(_ error: any Error) -> PlaybackError {
        if let failure = error as? RemoteHTTPFailure {
            if failure.code == 40 || failure.code == 50 || failure.code == 401 || failure.code == 403 {
                return .rightsRestricted
            }
            return .sourceUnavailable
        }
        return defaultMap(error)
    }

    // MARK: - 网络与协议解析

    private func buildURL(endpoint: String, extraQuery: [URLQueryItem] = []) -> URL? {
        guard let base = config.baseURL else { return nil }
        var url = base
        if !base.path.hasSuffix("/rest") {
            url.appendPathComponent("rest")
        }
        url.appendPathComponent(endpoint)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let password = secrets.load(account: config.passwordAccountKey) ?? ""
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let token = Self.md5Hex(password + salt)

        var items = [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "FLOW"),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: extraQuery)
        components.queryItems = items
        return components.url
    }

    private func requestEnvelope(endpoint: String, extraQuery: [URLQueryItem] = []) async throws -> SubsonicResponseBody {
        guard let url = buildURL(endpoint: endpoint, extraQuery: extraQuery) else {
            throw PlaybackError.sourceUnavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.api
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.sourceUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteHTTPFailure(code: http.statusCode,
                                    message: "OpenSubsonic HTTP \(http.statusCode)",
                                    url: url.absoluteString)
        }
        let root = try JSONDecoder().decode(SubsonicRoot.self, from: data)
        let body = root.subsonicResponse
        if body.status.lowercased() != "ok" {
            let code = body.error?.code ?? -1
            let message = body.error?.message ?? "Subsonic error"
            throw RemoteHTTPFailure(code: code, message: message, url: url.absoluteString)
        }
        return body
    }

    private func makeTrack(_ song: SubsonicSong) -> Track {
        Track(
            sourceID: config.sourceID,
            externalID: song.id,
            title: song.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? song.id,
            artist: song.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            album: song.album?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            duration: TimeInterval(song.duration ?? 0),
            artwork: song.coverArt.map { ArtworkReference(.opaque($0)) },
            lyrics: LyricsReference(.opaque(song.id))
        )
    }

    private func buildStructuredLyrics(_ list: [StructuredLyricTrack], identity: TrackIdentity) -> LyricsDocument? {
        guard let primary = list.first(where: { !$0.line.isEmpty }) else { return nil }
        let translationTrack = list.dropFirst().first { !$0.line.isEmpty && $0.lang != primary.lang }
        let lines: [LyricLine] = primary.line.enumerated().map { idx, item in
            let start = item.start.map { TimeInterval($0) / 1000.0 } ?? TimeInterval(idx)
            let translation: String? = translationTrack?.line.first { candidate in
                guard let s1 = item.start, let s2 = candidate.start else { return false }
                return abs(s1 - s2) <= 500
            }?.value
            return LyricLine(start: start, text: item.value, translation: translation)
        }
        return LyricsDocument(
            trackIdentity: identity,
            lines: lines,
            source: .external,
            synchronization: primary.synced ?? true ? .synced : .unsynced
        )
    }

    private static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 必须可观察：设置页的音质下拉框直接读 `currentQualityTier`，否则选完之后界面停在旧值。
@MainActor
@Observable
final class OpenSubsonicQualityController: QualitySelectableSourceController {
    @ObservationIgnored private let source: OpenSubsonicSource
    private(set) var currentQualityTier: AudioQualityTier

    init(source: OpenSubsonicSource) {
        self.source = source
        self.currentQualityTier = source.currentQuality
    }

    var lastActualQualityText: String? { source.actualQualityDescription }

    var availableQualityTiers: [AudioQualityTier] {
        [.auto, .standard, .high, .lossless]
    }

    func qualityRequirementHint(for tier: AudioQualityTier) -> String? {
        switch tier {
        case .auto, .lossless, .hifi, .hiRes:
            return String(localized: "请求服务器原始音频流（不转码）。")
        case .high:
            return String(localized: "请求最高 320 kbps 音频流，适合移动网络。")
        case .standard:
            return String(localized: "请求 128 kbps 省流转码音频。")
        }
    }

    func applyQuality(_ tier: AudioQualityTier) async -> String? {
        currentQualityTier = tier
        source.updateQuality(tier)
        return nil
    }
}

// MARK: - Subsonic JSON 模型

private struct SubsonicRoot: Decodable {
    let subsonicResponse: SubsonicResponseBody

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

private struct SubsonicResponseBody: Decodable {
    let status: String
    let error: SubsonicErrorBody?
    let searchResult3: SubsonicSongContainer?
    let randomSongs: SubsonicSongContainer?
    let similarSongs2: SubsonicSongContainer?
    let lyrics: SubsonicLegacyLyrics?
    let lyricsList: SubsonicLyricsList?
}

private struct SubsonicErrorBody: Decodable {
    let code: Int?
    let message: String?
}

private struct SubsonicSongContainer: Decodable {
    let song: [SubsonicSong]?
}

private struct SubsonicSong: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
}

private struct SubsonicLegacyLyrics: Decodable {
    let value: String?
}

private struct SubsonicLyricsList: Decodable {
    let structuredLyrics: [StructuredLyricTrack]?
}

private struct StructuredLyricTrack: Decodable {
    let synced: Bool?
    let lang: String?
    let line: [StructuredLyricLine]
}

private struct StructuredLyricLine: Decodable {
    let start: Int?
    let value: String
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
