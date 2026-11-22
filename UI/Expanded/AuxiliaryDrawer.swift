import SwiftUI

/// 队列、设置与校准覆盖内容区，固定底部播放栏始终可操作。
struct AuxiliaryDrawer: View {
    @Bindable var model: MorphPresentationModel
    let panel: AuxiliaryPanel
    var onClose: () -> Void

    var body: some View {
        DrawerSurface(width: 336) {
            VStack(alignment: .leading, spacing: 0) {
                header
                FlowDivider()
                Group {
                    switch panel {
                    case .queue: QueueDrawerContent(model: model)
                    case .library: LibraryDrawerContent(model: model, onClose: onClose)
                    case .settings: QuickSettingsDrawerContent(model: model)
                    case .calibrate: CalibrateDrawerContent(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.s)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            flowIcon(systemName: panel.symbolName, size: 12)
                .foregroundStyle(FlowColor.secondaryText)
            Text(panel.title)
                .flowType(.homeTitle)
                .foregroundStyle(.primary)
            Spacer()
            FlowIconButton(systemName: "xmark", label: "收起", size: 34, symbolSize: 14, prominent: true, action: onClose)
        }
        .padding(.bottom, Spacing.xs)
    }
}

// MARK: - 队列

private struct QueueDrawerContent: View {
    @Bindable var model: MorphPresentationModel

    @Environment(\.app) private var app
    @State private var listState = SongListState()
    private var tracks: [Track.ID: Track] {
        Dictionary(listState.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var visibleItems: [(offset: Int, element: Track.ID)] {
        Array(model.queue.items.enumerated()).filter { tracks[$0.element] != nil }
    }
    /// "清空待播"的两段式确认状态。
    @State private var confirmingClear = false
    @State private var draggingIndex: Int?
    @State private var dropIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if listState.isLoading { ProgressView().controlSize(.small) }
            if let message = listState.message { Text(message).flowType(.homeSecondary) }
            if visibleItems.isEmpty {
                if !listState.isLoading && listState.message == nil { emptyState }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleItems, id: \.element) { index, id in
                            row(index: index, id: id)
                        }
                    }
                    .padding(.top, Spacing.xxs)
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
            HStack(spacing: Spacing.xs) {
                // 两段式确认：清空队列是破坏性操作，而且这次真的会动屏幕上那一列。
                FlowTextButton(title: confirmingClear ? "确认清空？" : "清空待播",
                               symbolName: confirmingClear ? "exclamationmark.triangle" : "trash", prominent: true) {
                    guard let playback = app?.playback else { return }
                    if confirmingClear {
                        confirmingClear = false
                        if playback.clearUpNext() { refresh() }
                    } else {
                        confirmingClear = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            confirmingClear = false
                        }
                    }
                }
                Spacer()
                FlowCaption(text: "\(visibleItems.count) 首")
            }
            .padding(.top, Spacing.xxs)
        }
        .task(id: model.queue) { await loadTracks() }
        .onDisappear { listState.cancel() }
        // 队列先建立、曲目随后才落库：标题映射一到就重读，否则第一版永远是"未知曲目"。
        .onChange(of: model.trackTitles) { _, _ in Task { await loadTracks() } }
    }

    private func row(index: Int, id: Track.ID) -> some View {
        let track = tracks[id]
        let isCurrent = model.queue.currentID == id
        return QueueRowView(
            isCurrent: isCurrent,
            isDropTarget: dropIndex == index && draggingIndex != nil && draggingIndex != index,
            // 队列行同样要走统一的展示解析，否则这里显示的是 B 站原始视频标题，
            // 和详情面板里的歌名对不上（同一首歌两个名字）。
            title: track.map { MorphPresentationModel.display($0).title } ?? "未知曲目",
            artist: track.map { MorphPresentationModel.display($0).artist ?? "" } ?? "",
            onPlay: { play(id) },
            onDragChanged: { translation in
                if draggingIndex == nil, abs(translation) > 6 { draggingIndex = index }
            },
            onHover: {
                if draggingIndex != nil { dropIndex = index }
            },
            onDragEnded: {
                defer { draggingIndex = nil; dropIndex = nil }
                guard let from = draggingIndex, let to = dropIndex, from != to else { return }
                app?.playback.moveQueueItem(from: from, to: to)
                refresh()
            },
            // 队列以前只能整体「清空待播」，删不掉单独一首。
            // 当前曲目不给删除入口——删了会让"当前曲目"凭空消失、音频还在响。
            onRemove: isCurrent ? nil : {
                app?.playback.removeQueueItem(at: index)
                refresh()
            }
        )
    }

    private var emptyState: some View {
        QueueEmptyState().padding(.top, Spacing.m)
    }

    private func play(_ id: Track.ID) {
        guard let track = tracks[id], let playback = app?.playback else { return }
        Task { await playback.load(track, autoplay: true) }
    }

    private func reloadQueue() {
        guard let playback = app?.playback else { return }
        model.queue = playback.queueSnapshot
        model.track = playback.currentTrack
        model.repeatMode = playback.queueSnapshot.repeatMode
        model.isShuffling = playback.queueSnapshot.isShuffling
    }

    private func refresh() {
        reloadQueue()
    }

    private func loadTracks() async {
        guard let app else { return }
        // 本地数据秒回：不清空旧列表，否则切歌/编辑队列时整列闪一帧空白。
        await listState.load(keepList: true) { progress in
            let all = (try? await app.tracks.all()) ?? []
            let queue = app.playback.queueSnapshot
            let raw = (queue.items + queue.nextUp + queue.later).compactMap { id in
                app.playback.track(for: id) ?? all.first { $0.id == id }
            }
            guard app.settings.enableNetwork else {
                return raw.filter { app.offline.isOffline($0.identity) || app.sourceManager.isTrackVisible($0) }
            }
            return try await app.sourceManager.verifyTracks(raw, progress: progress)
        }
    }
}

/// 独立组件便于在不启动异步加载的情况下验证空态排版。
struct QueueEmptyState: View {
    var body: some View {
        Text("队列还是空的").flowType(.homeTitle).foregroundStyle(FlowColor.secondaryText)
    }
}

/// 队列行：拖动排序用横向位移做阈值，悬停决定落点。
/// 队列里的一行。
///
/// 不设为 `private`：`ImageRenderer` 无法排版 `ScrollView` 里的内容
/// （离屏渲染时滚动容器里的子视图不参与布局），要验证这一行的排版
/// 只能把它单独渲染出来测。见 `DrawerRenderProbeTests`。
struct QueueRowView: View {
    var isCurrent: Bool
    var isDropTarget: Bool
    var title: String
    var artist: String
    var onPlay: () -> Void
    var onDragChanged: (CGFloat) -> Void
    var onHover: () -> Void
    var onDragEnded: () -> Void
    /// nil 表示这一行不给删除入口（当前曲目）。
    var onRemove: (() -> Void)?

