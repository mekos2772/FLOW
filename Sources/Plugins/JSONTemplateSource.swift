import Foundation

/// 声明式 JSON API 音源模板定义（零脚本执行：URL 模板插值 + 请求头 + JSON 点分/回退路径提取）。
struct JSONTemplateDefinition: Codable, Equatable, Sendable {
    struct TrackFieldMap: Codable, Equatable, Sendable {
        var id: String = "id"
        var title: String = "title"
        var artist: String = "artist"
        var album: String? = "album"
        var duration: String? = "duration"
        var artwork: String? = "artwork"
        var streamUrl: String? = "url"
        var lyricsUrl: String? = nil
        var artworkTemplate: String? = nil
        var streamUrlTemplate: String? = nil
        var lyricsUrlTemplate: String? = nil

        init(id: String = "id",
             title: String = "title",
             artist: String = "artist",
             album: String? = "album",
             duration: String? = "duration",
             artwork: String? = "artwork",
             streamUrl: String? = "url",
             lyricsUrl: String? = nil,
             artworkTemplate: String? = nil,
             streamUrlTemplate: String? = nil,
             lyricsUrlTemplate: String? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artwork = artwork
            self.streamUrl = streamUrl
            self.lyricsUrl = lyricsUrl
            self.artworkTemplate = artworkTemplate
            self.streamUrlTemplate = streamUrlTemplate
            self.lyricsUrlTemplate = lyricsUrlTemplate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? "id"
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "title"
            artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? "artist"
            album = try c.decodeIfPresent(String.self, forKey: .album) ?? "album"
            duration = try c.decodeIfPresent(String.self, forKey: .duration) ?? "duration"
            artwork = try c.decodeIfPresent(String.self, forKey: .artwork) ?? "artwork"
            streamUrl = try c.decodeIfPresent(String.self, forKey: .streamUrl) ?? "url"
            lyricsUrl = try c.decodeIfPresent(String.self, forKey: .lyricsUrl)
            artworkTemplate = try c.decodeIfPresent(String.self, forKey: .artworkTemplate)
            streamUrlTemplate = try c.decodeIfPresent(String.self, forKey: .streamUrlTemplate)
            lyricsUrlTemplate = try c.decodeIfPresent(String.self, forKey: .lyricsUrlTemplate)
        }
    }

    struct ListEndpoint: Codable, Equatable, Sendable {
        var method: String? = "GET"
        var url: String
        var headers: [String: String]? = nil
        var itemsPath: String? = nil
        var fields: TrackFieldMap = TrackFieldMap()
        /// 部分公开接口返回的时长为毫秒而非秒，可设为 0.001。
        var durationScale: Double? = nil

        init(method: String? = "GET",
             url: String,
             headers: [String: String]? = nil,
             itemsPath: String? = nil,
             fields: TrackFieldMap = TrackFieldMap(),
             durationScale: Double? = nil) {
            self.method = method
            self.url = url
            self.headers = headers
            self.itemsPath = itemsPath
            self.fields = fields
            self.durationScale = durationScale
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
            url = try c.decode(String.self, forKey: .url)
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
            itemsPath = try c.decodeIfPresent(String.self, forKey: .itemsPath)
            fields = try c.decodeIfPresent(TrackFieldMap.self, forKey: .fields) ?? TrackFieldMap()
            durationScale = try c.decodeIfPresent(Double.self, forKey: .durationScale)
        }
    }

    struct ResolveEndpoint: Codable, Equatable, Sendable {
        /// `"json"`（默认请求并按 `streamUrlPath` 抽取）或 `"direct"`（直接将插值后 `url` 作为音流直链）。
        var mode: String? = nil
        var method: String? = "GET"
        var url: String
        var headers: [String: String]? = nil
        var streamUrlPath: String = "url"
        var headersPath: String? = nil
        var codec: String? = nil
        var fileExtension: String? = nil
        var bitrate: Int? = nil

