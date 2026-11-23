import CryptoKit
import Foundation

/// RVC 模型与底座资源下载镜像模式。
/// 默认采用国内友好的 HuggingFace 镜像源（hf-mirror.com），并自动保留官方地址兜底。
enum VoiceMirrorMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case hfMirror = "hfMirror"
    case official = "official"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hfMirror:
            return "默认镜像源（HF-Mirror）"
        case .official:
            return "官方直连（HuggingFace / GitHub）"
        case .custom:
            return "自定义镜像"
        }
    }

    var shortDescription: String {
        switch self {
        case .hfMirror:
            return "模型文件优先从 hf-mirror.com 下载，失败时自动回退官方源；在线检索仍需能访问 huggingface.co"
        case .official:
            return "直接连接 huggingface.co 与 github.com（适合海外网络或已配置代理环境）"
        case .custom:
            return "使用自定义 HuggingFace 镜像域名与可选 GitHub 加速前缀"
        }
    }
}

/// 镜像重写配置：封装镜像模式、自定义域名以及候选 URL 生成策略。
struct VoiceModelMirrorConfig: Equatable, Hashable, Codable, Sendable {
    static let defaultHFMirrorBase = "https://hf-mirror.com"
    static let officialHFBase = "https://huggingface.co"

    var mode: VoiceMirrorMode
    var customHFMirrorBase: String
    var customGitHubPrefix: String

    init(
        mode: VoiceMirrorMode = .hfMirror,
        customHFMirrorBase: String = VoiceModelMirrorConfig.defaultHFMirrorBase,
        customGitHubPrefix: String = ""
    ) {
        self.mode = mode
        self.customHFMirrorBase = Self.normalizedBaseURLString(
            customHFMirrorBase,
            fallback: Self.defaultHFMirrorBase
        )
        self.customGitHubPrefix = Self.normalizedOptionalPrefix(customGitHubPrefix)
    }

    static let `default` = VoiceModelMirrorConfig()

    /// 规范化基础域名配置：空串回退到默认地址，补全 https://，去掉末尾斜杠。
    static func normalizedBaseURLString(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let withScheme: String
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 规范化可选前缀（例如 `https://mirror.example/` -> `https://mirror.example`）。
    static func normalizedOptionalPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme: String
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 当前生效的 HuggingFace Hub 根地址（用于网页检索 API 与 `/resolve/...` 下载）。
    var activeHuggingFaceBaseURLString: String {
        switch mode {
        case .hfMirror:
            return Self.defaultHFMirrorBase
        case .official:
            return Self.officialHFBase
        case .custom:
            return Self.normalizedBaseURLString(
                customHFMirrorBase,
                fallback: Self.defaultHFMirrorBase
            )
        }
    }

    /// 根据当前镜像模式重写单个 URL（保持路径与 query 不变）。
    func preferredURL(for url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }

        // 1. HuggingFace / HF-Mirror 互转
        if host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com" {
            let targetBase: String
            switch mode {
            case .hfMirror:
                targetBase = Self.defaultHFMirrorBase
            case .official:
                targetBase = Self.officialHFBase
            case .custom:
                targetBase = Self.normalizedBaseURLString(
                    customHFMirrorBase,
                    fallback: Self.defaultHFMirrorBase
                )
            }
            if let rewritten = Self.replacingOrigin(of: url, withBase: targetBase) {
                return rewritten
            }
            return url
        }

        // 2. GitHub 资源加速前缀（仅在自定义模式下且配置了前缀时启用；GitHub API 查询不加前缀）
        if mode == .custom,
           !customGitHubPrefix.isEmpty,
           (host == "github.com" || host == "raw.githubusercontent.com") {
            let prefix = Self.normalizedOptionalPrefix(customGitHubPrefix)
            if !prefix.isEmpty, let rewritten = URL(string: "\(prefix)/\(url.absoluteString)") {
                return rewritten
            }
        }

