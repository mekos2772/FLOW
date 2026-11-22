import Foundation

/// 列表分批加载进度（源无关，供搜索/发现/歌单渐进刷新列表）。
struct TrackListBatch: Sendable {
    var tracks: [Track] = []
    var checked = 0
    var total = 0
    var unavailable = 0
    var customMessage: String? = nil

    init(tracks: [Track] = [],
         checked: Int = 0,
         total: Int = 0,
         unavailable: Int = 0,
         message: String? = nil) {
        self.tracks = tracks
        self.checked = checked
        self.total = total
        self.unavailable = unavailable
        self.customMessage = message
    }

    var message: String? {
        if let customMessage { return customMessage }
        if unavailable > 0 { return SourceErrorPresentation.unavailableSentinel }
        return checked == total && tracks.isEmpty ? SourceErrorPresentation.emptyResultSentinel : nil
    }
}

/// 可选能力：发现页 / 榜单推荐。
protocol DiscoverableSourceProvider: PlaybackSourceProvider {
    func discoverTracks(limit: Int,
                        progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track]
}

/// 可选能力：直链 / 特定 ID 解析（例如分享链接、分P、歌单链接）。
protocol URLResolvableSourceProvider: PlaybackSourceProvider {
    func canHandleQuery(_ query: String) -> Bool
    func resolveQuery(_ query: String) async throws -> [Track]
}

/// 可选能力：相关推荐连续电台。
protocol RelatedRadioSourceProvider: PlaybackSourceProvider {
    func relatedTracks(for track: Track, limit: Int) async throws -> [Track]
}

/// 可选能力：多档音质切换与实际音质描述。
@MainActor
protocol QualitySelectableSourceController: AnyObject, Sendable {
    var currentQualityTier: AudioQualityTier { get }
    var lastActualQualityText: String? { get }
    var availableQualityTiers: [AudioQualityTier] { get }
    func qualityRequirementHint(for tier: AudioQualityTier) -> String?
    func applyQuality(_ tier: AudioQualityTier) async -> String?
}

/// 源账号认证状态。
enum SourceAuthState: Equatable, Sendable {
    case signedOut
    case showingQR(url: String, hint: String)
    case scanned(hint: String)
    case expired(hint: String)
    case failed(String)
    case signedIn(summary: String, detail: String?)
}

/// 源内个人集合（收藏夹、历史或远端歌单）。
struct SourceCollection: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case favorites
        case history
        case playlists
    }

    let id: String
    let title: String
    let kind: Kind
}

/// 可选能力：账号登录与个人曲库控制器（扫码、Cookie/Token 或服务器表单登录）。
@MainActor
protocol SourceAccountController: AnyObject, Sendable {
    var authState: SourceAuthState { get }
    var supportsQRLogin: Bool { get }
    var isSigningIn: Bool { get }
    var accountDetailText: String? { get }

    func refreshAuthStatus() async
    func beginQRLogin() async
    func cancelLogin()
    func signOut()
    func collections() async throws -> [SourceCollection]
    func tracks(in collection: SourceCollection) async throws -> [Track]
}

/// 源无关的网络与接口友好错误文案转换。
enum SourceErrorPresentation {
    static var emptyResultSentinel: String { String(localized: "没有找到这首歌") }
    static var unavailableSentinel: String { String(localized: "暂时无法加载，请稍后重试") }

    static func friendly(_ error: any Error, subject: String? = nil) -> String {
        if let playbackError = error as? PlaybackError {
            return playbackError.detail
        }
        if let remote = error as? RemoteHTTPFailure {
            // 用户看到的是「添加服务器失败」，不该是「WebDAV HTTP 401（401）」这种工程串。
            switch remote.code {
            case 401, 403, 40, 41:
                // 40 / 41 是 Subsonic 协议的「用户名或密码错误 / 不支持该登录方式」。
                return String(localized: "用户名或密码不对，或这个账号没有访问权限。")
            case 404:
                return String(localized: "在这个地址上找不到服务，请检查服务器地址。")
            case 500...599:
                return String(localized: "服务器暂时出错了，请稍后再试。")
            default:
                return remote.localizedDescription
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "网络似乎断开了，请检查连接后再试")
            case .timedOut:
                let target = subject ?? String(localized: "音源")
                return String(localized: "请求\(target)响应较慢（已超时），请稍后重试")
            default:
                break
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return (error as NSError).localizedDescription
    }
}
