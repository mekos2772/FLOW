import Foundation

/// 标准 WebDAV 网络存储音源：支持 `PROPFIND` 目录发现、Basic Auth 认证、同目录 `.lrc` 歌词与封面读取。
final class WebDAVSource:
    PlaybackSourceProvider,
    OfflineStreamDescriptorProviding,
    DiscoverableSourceProvider,
    @unchecked Sendable
{
    let config: ServerSourceConfig
    let supportsGaplessPrewarm = true
    private let secrets: any SecretStoring
    private let session: URLSession
    private let audioCache: MediaAudioCache
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let lock = NSLock()

    private var cachedTracks: [Track] = []
    private var audioURLByID: [String: URL] = [:]
    private var lrcURLByID: [String: URL] = [:]
    private var coverURLByID: [String: URL] = [:]

    private static let maxScanDepth = 2
    private static let coverNames: Set<String> = [
        "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png", "front.jpg"
    ]

    init(config: ServerSourceConfig,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         session: URLSession = .shared,
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         audioCache: MediaAudioCache = .shared) {
        self.config = config
        self.secrets = secrets
        self.session = session
        self.audioCache = audioCache
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
            supportsRelatedRadio: false,
            supportsQualitySelection: false,
            allowedDomains: config.allowedDomains
        )
    }

    func testConnection() async throws {
        guard let rootURL = config.baseURL else {
            throw PlaybackError.sourceUnavailable
        }
        _ = try await propfind(url: rootURL)
    }

    // MARK: - PlaybackSourceProvider

    func search(_ request: SearchRequest) async throws -> [Track] {
        let all = try await ensureIndexLoaded()
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [Track] = query.isEmpty
            ? all
            : all.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
                    || $0.externalID.localizedCaseInsensitiveContains(query)
            }
        return Array(matched.dropFirst(request.offset).prefix(request.limit))
    }

    func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
        let all = try await refreshIndex()
        let slice = Array(all.prefix(limit))
        progress?(TrackListBatch(tracks: slice, checked: slice.count, total: slice.count))
        return slice
    }

    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        guard track.sourceID == config.sourceID else { return nil }
        return try makeStreamDescriptor(for: track)
    }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        let stream = try makeStreamDescriptor(for: track)
        return try await RemoteStreamSessionFactory.makeSession(
            track: track,
            stream: stream,
            cache: audioCache,
            streamingAssetBuilder: streamingAssetBuilder
        )
    }

    private func makeStreamDescriptor(for track: Track) throws -> AudioStreamDescriptor {
        guard track.sourceID == config.sourceID else { throw PlaybackError.sourceUnavailable }
        let url: URL
        if let indexed = lock.withLock({ audioURLByID[track.externalID] }) {
            url = indexed
        } else if let direct = URL(string: track.externalID), direct.scheme != nil {
            url = direct
        } else {
            throw PlaybackError.sourceUnavailable
        }
        guard isSameOriginAsBase(url) else {
            throw PlaybackError.sourceUnavailable
        }
        let ext = url.pathExtension.lowercased()
        let losslessExt: Set<String> = ["flac", "wav", "aiff", "alac"]
        return AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: ext.isEmpty ? "mp3" : ext,
            qualityTier: losslessExt.contains(ext) ? .lossless : .high,
            qualityID: 0,
            codec: ext.isEmpty ? "AUDIO" : ext.uppercased(),
            bandwidth: 0,
            isLossless: losslessExt.contains(ext),
            url: url,
            headers: authHeaders(),
            allowedDomains: allowedBaseHosts
        )
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        session
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        let targetURL: URL?
        switch reference.media {
        case .embedded(let data):
            return data
        case .remote(let url), .file(let url):
            targetURL = url
        case .opaque(let id):
            targetURL = lock.withLock { coverURLByID[id] } ?? URL(string: id)
        }
        guard let url = targetURL, isSameOriginAsBase(url) else { return nil }
        return try await fetchData(url: url)
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        guard let lrcURL = lock.withLock({ lrcURLByID[track.externalID] }) else {
            return nil
        }
        let data = try await fetchData(url: lrcURL)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              let parsed = LRCParser.parse(text), !parsed.lines.isEmpty else {
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
        if let failure = error as? RemoteHTTPFailure {
            if failure.code == 401 || failure.code == 403 {
                return .rightsRestricted
            }
            return .sourceUnavailable
        }
        return defaultMap(error)
    }

    // MARK: - 目录扫描与 PROPFIND

    private func ensureIndexLoaded() async throws -> [Track] {
        let existing = lock.withLock { cachedTracks }
        if !existing.isEmpty { return existing }
        return try await refreshIndex()
    }

    private func refreshIndex() async throws -> [Track] {
        guard let rootURL = config.baseURL else {
            throw PlaybackError.sourceUnavailable
        }
        var visited = Set<String>()
        var allEntries: [WebDAVEntry] = []
        try await scanDirectory(rootURL, depth: 0, visited: &visited, output: &allEntries)

        var tracks: [Track] = []
        var audioMap: [String: URL] = [:]
        var lrcByStem: [String: URL] = [:]
        var folderCovers: [String: URL] = [:]

        for entry in allEntries where !entry.isDirectory {
            let ext = entry.url.pathExtension.lowercased()
            let folderKey = entry.url.deletingLastPathComponent().standardizedFileURL.path
            if ext == "lrc" {
                let stemKey = entry.url.deletingPathExtension().standardizedFileURL.path
                lrcByStem[stemKey] = entry.url
            } else if Self.coverNames.contains(entry.url.lastPathComponent.lowercased()) {
                folderCovers[folderKey] = entry.url
            }
        }

        var lrcMap: [String: URL] = [:]
        var coverMap: [String: URL] = [:]
        for entry in allEntries where !entry.isDirectory {
            let ext = entry.url.pathExtension.lowercased()
            guard LocalLibrarySource.supportedExtensions.contains(ext) else { continue }
            let id = entry.url.absoluteString
            let stemKey = entry.url.deletingPathExtension().standardizedFileURL.path
            let folderKey = entry.url.deletingLastPathComponent().standardizedFileURL.path
            let parsed = Self.parseTitleAndArtist(from: entry.url)

            audioMap[id] = entry.url
            if let lrcURL = lrcByStem[stemKey] {
                lrcMap[id] = lrcURL
            }
            let artRef: ArtworkReference?
            if let coverURL = folderCovers[folderKey] {
                coverMap[id] = coverURL
                artRef = ArtworkReference(.remote(coverURL))
            } else {
                artRef = nil
            }
            tracks.append(Track(
                sourceID: config.sourceID,
                externalID: id,
                title: parsed.title,
                artist: parsed.artist,
                duration: 0,
                artwork: artRef,
                lyrics: lrcByStem[stemKey].map { LyricsReference(.remote($0)) }
            ))
        }

        let sorted = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        lock.withLock {
            cachedTracks = sorted
            audioURLByID = audioMap
            lrcURLByID = lrcMap
            coverURLByID = coverMap
        }
        return sorted
    }

    private func scanDirectory(_ directoryURL: URL,
                               depth: Int,
                               visited: inout Set<String>,
                               output: inout [WebDAVEntry]) async throws {
        let key = directoryURL.standardizedFileURL.absoluteString
        guard visited.insert(key).inserted else { return }
        let entries = try await propfind(url: directoryURL)
        for entry in entries {
            let entryKey = entry.url.standardizedFileURL.absoluteString
            if entryKey == key || entryKey == "\(key)/" || "\(entryKey)/" == key {
                continue
            }
            output.append(entry)
            if entry.isDirectory && depth < Self.maxScanDepth {
                try await scanDirectory(entry.url, depth: depth + 1, visited: &visited, output: &output)
            }
        }
    }

    private func propfind(url: URL) async throws -> [WebDAVEntry] {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = NetworkTimeouts.api
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:resourcetype/>
            <D:getcontentlength/>
          </D:prop>
        </D:propfind>
        """
        request.httpBody = Data(body.utf8)

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: allowedBaseHosts,
            networkAllowed: { true }
        )
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.sourceUnavailable
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw RemoteHTTPFailure(code: http.statusCode,
                                    message: "WebDAV HTTP \(http.statusCode)",
                                    url: url.absoluteString)
        }
        return WebDAVXMLParser.parse(data: data, baseURL: url)
    }

    private func fetchData(url: URL) async throws -> Data {
        guard isSameOriginAsBase(url) else {
            throw PlaybackError.sourceUnavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkTimeouts.api
        for (k, v) in authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: allowedBaseHosts,
            networkAllowed: { true }
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaybackError.sourceUnavailable
        }
        return data
    }

    private var allowedBaseHosts: [String] {
        config.baseURL?.host.map { [$0] } ?? []
    }

    private func isSameOriginAsBase(_ url: URL) -> Bool {
        guard let base = config.baseURL else { return false }
        return SourceDomainPolicy.isSameOrigin(url, as: base)
    }

    private func authHeaders() -> [String: String] {
        let password = secrets.load(account: config.passwordAccountKey) ?? ""
        guard !config.username.isEmpty || !password.isEmpty else { return [:] }
        let raw = "\(config.username):\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return ["Authorization": "Basic \(encoded)"]
    }

    private static func parseTitleAndArtist(from url: URL) -> (title: String, artist: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        let decoded = stem.removingPercentEncoding ?? stem
        if let separator = decoded.range(of: " - ") {
            let artist = String(decoded[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(decoded[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return (title, artist)
            }
        }
        return (decoded, "")
    }
}

private struct WebDAVEntry: Sendable {
    let url: URL
    let isDirectory: Bool
}

private final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var entries: [WebDAVEntry] = []

    private var inResponse = false
    private var inResourceType = false
    private var currentHref = ""
    private var currentIsDirectory = false
    private var currentElement = ""

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parse(data: Data, baseURL: URL) -> [WebDAVEntry] {
        let delegate = WebDAVXMLParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...]).lowercased()
        }
        return elementName.lowercased()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        currentElement = name
        switch name {
        case "response":
            inResponse = true
            currentHref = ""
            currentIsDirectory = false
        case "resourcetype" where inResponse:
            inResourceType = true
        case "collection" where inResponse && inResourceType:
            currentIsDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inResponse, currentElement == "href" else { return }
        currentHref += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "resourcetype":
            inResourceType = false
        case "response":
            let trimmed = currentHref.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let url = resolveHref(trimmed) {
                entries.append(WebDAVEntry(url: url, isDirectory: currentIsDirectory))
            }
            inResponse = false
        default:
            break
        }
        if currentElement == name {
            currentElement = ""
        }
    }

    private func resolveHref(_ href: String) -> URL? {
        let candidate: URL?
        if let direct = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            candidate = direct
        } else {
            let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
            candidate = URL(string: encoded, relativeTo: baseURL)?.absoluteURL
        }
        guard let url = candidate, SourceDomainPolicy.isSameOrigin(url, as: baseURL) else {
            return nil
        }
        return url
    }
}