        init(mode: String? = nil,
             method: String? = "GET",
             url: String,
             headers: [String: String]? = nil,
             streamUrlPath: String = "url",
             headersPath: String? = nil,
             codec: String? = nil,
             fileExtension: String? = nil,
             bitrate: Int? = nil) {
            self.mode = mode
            self.method = method
            self.url = url
            self.headers = headers
            self.streamUrlPath = streamUrlPath
            self.headersPath = headersPath
            self.codec = codec
            self.fileExtension = fileExtension
            self.bitrate = bitrate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode)
            method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
            url = try c.decode(String.self, forKey: .url)
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
            streamUrlPath = try c.decodeIfPresent(String.self, forKey: .streamUrlPath) ?? "url"
            headersPath = try c.decodeIfPresent(String.self, forKey: .headersPath)
            codec = try c.decodeIfPresent(String.self, forKey: .codec)
            fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
            bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        }
    }

    struct LyricsEndpoint: Codable, Equatable, Sendable {
        var method: String? = "GET"
        var url: String
        var headers: [String: String]? = nil
        var textPath: String? = "lrc"
    }

    var schema: String?
    var id: String
    var name: String
    var version: String?
    var allowedDomains: [String]?
    var headers: [String: String]?
    var search: ListEndpoint
    var discover: ListEndpoint?
    var resolve: ResolveEndpoint?
    var lyrics: LyricsEndpoint?

    init(schema: String? = nil,
         id: String,
         name: String,
         version: String? = nil,
         allowedDomains: [String]? = nil,
         headers: [String: String]? = nil,
         search: ListEndpoint,
         discover: ListEndpoint? = nil,
         resolve: ResolveEndpoint? = nil,
         lyrics: LyricsEndpoint? = nil) {
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.allowedDomains = allowedDomains
        self.headers = headers
        self.search = search
        self.discover = discover
        self.resolve = resolve
        self.lyrics = lyrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        let decodedName = try c.decodeIfPresent(String.self, forKey: .name)
        let decodedID = try c.decodeIfPresent(String.self, forKey: .id)
        name = decodedName ?? decodedID ?? "Custom JSON Source"
        id = decodedID ?? name
        version = try c.decodeIfPresent(String.self, forKey: .version)
        allowedDomains = try c.decodeIfPresent([String].self, forKey: .allowedDomains)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        search = try c.decode(ListEndpoint.self, forKey: .search)
        discover = try c.decodeIfPresent(ListEndpoint.self, forKey: .discover)
        resolve = try c.decodeIfPresent(ResolveEndpoint.self, forKey: .resolve)
        lyrics = try c.decodeIfPresent(LyricsEndpoint.self, forKey: .lyrics)
    }

    var sourceID: SourceID {
        let sanitized = SourceDomainPolicy.sanitizeID(id.isEmpty ? name : id, fallbackPrefix: "json")
        return SourceID(rawValue: "json-\(sanitized)")
    }
}

/// 基于 `JSONTemplateDefinition` 运行的纯声明式网络音源。
final class JSONTemplateSource: PlaybackSourceProvider, OfflineStreamDescriptorProviding, DiscoverableSourceProvider, @unchecked Sendable {
    let definition: JSONTemplateDefinition
    private let session: URLSession
    private let networkAllowed: @Sendable () -> Bool
    private let audioCache: MediaAudioCache
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let hlsAssetBuilder: HLSAssetBuilder?
    private let lock = NSLock()

    private var directStreamURLs: [TrackIdentity: URL] = [:]
    private var lyricsURLs: [TrackIdentity: URL] = [:]

    init(definition: JSONTemplateDefinition,
         session: URLSession = .shared,
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         audioCache: MediaAudioCache = .shared,
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         hlsAssetBuilder: HLSAssetBuilder? = nil) {
        self.definition = definition
        self.session = session
        self.networkAllowed = networkAllowed
        self.audioCache = audioCache
        self.streamingAssetBuilder = streamingAssetBuilder
        self.hlsAssetBuilder = hlsAssetBuilder
    }

    var descriptor: SourceDescriptor {
        SourceDescriptor(
            id: definition.sourceID,
            displayName: definition.name.isEmpty ? definition.id : definition.name,
            kind: .jsonTemplate,
            requiresNetwork: true,
            supportsSearch: true,
            supportsLyrics: definition.lyrics != nil,
            supportsDiscover: definition.discover != nil,
            supportsAccount: false,
            supportsRelatedRadio: false,
            supportsQualitySelection: false,
            allowedDomains: definition.allowedDomains ?? []
        )
    }

