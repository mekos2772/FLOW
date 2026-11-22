import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 浏览内容区；搜索、侧栏与底部播放栏由主窗口统一承接。
struct OnlineHomeView: View {
    @Bindable var model: MorphPresentationModel
    @Environment(\.app) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var showsGitHubSearchSheet = false
    @State private var showsLocalPicker = false
    @State private var isEnablingPresetID: String?
    @State private var onboardingHint: String?
    @State private var onboardingNeedsNetworkPreset: ExternalAPIPreset?
    @State private var confirmsClearAICovers = false
    @State private var confirmsClearOffline = false
    private var home: OnlineHomeState { model.home }

    private var showsAICovers: Bool { home.section == .offline && home.offlineKind == .aiCovers }

    /// 有 AI 成品才出现切换，没用过 AI 翻唱的人看到的离线页保持原样。
    private var showsOfflineKindSwitch: Bool {
        guard home.section == .offline, let voice = app?.voice else { return false }
        return !voice.storedCovers.isEmpty || home.offlineKind == .aiCovers
    }

    private var aiCoverRows: [(cover: VoiceManager.StoredCover, track: Track)] {
        (app?.voice?.storedCovers ?? []).compactMap { cover in
            home.coverTrack(cover).map { (cover, $0) }
        }
    }