    @State private var hovered = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: Spacing.xs) {
            flowIcon(systemName: isCurrent ? "waveform" : "line.3.horizontal", size: 10)
                .foregroundStyle(isCurrent ? Color.primary : FlowColor.tertiaryText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .flowType(.homeControl)
                    .foregroundStyle(isCurrent ? .primary : FlowColor.secondaryText)
                    .lineLimit(1)
                if !artist.isEmpty {
                    Text(artist)
                        .flowType(.homeSecondary)
                        .foregroundStyle(FlowColor.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let onRemove {
                // **常驻**，只在悬停时可见。
                //
                // 之前是 `if hovered { 按钮 }`：鼠标用户看得到，键盘和读屏用户永远够不到——
                // 悬停状态不产生，按钮就不存在。现在它始终在视图树里（视觉上 opacity 0），
                // 读屏能读、焦点能停；`allowsHitTesting` 只在悬停时接鼠标，避免误点。
                Button(action: onRemove) {
                    flowIcon(systemName: "xmark", size: 13)
                        .foregroundStyle(FlowColor.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 不能是 `opacity(0)`：实测全透明元素连 AX 都不出现（读屏依然够不到）。
                // 常驻低对比 + 悬停加深，兼顾"不杂乱"和"可达"。
                .opacity(hovered ? 1 : 0.75)
                .accessibilityLabel(Text("从队列移除"))
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isDropTarget ? FlowColor.hover : (hovered ? FlowColor.hover.opacity(0.5) : .clear))
        }
        .offset(x: dragOffset)
        .contentShape(Rectangle())
        .onHover { hovered = $0; if $0 { onHover() } }
        .onTapGesture(perform: onPlay)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    dragOffset = value.translation.width
                    onDragChanged(value.translation.height)
                }
                .onEnded { _ in
                    dragOffset = 0
                    onDragEnded()
                }
        )
        // 整行是**一个**无障碍元素。
        //
        // 只在容器上写 `.accessibilityLabel` 会把同一句话复印到每个子元素上：
        // 实测一行在 AX 树里出现三个「正在播放：英雄主义」（图标 + 标题 + 歌手），
        // 读屏会把这句话念三遍。`children: .ignore` 丢掉子元素，自己去描述整行。
        // `.contain` 而不是 `.ignore`：删除按钮必须是可独立聚焦的元素。
        // 用 `.ignore` 时整行是一个元素，`×` 与它一起被吞掉；
        // 试过 `.accessibilityActions` 补自定义动作——实测该元素连 `AXCustomActions`
        // 属性都没有，SwiftUI 在这里没生成。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isCurrent ? "正在播放：\(title)" : title))
        .accessibilityValue(Text(artist))
    }
}

// MARK: - 资料库

private struct LibraryDrawerContent: View {
    @Bindable var model: MorphPresentationModel
    var onClose: () -> Void

    @Environment(\.app) private var app
    @State private var listState = SongListState()
    private var tracks: [Track] { listState.tracks }
    @State private var favorites: [TrackIdentity] = []
    /// 最近播放。以前抽屉里只有「收藏」，想找刚听过的那首要绕去搜索。
    @State private var recent: [TrackIdentity] = []
    // 初始屏由 model 决定：从主页面右上角的「在线音乐」进来时直接落到在线。
    // 之前用 onAppear 里改 State，抽屉被重建一次后标志已被消费，结果又回到"全部"。
    @State private var section: Section
    @State private var status: String?
    @State private var onlineQuery = ""

    /// 抽屉只放"我的东西"。
    ///
    /// 在线搜索与推荐已经在主页面上了（空闲态就是在线首页），
    /// 抽屉再放一份只会让屏幕上出现两份一模一样的列表。
    private enum Section: String, CaseIterable, Identifiable {
        case favorites
        case recent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .favorites: return "收藏"
            case .recent: return "最近"
            }
        }
    }