        return url
    }

    /// 返回官方直连地址（去除镜像域/前缀，便于兜底回退）。
    func officialURL(for url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        if host == "hf-mirror.com" {
            return Self.replacingOrigin(of: url, withBase: Self.officialHFBase) ?? url
        }
        if customHostMatches(host) {
            var stripped = url
            let prefix = (URLComponents(string: customHFMirrorBase)?.path ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !prefix.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               comps.path.hasPrefix("/\(prefix)/") {
                comps.path = String(comps.path.dropFirst(prefix.count + 1))
                stripped = comps.url ?? url
            }
            return Self.replacingOrigin(of: stripped, withBase: Self.officialHFBase) ?? url
        }
        return url
    }

    /// 生成按优先级排序、去重后的候选下载地址列表：
    /// `[首选镜像 URL..., 备选官方/备用源 URL...]`。
    func candidateURLs(for primary: URL, alternates: [URL] = []) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func appendUnique(_ url: URL) {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }

        let inputs = [primary] + alternates
        // 对每个源文件优先采用当前模式（默认镜像），随即提供官方地址回退，避免镜像整站故障时连续重复重试同一镜像主机。
        for url in inputs {
            appendUnique(preferredURL(for: url))
            appendUnique(officialURL(for: url))
            appendUnique(url)
            if mode == .official, Self.isHuggingFaceHost(url.host),
               let mirror = Self.replacingOrigin(of: url, withBase: Self.defaultHFMirrorBase) {
                appendUnique(mirror)
            }
        }

        return result
    }

    /// HF Hub 的 `/api/*` 检索请求：hf-mirror.com 只代理文件下载、`/api` 会 308 回官方站，
    /// 先试它只会多等一轮超时；自定义镜像可能代理了 API，保留在官方之前。
    func apiCandidateURLs(for officialURL: URL) -> [URL] {
        switch mode {
        case .official, .hfMirror:
            return [officialURL]
        case .custom:
            return candidateURLs(for: officialURL)
        }
    }

    private func customHostMatches(_ host: String) -> Bool {
        guard mode == .custom,
              let customHost = URL(string: customHFMirrorBase)?.host?.lowercased()
        else { return false }
        return host == customHost
    }

    private static func isHuggingFaceHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "huggingface.co" || host == "www.huggingface.co" || host == "hf-mirror.com"
    }

    private static func replacingOrigin(of url: URL, withBase base: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(string: base),
              let scheme = baseComponents.scheme,
              let host = baseComponents.host
        else { return nil }
        components.scheme = scheme
        components.host = host
        components.port = baseComponents.port
        // 自定义镜像可能挂在子路径下（如 `https://example.com/hf`），保留这段前缀。
        let prefix = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty, !components.path.hasPrefix("/\(prefix)/") {
            components.path = "/\(prefix)" + components.path
        }
        return components.url
    }
}

/// 共享的 RVC 远端请求与大文件下载器：
/// - 统一尊重联网开关（含 HTTP 重定向阶段）
/// - 自动按镜像列表 -> 官方源顺序尝试下载并反馈实时进度
/// - 支持分块流式 SHA256 校验，避免百兆模型占用大量内存
enum VoiceRemoteDownloader {
    struct DownloadResult: Sendable {
        let tempFileURL: URL
        let sha256: String
        let resolvedURL: URL
    }

