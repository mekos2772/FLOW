import SwiftUI

/// 歌词区的「换一版歌词 / 手动搜词与持久化绑定」右键菜单。
///
/// 展开播放器默认歌词与编辑式版式挂同一份修饰器：
/// - 切换当前歌名/歌手手打搜索 **AMLL 逐字** 与 **LRCLIB**；
/// - 将选中的版本按 `TrackIdentity` 持久化绑定，高于自动匹配与 CC 字幕优先级；
/// - 支持一键解除绑定恢复自动匹配。
struct LyricVariantMenu: ViewModifier {
    @Bindable var model: MorphPresentationModel

    @Environment(\.app) private var app
    @State private var isLoading = false
    @State private var keywordQuery = ""
    @State private var artistQuery = ""
    @State private var candidates: [LyricVariantCandidate] = []
    @State private var note: String?
    @State private var hoveredID: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var applyTask: Task<Void, Never>?
    @State private var applyGeneration = 0

    private var boundRecord: BoundLyricRecord? {
        guard let store = app?.lyricBindings, let track = model.track else { return nil }
        _ = store.revision
        return store.binding(for: track.identity)
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let showingTranslation = app?.appearance.showLyricTranslation ?? model.showLyricTranslation
                Button(showingTranslation ? "隐藏中文译文" : "显示中文译文") {
                    let next = !showingTranslation
                    if let app {
                        app.setShowLyricTranslation(next)
                    } else {
                        model.showLyricTranslation = next
                    }
                }
                Button("换一版歌词…") {
                    model.showsLyricPicker = true
                }
                if boundRecord != nil {
                    Button("恢复自动匹配歌词") {
                        triggerClearBinding()
                    }
                }
                if !candidates.isEmpty {
                    Divider()
                    ForEach(candidates) { candidate in
                        Button {
                            triggerApply(candidate)
                        } label: {
                            Text(verbatim: "\(candidate.describe) [\(candidate.sourceBadge)]")
                        }
                    }
                }
            }
            .popover(isPresented: $model.showsLyricPicker, arrowEdge: .trailing) {
                pickerContent
            }
            .onChange(of: model.showsLyricPicker) { _, isShown in
                if isShown {
                    preparePicker()
                }
            }
            .onChange(of: model.track?.identity) { _, _ in
                searchTask?.cancel()
                searchTask = nil
                applyTask?.cancel()
                applyTask = nil
                applyGeneration &+= 1
                model.showsLyricPicker = false
                isLoading = false
                keywordQuery = ""
                artistQuery = ""
                candidates = []
                note = nil
            }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("选择歌词版本")
                    .flowType(.homeTitle)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if let bound = boundRecord {
                HStack(spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("已手动绑定")
                                .flowType(.homeSecondary)
                                .foregroundStyle(FlowColor.tertiaryText)
                            Text(verbatim: bound.providerName)
                                .flowType(.homeSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(FlowColor.emphasis(model.ambient?.swiftUIColor).opacity(0.16),
                                            in: Capsule())
                        }
                        Text(verbatim: bound.describe)
                            .flowType(.homeControl)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Button("恢复自动") {
                        triggerClearBinding()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(FlowColor.hover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.control))
            }

            VStack(spacing: 6) {
                TextField("输入歌名或「歌手 - 歌名」", text: $keywordQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { triggerManualSearch() }
                HStack(spacing: 6) {
                    TextField("歌手（可选）", text: $artistQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { triggerManualSearch() }
                    Button("搜索") {
                        triggerManualSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSearchButtonDisabled)
                }
            }

            if let note {
                Text(note)
                    .flowType(.homeSecondary)
                    .foregroundStyle(FlowColor.secondaryText)
            }

            if !candidates.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(height: candidateListHeight)
            }
        }
        .padding(Spacing.m)
        .frame(width: 368)
    }

    private var candidateListHeight: CGFloat {
        // macOS NSPopover 下 ScrollView 仅写 maxHeight 会被压缩为 0；按条目显式计算理想高并封顶 240pt。
        let rowsHeight = candidates.reduce(CGFloat(0)) { partial, item in
            partial + (item.secondarySummary.isEmpty ? 32 : 48)
        }
        let spacing = CGFloat(max(0, candidates.count - 1)) * 4
        return min(240, max(40, rowsHeight + spacing + 4))
    }

