import Foundation

/// GitHub 音源发现检索模式。
enum GitHubSearchMode: String, CaseIterable, Identifiable, Sendable {
    case repositories
    case files

    var id: String { rawValue }
}

/// 解析出的 GitHub 仓库/文件直达目标。
struct GitHubDirectTarget: Equatable, Sendable {
    let owner: String
    let repo: String
    let branchHint: String?
    let filePathHint: String?
}

/// GitHub 搜索或直达定位出的公开仓库候选。
struct GitHubRepoCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let owner: String
    let name: String
    let fullName: String
    let description: String
    let stars: Int
    let defaultBranch: String
    let updatedAt: String
    let htmlURL: URL
    let topics: [String]
}

/// 从 GitHub 仓库或代码检索中发现的可导入音源配置文件。
struct GitHubConfigCandidate: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case subscriptionManifest
        case jsonTemplateOrConfig
        case jsPlugin
    }

    let id: String
    let displayName: String
    let path: String
    var kind: Kind
    let rawURL: URL
    let htmlURL: URL?
    let sizeBytes: Int?
    let repoFullName: String
    var compatibility: Compatibility = .unchecked

    enum Compatibility: Hashable, Sendable {
        case unchecked
        case recognized
        case unsupported

        var sortRank: Int {
            switch self {
            case .recognized: 0
            case .unchecked: 1
            case .unsupported: 2
            }
        }
    }
}

/// 预览 `plugins.json` 等订阅清单时解析出的单个子源条目。
struct GitHubManifestEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String?
    let url: URL
    let userVariables: [String: String]?
}

/// GitHub 音源发现过程中的可恢复错误。
enum GitHubDiscoveryError: LocalizedError, Equatable, Sendable {
    case invalidQuery
    case rateLimited(hasToken: Bool)
    case unauthorized
    case repositoryNotFound(String)
    case httpFailure(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return String(localized: "请输入搜索关键词，或粘贴 owner/repo 与 GitHub 仓库链接")
        case .rateLimited(let hasToken):
            if hasToken {
                return String(localized: "GitHub API 触发速率限制，请稍等片刻后再试")
            }
            return String(localized: "GitHub 匿名请求已达速率限制，请稍后再试或填入个人 GitHub Token 提高限额")
        case .unauthorized:
            return String(localized: "GitHub Token 无效或已过期，请检查或清除后重试")
        case .repositoryNotFound(let target):
            return String(localized: "未找到 GitHub 仓库或分支：\(target)")
        case .httpFailure(let code, let message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty
                ? String(localized: "GitHub 请求失败（\(code)）")
                : String(localized: "GitHub 请求失败（\(code)）：\(clean)")
        case .invalidResponse:
            return String(localized: "GitHub 返回了无法解析的数据")
        }
    }
}

/// 通过 GitHub 公开 API 搜索开源仓库、扫描内部配置文件并预览订阅清单。
///
/// 所有网络请求均通过 `PluginHTTPClient` 校验目标域名与系统「允许联网」开关。
final class GitHubSourceDiscovery: @unchecked Sendable {
    static let tokenAccountKey = "github.discovery.token"
    private static let allowedDomains = ["api.github.com", "raw.githubusercontent.com", "cdn.jsdelivr.net"]
    private static let maximumCandidateBytes = 2_000_000

    private let session: URLSession
    private let secrets: any SecretStoring
    private let networkAllowed: @Sendable () -> Bool

    init(session: URLSession = .shared,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         networkAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.session = session
        self.secrets = secrets
        self.networkAllowed = networkAllowed
    }

    // MARK: - Token 管理（存入 Keychain / SecretStoring）

    var hasToken: Bool {
        currentToken() != nil
    }

