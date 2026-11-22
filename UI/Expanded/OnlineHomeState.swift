import Foundation
import Observation

/// 浏览页各自保存结果；切页只取消请求，不重置播放或丢失搜索。
@MainActor
@Observable
final class OnlineHomeState {
    enum Section: Hashable { case recommendations, search, favorites, recent, playlists, offline }
    /// 离线页内的两类内容：下载保存的原曲，与本机生成的 AI 翻唱成品。
    enum OfflineKind: Hashable { case songs, aiCovers }

    var query = ""
    var offlineKind: OfflineKind = .songs
    /// 早期 AI 成品清单没存歌名：按身份从离线库/曲目库反查到的曲目。
    private(set) var legacyCoverTracks: [String: Track] = [:]
    private(set) var submittedQuery = ""
    private(set) var section: Section = .recommendations
    private let recommendationsList = SongListState()
    private let searchList = SongListState()
    private let favoritesList = SongListState()
    private let recentList = SongListState()
    private let offlineList = SongListState()
    private(set) var rankingPool: [Track] = []
    private(set) var favorites: Set<TrackIdentity> = []
    private(set) var recentSearches: [String] = []
    private(set) var artworkRevision = 0
    private var loaded: Set<Section> = []
    /// 已加载分区的上次刷新时刻：推荐/搜索结果 10 分钟内回首页不重复拉，
    /// 超过就算陈旧重取（否则整个会话看到的永远是第一次打开那份榜单）。
    private var loadedAt: [Section: Date] = [:]
    private static let staleAfter: TimeInterval = 600
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var list: SongListState {
        switch section {
        case .recommendations, .playlists: recommendationsList
        case .search: searchList
        case .favorites: favoritesList
        case .recent: recentList
        case .offline: offlineList
        }
    }

    var title: String {
        switch section {
        case .recommendations: String(localized: "首页")
        case .search: String(localized: "搜索结果")
        case .favorites: String(localized: "收藏")
        case .recent: String(localized: "最近播放")
        case .playlists: String(localized: "歌单")
        case .offline: String(localized: "离线")
        }
    }

    var canShowMore: Bool {
        section == .recommendations && RankingPagination.canShowMore(current: list.tracks.count, pool: rankingPool.count)
    }

    var feedback: String? {
        guard !list.isLoading else { return nil }
        if let message = list.message {
            if message == SourceErrorPresentation.emptyResultSentinel {
                switch section {
                case .recommendations: return String(localized: "暂无推荐歌曲")
                case .search: return String(localized: "没有找到这首歌")
                case .favorites: return String(localized: "暂无可显示的收藏")
                case .recent: return String(localized: "暂无可显示的播放记录")
                case .playlists, .offline: return nil
                }
            }
            if message == SourceErrorPresentation.unavailableSentinel {
                return String(localized: "暂时无法加载歌曲")
            }
            return message
        }
        guard list.tracks.isEmpty else { return nil }
        switch section {
        case .favorites: return String(localized: "还没有收藏")
        case .recent: return String(localized: "还没有播放记录")
        case .offline: return String(localized: "还没有离线保存的歌曲")
        default: return String(localized: "搜索一首想听的歌")
        }
    }

    /// 空态标题的"用户友好版"：接口失败时不再把后端原始错误文案铺成主标题，
    /// 降级成通用的"加载失败"引导，让用户看到"重试/去搜索"而不是技术行话。
    /// 真空集合（如确实没有收藏）仍走各自的友好文案。
    var friendlyEmpty: String? {
        guard !list.isLoading else { return nil }
        if let message = list.message {
            // "没找到"与"暂时无法"两条用户能听懂的文案放行；
            // 其它（限流、登录失效、网络断开等）统一收成「加载失败」。
            if message == SourceErrorPresentation.emptyResultSentinel {
                switch section {
                case .recommendations: return String(localized: "暂无推荐歌曲")
                case .search: return String(localized: "没有找到这首歌")
                case .favorites: return String(localized: "暂无可显示的收藏")
                case .recent: return String(localized: "暂无可显示的播放记录")
                case .playlists, .offline: return nil
                }
            }
            if message == SourceErrorPresentation.unavailableSentinel {
                return String(localized: "暂时无法加载歌曲")
            }
            return String(localized: "加载失败")
        }
        guard list.tracks.isEmpty else { return nil }
        switch section {
        case .favorites: return String(localized: "还没有收藏")
        case .recent: return String(localized: "还没有播放记录")
        case .offline: return String(localized: "还没有离线保存的歌曲")
        default: return String(localized: "搜索一首想听的歌")
        }
    }

