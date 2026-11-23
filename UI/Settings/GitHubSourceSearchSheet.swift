import SwiftUI

/// 从 GitHub 搜索公开仓库或配置文件并一键导入到音源管理器。
struct GitHubSourceSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.app) private var app

    let onImported: ([SourceManager.ManagedSource], _ originDisplayName: String) -> Void

    @State private var query = ""
    @State private var searchMode: GitHubSearchMode = .repositories
    @State private var showsTokenPanel = false
    @State private var tokenInput = ""
    @State private var hasToken = false

    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var showingPresets = true
    @State private var repos: [GitHubRepoCandidate] = []
    @State private var selectedRepo: GitHubRepoCandidate?
    @State private var directTarget: GitHubDirectTarget?

    @State private var isInspectingRepo = false
    @State private var configs: [GitHubConfigCandidate] = []

    @State private var expandedManifestID: String?
    @State private var manifestEntriesByID: [String: [GitHubManifestEntry]] = [:]
    @State private var loadingManifestID: String?

    @State private var importingIDs: Set<String> = []
    @State private var importedURLStrings: Set<String> = []
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var searchGeneration = 0
    @State private var inspectGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var inspectTask: Task<Void, Never>?
    @State private var queryTask: Task<Void, Never>?
    @State private var submittedQuery = ""
    @State private var configsByRepo: [String: [GitHubConfigCandidate]] = [:]

    // 只给通用关键词：不提供一键去找抓取商业平台的音源（兼容这些格式的代码照常保留）。
    private static let quickQueries: [(label: LocalizedStringKey, query: String)] = [
        ("MusicFree", "musicfree plugin"),
        ("FLOW 模板", "flow-source-v1"),
        ("Navidrome", "navidrome plugin"),
    ]

    init(onImported: @escaping ([SourceManager.ManagedSource], _ originDisplayName: String) -> Void = { _, _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.s)

            searchControls
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)

            if showsTokenPanel {
                tokenBar
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.s)
            }

            if let errorMessage {
                FlowCaption(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.xs)
            } else if let statusMessage {
                FlowCaption(verbatim: statusMessage)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.xs)
            }

            FlowDivider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FlowDivider()

            footerBar
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
        }
        .frame(width: 680, height: 500)
        .task {
            syncManagerSnapshot()
            guard !RuntimeSandbox.isTestHost, !hasSearched else { return }
            query = RuntimeSandbox.defaults.string(forKey: "sources.githubDiscoveryQuery") ?? "musicfree plugin"
            runSearch()
        }
        .onDisappear {
            queryTask?.cancel()
            searchTask?.cancel()
            inspectTask?.cancel()
            searchGeneration &+= 1
            inspectGeneration &+= 1
        }
        .onChange(of: query) { _, _ in
            scheduleSearch()
        }
        .onChange(of: app?.sourceManager.revision ?? 0) { _, _ in
            syncManagerSnapshot()
        }
    }

    // MARK: - 顶部与搜索栏

    private var headerBar: some View {
        HStack(spacing: Spacing.xs) {
            Text("从 GitHub 搜索音源")
                .flowType(.homeTitle)
            Spacer()
            Button {
                withAnimation(Motion.fade(Motion.micro)) {
                    showsTokenPanel.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    flowIcon(systemName: hasToken ? "key.fill" : "key", size: 11)
                    Text(hasToken ? "已配置 Token" : "Token（可选）")
                        .flowType(.caption)
                }
                .foregroundStyle(hasToken ? Color.primary : FlowColor.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FlowColor.hover.opacity(showsTokenPanel ? 1 : 0.5), in: RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)

            Button("完成") {
                dismiss()
            }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                TextField("搜索仓库关键词，或粘贴 owner/repo / GitHub 链接", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        runSearch()
                    }

                if hasToken {
                    Picker("搜索范围", selection: $searchMode) {
                        Text("搜仓库").tag(GitHubSearchMode.repositories)
                        Text("搜文件").tag(GitHubSearchMode.files)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                    .onChange(of: searchMode) { _, _ in
                        if hasSearched && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            runSearch()
                        }
                    }
                }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24)
                }

                Button("搜索") {
                    runSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: Spacing.xs) {
                Button {
                    withAnimation(Motion.fade(Motion.micro)) {
                        showingPresets = true
                    }
                } label: {
                    Text("多 API 预设")
                        .flowType(.caption)
                        .foregroundStyle(showingPresets ? Color.primary : FlowColor.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(FlowColor.hover.opacity(showingPresets ? 1 : 0.6), in: Capsule())
                }
                .buttonStyle(.plain)

                Text("推荐关键词：")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
                ForEach(Array(Self.quickQueries.enumerated()), id: \.offset) { _, preset in
                    Button {
                        query = preset.query
                        searchMode = .repositories
                        showingPresets = false
                        runSearch()
                    } label: {
                        Text(preset.label)
                            .flowType(.caption)
                            .foregroundStyle(FlowColor.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(FlowColor.hover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var tokenBar: some View {
        HStack(spacing: Spacing.xs) {
            SecureField("粘贴 GitHub Token（提高限流并解锁代码搜索，存入钥匙串）", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveToken() }

            Button("保存") {
                saveToken()
            }
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if hasToken {
                Button("清除") {
                    clearToken()
                }
            }
        }
        .padding(Spacing.xs)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.control))
    }

    // MARK: - 主体区域

    @ViewBuilder
    private var mainContent: some View {
        if showingPresets {
            presetsContent
        } else if searchMode == .files {
            fileSearchContent
        } else {
            HStack(spacing: 0) {
                repositoryListPane
                    .frame(width: 256)
                Rectangle()
                    .fill(FlowColor.hairline)
                    .frame(width: 1)
                repositoryConfigsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var presetsContent: some View {
        let presets = app?.sourceManager.availableAPIPresets ?? ExternalAPIPresetCatalog.presets
        let importingAll = importingIDs.contains("__all_presets__")
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("外部多 API 预设")
                            .flowType(.body)
                            .fontWeight(.medium)
                        Text("提供 Audius、Radio Browser 与 Internet Archive 开放接口模板，按需获取并导入。")
                            .flowType(.caption)
                            .foregroundStyle(FlowColor.tertiaryText)
                    }
                    Spacer()
                    if importingAll {
                        ProgressView().controlSize(.small)
                    }
                    Button("全部获取并导入") {
                        importAllPresets(presets)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importingAll)
                }

                ForEach(presets) { preset in
                    let isImporting = importingIDs.contains("preset:\(preset.id)")
                    let isImported = app?.sourceManager.isPresetImported(preset) ?? false
                    let origin = app?.sourceManager.presetOriginDescription(preset) ?? preset.localizedOriginBadge

                    HStack(alignment: .center, spacing: Spacing.xs) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(verbatim: preset.localizedDisplayName)
                                    .flowType(.body)
                                    .fontWeight(.medium)
                                Text(verbatim: preset.localizedOriginBadge)
                                    .flowType(.caption)
                                    .foregroundStyle(FlowColor.secondaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(FlowColor.hover, in: Capsule())
                                if isImported {
                                    Text("已导入")
                                        .flowType(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(verbatim: "\(preset.localizedSummary) · \(origin)")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.xs)
                        if isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Button(isImported ? "重新获取" : "获取并导入") {
                            importPresetItem(preset)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isImporting || importingAll)
                    }
                    .padding(Spacing.s)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(FlowColor.hairline, lineWidth: 1)
                    }
                }
            }
            .padding(Spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repositoryListPane: some View {
        Group {
            if isSearching && repos.isEmpty {
                centeredPlaceholder(symbol: "magnifyingglass", text: "正在搜索 GitHub 仓库…", showsSpinner: true)
            } else if repos.isEmpty {
                centeredPlaceholder(
                    symbol: hasSearched ? "tray" : "sparkles",
                    text: hasSearched
                        ? "没有找到匹配的仓库，请换个关键词或直接输入 owner/repo"
                        : "输入关键词搜索开源音源仓库，或直接粘贴 GitHub 仓库链接",
                    showsSpinner: false
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        Button {
                            inspectTask?.cancel()
                            inspectGeneration &+= 1
                            isInspectingRepo = false
                            selectedRepo = nil
                            expandedManifestID = nil
                            configs = allDiscoveredConfigs
                        } label: {
                            HStack {
                                Text("全部结果")
                                Spacer()
                                if isSearching {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .flowType(.body)
                            .padding(Spacing.xs)
                            .background(selectedRepo == nil ? FlowColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control))
                        }
                        .buttonStyle(.plain)
                        ForEach(repos) { repo in
                            repositoryRow(repo)
                        }
                    }
                    .padding(Spacing.xs)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func repositoryRow(_ repo: GitHubRepoCandidate) -> some View {
        let isSelected = selectedRepo?.id == repo.id
        return Button {
            selectRepo(repo)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: repo.fullName)
                        .flowType(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: "★ \(Self.formatStars(repo.stars))")
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                }
                if !repo.description.isEmpty {
                    Text(verbatim: repo.description)
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                        .lineLimit(2)
                }
                if !repo.updatedAt.isEmpty {
                    Text(verbatim: "\(repo.defaultBranch) · \(repo.updatedAt)")
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.tertiaryText)
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? FlowColor.hover : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(FlowColor.hairline, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repositoryConfigsPane: some View {
        Group {
            if isInspectingRepo || (isSearching && configs.isEmpty) {
                centeredPlaceholder(symbol: "doc.text.magnifyingglass", text: "正在自动检查音源文件…", showsSpinner: true)
            } else if configs.isEmpty {
                centeredPlaceholder(
                    symbol: "questionmark.folder",
                    text: "未发现支持的音源文件。API 服务源码需要先部署并适配为音源插件。",
                    showsSpinner: false
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            Text("已发现 \(configs.count) 个配置文件")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                            Spacer()
                            if let selectedRepo {
                                Text(verbatim: selectedRepo.fullName)
                                    .flowType(.caption)
                                    .foregroundStyle(FlowColor.tertiaryText)
                            }
                        }
                        .padding(.horizontal, 2)
                        ForEach(configs) { config in
                            configCard(config, showRepoName: selectedRepo == nil)
                        }
                    }
                    .padding(Spacing.s)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var fileSearchContent: some View {
        Group {
            if isSearching && configs.isEmpty {
                centeredPlaceholder(symbol: "magnifyingglass", text: "正在搜索 GitHub 文件…", showsSpinner: true)
            } else if configs.isEmpty {
                centeredPlaceholder(
                    symbol: hasSearched ? "tray" : "doc.text.magnifyingglass",
                    text: hasSearched ? "未搜索到匹配的 .js 或 .json 音源文件" : "输入关键词全网检索 .js 插件或 .json 模板文件",
                    showsSpinner: false
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(configs) { config in
                            configCard(config, showRepoName: true)
                        }
                    }
                    .padding(Spacing.s)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // 注意：`Text("已发现 \(configs.count) 个配置文件")` 的格式键需要走格式化；直接用 Text(localized:) 或把 %lld 写好。
    private func configCard(_ config: GitHubConfigCandidate, showRepoName: Bool) -> some View {
        let isImporting = importingIDs.contains(config.id)
        let isImported = isURLImported(config.rawURL)
        let isExpanded = expandedManifestID == config.id
        let isLoadingManifest = loadingManifestID == config.id

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: config.displayName)
                            .flowType(.body)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        kindBadge(config.kind)

                        if isImported {
                            Text("已导入")
                                .flowType(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    HStack(spacing: 6) {
                        if showRepoName {
                            Text(verbatim: "\(config.repoFullName) · \(config.path)")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(verbatim: config.path)
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let sizeBytes = config.sizeBytes {
                            Text(verbatim: "· \(ByteText.size(Int64(sizeBytes)))")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                        }
                    }
                    if config.compatibility == .unsupported {
                        Text("此文件不是支持的音源格式，需先适配。")
                            .flowType(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if config.compatibility == .unchecked {
                        Text("尚未检查，导入时会验证格式。")
                            .flowType(.caption)
                            .foregroundStyle(FlowColor.tertiaryText)
                    }
                }

                Spacer(minLength: Spacing.xs)

                if config.kind == .subscriptionManifest && config.compatibility != .unsupported {
                    Button(isExpanded ? "收起" : "预览条目") {
                        toggleManifestPreview(config)
                    }
                    .disabled(isLoadingManifest)
                }

                if isImporting {
                    ProgressView().controlSize(.small)
                }

                if config.compatibility == .unsupported, let htmlURL = config.htmlURL {
                    Link("查看源码", destination: htmlURL)
                        .flowType(.caption)
                } else {
                    Button(importButtonTitle(for: config, isImported: isImported)) {
                        importCandidate(id: config.id, url: config.rawURL, displayName: config.displayName)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isImporting || config.compatibility == .unsupported)
                }
            }

            if isExpanded {
                manifestPreviewSection(for: config, isLoading: isLoadingManifest)
            }
        }
        .padding(Spacing.s)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(FlowColor.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func manifestPreviewSection(for config: GitHubConfigCandidate, isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowDivider()
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在解析订阅清单…")
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                }
                .padding(.vertical, 4)
            } else if let entries = manifestEntriesByID[config.id], !entries.isEmpty {
                ForEach(entries) { entry in
                    let entryImporting = importingIDs.contains(entry.id)
                    let entryImported = isURLImported(entry.url)
                    HStack(spacing: Spacing.xs) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: entry.name)
                                    .flowType(.caption)
                                    .foregroundStyle(.primary)
                                if let version = entry.version, !version.isEmpty {
                                    Text(verbatim: "v\(version)")
                                        .flowType(.caption)
                                        .foregroundStyle(FlowColor.tertiaryText)
                                }
                                if entryImported {
                                    Text("已导入")
                                        .flowType(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(verbatim: entry.url.absoluteString)
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if entryImporting {
                            ProgressView().controlSize(.small)
                        }
                        Button(entryImported ? "重新导入" : "导入") {
                            importCandidate(
                                id: entry.id,
                                url: entry.url,
                                displayName: entry.name,
                                initialUserVariables: entry.userVariables
                            )
                        }
                        .controlSize(.small)
                        .disabled(entryImporting)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("清单内没有可解析的音源条目")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
            }
        }
    }

    private func kindBadge(_ kind: GitHubConfigCandidate.Kind) -> some View {
        let title: LocalizedStringKey = switch kind {
        case .subscriptionManifest: "订阅清单"
        case .jsonTemplateOrConfig: "JSON 配置"
        case .jsPlugin: "JS 插件"
        }
        return Text(title)
            .flowType(.caption)
            .foregroundStyle(FlowColor.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(FlowColor.hover, in: Capsule())
    }

    private func importButtonTitle(for config: GitHubConfigCandidate, isImported: Bool) -> LocalizedStringKey {
        if config.compatibility == .unsupported { return "需适配" }
        if config.kind == .subscriptionManifest {
            return isImported ? "重新导入全部" : "导入全部"
        }
        if config.kind == .jsPlugin && config.compatibility == .recognized && !isImported {
            return "适配并导入"
        }
        return isImported ? "重新导入" : "导入"
    }

    private var footerBar: some View {
        HStack(spacing: Spacing.s) {
            if let app, !app.settings.enableNetwork {
                Text("联网已关闭，开启后才能检索并导入 GitHub 仓库。")
                    .flowType(.caption)
                    .foregroundStyle(.orange)
                FlowTextButton(title: "允许联网", symbolName: "network") {
                    Task {
                        await app.setEnableNetwork(true)
                        errorMessage = nil
                    }
                }
            } else {
                Text("第三方脚本将在隔离沙箱中运行并遵循白名单域名策略，导入前请确认仓库可信。")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.tertiaryText)
            }
            Spacer()
        }
    }

    private func centeredPlaceholder(symbol: String, text: LocalizedStringKey, showsSpinner: Bool) -> some View {
        VStack(spacing: Spacing.s) {
            if showsSpinner {
                ProgressView()
            } else {
                flowIcon(systemName: symbol, size: 26)
                    .foregroundStyle(FlowColor.tertiaryText)
            }
            Text(text)
                .flowType(.caption)
                .foregroundStyle(FlowColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 状态同步与动作

    private func syncManagerSnapshot() {
        guard let manager = app?.sourceManager else { return }
        hasToken = manager.hasGitHubToken
        importedURLStrings.formUnion(manager.importedOriginURLs)
    }

    private func isURLImported(_ url: URL) -> Bool {
        let normalized = SourceDomainPolicy.normalizeImportURL(url.absoluteString)?.absoluteString ?? url.absoluteString
        return importedURLStrings.contains(normalized) || importedURLStrings.contains(url.absoluteString)
    }

    private func saveToken() {
        guard let manager = app?.sourceManager else { return }
        do {
            try manager.saveGitHubToken(tokenInput)
            tokenInput = ""
            hasToken = manager.hasGitHubToken
            showsTokenPanel = false
            errorMessage = nil
            statusMessage = String(localized: "已保存 GitHub Token 至系统钥匙串")
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func clearToken() {
        guard let manager = app?.sourceManager else { return }
        manager.clearGitHubToken()
        tokenInput = ""
        hasToken = false
        searchMode = .repositories
        statusMessage = String(localized: "已清除 GitHub Token")
    }

    private var allDiscoveredConfigs: [GitHubConfigCandidate] {
        repos.flatMap { configsByRepo[$0.id] ?? [] }
            .sorted { $0.compatibility.sortRank < $1.compatibility.sortRank }
    }

    private func scheduleSearch() {
        queryTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != submittedQuery else { return }
        submittedQuery = ""
        searchTask?.cancel()
        inspectTask?.cancel()
        searchGeneration &+= 1
        inspectGeneration &+= 1
        isSearching = false
        isInspectingRepo = false
        guard !trimmed.isEmpty else {
            submittedQuery = ""
            configs = []
            repos = []
            configsByRepo = [:]
            selectedRepo = nil
            errorMessage = nil
            showingPresets = true
            return
        }
        queryTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                runSearch()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func runSearch() {
        queryTask?.cancel()
        guard let manager = app?.sourceManager else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        submittedQuery = trimmed
        RuntimeSandbox.defaults.set(trimmed, forKey: "sources.githubDiscoveryQuery")
        errorMessage = nil
        statusMessage = nil
        showingPresets = false
        hasSearched = true
        isSearching = true
        expandedManifestID = nil
        searchGeneration &+= 1
        inspectGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        inspectTask?.cancel()
        isInspectingRepo = false
        configs = []
        configsByRepo = [:]
        repos = []
        selectedRepo = nil
        directTarget = manager.parseGitHubDirectTarget(trimmed)
        let target = directTarget
        let activeMode = hasToken ? searchMode : .repositories
        searchTask = Task {
            defer {
                if searchGeneration == generation {
                    isSearching = false
                }
            }
            do {
                if activeMode == .files {
                    let hits = try await manager.searchGitHubFiles(query: trimmed)
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    configs = hits
                } else {
                    let foundRepos = try await manager.searchGitHubRepositories(query: trimmed)
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    repos = foundRepos
                    var firstError: (any Error)?
                    // 限制自动扫描范围，逐仓库呈现结果，避免一次消耗过多匿名请求额度。
                    for repo in foundRepos.prefix(6) {
                        try Task.checkCancellation()
                        do {
                            let matchedTarget = target.flatMap {
                                "\($0.owner)/\($0.repo)".caseInsensitiveCompare(repo.fullName) == .orderedSame ? $0 : nil
                            }
                            let items = try await manager.inspectGitHubRepository(
                                repo,
                                branchOverride: matchedTarget?.branchHint,
                                preferredPath: matchedTarget?.filePathHint
                            )
                            guard !Task.isCancelled, searchGeneration == generation else { return }
                            configsByRepo[repo.id] = items
                            if selectedRepo == nil {
                                configs = allDiscoveredConfigs
                            } else if selectedRepo?.id == repo.id, !isInspectingRepo {
                                configs = items
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as SourceDomainPolicy.Violation {
                            if case .networkDisabled = error { throw error }
                            if firstError == nil { firstError = error }
                        } catch let error as PlaybackError where error == .networkDisabled {
                            throw error
                        } catch let error as GitHubDiscoveryError {
                            switch error {
                            case .rateLimited, .unauthorized: throw error
                            default: if firstError == nil { firstError = error }
                            }
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                    if configs.isEmpty, let firstError {
                        errorMessage = friendlyError(firstError)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                errorMessage = friendlyError(error)
            }
        }
    }

    private func selectRepo(_ repo: GitHubRepoCandidate) {
        guard let manager = app?.sourceManager else { return }
        selectedRepo = repo
        configs = []
        expandedManifestID = nil
        errorMessage = nil
        inspectGeneration &+= 1
        let generation = inspectGeneration
        let activeSearchGeneration = searchGeneration
        inspectTask?.cancel()
        if let cached = configsByRepo[repo.id] {
            configs = cached
            isInspectingRepo = false
            return
        }
        isInspectingRepo = true

        let matchedDirect: GitHubDirectTarget? = {
            guard let target = directTarget,
                  "\(target.owner)/\(target.repo)".caseInsensitiveCompare(repo.fullName) == .orderedSame else {
                return nil
            }
            return target
        }()
        let branchOverride = matchedDirect?.branchHint
        let preferredPath = matchedDirect?.filePathHint

        inspectTask = Task {
            defer {
                if inspectGeneration == generation {
                    isInspectingRepo = false
                }
            }
            do {
                let items = try await manager.inspectGitHubRepository(
                    repo,
                    branchOverride: branchOverride,
                    preferredPath: preferredPath
                )
                guard !Task.isCancelled,
                      inspectGeneration == generation,
                      searchGeneration == activeSearchGeneration else { return }
                configsByRepo[repo.id] = items
                configs = items
            } catch is CancellationError {
                return
            } catch {
                guard inspectGeneration == generation else { return }
                errorMessage = friendlyError(error)
            }
        }
    }

    private func toggleManifestPreview(_ config: GitHubConfigCandidate) {
        if expandedManifestID == config.id {
            expandedManifestID = nil
            return
        }
        expandedManifestID = config.id
        if manifestEntriesByID[config.id] != nil {
            return
        }
        guard let manager = app?.sourceManager else { return }
        loadingManifestID = config.id
        errorMessage = nil

        Task {
            defer {
                if loadingManifestID == config.id {
                    loadingManifestID = nil
                }
            }
            do {
                let entries = try await manager.inspectGitHubManifest(at: config.rawURL)
                manifestEntriesByID[config.id] = entries
            } catch {
                errorMessage = friendlyError(error)
            }
        }
    }

    private func importCandidate(id: String,
                                 url: URL,
                                 displayName: String,
                                 initialUserVariables: [String: String]? = nil) {
        guard let manager = app?.sourceManager else { return }
        importingIDs.insert(id)
        errorMessage = nil
        statusMessage = nil

        Task {
            defer { importingIDs.remove(id) }
            do {
                let imported = try await manager.importSources(from: url, initialUserVariables: initialUserVariables)
                let normalized = SourceDomainPolicy.normalizeImportURL(url.absoluteString)?.absoluteString ?? url.absoluteString
                importedURLStrings.insert(normalized)
                finishImportFeedback(imported, originDisplayName: displayName, manager: manager)
            } catch {
                errorMessage = friendlyError(error)
            }
        }
    }

    private func importPresetItem(_ preset: ExternalAPIPreset) {
        guard let manager = app?.sourceManager else { return }
        let key = "preset:\(preset.id)"
        importingIDs.insert(key)
        errorMessage = nil
        statusMessage = nil

        Task {
            defer { importingIDs.remove(key) }
            do {
                let imported = try await manager.importPreset(preset)
                finishImportFeedback(imported, originDisplayName: preset.localizedDisplayName, manager: manager)
            } catch {
                errorMessage = friendlyError(error)
            }
        }
    }

    private func importAllPresets(_ presets: [ExternalAPIPreset]) {
        guard let manager = app?.sourceManager else { return }
        importingIDs.insert("__all_presets__")
        errorMessage = nil
        statusMessage = nil

        Task {
            defer { importingIDs.remove("__all_presets__") }
            var allImported: [SourceManager.ManagedSource] = []
            var firstError: (any Error)?
            for preset in presets {
                do {
                    let items = try await manager.importPreset(preset)
                    allImported.append(contentsOf: items)
                } catch is CancellationError {
                    return
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if !allImported.isEmpty {
                finishImportFeedback(allImported, originDisplayName: String(localized: "多 API 预设"), manager: manager)
                if let firstError {
                    errorMessage = friendlyError(firstError)
                }
            } else if let firstError {
                errorMessage = friendlyError(firstError)
            }
        }
    }

    private func finishImportFeedback(_ imported: [SourceManager.ManagedSource],
                                      originDisplayName: String,
                                      manager: SourceManager) {
        if imported.count > 1 {
            statusMessage = String(localized: "已导入 \(imported.count) 个音源")
        } else if let first = imported.first {
            let hasVars = !manager.userVariableSpecs(for: first.id).isEmpty
            statusMessage = hasVars
                ? String(localized: "已导入「\(first.descriptor.displayName)」，可在音源列表点击钥匙按钮配置参数")
                : String(localized: "已导入：\(first.descriptor.displayName)")
        }
        onImported(imported, originDisplayName)
    }

    private func friendlyError(_ error: any Error) -> String {
        if let playback = error as? PlaybackError, playback == .networkDisabled {
            return String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再搜索。")
        }
        if let violation = error as? SourceDomainPolicy.Violation, case .networkDisabled = violation {
            return String(localized: "联网已关闭，请先到 设置 → 通用 开启「允许联网」后再搜索。")
        }
        return SourceErrorPresentation.friendly(error)
    }

    private static func formatStars(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
