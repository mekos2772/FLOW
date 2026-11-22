import SwiftUI

/// 菜单栏面板（规格 12）。
///
/// 三条约束：
/// 1. 与 FLOW 同一套视觉语言（令牌、字距、层级），不是"另一份完整播放器"；
/// 2. 空间永远不够，所以只用图标 + 一行曲目信息，不塞滚动歌名；
/// 3. 所有操作作用在**真实播放内核**上，形态操作走 `MorphControlling`，不复制状态。
struct MenuBarView: View {
    @Environment(\.app) private var app
    @Environment(\.openSettings) private var openSettings

    @State private var tick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            FlowDivider()
            lyricSnapshot
            transport
            FlowDivider()
            morphControls
            FlowDivider()
            footer
        }
        .padding(Spacing.s)
        .frame(width: 268)
        // 进度与歌词快照：菜单栏不持有独立时钟，只是每 0.5s 读一次投影。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                tick &+= 1
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            FlowMarkView(height: 11)
            Circle()
                .fill(isPlaying ? Color.primary : FlowColor.tertiaryText)
                .frame(width: 4, height: 4)
            Spacer(minLength: 0)
            Text(morphologyLabel)
                .flowType(.eyebrow)
                .foregroundStyle(FlowColor.tertiaryText)
        }
    }

    // MARK: - 当前曲目 + 一行歌词

    private var lyricSnapshot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .flowType(.trackTitleCompact.scaled(0.72))
                .lineLimit(1)
            if let error = app?.playback.lastError {
                HStack(spacing: 4) {
                    flowIcon(systemName: "exclamationmark.triangle.fill", size: 9)
                    Text(error.title).flowType(.caption)
                }
                .foregroundStyle(FlowColor.secondaryText)
                .lineLimit(1)
            } else if let line = currentLine {
                Text(line)
                    .flowType(.caption)
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
            } else if !artist.isEmpty {
                Text(artist)
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                    .lineLimit(1)
            }
            HairlineProgress(progress: progress, tint: .primary, height: 2)
                .padding(.top, 6)
        }
    }

    // MARK: - 播放控制

    private var transport: some View {
        HStack(spacing: Spacing.xs) {
            FlowIconButton(systemName: "backward.fill", label: "上一首", size: 28, symbolSize: 12) {
                Task { await app?.playback.skip(.previous) }
            }
            FlowPlayButton(isPlaying: isPlaying, size: 32) {
                Task { await app?.playback.togglePlayback() }
            }
            FlowIconButton(systemName: "forward.fill", label: "下一首", size: 28, symbolSize: 12) {
                Task { await app?.playback.skip(.next) }
            }
            Spacer(minLength: 0)
            Text(timecode)
                .flowType(.timecode)
                .foregroundStyle(FlowColor.tertiaryText)
        }
    }

    // MARK: - 形态

    private var morphControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach([PlayerMorphology.expanded, .compact, .capsule, .edge], id: \.rawValue) { morphology in
                    Button {
                        app?.morph.setMorphology(morphology)
                    } label: {
                        flowIcon(systemName: morphology.symbolName, size: 13)
                            .foregroundStyle(currentMorphology == morphology
                                             ? Color.primary : FlowColor.secondaryText)
                            .frame(width: 32, height: 26)
                            .background {
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .fill(currentMorphology == morphology ? FlowColor.hover : .clear)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("切换到\(morphology.displayName)形态")
                }
                Spacer(minLength: 0)
                FlowIconButton(systemName: isMorphologyLocked ? "lock.fill" : "lock.open",
                               label: isMorphologyLocked ? "解除形态锁定" : "锁定当前形态",
                               isActive: isMorphologyLocked, size: 26, symbolSize: 11) {
                    app?.morph.toggleMorphologyLock()
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggleRow("隐私模式", isOn: app?.privacy.isEnabled ?? false) { value in
                app?.privacy.setEnabled(value)
            }
            // 命名要对得上行为：开关真正切的是悬浮形态（capsule）而非"歌词文本"。
            // 用"悬浮歌词"避免用户以为是在开关歌词渲染本身。
            toggleRow("悬浮歌词", isOn: app?.morph.isVisible ?? true) { value in
                if value { app?.morph.setMorphology(.capsule) } else { app?.floatingLyrics.hide() }
            }
            if let sleepTimer = app?.sleepTimer {
                sleepTimerRow(sleepTimer)
            }
            // 音源状态：按 SourceManager 展示当前活动音源与设置入口，不直接依赖特定平台服务。
            if let manager = app?.sourceManager {
                FlowDivider()
                MenuSourceSection(manager: manager) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            HStack(spacing: Spacing.s) {
                FlowTextButton(title: "恢复默认布局", symbolName: "arrow.counterclockwise") {
                    Task { await app?.morph.resetPlacementMemory() }
                }
                Spacer(minLength: 0)
                FlowTextButton(title: "设置", symbolName: "gearshape") {
                    // 隐藏 Dock 图标后 App 是 `.accessory` 策略：直接 `openSettings()`
                    // 可能让设置窗口出现在其它窗口后面（甚至看起来"点了没反应"）。
                    // 与深链打开播放器同样的做法——先激活再展示。
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
        }
    }

    @ViewBuilder
    private func sleepTimerRow(_ timer: SleepTimerDriver) -> some View {
        if timer.isArmed {
            FlowTextButton(title: "取消睡眠定时", symbolName: "moon.zzz") { timer.cancel() }
        } else {
            HStack(spacing: 6) {
                Text("睡眠定时")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                ForEach([30, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分") {
                        timer.start(for: .seconds(minutes * 60))
                    }
                    .buttonStyle(.plain)
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(FlowColor.hover)
                    }
                }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
                .flowType(.caption)
                .foregroundStyle(FlowColor.secondaryText)
            Spacer()
            // 同 SettingsView：菜单栏里的 Toggle 也只在主线程回调。
            Toggle("", isOn: Binding(get: { isOn },
                                     set: { value in MainActor.assumeIsolated { action(value) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    // MARK: - 投影

    private var isPlaying: Bool { app?.playback.state.isPlaying ?? false }
    private var title: String {
        guard !(app?.privacy.isMasking ?? false) else { return String(localized: "正在播放") }
        guard let track = app?.playback.currentTrack else { return String(localized: "未在播放") }
        let resolved = MorphPresentationModel.display(track).title
        // 未通过歌曲确认前不泄露 B 站原始视频标题或 BV 号。
        return resolved.isEmpty ? String(localized: "正在加载…") : resolved
    }
    private var artist: String {
        guard !(app?.privacy.isMasking ?? false) else { return "" }
        return app?.playback.currentTrack.flatMap { MorphPresentationModel.display($0).artist } ?? ""
    }
    private var currentLine: String? {
        guard !(app?.privacy.isMasking ?? false), let app,
              let track = app.playback.currentTrack, app.sourceManager.isTrackVisible(track) else { return nil }
        let snapshot = app.lyricEngine.snapshot(at: app.playback.currentPosition)
        return snapshot.current?.text
    }
    private var currentMorphology: PlayerMorphology { app?.morph.morphology ?? .expanded }
    private var isMorphologyLocked: Bool { app?.morph.isMorphologyLocked ?? false }

    private var morphologyLabel: String {
        app?.morph.morphology.displayName ?? ""
    }

    private var progress: Double {
        let duration = app?.playback.duration ?? 0
        guard duration > 0 else { return 0 }
        return min(max((app?.playback.currentPosition ?? 0) / duration, 0), 1)
    }

    private var timecode: String {
        let position = app?.playback.currentPosition ?? 0
        let duration = app?.playback.duration ?? 0
        // 直接用 `DurationText`（唯一的时长格式化实现）。
        // 之前借道 `ExpandedPlayerView.format`——菜单栏为了一个格式化函数
        // 依赖了整个播放器视图，属于跨层引用，且与 `DurationText` 是两份实现。
        return "\(DurationText.clock(position)) / \(DurationText.clock(duration))"
    }
}


/// 菜单栏面板的外壳。
///
/// 两件事必须在这里做，不能指望子视图：
/// 1. `MenuBarExtra(.window)` 的系统底是 vibrancy 材质，会把壁纸颜色透上来
///    （彩色壁纸下实测顶部出现一条暖色渐变）。纯黑白体系里必须换成不透明中性底。
/// 2. 开关/滑块的强调色默认取系统强调色（蓝）。统一压到主色。
struct MenuBarPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MenuBarView()
            .background(Surface.opaqueFallback(colorScheme))
            .tint(.primary)
    }
}

/// 菜单栏里的轻量多音源摘要区（详细管理与导入落在设置窗格）。
private struct MenuSourceSection: View {
    let manager: SourceManager
    let onManageSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                flowIcon(systemName: "antenna.radiowaves.left.and.right", size: 12)
                    .foregroundStyle(FlowColor.secondaryText)
                Text(verbatim: manager.activeBrowseSource?.descriptor.displayName ?? String(localized: "未配置音源"))
                    .flowType(.caption)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if manager.browsableSources.count > 1 {
                    FlowCaption(text: "\(manager.browsableSources.count) 源")
                }
            }
            FlowTextButton(title: "管理或导入音源…", symbolName: "slider.horizontal.3", action: onManageSources)
        }
    }
}
