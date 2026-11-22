import AppKit
import SwiftUI
import Translation

/// 在线检索 HuggingFace（默认镜像源）/ GitHub RVC 模型或通过直链下载并自动导入音色包，无需再手动选文件。
struct VoiceModelFetchSheet: View {
    enum FetchTab: String, CaseIterable, Identifiable {
        case curated = "curated"
        case huggingFace = "huggingface"
        case github = "github"
        case directURL = "directURL"

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .curated: return "精选"
            case .huggingFace: return "HuggingFace"
            case .github: return "GitHub"
            case .directURL: return "URL 直链"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.app) private var app

    let onImported: (VoicePackManifest) -> Void

    @State private var selectedTab: FetchTab = .curated
    @State private var searchQuery = "rvc onnx"
    @State private var directURLInput = ""
    @State private var directNameInput = ""
    @State private var hasAutoSearched = false
    @State private var importingCuratedID: String?

    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var repos: [VoiceModelRepoSummary] = []
    @State private var selectedRepo: VoiceModelRepoSummary?

    @State private var isInspectingRepo = false
    @State private var remoteFiles: [VoiceModelRemoteFile] = []

    @State private var importedFileIDs: Set<String> = []
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var inspectTask: Task<Void, Never>?
    /// 切页签会清空提示；从直链跳到仓库检索时要在切换后再显示这句说明。
    @State private var pendingTabStatus: String?
    /// 直链下载开始时锁定的标识：下载中改输入框不会让进度消失、也不能再点一次。
    @State private var activeDirectDownloadID: String?

    /// 「精选」页的可下载卡片：先放内置清单，打开后自动检索补充。
    @State private var onlineVoices: [VoiceModelRemoteFile] = OnlineVoiceCatalog.seedFiles
    @State private var isDiscovering = false
    @State private var discoveryUnreachable = false
    @State private var hasDiscovered = false
    @State private var discoveryTask: Task<Void, Never>?
    /// 系统翻译失败（用户没下载语言包等）后，留一个按钮让用户再试；加一次就重新请求翻译。
    @State private var translationAttempt = 0
    @State private var translationFailed = false

    private static let quickKeywords: [(label: String, query: String)] = [
        ("ozada/onnx_rvc", "ozada/onnx_rvc"),
        ("rvc onnx", "rvc onnx"),
        ("voicepack", "voicepack"),
        ("onnx_rvc", "onnx_rvc")
    ]