    init(model: MorphPresentationModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _section = State(initialValue: .favorites)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            drawerTitle
            if listState.isLoading { ProgressView().controlSize(.small) }
            if let message = listState.message { Text(message).flowType(.homeSecondary) }
            list(sectionTracks)
            FlowDivider()
            footer
        }
        // 收藏变化与切曲都要重读：抽屉是"我的东西"的快照，
        // 用固定 `.task` 只会在首次上屏时读一次，之后星标就再也进不来。
        .task(id: model.track?.id) { await reload() }
        .onChange(of: model.libraryRevision) { _, _ in Task { await reload() } }
        .onDisappear { listState.cancel() }
    }

    // MARK: - 标题

    private var drawerTitle: some View {
        HStack(spacing: Spacing.xs) {
            // 两个分区用纯文字切换：抽屉很窄，分段控件会把标题挤没。
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    Text(item.title)
                        .flowType(.homeControl)
                        .foregroundStyle(section == item ? Color.primary : FlowColor.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let status {
                FlowCaption(verbatim: status)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - 列表

    private func list(_ items: [Track]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if items.isEmpty && !listState.isLoading && listState.message == nil {
                    emptyState
                }
                ForEach(items) { track in
                    FlowRow(isSelected: track.id == model.track?.id,
                            action: { play(track) }) {
                        VStack(alignment: .leading, spacing: 1) {
                            // 走统一的展示解析：直接用 `track.title` 会露出 B 站原始视频标题。
                            Text(MorphPresentationModel.display(track).title)
                                .flowType(.homeControl).lineLimit(1)
                            Text(MorphPresentationModel.display(track).artist ?? "未知艺术家")
                                .flowType(.homeSecondary)
                                .foregroundStyle(FlowColor.tertiaryText)
                                .lineLimit(1)
                        }
                    } trailing: {
                        Text(ExpandedPlayerView.format(track.duration))
                            .flowType(.homeSecondary)
                            .foregroundStyle(FlowColor.tertiaryText)
                    }
                    // 右菜单做"下一首播放 / 稍后播放"：不占行宽，也不打断扫读。
                    .contextMenu {
                        Button("立即播放") { play(track) }
                        Button("下一首播放") { enqueueNext(track) }
                        Button("稍后播放") { enqueueLater(track) }
                        Divider()
                        Button(isFavorite(track) ? "取消收藏" : "收藏") { toggleFavorite(track) }
                    }
                }
            }
            .padding(.top, Spacing.xxs)
        }
        .scrollIndicators(.never)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(section == .favorites ? "还没有收藏" : "还没有播放记录")
                .flowType(.homeSecondary)
                .foregroundStyle(FlowColor.secondaryText)
        }
        .padding(.vertical, Spacing.s)
    }

    // MARK: - 底部：音源状态

    // MARK: - 在线（B 站）

    /// 在线音乐：账号、搜索、推荐、收藏夹、歌单，全在这块里。
    ///
    /// 放在主窗口的资料库抽屉里，而不是再做一层窗口——
    /// 用户在主页面就能完成"找歌 → 播放"，不需要先绕到菜单栏。
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(model.track == nil ? FlowColor.tertiaryText : Color.primary)
                    .frame(width: 5, height: 5)
                Text(sourceName)
                    .flowType(.homeSecondary)
                    .foregroundStyle(FlowColor.secondaryText)
                Spacer(minLength: 0)
                if let status {
                    FlowCaption(verbatim: status)
                } else {
                    // 必须和上面那份列表同源：之前这里是 `tracks.count`（整个曲目库的条数），
                    // 而列表渲染的是 `sectionTracks`（收藏那一份），于是出现"列表 2 行、底部写 5 首"。
                    FlowCaption(text: "\(sectionTracks.count) 首")
                }
            }
        }
    }

    private var sourceName: String {
        guard let track = model.track else { return String(localized: "未在播放") }
        return app?.sourceManager.displayName(for: track.sourceID) ?? track.sourceID.rawValue
    }

    // MARK: - 数据

    /// 收藏列表：优先用曲目库里能对上的条目；
    /// 在线曲目可能还没进曲目库（只播过没落库），这时用最近播放里记下的那一份。
    private var sectionTracks: [Track] {
        var byIdentity: [TrackIdentity: Track] = [:]
        for track in tracks where byIdentity[track.identity] == nil { byIdentity[track.identity] = track }
        let keys = section == .favorites ? favorites : recent
        return keys.compactMap { byIdentity[$0] }.filter { app?.sourceManager.isTrackVisible($0) ?? true }
    }

    private func isFavorite(_ track: Track) -> Bool {
        favorites.contains(track.identity)
    }

    private func play(_ track: Track) {
        Task { await app?.playback.load(track, autoplay: true) }
    }

    private func enqueueNext(_ track: Track) {
        app?.playback.enqueueNext(track)
        app?.morph.refreshQueue()
        status = "下一首：\(MorphPresentationModel.display(track).title)"
    }

    private func enqueueLater(_ track: Track) {
        app?.playback.enqueueLater(track)
        app?.morph.refreshQueue()
        status = "稍后：\(MorphPresentationModel.display(track).title)"
    }

    private func toggleFavorite(_ track: Track) {
        Task {
            let result = await app?.toggleFavorite(track)
            if track.identity == model.track?.identity { model.isFavorite = result ?? false }
            model.libraryRevision &+= 1
            await reload()
        }
    }

    private func reload() async {
        guard let app else { return }
        await listState.load { progress in
            let stored = (try? await app.tracks.all()) ?? []
            let favoriteKeys = await app.library.favorites()
            let recentKeys = await app.library.recent(limit: 30)
            try Task.checkCancellation()
            favorites = favoriteKeys
            recent = recentKeys
            let keys = Array(Set(favoriteKeys + recentKeys))
            let live = app.playback.queueSnapshot.items.compactMap { app.playback.track(for: $0) }
            let raw = keys.map { key in
                (stored + live).first { $0.identity == key }
                    ?? Track(sourceID: key.sourceID, externalID: key.externalID,
                             title: key.externalID, artist: "", duration: 0)
            }
            guard app.settings.enableNetwork else {
                return raw.filter { app.offline.isOffline($0.identity) || app.sourceManager.isTrackVisible($0) }
            }
            return try await app.sourceManager.verifyTracks(raw, progress: progress)
        }
    }

}

