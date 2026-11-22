import SwiftUI

enum VoiceVersionChoice: Hashable {
    case original
    case voiceAI
}

/// 播放器栏与沉浸胶囊共用的「原曲 / AI 翻唱」一键切换控件。
struct VoiceVersionSwitch: View {
    @Environment(\.app) private var app
    var track: Track?
    @Bindable var model: MorphPresentationModel
    var style: FlowSegmentedSwitch<VoiceVersionChoice>.Style = .standard
    var compact = false

    @State private var alertMessage: String?

    var body: some View {
        if let track, let voice = app?.voice, shouldShow(voice: voice, track: track) {
            let trackKey = TrackIdentity.storageKey(track.identity)
            let isFetchingInput = voice.fetchingInputTrackKeys.contains(trackKey)
            let taskInfo = voice.taskInfo(for: track)
            let isConverting = isFetchingInput || (taskInfo != nil && taskInfo?.state.isTerminal == false)
            let selection: VoiceVersionChoice = (model.isPlayingVoiceAI || (voice.isEnabled && isConverting))
                ? .voiceAI
                : .original

            HStack(spacing: 6) {
                FlowSegmentedSwitch(
                    items: [
                        .init(value: .original, title: String(localized: "原曲"), identifier: "voice.version.original"),
                        .init(
                            value: .voiceAI,
                            title: compact ? String(localized: "AI") : String(localized: "AI 翻唱"),
                            identifier: "voice.version.ai"
                        ),
                    ],
                    selection: selection,
                    style: style
                ) { chosen in
                    handleSelect(chosen, track: track, voice: voice)
                }

                if isConverting {
                    ProgressView()
                        .controlSize(.mini)
                        .help(isFetchingInput ? "正在缓冲原曲音频…" : "正在生成 AI 翻唱…")
                }
            }
            .alert(
                "AI 翻唱",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                )
            ) {
                Button("好") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func shouldShow(voice: VoiceManager, track: Track) -> Bool {
        guard voice.showEntryInPlayer else { return false }
        if voice.isEnabled || model.isPlayingVoiceAI { return true }
        if voice.existingRender(for: track) != nil { return true }
        if let info = voice.taskInfo(for: track), !info.state.isTerminal { return true }
        return voice.canStartGeneration
    }

    private func handleSelect(_ choice: VoiceVersionChoice, track: Track, voice: VoiceManager) {
        Task {
            do {
                switch choice {
                case .original:
                    await voice.switchToOriginalPlayback(for: track, autoplay: !model.isPlaying)
                case .voiceAI:
                    // 缺模型但能联网：生成任务会先自动下载；断网时才拦下来说明。
                    if !voice.baseModelsReady, !voice.isNetworkEnabled {
                        alertMessage = voice.hubertIncompatibleReason
                            ?? String(localized: "还没有下载所需模型。请先允许联网，或在 设置 → 音色 里导入模型文件。")
                        return
                    }
                    if voice.selectedPack == nil {
                        alertMessage = String(localized: "请先选择一个 AI 音色包。")
                        return
                    }
                    try await voice.switchToVoicePlayback(for: track, autoplay: true)
                }
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}
