import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口。
///
/// 采用 macOS 现代设置布局（左侧轻量分区 + 右侧内容），但样式完全走 FLOW 令牌：
/// 没有系统蓝大色块选中态、没有分组卡片、没有默认灰底 Form。
/// 每一行都绑定真实状态——**没有装饰性开关**（规格 16）。
struct SettingsView: View {
    @Environment(\.app) private var app
    // 调试入口：截图/验收时直接落到指定分页（无辅助功能权限时也能验证）。
    // 只认环境变量，不写进用户偏好。
    @State private var pane: SettingsPane =
        SettingsPane(rawValue: ProcessInfo.processInfo.environment["SLP_SETTINGS_PANE"] ?? "") ?? .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(FlowColor.hairline).frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(pane.title)
                        .flowType(FlowType.trackTitleCompact.scaled(0.9))
                        .padding(.bottom, Spacing.xxs)
                    paneContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
            }
            .scrollIndicators(.never)
        }
        // 不要自己画窗口底色：设置窗是系统窗，让它用系统背景，
        // 否则会出现"系统深色、设置窗却是白的"这种自相矛盾（实机踩到过）。
        .frame(width: 640, height: 460)
        .onAppear(perform: consumeRequestedPane)
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigation.didRequestPane)) { _ in
            consumeRequestedPane()
        }
    }

    private func consumeRequestedPane() {
        guard let raw = SettingsNavigation.takePendingPane(),
              let requested = SettingsPane(rawValue: raw) else { return }
        pane = requested
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FLOW")
                .flowType(.wordmark)
                .foregroundStyle(FlowColor.tertiaryText)
                .padding(.horizontal, Spacing.s)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.s)

            ForEach(SettingsPane.allCases) { item in
                SettingsSidebarRow(item: item, isSelected: pane == item) {
                    pane = item
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 168)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .morphology: MorphologyPane()
        case .lyrics: LyricsPaneSettings()
        case .playback: PlaybackPane()
        case .voice: VoicePane()
        case .onlineMusic: OnlineMusicPane()
        case .shortcuts: ShortcutPane()
        case .permission: PermissionPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }

    /// 剩余时间文案。`Duration` 直接 `description` 会长成 "1798 seconds"，
    /// 这里统一成 `29:58` 这种一眼能读的形式。
    static func countdownText(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        // 复用唯一的时长格式化。原来这里自己拼 `mm:ss`，
        // 而睡眠定时器**提供 90 分钟选项**——那会显示成 `90:00`，应为 `1:30:00`。
        return DurationText.clock(TimeInterval(total))
    }
}

/// 别的页面打开设置时指定落到哪一页。
///
/// 起因：首页空态的「前往设置导入音源」打开的是「通用」页，新用户还得自己找「在线音乐」。
/// 设置窗可能还没创建（先记下待消费的页）也可能已经开着（再发一次通知），两种都要接住。
@MainActor
enum SettingsNavigation {
    static let didRequestPane = Notification.Name("flow.settings.didRequestPane")
    static let onlineMusicPane = "onlineMusic"
    static let voicePane = "voice"
    private static var pendingPane: String?

    static func request(_ pane: String) {
        pendingPane = pane
        NotificationCenter.default.post(name: didRequestPane, object: nil)
    }

    static func takePendingPane() -> String? {
        defer { pendingPane = nil }
        return pendingPane
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, morphology, lyrics, playback, voice, onlineMusic, shortcuts, permission, advanced, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .morphology: return "形态与自动变形"
        case .lyrics: return "歌词"
        case .playback: return "播放"
        case .voice: return "音色"
        case .onlineMusic: return "在线音乐"
        case .shortcuts: return "快捷键"
        case .permission: return "权限"
        case .advanced: return "高级"
        case .about: return "关于 FLOW"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .morphology: return "rectangle.compress.vertical"
        case .lyrics: return "text.bubble"
        case .playback: return "play.circle"
        case .voice: return "person.wave.2"
        case .onlineMusic: return "waveform"
        case .shortcuts: return "keyboard"
        case .permission: return "lock.shield"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsSidebarRow: View {
    let item: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                flowIcon(systemName: item.symbolName, size: 11)
                    .frame(width: 14)
                Text(item.title)
                    .flowType(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : FlowColor.secondaryText)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? FlowColor.hover : (isHovering ? FlowColor.hover.opacity(0.55) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, Spacing.xs)
    }
}

// MARK: - 通用行样式

/// 设置行：左侧标题 + 说明，右侧控件。没有卡片、没有分组框。
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    /// 摘要：只写一行，说清"这个开关做什么"。
    var detail: LocalizedStringKey?
    /// 详细说明（可选）。给了它就说明摘要只留一行，剩下的收进标题旁的 `?` 气泡。
    ///
    /// 起因：设置页原来每一行都配 2–4 行说明，一个开关能占掉四行高度，
    /// 整页像文档而不像设置。QQ 音乐/网易云的常规做法是"一行标签 + 一个问号"。
    var explanation: LocalizedStringKey?
    @State private var showsExplanation = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .flowType(.body)
                        .foregroundStyle(.primary)
                    if explanation != nil {
                        Button {
                            withAnimation(Motion.fade(Motion.micro)) { showsExplanation.toggle() }
                        } label: {
                            flowIcon(systemName: "questionmark.circle", size: 10)
                                .foregroundStyle(FlowColor.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(showsExplanation ? "收起说明" : "说明"))
                    }
                }
                // 默认只显示一行摘要；点 `?` **就地**展开完整说明。
                //
                // 没用 `.popover`：在滚动面板里它没能可靠弹出（实测点了没反应，
                // AX 树里也找不到气泡内容）。就地展开没有这类问题，
                // 而且读屏能直接读到展开后的文字。
                if showsExplanation, let explanation {
                    Text(explanation)
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let detail {
                    Text(detail)
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                        .lineLimit(explanation == nil ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.s)
            // 行标题传给右侧控件当无障碍名：开关、下拉都隐藏了自己的标签，
            // 不传的话读屏只念「开关，关」，听不出是哪一项。
            control
                .environment(\.settingsRowTitle, title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRowTitleKey: EnvironmentKey {
    // 不可变的 nil 常量；LocalizedStringKey 没标 Sendable，只能这样声明。
    nonisolated(unsafe) static let defaultValue: LocalizedStringKey? = nil
}

extension EnvironmentValues {
    var settingsRowTitle: LocalizedStringKey? {
        get { self[SettingsRowTitleKey.self] }
        set { self[SettingsRowTitleKey.self] = newValue }
    }
}

private struct SettingsRowLabel: ViewModifier {
    @Environment(\.settingsRowTitle) private var title

    func body(content: Content) -> some View {
        if let title {
            content.accessibilityLabel(Text(title))
        } else {
            content
        }
    }
}

extension View {
    /// 给隐藏了标签的控件补上所在设置行的标题作为无障碍名。
    func settingsRowLabel() -> some View { modifier(SettingsRowLabel()) }
}

/// 一个分区标题 + 若干行。
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: Spacing.s) {
                content
            }
        }
    }
}

private struct SettingsToggle: View {
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        // `Binding(set:)` 要求 `@Sendable`，而这里的回调是视图闭包。
        // AppKit 的 Toggle 只在主线程改值，用 `assumeIsolated` 把这个既成事实说清楚，
        // 而不是把闭包标成 `@Sendable` 骗过编译器。
        Toggle("", isOn: Binding(get: { isOn },
                                 set: { value in MainActor.assumeIsolated { action(value) } }))
            .labelsHidden()
            .settingsRowLabel()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct SettingsSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String
    /// 无障碍名：滑杆本身不带标签，读屏只念数字。
    /// 必须排在 `onChange` **之前**，否则调用点的尾随闭包会落在它身上。
    var accessibilityLabel: String = ""
    let onChange: (Double) -> Void

    var body: some View {
        // 用主界面同一套 `HairlineSlider`（2pt 轨道 + hover 才出现的圆点）。
        // 之前这里用的是系统 `Slider`：白圆点、粗轨道，同一个 App 里出现两种滑杆语言。
        //
        // 另外把数值压到紧贴控件：原来滑块在 x≈1095 结束、数值在 x≈1190，
        // 中间 95pt 空白，眼睛要来回扫。
        HStack(spacing: 6) {
            HairlineSlider(value: Binding(get: { value },
                                          set: { newValue in
                                              MainActor.assumeIsolated { onChange(newValue) }
                                          }),
                           range: range,
                           accessibilityLabel: accessibilityLabel)
                .frame(width: 130)
            Text(format(value))
                .flowType(.timecode)
                .foregroundStyle(FlowColor.tertiaryText)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - 通用

struct GeneralPane: View {
    @Environment(\.app) private var app
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var launchMessage: String?
    @State private var networkEnabled = false
    @State private var hideDockIcon = false
    @State private var launchNeedsApproval = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "启动与常驻") {
                SettingsRow(title: "隐藏 Dock 图标",
                            detail: "只保留菜单栏入口。隐藏后仍可用 ⌃⌥H 或菜单栏唤回播放器。") {
                    SettingsToggle(isOn: hideDockIcon) { value in
                        hideDockIcon = value
                        Task { await app?.settings.setHideDockIcon(value) }
                        NSApp.setActivationPolicy(value ? .accessory : .regular)
                    }
                }
                SettingsRow(title: "开机时自动启动",
                            detail: launchNeedsApproval
                                ? "需要在「系统设置 → 通用 → 登录项」里允许 FLOW。"
                                : launchMessage.map { LocalizedStringKey($0) }) {
                    HStack(spacing: 8) {
                        if launchNeedsApproval {
                            FlowTextButton(title: "打开登录项设置", symbolName: "gearshape") {
                                launchAtLogin.openSystemLoginItems()
                            }
                        }
                        SettingsToggle(isOn: launchAtLogin.isEnabled) { value in
                            do {
                                try launchAtLogin.setEnabled(value)
                                launchMessage = nil
                            } catch {
                                // 未签名构建必然失败：如实报错，不假装成功
                                launchMessage = error.localizedDescription
                            }
                            launchNeedsApproval = launchAtLogin.needsApproval
                        }
                    }
                }
                // 这是个**固定行为**，不是设置项。之前右侧挂着一句「收进菜单栏」，
                // 和旁边的下拉、开关长得一样，用户会去点它。固定行为写进说明里就行。
                SettingsRow(title: "关闭完整播放器时",
                            detail: "点右上角的关闭按钮会收进菜单栏，不退出应用。") {
                    EmptyView()
                }
            }

            SettingsGroup(title: "网络与隐私") {
                SettingsRow(title: "允许联网获取歌词与封面",
                            detail: "关闭后停止一切网络请求；本地目录与已缓存封面、歌词仍可使用。",
                            explanation: "开启时允许已配置的在线音源、媒体服务器及第三方插件访问网络；关闭后应用完全不发起网络请求。") {
                    SettingsToggle(isOn: networkEnabled) { value in
                        networkEnabled = value
                        Task { await app?.setEnableNetwork(value) }
                    }
                }
                SettingsRow(title: "会议时隐藏歌名与歌词",
                            detail: "检测到 Zoom / 腾讯会议 / Teams / 飞书 / 钉钉 等进入前台时，把歌名与歌词遮起来。",
                            explanation: "只看当前在前台的是哪个应用，不记录任何会议内容。打开时使用内置的常见会议应用清单。") {
                    SettingsToggle(isOn: app?.privacy.isMeetingModeEnabled ?? false) { value in
                        app?.privacy.setMeetingModeEnabled(value)
                    }
                }
                SettingsRow(title: "界面语言",
                            detail: "跟随系统语言（简体中文 / English）。应用内不提供单独切换。") {
                    EmptyView()
                }
            }

            SettingsGroup(title: "上手") {
                SettingsRow(title: "新手引导",
                            detail: "第一次打开完整播放器时自动显示一次，用文字和箭头指出各块区域。") {
                    FlowTextButton(title: "重新查看", symbolName: "sparkles") {
                        // 引导画在完整播放器上：先从菜单栏/悬浮形态展开，再请求重看。
                        app?.morph.expand()
                        Onboarding.requestReplay()
                    }
                }
            }
        }
        .onAppear {
            networkEnabled = app?.settings.enableNetwork ?? true
            hideDockIcon = app?.settings.hideDockIcon ?? false
            launchNeedsApproval = launchAtLogin.needsApproval
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从系统设置回来时刷新「待批准」状态。
            launchNeedsApproval = launchAtLogin.needsApproval
        }
    }
}

