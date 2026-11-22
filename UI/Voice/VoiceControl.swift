import SwiftUI
import UniformTypeIdentifiers

/// 播放栏「音色」入口：一枚图标 + 进度环，点开才是管理面板。
struct VoiceControl: View {
    private struct AlertPayload {
        let title: String
        let message: String
    }

    @Environment(\.app) private var app
    var track: Track?
    var onPopoverPresentedChanged: ((Bool) -> Void)? = nil

    @State private var showPanel = false
    @State private var showAdvanced = false
    @State private var showImporter = false
    @State private var alertPayload: AlertPayload?

    private var voice: VoiceManager? { app?.voice }

    var body: some View {
        if let voice, voice.showEntryInPlayer {
            Button { showPanel.toggle() } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(voice.isEnabled ? Color.primary : FlowColor.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(voice.isEnabled ? FlowColor.hover : .clear)
                        )
                    if let info = track.flatMap({ voice.taskInfo(for: $0) }),
                       case let .running(_, fraction, _) = info.state, fraction < 1 {
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Color.primary.opacity(0.75), lineWidth: 1.6)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 26, height: 26)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("音色：AI 翻唱")
            .popover(isPresented: $showPanel, arrowEdge: .bottom) {
                VoicePanel(
                    voice: voice,
                    track: track,
                    onImport: { showImporter = true },
                    onOpenAdvanced: {
                        showPanel = false
                        showAdvanced = true
                    },
                    onError: { title, message in
                        alertPayload = AlertPayload(title: title, message: message)
                    }
                )
            }
            .sheet(isPresented: $showAdvanced) {
                VoiceAdvancedPanel(voice: voice, track: track)
            }
            .onChange(of: showPanel) { _, isPresented in
                onPopoverPresentedChanged?(isPresented || showAdvanced)
            }
            .onChange(of: showAdvanced) { _, isPresented in
                onPopoverPresentedChanged?(showPanel || isPresented)
            }
            .onDisappear {
                onPopoverPresentedChanged?(false)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.folder, .item],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result, voice: voice)
            }
            .alert(
                LocalizedStringKey(alertPayload?.title ?? "FLOW Voice"),
                isPresented: Binding(
                    get: { alertPayload != nil },
                    set: { if !$0 { alertPayload = nil } }
                )
            ) {
                Button("好") { alertPayload = nil }
            } message: {
                Text(alertPayload?.message ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>, voice: VoiceManager) {
        switch result {
        case .failure(let err):
            alertPayload = AlertPayload(title: String(localized: "导入失败"), message: err.localizedDescription)
        case .success(let urls):
            Task {
                do {
                    try await VoiceImportHelper.importPack(from: urls, into: voice)
                } catch {
                    alertPayload = AlertPayload(title: String(localized: "导入失败"), message: error.localizedDescription)
                }
            }
        }
    }
}

