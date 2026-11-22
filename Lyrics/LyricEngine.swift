import Foundation
import Observation

/// 歌词引擎。整个应用唯一的歌词时间轴来源。
///
/// 三条硬约束：
/// 1. 位置只由播放时钟换算，引擎自己不计时、不持有 Timer；
/// 2. 切歌时用 token 作废旧加载，避免"上一首的歌词晚到覆盖了新歌"；
/// 3. 用户偏移与 LRC 自带 offset 分开保存：前者可重置，后者属于文档本身。
@MainActor
@Observable
final class LyricEngine {
    enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case empty          // 没有歌词
        case unsynced       // 有文本但没有时间轴
        case failed
    }

    struct Snapshot: Equatable, Sendable {
        var current: LyricLine?
        var next: LyricLine?
        var previous: LyricLine?
        var progressInLine: Double
        /// 当前歌词时间（已含用户偏移与文档偏移）。逐字填充用它算，而不是用整行进度。
        var time: TimeInterval = 0
        var index: Int?
        var totalLines: Int
        var unsyncedLines: [String]

        static let empty = Snapshot(current: nil, next: nil, previous: nil,
                                    progressInLine: 0, time: 0, index: nil,
                                    totalLines: 0, unsyncedLines: [])
    }

    private(set) var document: LyricsDocument?
    private(set) var state: LoadState = .idle
    private(set) var userOffset: TimeInterval = 0
    private(set) var currentIdentity: TrackIdentity?

    private var timeline = LyricTimeline(lines: [])
    private var loadToken = UUID()
    private let loader: any LyricsLoading
    private let offsets: any LyricsOffsetStoring
    private var hasUnsavedOffset = false
    /// 文档更新（切歌载入或手动换词/恢复）通知监听，确保暂停态也零延迟同步 UI 快照。
    @ObservationIgnored var onDocumentChanged: (@MainActor () -> Void)?

    init(loader: any LyricsLoading, offsets: any LyricsOffsetStoring) {
        self.loader = loader
        self.offsets = offsets
    }

    /// 当前歌词实际使用的时间基准：播放时间 + 用户偏移 + 文档自带偏移。
    func effectiveTime(for playbackTime: TimeInterval) -> TimeInterval {
        max(0, playbackTime + userOffset + (document?.embeddedOffset ?? 0))
    }

    func snapshot(at playbackTime: TimeInterval) -> Snapshot {
        guard let document, document.isSynced, !timeline.isEmpty else {
            return Snapshot(current: nil, next: nil, previous: nil, progressInLine: 0,
                            time: effectiveTime(for: playbackTime),
                            index: nil, totalLines: document?.lines.count ?? 0,
                            unsyncedLines: document?.isSynced == false ? document?.lines.map(\.text) ?? [] : [])
        }
        let time = effectiveTime(for: playbackTime)
        return Snapshot(
            current: timeline.line(at: time),
            next: timeline.nextLine(after: time),
            previous: timeline.previousLine(before: time),
            progressInLine: timeline.progress(at: time),
            time: time,
            index: timeline.index(at: time),
            totalLines: timeline.lines.count,
            unsyncedLines: []
        )
    }

    // MARK: - 加载

    func load(track: Track?) async {
        let token = UUID()
        loadToken = token

        guard let track else {
            document = nil
            timeline = LyricTimeline(lines: [])
            state = .idle
            currentIdentity = nil
            userOffset = 0
            return
        }

        // 换歌的那一刻就把上一首的歌词撤掉。
        //
        // 之前只改了 `state`，文档和时间轴要等新歌词回来才换——而取歌词要走网络，
        // 这几秒里屏幕上（完整播放器、胶囊、迷你条、菜单栏、小组件）滚动的是**上一首**
        // 的歌词，对着的却是新歌的进度。同一首歌重新加载时不清，避免闪一下空白。
        if currentIdentity != track.identity {
            document = nil
            timeline = LyricTimeline(lines: [])
            userOffset = 0
        }
        currentIdentity = track.identity
        state = .loading
        let savedOffset = await offsets.offset(for: track.identity)
        // 读偏移有一次挂起：期间又换了歌的话，这次加载已经作废。
        guard loadToken == token else { return }
        userOffset = savedOffset
        hasUnsavedOffset = false

        let loaded = await loader.loadLyrics(for: track)
        // 旧加载晚到的结果直接丢弃，不允许覆盖当前曲目。
        guard loadToken == token else { return }

        guard let loaded else {
            document = nil
            timeline = LyricTimeline(lines: [])
            state = .empty
            onDocumentChanged?()
            return
        }

        let normalized = TextNormalizer.simplified(document: loaded)
        document = normalized
        timeline = LyricTimeline(lines: normalized.lines)
        state = normalized.isSynced ? .loaded : .unsynced
        onDocumentChanged?()
    }

    /// 手动指定歌词文档（用户换了一版歌词）。
    ///
    /// 不走 loader：这一份是用户从候选里**挑出来的**，再去请求只会拿回默认那一条。
    func overrideDocument(_ newDocument: LyricsDocument) {
        // 作废还在路上的自动加载：它晚到的话会把用户刚挑的这一版盖回去。
        loadToken = UUID()
        let normalized = TextNormalizer.simplified(document: newDocument)
        document = normalized
        timeline = LyricTimeline(lines: normalized.lines)
        state = normalized.isSynced ? .loaded : .unsynced
        currentIdentity = normalized.trackIdentity
        onDocumentChanged?()
    }

    // MARK: - 偏移

    /// 测试与调试用：直接设定偏移但不标记为"已保存"。
    func adminSetOffsetForTest(_ value: TimeInterval) {
        userOffset = (value * 1000).rounded() / 1000
    }

    func setOffset(_ value: TimeInterval) {
        userOffset = (value * 1000).rounded() / 1000   // 毫秒精度
        hasUnsavedOffset = true
    }

    func adjustOffset(by delta: TimeInterval) {
        setOffset(userOffset + delta)
    }

    /// 回车保存。
    func commitOffset() async {
        guard let identity = currentIdentity else { return }
        guard hasUnsavedOffset || userOffset != 0 else { return }
        hasUnsavedOffset = false
        await offsets.save(userOffset, for: identity)
    }

    /// Esc 取消：回到上次保存的值。
    func revertOffset() async {
        guard let identity = currentIdentity else { return }
        userOffset = await offsets.offset(for: identity)
        hasUnsavedOffset = false
    }

    func resetOffset() async {
        guard let identity = currentIdentity else { return }
        userOffset = 0
        hasUnsavedOffset = false
        await offsets.remove(for: identity)
    }
}