    func validateDefinition() throws {
        let rules = definition.allowedDomains ?? []
        var endpoints = [definition.search.url]
        if let d = definition.discover?.url { endpoints.append(d) }
        if let r = definition.resolve?.url { endpoints.append(r) }
        if let l = definition.lyrics?.url { endpoints.append(l) }
        for raw in endpoints {
            let sanitized = raw
                .replacingOccurrences(of: "{{query}}", with: "test")
                .replacingOccurrences(of: "{{limit}}", with: "20")
                .replacingOccurrences(of: "{{offset}}", with: "0")
                .replacingOccurrences(of: "{{page}}", with: "1")
                .replacingOccurrences(of: "{{id}}", with: "test-id")
                .replacingOccurrences(of: "{{title}}", with: "title")
                .replacingOccurrences(of: "{{artist}}", with: "artist")
            _ = try SourceDomainPolicy.validate(url: sanitized, allowedDomains: rules)
        }
    }

    // MARK: - PlaybackSourceProvider

    func search(_ request: SearchRequest) async throws -> [Track] {
        let page = max(1, (request.offset / max(1, request.limit)) + 1)
        let vars: [String: String] = [
            "query": request.query,
            "limit": String(max(1, request.limit)),
            "offset": String(max(0, request.offset)),
            "page": String(page),
        ]
        return try await fetchTrackList(endpoint: definition.search, variables: vars)
    }