/// 音色快速面板：总开关、当前歌曲渲染状态（取消/重新生成）、音色包列表、高级参数入口。
private struct VoicePanel: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.app) private var app
    let voice: VoiceManager
    var track: Track?
    var onImport: () -> Void
    var onOpenAdvanced: () -> Void
    var onError: (String, String) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("音色").flowType(.homeTitle)
                Spacer()
                // 开关只决定"有成品时播 AI 版"；生成走下面的显式按钮，打开开关不会开始转换。
                Toggle("", isOn: Binding(
                    get: { voice.isEnabled },
                    set: { voice.isEnabled = $0 }
                ))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if let track {
                trackActionRow(track: track)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }

            if !voice.baseModelsReady {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: (voice.isEnabled || voice.hubertIncompatibleReason != nil) ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle((voice.isEnabled || voice.hubertIncompatibleReason != nil) ? .orange : FlowColor.secondaryText)
                    if let incompatible = voice.hubertIncompatibleReason {
                        Text(incompatible)
                            .flowType(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(voice.isNetworkEnabled
                             ? "还没有下载所需模型，第一次生成时会自动下载（耗时较长）。"
                             : "还没有下载所需模型。请先允许联网，或在设置里导入模型文件。")
                            .flowType(.caption)
                            .foregroundStyle(FlowColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if voice.hubertIncompatibleReason != nil, voice.isNetworkEnabled {
                        Button("重新下载") {
                            Task {
                                do { try await voice.downloadBaseAsset(.hubert) }
                                catch { onError(String(localized: "下载失败"), error.localizedDescription) }
                            }
                        }
                        .buttonStyle(.plain)
                        .flowType(.caption)
                        .foregroundStyle(Color.primary)
                    }
                    Button("去设置") {
                        SettingsNavigation.request(SettingsNavigation.voicePane)
                        openSettings()
                    }
                    .buttonStyle(.plain)
                    .flowType(.caption)
                    .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            FlowDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if voice.packs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有音色").flowType(.homeControl)
                            Text("在设置 → 音色 里点「在线获取…」，或把 .voicepack 文件夹 / .onnx 文件拖到这里。")
                                .flowType(.homeSecondary)
                                .foregroundStyle(FlowColor.secondaryText)
                        }
                        .padding(.vertical, 10)
                    } else {
                        ForEach(voice.packs, id: \.packID) { pack in
                            packRow(pack)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(maxHeight: 240)

            FlowDivider()

            HStack(spacing: 10) {
                Button { onImport() } label: {
                    Label("导入音色", systemImage: "plus").flowType(.homeSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onOpenAdvanced() } label: {
                    Text("高级参数").flowType(.homeSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 332)
        .overlay {
            VoiceDropHighlightOverlay(isTargeted: isDropTargeted, cornerRadius: 10)
        }
        .voicePackDropDestination(into: voice, isTargeted: $isDropTargeted) { message in
            onError(String(localized: "导入失败"), message)
        }
        .task(id: track?.id) {
            if let track {
                await voice.refreshRenderAvailability(for: track)
            }
        }
    }

    @ViewBuilder
    private func trackActionRow(track: Track) -> some View {
        let trackKey = TrackIdentity.storageKey(track.identity)
        let isCurrentPlayingAI = (app?.playback.isPlayingVoiceAI == true)
            && (app?.playback.currentTrack?.identity == track.identity)
        if voice.fetchingInputTrackKeys.contains(trackKey) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("正在获取原曲音频…").flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                Spacer()
            }
        } else if let info = voice.taskInfo(for: track), !info.state.isTerminal {
            HStack(spacing: 8) {
                switch info.state {
                case .queued:
                    Text("排队中").flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                case let .running(stage, fraction, _):
                    ProgressView(value: fraction).controlSize(.mini).frame(width: 64)
                    Text(stage.displayName).flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                default:
                    EmptyView()
                }
                Spacer()
                Button {
                    voice.cancelRender(trackKey: trackKey)
                } label: {
                    Text("取消").flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                }
                .buttonStyle(.plain)
            }
        } else if isCurrentPlayingAI {
            HStack(spacing: 8) {
                Text("正在播放 AI 版").flowType(.caption).foregroundStyle(Color.primary)
                Spacer()
                Button {
                    Task { await voice.switchToOriginalPlayback(for: track, autoplay: false) }
                } label: {
                    Text("切回原曲").flowType(.caption).foregroundStyle(Color.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(FlowColor.hover, in: Capsule())
                }
                .buttonStyle(.plain)
                if voice.selectedPack != nil {
                    Button {
                        Task {
                            do { _ = try await voice.requestRender(for: track, force: true) }
                            catch { onError(String(localized: "无法生成 AI 翻唱"), error.localizedDescription) }
                        }
                    } label: {
                        Text("重新生成").flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if voice.existingRender(for: track) != nil {
            HStack(spacing: 8) {
                Text("AI 翻唱已就绪").flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                Spacer()
                Button {
                    playVoiceVersion(of: track)
                } label: {
                    Text("播放 AI 版").flowType(.caption).foregroundStyle(Color.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(FlowColor.hover, in: Capsule())
                }
                .buttonStyle(.plain)
                if voice.selectedPack != nil {
                    Button {
                        Task {
                            do { _ = try await voice.requestRender(for: track, force: true) }
                            catch { onError(String(localized: "无法生成 AI 翻唱"), error.localizedDescription) }
                        }
                    } label: {
                        Text("重新生成").flowType(.caption).foregroundStyle(FlowColor.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if let err = voice.errorMessage(for: track) {
            HStack(spacing: 8) {
                Text(err).flowType(.caption).foregroundStyle(.red).lineLimit(3)
                Spacer()
                if voice.selectedPack != nil {
                    Button {
                        playVoiceVersion(of: track)
                    } label: {
                        Text("重试").flowType(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if voice.canStartGeneration {
            HStack {
                Text("当前播放原曲").flowType(.caption).foregroundStyle(FlowColor.tertiaryText)
                Spacer()
                Button {
                    playVoiceVersion(of: track)
                } label: {
                    Text("生成并播放 AI 版").flowType(.caption).foregroundStyle(Color.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(FlowColor.hover, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 显式切换并生成/起播 AI 翻唱版本。
    private func playVoiceVersion(of track: Track) {
        Task {
            do {
                try await voice.switchToVoicePlayback(for: track, autoplay: true)
            } catch {
                if voice.errorMessage(for: track) == nil {
                    onError(String(localized: "无法生成 AI 翻唱"), error.localizedDescription)
                }
            }
        }
    }

    private func packRow(_ pack: VoicePackManifest) -> some View {
        let isSelected = pack.packID == voice.selectedPack?.packID
        return Button {
            voice.selectPack(pack.packID)
            if let track {
                Task { await voice.refreshRenderAvailability(for: track) }
            }
        } label: {
            HStack(spacing: 8) {
                VoicePackAvatarView(coverURL: voice.coverURL(for: pack), isSelected: isSelected, size: 22)
                Text(pack.displayName).flowType(.homeSecondary).lineLimit(1)
                Spacer()
                Text("\(pack.versions.count) 个版本").flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.primary : FlowColor.tertiaryText)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
