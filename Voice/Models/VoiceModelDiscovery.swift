import Foundation

/// 远端 RVC 音色检索平台。
enum VoiceModelSearchPlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case huggingFace = "huggingface"
    case github = "github"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace:
            return "HuggingFace / 镜像"
        case .github:
            return "GitHub"
        }
    }
}

/// 远端模型仓库摘要。
struct VoiceModelRepoSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let platform: VoiceModelSearchPlatform
    let repoID: String
    let title: String
    let summary: String
    let downloadsOrStars: Int
    let onnxFileCount: Int
    let tags: [String]
    let pageURL: URL
    let defaultBranch: String
    let isRecommended: Bool
}

/// 仓库内可直接下载并自动导入的单个音色：独立 `.onnx`，或一个 `.voicepack` 文件夹（整组下载）。
struct VoiceModelRemoteFile: Identifiable, Hashable, Codable, Sendable {
    /// `.voicepack` 文件夹里的一个文件（`pack.json` / `model.onnx` / `index.f32bin` / 封面）。
    struct PackFile: Hashable, Codable, Sendable {
        let name: String
        let url: URL
        let sizeBytes: Int64?
        let sha256: String?
    }

    let id: String
    let repoID: String
    let platform: VoiceModelSearchPlatform
    let fileName: String
    let relativePath: String
    let displayName: String
    let downloadURL: URL
    let sizeBytes: Int64?
    let sha256: String?
    let companionIndexURL: URL?
    /// 非空表示这是一个 `.voicepack` 文件夹：`downloadURL` 只作标识，实际按这里逐个下载后整体导入。
    var packFiles: [PackFile]? = nil

    var formattedSize: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// 直链输入的分类结果：决定是下载、转仓库检索，还是提示先离线转换。
enum VoiceModelLinkKind: Equatable, Sendable {
    case modelFile(URL)
    case requiresConversion(ext: String)
    case repository(repoID: String, platform: VoiceModelSearchPlatform?)
    case invalid
}

/// 远端模型下载落盘产物，等待直接交由 `VoicePackStore.importPack` 自动导入。
struct DownloadedVoiceModelPayload: Sendable {
    let stagingDirectory: URL
    let modelFileURL: URL
    let indexFileURL: URL?
    let sha256: String
    let resolvedURL: URL
    let inferredDisplayName: String
}

/// 负责从 HuggingFace（默认走 hf-mirror.com 镜像源并支持官方回退）及 GitHub 自动检索可运行 RVC ONNX / `.voicepack` 音色。
final class VoiceModelDiscovery: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static let curatedSearchKeywords: [String] = [
        "ozada/onnx_rvc",
        "rvc onnx",
        "voicepack"
    ]

    // MARK: - Search

    func searchRepositories(
        query: String,
        platform: VoiceModelSearchPlatform,
        mirrorConfig: VoiceModelMirrorConfig = .default,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRepoSummary] {
        guard allowNetwork() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法在线搜索音色模型。")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQuery = trimmed.isEmpty ? (platform == .huggingFace ? "rvc onnx" : "rvc onnx voice") : trimmed

        // 输入中文名 / 罗马字（如「高松灯」「tomori」）时直接映射到对应的公开仓库
        let curatedRepo = CuratedVoiceCatalog.sourceRepo(matchingQuery: trimmed)
        let direct = curatedRepo.map { (platform: VoiceModelSearchPlatform.huggingFace, repoID: $0) }
            ?? Self.parseDirectRepoIdentifier(from: trimmed)

        // 若用户输入了明确的 owner/repo、仓库 URL 或精选音色名，优先直接探测该仓库详情并置顶返回
        if let direct {
            let targetPlatform = direct.platform ?? platform
            let stub = VoiceModelRepoSummary(
                id: "\(targetPlatform.rawValue):\(direct.repoID)",
                platform: targetPlatform,
                repoID: direct.repoID,
                title: direct.repoID,
                summary: "直接解析的模型仓库",
                downloadsOrStars: 0,
                onnxFileCount: 0,
                tags: [],
                pageURL: Self.repoPageURL(platform: targetPlatform, repoID: direct.repoID, mirrorConfig: mirrorConfig),
                defaultBranch: "main",
                isRecommended: true
            )
            let files = try await inspectRepository(stub, mirrorConfig: mirrorConfig, allowNetwork: allowNetwork)
            let sampleNames = files.prefix(3).map(\.displayName).joined(separator: "、")
            let ellipsis = files.count > 3 ? "…" : ""
            let updated = VoiceModelRepoSummary(
                id: stub.id,
                platform: stub.platform,
                repoID: stub.repoID,
                title: stub.title,
                summary: files.isEmpty
                    ? "已找到仓库，但未发现可运行的 .onnx / .voicepack 音色文件"
                    : "\(files.count) 个音色：\(sampleNames)\(ellipsis)",
                downloadsOrStars: stub.downloadsOrStars,
                onnxFileCount: files.count,
                tags: stub.tags,
                pageURL: stub.pageURL,
                defaultBranch: stub.defaultBranch,
                isRecommended: true
            )
            return [updated]
        }

        switch platform {
        case .huggingFace:
            return try await searchHuggingFace(query: effectiveQuery, mirrorConfig: mirrorConfig, allowNetwork: allowNetwork)
        case .github:
            return try await searchGitHub(query: effectiveQuery, allowNetwork: allowNetwork)
        }
    }