    init(onImported: @escaping (VoicePackManifest) -> Void = { _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.s)

            modeAndSearchBar
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)

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
        .frame(width: 720, height: 520)
        .task {
            // 打开即自动获取：精选卡片先显示内置清单，联网时在后台补充最新的可下载音色。
            guard !hasAutoSearched else { return }
            hasAutoSearched = true
            discoverOnlineVoices()
            guard selectedTab == .huggingFace || selectedTab == .github,
                  app?.voice?.isNetworkEnabled == true else { return }
            triggerSearch()
        }
        .voiceNameTranslation(
            pending: pendingTranslations,
            attempt: translationAttempt,
            onTranslated: { translated in
                // 系统翻不出中文的名字（例如连写的人名）保持英文，不算失败、也不反复弹按钮。
                app?.voice?.nameTranslations.store(translated)
                translationFailed = false
            },
            onFailure: { translationFailed = true }
        )
        .onDisappear {
            searchTask?.cancel()
            inspectTask?.cancel()
            discoveryTask?.cancel()
        }
    }

    // MARK: - Header & Controls

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("在线获取 RVC 音色")
                    .flowType(.homeTitle)
                Text("下载完成后自动导入音色列表，无需再手动挑选文件。")
                    .flowType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let voice = app?.voice {
                FlowCaption(verbatim: voice.mirrorMode.displayName)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var modeAndSearchBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker("获取方式", selection: $selectedTab) {
                ForEach(FetchTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedTab) { _, newTab in
                // 上一个页签的检索还在跑的话，结果不能落到新页签上。
                searchTask?.cancel()
                inspectTask?.cancel()
                isSearching = false
                isInspectingRepo = false
                errorMessage = nil
                statusMessage = nil
                repos = []
                selectedRepo = nil
                remoteFiles = []
                hasSearched = false
                // 切到检索页签时同样自动查一次，不用再手动点「搜索」。
                if (newTab == .huggingFace || newTab == .github), app?.voice?.isNetworkEnabled == true {
                    triggerSearch()
                }
                if let pendingTabStatus {
                    statusMessage = pendingTabStatus
                    self.pendingTabStatus = nil
                }
            }

            if selectedTab == .huggingFace || selectedTab == .github {
                HStack(spacing: Spacing.xs) {
                    TextField(
                        selectedTab == .huggingFace
                            ? "输入关键词或 owner/repo（如 ozada/onnx_rvc）"
                            : "输入 GitHub 搜索词或 owner/repo",
                        text: $searchQuery
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { triggerSearch() }

                    FlowTextButton(
                        title: isSearching ? "搜索中…" : "搜索",
                        symbolName: "magnifyingglass"
                    ) {
                        triggerSearch()
                    }
                    .disabled(isSearching)
                }

                if selectedTab == .huggingFace {
                    HStack(spacing: 6) {
                        Text("常用检索：")
                            .flowType(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Self.quickKeywords, id: \.query) { preset in
                            Button {
                                searchQuery = preset.query
                                triggerSearch()
                            } label: {
                                Text(verbatim: preset.label)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Main Area

    @ViewBuilder
    private var mainContent: some View {
        if selectedTab == .curated {
            curatedPane
        } else if selectedTab == .directURL {
            directURLPane
        } else {
            HSplitView {
                repoListPane
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
                fileListPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var repoListPane: some View {
        Group {
            if isSearching {
                VStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("正在检索模型仓库…")
                        .flowType(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repos.isEmpty {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    if hasSearched {
                        Text("未找到包含 RVC 模型文件的公开仓库")
                            .flowType(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("点击「搜索」或直接输入 owner/repo 获取可用音色")
                            .flowType(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(repos, selection: Binding(
                    get: { selectedRepo?.id },
                    set: { id in
                        if let id, let target = repos.first(where: { $0.id == id }) {
                            selectRepo(target)
                        }
                    }
                )) { repo in
                    Button {
                        selectRepo(repo)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(verbatim: repo.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if repo.onnxFileCount > 0 {
                                    Text(verbatim: "\(repo.onnxFileCount) ONNX")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                }
                            }
                            Text(verbatim: repo.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(repo.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var fileListPane: some View {
        Group {
            if isInspectingRepo {
                VStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("正在扫描仓库内的音色模型文件…")
                        .flowType(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedRepo == nil {
                VStack(spacing: Spacing.xs) {
                    Text("从左侧选择一个模型仓库查看可下载的音色")
                        .flowType(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remoteFiles.isEmpty {
                VStack(spacing: Spacing.xs) {
                    Text("这个仓库里没有能直接使用的音色")
                        .flowType(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("有些仓库只放了 .pth 训练权重，需要先在电脑上转换成音色包才能使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("每一项就是一个音色，名字通常就是角色或歌手名，导入后可以重命名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 6)
                    List(remoteFiles) { file in
                        remoteFileRow(file)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func remoteFileRow(_ file: VoiceModelRemoteFile) -> some View {
        let voice = app?.voice
        let isDownloading = voice?.downloadingRemoteModelIDs.contains(file.id) ?? false
        let progress = voice?.remoteModelDownloadProgress[file.id] ?? 0
        let isImported = importedFileIDs.contains(file.id)

        return HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(verbatim: file.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let sizeText = file.formattedSize {
                        Text(verbatim: "· \(sizeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if file.companionIndexURL != nil {
                        Text("· 含索引")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer(minLength: 8)

            if isDownloading {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 64)
                    Text(verbatim: "\(Int((progress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    FlowIconButton(systemName: "xmark.circle", label: "取消下载", size: 24, symbolSize: 12) {
                        voice?.cancelDownload(file.id)
                    }
                }
            } else if isImported {
                Label("已导入", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                FlowTextButton(title: "下载并导入", symbolName: "arrow.down.circle") {
                    downloadAndImport(file)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 精选卡片

    private var curatedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Text("可直接下载").flowType(.homeControl)
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                        Text("正在获取最新音色…").flowType(.caption).foregroundStyle(.secondary)
                    } else if discoveryUnreachable {
                        Text("暂时连不上 HuggingFace，先显示内置的音色。")
                            .flowType(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if showsTranslateButton {
                        FlowTextButton(title: "翻译成中文", symbolName: "character.bubble") {
                            translationFailed = false
                            translationAttempt += 1
                        }
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: Spacing.m)],
                    spacing: Spacing.m
                ) {
                    ForEach(onlineVoices) { file in
                        onlineVoiceCard(file)
                    }
                }

                Text("角色音色（需要先在电脑上转换）").flowType(.homeControl)
                    .padding(.top, Spacing.s)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: Spacing.m)],
                    spacing: Spacing.m
                ) {
                    ForEach(CuratedVoiceCatalog.all) { item in
                        curatedCard(item)
                    }
                }

                Text("转换好的音色包放在 \(CuratedVoiceCatalog.packsDirectoryDisplayPath) 时，卡片可直接导入。")
                    .font(.caption2)
                    .foregroundStyle(FlowColor.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.m)
        }
    }

    private func englishName(_ file: VoiceModelRemoteFile) -> String {
        VoiceNameLocalizer.englishName(fromFileName: file.fileName)
    }

    private func cardName(_ file: VoiceModelRemoteFile) -> String {
        let english = englishName(file)
        return app?.voice?.nameTranslations.displayName(for: english) ?? english
    }

    private var pendingTranslations: [String] {
        guard VoiceNameLocalizer.wantsChinese, let voice = app?.voice else { return [] }
        return voice.nameTranslations.pending(onlineVoices.map(englishName))
    }

    private var showsTranslateButton: Bool {
        guard #available(macOS 15.0, *) else { return false }
        return translationFailed && !pendingTranslations.isEmpty
    }

    private func onlineVoiceCard(_ file: VoiceModelRemoteFile) -> some View {
        let voice = app?.voice
        let name = cardName(file)
        let english = englishName(file)
        let existingPack = voice?.importedPack(for: file)
        let isDownloading = voice?.downloadingRemoteModelIDs.contains(file.id) ?? false
        let progress = voice?.remoteModelDownloadProgress[file.id] ?? 0
        let detail = [name == english ? nil : english, file.formattedSize].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Self.gradient(seed: file.id))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Text(verbatim: String(name.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.headline)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Text("来源：\(file.repoID)")
                .font(.caption2)
                .foregroundStyle(FlowColor.tertiaryText)
                .lineLimit(1)

            HStack(spacing: Spacing.s) {
                if isDownloading {
                    ProgressView(value: progress)
                        .frame(maxWidth: .infinity)
                    Text(verbatim: "\(Int((progress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    FlowIconButton(systemName: "xmark.circle", label: "取消下载", size: 24, symbolSize: 12) {
                        voice?.cancelDownload(file.id)
                    }
                } else if let pack = existingPack {
                    Label("已导入", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer(minLength: 0)
                    if voice?.selectedPack?.packID == pack.packID {
                        Text("使用中").font(.caption).foregroundStyle(.secondary)
                    } else {
                        FlowTextButton(title: "使用", symbolName: "play.circle") {
                            voice?.selectPack(pack.packID)
                            statusMessage = String(localized: "已切换到音色：\(pack.displayName)")
                        }
                    }
                } else {
                    FlowTextButton(title: "下载并导入", symbolName: "arrow.down.circle") {
                        downloadCard(file, name: name)
                    }
                    .disabled(voice?.isNetworkEnabled != true)
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowColor.hairline, lineWidth: 1)
        )
    }

    /// 按标识稳定取色：同一个音色每次打开颜色一致。
    private static func gradient(seed: String) -> LinearGradient {
        let palette: [(Color, Color)] = [
            (Color(red: 0.36, green: 0.55, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.9)),
            (Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.9, green: 0.36, blue: 0.5)),
            (Color(red: 0.3, green: 0.75, blue: 0.65), Color(red: 0.25, green: 0.5, blue: 0.85)),
            (Color(red: 0.95, green: 0.65, blue: 0.3), Color(red: 0.95, green: 0.4, blue: 0.55)),
            (Color(red: 0.55, green: 0.6, blue: 0.7), Color(red: 0.35, green: 0.4, blue: 0.55)),
        ]
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        let pair = palette[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func discoverOnlineVoices() {
        guard let voice = app?.voice, voice.isNetworkEnabled, !hasDiscovered else { return }
        hasDiscovered = true
        isDiscovering = true
        discoveryTask?.cancel()
        discoveryTask = Task {
            let result = await voice.discoverOnlineVoices()
            guard !Task.isCancelled else { return }
            isDiscovering = false
            discoveryUnreachable = !result.reachable
            onlineVoices = OnlineVoiceCatalog.merged(seed: OnlineVoiceCatalog.seedFiles, discovered: result.files)
        }
    }

    private func downloadCard(_ file: VoiceModelRemoteFile, name: String) {
        guard let voice = app?.voice else { return }
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let manifest = try await voice.downloadAndImportRemoteModel(file, displayName: name)
                statusMessage = String(localized: "已下载并自动导入音色：\(manifest.displayName)")
                onImported(manifest)
            } catch {
                guard !Self.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func curatedCard(_ item: CuratedVoice) -> some View {
        let voice = app?.voice
        let existingPack = voice?.packs.first { $0.displayName == item.displayName }
        let ready = CuratedVoiceCatalog.hasLocalPack(for: item)
        let importing = importingCuratedID == item.id

        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 10) {
                Circle()
                    .fill(accentGradient(for: item))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Text(verbatim: String(item.displayName.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.displayName)
                        .font(.headline)
                    Text(verbatim: item.work)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(verbatim: "来源：\(item.sourceRepo)")
                .font(.caption2)
                .foregroundStyle(FlowColor.tertiaryText)
                .lineLimit(1)

            HStack(spacing: Spacing.s) {
                if importing {
                    ProgressView().controlSize(.small)
                    Text("正在导入…").font(.caption).foregroundStyle(.secondary)
                } else if let pack = existingPack {
                    Label("已导入", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer(minLength: 0)
                    FlowTextButton(title: "使用", symbolName: "play.circle") {
                        voice?.selectPack(pack.packID)
                        statusMessage = String(localized: "已切换到音色：\(item.displayName)")
                    }
                } else if ready {
                    FlowTextButton(title: "导入", symbolName: "arrow.down.circle") {
                        importCurated(item)
                    }
                } else {
                    Text("尚未转换")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    FlowTextButton(title: "打开源站", symbolName: "safari") {
                        if let url = URL(string: "https://huggingface.co/\(item.sourceRepo)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowColor.hairline, lineWidth: 1)
        )
    }

    private func accentGradient(for item: CuratedVoice) -> LinearGradient {
        let colors: [Color] = switch item.id {
        case "tomori": [Color(red: 0.36, green: 0.55, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.9)]
        case "manbo": [Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.9, green: 0.36, blue: 0.5)]
        default: [Color(red: 0.95, green: 0.65, blue: 0.3), Color(red: 0.95, green: 0.4, blue: 0.55)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func importCurated(_ item: CuratedVoice) {
        guard let voice = app?.voice else { return }
        importingCuratedID = item.id
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { importingCuratedID = nil }
            do {
                let manifest = try await voice.importPack(
                    weightURL: CuratedVoiceCatalog.localPackURL(for: item),
                    displayName: item.displayName
                )
                statusMessage = String(localized: "已导入音色：\(manifest.displayName)")
                onImported(manifest)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var directURLPane: some View {
        let trackingID = activeDirectDownloadID ?? directTrackingID
        let voice = app?.voice
        let isDownloading = voice?.downloadingRemoteModelIDs.contains(trackingID) ?? false
        let progress = voice?.remoteModelDownloadProgress[trackingID] ?? 0

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("音色模型下载链接（.onnx）")
                        .flowType(.body)
                    TextField(
                        "https://huggingface.co/.../resolve/main/model.onnx",
                        text: $directURLInput
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("可以直接粘贴 HuggingFace 或 GitHub 的文件页面链接，会按当前下载通道下载并自动导入。粘贴仓库或 .voicepack 文件夹链接时，会切到仓库检索。")
                        .flowType(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("显示名称（可选）")
                        .flowType(.body)
                    TextField("留空时自动从文件名识别", text: $directNameInput)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: Spacing.s) {
                    if isDownloading {
                        ProgressView(value: progress)
                            .frame(width: 120)
                        Text(verbatim: "\(Int((progress * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        FlowIconButton(systemName: "xmark.circle", label: "取消下载", size: 24, symbolSize: 12) {
                            voice?.cancelDownload(trackingID)
                        }
                    }
                    FlowTextButton(
                        title: isDownloading ? "正在下载并导入…" : "下载并自动导入",
                        symbolName: "arrow.down.circle.fill"
                    ) {
                        downloadDirectURL()
                    }
                    .disabled(isDownloading || directURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Spacing.m)
        }
    }

    private var footerBar: some View {
        HStack(spacing: Spacing.s) {
            if let voice = app?.voice, !voice.isNetworkEnabled {
                Text("当前已关闭应用联网，请先开启联网后再搜索下载。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                FlowTextButton(title: "允许联网", symbolName: "network") {
                    Task {
                        await app?.setEnableNetwork(true)
                        voice.refreshEnvironmentStatus()
                        errorMessage = nil
                        discoverOnlineVoices()
                        if selectedTab == .huggingFace || selectedTab == .github { triggerSearch() }
                    }
                }
            } else {
                Text("模型文件优先走下载通道，失败时回退官方源；在线检索需要能访问 HuggingFace 或 GitHub。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var directTrackingID: String {
        let trimmed = directURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = VoiceModelDiscovery.normalizedDirectModelURL(from: trimmed)?.absoluteString ?? trimmed
        return "direct:\(normalized)"
    }

    // MARK: - Actions

    private func triggerSearch() {
        guard let voice = app?.voice else { return }
        guard voice.isNetworkEnabled else {
            errorMessage = String(localized: "已在设置中关闭联网，请先开启联网后再搜索。")
            return
        }
        let platform: VoiceModelSearchPlatform = (selectedTab == .github) ? .github : .huggingFace
        let q = searchQuery
        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        errorMessage = nil
        statusMessage = nil
        selectedRepo = nil
        remoteFiles = []

        searchTask = Task {
            do {
                let result = try await voice.searchVoiceModelRepos(query: q, platform: platform)
                guard !Task.isCancelled else { return }
                repos = result
                isSearching = false
                if let first = result.first {
                    selectRepo(first)
                }
            } catch {
                // 被新检索/切页签取消的旧请求：状态由新请求负责，别把"已取消"写成错误。
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                isSearching = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func selectRepo(_ repo: VoiceModelRepoSummary) {
        guard let voice = app?.voice else { return }
        selectedRepo = repo
        inspectTask?.cancel()
        isInspectingRepo = true
        remoteFiles = []
        errorMessage = nil

        inspectTask = Task {
            do {
                let files = try await voice.inspectVoiceModelRepo(repo)
                guard !Task.isCancelled else { return }
                remoteFiles = files
                isInspectingRepo = false
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                isInspectingRepo = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func downloadAndImport(_ file: VoiceModelRemoteFile) {
        guard let voice = app?.voice else { return }
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let manifest = try await voice.downloadAndImportRemoteModel(file)
                importedFileIDs.insert(file.id)
                statusMessage = String(localized: "已下载并自动导入音色：\(manifest.displayName)")
                onImported(manifest)
            } catch {
                guard !Self.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func downloadDirectURL() {
        guard let voice = app?.voice else { return }
        let trimmed = directURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: URL
        switch VoiceModelDiscovery.classifyDirectLink(trimmed) {
        case let .requiresConversion(ext):
            // 直接说清原因，避免下载几百 MB 的权重再报一个看不懂的错。
            errorMessage = VoiceModelDiscovery.archiveExtensions.contains(ext)
                ? String(localized: "这是压缩包，App 不能直接下载使用。请先下载并解压，再把里面的 .voicepack 文件夹拖进来导入。")
                : String(localized: "这是训练用的 .pth / .index 文件，App 不能直接使用，需要先在电脑上转换成音色包。")
            return
        case let .repository(repoID, platform):
            let targetTab: FetchTab = platform == .github ? .github : .huggingFace
            searchQuery = repoID
            pendingTabStatus = String(localized: "这是仓库或音色包文件夹的链接，已切换到仓库检索，在右侧选一个音色下载即可。")
            if selectedTab == targetTab {
                triggerSearch()
                statusMessage = pendingTabStatus
                pendingTabStatus = nil
            } else {
                selectedTab = targetTab
            }
            return
        case let .modelFile(url):
            parsed = url
        case .invalid:
            errorMessage = String(localized: "请输入有效的 HTTPS/HTTP 模型文件地址。")
            return
        }
        errorMessage = nil
        statusMessage = nil
        let customName = directNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        activeDirectDownloadID = "direct:\(parsed.absoluteString)"
        Task {
            defer { activeDirectDownloadID = nil }
            do {
                let manifest = try await voice.downloadAndImportPack(
                    from: parsed,
                    displayName: customName.isEmpty ? nil : customName
                )
                statusMessage = String(localized: "已下载并自动导入音色：\(manifest.displayName)")
                directURLInput = ""
                directNameInput = ""
                onImported(manifest)
            } catch {
                guard !Self.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}


// MARK: - 音色名自动翻译（macOS 15+ 系统翻译）

private extension View {
    /// 把还没有中文译名的英文音色名交给系统翻译；第一次会由系统询问是否下载语言包，之后离线可用。
    @ViewBuilder
    func voiceNameTranslation(
        pending: [String],
        attempt: Int,
        onTranslated: @escaping @MainActor ([String: String]) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            modifier(VoiceNameTranslationModifier(
                pending: pending,
                attempt: attempt,
                onTranslated: onTranslated,
                onFailure: onFailure
            ))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct VoiceNameTranslationModifier: ViewModifier {
    /// 动作在非隔离上下文里创建：会话不会跨主线程传递（Swift 6 区域隔离要求）。
    nonisolated static func translationAction(
        names: [String],
        onTranslated: @escaping @MainActor ([String: String]) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) -> (TranslationSession) async -> Void {
        { session in
            guard !names.isEmpty else { return }
            do {
                let requests = names.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                let responses = try await session.translations(from: requests)
                var translated: [String: String] = [:]
                for response in responses {
                    translated[response.clientIdentifier ?? response.sourceText] = response.targetText
                }
                await onTranslated(translated)
            } catch {
                await onFailure()
            }
        }
    }

    struct Trigger: Equatable {
        let pending: [String]
        let attempt: Int
    }

    let pending: [String]
    let attempt: Int
    let onTranslated: @MainActor ([String: String]) -> Void
    let onFailure: @MainActor () -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var lastAttempt = -1
    @State private var requested: Set<String> = []

    func body(content: Content) -> some View {
        content
            .translationTask(
                configuration,
                action: Self.translationAction(names: pending, onTranslated: onTranslated, onFailure: onFailure)
            )
            .onChange(of: Trigger(pending: pending, attempt: attempt), initial: true) { _, trigger in
                // 自动获取补充了新名字时再翻一次；名单没变不重复请求；
                // 用户点「翻译成中文」会加 attempt 强制重来。
                guard !trigger.pending.isEmpty else { return }
                let hasNewNames = !Set(trigger.pending).isSubset(of: requested)
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "zh-Hans")
                    )
                } else if hasNewNames || trigger.attempt != lastAttempt {
                    configuration?.invalidate()
                }
                requested.formUnion(trigger.pending)
                lastAttempt = trigger.attempt
            }
    }
}
