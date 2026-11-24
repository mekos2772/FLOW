import Foundation
import Observation

/// 语义化版本号（支持 `v0.1.5`、`0.1.10`、`1.0.0-beta.1`），避免按字符串字典序比较把 `0.1.10` 判成旧于 `0.1.5`。
struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let isPrerelease: Bool

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutPrefix = (trimmed.hasPrefix("v") || trimmed.hasPrefix("V"))
            ? String(trimmed.dropFirst())
            : trimmed
        let withoutBuild = withoutPrefix.split(separator: "+", maxSplits: 1).first.map(String.init) ?? withoutPrefix
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        let core = parts[0].split(separator: ".")
        guard !core.isEmpty, core.count <= 3 else { return nil }
        let nums = core.compactMap { Int($0) }
        guard nums.count == core.count, nums.allSatisfy({ $0 >= 0 }) else { return nil }
        self.major = nums[0]
        self.minor = nums.count > 1 ? nums[1] : 0
        self.patch = nums.count > 2 ? nums[2] : 0
        self.isPrerelease = parts.count > 1
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

/// GitHub Release 更新信息快照。
struct AppReleaseInfo: Equatable, Sendable {
    let tagName: String
    let version: String
    let releaseURL: URL
    let downloadURL: URL?
    let summary: String?
}

/// 应用更新检查状态。
enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(AppReleaseInfo)
    case failed(String)
}

/// 基于 GitHub Releases API 的手动检查更新器。
///
/// 仅在用户主动点击「检查更新」时联网，严格遵守应用的「允许联网」开关，
/// 且仅放行 GitHub 官方域名（`api.github.com` / `github.com` / `*.githubusercontent.com`）的 HTTPS 地址。
@MainActor
@Observable
final class AppUpdateChecker {
    static let defaultRepository = "mekos2772/FLOW"
    static let releasesPageURL = URL(string: "https://github.com/mekos2772/FLOW/releases")!
    private static let apiAllowedDomains = ["api.github.com"]
    private static let releaseLinkAllowedDomains = ["github.com", "*.githubusercontent.com"]

    private(set) var state: AppUpdateState = .idle

    @ObservationIgnored private let repository: String
    @ObservationIgnored private let currentVersionProvider: @Sendable () -> String
    @ObservationIgnored private let networkAllowed: @Sendable () -> Bool
    @ObservationIgnored private let session: URLSession

    init(
        repository: String = AppUpdateChecker.defaultRepository,
        currentVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        },
        networkAllowed: @escaping @Sendable () -> Bool,
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.currentVersionProvider = currentVersionProvider
        self.networkAllowed = networkAllowed
        self.session = session
    }

    func checkForUpdates() async {
        guard state != .checking else { return }
        guard networkAllowed() else {
            state = .failed(String(localized: "当前已关闭联网，请在隐私设置中开启「允许联网」后再检查更新。"))
            return
        }
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            state = .failed(String(localized: "更新地址无效"))
            return
        }

        state = .checking
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FLOW-macOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await PluginHTTPClient.data(
                for: request,
                session: session,
                allowedDomains: Self.apiAllowedDomains,
                networkAllowed: networkAllowed,
                maximumBytes: 512 * 1024
            )
            guard let http = response as? HTTPURLResponse else {
                state = .failed(String(localized: "未收到有效的更新响应"))
                return
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                state = .failed(String(localized: "GitHub 接口请求受限，请稍后再试或直接前往发布页查看。"))
                return
            }
            if http.statusCode == 404 {
                state = .upToDate(currentVersion: currentVersionProvider())
                return
            }
            guard (200...299).contains(http.statusCode) else {
                state = .failed(String(localized: "检查更新失败（HTTP \(http.statusCode)）"))
                return
            }

            let decoded = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            let currentRaw = currentVersionProvider()
            guard let remoteVer = SemanticVersion(rawValue: decoded.tagName),
                  let currentVer = SemanticVersion(rawValue: currentRaw) else {
                state = .failed(String(localized: "无法解析版本号（\(decoded.tagName)）"))
                return
            }

            if remoteVer > currentVer {
                let releaseURL = Self.validatedHTTPSGitHubURL(decoded.htmlURL) ?? Self.releasesPageURL
                let downloadURL = Self.pickDMGDownloadURL(from: decoded.assets ?? [])
                let summary = Self.extractSummary(from: decoded.body)
                let cleanVer = "\(remoteVer.major).\(remoteVer.minor).\(remoteVer.patch)"
                state = .updateAvailable(AppReleaseInfo(
                    tagName: decoded.tagName,
                    version: cleanVer,
                    releaseURL: releaseURL,
                    downloadURL: downloadURL,
                    summary: summary
                ))
            } else {
                state = .upToDate(currentVersion: currentRaw)
            }
        } catch is CancellationError {
            state = .idle
        } catch let violation as SourceDomainPolicy.Violation {
            if case .networkDisabled = violation {
                state = .failed(String(localized: "当前已关闭联网，请在隐私设置中开启「允许联网」后再检查更新。"))
            } else {
                state = .failed(String(localized: "更新地址未通过安全校验"))
            }
        } catch {
            state = .failed(SourceErrorPresentation.friendly(error, subject: String(localized: "更新服务")))
        }
    }

    // MARK: - 内部解析

    private struct GitHubReleasePayload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: String
        let body: String?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private static func validatedHTTPSGitHubURL(_ raw: String) -> URL? {
        guard let url = try? SourceDomainPolicy.validate(url: raw, allowedDomains: releaseLinkAllowedDomains),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    private static func pickDMGDownloadURL(from assets: [GitHubReleasePayload.Asset]) -> URL? {
        let dmgAssets = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let preferred = dmgAssets.first { $0.name.lowercased().contains("arm64") } ?? dmgAssets.first
        guard let preferred else { return nil }
        return validatedHTTPSGitHubURL(preferred.browserDownloadURL)
    }

    private static func extractSummary(from body: String?) -> String? {
        guard let body else { return nil }
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return nil }
        let joined = lines.prefix(3).joined(separator: "\n")
        if joined.count <= 200 { return joined }
        return String(joined.prefix(200)) + "…"
    }
}