    /// 是否在空态上额外挂「重试 + 去搜索」按钮：只在接口报错时给，真空集合不打扰。
    var showsLoadFailedHint: Bool {
        guard !list.isLoading, let message = list.message else { return false }
        // noMatch/unavailable 是"已经走到最后一步"的明确答复，不是可重试的失败。
        return message != SourceErrorPresentation.emptyResultSentinel
            && message != SourceErrorPresentation.unavailableSentinel
    }

    func activate(app: AppContainer?) {
        recentSearches = RecentSearchStore().all
        // 离开期间可能在播放页点过星标：loaded 命中时只重读收藏集合，
        // 不重拉整页（否则每次回首页都打一遍接口）。
        if loaded.contains(section), section != .playlists {
            Task { await refreshFavorites(app: app) }
            // 超过时效当陈旧处理：否则整个会话只见到第一次打开那份榜单。
            if let at = loadedAt[section], Date().timeIntervalSince(at) < Self.staleAfter { return }
        }
        guard section != .playlists, let app else { return }
        refresh(app: app)
    }

    func select(_ destination: Section, app: AppContainer?) {
        if section != destination { cancel(); section = destination }
        if destination == .favorites || destination == .recent || destination == .offline {
            refresh(app: app)
        } else if destination == .search {
            if !loaded.contains(.search), !submittedQuery.isEmpty { refresh(app: app) }
        } else if !loaded.contains(destination) {
            refresh(app: app)
        }
    }