// MARK: - 快捷设置

private struct QuickSettingsDrawerContent: View {
    @Bindable var model: MorphPresentationModel

    @Environment(\.app) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                group("形态") {
                    toggleRow("锁定当前形态", isOn: app?.morph.isMorphologyLocked ?? false) {
                        app?.morph.toggleMorphologyLock()
                        refresh()
                    }
                    toggleRow("自动避让前台窗口", isOn: app?.appearance.autoAvoidEnabled ?? true) {
                        app?.morph.setAutoAvoid(!(app?.appearance.autoAvoidEnabled ?? true))
                        refresh()
                    }
                    if (app?.appearance.autoAvoidEnabled ?? true),
                       let floating = app?.floatingLyrics,
                       !floating.accessibilityPermission.allowsWindowInspection {
                        HStack(spacing: 6) {
                            Text("未授辅助功能权限，避让未生效")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                            Spacer()
                            FlowTextButton(title: "去授权", symbolName: "hand.raised") {
                                floating.requestAccessibilityPermission()
                            }
                        }
                    }
                    toggleRow("鼠标穿透", isOn: !model.isInteractive) {
                        app?.morph.toggleInteractive()
                        refresh()
                    }
                    toggleRow("锁定位置", isOn: model.isPositionLocked) {
                        app?.morph.togglePositionLock()
                        refresh()
                    }
                    toggleRow("隐匿时保留边缘把手",
                              isOn: app?.morph.dormantStyle == .edgeHandle) {
                        let next: DormantStyle = app?.morph.dormantStyle == .edgeHandle
                            ? .hideCompletely : .edgeHandle
                        app?.morph.setDormantStyle(next)
                        refresh()
                    }
                }