    private func candidateRow(_ candidate: LyricVariantCandidate) -> some View {
        let matched = isBoundCandidate(candidate)
        return Button {
            triggerApply(candidate)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.trackName)
                        .flowType(.homeControl)
                        .fontWeight(matched ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !candidate.secondarySummary.isEmpty {
                        Text(verbatim: candidate.secondarySummary)
                            .flowType(.homeSecondary)
                            .foregroundStyle(FlowColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                Text(verbatim: candidate.sourceBadge)
                    .flowType(.homeSecondary)
                    .foregroundStyle(candidate.source == .amll
                                     ? FlowColor.emphasis(model.ambient?.swiftUIColor)
                                     : FlowColor.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        candidate.source == .amll
                            ? FlowColor.emphasis(model.ambient?.swiftUIColor).opacity(0.14)
                            : FlowColor.hover,
                        in: Capsule()
                    )
                if matched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowColor.emphasis(model.ambient?.swiftUIColor))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                hoveredID == candidate.id ? FlowColor.hover : (matched ? FlowColor.hover.opacity(0.5) : .clear),
                in: RoundedRectangle(cornerRadius: Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? candidate.id : (hoveredID == candidate.id ? nil : hoveredID)
        }
    }

    private var isSearchButtonDisabled: Bool {
        let k = keywordQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLoading || (k.isEmpty && a.isEmpty)
    }

    private func isBoundCandidate(_ candidate: LyricVariantCandidate) -> Bool {
        guard let bound = boundRecord else { return false }
        if let boundID = bound.sourceIdentifier {
            return boundID == candidate.id
        }
        let expectedProvider = candidate.source == .amll ? "AMLL" : "LRCLIB"
        return bound.providerName == expectedProvider
            && bound.trackName == candidate.trackName
            && bound.artistName == candidate.artistName
    }

    private func preparePicker() {
        searchTask?.cancel()
        guard let track = model.track, let coordinator = app?.lyricVariants else {
            candidates = []
            note = String(localized: "当前没有可匹配歌词的曲目")
            return
        }
        let suggested = coordinator.suggestedQuery(for: track)
        keywordQuery = suggested.keyword
        artistQuery = suggested.artist
        searchTask = Task { await loadDefaultCandidates(for: track, coordinator: coordinator) }
    }

    private func triggerManualSearch() {
        searchTask?.cancel()
        guard let coordinator = app?.lyricVariants else { return }
        let keyword = keywordQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty || !artist.isEmpty else {
            note = String(localized: "请输入歌名或歌手关键词")
            return
        }
        let track = model.track
        searchTask = Task {
            await performManualSearch(keyword: keyword, artist: artist, track: track, coordinator: coordinator)
        }
    }

    private func loadDefaultCandidates(for track: Track, coordinator: LyricVariantCoordinator) async {
        isLoading = true
        note = String(localized: "正在搜索候选歌词…")
        let found = await coordinator.defaultCandidates(for: track)
        guard !Task.isCancelled, model.track?.identity == track.identity else { return }
        isLoading = false
        candidates = found
        note = found.isEmpty ? emptyResultMessage(coordinator: coordinator) : nil
    }

    private func performManualSearch(keyword: String, artist: String, track: Track?,
                                     coordinator: LyricVariantCoordinator) async {
        isLoading = true
        note = String(localized: "正在搜索候选歌词…")
        let found = await coordinator.search(keyword: keyword, artist: artist, for: track)
        guard !Task.isCancelled, model.track?.identity == track?.identity else { return }
        isLoading = false
        candidates = found
        note = found.isEmpty ? emptyResultMessage(coordinator: coordinator) : nil
    }

    private func emptyResultMessage(coordinator: LyricVariantCoordinator) -> String {
        coordinator.networkAllowed()
            ? String(localized: "未找到匹配的同步歌词")
            : String(localized: "离线模式下仅可检索本地缓存，未找到匹配歌词")
    }

    private func triggerApply(_ candidate: LyricVariantCandidate) {
        applyTask?.cancel()
        applyGeneration &+= 1
        let generation = applyGeneration
        applyTask = Task { await apply(candidate, generation: generation) }
    }

    private func triggerClearBinding() {
        applyTask?.cancel()
        applyGeneration &+= 1
        let generation = applyGeneration
        applyTask = Task { await clearBinding(generation: generation) }
    }

    private func apply(_ candidate: LyricVariantCandidate, generation: Int) async {
        guard let track = model.track, let coordinator = app?.lyricVariants else { return }
        isLoading = true
        let doc = await coordinator.apply(candidate, for: track)
        guard !Task.isCancelled, applyGeneration == generation, model.track?.identity == track.identity else { return }
        isLoading = false
        if let doc, !doc.lines.isEmpty {
            note = String(localized: "已绑定《\(candidate.trackName)》")
        } else {
            note = String(localized: "这版没有同步歌词")
        }
    }

    private func clearBinding(generation: Int) async {
        guard let track = model.track, let coordinator = app?.lyricVariants else { return }
        isLoading = true
        await coordinator.clearBinding(for: track)
        guard !Task.isCancelled, applyGeneration == generation, model.track?.identity == track.identity else { return }
        isLoading = false
        note = String(localized: "已恢复自动匹配")
    }
}

extension View {
    /// 给任意歌词版式挂上统一的「换一版」菜单。
    func lyricVariantMenu(model: MorphPresentationModel) -> some View {
        modifier(LyricVariantMenu(model: model))
    }
}