    var body: some View {
        Group {
            if home.section == .playlists {
                PlaylistContent(onPlay: { model.showPlayer(); app?.noteAuxiliaryActivity(false) })
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Text(home.title).flowType(.pageTitle)
                        if home.section == .recommendations,
                           let manager = app?.sourceManager,
                           !manager.browsableSources.isEmpty {
                            sourceSelectorMenu(manager: manager)
                        } else if home.section == .search,
                                  let manager = app?.sourceManager,
                                  manager.hasAnyConfiguredSource {
                            FlowCaption(text: manager.aggregateSearchEnabled
                                        ? "已聚合全部启用源"
                                        : "当前源：\(manager.activeBrowseSource?.descriptor.displayName ?? "-")")
                        } else if showsOfflineKindSwitch {
                            FlowSegmentedSwitch(
                                items: [
                                    .init(value: OnlineHomeState.OfflineKind.songs,
                                          title: String(localized: "离线歌曲"), identifier: "offline.kind.songs"),
                                    .init(value: .aiCovers,
                                          title: String(localized: "AI 翻唱"), identifier: "offline.kind.ai"),
                                ],
                                selection: home.offlineKind
                            ) { home.offlineKind = $0 }
                        }
                        Spacer()
                        if home.section == .favorites, !home.list.tracks.isEmpty {
                            FlowTextButton(title: "全部离线", symbolName: "arrow.down.circle", prominent: true) {
                                Task { _ = await app?.downloadOffline(home.list.tracks) }
                            }
                        } else if showsAICovers {
                            if let first = aiCoverRows.first {
                                FlowTextButton(title: "播放全部", symbolName: "play.fill", prominent: true) {
                                    playAICover(first.cover)
                                }
                                FlowTextButton(title: "清空 AI 翻唱", symbolName: "trash") {
                                    confirmsClearAICovers = true
                                }
                            }
                        } else if home.section == .offline, !home.list.tracks.isEmpty {
                            FlowTextButton(title: "播放全部", symbolName: "play.fill", prominent: true) {
                                play(home.list.tracks[0])
                            }
                            FlowTextButton(title: "清空离线", symbolName: "trash") {
                                confirmsClearOffline = true
                            }
                        }
                        if showsAICovers {
                            FlowIconButton(systemName: "arrow.clockwise", label: "刷新",
                                           size: 36, symbolSize: 15, prominent: true) { refreshAICovers() }
                        } else if home.list.isLoading {
                            ProgressView().controlSize(.small).accessibilityLabel(Text("正在加载"))
                        } else {
                            FlowIconButton(systemName: "arrow.clockwise", label: "刷新",
                                           size: 36, symbolSize: 15, prominent: true) { home.refresh(app: app) }
                        }
                    }
                    if showsAICovers {
                        aiCoverContent
                    } else {
                        if let status = app?.offline.statusMessage,
                           home.section == .favorites || home.section == .offline {
                            FlowCaption(verbatim: status)
                        }
                        if home.list.tracks.isEmpty { emptyState }
                        else { songList }
                    }
                }
            }
        }
        .confirmationDialog("删除全部离线歌曲？", isPresented: $confirmsClearOffline) {
            Button("全部删除", role: .destructive) {
                Task { await app?.offline.clearAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(home.list.tracks.count) 首离线保存的歌曲，之后需要联网重新下载。")
        }
        .confirmationDialog("清空全部 AI 翻唱？", isPresented: $confirmsClearAICovers) {
            Button("清空", role: .destructive) {
                _ = app?.voice?.deleteStoredCovers(app?.voice?.storedCovers ?? [])
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("生成的 AI 版音频会从这台 Mac 上删除，之后可以在播放器里重新生成。")
        }
        .task(id: app?.voice?.storedCovers.map(\.id) ?? []) {
            await home.resolveLegacyCoverTracks(app: app)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.libraryRevision) { _, _ in
            if home.section == .favorites { home.loadFavorites(app: app) }
            else { Task { await home.refreshFavorites(app: app) } }
        }
        .onChange(of: app?.offline.revision ?? 0) { _, _ in
            if home.section == .offline { home.loadOffline(app: app) }
        }
        .onDisappear { home.cancel() }
        .task(id: app?.sourceManager.revision ?? 0) { home.activate(app: app) }
        .sheet(isPresented: $showsGitHubSearchSheet) {
            GitHubSourceSearchSheet { _, originName in
                onboardingHint = String(localized: "已导入：\(originName)")
                home.refresh(app: app)
            }
        }
        .fileImporter(
            isPresented: $showsLocalPicker,
            allowedContentTypes: [.folder, .audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .failure(let err):
                onboardingHint = err.localizedDescription
            case .success(let urls):
                guard !urls.isEmpty, let app else { return }
                Task { @MainActor in
                    let tracks = await app.sourceManager.openLocalAudioURLs(urls)
                    if let first = tracks.first {
                        onboardingHint = String(localized: "已添加本地曲目，共 \(tracks.count) 首")
                        _ = first
                    } else {
                        onboardingHint = String(localized: "已添加本地音乐目录")
                    }
                    home.refresh(app: app)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceSelectorMenu(manager: SourceManager) -> some View {
        let activeName = manager.activeBrowseSource?.descriptor.displayName ?? String(localized: "选择音源")
        Menu {
            ForEach(manager.browsableSources) { source in
                Button {
                    home.switchBrowseSource(source.id, app: app)
                } label: {
                    if manager.activeBrowseSource?.id == source.id {
                        Label(source.descriptor.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: source.descriptor.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                flowIcon(systemName: "antenna.radiowaves.left.and.right", size: 12)
                Text(verbatim: activeName).flowType(.homeControl)
                flowIcon(systemName: "chevron.down", size: 10)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(FlowColor.hover, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("home.sourceSelector")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if home.list.isLoading {
                Spacer()
            } else if home.section == .recommendations,
                      let manager = app?.sourceManager,
                      !manager.hasAnyConfiguredSource {
                flowIcon(systemName: "tray.and.arrow.down", size: 34)
                    .foregroundStyle(FlowColor.secondaryText)
                Text("尚未配置音源")
                    .flowType(.homeTitle)
                    .foregroundStyle(.primary)
                Text("选择本地音乐或启用开放曲库，也可以前往设置自动获取外部音源，或直接把音频 / 歌词 / 音源拖进窗口。")
                    .flowType(.body)
                    .foregroundStyle(FlowColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 24)

                HStack(spacing: 10) {
                    FlowTextButton(title: "添加本地音乐…", symbolName: "folder.badge.plus", prominent: true) {
                        onboardingHint = nil
                        onboardingNeedsNetworkPreset = nil
                        showsLocalPicker = true
                    }

                    if let audius = ExternalAPIPresetCatalog.presets.first(where: { $0.id == "audius-open" }) {
                        FlowTextButton(
                            title: isEnablingPresetID == audius.id ? "启用中…" : "启用开放音乐",
                            symbolName: "waveform",
                            prominent: true
                        ) {
                            enableQuickPreset(audius)
                        }
                        .disabled(isEnablingPresetID != nil)
                    }
                }
                .padding(.top, 4)

                HStack(spacing: 10) {
                    FlowTextButton(title: "从 GitHub 搜索音源…", symbolName: "magnifyingglass") {
                        showsGitHubSearchSheet = true
                    }
                    FlowTextButton(title: "前往设置导入音源", symbolName: "slider.horizontal.3") {
                        SettingsNavigation.request(SettingsNavigation.onlineMusicPane)
                        openSettings()
                    }
                }

                if let onboardingHint {
                    VStack(spacing: 6) {
                        FlowCaption(verbatim: onboardingHint)
                            .multilineTextAlignment(.center)
                        if let pendingPreset = onboardingNeedsNetworkPreset {
                            FlowTextButton(title: "允许联网并启用", symbolName: "network", prominent: true) {
                                Task {
                                    await app?.setEnableNetwork(true)
                                    onboardingNeedsNetworkPreset = nil
                                    enableQuickPreset(pendingPreset)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                let symbol: String = switch home.section {
                case .favorites: "star"
                case .recent: "clock"
                case .offline: "arrow.down.circle"
                default: "music.note"
                }
                flowIcon(systemName: symbol, size: 32)
                    .foregroundStyle(FlowColor.secondaryText)
                // 加载失败/真空集合都收进 friendlyEmpty：技术性错误不再铺成页面主标题。
                if let feedback = home.friendlyEmpty {
                    Text(feedback).flowType(.homeTitle)
                        .foregroundStyle(FlowColor.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                if let app, !app.settings.enableNetwork,
                   home.section == .recommendations || home.section == .search {
                    FlowTextButton(title: "允许联网并重试", symbolName: "network", prominent: true) {
                        Task {
                            await app.setEnableNetwork(true)
                            home.refresh(app: app)
                        }
                    }
                    .padding(.top, 4)
                } else if home.section == .search,
                          let manager = app?.sourceManager,
                          !manager.aggregateSearchEnabled,
                          manager.browsableSources.filter(\.descriptor.supportsSearch).count > 1 {
                    FlowTextButton(title: "在全部启用音源中重搜", symbolName: "rectangle.stack", prominent: true) {
                        manager.aggregateSearchEnabled = true
                        home.refresh(app: app)
                    }
                    .padding(.top, 4)
                }
                // 接口失败时给双引导：重试 + 去搜索。不再让用户盯着错误文案发呆。
                if home.showsLoadFailedHint {
                    HStack(spacing: 12) {
                        FlowTextButton(title: "重试", symbolName: "arrow.clockwise", prominent: true) {
                            home.refresh(app: app)
                        }
                        FlowTextButton(title: "去搜索", symbolName: "magnifyingglass") {
                            // 去搜索 = 让用户直接开始打字：把焦点送进顶部搜索框，
                            // 而不是切到某个 section（搜索 section 只在有结果时出现）。
                            model.requestSearchFocus()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("home.empty")
    }

    private var songList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(home.list.tracks) { track in
                    let isOffline = app?.offline.isOffline(track.identity) ?? false
                    let isDownloading = app?.offline.isDownloading(track.identity) ?? false
                    let badge = (app?.sourceManager.browsableSources.count ?? 0) > 1
                        ? app?.sourceManager.displayName(for: track.sourceID)
                        : nil
                    SongRow(track: track, isCurrent: model.track?.identity == track.identity,
                            isFavorite: home.favorites.contains(track.identity),
                            isOffline: isOffline,
                            isDownloadingOffline: isDownloading,
                            sourceBadge: badge,
                            onFavorite: { toggleFavorite(track) },
                            onToggleOffline: home.section == .offline ? nil : { toggleOffline(track, isOffline: isOffline) },
                            onRemove: home.section == .offline ? { removeOffline(track) } : nil,
                            removeLabel: "移除离线",
                            onPlay: { play(track) })
                        // 不要在这里拼 artworkRevision：decorate 每落一张封面 revision+1，
                        // 整列 60 行全部重建、行内 hover/状态丢失（首张加载期可发生十几次）。
                        // SongRow 自己从 ArtworkStore 取图，身份变化时重读即可。
                        .id(track.identity)
                        .contextMenu {
                            Button("播放") { play(track) }
                            Button("下一首播放") { app?.playback.enqueueNext(track) }
                            Button("加入播放队列") { app?.playback.enqueueLater(track) }
                            Divider()
                            Button(home.favorites.contains(track.identity) ? "取消收藏" : "收藏") { toggleFavorite(track) }
                            Button(isOffline ? "移除离线" : "离线保存") { toggleOffline(track, isOffline: isOffline) }
                        }
                }
                if home.canShowMore {
                    Button("显示更多") { home.showMore(app: app) }
                        .buttonStyle(.plain).flowType(.homeControl)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                if let feedback = home.feedback {
                    Text(feedback).flowType(.homeSecondary)
                        .foregroundStyle(FlowColor.secondaryText).padding(.vertical, 12)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private var aiCoverContent: some View {
        let rows = aiCoverRows
        if rows.isEmpty {
            VStack(spacing: 12) {
                flowIcon(systemName: "person.wave.2", size: 32)
                    .foregroundStyle(FlowColor.secondaryText)
                Text("还没有 AI 翻唱").flowType(.homeTitle)
                    .foregroundStyle(FlowColor.secondaryText)
                Text("在播放器的「音色」里生成后，会出现在这里")
                    .flowType(.body)
                    .foregroundStyle(FlowColor.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("offline.ai.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.cover.id) { row in
                        SongRow(track: row.track,
                                isCurrent: isPlayingAICover(row.cover),
                                sourceBadge: app?.voice?.packName(for: row.cover),
                                onRemove: { deleteAICover(row.cover) },
                                removeLabel: "删除 AI 翻唱",
                                removeSymbol: "trash",
                                onPlay: { playAICover(row.cover) })
                            .contextMenu {
                                Button("播放") { playAICover(row.cover) }
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([row.cover.latest.render.fileURL])
                                }
                                Divider()
                                Button("删除 AI 翻唱", role: .destructive) { deleteAICover(row.cover) }
                            }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private func isPlayingAICover(_ cover: VoiceManager.StoredCover) -> Bool {
        guard model.isPlayingVoiceAI,
              let current = model.track,
              TrackIdentity.storageKey(current.identity) == cover.trackKey,
              let loaded = app?.voice?.renders[cover.trackKey] else { return false }
        return cover.cacheKeys.contains(loaded.cacheKey)
    }

    private func playAICover(_ cover: VoiceManager.StoredCover) {
        guard let app, let voice = app.voice else { return }
        let rows = aiCoverRows
        guard let track = rows.first(where: { $0.cover.id == cover.id })?.track else { return }
        model.showPlayer()
        app.noteAuxiliaryActivity(false)
        app.playback.setQueue(rows.map(\.track), current: track)
        Task { await voice.playStoredCover(cover, track: track, queue: rows.map(\.cover)) }
    }

    private func deleteAICover(_ cover: VoiceManager.StoredCover) {
        _ = app?.voice?.deleteStoredCovers([cover])
    }

    private func refreshAICovers() {
        app?.voice?.reloadStoredCovers()
        Task { await home.resolveLegacyCoverTracks(app: app) }
    }

    private func toggleFavorite(_ track: Track) {
        Task {
            let result = await app?.toggleFavorite(track)
            if model.track?.identity == track.identity { model.isFavorite = result ?? false }
            model.libraryRevision &+= 1
        }
    }

    private func toggleOffline(_ track: Track, isOffline: Bool) {
        Task {
            if isOffline {
                await app?.removeOffline(track)
            } else {
                _ = await app?.downloadOffline(track)
            }
        }
    }

    private func removeOffline(_ track: Track) {
        Task { await app?.removeOffline(track) }
    }

    private func play(_ track: Track) {
        let tracks = home.list.tracks
        model.showPlayer()
        app?.noteAuxiliaryActivity(false)
        app?.playback.setQueue(tracks, current: track)
        Task { await app?.playback.load(track, autoplay: true) }
    }

    private func enableQuickPreset(_ preset: ExternalAPIPreset) {
        guard let app else { return }
        onboardingHint = nil
        onboardingNeedsNetworkPreset = nil
        isEnablingPresetID = preset.id
        Task { @MainActor in
            defer { isEnablingPresetID = nil }
            do {
                if let source = try await app.sourceManager.setPresetEnabled(preset, enabled: true) {
                    app.sourceManager.selectActiveBrowseSource(source.id)
                    home.refresh(app: app)
                }
            } catch let playbackError as PlaybackError where playbackError == .networkDisabled {
                onboardingNeedsNetworkPreset = preset
                onboardingHint = String(localized: "当前未允许联网，开启后即可获取并启用该音源")
            } catch let violation as SourceDomainPolicy.Violation {
                if case .networkDisabled = violation {
                    onboardingNeedsNetworkPreset = preset
                    onboardingHint = String(localized: "当前未允许联网，开启后即可获取并启用该音源")
                } else {
                    onboardingHint = SourceErrorPresentation.friendly(violation)
                }
            } catch {
                onboardingHint = SourceErrorPresentation.friendly(error)
            }
        }
    }
}