    func queryEdited() {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) != submittedQuery else { return }
        if section == .search { cancel() }
        submittedQuery = ""
        searchList.tracks = []
        searchList.message = nil
        loaded.remove(.search)
    }

    func clearRecentSearches() {
        RecentSearchStore().clear()
        recentSearches = []
    }

    func submit(app: AppContainer?) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        runSearch(keyword: keyword, app: app)
    }

    private func runSearch(keyword: String, app: AppContainer?) {
        guard let manager = app?.sourceManager else { return }
        cancel()
        section = .search
        submittedQuery = keyword
        recentSearches = RecentSearchStore().record(keyword)
        start(app: app) { progress in
            try await manager.search(query: keyword, progress: progress)
        }
    }

    func recommendations(app: AppContainer?) {
        guard let manager = app?.sourceManager else { return }
        cancel()
        section = .recommendations
        rankingPool = []
        start(app: app) { progress in try await manager.discoverTracks(limit: 60, progress: progress) }
    }

    func switchBrowseSource(_ sourceID: SourceID, app: AppContainer?) {
        guard let manager = app?.sourceManager else { return }
        manager.selectActiveBrowseSource(sourceID)
        loaded.remove(.recommendations)
        loadedAt.removeValue(forKey: .recommendations)
        if section == .recommendations {
            recommendations(app: app)
        }
    }

    /// AI 翻唱行要展示的曲目：优先用清单里存的，其次反查结果，最后用身份拼一个占位（仍能播放成品）。
    /// 时长取成品本身，源给的时长可能为 0。
    func coverTrack(_ cover: VoiceManager.StoredCover) -> Track? {
        let render = cover.latest.render
        let base: Track
        if let known = cover.track ?? legacyCoverTracks[cover.trackKey] {
            base = known
        } else if let identity = TrackIdentity.fromStorageKey(cover.trackKey) {
            base = Track(sourceID: identity.sourceID, externalID: identity.externalID,
                         title: identity.externalID, artist: "", duration: render.duration)
        } else {
            return nil
        }
        guard base.duration <= 0 else { return base }
        return Track(id: base.id, sourceID: base.sourceID, externalID: base.externalID, title: base.title,
                     artist: base.artist, album: base.album, duration: render.duration, artwork: base.artwork,
                     lyrics: base.lyrics, persistentIdentifier: base.persistentIdentifier)
    }

    func resolveLegacyCoverTracks(app: AppContainer?) async {
        guard let app, let voice = app.voice else { return }
        let missing = voice.storedCovers.filter { $0.track == nil && legacyCoverTracks[$0.trackKey] == nil }
        guard !missing.isEmpty else { return }
        let stored = (try? await app.tracks.all()) ?? []
        for cover in missing {
            guard let identity = TrackIdentity.fromStorageKey(cover.trackKey),
                  let hit = app.offline.savedTrack(for: identity) ?? stored.first(where: { $0.identity == identity })
            else { continue }
            legacyCoverTracks[cover.trackKey] = hit
        }
    }

    func loadFavorites(app: AppContainer?) { loadLibrary(.favorites, app: app) }
    func loadRecent(app: AppContainer?) { loadLibrary(.recent, app: app) }
    func loadOffline(app: AppContainer?) {
        guard let app else { return }
        cancel()
        section = .offline
        start(app: app) { _ in await app.offline.refresh() }
    }

    private func loadLibrary(_ destination: Section, app: AppContainer?) {
        guard let app else { return }
        cancel()
        section = destination
        start(app: app) { progress in
            let keys = destination == .favorites
                ? await app.library.favorites() : await app.library.recent(limit: 100)
            let stored = try await app.tracks.all()
            try Task.checkCancellation()
            let live = app.playback.queueSnapshot.items.compactMap { app.playback.track(for: $0) }
            let raw = keys.map { key in
                app.offline.savedTrack(for: key)
                    ?? (live + stored).first { $0.identity == key }
                    ?? Track(sourceID: key.sourceID, externalID: key.externalID,
                             title: key.externalID, artist: "", duration: 0)
            }
            guard !raw.isEmpty else { return [] }
            guard app.settings.enableNetwork else {
                return raw.filter { app.offline.isOffline($0.identity) || app.sourceManager.isTrackVisible($0) }
            }
            let verified = try await app.sourceManager.verifyTracks(raw, progress: progress)
            // 校验可以并发完成，列表仍保持收藏／历史仓库的原始顺序；离线保存的曲目不受 30 天过期限制。
            return keys.compactMap { key in
                verified.first { $0.identity == key } ?? app.offline.savedTrack(for: key)
            }
        }
    }

    func refresh(app: AppContainer?) {
        switch section {
        case .recommendations: recommendations(app: app)
        case .search:
            let keyword = submittedQuery.isEmpty ? query.trimmingCharacters(in: .whitespacesAndNewlines) : submittedQuery
            guard !keyword.isEmpty else { return }
            runSearch(keyword: keyword, app: app)
        case .favorites: loadFavorites(app: app)
        case .recent: loadRecent(app: app)
        case .playlists: break
        case .offline: loadOffline(app: app)
        }
    }

    func showMore(app: AppContainer?) {
        let next = RankingPagination.nextCount(current: list.tracks.count, pool: rankingPool.count)
        list.tracks = Array(rankingPool.prefix(next))
        task?.cancel()
        let token = generation
        task = Task { await decorate(app: app, token: token) }
    }

    func refreshFavorites(app: AppContainer?) async {
        guard let app else { return }
        let keys = await app.library.favorites()
        guard !Task.isCancelled else { return }
        favorites = Set(keys)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if list.isLoading { loaded.remove(section) }
        list.cancel()
    }

    private func start(app: AppContainer?, operation: @escaping @MainActor (@escaping SongListState.Progress) async throws -> [Track]) {
        cancel()
        let token = generation
        let requestedSection = section
        let requestedList = list
        task = Task {
            guard generation == token, !Task.isCancelled else { return }
            let accepted = await requestedList.load(operation)
            guard accepted, generation == token, !Task.isCancelled else { return }
            loaded.insert(requestedSection)
            loadedAt[requestedSection] = Date()
            if requestedSection == .recommendations {
                rankingPool = requestedList.tracks
                requestedList.tracks = Array(rankingPool.prefix(RankingPagination.pageSize))
            }
            if requestedList.tracks.isEmpty {
                let isEmptyLibrary: Bool
                switch requestedSection {
                case .favorites: isEmptyLibrary = await app?.library.favorites().isEmpty == true
                case .recent: isEmptyLibrary = await app?.library.recent(limit: 1).isEmpty == true
                case .offline: isEmptyLibrary = app?.offline.tracks.isEmpty == true
                default: isEmptyLibrary = false
                }
                guard generation == token, !Task.isCancelled else { return }
                if isEmptyLibrary { requestedList.message = nil }
            }
            await decorate(app: app, token: token)
        }
    }

    private func decorate(app: AppContainer?, token: UUID) async {
        await refreshFavorites(app: app)
        guard let registry = app?.sourceRegistry else { return }
        for track in list.tracks where ArtworkStore.shared.image(forIdentity: track.identity) == nil {
            guard generation == token, !Task.isCancelled else { return }
            guard let reference = track.artwork,
                  let provider = registry.provider(for: track.sourceID),
                  let data = try? await provider.artwork(for: reference), !data.isEmpty else { continue }
            guard generation == token, !Task.isCancelled else { return }
            _ = ArtworkStore.shared.store(data, for: track.identity)
            artworkRevision &+= 1
        }
    }
}
