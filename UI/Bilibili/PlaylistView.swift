import SwiftUI

/// 账户设置保留弹窗入口，主窗口直接嵌入相同的歌单内容。
struct PlaylistView: View {
    @Binding var isPresented: Bool

    var body: some View {
        PlaylistContent(onClose: { isPresented = false })
            .padding(24)
            .frame(width: 560, height: 500)
    }
}

struct PlaylistContent: View {
    var onClose: (() -> Void)?
    var onPlay: () -> Void = {}
    @Environment(\.app) private var app
    @State private var state = PlaylistPageState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("歌单").flowType(.pageTitle)
                Spacer()
                if state.list.isLoading { ProgressView().controlSize(.small) }
                if let onClose {
                    FlowIconButton(systemName: "xmark", label: "关闭", size: 36,
                                   prominent: true, action: onClose)
                }
            }
            HStack(spacing: 12) {
                TextField("新歌单名称", text: $state.newName)
                    .textFieldStyle(.roundedBorder).flowType(.homeControl)
                    .accessibilityLabel("新歌单名称")
                    .onSubmit { state.create(app: app) }
                Button("新建") { state.create(app: app) }
                    .disabled(state.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let selected = state.selected {
                HStack(spacing: 12) {
                    Picker("选择歌单", selection: Binding(get: { selected.id }, set: { state.select($0) })) {
                        ForEach(state.playlists) { playlist in Text(playlist.name).tag(playlist.id) }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                    Spacer(minLength: 0)
                    FlowIconButton(systemName: "trash", label: "删除歌单", size: 34,
                                   symbolSize: 15, prominent: true) { state.deletingID = selected.id }
                }
                HStack(spacing: 12) {
                    Button { play() } label: {
                        HStack(spacing: 6) { flowIcon(systemName: "play.fill", size: 12); Text("播放全部") }
                    }
                        .disabled(state.visibleEntries.isEmpty)
                    Button { state.addCurrent(app: app) } label: { Label("加入当前曲目", systemImage: "plus") }
                        .disabled(app?.playback.currentTrack == nil)
                    Button { Task { await state.downloadOffline(app: app) } } label: {
                        Label("离线保存", systemImage: "arrow.down.circle")
                    }
                        .disabled(state.visibleEntries.isEmpty || state.isDownloadingOffline)
                }
                if !state.visibleEntries.isEmpty {
                    List {
                        ForEach(state.visibleEntries, id: \.index) { item in
                            let isOffline = app?.offline.isOffline(item.track.identity) ?? false
                            let isDownloading = app?.offline.isDownloading(item.track.identity) ?? false
                            SongRow(track: item.track,
                                    isCurrent: app?.playback.currentTrack?.identity == item.track.identity,
                                    isOffline: isOffline,
                                    isDownloadingOffline: isDownloading,
                                    onToggleOffline: {
                                        Task {
                                            if isOffline { await app?.removeOffline(item.track) }
                                            else { _ = await app?.downloadOffline(item.track) }
                                        }
                                    },
                                    onRemove: { state.remove(at: item.index, app: app) },
                                    onPlay: { play(item.track) })
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { state.move(from: $0, to: $1, app: app) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                } else if !state.list.isLoading {
                    empty(selected.entries.isEmpty ? String(localized: "歌单还是空的")
                          : state.list.message ?? String(localized: "歌单还是空的"))
                } else { Spacer() }
            } else {
                empty(String(localized: "还没有歌单"))
            }
            if let message = state.message ?? (state.visibleEntries.isEmpty ? nil : state.list.message) {
                Text(message).flowType(.homeSecondary).foregroundStyle(FlowColor.secondaryText)
            }
        }
        .flowType(.homeControl)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { state.reload(app: app) }
        .task(id: "\(state.selectedID?.uuidString ?? "")-\(state.revision)") { await state.loadSongs(app: app) }
        .onDisappear { state.list.cancel() }
        .alert("删除歌单？", isPresented: Binding(get: { state.deletingID != nil }, set: {
            if !$0 { state.deletingID = nil }
        })) {
            Button("取消", role: .cancel) { state.deletingID = nil }
            Button("删除", role: .destructive) { state.confirmDelete(app: app) }
        } message: {
            Text("歌单将被删除，歌曲和收藏不受影响。")
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).flowType(.homeTitle).foregroundStyle(FlowColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func play(_ track: Track? = nil) {
        if state.play(track, app: app) { onPlay() }
    }
}
