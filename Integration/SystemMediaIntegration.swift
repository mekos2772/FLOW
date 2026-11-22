import Foundation

/// 系统媒体集成：把统一播放状态投影到系统正在播放，并把系统命令送回播放内核。
///
/// 这里是唯一注册远程命令的地方，保证"一条媒体键只触发一次业务动作"。
@MainActor
final class SystemMediaIntegration {
    private let bridge: MediaPlayerNowPlayingBridge
    private let playback: PlaybackEngine
    private let library: any LibraryStoring
    private var task: Task<Void, Never>?
    private var lastRecordedIdentity: TrackIdentity?
    private var lastPublishedSecond: Int = -1
    private var lastPublishedTitle: String?
    /// 封面缓存：按曲目身份缓存，避免每秒重新下载同一张图。
    private var artworkCache: [TrackIdentity: Data] = [:]
    private var artworkTask: Task<Void, Never>?

    init(bridge: MediaPlayerNowPlayingBridge, playback: PlaybackEngine, library: any LibraryStoring) {
        self.bridge = bridge
        self.playback = playback
        self.library = library
    }

    func start() {
        bridge.onCommand = { [weak self] command in
            self?.handle(command)
        }
        bridge.configureCommandsIfNeeded()

        task = Task { [weak self] in
            guard let self else { return }
            for await _ in self.playback.stateUpdates() {
                self.publish()
            }
        }
    }

    func stop() {
        task?.cancel()
        artworkTask?.cancel()
        bridge.clear()
    }

    /// 立刻按当前状态重新推一次（不受"每秒一次"的节流限制）。
    ///
    /// 隐私遮罩变化时必须调用：推送原本只跟着播放状态走，
    /// 暂停着的时候打开隐私模式，控制中心会一直挂着真实歌名，直到下一次播放/暂停。
    func republish() {
        lastPublishedSecond = -1
        forcePublish = true
        publish()
    }

    private var forcePublish = false

    /// 在线曲目的封面是远端 URL：必须走源去取，控制中心才有图。
    ///
    /// 拉取失败不回退占位图——`MPNowPlayingInfoCenter` 自己会留空，
    /// 塞一张假封面反而误导。
    private func loadArtwork(for track: Track, identity: TrackIdentity) {
        guard isNetworkEnabled?() ?? true else { return }
        guard let reference = track.artwork else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            guard self.isNetworkEnabled?() ?? true else { return }
            guard let provider = self.sourceProvider?(track.sourceID) else { return }
            guard let data = try? await provider.artwork(for: reference) else { return }
            guard !Task.isCancelled, !data.isEmpty else { return }
            // 只留最近几张：这张字典以前只增不减，听得越久占得越多。
            if self.artworkCache.count >= 6 { self.artworkCache.removeAll() }
            self.artworkCache[identity] = data
            // 同一张图也要交给界面用的封面仓库：控制中心与播放器共用一次下载，
            // 否则会出现"控制中心有图、播放器里永远是灰音符"（实测就是这样）。
            ArtworkStore.shared.store(data, for: identity)
            // 拿到图后立刻再推一次，否则要等下一秒才显示。
            self.lastPublishedSecond = -1
            self.publish()
        }
    }

    /// 由容器注入：集成层不知道有哪些源。
    var sourceProvider: ((SourceID) -> (any PlaybackSourceProvider)?)?
    /// 动态联网状态：关闭联网后停止补下载远端封面。
    var isNetworkEnabled: (() -> Bool)?

    /// 测试用入口：看遮罩时会下发给系统什么。
    func publishedTrackForTesting(_ track: Track?) -> Track? { publishedTrack(track) }

    /// 由容器注入：当前是否处于隐私/会议遮罩状态。
    ///
    /// 隐私模式下 App 自己的界面会隐藏歌名，但**系统"正在播放"面板**
    /// （锁屏、控制中心、菜单栏媒体区）如果没有一起处理，会照常显示真实标题——
    /// 用户开隐私模式的理由恰恰是不想让别人看到在听什么。
    var isPrivacyMasked: (() -> Bool)?

    /// 交给系统的曲目显示信息（统一经由 `MorphPresentationModel.display` 解析）。
    private static func presentable(_ track: Track) -> Track? {
        let display = MorphPresentationModel.display(track)
        return Track(id: track.id, sourceID: track.sourceID, externalID: track.externalID,
                     title: display.title, artist: display.artist ?? "", album: track.album,
                     duration: track.duration, artwork: track.artwork, lyrics: track.lyrics,
                     persistentIdentifier: track.persistentIdentifier)
    }

    /// 遮罩时交给系统的曲目：标题占位、无艺人、无封面。
    private func publishedTrack(_ track: Track?) -> Track? {
        guard let track else { return nil }
        guard isPrivacyMasked?() ?? false else { return track }
        return Track(id: track.id,
                     sourceID: track.sourceID,
                     externalID: track.externalID,
                     title: "正在播放",
                     artist: "",
                     album: nil,
                     duration: track.duration,
                     artwork: nil,
                     lyrics: nil)
    }

    private func publish() {
        let state = playback.state
        let track = publishedTrack(playback.currentTrack.flatMap(Self.presentable))
        let position = playback.currentPosition
        let masked = isPrivacyMasked?() ?? false

        // 每秒最多推一次进度，避免把 MPNowPlayingInfoCenter 当高频刷新通道。
        let second = Int(position)
        // 曲目的元信息在同一秒内被补全（占位标题 → 真歌名）也要推：只比秒数会把它漏掉，
        // 控制中心整首歌都挂着占位标题。
        let titleChanged = track?.title != lastPublishedTitle
        if forcePublish || titleChanged || second != lastPublishedSecond || state != bridge.lastPublishedState {
            forcePublish = false
            lastPublishedSecond = second
            lastPublishedTitle = track?.title
            let identity = track.map { TrackIdentity(sourceID: $0.sourceID, externalID: $0.externalID) }
            if let identity, artworkCache[identity] == nil,
               let cached = ArtworkStore.shared.data(forIdentity: identity) {
                artworkCache[identity] = cached
            }
            bridge.update(state: state, track: track, position: position,
                          artwork: masked ? nil : identity.flatMap { artworkCache[$0] })
            // 遮罩时不下载封面：下载了也没用，还会把图留在内存里。
            if !masked, let identity, artworkCache[identity] == nil, let track {
                loadArtwork(for: track, identity: identity)
            }
        }

        if let track, state.isPlaying, lastRecordedIdentity != track.identity {
            lastRecordedIdentity = track.identity
            let identity = track.identity
            Task { [library] in await library.recordPlayed(identity, at: .now) }
        }
    }

    private func handle(_ command: RemoteCommand) {
        Task { [playback] in
            switch command {
            case .play:
                await playback.play()
            case .pause:
                await playback.pause()
            case .toggle:
                // 与界面上的播放键同一条语义（失败 = 重试，空闲 = 从队首开始）。
                await playback.togglePlayback()
            case .next:
                await playback.skip(.next)
            case .previous:
                await playback.skip(.previous)
            case let .seek(position):
                await playback.seek(to: position)
            }
        }
    }
}