                group("歌词") {
                    sliderRow("字号", value: app?.appearance.lyricFontSize ?? 15, range: 11...30,
                              display: { "\(Int($0.rounded())) pt" }) {
                        app?.appearance.setLyricFontSize($0)
                        app?.morph.applyLyricFontSize($0)
                    }
                    sliderRow("行距", value: app?.appearance.lyricLineSpacing ?? 8, range: 0...24,
                              display: { "\(Int($0.rounded())) pt" }) {
                        app?.appearance.setLyricLineSpacing($0)
                        app?.morph.applyLyricLineSpacing($0)
                    }
                    sliderRow("悬浮不透明度", value: app?.appearance.floatingOpacity ?? 0.95, range: 0.3...1,
                              display: { "\(Int(($0 * 100).rounded()))%" }) {
                        app?.appearance.setFloatingOpacity($0)
                        app?.morph.applyFloatingOpacity($0)
                    }
                }

                group("窗口与快捷入口") {
                    FlowTextButton(title: "管理音源与预设…", symbolName: "antenna.radiowaves.left.and.right", prominent: true) {
                        SettingsNavigation.request(SettingsNavigation.onlineMusicPane)
                        openSettings()
                    }
                    FlowTextButton(title: "AI 音色与底座…", symbolName: "person.wave.2", prominent: true) {
                        SettingsNavigation.request(SettingsNavigation.voicePane)
                        openSettings()
                    }
                    FlowTextButton(title: "打开完整设置…", symbolName: "gearshape", prominent: true) {
                        openSettings()
                    }
                }