    func inspectRepository(
        _ repo: VoiceModelRepoSummary,
        mirrorConfig: VoiceModelMirrorConfig = .default,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRemoteFile] {
        guard allowNetwork() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法读取仓库模型列表。")
        }

        switch repo.platform {
        case .huggingFace:
            return try await inspectHuggingFaceRepo(
                repoID: repo.repoID,
                mirrorConfig: mirrorConfig,
                allowNetwork: allowNetwork
            )
        case .github:
            return try await inspectGitHubRepo(
                repoID: repo.repoID,
                defaultBranchHint: repo.defaultBranch,
                allowNetwork: allowNetwork
            )
        }
    }

    /// 下载单个远端音色 `.onnx` / `.voicepack`（以及可选的同名 `.f32bin` 向量索引）并重命名为标准扩展名，便于直接自动导入。
    func downloadRemoteModel(
        from url: URL,
        suggestedFileName: String? = nil,
        displayName: String? = nil,
        expectedSHA256: String? = nil,
        companionIndexURL: URL? = nil,
        inferCompanionIndex: Bool = true,
        packFiles: [VoiceModelRemoteFile.PackFile]? = nil,
        mirrorConfig: VoiceModelMirrorConfig = .default,
        allowNetwork: @escaping @Sendable () -> Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadedVoiceModelPayload {
        guard allowNetwork() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法下载远端音色。")
        }

        if let packFiles, !packFiles.isEmpty {
            return try await downloadPackFolder(
                files: packFiles,
                folderName: suggestedFileName ?? url.lastPathComponent,
                displayName: displayName,
                mirrorConfig: mirrorConfig,
                allowNetwork: allowNetwork,
                onProgress: onProgress
            )
        }

        let canonicalURL = Self.normalizedDirectModelURL(from: url.absoluteString) ?? url
        let candidates = mirrorConfig.candidateURLs(for: canonicalURL)
        let downloaded = try await VoiceRemoteDownloader.downloadFileWithFallback(
            candidateURLs: candidates,
            session: session,
            allowNetwork: allowNetwork,
            expectedSHA256: expectedSHA256,
            onProgress: onProgress
        )

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-import-\(UUID().uuidString)", isDirectory: true)
        do {
            if Self.isLFSPointerFile(at: downloaded.tempFileURL) {
                throw VoiceError.unsupportedModel(String(localized: "这个链接下到的只是 Git LFS 占位文件，不是模型本体。请到仓库页面点「Download」取得真实下载地址后再粘贴。"))
            }
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            let rawFileName = Self.resolveSafeFileName(
                suggested: suggestedFileName,
                url: canonicalURL,
                fallbackExt: "onnx"
            )
            let stagedModelURL = stagingDir.appendingPathComponent(rawFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: stagedModelURL.path) {
                try FileManager.default.removeItem(at: stagedModelURL)
            }
            try FileManager.default.moveItem(at: downloaded.tempFileURL, to: stagedModelURL)

            var stagedIndexURL: URL?
            // 直链只给了 .onnx 时，按同名同目录猜一个 .f32bin 索引；不存在会自动跳过。
            // 仓库列表里的文件已经知道有没有索引，不再多猜两次请求。
            let resolvedCompanionIndex = companionIndexURL
                ?? (inferCompanionIndex ? Self.inferredCompanionIndexURL(for: canonicalURL) : nil)
            if let companionIndexURL = resolvedCompanionIndex {
                let indexCandidates = mirrorConfig.candidateURLs(for: companionIndexURL)
                if let indexResult = try? await VoiceRemoteDownloader.downloadFileWithFallback(
                    candidateURLs: indexCandidates,
                    session: session,
                    allowNetwork: allowNetwork
                ) {
                    let indexName = Self.resolveSafeFileName(
                        suggested: companionIndexURL.lastPathComponent,
                        url: companionIndexURL,
                        fallbackExt: "f32bin"
                    )
                    let targetIndex = stagingDir.appendingPathComponent(indexName, isDirectory: false)
                    try? FileManager.default.removeItem(at: targetIndex)
                    if (try? FileManager.default.moveItem(at: indexResult.tempFileURL, to: targetIndex)) != nil {
                        stagedIndexURL = targetIndex
                    } else {
                        try? FileManager.default.removeItem(at: indexResult.tempFileURL)
                    }
                }
            }

            let resolvedName = Self.humanizedDisplayName(
                from: displayName ?? rawFileName
            )
            return DownloadedVoiceModelPayload(
                stagingDirectory: stagingDir,
                modelFileURL: stagedModelURL,
                indexFileURL: stagedIndexURL,
                sha256: downloaded.sha256,
                resolvedURL: downloaded.resolvedURL,
                inferredDisplayName: resolvedName
            )
        } catch {
            try? FileManager.default.removeItem(at: downloaded.tempFileURL)
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }
    }

    /// 逐个下载 `.voicepack` 文件夹里的文件，拼回同名文件夹交给导入；进度按文件大小加权。
    private func downloadPackFolder(
        files: [VoiceModelRemoteFile.PackFile],
        folderName: String,
        displayName: String?,
        mirrorConfig: VoiceModelMirrorConfig,
        allowNetwork: @escaping @Sendable () -> Bool,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadedVoiceModelPayload {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-import-\(UUID().uuidString)", isDirectory: true)
        let safeFolder = Self.resolveSafeFileName(
            suggested: (folderName as NSString).lastPathComponent, url: nil, fallbackExt: "voicepack"
        )
        let packDir = stagingDir.appendingPathComponent(safeFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
            let weights = files.map { Double(max($0.sizeBytes ?? 1, 1)) }
            let total = weights.reduce(0, +)
            var done = 0.0
            var modelSHA = ""
            var resolved = files[0].url
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let before = done
                let weight = weights[index]
                let result = try await VoiceRemoteDownloader.downloadFileWithFallback(
                    candidateURLs: mirrorConfig.candidateURLs(for: file.url),
                    session: session,
                    allowNetwork: allowNetwork,
                    expectedSHA256: file.sha256
                ) { pct in
                    onProgress?(min((before + pct * weight) / total, 0.99))
                }
                done += weight
                let name = Self.sanitizedFileName(file.name)
                let target = packDir.appendingPathComponent(name, isDirectory: false)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: result.tempFileURL, to: target)
                if name.lowercased().hasSuffix(".onnx") {
                    modelSHA = result.sha256
                    resolved = result.resolvedURL
                }
            }
            onProgress?(1)
            return DownloadedVoiceModelPayload(
                stagingDirectory: stagingDir,
                modelFileURL: packDir,
                indexFileURL: nil,
                sha256: modelSHA,
                resolvedURL: resolved,
                inferredDisplayName: Self.humanizedDisplayName(from: displayName ?? safeFolder)
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }
    }

    // MARK: - 仓库文件 → 音色条目

    /// `a/高松灯.voicepack/model.onnx` → `a/高松灯.voicepack`；不在音色包文件夹里返回 nil。
    static func voicepackFolder(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".voicepack") }),
              index < parts.count - 1 else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// 音色包文件夹里需要随包下载的文件类型（其余如 README 忽略）。
    private static let packFileExtensions: Set<String> = ["json", "onnx", "f32bin", "png", "jpg", "jpeg", "webp"]

    struct RepoListing {
        struct Item {
            let path: String
            let size: Int64?
            let sha256: String?
        }

        /// 独立的 `.onnx` 音色（不含底座模型与音色包文件夹里的文件）。
        var standaloneModels: [Item] = []
        /// 同目录同名 `.f32bin` 索引，按小写 stem 索引。
        var indexByStem: [String: Item] = [:]
        /// `.voicepack` 文件夹 → 其中需要下载的文件；只保留含 `.onnx` 的文件夹。
        var packFolders: [(folder: String, files: [Item])] = []

        var voiceNames: [String] {
            packFolders.map { VoiceModelDiscovery.humanizedDisplayName(from: $0.folder) }
                + standaloneModels.map { VoiceModelDiscovery.humanizedDisplayName(from: $0.path) }
        }

        var voiceCount: Int { packFolders.count + standaloneModels.count }
    }

    static func repoListing(_ items: [RepoListing.Item]) -> RepoListing {
        var listing = RepoListing()
        var folders: [String: [RepoListing.Item]] = [:]
        var folderOrder: [String] = []
        for item in items {
            if let folder = voicepackFolder(of: item.path) {
                let ext = (item.path as NSString).pathExtension.lowercased()
                guard packFileExtensions.contains(ext) else { continue }
                if folders[folder] == nil { folderOrder.append(folder) }
                folders[folder, default: []].append(item)
                continue
            }
            let lower = item.path.lowercased()
            if lower.hasSuffix(".f32bin") {
                let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                listing.indexByStem[stem] = item
            } else if lower.hasSuffix(".onnx"), !isBaseInfrastructureFileName(item.path) {
                listing.standaloneModels.append(item)
            }
        }
        listing.packFolders = folderOrder.compactMap { folder in
            guard let files = folders[folder],
                  files.contains(where: { $0.path.lowercased().hasSuffix(".onnx") }) else { return nil }
            return (folder, files)
        }
        return listing
    }

    // MARK: - URL & Identifier Normalization

    static func parseDirectRepoIdentifier(from rawInput: String) -> (platform: VoiceModelSearchPlatform?, repoID: String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            let parts = url.pathComponents.filter { $0 != "/" }
            if (host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com"),
               parts.count >= 2, parts[0] != "spaces", parts[0] != "datasets" {
                return (.huggingFace, "\(parts[0])/\(parts[1])")
            }
            if host == "github.com", parts.count >= 2 {
                let owner = parts[0]
                let repo = parts[1].replacingOccurrences(of: ".git", with: "")
                return (.github, "\(owner)/\(repo)")
            }
        }

        // 支持直接输入 `owner/repo`
        if !trimmed.contains(" "), !trimmed.contains("://") {
            let comps = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count == 2,
               comps[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
               comps[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) {
                return (nil, "\(comps[0])/\(comps[1])")
            }
        }

        return nil
    }

    /// 能直接下载运行的单文件只有 `.onnx`；`.voicepack` 是文件夹，按仓库检索整组下载。
    static let runnableModelExtensions: Set<String> = ["onnx"]
    static let conversionRequiredExtensions: Set<String> = [
        "pth", "pt", "ckpt", "index", "zip", "tar", "gz", "tgz", "7z"
    ]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z"]

    static func classifyDirectLink(_ raw: String) -> VoiceModelLinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        let ext = (URL(string: trimmed)?.pathExtension ?? "").lowercased()
        if conversionRequiredExtensions.contains(ext) {
            return .requiresConversion(ext: ext)
        }
        if runnableModelExtensions.contains(ext) {
            guard let url = normalizedDirectModelURL(from: trimmed) else { return .invalid }
            return .modelFile(url)
        }
        if ext == "voicepack" {
            guard let direct = parseDirectRepoIdentifier(from: trimmed) else { return .invalid }
            return .repository(repoID: direct.repoID, platform: direct.platform)
        }
        if let direct = parseDirectRepoIdentifier(from: trimmed) {
            return .repository(repoID: direct.repoID, platform: direct.platform)
        }
        return .invalid
    }

    /// 将常见网页展示链接（例如 HuggingFace `/blob/main/...` 或 GitHub `/blob/main/...`）规范化为可直链下载的地址。
    static func normalizedDirectModelURL(from rawURLString: String) -> URL? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }

        // HuggingFace / HF-Mirror `/owner/repo/blob/branch/path` -> `/owner/repo/resolve/branch/path`
        if (host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com"),
           parts.count >= 5, parts[2] == "blob" {
            var rewritten = parts
            rewritten[2] = "resolve"
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.path = "/" + rewritten.joined(separator: "/")
            return comps?.url ?? url
        }

        // HuggingFace 数据集 `/datasets/owner/repo/blob/branch/path` 同理
        if (host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com"),
           parts.count >= 6, parts[0] == "datasets", parts[3] == "blob" {
            var rewritten = parts
            rewritten[3] = "resolve"
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.path = "/" + rewritten.joined(separator: "/")
            return comps?.url ?? url
        }

        // GitHub `/owner/repo/blob/branch/path` -> `https://raw.githubusercontent.com/owner/repo/branch/path`
        if host == "github.com", parts.count >= 5, parts[2] == "blob" {
            let rawPath = "/" + ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/")
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "raw.githubusercontent.com"
            comps.path = rawPath
            return comps.url ?? url
        }

        return url
    }

    /// HuggingFace `/resolve/` 链接若只给了 `.onnx`，同目录同名 `.f32bin` 通常是配套检索索引。
    static func inferredCompanionIndexURL(for modelURL: URL) -> URL? {
        let host = modelURL.host?.lowercased() ?? ""
        guard modelURL.pathExtension.lowercased() == "onnx",
              host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com",
              modelURL.path.contains("/resolve/") else { return nil }
        let stem = modelURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }
        return modelURL.deletingLastPathComponent().appendingPathComponent("\(stem).f32bin")
    }

    static func isBaseInfrastructureFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".voicepack") { return false }
        let stem = (lower as NSString).deletingPathExtension
        let blockedTokens = [
            "rmvpe", "hubert", "contentvec", "vec-256", "vec-768",
            "uvr-mdx", "uvr_mdx", "voc_ft", "fcpe", "crepe", "harvest"
        ]
        return blockedTokens.contains { stem.contains($0) }
    }

    static func humanizedDisplayName(from raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let candidate = stem.isEmpty ? raw : stem
        let cleaned = candidate
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "RVC 音色" : cleaned
    }

    // MARK: - HuggingFace API

    private func searchHuggingFace(
        query: String,
        mirrorConfig: VoiceModelMirrorConfig,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRepoSummary] {
        var components = URLComponents()
        components.path = "/api/models"
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "full", value: "true")
        ]
        guard let officialURL = URL(string: VoiceModelMirrorConfig.officialHFBase + (components.string ?? "")) else {
            throw VoiceError.unsupportedModel("无法构造 HuggingFace 搜索地址")
        }

        let (data, _) = try await fetchWithMirrorFallback(
            officialURL: officialURL,
            mirrorConfig: mirrorConfig,
            allowNetwork: allowNetwork
        )
        let decoded = try JSONDecoder().decode([HFModelDTO].self, from: data)

        let mapped: [VoiceModelRepoSummary] = decoded.compactMap { item in
            let listing = Self.repoListing((item.siblings ?? []).map {
                RepoListing.Item(path: $0.rfilename, size: $0.lfs?.size ?? $0.size, sha256: nil)
            })
            // 只保留真的含可运行音色的仓库：否则列表里全是底座/训练仓库，用户无法判断哪个能用。
            guard listing.voiceCount > 0 else { return nil }
            // 直接把前几个音色名放进摘要，用户不用点进去猜"这是谁的声音"。
            let names = listing.voiceNames
            let sampleNames = names.prefix(3)
            let ellipsis = names.count > sampleNames.count ? "…" : ""
            let summaryText = "\(listing.voiceCount) 个音色：\(sampleNames.joined(separator: "、"))\(ellipsis) · \(item.downloads ?? 0) 次下载"

            return VoiceModelRepoSummary(
                id: "hf:\(item.id)",
                platform: .huggingFace,
                repoID: item.id,
                title: item.id,
                summary: summaryText,
                downloadsOrStars: item.downloads ?? 0,
                onnxFileCount: listing.voiceCount,
                tags: item.tags ?? [],
                pageURL: Self.repoPageURL(platform: .huggingFace, repoID: item.id, mirrorConfig: mirrorConfig),
                defaultBranch: "main",
                isRecommended: item.id.caseInsensitiveCompare("ozada/onnx_rvc") == .orderedSame
            )
        }

        return mapped.sorted { lhs, rhs in
            if lhs.onnxFileCount != rhs.onnxFileCount {
                return lhs.onnxFileCount > rhs.onnxFileCount
            }
            return lhs.downloadsOrStars > rhs.downloadsOrStars
        }
    }

    private func inspectHuggingFaceRepo(
        repoID: String,
        mirrorConfig: VoiceModelMirrorConfig,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRemoteFile] {
        let encodedRepo = repoID.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let officialURL = URL(string: "\(VoiceModelMirrorConfig.officialHFBase)/api/models/\(encodedRepo)?blobs=true") else {
            throw VoiceError.unsupportedModel("无效的仓库标识：\(repoID)")
        }

        let (data, _) = try await fetchWithMirrorFallback(
            officialURL: officialURL,
            mirrorConfig: mirrorConfig,
            allowNetwork: allowNetwork
        )
        let detail = try JSONDecoder().decode(HFModelDTO.self, from: data)
        let listing = Self.repoListing((detail.siblings ?? []).map {
            // `?blobs=true` 的模型详情返回 `lfs.sha256`；`tree` 接口返回的 `lfs.oid` 也是同一个 SHA256。
            RepoListing.Item(path: $0.rfilename, size: $0.lfs?.size ?? $0.size, sha256: $0.lfs?.sha256 ?? $0.lfs?.oid)
        })
        return Self.remoteFiles(from: listing, repoID: repoID, platform: .huggingFace) { path in
            Self.hfResolveURL(repoID: repoID, relativePath: path)
        }
    }

    /// 把仓库清单转成可下载条目：音色包文件夹在前（整组下载），独立 `.onnx` 在后（配同名索引）。
    static func remoteFiles(
        from listing: RepoListing,
        repoID: String,
        platform: VoiceModelSearchPlatform,
        resolveURL: (String) -> URL?
    ) -> [VoiceModelRemoteFile] {
        let idPrefix = platform == .huggingFace ? "hf" : "gh"
        var files: [VoiceModelRemoteFile] = []
        for (folder, items) in listing.packFolders {
            let packFiles = items.compactMap { item -> VoiceModelRemoteFile.PackFile? in
                guard let url = resolveURL(item.path) else { return nil }
                return VoiceModelRemoteFile.PackFile(
                    name: (item.path as NSString).lastPathComponent,
                    url: url,
                    sizeBytes: item.size,
                    sha256: item.sha256
                )
            }
            guard let identity = resolveURL(folder), !packFiles.isEmpty else { continue }
            let folderName = (folder as NSString).lastPathComponent
            let total = items.compactMap(\.size).reduce(0, +)
            files.append(VoiceModelRemoteFile(
                id: "\(idPrefix):\(repoID)::\(folder)",
                repoID: repoID,
                platform: platform,
                fileName: folderName,
                relativePath: folder,
                displayName: humanizedDisplayName(from: folderName),
                downloadURL: identity,
                sizeBytes: total > 0 ? total : nil,
                sha256: nil,
                companionIndexURL: nil,
                packFiles: packFiles
            ))
        }
        for item in listing.standaloneModels {
            guard let downloadURL = resolveURL(item.path) else { continue }
            let fileName = (item.path as NSString).lastPathComponent
            let stem = (fileName as NSString).deletingPathExtension.lowercased()
            files.append(VoiceModelRemoteFile(
                id: "\(idPrefix):\(repoID)::\(item.path)",
                repoID: repoID,
                platform: platform,
                fileName: fileName,
                relativePath: item.path,
                displayName: humanizedDisplayName(from: fileName),
                downloadURL: downloadURL,
                sizeBytes: item.size,
                sha256: item.sha256,
                companionIndexURL: listing.indexByStem[stem].flatMap { resolveURL($0.path) }
            ))
        }
        return files
    }

    // MARK: - GitHub API

    private func searchGitHub(
        query: String,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRepoSummary] {
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "20")
        ]
        guard let url = components?.url else {
            throw VoiceError.unsupportedModel("无法构造 GitHub 搜索地址")
        }

        let (data, _) = try await VoiceRemoteDownloader.fetchData(for: url, session: session, allowNetwork: allowNetwork)
        let decoded = try JSONDecoder().decode(GitHubRepoSearchDTO.self, from: data)
        return decoded.items.compactMap { item in
            guard let htmlURL = URL(string: item.htmlUrl) else { return nil }
            let desc = (item.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return VoiceModelRepoSummary(
                id: "gh:\(item.fullName)",
                platform: .github,
                repoID: item.fullName,
                title: item.fullName,
                summary: desc.isEmpty ? "★ \(item.stargazersCount) · GitHub 仓库" : "★ \(item.stargazersCount) · \(desc)",
                downloadsOrStars: item.stargazersCount,
                onnxFileCount: 0,
                tags: item.topics ?? [],
                pageURL: htmlURL,
                defaultBranch: item.defaultBranch ?? "main",
                isRecommended: false
            )
        }
    }

    private func inspectGitHubRepo(
        repoID: String,
        defaultBranchHint: String,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> [VoiceModelRemoteFile] {
        var branch = defaultBranchHint
        if let repoInfoURL = URL(string: "https://api.github.com/repos/\(repoID)") {
            if let (repoData, _) = try? await VoiceRemoteDownloader.fetchData(for: repoInfoURL, session: session, allowNetwork: allowNetwork),
               let repoInfo = try? JSONDecoder().decode(GitHubRepoDetailDTO.self, from: repoData),
               let realBranch = repoInfo.defaultBranch, !realBranch.isEmpty {
                branch = realBranch
            }
        }

        var files: [VoiceModelRemoteFile] = []
        var treeError: Error?
        if let treeURL = URL(string: "https://api.github.com/repos/\(repoID)/git/trees/\(branch)?recursive=1") {
            do {
                let (treeData, _) = try await VoiceRemoteDownloader.fetchData(for: treeURL, session: session, allowNetwork: allowNetwork)
                let tree = try JSONDecoder().decode(GitHubTreeResponseDTO.self, from: treeData)
                let blobs = tree.tree.filter { $0.type == "blob" }
                // 模型一般超过 GitHub 的单文件上限，仓库里存的是 Git LFS 占位符（一百多字节的文本）：
                // 这类文件要从 LFS 地址取，按 raw 地址下到的只是占位符；大小未知，不显示那个假的字节数。
                let lfsPaths = Set(blobs.filter { Self.looksLikeLFSPointer(path: $0.path, size: $0.size) }.map(\.path))
                let listing = Self.repoListing(blobs.map {
                    RepoListing.Item(path: $0.path, size: lfsPaths.contains($0.path) ? nil : $0.size, sha256: nil)
                })
                files = Self.remoteFiles(from: listing, repoID: repoID, platform: .github) { path in
                    Self.githubRawURL(repoID: repoID, branch: branch, relativePath: path, lfs: lfsPaths.contains(path))
                }
            } catch let error as VoiceError {
                // 关联网、被限流要如实告诉用户；别的失败（空仓库等）再去 Releases 里找找。
                if case .networkDisabled = error { throw error }
                if VoiceRemoteDownloader.isRateLimited(error) { throw error }
                treeError = error
            } catch {
                treeError = error
            }
        }

        // 若仓库把音色模型上传在 Release Assets 而非 git tree 中，一并扫描最新 Releases
        if files.isEmpty,
           let relURL = URL(string: "https://api.github.com/repos/\(repoID)/releases?per_page=3"),
           let (relData, _) = try? await VoiceRemoteDownloader.fetchData(for: relURL, session: session, allowNetwork: allowNetwork),
           let releases = try? JSONDecoder().decode([GitHubReleaseDTO].self, from: relData) {
            for rel in releases {
                for asset in rel.assets {
                    // Release 附件是单个文件；`.voicepack` 是文件夹，没法当单文件导入。
                    guard asset.name.lowercased().hasSuffix(".onnx") else { continue }
                    guard !Self.isBaseInfrastructureFileName(asset.name) else { continue }
                    guard let dlURL = URL(string: asset.browserDownloadUrl) else { continue }
                    files.append(
                        VoiceModelRemoteFile(
                            id: "gh-rel:\(repoID)::\(asset.name)",
                            repoID: repoID,
                            platform: .github,
                            fileName: asset.name,
                            relativePath: "releases/\(asset.name)",
                            displayName: Self.humanizedDisplayName(from: asset.name),
                            downloadURL: dlURL,
                            sizeBytes: asset.size,
                            sha256: nil,
                            companionIndexURL: nil
                        )
                    )
                }
            }
        }

        if files.isEmpty, let treeError { throw treeError }
        return files
    }

    // MARK: - Helpers

    private func fetchWithMirrorFallback(
        officialURL: URL,
        mirrorConfig: VoiceModelMirrorConfig,
        allowNetwork: @escaping @Sendable () -> Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let candidates = mirrorConfig.apiCandidateURLs(for: officialURL)
        var lastError: Error?
        for url in candidates {
            try Task.checkCancellation()
            do {
                return try await VoiceRemoteDownloader.fetchData(
                    for: url,
                    session: session,
                    allowNetwork: allowNetwork
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let voiceError as VoiceError {
                if case .networkDisabled = voiceError { throw voiceError }
                lastError = voiceError
            } catch let policy as SourceDomainPolicy.Violation {
                if case .networkDisabled = policy {
                    throw VoiceError.networkDisabled("已在设置中关闭联网，无法请求模型列表。")
                }
                lastError = policy
            } catch {
                lastError = error
            }
        }
        if lastError is URLError || lastError == nil {
            // 连不上：镜像只代理文件下载，检索接口只能访问官方站。
            throw VoiceError.io(String(localized: "连不上 huggingface.co，暂时无法在线检索。镜像只能加速下载：可以在「URL 直链」里粘贴模型下载链接，或换个能访问的网络再试。"))
        }
        throw lastError ?? VoiceError.io("无法连接模型索引服务")
    }

    private static func repoPageURL(
        platform: VoiceModelSearchPlatform,
        repoID: String,
        mirrorConfig: VoiceModelMirrorConfig
    ) -> URL {
        switch platform {
        case .huggingFace:
            return URL(string: "\(mirrorConfig.activeHuggingFaceBaseURLString)/\(repoID)")
                ?? URL(string: "https://huggingface.co/\(repoID)")!
        case .github:
            return URL(string: "https://github.com/\(repoID)")!
        }
    }

    static func hfResolveURL(repoID: String, relativePath: String) -> URL? {
        let encodedPath = relativePath.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "\(VoiceModelMirrorConfig.officialHFBase)/\(repoID)/resolve/main/\(encodedPath)")
    }

    static func githubRawURL(repoID: String, branch: String, relativePath: String, lfs: Bool = false) -> URL? {
        let encodedPath = relativePath.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        if lfs {
            return URL(string: "https://media.githubusercontent.com/media/\(repoID)/\(branch)/\(encodedPath)")
        }
        return URL(string: "https://raw.githubusercontent.com/\(repoID)/\(branch)/\(encodedPath)")
    }

    /// Git LFS 占位符只有一百多字节；真正的模型和索引不可能这么小。
    static func looksLikeLFSPointer(path: String, size: Int64?) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".onnx") || lower.hasSuffix(".f32bin"), let size else { return false }
        return size > 0 && size < 1024
    }

    /// 下载到的文件其实是 Git LFS 占位符（不是模型本体）。
    static func isLFSPointerFile(at url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.int64Value < 1024,
              let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix("version https://git-lfs")
    }

    private static func resolveSafeFileName(suggested: String?, url: URL?, fallbackExt: String) -> String {
        let base = sanitizedFileName(suggested?.isEmpty == false ? suggested! : (url?.lastPathComponent ?? ""))
        let ext = (base as NSString).pathExtension.lowercased()
        if ext == "onnx" || ext == "voicepack" || ext == "f32bin" {
            return base
        }
        return "\(base).\(fallbackExt)"
    }

    /// 只做路径安全处理、保留原扩展名（音色包里的 `pack.json`、封面图要原样落盘）。
    private static func sanitizedFileName(_ raw: String) -> String {
        let candidate = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "voice_model" : candidate
    }
}