    func saveToken(_ rawToken: String) throws {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearToken()
            return
        }
        try secrets.save(trimmed, account: Self.tokenAccountKey)
    }

    func clearToken() {
        secrets.remove(account: Self.tokenAccountKey)
    }

    private func currentToken() -> String? {
        guard let raw = secrets.load(account: Self.tokenAccountKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    // MARK: - 搜索与探测

    /// 搜索公开 GitHub 仓库；若输入为 `owner/repo` 或仓库链接则直接定位该仓库。
    func searchRepositories(query rawQuery: String) async throws -> [GitHubRepoCandidate] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubDiscoveryError.invalidQuery }

        if let direct = Self.parseDirectRepositoryTarget(trimmed) {
            let repo = try await fetchRepository(owner: direct.owner, repo: direct.repo)
            return [repo]
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/search/repositories"
        components.queryItems = [
            URLQueryItem(name: "q", value: Self.repositorySearchQuery(for: trimmed)),
            URLQueryItem(name: "per_page", value: "20"),
        ]
        guard let url = components.url else { throw GitHubDiscoveryError.invalidQuery }

        let data = try await performGET(url: url, notFoundContext: trimmed)
        let decoded: APIRepoSearchResponse
        do {
            decoded = try JSONDecoder().decode(APIRepoSearchResponse.self, from: data)
        } catch {
            throw GitHubDiscoveryError.invalidResponse
        }
        return decoded.items.map { $0.toCandidate() }
    }

    /// 获取单个仓库详情（用于直达 `owner/repo` 或贴入 GitHub URL）。
    func fetchRepository(owner: String, repo: String) async throws -> GitHubRepoCandidate {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)"
        guard let url = components.url else { throw GitHubDiscoveryError.invalidQuery }

        let data = try await performGET(url: url, notFoundContext: "\(owner)/\(repo)")
        let decoded: APIRepoItem
        do {
            decoded = try JSONDecoder().decode(APIRepoItem.self, from: data)
        } catch {
            throw GitHubDiscoveryError.invalidResponse
        }
        return decoded.toCandidate()
    }

    /// 扫描指定仓库内可导入的 `.js` 插件、`.json` 模板与订阅清单。
    func inspectRepository(_ repo: GitHubRepoCandidate,
                           branchOverride: String? = nil,
                           preferredPath: String? = nil) async throws -> [GitHubConfigCandidate] {
        let primaryBranch = (branchOverride?.isEmpty == false ? branchOverride! : repo.defaultBranch)
        do {
            return try await inspectRepositoryOnBranch(repo, branch: primaryBranch, preferredPath: preferredPath)
        } catch let error as GitHubDiscoveryError {
            if let branchOverride, !branchOverride.isEmpty, branchOverride != repo.defaultBranch {
                switch error {
                case .repositoryNotFound, .httpFailure:
                    return try await inspectRepositoryOnBranch(repo, branch: repo.defaultBranch, preferredPath: preferredPath)
                case .rateLimited, .unauthorized, .invalidQuery, .invalidResponse:
                    break
                }
            }
            throw error
        }
    }

    private func inspectRepositoryOnBranch(_ repo: GitHubRepoCandidate,
                                           branch: String,
                                           preferredPath: String?) async throws -> [GitHubConfigCandidate] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repo.owner)/\(repo.name)/git/trees/\(branch)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let treeURL = components.url else { throw GitHubDiscoveryError.invalidQuery }

        do {
            let data = try await performGET(url: treeURL, notFoundContext: "\(repo.fullName) (\(branch))")
            let treeResponse = try JSONDecoder().decode(APIGitTreeResponse.self, from: data)
            let items = Self.filterConfigCandidates(
                from: treeResponse.tree.map { ($0.path, $0.type, $0.size) },
                repo: repo,
                branch: branch,
                preferredPath: preferredPath
            )
            if !treeResponse.isTruncated || !items.isEmpty {
                return items
            }
        } catch let error as GitHubDiscoveryError {
            switch error {
            case .rateLimited, .unauthorized:
                throw error
            case .httpFailure(let status, _) where status == 409:
                // 409 Conflict 表示仓库为空，无任何提交树。
                return []
            case .repositoryNotFound, .httpFailure, .invalidResponse, .invalidQuery:
                break
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error is SourceDomainPolicy.Violation || error is PlaybackError {
                throw error
            }
        }

        // 树被截断或部分仓库分支名异常时，降级到目录内容探测（根目录 + 常见插件目录）。
        return try await inspectRepositoryViaContents(repo: repo, branch: branch, preferredPath: preferredPath)
    }

    /// 全网代码文件搜索（GitHub `/search/code` 要求已配置 Token）。
    func searchFiles(query rawQuery: String) async throws -> [GitHubConfigCandidate] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubDiscoveryError.invalidQuery }
        guard hasToken else { throw GitHubDiscoveryError.unauthorized }

        let effectiveQuery: String
        let lower = trimmed.lowercased()
        if lower.contains("extension:") || lower.contains("language:") || lower.contains("filename:") {
            effectiveQuery = trimmed
        } else {
            effectiveQuery = "\(trimmed) (extension:js OR extension:json)"
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/search/code"
        components.queryItems = [
            URLQueryItem(name: "q", value: effectiveQuery),
            URLQueryItem(name: "per_page", value: "25"),
        ]
        guard let url = components.url else { throw GitHubDiscoveryError.invalidQuery }

        let data = try await performGET(url: url, notFoundContext: trimmed)
        let decoded: APICodeSearchResponse
        do {
            decoded = try JSONDecoder().decode(APICodeSearchResponse.self, from: data)
        } catch {
            throw GitHubDiscoveryError.invalidResponse
        }

        var seen = Set<String>()
        var results: [GitHubConfigCandidate] = []
        for item in decoded.items {
            let lowerName = item.name.lowercased()
            guard lowerName.hasSuffix(".js") || lowerName.hasSuffix(".json") else { continue }
            guard let kind = Self.classifyKind(path: item.path, sizeBytes: nil) else { continue }
            guard let rawURL = SourceDomainPolicy.normalizeImportURL(item.htmlURL) else { continue }
            let uniqueKey = "\(item.repository.fullName):\(item.path)"
            guard seen.insert(uniqueKey).inserted else { continue }
            results.append(
                GitHubConfigCandidate(
                    id: uniqueKey,
                    displayName: Self.friendlyDisplayName(path: item.path, kind: kind),
                    path: item.path,
                    kind: kind,
                    rawURL: rawURL,
                    htmlURL: URL(string: item.htmlURL),
                    sizeBytes: nil,
                    repoFullName: item.repository.fullName
                )
            )
        }
        return results
    }

    /// 拉取并解析 `plugins.json` 等订阅清单内的子音源列表供预览（GitHub Raw 自动支持 jsDelivr CDN 回退）。
    func inspectManifest(at rawURL: URL) async throws -> [GitHubManifestEntry] {
        let candidates = SourceDomainPolicy.rawGitHubMirrorCandidates(for: rawURL)
        var lastError: Error?
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let data = try await performGET(url: candidate, notFoundContext: rawURL.lastPathComponent)
                return try Self.parseManifestEntries(data: data, originURL: rawURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch let violation as SourceDomainPolicy.Violation {
                if case .networkDisabled = violation { throw violation }
                lastError = violation
            } catch let disc as GitHubDiscoveryError {
                switch disc {
                case .unauthorized, .rateLimited:
                    throw disc
                default:
                    lastError = disc
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GitHubDiscoveryError.invalidResponse
    }

    /// 只读检查候选内容，不执行第三方脚本，也不保存或启用音源。
    func inspectCandidates(_ candidates: [GitHubConfigCandidate]) async throws -> [GitHubConfigCandidate] {
        var result: [GitHubConfigCandidate] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard index < 8, (candidate.sizeBytes ?? 0) <= Self.maximumCandidateBytes else {
                result.append(candidate)
                continue
            }
            var inspected = candidate
            for url in SourceDomainPolicy.rawGitHubMirrorCandidates(for: candidate.rawURL) {
                do {
                    let data = try await performGET(
                        url: url,
                        notFoundContext: candidate.path,
                        maximumBytes: Self.maximumCandidateBytes
                    )
                    if let kind = Self.sourcePayloadKind(data) {
                        inspected.kind = kind
                        inspected.compatibility = .recognized
                    } else {
                        inspected.compatibility = .unsupported
                    }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let violation as SourceDomainPolicy.Violation {
                    if case .networkDisabled = violation { throw violation }
                } catch let error as PlaybackError where error == .networkDisabled {
                    throw error
                } catch let error as GitHubDiscoveryError {
                    if case .rateLimited = error { throw error }
                    if case .unauthorized = error { throw error }
                } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
                    break
                } catch {
                    // 下载失败保留为待识别候选，仍允许用户通过导入重试。
                }
            }
            result.append(inspected)
        }
        return result.sorted { $0.compatibility.sortRank < $1.compatibility.sortRank }
    }

    // MARK: - 静态解析与规则过滤

    static func repositorySearchQuery(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 显式 GitHub 查询语法与仓库直达输入保持原样。
        guard !trimmed.contains(":"), parseDirectRepositoryTarget(trimmed) == nil else { return trimmed }
        let normalized = trimmed
            .replacingOccurrences(of: "哔哩哔哩", with: "bilibili", options: .caseInsensitive)
            .replacingOccurrences(of: "b站", with: "bilibili", options: .caseInsensitive)
        let lower = normalized.lowercased()
        if lower.contains("bilibili"), !lower.contains("musicfree"), !lower.contains("lx") {
            return "bilibili musicfree"
        }
        return normalized
    }

    /// 内容识别仅判断支持的文件格式；可用性仍由导入时的沙箱与能力检查决定。
    static func sourcePayloadKind(_ data: Data) -> GitHubConfigCandidate.Kind? {
        guard data.count <= maximumCandidateBytes, let rawText = String(data: data, encoding: .utf8) else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let cleanData = SourceDomainPolicy.stripJSONP(Data(text.utf8))
        if let entries = SourceSubscriptionManifest.parseEntries(from: cleanData), !entries.isEmpty {
            return .subscriptionManifest
        }
        if (try? JSONDecoder().decode(JSONTemplateDefinition.self, from: cleanData)) != nil {
            return .jsonTemplateOrConfig
        }
        if let definitions = try? JSONDecoder().decode([JSONTemplateDefinition].self, from: cleanData), !definitions.isEmpty {
            return .jsonTemplateOrConfig
        }
        let objects: [[String: Any]]
        if let object = try? JSONSerialization.jsonObject(with: cleanData) as? [String: Any] {
            objects = [object]
        } else {
            objects = (try? JSONSerialization.jsonObject(with: cleanData) as? [[String: Any]]) ?? []
        }
        if objects.contains(where: { object in
            let kind = (object["kind"] as? String ?? object["type"] as? String ?? "").lowercased()
            let address = object["baseURL"] as? String ?? object["url"] as? String ?? ""
            return ["opensubsonic", "subsonic", "navidrome", "webdav"].contains(kind)
                && ServerSourceConfig.normalizedBaseURL(from: address) != nil
        }) {
            return .jsonTemplateOrConfig
        }
        if text.contains("globalThis.lx") || text.contains("lx.on(") {
            return .jsPlugin
        }
        let exportsPlugin = text.contains("module.exports") || text.contains("exports.")
        let methods = [
            "search", "getMediaSource", "getMusicInfo", "importMusicSheet", "getLyric", "getTopLists",
            "resolve", "discover", "getRecommendSheetsByTag",
        ]
        if exportsPlugin, methods.contains(where: { text.contains($0) }) {
            return .jsPlugin
        }
        return nil
    }

    /// 识别 `owner/repo`、`https://github.com/owner/repo/...` 与 `raw.githubusercontent.com/...` 直达输入。
    static func parseDirectRepositoryTarget(_ raw: String) -> GitHubDirectTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            let parts = url.pathComponents.filter { $0 != "/" }
            if host == "github.com" || host == "www.github.com" {
                guard parts.count >= 2 else { return nil }
                let owner = parts[0]
                var repo = parts[1]
                if repo.hasSuffix(".git") {
                    repo = String(repo.dropLast(4))
                }
                guard isValidGitHubSlug(owner), isValidGitHubSlug(repo) else { return nil }
                if parts.count >= 4, parts[2] == "blob" || parts[2] == "tree" || parts[2] == "raw" {
                    let branch = parts[3]
                    let filePath = parts.count > 4 ? parts[4...].joined(separator: "/") : nil
                    return GitHubDirectTarget(
                        owner: owner,
                        repo: repo,
                        branchHint: branch,
                        filePathHint: parts[2] == "blob" || parts[2] == "raw" ? filePath : nil
                    )
                }
                return GitHubDirectTarget(owner: owner, repo: repo, branchHint: nil, filePathHint: nil)
            }

            if host == "raw.githubusercontent.com" {
                guard parts.count >= 4 else { return nil }
                let owner = parts[0]
                let repo = parts[1]
                guard isValidGitHubSlug(owner), isValidGitHubSlug(repo) else { return nil }
                let branch = parts[2]
                let filePath = parts[3...].joined(separator: "/")
                return GitHubDirectTarget(owner: owner, repo: repo, branchHint: branch, filePathHint: filePath)
            }
            return nil
        }

        let slashParts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard slashParts.count == 2 else { return nil }
        let owner = slashParts[0]
        var repo = slashParts[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        guard isValidGitHubSlug(owner), isValidGitHubSlug(repo) else { return nil }
        return GitHubDirectTarget(owner: owner, repo: repo, branchHint: nil, filePathHint: nil)
    }

    static func rawURL(owner: String, repo: String, branch: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = "/\(owner)/\(repo)/\(branch)/\(cleanPath)"
        return components.url
    }

    static func blobURL(owner: String, repo: String, branch: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = "/\(owner)/\(repo)/blob/\(branch)/\(cleanPath)"
        return components.url
    }

    static func filterConfigCandidates(from entries: [(path: String, type: String, size: Int?)],
                                       repo: GitHubRepoCandidate,
                                       branch: String,
                                       preferredPath: String? = nil) -> [GitHubConfigCandidate] {
        let blobs = entries.filter { $0.type == "blob" }
        let hasDistJS = blobs.contains { entry in
            let lower = entry.path.lowercased()
            return lower.hasPrefix("dist/") && lower.hasSuffix(".js")
        }

        var candidates: [GitHubConfigCandidate] = []
        var seenPaths = Set<String>()

        for entry in blobs {
            guard seenPaths.insert(entry.path).inserted else { continue }
            let isExplicitPreferred = preferredPath != nil && entry.path == preferredPath
            guard let kind = classifyKind(
                path: entry.path,
                sizeBytes: entry.size,
                hasDistJS: hasDistJS,
                allowExactPreferred: isExplicitPreferred
            ) else {
                continue
            }
            guard let rawURL = rawURL(owner: repo.owner, repo: repo.name, branch: branch, path: entry.path) else {
                continue
            }
            candidates.append(
                GitHubConfigCandidate(
                    id: "\(repo.fullName)#\(branch):\(entry.path)",
                    displayName: friendlyDisplayName(path: entry.path, kind: kind),
                    path: entry.path,
                    kind: kind,
                    rawURL: rawURL,
                    htmlURL: blobURL(owner: repo.owner, repo: repo.name, branch: branch, path: entry.path),
                    sizeBytes: entry.size,
                    repoFullName: repo.fullName
                )
            )
        }

        if let preferredPath, !candidates.contains(where: { $0.path == preferredPath }),
           let kind = classifyKind(path: preferredPath, sizeBytes: nil, hasDistJS: false, allowExactPreferred: true),
           let rawURL = rawURL(owner: repo.owner, repo: repo.name, branch: branch, path: preferredPath) {
            candidates.append(
                GitHubConfigCandidate(
                    id: "\(repo.fullName)#\(branch):\(preferredPath)",
                    displayName: friendlyDisplayName(path: preferredPath, kind: kind),
                    path: preferredPath,
                    kind: kind,
                    rawURL: rawURL,
                    htmlURL: blobURL(owner: repo.owner, repo: repo.name, branch: branch, path: preferredPath),
                    sizeBytes: nil,
                    repoFullName: repo.fullName
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            if let preferredPath {
                let lHit = lhs.path == preferredPath
                let rHit = rhs.path == preferredPath
                if lHit != rHit { return lHit }
            }
            let lRank = sortRank(lhs)
            let rRank = sortRank(rhs)
            if lRank != rRank { return lRank < rRank }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    static func parseManifestEntries(data: Data, originURL: URL) throws -> [GitHubManifestEntry] {
        guard let rawEntries = SourceSubscriptionManifest.parseEntries(from: data) else {
            throw GitHubDiscoveryError.invalidResponse
        }

        var result: [GitHubManifestEntry] = []
        var seen = Set<String>()
        for entry in rawEntries {
            guard let rawLink = entry.resolvedURLString,
                  let resolvedURL = SourceDomainPolicy.resolveImportURL(rawLink, relativeTo: originURL),
                  originURL.isFileURL || ["http", "https"].contains(resolvedURL.scheme?.lowercased() ?? "") else {
                // 线上清单只能指向 http(s)，不让它引用本机文件；本地清单引用同目录文件照常。
                continue
            }
            let fallbackName = resolvedURL.lastPathComponent.isEmpty ? resolvedURL.absoluteString : resolvedURL.lastPathComponent
            let title = entry.resolvedName ?? fallbackName
            let key = "\(title)|\(resolvedURL.absoluteString)"
            guard seen.insert(key).inserted else { continue }
            result.append(
                GitHubManifestEntry(
                    id: key,
                    name: title,
                    version: entry.version,
                    url: resolvedURL,
                    userVariables: entry.userVariables
                )
            )
        }
        return result
    }

    // MARK: - 内部 HTTP 与分类辅助

    private func inspectRepositoryViaContents(repo: GitHubRepoCandidate,
                                              branch: String,
                                              preferredPath: String?) async throws -> [GitHubConfigCandidate] {
        var collected: [(path: String, type: String, size: Int?)] = []
        let candidateDirs = ["", "dist", "plugins", "sources", "examples"]
        for dir in candidateDirs {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.github.com"
            components.path = dir.isEmpty
                ? "/repos/\(repo.owner)/\(repo.name)/contents"
                : "/repos/\(repo.owner)/\(repo.name)/contents/\(dir)"
            components.queryItems = [URLQueryItem(name: "ref", value: branch)]
            guard let url = components.url else { continue }
            do {
                let data = try await performGET(url: url, notFoundContext: "\(repo.fullName)/\(dir)")
                let items = try JSONDecoder().decode([APIContentItem].self, from: data)
                for item in items where item.type == "file" {
                    collected.append((item.path, "blob", item.size))
                }
            } catch let err as GitHubDiscoveryError {
                switch err {
                case .rateLimited, .unauthorized:
                    throw err
                case .repositoryNotFound, .httpFailure, .invalidResponse, .invalidQuery:
                    if dir.isEmpty { throw err }
                }
            }
        }
        return Self.filterConfigCandidates(from: collected, repo: repo, branch: branch, preferredPath: preferredPath)
    }

    private func performGET(url: URL, notFoundContext: String, maximumBytes: Int? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTimeouts.api
        request.setValue("FLOW-SpatialLyricsPlayer", forHTTPHeaderField: "User-Agent")
        if url.host?.lowercased() == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token = currentToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: Self.allowedDomains,
            networkAllowed: networkAllowed,
            maximumBytes: maximumBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw GitHubDiscoveryError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw GitHubDiscoveryError.unauthorized
        case 403, 429:
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            let apiMsg = Self.extractAPIMessage(from: data)
            if http.statusCode == 429 || remaining == "0" || apiMsg.lowercased().contains("rate limit") {
                throw GitHubDiscoveryError.rateLimited(hasToken: hasToken)
            }
            throw GitHubDiscoveryError.httpFailure(statusCode: http.statusCode, message: apiMsg)
        case 404:
            throw GitHubDiscoveryError.repositoryNotFound(notFoundContext)
        default:
            throw GitHubDiscoveryError.httpFailure(
                statusCode: http.statusCode,
                message: Self.extractAPIMessage(from: data)
            )
        }
    }

    private static func extractAPIMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String else {
            return ""
        }
        return message
    }

    private static func isValidGitHubSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let ignoredPathSegments: Set<String> = [
        "node_modules", ".git", ".github", ".vscode", ".idea",
        "test", "tests", "__tests__", "fixtures", "mock", "mocks",
    ]

    private static let ignoredBuildDirectorySegments: Set<String> = [
        "scripts", "script", "tools", "build", "config", ".husky",
    ]

    private static let ignoredJSONFilenames: Set<String> = [
        "package.json", "package-lock.json", "tsconfig.json", "jsconfig.json",
        "composer.json", "deno.json", "deno.jsonc", "manifest.json",
        "renovate.json", "lerna.json", "turbo.json", "vercel.json",
        "netlify.json", "nodemon.json", "bower.json", "project.json",
        "components.json", "biome.json", "bun.json", "schema.json",
        ".eslintrc.json", ".prettierrc.json", "launch.json", "settings.json",
    ]

    private static let ignoredJSFilenames: Set<String> = [
        "gulpfile.js", "gruntfile.js", "webpack.js", "rollup.js",
        "utils.js", "helper.js", "helpers.js", "common.js",
        "constants.js", "types.js", "config.js", "build.js",
    ]

    private static let manifestFilenames: Set<String> = [
        "plugins.json", "sources.json", "feeds.json", "plugin.json",
        "source-list.json", "sub.json", "subscription.json",
    ]

    private static func classifyKind(path: String,
                                     sizeBytes: Int?,
                                     hasDistJS: Bool = false,
                                     allowExactPreferred: Bool = false) -> GitHubConfigCandidate.Kind? {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else { return nil }
        let lowerFilename = filename.lowercased()
        let ext = (lowerFilename as NSString).pathExtension

        guard ext == "js" || ext == "json" else { return nil }
        if !allowExactPreferred && filename.hasPrefix(".") { return nil }

        let dirSegments = components.dropLast().map { $0.lowercased() }
        if !allowExactPreferred {
            if dirSegments.contains(where: { $0.hasPrefix(".") || ignoredPathSegments.contains($0) }) {
                return nil
            }
        }

        if ext == "json" {
            if !allowExactPreferred {
                if ignoredJSONFilenames.contains(lowerFilename)
                    || lowerFilename.hasPrefix("tsconfig.")
                    || lowerFilename.hasSuffix(".schema.json") {
                    return nil
                }
                if let sizeBytes, sizeBytes > 512_000 {
                    return nil
                }
            }
            if manifestFilenames.contains(lowerFilename) {
                return .subscriptionManifest
            }
            if !lowerFilename.hasSuffix(".flow.json")
                && (lowerFilename.contains("plugins") || lowerFilename.contains("sources") || lowerFilename.contains("feeds")) {
                return .subscriptionManifest
            }
            return .jsonTemplateOrConfig
        }

        // .js 处理
        if !allowExactPreferred {
            if ignoredJSFilenames.contains(lowerFilename)
                || lowerFilename.hasSuffix(".config.js")
                || lowerFilename.hasSuffix(".test.js")
                || lowerFilename.hasSuffix(".spec.js") {
                return nil
            }
            if dirSegments.contains(where: { ignoredBuildDirectorySegments.contains($0) }) {
                return nil
            }
            if hasDistJS && dirSegments.first == "src" {
                return nil
            }
        }
        return .jsPlugin
    }

    private static func friendlyDisplayName(path: String, kind: GitHubConfigCandidate.Kind) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else { return path }
        if kind == .jsPlugin, filename.lowercased() == "index.js", components.count >= 2 {
            let parent = components[components.count - 2]
            return "\(parent) (\(filename))"
        }
        return filename
    }

    private static func sortRank(_ item: GitHubConfigCandidate) -> Int {
        switch item.kind {
        case .subscriptionManifest:
            return 0
        case .jsonTemplateOrConfig:
            return item.path.lowercased().hasSuffix(".flow.json") ? 1 : 3
        case .jsPlugin:
            return 2
        }
    }
}

// MARK: - GitHub API 解码结构

private struct APIRepoSearchResponse: Decodable {
    let items: [APIRepoItem]
}

private struct APIRepoItem: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let fullName: String
    let name: String
    let owner: Owner
    let description: String?
    let stargazersCount: Int?
    let defaultBranch: String?
    let updatedAt: String?
    let htmlURL: String
    let topics: [String]?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
        case owner
        case description
        case stargazersCount = "stargazers_count"
        case defaultBranch = "default_branch"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case topics
    }

    func toCandidate() -> GitHubRepoCandidate {
        let fallbackURL = URL(string: "https://github.com/\(fullName)")!
        let shortDate = updatedAt.map { String($0.prefix(10)) } ?? ""
        return GitHubRepoCandidate(
            id: fullName,
            owner: owner.login,
            name: name,
            fullName: fullName,
            description: (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            stars: stargazersCount ?? 0,
            defaultBranch: (defaultBranch?.isEmpty == false ? defaultBranch! : "main"),
            updatedAt: shortDate,
            htmlURL: URL(string: htmlURL) ?? fallbackURL,
            topics: topics ?? []
        )
    }
}

private struct APIGitTreeResponse: Decodable {
    struct Entry: Decodable {
        let path: String
        let type: String
        let size: Int?
    }

    let tree: [Entry]
    let truncated: Bool?

    var isTruncated: Bool { truncated ?? false }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tree = try c.decodeIfPresent([Entry].self, forKey: .tree) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
    }

    enum CodingKeys: String, CodingKey {
        case tree, truncated
    }
}

private struct APIContentItem: Decodable {
    let name: String
    let path: String
    let type: String
    let size: Int?
}

private struct APICodeSearchResponse: Decodable {
    struct Item: Decodable {
        struct Repo: Decodable {
            let fullName: String

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
            }
        }

        let name: String
        let path: String
        let htmlURL: String
        let repository: Repo

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case htmlURL = "html_url"
            case repository
        }
    }

    let items: [Item]
}
