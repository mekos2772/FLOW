import Foundation

struct SourceSubscriptionManifest: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let name: String?
        let title: String?
        let version: String?
        let url: String?
        let srcUrl: String?
        let link: String?
        let userVariables: [String: String]?

        init(name: String? = nil,
             title: String? = nil,
             version: String? = nil,
             url: String? = nil,
             srcUrl: String? = nil,
             link: String? = nil,
             userVariables: [String: String]? = nil) {
            self.name = name
            self.title = title
            self.version = version
            self.url = url
            self.srcUrl = srcUrl
            self.link = link
            self.userVariables = userVariables
        }

        var resolvedName: String? {
            let raw = (name ?? title)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }

        var resolvedURLString: String? {
            url ?? srcUrl ?? link
        }
    }

    let plugins: [Entry]?
    let sources: [Entry]?
    let feeds: [Entry]?

    var allEntries: [Entry] {
        plugins ?? sources ?? feeds ?? []
    }

    static func parseEntries(from data: Data) -> [Entry]? {
        var rawText = String(data: data, encoding: .utf8) ?? ""
        if rawText.hasPrefix("\u{FEFF}") {
            rawText.removeFirst()
        }
        let cleanData = SourceDomainPolicy.stripJSONP(Data(rawText.utf8))
        let trimmed = (String(data: cleanData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{"),
           let manifest = try? JSONDecoder().decode(SourceSubscriptionManifest.self, from: cleanData),
           !manifest.allEntries.isEmpty {
            return manifest.allEntries.filter { $0.resolvedURLString?.isEmpty == false }
        }
        if trimmed.hasPrefix("[") {
            if let arrayEntries = try? JSONDecoder().decode([Entry].self, from: cleanData) {
                let valid = arrayEntries.filter { $0.resolvedURLString?.isEmpty == false }
                if !valid.isEmpty { return valid }
            }
            if let urlStrings = try? JSONDecoder().decode([String].self, from: cleanData),
               !urlStrings.isEmpty {
                return urlStrings.map { Entry(url: $0) }
            }
        }
        return nil
    }
}

/// 持久化管理用户导入的第三方 `.js` 音源插件与 `.json` 接口模板。
final class ImportedSourceStore: @unchecked Sendable {
    struct Record: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case jsPlugin
            case jsonTemplate
        }

        let sourceID: String
        let kind: Kind
        let filename: String
        let originURL: String?
    }

    enum ImportedProvider: Sendable {
        case js(JSPluginSource)
        case json(JSONTemplateSource)
        case server(ServerSourceConfig, password: String?)

        var sourceID: SourceID {
            switch self {
            case .js(let s): return s.descriptor.id
            case .json(let s): return s.descriptor.id
            case .server(let c, _): return c.sourceID
            }
        }
    }

    private struct ServerPresetPayload: Decodable {
        let schema: String?
        let kind: String?
        let type: String?
        let id: String?
        let displayName: String?
        let name: String?
        let baseURL: String?
        let url: String?
        let username: String?
        let password: String?

        func toConfig() -> (ServerSourceConfig, String?)? {
            let rawKind = (kind ?? type ?? "").lowercased()
            let parsedKind: ServerSourceConfig.ProtocolKind
            if rawKind == "opensubsonic" || rawKind == "subsonic" || rawKind == "navidrome" {
                parsedKind = .openSubsonic
            } else if rawKind == "webdav" {
                parsedKind = .webDAV
            } else {
                return nil
            }
            guard let rawBase = baseURL ?? url,
                  let normalized = ServerSourceConfig.normalizedBaseURL(from: rawBase) else {
                return nil
            }
            let title = (displayName ?? name ?? normalized.host ?? parsedKind.displayName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let config = ServerSourceConfig(
                id: id ?? SourceDomainPolicy.sanitizeID(title, fallbackPrefix: rawKind),
                kind: parsedKind,
                displayName: title.isEmpty ? parsedKind.displayName : title,
                baseURLString: normalized.absoluteString,
                username: username ?? ""
            )
            return (config, password)
        }
    }

    let directory: URL
    private let session: URLSession
    private let secrets: any SecretStoring
    private let networkAllowed: @Sendable () -> Bool
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let hlsAssetBuilder: HLSAssetBuilder?
    private let lock = NSLock()

    static var defaultDirectory: URL {
        if let sandbox = RuntimeSandbox.dataDirectory {
            return sandbox.appendingPathComponent("ImportedSources", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SpatialLyricsPlayer/ImportedSources", isDirectory: true)
    }

    init(directory: URL = ImportedSourceStore.defaultDirectory,
         session: URLSession = .shared,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         hlsAssetBuilder: HLSAssetBuilder? = nil) {
        self.directory = directory
        self.session = session
        self.secrets = secrets
        self.networkAllowed = networkAllowed
        self.streamingAssetBuilder = streamingAssetBuilder
        self.hlsAssetBuilder = hlsAssetBuilder
    }

    private var indexURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    func loadRecords() -> [Record] {
        lock.withLock { loadRecordsUnlocked() }
    }

    func restoreAll() -> [ImportedProvider] {
        let records = loadRecords()
        var restored: [ImportedProvider] = []
        for record in records {
            let fileURL = directory.appendingPathComponent(record.filename)
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
            switch record.kind {
            case .jsPlugin:
                if let script = String(data: data, encoding: .utf8),
                   let source = try? JSPluginSource(
                       scriptSource: script,
                       fallbackID: fileURL.deletingPathExtension().lastPathComponent,
                       session: session,
                       secrets: secrets,
                       networkAllowed: networkAllowed,
                       streamingAssetBuilder: streamingAssetBuilder,
                       hlsAssetBuilder: hlsAssetBuilder
                   ) {
                    restored.append(.js(source))
                }
            case .jsonTemplate:
                if let definition = try? JSONDecoder().decode(JSONTemplateDefinition.self, from: data) {
                    let source = JSONTemplateSource(
                        definition: definition,
                        session: session,
                        networkAllowed: networkAllowed,
                        streamingAssetBuilder: streamingAssetBuilder,
                        hlsAssetBuilder: hlsAssetBuilder
                    )
                    if (try? source.validateDefinition()) != nil {
                        restored.append(.json(source))
                    }
                }
            }
        }
        return restored
    }

    func importFromURL(_ url: URL) async throws -> [ImportedProvider] {
        let targetURL: URL
        if url.isFileURL {
            targetURL = url
            let data = try Data(contentsOf: targetURL)
            return try await importPayload(data: data, filenameHint: targetURL.lastPathComponent, originURL: nil)
        }
        targetURL = SourceDomainPolicy.normalizeImportURL(url.absoluteString) ?? url
        _ = try SourceDomainPolicy.validate(url: targetURL, allowedDomains: [])
        guard networkAllowed() else {
            throw PlaybackError.networkDisabled
        }

        let candidates = SourceDomainPolicy.rawGitHubMirrorCandidates(for: targetURL)
        var lastError: Error?
        for candidateURL in candidates {
            try Task.checkCancellation()
            guard networkAllowed() else {
                throw PlaybackError.networkDisabled
            }
            var request = URLRequest(url: candidateURL)
            request.timeoutInterval = NetworkTimeouts.api
            do {
                let (data, response) = try await PluginHTTPClient.data(
                    for: request,
                    session: session,
                    allowedDomains: [],
                    networkAllowed: networkAllowed
                )
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    lastError = RemoteHTTPFailure(
                        code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        message: String(localized: "下载音源插件失败"),
                        url: candidateURL.absoluteString
                    )
                    continue
                }
                return try await importPayload(data: data, filenameHint: targetURL.lastPathComponent, originURL: targetURL.absoluteString)
            } catch is CancellationError {
                throw CancellationError()
            } catch let violation as SourceDomainPolicy.Violation {
                if case .networkDisabled = violation {
                    throw PlaybackError.networkDisabled
                }
                lastError = violation
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteHTTPFailure(
            code: -1,
            message: String(localized: "下载音源插件失败"),
            url: targetURL.absoluteString
        )
    }

    func remove(sourceID: SourceID) {
        lock.withLock {
            var records = loadRecordsUnlocked()
            let targets = records.filter { $0.sourceID == sourceID.rawValue }
            records.removeAll { $0.sourceID == sourceID.rawValue }
            for target in targets {
                let fileURL = directory.appendingPathComponent(target.filename)
                try? FileManager.default.removeItem(at: fileURL)
            }
            saveRecordsUnlocked(records)
        }
    }

    // MARK: - 导入分发

    func importPayload(data: Data, filenameHint: String, originURL: String?) async throws -> [ImportedProvider] {
        let ext = (filenameHint as NSString).pathExtension.lowercased()
        let stem = (filenameHint as NSString).deletingPathExtension
        let rawText = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let cleanData = SourceDomainPolicy.stripJSONP(Data(rawText.utf8))
        let trimmed = (String(data: cleanData, encoding: .utf8) ?? rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeScript = rawText.contains("module.exports")
            || rawText.contains("exports.")
            || rawText.contains("globalThis.lx")
            || rawText.contains("lx.on(")
            || rawText.contains("@name")

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || (ext == "json" && !looksLikeScript) {
            if let batch = try await importJSONCollectionIfPresent(data: cleanData, trimmed: trimmed, originURL: originURL) {
                return batch
            }
            if let serverPreset = try? JSONDecoder().decode(ServerPresetPayload.self, from: cleanData),
               let (config, password) = serverPreset.toConfig() {
                return [.server(config, password: password)]
            }
            return [try importJSONTemplate(data: cleanData, originURL: originURL)]
        }

        if ext == "js" || looksLikeScript {
            return [try importJSScript(script: rawText, fallbackID: stem, originURL: originURL)]
        }

        throw RemoteHTTPFailure(
            code: -1,
            message: String(localized: "不支持的音源文件格式，仅支持 .js 插件与 .json 接口模板"),
            url: originURL ?? filenameHint
        )
    }

    private func importJSONCollectionIfPresent(data: Data,
                                               trimmed: String,
                                               originURL: String?) async throws -> [ImportedProvider]? {
        let entries: [SourceSubscriptionManifest.Entry]
        if trimmed.hasPrefix("{"),
           let manifestEntries = SourceSubscriptionManifest.parseEntries(from: data) {
            entries = manifestEntries
        } else if trimmed.hasPrefix("[") {
            if let arrayTemplates = try? JSONDecoder().decode([JSONTemplateDefinition].self, from: data),
               !arrayTemplates.isEmpty {
                return try arrayTemplates.map { def in
                    let encoded = try JSONEncoder().encode(def)
                    return try importJSONTemplate(data: encoded, originURL: originURL)
                }
            }
            if let arrayServers = try? JSONDecoder().decode([ServerPresetPayload].self, from: data) {
                let presets = arrayServers.compactMap { $0.toConfig() }
                if !presets.isEmpty {
                    return presets.map { .server($0.0, password: $0.1) }
                }
            }
            if let manifestEntries = SourceSubscriptionManifest.parseEntries(from: data) {
                entries = manifestEntries
            } else {
                return nil
            }
        } else {
            return nil
        }

        let baseOrigin = originURL.flatMap { SourceDomainPolicy.normalizeImportURL($0) ?? URL(string: $0) }
        var imported: [ImportedProvider] = []
        var firstError: (any Error)?
        for entry in entries {
            guard let rawLink = entry.resolvedURLString,
                  let remote = SourceDomainPolicy.resolveImportURL(rawLink, relativeTo: baseOrigin) else {
                continue
            }
            // 联网下载的订阅清单只能引用 http(s) 子条目：不能借清单读用户本机的 file:// 文件。
            if baseOrigin != nil, !["http", "https"].contains(remote.scheme?.lowercased() ?? "") {
                continue
            }
            do {
                let sub = try await importFromURL(remote)
                if let vars = entry.userVariables, !vars.isEmpty {
                    for provider in sub {
                        if case .js(let js) = provider {
                            js.runtime.saveUserVariables(vars)
                        }
                    }
                }
                imported.append(contentsOf: sub)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
                RedactingLog.info("Subscription item skipped: \(rawLink) (\(error.localizedDescription))")
            }
        }
        guard !imported.isEmpty else {
            throw firstError ?? RemoteHTTPFailure(
                code: -1,
                message: String(localized: "订阅清单里没有可导入的音源"),
                url: originURL ?? "subscription.json"
            )
        }
        return imported
    }

    private func importJSScript(script: String, fallbackID: String, originURL: String?) throws -> ImportedProvider {
        let source = try JSPluginSource(
            scriptSource: script,
            fallbackID: fallbackID.isEmpty ? "plugin" : fallbackID,
            session: session,
            secrets: secrets,
            networkAllowed: networkAllowed,
            streamingAssetBuilder: streamingAssetBuilder,
            hlsAssetBuilder: hlsAssetBuilder
        )
        let safeID = SourceDomainPolicy.sanitizeID(source.manifest.id, fallbackPrefix: "js")
        let filename = "\(safeID).js"
        try persistFile(Data(script.utf8),
                        filename: filename,
                        record: Record(sourceID: source.descriptor.id.rawValue, kind: .jsPlugin, filename: filename, originURL: originURL))
        return .js(source)
    }

    private func importJSONTemplate(data: Data, originURL: String?) throws -> ImportedProvider {
        let definition = try JSONDecoder().decode(JSONTemplateDefinition.self, from: data)
        let source = JSONTemplateSource(
            definition: definition,
            session: session,
            networkAllowed: networkAllowed,
            streamingAssetBuilder: streamingAssetBuilder,
            hlsAssetBuilder: hlsAssetBuilder
        )
        try source.validateDefinition()
        let safeID = SourceDomainPolicy.sanitizeID(definition.id.isEmpty ? definition.name : definition.id, fallbackPrefix: "json")
        let filename = "\(safeID).json"
        try persistFile(data,
                        filename: filename,
                        record: Record(sourceID: source.descriptor.id.rawValue, kind: .jsonTemplate, filename: filename, originURL: originURL))
        return .json(source)
    }

    private func persistFile(_ data: Data, filename: String, record: Record) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            var records = loadRecordsUnlocked()
            records.removeAll { $0.sourceID == record.sourceID }
            records.append(record)
            saveRecordsUnlocked(records)
        }
    }

    private func loadRecordsUnlocked() -> [Record] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRecordsUnlocked(_ records: [Record]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