// MARK: - DTOs

private struct HFModelDTO: Decodable {
    let id: String
    let downloads: Int?
    let tags: [String]?
    let siblings: [HFSiblingDTO]?
}

private struct HFSiblingDTO: Decodable {
    let rfilename: String
    let size: Int64?
    let lfs: HFLfsDTO?
}

private struct HFLfsDTO: Decodable {
    let sha256: String?
    let oid: String?
    let size: Int64?
}

private struct GitHubRepoSearchDTO: Decodable {
    let items: [GitHubRepoItemDTO]
}

private struct GitHubRepoItemDTO: Decodable {
    let fullName: String
    let description: String?
    let stargazersCount: Int
    let htmlUrl: String
    let defaultBranch: String?
    let topics: [String]?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case description
        case stargazersCount = "stargazers_count"
        case htmlUrl = "html_url"
        case defaultBranch = "default_branch"
        case topics
    }
}

private struct GitHubRepoDetailDTO: Decodable {
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

private struct GitHubTreeResponseDTO: Decodable {
    let tree: [GitHubTreeNodeDTO]
}

private struct GitHubTreeNodeDTO: Decodable {
    let path: String
    let type: String
    let size: Int64?
}

private struct GitHubReleaseDTO: Decodable {
    let assets: [GitHubReleaseAssetDTO]
}

private struct GitHubReleaseAssetDTO: Decodable {
    let name: String
    let size: Int64
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadUrl = "browser_download_url"
    }
}