                Spacer(minLength: Spacing.s)
            }
            .padding(.top, Spacing.xs)
        }
        .scrollIndicators(.never)
    }

    private func refresh() {
        model.isInteractive = app?.morph.isInteractive ?? false
        model.isPositionLocked = app?.morph.isPositionLocked ?? false
        model.isMorphologyLocked = app?.morph.isMorphologyLocked ?? false
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).flowType(.homeControl)
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).flowType(.homeControl).foregroundStyle(FlowColor.secondaryText)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // `labelsHidden()` 只影响视觉，无障碍标签得显式补上：
                // 之前抽屉里 5 个开关在 AX 树里全是无名的 `AXCheckBox`，
                // 读屏只能念"复选框"，读不出是哪一个。
                .accessibilityLabel(Text(title))
        }
    }

    private func sliderRow(_ title: String,
                           value: Double,
                           range: ClosedRange<Double>,
                           display: (Double) -> String,
                           onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).flowType(.homeControl).foregroundStyle(FlowColor.secondaryText)
                Spacer()
                // 以前一律 `%.2f`：字号显示 `15.00`、不透明度显示 `0.95`，
                // 是调试输出而不是界面读数。改成"整数 + 单位"或百分比。
                Text(display(value))
                    .flowType(.homeSecondary)
                    .foregroundStyle(FlowColor.tertiaryText)
            }
            // 同 SettingsView：滑块回调由 AppKit 在主线程触发。
            Slider(value: Binding(get: { value },
                                  set: { newValue in
                                      MainActor.assumeIsolated { onChange(newValue) }
                                  }), in: range)
                .controlSize(.mini)
                .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - 歌词校准

private struct CalibrateDrawerContent: View {
    @Bindable var model: MorphPresentationModel

    @Environment(\.app) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("当前偏移 \(offsetText)")
                .flowType(.trackTitleCompact)
                .foregroundStyle(.primary)
            FlowCaption(text: "每首歌单独记忆。方向键微调，回车保存，Esc 取消。")

            HStack(spacing: Spacing.xs) {
                stepButton("-200", delta: -0.2)
                stepButton("-50", delta: -0.05)
                stepButton("+50", delta: 0.05)
                stepButton("+200", delta: 0.2)
            }

            HStack(spacing: Spacing.xs) {
                FlowTextButton(title: "保存", symbolName: "checkmark", prominent: true) {
                    Task {
                        await app?.lyricEngine.commitOffset()
                        refresh()
                    }
                }
                FlowTextButton(title: "重置", symbolName: "arrow.counterclockwise", prominent: true) {
                    Task {
                        await app?.lyricEngine.resetOffset()
                        refresh()
                    }
                }
            }

            Spacer()
            Text(model.floatingLine)
                .flowType(FlowType.lyricCurrent(size: 22))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.bottom, Spacing.s)
        }
        .padding(.top, Spacing.xs)
        .onAppear { refresh() }
        .background {
            // 方向键微调：悬浮面板不是 key window 时也能用，所以这里挂键盘监听。
            KeyboardOffsetMonitor(
                onAdjust: { delta in
                    app?.lyricEngine.adjustOffset(by: delta)
                    refresh()
                },
                onCommit: {
                    Task { await app?.lyricEngine.commitOffset() }
                },
                onCancel: {
                    Task {
                        await app?.lyricEngine.revertOffset()
                        refresh()
                    }
                }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var offsetText: String { DurationText.offset(model.lyricOffset) }

    private func stepButton(_ title: String, delta: TimeInterval) -> some View {
        Button(title) {
            app?.lyricEngine.adjustOffset(by: delta)
            refresh()
        }
        .buttonStyle(.plain)
        .flowType(.homeSecondary)
        .foregroundStyle(FlowColor.secondaryText)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(FlowColor.hover)
        }
    }

    private func refresh() {
        model.lyricOffset = app?.lyricEngine.userOffset ?? 0
    }
}