    static func fetchData(
        for url: URL,
        session: URLSession,
        allowNetwork: @escaping @Sendable () -> Bool,
        timeout: TimeInterval = 20
    ) async throws -> (Data, HTTPURLResponse) {
        guard allowNetwork() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法请求远端模型。")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("SpatialLyricsPlayer/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: [],
            networkAllowed: allowNetwork
        )
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.inferenceFailed("无效的服务器响应")
        }
        if (http.statusCode == 403 || http.statusCode == 429), url.host?.lowercased() == "api.github.com" {
            throw VoiceError.io(rateLimitMessage)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.inferenceFailed("请求失败（HTTP \(http.statusCode)）：\(url.host ?? url.absoluteString)")
        }
        return (data, http)
    }

    static let rateLimitMessage = String(localized: "GitHub 暂时限制了访问次数（未登录每小时约 60 次），请过一会儿再试，或改用 HuggingFace 检索。")

    static func isRateLimited(_ error: VoiceError) -> Bool {
        if case .io(let message) = error { return message == rateLimitMessage }
        return false
    }

    static func downloadFileWithFallback(
        candidateURLs: [URL],
        session: URLSession,
        allowNetwork: @escaping @Sendable () -> Bool,
        expectedSHA256: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        guard allowNetwork() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法请求远端模型。")
        }
        guard !candidateURLs.isEmpty else {
            throw VoiceError.unsupportedModel("未配置可用的下载地址")
        }

        var lastError: Error?
        var sha256Failure: Error?
        for url in candidateURLs {
            try Task.checkCancellation()
            guard allowNetwork() else {
                throw VoiceError.networkDisabled("已在设置中关闭联网，已中止下载。")
            }
            onProgress?(0)
            do {
                let stagedURL = try await downloadSingleFile(
                    from: url,
                    session: session,
                    allowNetwork: allowNetwork,
                    onProgress: onProgress
                )
                do {
                    let actualSHA256 = try sha256Stream(url: stagedURL)
                    if let expectedSHA256,
                       actualSHA256.caseInsensitiveCompare(expectedSHA256) != .orderedSame {
                        try? FileManager.default.removeItem(at: stagedURL)
                        throw VoiceError.invalidManifest(
                            reason: "SHA256 校验失败（期望 \(expectedSHA256.prefix(12))…，实际 \(actualSHA256.prefix(12))…），已拒绝写入"
                        )
                    }
                    onProgress?(1.0)
                    return DownloadResult(tempFileURL: stagedURL, sha256: actualSHA256, resolvedURL: url)
                } catch {
                    try? FileManager.default.removeItem(at: stagedURL)
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let voiceError as VoiceError where isFatalNetworkPolicyError(voiceError) {
                throw voiceError
            } catch let voiceError as VoiceError {
                if case .invalidManifest = voiceError, sha256Failure == nil {
                    sha256Failure = voiceError
                }
                lastError = voiceError
            } catch let policyError as SourceDomainPolicy.Violation {
                if case .networkDisabled = policyError {
                    throw VoiceError.networkDisabled("已在设置中关闭联网，已中止下载。")
                }
                lastError = policyError
            } catch {
                lastError = error
            }
        }

        throw sha256Failure ?? lastError ?? VoiceError.io("全部下载源均不可用")
    }

    /// 流式分块计算文件 SHA256，防止数百 MB 的 ONNX 模型导致高内存峰值。
    static func sha256Stream(url: URL, chunkSize: Int = 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isFatalNetworkPolicyError(_ error: VoiceError) -> Bool {
        if case .networkDisabled = error { return true }
        return false
    }

    private static func downloadSingleFile(
        from url: URL,
        session: URLSession,
        allowNetwork: @escaping @Sendable () -> Bool,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.setValue("SpatialLyricsPlayer/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let redirects = PluginHTTPClient.RedirectValidator(
            allowedDomains: [],
            originURL: url,
            networkAllowed: allowNetwork
        )
        try redirects.validate(request)

        let taskBox = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice-dl-\(UUID().uuidString).part")

                let task = session.downloadTask(with: request) { tempURL, response, error in
                    taskBox.invalidateObserver()
                    if !allowNetwork() {
                        // 下载途中关了联网（进度回调里已叫停）：按"联网已关闭"报，不当成普通失败去换源重试。
                        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                        continuation.resume(throwing: VoiceError.networkDisabled("已在设置中关闭联网，已中止下载。"))
                        return
                    }
                    if let violation = redirects.violation {
                        if case .networkDisabled = violation {
                            continuation.resume(throwing: VoiceError.networkDisabled("已在设置中关闭联网，已中止下载。"))
                        } else {
                            continuation.resume(throwing: violation)
                        }
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: VoiceError.io("下载未返回有效的 HTTP 响应"))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        continuation.resume(
                            throwing: VoiceError.io("下载失败（HTTP \(http.statusCode)）")
                        )
                        return
                    }
                    guard let tempURL else {
                        continuation.resume(throwing: VoiceError.io("下载未生成临时文件"))
                        return
                    }
                    do {
                        if FileManager.default.fileExists(atPath: stagedURL.path) {
                            try FileManager.default.removeItem(at: stagedURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: stagedURL)
                        continuation.resume(returning: stagedURL)
                    } catch {
                        try? FileManager.default.removeItem(at: stagedURL)
                        continuation.resume(throwing: error)
                    }
                }
                task.delegate = redirects

                // 进度回调顺带盯着联网开关：生成任务里自动下载底座模型不在「下载」列表里，
                // 关联网时没人替它取消，只能在这里自己停。
                let obs = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    guard allowNetwork() else {
                        taskBox.cancel()
                        return
                    }
                    let clamped = min(max(progress.fractionCompleted, 0), 0.99)
                    if let onProgress, taskBox.shouldEmitProgress(clamped) {
                        onProgress(clamped)
                    }
                }
                taskBox.setObserver(obs)

                taskBox.set(task)
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var observer: NSKeyValueObservation?
    private var lastReported: Double = -1

    func set(_ task: URLSessionDownloadTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func setObserver(_ obs: NSKeyValueObservation) {
        lock.withLock {
            if !cancelled {
                self.observer = obs
            } else {
                obs.invalidate()
            }
        }
    }

    func invalidateObserver() {
        lock.withLock {
            observer?.invalidate()
            observer = nil
        }
    }

    func shouldEmitProgress(_ clamped: Double) -> Bool {
        lock.withLock {
            if lastReported < 0 || clamped - lastReported >= 0.01 {
                lastReported = clamped
                return true
            }
            return false
        }
    }

    func cancel() {
        let target = lock.withLock { () -> URLSessionDownloadTask? in
            cancelled = true
            observer?.invalidate()
            observer = nil
            return task
        }
        target?.cancel()
    }
}
