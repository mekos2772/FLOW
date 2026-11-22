import AppKit
import Foundation
import Observation

/// 次级内容（抽屉）。这些内容不属于主视觉，打开时压在歌词之上，不改变播放器形态。
enum AuxiliaryPanel: String, Sendable, Equatable, CaseIterable {
    case queue
    case library
    case settings
    case calibrate

    var title: String {
        switch self {
        case .queue: return String(localized: "队列")
        case .library: return String(localized: "资料库")
        case .settings: return String(localized: "快捷设置")
        case .calibrate: return String(localized: "歌词校准")
        }
    }

    var symbolName: String {
        switch self {
        case .queue: return "list.bullet"
        case .library: return "music.note.list"
        case .settings: return "slider.horizontal.3"
        case .calibrate: return "metronome"
        }
    }
}

/// 表现层状态投影。
///
/// 这是全应用**唯一**给界面读的播放器快照：主窗口、迷你条、胶囊、贴边、
/// 菜单栏都读这一个对象，因此不可能出现"两个界面进度不一样"的情况。
///
/// 它不是事实来源：事实在 `PlaybackEngine` / `LyricEngine`，
/// 这里只做投影与节流（界面不需要每个采样点都刷新）。
@MainActor
@Observable
final class MorphPresentationModel {
    // MARK: 形态
    /// 当前内容形态。
    var morphology: PlayerMorphology = .expanded
    /// 过渡中（用于视图决定要不要隐藏某些交互）。
    var isTransitioning = false
    /// 沉浸播放：完整形态的一种呈现方式（场景 + 歌词），不是第六种形态——
    /// 形态机完全不知道它，收缩到任何悬浮形态前由窗口控制器先退出沉浸。
    var isImmersive = false

    /// 动画进行中的固定排版尺寸。
    ///
    /// 窗口在动画里逐帧改尺寸，如果内容按**实时**尺寸排版，就会在高度穿过
    /// 108/160/224pt 这些断点时整棵子树换掉（标题→歌词→上一行）。
    /// 结果既有额外排版成本，也会看到"内容突然跳一下"。
    /// 动画期间钉在目标尺寸上，断点只在落地那一刻生效一次。
    var presentationSizeOverride: CGSize?
    /// 几何动画（迁移/变形）是否在进行，供视图降低逐帧开销。
    var isAnimatingGeometry = false
    /// 内容层的回弹缩放（1 = 常态，>1 = 过冲峰值）。
    ///
    /// 阻尼感主要在**这里**：窗口 frame 必须钳在安全区内（否则压到别人的窗口），
    /// 所以"弹一下"的观感由内容层承担，它没有边界约束。
    var contentBounceScale: Double = 1
    /// 悬浮形态是否接收鼠标（穿透）。
    var isInteractive = false
    /// 位置锁定（不允许拖动）。
    var isPositionLocked = false
    /// 形态锁定（不允许自动变形）。
    var isMorphologyLocked = false
    /// 打开的次级内容。
    var auxiliary: AuxiliaryPanel? = MorphPresentationModel.initialDrawer
    /// 打开资料库抽屉时是否直接落到「在线音乐」。
    /// 主页面右上角的在线入口用它把用户送到正确的一屏，而不是让用户再点一次。
    /// 悬浮形态当前是否压在别的窗口上（决定用透明底还是实底）。
    var floatingOverlapsWindow = false

    /// 当前窗口区域的壁纸是否明亮；复杂浅纹理下加厚底板帮助分离文字。
    var wallpaperIsBright = false
    /// 文件不可读、动态壁纸或窗口覆盖时用可读性底色，不把未知亮度当成暗背景。
    var backgroundSampleUnavailable = true
    var floatingTone: BackgroundTone?

    /// 悬浮底板是否需要"看得见"的实底。
    var floatingNeedsSolidBase: Bool {
        floatingOverlapsWindow || wallpaperIsBright || backgroundSampleUnavailable
    }

    var prefersOnlineSection = ProcessInfo.processInfo.environment["SLP_DEBUG_DRAWER"] == "online"

    /// 调试：`SLP_DEBUG_DRAWER=library|queue|settings` 启动即展开对应抽屉。
    static var initialDrawer: AuxiliaryPanel? {
        guard let raw = ProcessInfo.processInfo.environment["SLP_DEBUG_DRAWER"] else { return nil }
        if raw == "online" { return .library }
        return AuxiliaryPanel(rawValue: raw)
    }
    /// 歌词校准/偏移面板是否展开。
    var isCalibrating = false
    /// 浏览与播放相互独立：回首页不释放当前会话。
    var isBrowsing = false
    var showsHome: Bool { track == nil || isBrowsing }
    let home = OnlineHomeState()

    /// "去搜索"按钮想聚焦顶部搜索框时，把这个 tick+1；
    /// `PlayerSearchField` 监听它并把焦点交给自己。
    /// 不能直接把 `@FocusState` 挂在 model 上（那是视图层概念），
    /// 用一个递增计数器让搜索框自己感知"现在该要焦点"。
    var searchFocusRequest: Int = 0

    /// 让顶部搜索框成为第一响应者：调用方先切到浏览页（保证搜索框可见），
    /// 再 bump 一下计数器，搜索框收到变化就 focus。
    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    func showHome() {
        isBrowsing = true
        auxiliary = nil
    }

    func showPlayer() {
        home.cancel()
        isBrowsing = false
        auxiliary = nil
    }