// MARK: - 在线音乐与多音源

/// 所有音源管理、账号授权、音质与离线缓存收在一处。
private struct OnlineMusicPane: View {
    @Environment(\.app) private var app
    @State private var cacheSize: String = "…"
    @State private var fadeEnabled = AudioFade.isEnabled
    @State private var importMessage: String?
    @State private var presetErrorMessage: String?
    @State private var loadingPresetIDs: Set<String> = []
    @State private var isEnablingAllPresets = false
    @State private var showsServerSheet = false
    @State private var showsURLImportSheet = false
    @State private var showsGitHubSearchSheet = false
    @State private var editingVariablesSource: SourceManager.ManagedSource?
    @State private var confirmsClearOffline = false
    @State private var sourcePendingRemoval: SourceManager.ManagedSource?

    private var managedSources: [SourceManager.ManagedSource] {
        (app?.sourceManager.sources ?? []).filter { $0.id != .mock }
    }

    private var pendingRemovalName: String { sourcePendingRemoval?.descriptor.displayName ?? "" }
    private var offlineCountText: String { String(app?.offline.tracks.count ?? 0) }
    private var offlineSizeText: String { Self.format(app?.offline.totalBytes ?? 0) }

    private var activeAccountSource: SourceManager.ManagedSource? {
        guard let manager = app?.sourceManager else { return nil }
        if let active = manager.activeBrowseSource, active.accountController != nil {
            return active
        }
        return managedSources.first { $0.isEnabled && $0.accountController != nil }
    }

    private var variableCredentialSource: SourceManager.ManagedSource? {
        guard let manager = app?.sourceManager else { return nil }
        if let active = manager.activeBrowseSource,
           !manager.userVariableSpecs(for: active.id).isEmpty {
            return active
        }
        return managedSources.first {
            $0.isEnabled && !manager.userVariableSpecs(for: $0.id).isEmpty
        }
    }

