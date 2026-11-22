import SwiftUI

/// 一个固定播放栏承接歌曲、播放控制与队列，页面切换不影响它。
struct TransportBand: View {
    @Bindable var model: MorphPresentationModel
    var isCompact = false
    var isNarrowSwitch = false
    @Environment(\.app) private var app
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 0) {
            FlowDivider()
            HStack(spacing: 16) {
                currentSong.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    transportButtons
                    progress
                }
                .frame(maxWidth: .infinity)
                utilities
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onChange(of: model.track?.identity) { _, _ in scrubPosition = nil }
    }

    private var currentSong: some View {
        HStack(spacing: 8) {
            Button {
                model.showPlayer()
                app?.noteAuxiliaryActivity(false)
            } label: {
                HStack(spacing: 12) {
                    ArtworkSlab(image: model.isMasked ? nil : model.artwork, ambient: nil,
                                side: 46, cornerRadius: 8, showsAmbientGlow: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayTitle ?? String(localized: "正在播放"))
                            .flowType(.homeControl).lineLimit(1)
                        if let artist = model.displayArtist {
                            HStack(spacing: 6) {
                                Text(artist).flowType(.homeSecondary)
                                    .foregroundStyle(FlowColor.secondaryText).lineLimit(1)
                                if model.isBuffering {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                        } else if model.isBuffering {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回播放页")
            .accessibilityIdentifier("home.nowPlaying")
            if !isCompact {
                FlowIconButton(systemName: model.isFavorite ? "star.fill" : "star",
                               label: model.isFavorite ? "取消收藏" : "收藏", isActive: model.isFavorite,
                               size: 32, symbolSize: 15, prominent: true, action: favorite)
            }
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            FlowIconButton(systemName: "shuffle", label: "随机播放", isActive: model.isShuffling,
                           size: 32, symbolSize: 14, prominent: true) {
                app?.playback.toggleShuffle()
                refresh()
            }
            FlowIconButton(systemName: "backward.fill", label: "上一首", isEnabled: model.track != nil,
                           size: 34, symbolSize: 16, prominent: true) { skip(.previous) }
            FlowPlayButton(isPlaying: model.isPlaying, size: 36, isEnabled: canPlay, action: togglePlayback)
            FlowIconButton(systemName: "forward.fill", label: "下一首", isEnabled: model.track != nil,
                           size: 34, symbolSize: 16, prominent: true) { skip(.next) }
            FlowIconButton(systemName: repeatSymbol, label: "播放模式：\(repeatName)",
                           isActive: model.repeatMode != .off, size: 32, symbolSize: 14, prominent: true) {
                app?.playback.cycleRepeatMode()
                refresh()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            Text(DurationText.clock(scrubPosition ?? model.position))
                .flowType(.homeSecondary).monospacedDigit()
                .foregroundStyle(FlowColor.secondaryText)
            HairlineSlider(value: Binding(get: { scrubPosition ?? model.position }, set: { scrubPosition = $0 }),
                           range: 0...max(model.duration, 1), onEditingChanged: { editing in
                guard !editing, let target = scrubPosition else { return }
                Task { await app?.playback.seek(to: target) }
                scrubPosition = nil
            }, accessibilityLabel: "播放进度")
                .disabled(model.track == nil || model.duration <= 0)
            Text(DurationText.clock(model.duration))
                .flowType(.homeSecondary).monospacedDigit()
                .foregroundStyle(FlowColor.secondaryText)
        }
    }

    private var utilities: some View {
        HStack(spacing: 4) {
            FlowIconButton(systemName: "quote.bubble", label: "歌词", isActive: !model.showsHome,
                           size: 32, symbolSize: 16, prominent: true) {
                if model.showsHome { model.showPlayer() } else { model.showHome() }
                app?.noteAuxiliaryActivity(false)
            }
            FlowIconButton(systemName: volumeSymbol, label: model.isMuted ? "取消静音" : "静音",
                           size: 32, symbolSize: 15, prominent: true) {
                app?.playback.toggleMute()
                refresh()
            }
            // Binding 的 setter 只接收用户输入，模型同步不会意外把静音的 0 落盘。
            HairlineSlider(value: Binding(get: { Double(model.isMuted ? 0 : model.volume) }, set: { value in
                let volume = Float(min(max(value, 0), 1))
                app?.playback.setVolume(volume)
                app?.appearance.setEngineVolume(Double(volume))
                refresh()
            }), accessibilityLabel: "音量")
                .frame(width: isCompact ? 54 : (isNarrowSwitch ? 64 : 76))
            FlowIconButton(systemName: "list.bullet", label: "队列", isActive: model.auxiliary == .queue,
                           size: 36, symbolSize: 16, prominent: true) {
                model.auxiliary = model.auxiliary == .queue ? nil : .queue
                app?.noteAuxiliaryActivity(model.auxiliary != nil)
            }
            // 音色入口与「原曲 / AI 翻唱」切换开关不随紧凑形态隐藏：
            // 在播时一眼可见且可一点切换版本。
            VoiceVersionSwitch(track: model.track, model: model, style: .standard, compact: isCompact || isNarrowSwitch)
                .padding(.leading, 2)
            VoiceControl(track: model.track)
                .padding(.leading, 2)
        }
    }

    private var repeatSymbol: String {
        switch model.repeatMode {
        case .off: "arrow.right.to.line"
        case .one: "repeat.1"
        case .all: "repeat"
        }
    }

    private var repeatName: String {
        switch model.repeatMode {
        case .off: String(localized: "顺序播放")
        case .one: String(localized: "单曲循环")
        case .all: String(localized: "列表循环")
        }
    }

    private var volumeSymbol: String {
        if model.isMuted || model.volume <= 0.001 { return "speaker.slash" }
        if model.volume < 0.34 { return "speaker" }
        if model.volume < 0.7 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    private var canPlay: Bool { model.track != nil || !model.queue.items.isEmpty }

    private func favorite() {
        guard let track = model.track else { return }
        Task {
            let result = await app?.toggleFavorite(track)
            if model.track?.identity == track.identity { model.isFavorite = result ?? false }
            model.libraryRevision &+= 1
        }
    }

    private func togglePlayback() {
        // 唯一语义在 PlaybackControlling.togglePlayback()（含 .failed 重试、
        // 空当前曲目回队首）；这里不重复实现，否则失败态按键无反应。
        Task { await app?.playback.togglePlayback() }
    }

    private func skip(_ direction: SkipDirection) { Task { await app?.playback.skip(direction) } }

    private func refresh() {
        guard let playback = app?.playback else { return }
        model.repeatMode = playback.queueSnapshot.repeatMode
        model.isShuffling = playback.queueSnapshot.isShuffling
        model.volume = playback.volume
        model.isMuted = playback.isMuted
    }
}