    func browse(_ section: OnlineHomeState.Section, app: AppContainer?) {
        showHome()
        home.select(section, app: app)
    }

    // MARK: 播放
    var state: PlaybackState = .idle
    /// 当前会话是否为 FLOW Voice AI 翻唱产物。
    var isPlayingVoiceAI = false
    /// 最近一次播放错误。非 nil 时界面必须把它显示出来（规格 8.4：不许静默吞异常）。
    var error: PlaybackError?
    var track: Track?
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1
    var isMuted = false
    var repeatMode: RepeatMode = .off
    var isShuffling = false
    var queue = PlaybackQueue(items: [], currentID: nil)
    /// 队列里出现的曲目标题。由控制器从曲目仓库刷新，视图不各自去查库。
    var trackTitles: [Track.ID: String] = [:]
    /// 收藏集合的版本号。收藏抽屉用它做 `.task(id:)`，
    /// 否则点了星标之后抽屉还挂着旧快照（"点亮了却进不了列表"）。
    var libraryRevision: Int = 0

    // MARK: 歌词
    var lyric: LyricEngine.Snapshot = .empty
    var lyricState: LyricEngine.LoadState = .idle
    var lyricOffset: TimeInterval = 0
    var showLyricTranslation: Bool = true
    var showsLyricPicker: Bool = false

    // MARK: 视觉
    var ambient: ArtworkPalette.Color?
    var artwork: NSImage?
    var isMasked = false
    /// 当前曲目是否已收藏。由视图在切歌/收藏操作后刷新，避免各处各查一次库。
    var isFavorite = false
    /// 空间决策给出的建议形态，设置页与调试面板读它。
    var recommendedMorphology: PlayerMorphology = .capsule
    /// 最近一次形态决策的原因，用于日志与实测证据。
    var lastMorphologyNote: String = ""

    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { if case .buffering = state { return true }; return false }

    /// 0…1 播放进度。时长未知时返回 0，不猜。
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// 标题。`nil` 表示"没有曲目"，由视图给本地化文案——
    /// 模型里返回中文字面量的话，英文界面会永远显示中文（实测踩到）。
    var displayTitle: String? {
        guard !isMasked, let track else { return nil }
        let title = Self.display(track).title
        return title.isEmpty ? nil : title
    }

    var displayArtist: String? {
        guard !isMasked, let track else { return nil }
        return Self.display(track).artist
    }

    /// 任意曲目的展示用（歌名, 歌手），供队列、资料库、首页与系统组件共用。
    static func display(_ track: Track) -> (title: String, artist: String?) {
        (track.title, track.artist.isEmpty ? nil : track.artist)
    }

    var displayAlbum: String? {
        guard !isMasked else { return nil }
        return track?.album
    }

    /// 悬浮形态显示的那一行：出错时优先显示错误标题，否则当前歌词，再回落到歌名。
    var floatingLine: String {
        if isMasked { return String(localized: "正在播放") }
        if let error { return "\(error.title)" }
        if let text = lyric.current?.text, !text.isEmpty { return text }
        // 没歌词时**不能**把原始视频标题整条塞进悬浮行：胶囊只有 392pt 宽，
        // 30 多字的 B 站标题会折成两三行，而且正上方 18pt 已经写过同一句。
        if let title = displayTitle, !title.isEmpty { return title }
        return String(localized: "未在播放")
    }

    /// 紧凑形态是否该显示那行歌词。
    ///
    /// `floatingLine` 在没有歌词时会回落到歌名，而紧凑条**上方已经有歌名**：
    /// 结果同一句话在同一张卡片里写了两遍，一遍 18pt 一遍 30pt。
    /// 没有歌词就不显示，把空间还给封面与进度线。
    var showsFloatingLine: Bool {
        if isMasked { return true }
        if error != nil { return true }
        if let text = lyric.current?.text, !text.isEmpty { return true }
        return false
    }

    /// 歌词区专用的当前行：**只**取歌词，出错时不会把错误标题当成歌词显示。
    /// 悬浮形态仍用 `floatingLine`（那里需要有错就报错）。
    var currentLyricText: String {
        if isMasked { return String(localized: "正在播放") }
        if let text = lyric.current?.text, !text.isEmpty { return text }
        // 还没有唱到第一句：用**歌名**而不是完整视频标题。
        // B 站视频标题常是「【4K修复】周杰伦 - 夜曲 MV 2160P修复版 新专辑…即将发行」，
        // 34pt 大字下会折成两三行，把版面压得没有呼吸感。
        if let title = displayTitle, !title.isEmpty { return title }
        return String(localized: "未在播放")
    }

    /// 歌词区大字用的短标题：优先取解析出的歌名，没有就用原题但截断。
    static func compactTitle(_ raw: String) -> String {
        let parsed = LyricQueryNormalizer.parseTitle(raw)
        let candidate = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = candidate.isEmpty ? raw : candidate
        if text.count <= 18 { return text }
        return String(text.prefix(18)) + "…"
    }

    var nextLine: String? {
        guard !isMasked else { return nil }
        return lyric.next?.text
    }

    var previousLine: String? {
        guard !isMasked else { return nil }
        return lyric.previous?.text
    }

    /// 当前句的中文译文（仅当开关开启且当前句为真歌词时返回）。
    var currentLyricTranslation: String? {
        guard !isMasked, showLyricTranslation else { return nil }
        return lyric.current?.translationText(showingTranslation: true)
    }
}