    private var qualityController: (any QualitySelectableSourceController)? {
        if let playingSourceID = app?.playback.currentTrack?.sourceID,
           let playing = app?.sourceManager.managedSource(for: playingSourceID),
           playing.isEnabled,
           let controller = playing.qualityController {
            return controller
        }
        return app?.sourceManager.activeQualityController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "音源管理") {
                if managedSources.isEmpty {
                    SettingsRow(title: "当前未配置可用音源",
                                detail: "可导入本地音频目录、标准服务器或第三方音源脚本 / JSON 模板。") {
                        FlowCaption(text: "0 个音源")
                    }
                } else {
                    ForEach(managedSources) { source in
                        SettingsRow(title: LocalizedStringKey(source.descriptor.displayName),
                                    detail: LocalizedStringKey(sourceDetail(source))) {
                            HStack(spacing: 8) {
                                if app?.sourceManager.activeBrowseSource?.id == source.id {
                                    FlowCaption(text: "当前浏览")
                                } else if source.isEnabled {
                                    FlowTextButton(title: "设为主页", symbolName: "house") {
                                        app?.sourceManager.selectActiveBrowseSource(source.id)
                                    }
                                }
                                SettingsToggle(isOn: source.isEnabled) { value in
                                    app?.sourceManager.setSourceEnabled(source.id, enabled: value)
                                }
                                if let specs = app?.sourceManager.userVariableSpecs(for: source.id), !specs.isEmpty {
                                    FlowIconButton(systemName: "key.horizontal", label: "配置音源参数", size: 28, symbolSize: 13) {
                                        editingVariablesSource = source
                                    }
                                }
                                if !source.isBuiltIn {
                                    FlowIconButton(systemName: "trash", label: "移除音源", size: 28, symbolSize: 13) {
                                        sourcePendingRemoval = source
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsRow(title: "本地音乐目录",
                            detail: "从本机磁盘扫描音频文件，自动解析内嵌封面与同目录 LRC 歌词。") {
                    HStack(spacing: 8) {
                        FlowTextButton(title: "添加文件夹…", symbolName: "folder.badge.plus") {
                            pickAndAddLocalLocations(directories: true, files: true)
                        }
                    }
                }

                SettingsRow(title: "媒体服务器",
                            detail: "连接 OpenSubsonic / Navidrome 或 WebDAV 网络曲库，密码安全存入 Keychain。") {
                    FlowTextButton(title: "添加服务器…", symbolName: "server.rack") {
                        showsServerSheet = true
                    }
                }

                SettingsRow(title: "导入第三方音源",
                            detail: "支持兼容 CommonJS 的 `.js` 音源插件及声明式 `.json` 接口模板。") {
                    HStack(spacing: 8) {
                        // 提示文字出现后会挤占宽度；按钮文字不能被压成逐字竖排。
                        FlowTextButton(title: "通过 URL 导入…", symbolName: "link.badge.plus") {
                            showsURLImportSheet = true
                        }
                        .fixedSize()
                        FlowTextButton(title: "选择文件导入", symbolName: "square.and.arrow.down") {
                            pickAndImportSourceFile()
                        }
                        .fixedSize()
                    }
                }

                if let importMessage {
                    FlowCaption(verbatim: importMessage)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            SettingsGroup(title: "自动获取与扩展预设") {
                Text("默认均未启用；可通过 GitHub 自动搜索发现，或按需获取并启用推荐社区扩展与开放 API 源。")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRow(title: "GitHub 自动搜源",
                            detail: "搜索公开仓库或输入 owner/repo，自动发现并导入插件与 JSON 配置。") {
                    FlowTextButton(title: "从 GitHub 搜索…", symbolName: "magnifyingglass") {
                        showsGitHubSearchSheet = true
                    }
                    .fixedSize()
                }

                SettingsRow(title: "一键获取推荐扩展源",
                            detail: "自动从外置目录或 GitHub 获取并启用全部推荐外部预设与开放 API 源。") {
                    HStack(spacing: 8) {
                        if isEnablingAllPresets {
                            ProgressView().controlSize(.small)
                        }
                        FlowTextButton(
                            title: isEnablingAllPresets ? "获取中…" : "一键获取并启用",
                            symbolName: "sparkles"
                        ) {
                            enableAllRecommendedPresets()
                        }
                        .fixedSize()
                        .disabled(isEnablingAllPresets || !loadingPresetIDs.isEmpty)
                    }
                }

                ForEach(app?.sourceManager.availableAPIPresets ?? ExternalAPIPresetCatalog.presets) { preset in
                    let isEnabled = app?.sourceManager.isPresetEnabled(preset) ?? false
                    let isLoading = loadingPresetIDs.contains(preset.id)
                    let origin = app?.sourceManager.presetOriginDescription(preset) ?? preset.localizedOriginBadge
                    let detail = "\(preset.localizedSummary) · \(origin)"
                    SettingsRow(title: LocalizedStringKey(preset.localizedDisplayName),
                                detail: LocalizedStringKey(detail)) {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            }
                            SettingsToggle(isOn: isEnabled) { newValue in
                                togglePreset(preset, enabled: newValue)
                            }
                            .disabled(isLoading || isEnablingAllPresets)
                        }
                    }
                }

                if let presetErrorMessage {
                    HStack(spacing: Spacing.s) {
                        FlowCaption(verbatim: presetErrorMessage)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if let app, !app.settings.enableNetwork {
                            FlowTextButton(title: "允许联网", symbolName: "network") {
                                Task {
                                    await app.setEnableNetwork(true)
                                    self.presetErrorMessage = nil
                                }
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "账号") {
                accountSection
            }

            SettingsGroup(title: "音质") {
                qualitySection
            }

            SettingsGroup(title: "播放与缓存") {
                SettingsRow(title: "切歌淡入淡出",
                            detail: "切歌时 0.12 秒淡入淡出，避免在线歌曲起播时的爆音。") {
                    SettingsToggle(isOn: fadeEnabled) { value in
                        fadeEnabled = value
                        AudioFade.isEnabled = value
                    }
                }
                SettingsRow(title: "电台连播",
                            detail: "一首放完自动接相关歌曲；全部播过就停下，不会随便重播。") {
                    SettingsToggle(isOn: app?.relatedRadio.isEnabled ?? true) { value in
                        app?.relatedRadio.setEnabled(value)
                    }
                }
                SettingsRow(title: "离线缓存",
                            detail: "听过的在线歌曲会缓存下来再次使用；换音质后会重新下载。") {
                    HStack(spacing: Spacing.s) {
                        FlowCaption(verbatim: cacheSize)
                        FlowTextButton(title: "清理", symbolName: "trash") {
                            Task {
                                await MediaAudioCache.shared.clear()
                                cacheSize = await Self.measureCacheSize()
                            }
                        }
                    }
                }
                SettingsRow(title: "永久离线",
                            detail: "显式离线保存的曲目永久保留，不参与 500 MB 自动清理。") {
                    HStack(spacing: Spacing.s) {
                        HStack(spacing: 4) {
                            Text("\(app?.offline.tracks.count ?? 0) 首")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                            FlowCaption(verbatim: "· \(Self.format(app?.offline.totalBytes ?? 0))")
                        }
                        FlowTextButton(title: "清理", symbolName: "trash") {
                            confirmsClearOffline = true
                        }
                        .disabled(app?.offline.tracks.isEmpty ?? true)
                    }
                }
            }
        }
        .confirmationDialog(
            "移除音源「\(pendingRemovalName)」？",
            isPresented: Binding(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            )
        ) {
            Button("移除", role: .destructive) {
                if let source = sourcePendingRemoval {
                    app?.sourceManager.removeConfiguredSource(source.id)
                }
                sourcePendingRemoval = nil
            }
            Button("取消", role: .cancel) { sourcePendingRemoval = nil }
        } message: {
            Text(sourcePendingRemoval?.id == .localFile
                 ? "会移除全部本地音乐目录，不会删除你电脑上的音乐文件。"
                 : "会删除这个音源的配置和保存的账号信息，之后需要重新添加。")
        }
        .confirmationDialog("删除全部离线歌曲？", isPresented: $confirmsClearOffline) {
            Button("全部删除", role: .destructive) {
                Task {
                    await app?.offline.clearAll()
                    cacheSize = await Self.measureCacheSize()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(offlineCountText) 首离线保存的歌曲（\(offlineSizeText)），之后需要联网重新下载。")
        }
        .task {
            cacheSize = await Self.measureCacheSize()
            _ = await app?.offline.refresh()
        }
        .task(id: activeAccountSource?.id) {
            if let controller = activeAccountSource?.accountController {
                await controller.refreshAuthStatus()
            }
        }
        .onChange(of: activeAccountSource?.accountController?.authState) { oldValue, newValue in
            guard case .signedIn = newValue else { return }
            // 仅在主动扫码登录完成时刷新流；打开设置页刷新已登录状态不应打断当前播放。
            let wasActivelySigningIn: Bool = switch oldValue {
            case .showingQR, .scanned: true
            default: false
            }
            guard wasActivelySigningIn,
                  let sourceID = activeAccountSource?.id,
                  let playback = app?.playback else { return }
            if playback.state != .idle,
               !playback.isPlayingVoiceAI,
               playback.currentTrack?.sourceID == sourceID {
                Task {
                    await playback.reloadAudioSource(autoplayIfInactive: false)
                }
            } else {
                playback.invalidatePrewarm()
            }
        }
        .sheet(isPresented: $showsServerSheet) {
            ServerSourceSheet { config, password in
                try await app?.sourceManager.addServerSource(config, password: password)
                importMessage = String(localized: "已连接：\(config.displayName)")
            }
        }
        .sheet(isPresented: $showsURLImportSheet) {
            URLSourceImportSheet { url in
                if let list = try await app?.sourceManager.importSources(from: url) {
                    recordImportResult(list)
                }
            }
        }
        .sheet(isPresented: $showsGitHubSearchSheet) {
            GitHubSourceSearchSheet { list, _ in
                recordImportResult(list)
            }
        }
        .sheet(item: $editingVariablesSource) { target in
            let specs = app?.sourceManager.userVariableSpecs(for: target.id) ?? []
            let existing = app?.sourceManager.userVariableValues(for: target.id) ?? [:]
            PluginVariablesSheet(
                sourceTitle: target.descriptor.displayName,
                specs: specs,
                initialValues: existing
            ) { updated in
                app?.sourceManager.updateJSPluginVariables(sourceID: target.id, values: updated)
                importMessage = String(localized: "已保存音源参数")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let source = activeAccountSource, let controller = source.accountController {
            let state = controller.authState
            let isSigningIn: Bool = switch state {
            case .showingQR, .scanned: true
            default: false
            }

            SettingsRow(title: LocalizedStringKey(source.descriptor.displayName),
                        detail: "登录后可用于读取该源的个人收藏、同步列表或按账号权限选择音质。") {
                HStack(spacing: 8) {
                    switch state {
                    case .signedIn(let summary, _):
                        FlowCaption(verbatim: summary)
                        FlowTextButton(title: "退出登录", symbolName: "rectangle.portrait.and.arrow.right") {
                            controller.signOut()
                            app?.playback.invalidatePrewarm()
                        }
                    case .signedOut, .showingQR, .scanned, .expired, .failed:
                        FlowCaption(text: "未登录")
                        if controller.supportsQRLogin {
                            FlowTextButton(title: isSigningIn ? "取消" : "登录", symbolName: "qrcode") {
                                if isSigningIn {
                                    controller.cancelLogin()
                                } else {
                                    Task { await controller.beginQRLogin() }
                                }
                            }
                        }
                    }
                }
            }

            if case .showingQR(let url, let hint) = state,
               let image = QRImageRenderer.make(for: url) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("扫码登录").flowType(.body).foregroundStyle(.primary)
                    Text("请使用对应平台的移动端扫描下面的二维码，确认后自动完成登录。")
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .center, spacing: 14) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityLabel("登录二维码")
                        VStack(alignment: .leading, spacing: 8) {
                            FlowCaption(verbatim: hint)
                            FlowTextButton(title: "取消登录", symbolName: "xmark") {
                                controller.cancelLogin()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else if case .scanned(let hint) = state {
                SettingsRow(title: "扫码登录", detail: "已扫码，请在移动端确认登录。") {
                    FlowCaption(verbatim: hint)
                }
            } else if case .expired(let hint) = state {
                retryQRRow(hint: hint, controller: controller)
            } else if case .failed(let hint) = state {
                retryQRRow(hint: hint, controller: controller)
            }

            if case .signedIn(_, let detail?) = state {
                SettingsRow(title: "账号状态",
                            detail: "音质与个人曲库权限由当前音源账号决定。") {
                    FlowCaption(verbatim: detail)
                }
            }
        } else if let credSource = variableCredentialSource {
            SettingsRow(title: LocalizedStringKey(credSource.descriptor.displayName),
                        detail: "该插件未提供扫码登录，可在音源参数中填写登录凭据（Cookie），或导入支持扫码登录的音源插件。") {
                FlowTextButton(title: "配置凭据", symbolName: "key.horizontal") {
                    editingVariablesSource = credSource
                }
            }
        } else {
            SettingsRow(title: "当前账号",
                        detail: "当前选中的音源无需账号授权，或在配置界面直接绑定凭据。") {
                FlowCaption(text: "无需登录")
            }
        }
    }

    private func retryQRRow(hint: String, controller: any SourceAccountController) -> some View {
        SettingsRow(title: "扫码登录", detail: "二维码没有生成出来，或已经失效。") {
            HStack(spacing: 8) {
                FlowCaption(verbatim: hint)
                FlowTextButton(title: "重新生成", symbolName: "arrow.clockwise") {
                    Task { await controller.beginQRLogin() }
                }
            }
        }
    }

    @ViewBuilder
    private var qualitySection: some View {
        let currentTier = qualityController?.currentQualityTier
            ?? (AudioQualityTier(rawValue: app?.settings.preferredQualityRaw ?? "") ?? .auto)
        let declared = qualityController?.availableQualityTiers ?? AudioQualityTier.allCases
        // 插件声明的档位里往往没有「自动」；当前值不在选项里时 Picker 会显示成空白、也选不中。
        let options = declared.contains(currentTier) ? declared : [currentTier] + declared
        let detail = qualityController?.qualityRequirementHint(for: currentTier)
            ?? String(localized: "偏好播放音质会应用于支持多档音轨的音源。")

        SettingsRow(title: "播放音质", detail: LocalizedStringKey(detail)) {
            Picker("", selection: Binding(
                get: { currentTier },
                set: { newValue in
                    guard newValue != currentTier else { return }
                    Task {
                        await app?.settings.setPreferredQualityRaw(newValue.rawValue)
                        await app?.sourceManager.applyPreferredQuality(newValue)
                        guard let playback = app?.playback else { return }
                        if playback.state != .idle,
                           !playback.isPlayingVoiceAI,
                           let currentSourceID = playback.currentTrack?.sourceID,
                           app?.sourceManager.managedSource(for: currentSourceID)?.qualityController != nil {
                            await playback.reloadAudioSource(autoplayIfInactive: false)
                        } else {
                            playback.invalidatePrewarm()
                        }
                    }
                }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(LocalizedStringKey(option.displayName)).tag(option)
                }
            }
            .labelsHidden()
            .settingsRowLabel()
            .frame(width: 150)
        }
        SettingsRow(title: "当前实际音质",
                    detail: "这是正在播放的歌曲实际拿到的格式与码率。") {
            FlowCaption(verbatim: qualityController?.lastActualQualityText ?? String(localized: "尚未播放"))
        }
    }

    private func sourceDetail(_ source: SourceManager.ManagedSource) -> String {
        let kindText: String = switch source.descriptor.kind {
        case .builtinLocal: String(localized: "本地目录")
        case .standardServer: String(localized: "标准媒体服务器")
        case .jsPlugin: String(localized: "JS 音源插件")
        case .jsonTemplate: String(localized: "JSON 接口模板")
        case .builtinLegacy: String(localized: "内置适配源")
        case .mock: String(localized: "模拟源")
        }
        if !source.descriptor.requiresNetwork {
            return "\(kindText) · \(String(localized: "本地离线可用"))"
        }
        if source.descriptor.allowedDomains.isEmpty {
            return "\(kindText) · \(String(localized: "需要联网"))"
        }
        return "\(kindText) · \(source.descriptor.allowedDomains.joined(separator: ", "))"
    }

    private func pickAndAddLocalLocations(directories: Bool, files: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = true
        if files {
            panel.allowedContentTypes = [.audio]
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let selectedURLs = panel.urls
        Task {
            await app?.sourceManager.openLocalAudioURLs(selectedURLs)
            importMessage = String(localized: "已扫描本地音源")
        }
    }

    private func pickAndImportSourceFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json, UTType(filenameExtension: "js")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                if let list = try await app?.sourceManager.importSources(from: url) {
                    recordImportResult(list)
                }
            } catch {
                importMessage = SourceErrorPresentation.friendly(error)
            }
        }
    }

    private func recordImportResult(_ list: [SourceManager.ManagedSource]) {
        if list.count > 1 {
            importMessage = String(localized: "已导入 \(list.count) 个音源")
        } else if let first = list.first {
            importMessage = String(localized: "已导入：\(first.descriptor.displayName)")
        }
    }

    private func togglePreset(_ preset: ExternalAPIPreset, enabled: Bool) {
        guard let manager = app?.sourceManager else { return }
        presetErrorMessage = nil
        if !enabled {
            Task {
                _ = try? await manager.setPresetEnabled(preset, enabled: false)
            }
            return
        }
        loadingPresetIDs.insert(preset.id)
        Task {
            defer { loadingPresetIDs.remove(preset.id) }
            do {
                if let source = try await manager.setPresetEnabled(preset, enabled: true) {
                    importMessage = String(localized: "已启用：\(source.descriptor.displayName)")
                }
            } catch let playbackError as PlaybackError where playbackError == .networkDisabled {
                presetErrorMessage = String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再从外部获取。")
            } catch let violation as SourceDomainPolicy.Violation {
                if case .networkDisabled = violation {
                    presetErrorMessage = String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再从外部获取。")
                } else {
                    presetErrorMessage = SourceErrorPresentation.friendly(violation)
                }
            } catch {
                presetErrorMessage = SourceErrorPresentation.friendly(error)
            }
        }
    }

    private func enableAllRecommendedPresets() {
        guard let manager = app?.sourceManager else { return }
        presetErrorMessage = nil
        isEnablingAllPresets = true
        let presets = manager.availableAPIPresets
        Task {
            defer { isEnablingAllPresets = false }
            var enabledCount = 0
            var firstError: (any Error)?
            for preset in presets {
                loadingPresetIDs.insert(preset.id)
                defer { loadingPresetIDs.remove(preset.id) }
                do {
                    if try await manager.setPresetEnabled(preset, enabled: true) != nil {
                        enabledCount += 1
                    }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if enabledCount > 0 {
                importMessage = String(localized: "已启用 \(enabledCount) 个外部预设音源")
            }
            if let firstError {
                if let playbackError = firstError as? PlaybackError, playbackError == .networkDisabled {
                    presetErrorMessage = String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再从外部获取。")
                } else if let violation = firstError as? SourceDomainPolicy.Violation, case .networkDisabled = violation {
                    presetErrorMessage = String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再从外部获取。")
                } else {
                    presetErrorMessage = SourceErrorPresentation.friendly(firstError)
                }
            }
        }
    }

    private static func measureCacheSize() async -> String {
        format(await MediaAudioCache.shared.totalSize())
    }

    private static func format(_ bytes: Int64) -> String {
        ByteText.size(bytes)
    }
}

/// 新增 OpenSubsonic / Navidrome / WebDAV 服务器配置弹窗。
private struct ServerSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (ServerSourceConfig, String) async throws -> Void

    @State private var kind: ServerSourceConfig.ProtocolKind = .openSubsonic
    @State private var displayName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加媒体服务器")
                .flowType(.homeTitle)

            Picker("协议类型", selection: $kind) {
                ForEach(ServerSourceConfig.ProtocolKind.allCases, id: \.self) { item in
                    Text(verbatim: item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                TextField("显示名称（如 家庭 Navidrome）", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                TextField("服务器地址（如 https://music.example.com）", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码 / Token", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                FlowCaption(verbatim: errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    saveTask?.cancel()
                    dismiss()
                }
                Spacer()
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                Button("测试并添加") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || ServerSourceConfig.normalizedBaseURL(from: serverURL) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { saveTask?.cancel() }
    }

    private func save() {
        errorMessage = nil
        isTesting = true
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ServerSourceConfig(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            displayName: name.isEmpty ? kind.displayName : name,
            baseURLString: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saveTask = Task {
            defer { isTesting = false }
            do {
                try await onSave(config, password)
                dismiss()
            } catch is CancellationError {
            } catch PlaybackError.networkDisabled {
                // 通用文案说的是"打开后就能播放"，放在添加服务器的表单里答非所问。
                errorMessage = String(localized: "联网已关闭，无法测试连接。到 设置 → 通用 打开「允许联网」后再添加。")
            } catch {
                errorMessage = SourceErrorPresentation.friendly(error)
            }
        }
    }
}

/// 通过 HTTPS 链接或订阅地址导入第三方 `.js` / `.json` 音源。
private struct URLSourceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (URL) async throws -> Void

    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?

    private var parsedURL: URL? {
        guard let url = SourceDomainPolicy.normalizeImportURL(urlText),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "file" else {
            return nil
        }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通过 URL 导入第三方音源")
                .flowType(.homeTitle)

            Text("粘贴 `.js` 音源插件、`.json` 接口模板或插件订阅清单的链接。插件仅能在声明的白名单域名内发起网络请求，并遵守应用联网开关。")
                .flowType(.caption)
                .foregroundStyle(FlowColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/plugins.json 或 source.js", text: $urlText)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                FlowCaption(verbatim: errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    importTask?.cancel()
                    dismiss()
                }
                Spacer()
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Button("导入") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { importTask?.cancel() }
    }

    private func runImport() {
        guard let url = parsedURL else { return }
        errorMessage = nil
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            do {
                try await onImport(url)
                dismiss()
            } catch is CancellationError {
            } catch PlaybackError.networkDisabled {
                errorMessage = String(localized: "联网已关闭，无法下载音源。到 设置 → 通用 打开「允许联网」后再导入。")
            } catch {
                errorMessage = SourceErrorPresentation.friendly(error)
            }
        }
    }
}

/// 编辑第三方插件声明的用户参数（对应 MusicFree `userVariables` 协议），写入沙盒安全存储。
private struct PluginVariablesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceTitle: String
    let specs: [JSPluginUserVariable]
    let onSave: ([String: String]) -> Void

    @State private var values: [String: String]

    init(sourceTitle: String,
         specs: [JSPluginUserVariable],
         initialValues: [String: String],
         onSave: @escaping ([String: String]) -> Void) {
        self.sourceTitle = sourceTitle
        self.specs = specs
        self.onSave = onSave
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配置「\(sourceTitle)」参数")
                .flowType(.homeTitle)

            ForEach(specs) { spec in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: spec.name)
                        .flowType(.body)
                    let binding = Binding<String>(
                        get: { values[spec.key] ?? "" },
                        set: { values[spec.key] = $0 }
                    )
                    if spec.isSecret {
                        SecureField(spec.hint ?? spec.name, text: binding)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(spec.hint ?? spec.name, text: binding)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let hint = spec.hint, !hint.isEmpty {
                        FlowCaption(verbatim: hint)
                    }
                }
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    onSave(values)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 外观

private struct AppearancePane: View {
    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "歌词") {
                SettingsRow(title: "歌词版式",
                            detail: "滚动：整段随播放推进、当前行放大。",
                            explanation: "滚动歌词是 Apple Music 风格：当前行居中放大、整段随播放推进并带弹簧跃动。编辑式只显示当前行与前后两行。") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.lyricLayout ?? .appleMusic },
                        set: { app?.appearance.setLyricLayout($0) }
                    )) {
                        ForEach(LyricLayout.allCases, id: \.self) { layout in
                            Text(LocalizedStringKey(layout.displayName)).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
            }

            // 只留一行说明：怎么进、怎么出。场景名本身就是描述，不再逐项解释。
            SettingsGroup(title: "沉浸模式") {
                SettingsRow(title: "播放页背景") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.playerBackground ?? .default },
                        set: { app?.appearance.setPlayerBackground($0) }
                    )) {
                        ForEach(PlayerBackground.allCases, id: \.self) { background in
                            Text(LocalizedStringKey(background.displayName)).tag(background)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityIdentifier("settings.playerBackground")
                }
                SettingsRow(title: "场景", detail: "在完整播放器里点 ⤢ 进入，按 Esc 退出。") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.immersiveScene ?? .default },
                        set: { app?.appearance.setImmersiveScene($0) }
                    )) {
                        ForEach(ImmersiveSceneKind.allCases, id: \.self) { scene in
                            Text(LocalizedStringKey(scene.displayName)).tag(scene)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityIdentifier("settings.immersive.scene")
                }
                SettingsRow(title: "随音乐变化") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.immersiveResponse ?? .default },
                        set: { app?.appearance.setImmersiveResponse($0) }
                    )) {
                        ForEach(ImmersiveResponse.allCases, id: \.self) { response in
                            Text(LocalizedStringKey(response.displayName)).tag(response)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityIdentifier("settings.immersive.response")
                }
                SettingsRow(title: "节拍联动") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.immersiveBeatSync ?? .default },
                        set: { app?.appearance.setImmersiveBeatSync($0) }
                    )) {
                        ForEach(ImmersiveBeatSync.allCases, id: \.self) { level in
                            Text(LocalizedStringKey(level.displayName)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityIdentifier("settings.immersive.beatSync")
                }
                SettingsRow(title: "进入时全屏") {
                    SettingsToggle(isOn: app?.appearance.immersiveEntersFullScreen ?? true) { value in
                        app?.appearance.setImmersiveEntersFullScreen(value)
                    }
                    .accessibilityIdentifier("settings.immersive.fullScreen")
                }
                SettingsRow(title: "省电（降低帧率）") {
                    SettingsToggle(isOn: app?.appearance.immersivePowerSaving ?? false) { value in
                        app?.appearance.setImmersivePowerSaving(value)
                    }
                    .accessibilityIdentifier("settings.immersive.powerSaving")
                }
            }

            SettingsGroup(title: "悬浮层") {
                SettingsRow(title: "悬浮深浅外观",
                            detail: "按播放器所在区域的壁纸亮度自动切换文字深浅。",
                            explanation: "浅背景用深色字，深背景用浅色字。背景无法判定时跟随系统外观，并给卡片加一层实底保证可读性。") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.floatingAppearance ?? .background },
                        set: { app?.morph.applyFloatingAppearance($0) }
                    )) {
                        ForEach(FloatingAppearanceMode.allCases, id: \.self) { mode in
                            Text(LocalizedStringKey(mode.displayName)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
                SettingsRow(title: "悬浮不透明度",
                            detail: "只作用于迷你条、胶囊与贴边；完整播放器始终不透明。") {
                    SettingsSlider(value: app?.appearance.floatingOpacity ?? 0.95,
                                   range: 0.3...1,
                                   format: { String(format: "%.0f%%", $0 * 100) },
                                   accessibilityLabel: "悬浮不透明度") { value in
                        app?.appearance.setFloatingOpacity(value)
                        app?.morph.applyFloatingOpacity(value)
                    }
                }
            }

            SettingsGroup(title: "动效") {
                SettingsRow(title: "形态过渡速度",
                            detail: "0.5× 更舒缓、1.5× 更利落。只影响形态变形与歌词排布切换的时长。",
                            explanation: "只影响形态变形与歌词排布切换的时长，不影响音频淡入淡出。0.5× 更舒缓，1.5× 更利落。") {
                    SettingsSlider(value: app?.appearance.morphTransitionSpeed ?? 1,
                                   range: 0.5...1.5,
                                   format: { String(format: "%.1f×", $0) },
                                   accessibilityLabel: "形态过渡速度") { value in
                        app?.appearance.setMorphTransitionSpeed(value)
                    }
                }
                SettingsRow(title: "减少动态效果",
                            detail: "跟随系统的「减弱动态效果」开关。",
                            explanation: "开启时不播放变形动画，只保留很短的淡入淡出，避免大幅运动引起不适。") {
                    FlowCaption(text: systemReduceMotion ? "系统已开启" : "系统未开启")
                }
            }
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    /// 只在"数据被恢复过 / 损坏被隔离过"时返回文案；正常情况不占版面。
    private func storageNoticeText(for app: AppContainer) -> String? {
        // 降级模式优先：它比"从备份恢复"更严重——这次运行根本不写盘。
        if let reason = app.degradedReason { return reason }
        let state = AppContainer.storageState(for: app.persistence)
        return state == "正常" ? nil : state
    }

    @Environment(\.app) private var app
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "关于 FLOW") {
                SettingsRow(title: "FLOW",
                            detail: "一件能在桌面上舒展、收缩、折叠的界面。歌词跟着你，不打断你。") {
                    FlowCaption(verbatim: "版本 \(version)")
                }
                SettingsRow(title: "软件更新",
                            detail: "手动向 GitHub Releases 查询新版本，仅在点击时联网。") {
                    if app?.updateChecker.state == .checking {
                        HStack(spacing: Spacing.xxs) {
                            ProgressView()
                                .controlSize(.small)
                            FlowCaption(text: "检查中…")
                        }
                    } else {
                        FlowTextButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath") {
                            Task { await app?.updateChecker.checkForUpdates() }
                        }
                    }
                }
                if let updateState = app?.updateChecker.state {
                    updateStatusView(for: updateState)
                }
                SettingsRow(title: "音源",
                            detail: "内置本地目录与标准媒体服务器协议，并支持通过插件或 JSON 模板自由扩展。") {
                    EmptyView()
                }
                SettingsRow(title: "隐私",
                            detail: "不录屏、不读键盘输入；账号密码只存在系统钥匙串里。自动避让只读取窗口位置和大小，不读窗口内容。") {
                    EmptyView()
                }
                SettingsRow(title: "开源组件",
                            detail: "FLOW Voice 原生推理采用 MIT 许可的 Microsoft ONNX Runtime (v1.32.0)。") {
                    EmptyView()
                }
            }

            // 数据被从备份恢复过、或库损坏被隔离过——这种事必须让用户看见，
            // 而不是只藏在"复制诊断"的文本里（第 119 节的演练就发现了这个空洞）。
            if let app, let state = storageNoticeText(for: app) {
                SettingsGroup(title: "本地数据") {
                    // `detail` 是 `LocalizedStringKey`，而这里是要展示的**运行时字符串**，
                    // 所以放在内容位而不是 detail（否则会被当成 key 去查表）。
                    SettingsRow(title: "存储状态") {
                        Text(state)
                            .flowType(.caption)
                            .foregroundStyle(FlowColor.secondaryText)
                    }
                }
            }

            SettingsGroup(title: "支持") {
                SettingsRow(title: "诊断信息",
                            detail: "包含版本、系统、权限、队列数量与存储状态，不含歌词、曲目与文件路径。") {
                    FlowTextButton(title: copied ? "已复制" : "复制", symbolName: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app?.diagnosticsReport() ?? "", forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
                SettingsRow(title: "数据位置",
                            detail: "曲目库、封面缓存、播放记录都在这个目录里。") {
                    FlowTextButton(title: "在 Finder 中显示", symbolName: "folder") {
                        guard let url = try? PersistenceController.storeURL() else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }

            SettingsGroup(title: "致谢与许可") {
                SettingsRow(title: "开源许可",
                            detail: "FLOW 以 MIT 许可开源。") {
                    EmptyView()
                }
                SettingsRow(title: "第三方组件",
                            detail: "AI 翻唱使用 ONNX Runtime（MIT 许可，© Microsoft）；其余基于 Apple 系统框架。",
                            explanation: "界面与播放基于 SwiftUI / AVFoundation，存储使用 SwiftData，第三方扩展通过系统自带 JavaScriptCore 隔离执行，在线歌词来自用户导入源或公共歌词库；本地 AI 翻唱的模型推理由内嵌的 ONNX Runtime 完成。") {
                    HStack(spacing: Spacing.xxs) {
                        if let license = Bundle.main.url(forResource: "ONNXRuntime-LICENSE", withExtension: "txt") {
                            FlowTextButton(title: "查看许可", symbolName: "doc.text") {
                                NSWorkspace.shared.open(license)
                            }
                        }
                        // ONNX Runtime 静态链接了 protobuf、abseil、Eigen 等，它们的声明必须随二进制一起提供。
                        if let notices = Bundle.main.url(forResource: "ONNXRuntime-ThirdPartyNotices", withExtension: "txt") {
                            FlowTextButton(title: "第三方声明", symbolName: "doc.plaintext") {
                                NSWorkspace.shared.open(notices)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func updateStatusView(for state: AppUpdateState) -> some View {
        switch state {
        case .idle, .checking:
            EmptyView()
        case .upToDate(let current):
            Text(String(localized: "当前已是最新版本（v\(current)）"))
                .flowType(.caption)
                .foregroundStyle(FlowColor.secondaryText)
        case .updateAvailable(let info):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "发现新版本 \(info.tagName)"))
                    .flowType(.caption)
                    .foregroundStyle(.primary)
                if let summary = info.summary {
                    Text(verbatim: summary)
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.xxs) {
                    if let downloadURL = info.downloadURL {
                        FlowTextButton(title: "下载安装包", symbolName: "arrow.down.circle") {
                            NSWorkspace.shared.open(downloadURL)
                        }
                    }
                    FlowTextButton(title: "前往发布页", symbolName: "safari") {
                        NSWorkspace.shared.open(info.releaseURL)
                    }
                }
            }
            .padding(.top, 2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(verbatim: message)
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.xxs) {
                    if let app, !app.settings.enableNetwork {
                        FlowTextButton(title: "允许联网", symbolName: "network") {
                            Task {
                                await app.setEnableNetwork(true)
                                await app.updateChecker.checkForUpdates()
                            }
                        }
                    }
                    FlowTextButton(title: "前往发布页", symbolName: "safari") {
                        NSWorkspace.shared.open(AppUpdateChecker.releasesPageURL)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - 形态

private struct MorphologyPane: View {
    @Environment(\.app) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "形态") {
                SettingsRow(title: "冷启动形态",
                            detail: "第一次打开、或没有记住上次形态时使用这个形态。") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.defaultMorphology ?? .expanded },
                        set: { app?.appearance.setDefaultMorphology($0) }
                    )) {
                        ForEach(PlayerMorphology.allCases, id: \.self) { morphology in
                            Text(LocalizedStringKey(morphology.displayName)).tag(morphology)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
                SettingsRow(title: "锁定当前形态",
                            detail: "锁定后只有用户操作能改变形态，系统不再自动收缩。") {
                    SettingsToggle(isOn: app?.morph.isMorphologyLocked ?? false) { _ in
                        app?.morph.toggleMorphologyLock()
                    }
                }
                SettingsRow(title: "悬浮歌词排布",
                            detail: "决定悬浮形态里显示几行：单行 / 双行 / 歌词板。") {
                    Picker("", selection: Binding(
                        get: { app?.morph.floatingShape ?? .capsule },
                        set: { app?.morph.setFloatingShape($0) }
                    )) {
                        ForEach(LyricsShape.allCases, id: \.self) { shape in
                            Text(LocalizedStringKey(shape.displayName)).tag(shape)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
            }

            SettingsGroup(title: "自动变形") {
                SettingsRow(title: "按空间自动变形",
                            detail: "关闭后只有用户操作能改形态；空间变化不再引起收缩或降级。") {
                    SettingsToggle(isOn: app?.appearance.autoMorphEnabled ?? true) { value in
                        app?.appearance.setAutoMorphEnabled(value)
                    }
                }
                SettingsRow(title: "切到别的应用时收缩",
                            detail: "失去焦点时自动收成迷你条。",
                            explanation: "开启后切走会从完整形态收成迷你条，切回来再展开。想一边听一边在别处工作时关掉它。") {
                    SettingsToggle(isOn: app?.appearance.autoCollapseOnDeactivate ?? false) { value in
                        app?.appearance.setAutoCollapseOnDeactivate(value)
                    }
                }
                SettingsRow(title: "自动避让前台窗口",
                            detail: "关闭后只遵守屏幕安全区，不再回避其他应用窗口。需要辅助功能授权。") {
                    SettingsToggle(isOn: app?.appearance.autoAvoidEnabled ?? true) { value in
                        app?.appearance.setAutoAvoidEnabled(value)
                        app?.floatingLyrics.applyAutoAvoid(value)
                    }
                }
                SettingsRow(title: "空间变多时",
                            detail: LocalizedStringKey(
                                (AutoExpandPolicy(rawValue: app?.appearance.autoExpandPolicyRaw ?? "balanced")
                                 ?? .balanced).detail)) {
                    Picker("", selection: Binding(
                        get: { AutoExpandPolicy(rawValue: app?.appearance.autoExpandPolicyRaw ?? "balanced") ?? .balanced },
                        set: { app?.appearance.setAutoExpandPolicy($0) }
                    )) {
                        ForEach(AutoExpandPolicy.allCases, id: \.self) { policy in
                            Text(LocalizedStringKey(policy.displayName)).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
                SettingsRow(title: "隐匿策略",
                            detail: "全屏应用、空间不足或用户隐藏时采用哪种隐匿方式。") {
                    Picker("", selection: Binding(
                        get: { app?.morph.dormantStyle ?? .hideCompletely },
                        set: { app?.morph.setDormantStyle($0) }
                    )) {
                        ForEach(DormantStyle.allCases, id: \.self) { style in
                            Text(LocalizedStringKey(style.displayName)).tag(style)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 150)
                }
            }

            SettingsGroup(title: "交互") {
                SettingsRow(title: "鼠标穿透",
                            detail: "开启后悬浮形态不接收鼠标，点击会落到下面的窗口；完整播放器始终可以点。用「鼠标穿透」快捷键或回到这里关闭。") {
                    SettingsToggle(isOn: app?.morph.isClickThroughEnabled ?? false) { _ in
                        app?.morph.toggleInteractive()
                    }
                }
                SettingsRow(title: "锁定位置", detail: "锁定后拖动不会移动窗口，自动避让也跳过它。") {
                    SettingsToggle(isOn: app?.morph.isPositionLocked ?? false) { _ in
                        app?.morph.togglePositionLock()
                    }
                }
                SettingsRow(title: "恢复默认布局",
                            detail: "清空记住的位置与形态，回到第一次打开时的样子。") {
                    FlowTextButton(title: "恢复", symbolName: "arrow.counterclockwise") {
                        Task { await app?.morph.resetPlacementMemory() }
                    }
                }
            }
        }
    }
}

// MARK: - 歌词

private struct LyricsPaneSettings: View {
    @Environment(\.app) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "排版") {
                SettingsRow(title: "字号", detail: "当前行字号；前后行按比例自适应。") {
                    SettingsSlider(value: app?.appearance.lyricFontSize ?? 15,
                                   range: 11...30,
                                   format: { String(format: "%.0f pt", $0) },
                                   accessibilityLabel: "歌词字号") { value in
                        app?.appearance.setLyricFontSize(value)
                        app?.floatingLyrics.applyLyricFontSize(value)
                    }
                }
                SettingsRow(title: "行距", detail: "调整歌词行与行之间的距离；在播放页和双行 / 歌词板里都会生效。") {
                    SettingsSlider(value: app?.appearance.lyricLineSpacing ?? 8,
                                   range: 0...24,
                                   format: { String(format: "%.0f pt", $0) },
                                   accessibilityLabel: "歌词行距") { value in
                        app?.appearance.setLyricLineSpacing(value)
                        app?.floatingLyrics.applyLyricLineSpacing(value)
                    }
                }
                SettingsRow(title: "显示中文译文", detail: "在外文歌原句下方对照显示中文译文。") {
                    SettingsToggle(isOn: app?.appearance.showLyricTranslation ?? true) { value in
                        app?.setShowLyricTranslation(value)
                    }
                }
            }

            SettingsGroup(title: "同步") {
                SettingsRow(title: "当前曲目偏移",
                            detail: "每首歌单独记住的歌词提前 / 延后量。要改请用下面的校准。") {
                    FlowCaption(verbatim: offsetText)
                }
                SettingsRow(title: "校准", detail: "在完整播放器右侧的校准面板里用方向键微调，回车保存。") {
                    FlowTextButton(title: "打开校准", symbolName: "arrow.left.and.right.square") {
                        app?.morph.openCalibration()
                    }
                }
            }
        }
    }

    private var offsetText: String {
        DurationText.offset(app?.lyricEngine.userOffset ?? 0)
    }
}

// MARK: - 播放

struct PlaybackPane: View {
    @Environment(\.app) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "输出") {
                SettingsRow(title: "默认音量",
                            detail: "每次打开 App 时使用的音量；之后跟随你手动调整。",
                            explanation: "只在打开 App 时使用一次。静音只在这次运行有效，下次打开按这里的音量出声。") {
                    SettingsSlider(value: app?.appearance.engineVolume ?? 0.7,
                                   range: 0...1,
                                   format: { String(format: "%.0f%%", $0 * 100) },
                                   accessibilityLabel: "默认音量") { value in
                        app?.appearance.setEngineVolume(value)
                        app?.playback.setVolume(Float(value))
                    }
                }
                SettingsRow(title: "拔出耳机时暂停",
                            detail: "只识别内置耳机口与蓝牙耳机；USB 声卡与 AirPlay 不猜，避免误暂停。") {
                    SettingsToggle(isOn: app?.settings.pauseOnHeadphoneUnplug ?? true) { value in
                        Task { await app?.settings.setPauseOnHeadphoneUnplug(value) }
                        app?.audioRouteMonitor?.setPolicy(AudioRoutePolicy(pauseOnHeadphoneUnplug: value))
                    }
                }
            }

            SettingsGroup(title: "音效与均衡") {
                SettingsRow(title: "响度自动平衡",
                            detail: "自动分析不同投稿的响度并平滑对齐，切歌不再忽大忽小。") {
                    SettingsToggle(isOn: app?.appearance.loudnessNormalizationEnabled ?? true) { value in
                        app?.appearance.setLoudnessNormalizationEnabled(value)
                    }
                }
                SettingsRow(title: "均衡器",
                            detail: "5 段均衡器（60 Hz – 14 kHz），切换预设或调节下方频段实时生效。") {
                    HStack(spacing: Spacing.s) {
                        Picker("", selection: Binding(
                            get: { app?.appearance.eqPreset ?? .off },
                            set: { preset in app?.appearance.setEQPreset(preset) }
                        )) {
                            ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                                Text(LocalizedStringKey(preset.displayName)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .settingsRowLabel()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 120)

                        if (app?.appearance.eqPreset ?? .off) != .off {
                            FlowTextButton(title: "重设均衡器", symbolName: "arrow.counterclockwise") {
                                app?.appearance.resetEQ()
                            }
                        }
                    }
                }
                if (app?.appearance.eqPreset ?? .off) != .off {
                    let bands = app?.appearance.effectiveEQBands ?? EqualizerPreset.off.defaultGainsDB
                    ForEach(EqualizerSpec.bands) { band in
                        SettingsRow(title: LocalizedStringKey(band.label)) {
                            SettingsSlider(value: bands[band.id],
                                           range: EqualizerSpec.gainRange,
                                           format: { String(format: "%+.0f dB", $0) },
                                           accessibilityLabel: band.label) { value in
                                app?.appearance.setEQBand(index: band.id, gainDB: value)
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "睡眠定时") {
                SettingsRow(title: "倒计时", detail: "到点淡出后暂停播放，不关闭应用。") {
                    HStack(spacing: 8) {
                        // 已设定时必须看得见"还剩多久"：之前只有一个「取消」，
                        // 用户点完 30 分之后界面没有任何变化，既不知道设没设上，也不知道剩多少。
                        if app?.sleepTimer?.isArmed == true {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                FlowCaption(text: "剩余 \(SettingsView.countdownText(app?.sleepTimer?.remaining ?? .zero))")
                            }
                        }
                        // 四个文字按钮在 260pt 的列里放不下（实测「15」和「分」被折行），
                        // 改成与下面「到点淡出」同一种下拉，顺带把「关闭」变成显式选项。
                        Picker("", selection: Binding(
                            get: { app?.sleepTimer?.armedMinutes ?? 0 },
                            set: { minutes in
                                guard let timer = app?.sleepTimer else { return }
                                if minutes == 0 { timer.cancel() }
                                else { timer.start(for: .seconds(minutes * 60)) }
                            }
                        )) {
                            Text("关闭").tag(0)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("60 分钟").tag(60)
                            Text("90 分钟").tag(90)
                        }
                        .labelsHidden()
                        .settingsRowLabel()
                    }
                }
                SettingsRow(title: "到点淡出", detail: "淡出时长，0 表示直接暂停。") {
                    Picker("", selection: Binding(
                        get: { app?.appearance.fadeOutMillis ?? 600 },
                        set: { value in
                            app?.appearance.setFadeOutMillis(value)
                            app?.sleepTimer?.fadeOutDuration = .milliseconds(value)
                        }
                    )) {
                        Text("不淡出").tag(0)
                        Text("300 毫秒").tag(300)
                        Text("600 毫秒").tag(600)
                        Text("1000 毫秒").tag(1000)
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 120)
                }
            }

            SettingsGroup(title: "模式") {
                // 原来这里只有一句「单曲循环」的只读文字，而播放条上是连点轮转——
                // 想直接从列表里选一种模式没有入口。改成下拉 + 随机开关，两处保持同步。
                SettingsRow(title: "循环模式", detail: "和播放条上的播放模式按钮同步，切换后立即保存。") {
                    Picker("", selection: Binding(
                        get: { app?.playback.queueSnapshot.repeatMode ?? .off },
                        set: { app?.playback.setRepeatMode($0) }
                    )) {
                        Text("顺序播放").tag(RepeatMode.off)
                        Text("单曲循环").tag(RepeatMode.one)
                        Text("列表循环").tag(RepeatMode.all)
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                }
                SettingsRow(title: "随机播放", detail: "从当前队列里随机取下一首，与循环模式互不影响。") {
                    SettingsToggle(isOn: app?.playback.queueSnapshot.isShuffling ?? false) { value in
                        app?.playback.setShuffling(value)
                    }
                }
            }
        }
    }

}

// MARK: - 音色（FLOW Voice）

/// 「音色」页：FLOW Voice 的总开关 + 音色包管理入口。
/// 日常控制在播放栏的音色开关里，这里留给管理与说明。
private struct VoicePane: View {
    @Environment(\.app) private var app
    @State private var showPackImporter = false
    @State private var showModelFetchSheet = false
    @State private var importingAssetKind: VoiceModelAssetsManager.AssetKind?
    @State private var packPendingDeletion: VoicePackManifest?
    @State private var showUninstallConfirm = false
    @State private var isDropTargeted = false
    @State private var alertMessage: String?
    @State private var hfMirrorDraft = VoiceModelMirrorConfig.defaultHFMirrorBase
    @State private var ghMirrorDraft = ""

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "FLOW Voice") {
                SettingsRow(title: "AI 翻唱",
                            detail: "开启后，生成过的歌自动播放 AI 版；新歌要在播放器里手动生成，不会自动转换。") {
                    SettingsToggle(isOn: app?.voice?.isEnabled ?? false) { value in
                        app?.voice?.isEnabled = value
                    }
                }
                SettingsRow(title: "在播放栏显示入口",
                            detail: "在播放器底栏与沉浸模式显示「音色」图标；卸载后自动收起。") {
                    SettingsToggle(isOn: app?.voice?.showEntryInPlayer ?? true) { value in
                        app?.voice?.showEntryInPlayer = value
                    }
                }
                SettingsRow(title: "推理质量",
                            detail: "控制分离重叠率与双次降噪强度。") {
                    Picker("", selection: Binding(
                        get: { app?.voice?.qualityMode ?? .balanced },
                        set: { app?.voice?.qualityMode = $0 }
                    )) {
                        ForEach(VoiceManager.VoiceQualityMode.allCases, id: \.self) { mode in
                            Text(LocalizedStringKey(mode.displayName)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            SettingsGroup(title: "音色包") {
                if let voice = app?.voice {
                    Group {
                        if voice.packs.isEmpty {
                            SettingsRow(title: "还没有音色",
                                        detail: "可选功能，初始不自带模型；可直接在线获取并自动导入，或拖入/选择本地 .voicepack / .onnx。") {
                                HStack(spacing: 8) {
                                    FlowTextButton(title: "在线获取…", symbolName: "icloud.and.arrow.down") {
                                        showModelFetchSheet = true
                                    }
                                    FlowTextButton(title: "导入音色", symbolName: "plus") {
                                        showPackImporter = true
                                    }
                                }
                            }
                        } else {
                            ForEach(voice.packs, id: \.packID) { pack in
                                voicePackRow(pack, voice: voice)
                            }
                            SettingsRow(title: "获取更多",
                                        detail: "可在线检索下载并自动导入，或拖拽/选择本地 .voicepack 文件夹 / .onnx + 可选 .f32bin 索引。") {
                                HStack(spacing: 8) {
                                    FlowTextButton(title: "在线获取…", symbolName: "icloud.and.arrow.down") {
                                        showModelFetchSheet = true
                                    }
                                    FlowTextButton(title: "导入音色", symbolName: "plus") {
                                        showPackImporter = true
                                    }
                                }
                            }
                        }
                    }
                    .overlay {
                        VoiceDropHighlightOverlay(isTargeted: isDropTargeted, cornerRadius: 10)
                    }
                    .voicePackDropDestination(into: voice, isTargeted: $isDropTargeted) { message in
                        alertMessage = message
                    }
                }
            }

            SettingsGroup(title: "模型下载与镜像源") {
                if let voice = app?.voice {
                    SettingsRow(title: "下载通道",
                                detail: LocalizedStringKey(voice.mirrorMode.shortDescription)) {
                        Picker("下载通道", selection: Binding(
                            get: { voice.mirrorMode },
                            set: { voice.setMirrorMode($0) }
                        )) {
                            Text("默认镜像源").tag(VoiceMirrorMode.hfMirror)
                            Text("官方直连").tag(VoiceMirrorMode.official)
                            Text("自定义镜像").tag(VoiceMirrorMode.custom)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }

                    if voice.mirrorMode == .custom {
                        SettingsRow(title: "HuggingFace 镜像",
                                    detail: "用于搜索仓库与拉取底座 / RVC 音色文件。") {
                            HStack(spacing: 6) {
                                TextField("https://hf-mirror.com", text: $hfMirrorDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 210)
                                    .onSubmit {
                                        voice.setCustomHFMirror(hfMirrorDraft)
                                        hfMirrorDraft = voice.customHFMirror
                                    }
                                FlowTextButton(title: "应用") {
                                    voice.setCustomHFMirror(hfMirrorDraft)
                                    hfMirrorDraft = voice.customHFMirror
                                }
                            }
                        }
                        SettingsRow(title: "GitHub 加速前缀",
                                    detail: "可选下载代理前缀（留空则直连 GitHub）。") {
                            HStack(spacing: 6) {
                                TextField("可选代理前缀，留空直连", text: $ghMirrorDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 210)
                                    .onSubmit {
                                        voice.setCustomGitHubMirror(ghMirrorDraft)
                                        ghMirrorDraft = voice.customGitHubMirror
                                    }
                                FlowTextButton(title: "应用") {
                                    voice.setCustomGitHubMirror(ghMirrorDraft)
                                    ghMirrorDraft = voice.customGitHubMirror
                                }
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "原生推理环境与底座模型") {
                if let voice = app?.voice {
                    SettingsRow(title: "推理后端",
                                detail: LocalizedStringKey(voice.activeBackendName)) {
                        EmptyView()
                    }
                    if voice.assetStatuses.contains(where: { !$0.isReady }) {
                        SettingsRow(title: "自动获取底座模型",
                                    detail: "一键下载缺少的模型并自动校验；第一次生成 AI 翻唱时也会自动下载。") {
                            if voice.isDownloadingAllBaseAssets {
                                FlowTextButton(title: "取消下载", symbolName: "xmark.circle") {
                                    voice.cancelAllDownloads()
                                }
                            } else {
                                FlowTextButton(title: "一键补齐缺失模型", symbolName: "arrow.down.circle") {
                                    runVoiceDownload { try await voice.downloadAllMissingBaseAssets() }
                                }
                                .disabled(voice.isDownloadingAsset != nil)
                            }
                        }
                    }
                    ForEach(voice.assetStatuses, id: \.kind) { status in
                        let formattedSize = Self.sizeFormatter.string(fromByteCount: status.sizeBytes)
                        let statusDetail: LocalizedStringKey = if let badReason = status.incompatibleReason {
                            LocalizedStringKey(badReason)
                        } else if status.exists {
                            "已就绪（\(formattedSize)）"
                        } else if status.kind.downloadURL != nil {
                            "未下载（联网时可自动下载并校验，也可手动导入）"
                        } else {
                            "未导入（需要手动导入模型文件）"
                        }
                        SettingsRow(title: LocalizedStringKey(status.kind.displayName),
                                    detail: statusDetail) {
                            HStack(spacing: 8) {
                                if !status.isReady, status.kind.downloadURL != nil {
                                    let pct = voice.assetDownloadProgress[status.kind]
                                    let downloadingThis = voice.isDownloadingAsset == status.kind
                                    let btnTitle: LocalizedStringKey = if downloadingThis, let pct, pct > 0 {
                                        "\(Int((pct * 100).rounded()))%"
                                    } else if downloadingThis {
                                        "下载中…"
                                    } else if status.incompatibleReason != nil {
                                        "重新下载"
                                    } else {
                                        "下载"
                                    }
                                    FlowTextButton(title: btnTitle) {
                                        runVoiceDownload { try await voice.downloadBaseAsset(status.kind) }
                                    }
                                    .disabled(voice.isDownloadingAsset != nil || voice.isDownloadingAllBaseAssets)
                                    if downloadingThis, !voice.isDownloadingAllBaseAssets {
                                        FlowIconButton(systemName: "xmark.circle", label: "取消下载") {
                                            voice.cancelDownload(VoiceManager.assetDownloadID(status.kind))
                                        }
                                    }
                                }
                                FlowTextButton(title: status.exists ? "替换" : "导入…") {
                                    importingAssetKind = status.kind
                                }
                                if status.exists {
                                    FlowTextButton(title: "移除") {
                                        do {
                                            _ = try voice.removeBaseAsset(status.kind)
                                        } catch {
                                            alertMessage = error.localizedDescription
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SettingsRow(title: "AI 渲染缓存",
                                detail: voice.isConverting
                                    ? "有转换正在进行，完成或取消后再清理。"
                                    : LocalizedStringKey(Self.sizeFormatter.string(fromByteCount: voice.cacheTotalBytes))) {
                        FlowTextButton(title: "清理缓存") {
                            do {
                                _ = try voice.clearAllCache()
                            } catch {
                                alertMessage = error.localizedDescription
                            }
                        }
                        .disabled(voice.cacheTotalBytes == 0 || voice.isConverting)
                    }
                }
            }

            SettingsGroup(title: "选装与卸载") {
                if let voice = app?.voice {
                    let totalText = Self.sizeFormatter.string(fromByteCount: voice.totalDiskFootprintBytes)
                    let footprintDetail: LocalizedStringKey = voice.hasAnyLocalData
                        ? "总计 \(totalText)（含底座模型、音色包与缓存）"
                        : "未安装本地模型与音色，占用 0 B"
                    SettingsRow(title: "本地组件与数据", detail: footprintDetail) {
                        FlowTextButton(title: "卸载组件…") {
                            showUninstallConfirm = true
                        }
                        .disabled(!voice.hasAnyLocalData && !voice.showEntryInPlayer && !voice.isEnabled)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            if let voice = app?.voice {
                hfMirrorDraft = voice.customHFMirror
                ghMirrorDraft = voice.customGitHubMirror
                voice.refreshEnvironmentStatus()
            }
        }
        .sheet(isPresented: $showModelFetchSheet) {
            VoiceModelFetchSheet()
        }
        .fileImporter(isPresented: $showPackImporter,
                      allowedContentTypes: [.folder, .item],
                      allowsMultipleSelection: true) { result in
            guard let voice = app?.voice else { return }
            switch result {
            case .failure(let err):
                alertMessage = err.localizedDescription
            case .success(let urls):
                Task {
                    do {
                        try await VoiceImportHelper.importPack(from: urls, into: voice)
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                }
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { importingAssetKind != nil },
                set: { if !$0 { importingAssetKind = nil } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            let kind = importingAssetKind
            importingAssetKind = nil
            guard let kind, let voice = app?.voice else { return }
            switch result {
            case .failure(let err):
                alertMessage = err.localizedDescription
            case .success(let urls):
                Task {
                    do {
                        try await VoiceImportHelper.importBaseAsset(from: urls, kind: kind, into: voice)
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                }
            }
        }
        .alert(
            "FLOW Voice",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("好") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(
            "删除音色包",
            isPresented: Binding(
                get: { packPendingDeletion != nil },
                set: { if !$0 { packPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                guard let pack = packPendingDeletion else { return }
                packPendingDeletion = nil
                do {
                    try app?.voice?.deletePack(pack.packID)
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {
                packPendingDeletion = nil
            }
        } message: {
            let name = packPendingDeletion?.displayName ?? ""
            Text("将从本地移除音色「\(name)」及其全部版本，此操作不可撤销。")
        }
        .alert("卸载 FLOW Voice", isPresented: $showUninstallConfirm) {
            Button("确认卸载", role: .destructive) {
                do {
                    _ = try app?.voice?.uninstallAll(hidePlayerEntry: true)
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let totalText = Self.sizeFormatter.string(fromByteCount: app?.voice?.totalDiskFootprintBytes ?? 0)
            Text("将删除所有底座 ONNX 模型、全部音色包与渲染缓存（共 \(totalText)），并关闭功能及隐藏播放栏入口；日后随时可在此重新导入。")
        }
    }

    /// 下载被用户取消（或卸载、关联网叫停）不算失败，不弹窗。
    private func runVoiceDownload(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private static func packDetailText(for pack: VoicePackManifest) -> LocalizedStringKey {
        if let ver = pack.selectedVersion {
            let countText = String(pack.versions.count)
            let metaText = "\(ver.id) · \(ver.architectureHint.uppercased()) · \(ver.sampleRate / 1000)kHz"
            return "\(countText) 个版本（\(metaText)）"
        }
        return "\(pack.versions.count) 个版本"
    }

    @ViewBuilder
    private func voicePackRow(_ pack: VoicePackManifest, voice: VoiceManager) -> some View {
        let isSelected = pack.packID == voice.selectedPack?.packID
        SettingsRow(title: LocalizedStringKey(pack.displayName), detail: Self.packDetailText(for: pack)) {
            HStack(spacing: 8) {
                if pack.versions.count > 1 {
                    Picker("", selection: Binding(
                        get: { pack.selectedVersionID },
                        set: { newVersionID in
                            do {
                                try voice.selectVersion(packID: pack.packID, versionID: newVersionID)
                            } catch {
                                alertMessage = error.localizedDescription
                            }
                        }
                    )) {
                        ForEach(pack.versions, id: \.id) { ver in
                            Text(ver.id).tag(ver.id)
                        }
                    }
                    .labelsHidden()
                    .settingsRowLabel()
                    .frame(width: 96)
                }
                if isSelected {
                    Text("使用中").flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                } else {
                    FlowTextButton(title: "使用") {
                        voice.selectPack(pack.packID)
                    }
                }
                FlowTextButton(title: "删除") {
                    packPendingDeletion = pack
                }
            }
        }
    }
}

// MARK: - 快捷键

/// 全局快捷键。这里列的是**真实注册成功的绑定**，
/// 不是"我们打算支持"的清单——注册数量直接读 `HotkeyCenter.registeredActionCount`。
private struct ShortcutPane: View {
    @Environment(\.app) private var app

    /// 正在录制新组合的那一项（nil 表示没在录制）。
    @State private var recording: HotkeyCenter.Action?
    /// 录制期间的事件监听器。
    @State private var monitor: Any?
    @State private var conflict: String?
    /// 偏好本身不是可观察对象：改完必须手动让这一屏重绘，否则标签停在旧组合上
    /// （实测点「恢复默认」后磁盘已经清掉，按钮仍显示改过的 ⌃⌥J）。
    @State private var revision = 0

    private var preferences: HotkeyPreferences { app?.morph.hotkeyPreferences ?? HotkeyPreferences() }

    private func detail(for action: HotkeyCenter.Action) -> String {
        switch action {
        case .cycleShape:
            return "按宽松顺序循环：完整 → 迷你 → 胶囊 → 贴边 → 完整。隐藏不在这条链上。"
        case .toggleInteractive:
            return "让悬浮形态不接收鼠标，方便点到底下的窗口；再按一次恢复。"
        case .toggleVisibility:
            return "用户显式隐藏优先于一切自动决策；再按一次回到隐藏前的形态。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "全局快捷键") {
                let _ = revision   // 建立依赖：preferences 变了要靠它触发重绘
                ForEach(HotkeyCenter.Action.allCases, id: \.rawValue) { action in
                    SettingsRow(title: LocalizedStringKey(action.title),
                                detail: LocalizedStringKey(detail(for: action))) {
                        HStack(spacing: 6) {
                            Button {
                                startRecording(action)
                            } label: {
                                Text(recording == action ? "按下新的组合…" : preferences.combo(for: action).display)
                                    .flowType(.timecode)
                                    .foregroundStyle(recording == action ? Color.primary : FlowColor.secondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(recording == action ? FlowColor.hover.opacity(1.6) : FlowColor.hover)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(action.title)：\(preferences.combo(for: action).display)，点击修改"))

                            if preferences.combo(for: action) != HotkeyPreferences.defaultsCombo(for: action) {
                                Button {
                                    resetToDefault(action)
                                } label: {
                                    flowIcon(systemName: "arrow.counterclockwise", size: 10)
                                        .foregroundStyle(FlowColor.tertiaryText)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("恢复默认"))
                            }
                        }
                    }
                }
            }

            if let conflict {
                Text(conflict)
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.secondaryText)
            }

            SettingsGroup(title: "播放器内") {
                SettingsRow(title: "空格", detail: "完整形态里播放 / 暂停（跟随键盘焦点）。") {
                    FlowCaption(text: "内置")
                }
                SettingsRow(title: "← / →", detail: "歌词校准模式下每次微调一个步长；回车保存，Esc 取消。") {
                    FlowCaption(text: "内置")
                }
            }

            Text("点组合即可改键：按下新的组合，Esc 取消。至少要带 ⌃ / ⌥ / ⌘ 之一，"
                 + "否则单个字母会变成全局热键、把打字吃掉。")
                .flowType(.caption)
                .foregroundStyle(FlowColor.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            SettingsRow(title: "已注册", detail: "实际向系统注册成功的快捷键数量。") {
                FlowCaption(verbatim: "\(HotkeyCenter.shared.registeredActionCount) / 3")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: HotkeyCenter.Action) {
        stopRecording()
        conflict = nil
        recording = action
        // 录制期间先停掉全局快捷键：否则按到已占用的组合会直接触发那个动作，看不到冲突提示。
        HotkeyCenter.shared.unregisterAll()
        // 本地监听：只在本 App 有焦点时收到，不会抢系统级按键。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {          // Esc 取消
                stopRecording()
                return nil
            }
            guard let combo = HotkeyCombo(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
                conflict = "至少要带 ⌃ / ⌥ / ⌘ 之一。"
                return nil
            }
            apply(combo, to: action)
            return nil
        }
    }

    private func apply(_ combo: HotkeyCombo, to action: HotkeyCenter.Action) {
        // 同一组合不能绑两个动作：先解掉另一项的占用。
        for other in HotkeyCenter.Action.allCases where other != action
            && preferences.combo(for: other) == combo {
            conflict = String(localized: "\(combo.display) 已经用于「\(other.title)」，请换一个。")
            stopRecording()
            return
        }
        let previous = preferences.combo(for: action)
        preferences.set(combo, for: action)
        revision &+= 1
        stopRecording()
        if !HotkeyCenter.shared.isRegistered(action) {
            // 新组合被系统或别的应用占着：退回原来的组合，别让这个动作变成没有快捷键。
            preferences.set(previous == HotkeyPreferences.defaultsCombo(for: action) ? nil : previous, for: action)
            app?.morph.reloadHotkeys()
            revision &+= 1
            conflict = String(localized: "\(combo.display) 被系统或别的应用占用了，已恢复为 \(previous.display)。")
        }
    }

    private func resetToDefault(_ action: HotkeyCenter.Action) {
        let defaultCombo = HotkeyPreferences.defaultsCombo(for: action)
        if let other = HotkeyCenter.Action.allCases.first(where: { $0 != action && preferences.combo(for: $0) == defaultCombo }) {
            conflict = String(localized: "\(defaultCombo.display) 已经用于「\(other.title)」，请先改掉那一项。")
            return
        }
        conflict = nil
        preferences.reset(action)
        app?.morph.reloadHotkeys()
        revision &+= 1
    }

    private func stopRecording() {
        let wasRecording = monitor != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        // 录制结束（含取消、离开页面）都要把全局快捷键装回去。
        if wasRecording { app?.morph.reloadHotkeys() }
    }
}

// MARK: - 权限

private struct PermissionPane: View {
    @Environment(\.app) private var app
    /// 本地快照：控制器里的权限状态不可观察，授权完回来要能立刻看到变化。
    @State private var permission: AccessibilityPermission = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "辅助功能") {
                SettingsRow(title: "当前状态",
                            detail: "读取前台窗口的位置与尺寸，用于自动避让。",
                            explanation: "只读取前台应用窗口的位置与尺寸；不读取窗口标题、文档内容，也不读键盘输入。") {
                    HStack(spacing: Spacing.xs) {
                        FlowCaption(verbatim: permissionText)
                        if !isGranted {
                            FlowTextButton(title: "去授权", symbolName: "hand.raised") {
                                requestOrOpenSettings()
                            }
                        }
                    }
                }
                SettingsRow(title: "未授权时", detail: LocalizedStringKey(effectiveDetail)) {
                    FlowCaption(text: isGranted ? "全部可用" : "部分可用")
                }
                // 权限页与形态页之前各说各话：这里写"未授权"，那边"自动避让"开关却是开的，
                // 用户无法判断避让到底生效没有。这里给出**当前真实生效的那一种行为**。
                SettingsRow(title: "自动避让", detail: "未授权时系统不会提供其他应用的窗口位置，避让无法生效。") {
                    FlowCaption(verbatim: avoidanceText)
                }
            }
        }
        .task {
            refreshPermission()
            // 停留在这一页时每 2 秒轻量复查一次；状态真的变了才走完整刷新（会重新评估空间布局）。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() != isGranted { refreshPermission() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
    }

    private func refreshPermission() {
        app?.floatingLyrics.refreshAccessibilityPermission()
        permission = app?.floatingLyrics.accessibilityPermission ?? .unknown
    }

    /// 系统的授权弹窗每次运行只出现一次；之后再点就直接打开「隐私与安全性 → 辅助功能」。
    private func requestOrOpenSettings() {
        let before = app?.floatingLyrics.accessibilityPermission
        app?.floatingLyrics.requestAccessibilityPermission()
        refreshPermission()
        if before == .notGranted || permission == .notGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var isGranted: Bool { permission == .granted }

    private var avoidanceText: String {
        guard isGranted else { return String(localized: "未生效（缺授权）") }
        return app?.appearance.autoAvoidEnabled == false
            ? String(localized: "已关闭（在「形态与自动变形」里打开）")
            : String(localized: "已生效")
    }

    private var effectiveDetail: String {
        isGranted
            ? "播放、歌词、安全区、多屏记忆、手动定位与自动避让全部可用。"
            : "播放、歌词、安全区、多屏记忆与手动定位全部照常；**自动避让不会生效**（系统不提供其他窗口位置），形态只按空间与用户操作变化。"
    }

    private var permissionText: String {
        switch permission {
        case .granted: return String(localized: "已授权")
        case .notGranted: return String(localized: "未授权")
        case .unavailable: return String(localized: "不可用")
        case .unknown: return String(localized: "未知")
        }
    }
}

// MARK: - 高级

private struct AdvancedPane: View {
    @Environment(\.app) private var app
    @State private var message: String?
    @State private var confirmingClearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SettingsGroup(title: "数据") {
                SettingsRow(title: "设置备份", detail: message.map { LocalizedStringKey($0) }) {
                    HStack(spacing: 6) {
                        FlowTextButton(title: "导出", symbolName: "square.and.arrow.up") { export() }
                        FlowTextButton(title: "导入", symbolName: "square.and.arrow.down") { importBackup() }
                    }
                }
                SettingsRow(title: "播放历史",
                            detail: "只保留最近 200 首；清空不影响收藏与队列。") {
                    // 破坏性操作要两步确认：队列的「清空待播」是这样的，这里之前点一下就没。
                    FlowTextButton(title: confirmingClearHistory ? "确认清空？" : "清空历史",
                                   symbolName: confirmingClearHistory ? "exclamationmark.triangle" : "trash") {
                        guard let library = app?.library else { return }
                        if confirmingClearHistory {
                            confirmingClearHistory = false
                            Task {
                                await library.clearHistory()
                                message = "已清空播放历史"
                            }
                        } else {
                            confirmingClearHistory = true
                            Task {
                                try? await Task.sleep(for: .seconds(3))
                                confirmingClearHistory = false
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "诊断") {
                SettingsRow(title: "运行报告", detail: "包含版本、系统、权限、队列数量与存储状态，不含歌词、曲目与文件路径。") {
                    FlowTextButton(title: "复制报告", symbolName: "doc.on.doc") { copyReport() }
                }
            }
        }
    }

    private func export() {
        guard let app else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "flow-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsBackup.encode(SettingsBackup.snapshot(from: app.settings))
            try data.write(to: url)
            message = "已导出到 \(url.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importBackup() {
        guard let app else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let backup = try SettingsBackup.decode(data)
            Task {
                await backup.apply(to: app.settings)
                await app.reloadSettingsAfterImport()
                NSApp.setActivationPolicy(app.settings.hideDockIcon ? .accessory : .regular)
                message = String(localized: "已导入设置。")
            }
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func copyReport() {
        guard let app else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.diagnosticsReport(), forType: .string)
        message = "报告已复制到剪贴板"
    }

}