    func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
        guard let discover = definition.discover else { return [] }
        let vars: [String: String] = [
            "query": "",
            "limit": String(max(1, limit)),
            "offset": "0",
            "page": "1",
        ]
        let tracks = try await fetchTrackList(endpoint: discover, variables: vars)
        progress?(TrackListBatch(tracks: tracks, checked: tracks.count, total: tracks.count))
        return tracks
    }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let descriptor = try await makeStreamDescriptor(for: track, quality: .high)
        return try await RemoteStreamSessionFactory.makeSession(
            track: track,
            stream: descriptor,
            cache: audioCache,
            streamingAssetBuilder: streamingAssetBuilder,
            hlsAssetBuilder: hlsAssetBuilder,
            session: session,
            networkAllowed: networkAllowed
        )
    }

    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        try await makeStreamDescriptor(for: track, quality: quality)
    }

    private func makeStreamDescriptor(for track: Track,
                                      quality: AudioQualityTier) async throws -> AudioStreamDescriptor {
        guard track.sourceID == definition.sourceID else {
            throw PlaybackError.sourceUnavailable
        }
        guard networkAllowed() else {
            throw PlaybackError.networkDisabled
        }
        let allowed = definition.allowedDomains ?? []
        var streamURL = lock.withLock { directStreamURLs[track.identity] }
            ?? persistedReference(for: track, key: "streamURL")
        var streamHeaders = definition.headers ?? [:]
        var codec = "AUDIO"
        var fileExt = "mp3"
        var bitrate = 0

        if let resolve = definition.resolve {
            let vars = ["id": track.externalID, "title": track.title, "artist": track.artist]
            if resolve.mode?.lowercased() == "direct" {
                streamURL = try buildURL(template: resolve.url, variables: vars)
            } else {
                let root = try await performJSONRequest(
                    method: resolve.method ?? "GET",
                    templateURL: resolve.url,
                    headers: mergedHeaders(resolve.headers),
                    variables: vars
                )
                if let resolvedString = JSONPathResolver.string(at: resolve.streamUrlPath, in: root) {
                    streamURL = try SourceDomainPolicy.validate(url: resolvedString, allowedDomains: allowed)
                }
                if let dynamicHeaders = JSONPathResolver.value(at: resolve.headersPath, in: root) as? [String: Any] {
                    for (k, v) in dynamicHeaders { streamHeaders[k] = "\(v)" }
                }
            }
            if let rHeaders = resolve.headers {
                for (k, v) in rHeaders { streamHeaders[k] = v }
            }
            if let c = resolve.codec, !c.isEmpty { codec = c }
            if let ext = resolve.fileExtension, !ext.isEmpty { fileExt = ext }
            if let br = resolve.bitrate { bitrate = br }
        }

        guard let finalURL = streamURL else {
            throw PlaybackError.sourceUnavailable
        }
        _ = try SourceDomainPolicy.validate(url: finalURL, allowedDomains: allowed)
        let inferredExt = finalURL.pathExtension.isEmpty ? fileExt : finalURL.pathExtension.lowercased()
        return AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: inferredExt,
            qualityTier: quality,
            qualityID: 0,
            codec: codec,
            bandwidth: bitrate,
            isLossless: inferredExt == "flac" || inferredExt == "wav",
            url: finalURL,
            headers: streamHeaders,
            allowedDomains: allowed
        )
    }

    private func persistedReference(for track: Track, key: String) -> URL? {
        guard let raw = track.persistentIdentifier,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else { return nil }
        return try? SourceDomainPolicy.validate(url: value, allowedDomains: definition.allowedDomains ?? [])
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        session
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        guard case .remote(let url) = reference.media else { return nil }
        guard networkAllowed() else { return nil }
        _ = try SourceDomainPolicy.validate(url: url, allowedDomains: definition.allowedDomains ?? [])
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.api
        for (k, v) in definition.headers ?? [:] {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: definition.allowedDomains ?? [],
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return data
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        guard networkAllowed() else { return nil }
        let customLyricsURL = lock.withLock { lyricsURLs[track.identity] }
            ?? persistedReference(for: track, key: "lyricsURL")
        let rawText: String?
        if let url = customLyricsURL {
            _ = try SourceDomainPolicy.validate(url: url, allowedDomains: definition.allowedDomains ?? [])
            rawText = try await performTextRequest(url: url, headers: definition.headers ?? [:])
        } else if let endpoint = definition.lyrics {
            let vars = ["id": track.externalID, "title": track.title, "artist": track.artist]
            let reqURL = try buildURL(template: endpoint.url, variables: vars)
            if let textPath = endpoint.textPath, !textPath.isEmpty {
                let jsonRoot = try await performJSONRequest(
                    method: endpoint.method ?? "GET",
                    templateURL: endpoint.url,
                    headers: mergedHeaders(endpoint.headers),
                    variables: vars
                )
                rawText = JSONPathResolver.string(at: textPath, in: jsonRoot)
            } else {
                rawText = try await performTextRequest(url: reqURL, headers: mergedHeaders(endpoint.headers))
            }
        } else {
            return nil
        }

        guard let text = rawText, let parsed = LRCParser.parse(text), !parsed.lines.isEmpty else {
            return nil
        }
        return LyricsDocument(
            trackIdentity: track.identity,
            lines: parsed.lines,
            metadata: parsed.metadata,
            source: .external,
            synchronization: parsed.synchronization
        )
    }

    func map(_ error: any Error) -> PlaybackError {
        if let violation = error as? SourceDomainPolicy.Violation {
            if case .networkDisabled = violation { return .networkDisabled }
            return .sourceUnavailable
        }
        return defaultMap(error)
    }

    // MARK: - 网络与映射辅助

    private func fetchTrackList(endpoint: JSONTemplateDefinition.ListEndpoint,
                                variables: [String: String]) async throws -> [Track] {
        let root = try await performJSONRequest(
            method: endpoint.method ?? "GET",
            templateURL: endpoint.url,
            headers: mergedHeaders(endpoint.headers),
            variables: variables
        )
        let listValue = JSONPathResolver.value(at: endpoint.itemsPath, in: root)
        guard let items = listValue as? [Any] else { return [] }

        let fields = endpoint.fields
        let scale = endpoint.durationScale ?? 1.0
        var tracks: [Track] = []
        for item in items {
            guard let id = JSONPathResolver.string(at: fields.id, in: item),
                  let title = JSONPathResolver.string(at: fields.title, in: item) else {
                continue
            }
            let artist = JSONPathResolver.string(at: fields.artist, in: item) ?? ""
            let album = JSONPathResolver.string(at: fields.album, in: item)
            let rawDuration = JSONPathResolver.double(at: fields.duration, in: item) ?? 0
            let duration = rawDuration > 0 ? rawDuration * scale : 0
            let trackVars = ["id": id, "title": title, "artist": artist]

            let artRef: ArtworkReference?
            if let artStr = JSONPathResolver.string(at: fields.artwork, in: item),
               let artURL = try? SourceDomainPolicy.validate(url: artStr, allowedDomains: definition.allowedDomains ?? []) {
                artRef = ArtworkReference(.remote(artURL))
            } else if let artTemplate = fields.artworkTemplate,
                      let artURL = try? buildURL(template: artTemplate, variables: trackVars) {
                artRef = ArtworkReference(.remote(artURL))
            } else {
                artRef = nil
            }

            var persistedReferences: [String: String] = [:]
            if let directStr = JSONPathResolver.string(at: fields.streamUrl, in: item),
               let directURL = try? SourceDomainPolicy.validate(url: directStr, allowedDomains: definition.allowedDomains ?? []) {
                lock.withLock { directStreamURLs[TrackIdentity(sourceID: definition.sourceID, externalID: id)] = directURL }
                persistedReferences["streamURL"] = directURL.absoluteString
            } else if let streamTemplate = fields.streamUrlTemplate,
                      let directURL = try? buildURL(template: streamTemplate, variables: trackVars) {
                lock.withLock { directStreamURLs[TrackIdentity(sourceID: definition.sourceID, externalID: id)] = directURL }
                persistedReferences["streamURL"] = directURL.absoluteString
            }
            if let lrcStr = JSONPathResolver.string(at: fields.lyricsUrl, in: item),
               let lrcURL = try? SourceDomainPolicy.validate(url: lrcStr, allowedDomains: definition.allowedDomains ?? []) {
                lock.withLock { lyricsURLs[TrackIdentity(sourceID: definition.sourceID, externalID: id)] = lrcURL }
                persistedReferences["lyricsURL"] = lrcURL.absoluteString
            } else if let lrcTemplate = fields.lyricsUrlTemplate,
                      let lrcURL = try? buildURL(template: lrcTemplate, variables: trackVars) {
                lock.withLock { lyricsURLs[TrackIdentity(sourceID: definition.sourceID, externalID: id)] = lrcURL }
                persistedReferences["lyricsURL"] = lrcURL.absoluteString
            }
            let persistentIdentifier: String?
            if let data = try? JSONSerialization.data(withJSONObject: persistedReferences, options: []),
               !persistedReferences.isEmpty {
                persistentIdentifier = String(data: data, encoding: .utf8)
            } else {
                persistentIdentifier = nil
            }
            let track = Track(
                sourceID: definition.sourceID,
                externalID: id,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                artwork: artRef,
                lyrics: LyricsReference(.opaque(id)),
                persistentIdentifier: persistentIdentifier
            )
            tracks.append(track)
        }
        return tracks
    }

    private func performJSONRequest(method: String,
                                    templateURL: String,
                                    headers: [String: String],
                                    variables: [String: String]) async throws -> Any {
        let url = try buildURL(template: templateURL, variables: variables)
        guard networkAllowed() else { throw PlaybackError.networkDisabled }
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = NetworkTimeouts.api
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: definition.allowedDomains ?? [],
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.sourceUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteHTTPFailure(code: http.statusCode,
                                    message: "JSON Template HTTP \(http.statusCode)",
                                    url: url.absoluteString)
        }
        let cleaned = SourceDomainPolicy.stripJSONP(data)
        return try JSONSerialization.jsonObject(with: cleaned)
    }

    private func performTextRequest(url: URL, headers: [String: String]) async throws -> String? {
        guard networkAllowed() else { throw PlaybackError.networkDisabled }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.api
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: definition.allowedDomains ?? [],
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private func buildURL(template: String, variables: [String: String]) throws -> URL {
        var rendered = template
        for (key, value) in variables {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? value
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: encoded)
        }
        return try SourceDomainPolicy.validate(url: rendered, allowedDomains: definition.allowedDomains ?? [])
    }

    private func mergedHeaders(_ extra: [String: String]?) -> [String: String] {
        var result = definition.headers ?? [:]
        if let extra {
            for (k, v) in extra { result[k] = v }
        }
        return result
    }
}
