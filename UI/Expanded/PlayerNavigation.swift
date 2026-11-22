import SwiftUI

/// 主窗口固定导航，页面选择不触碰播放引擎。
struct PlayerSidebar: View {
    @Bindable var model: MorphPresentationModel
    @Environment(\.app) private var app
    var onBrowse: () -> Void
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 6) {
            // 正在播放是用户最关心的目标，提到第一位：歌在响时它该伸手就够到，
            // 不该埋在收藏/最近播放之后。Spotify/Apple Music 的 Now Playing 都在顶级。
            if model.track != nil {
                item("正在播放", symbol: "waveform", active: !model.showsHome) {
                    model.showPlayer()
                    app?.noteAuxiliaryActivity(false)
                }
            }
            navigation("首页", symbol: "house", section: .recommendations)
            if !model.home.submittedQuery.isEmpty {
                navigation("搜索结果", symbol: "magnifyingglass", section: .search)
            }
            navigation("收藏", symbol: "star", section: .favorites)
            navigation("最近播放", symbol: "clock", section: .recent)
            navigation("歌单", symbol: "music.note.list", section: .playlists)
            navigation("离线", symbol: "arrow.down.circle", section: .offline)
            Spacer(minLength: isCompact ? 4 : 16)
            item("设置", symbol: "slider.horizontal.3", active: model.auxiliary == .settings) {
                model.auxiliary = model.auxiliary == .settings ? nil : .settings
                app?.noteAuxiliaryActivity(model.auxiliary != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 4 : 16)
        .frame(maxHeight: .infinity)
        .background(FlowColor.hover.opacity(0.5))
    }

    private func navigation(_ title: LocalizedStringKey, symbol: String, section: OnlineHomeState.Section) -> some View {
        item(title, symbol: symbol, active: model.showsHome && model.home.section == section) {
            onBrowse()
            model.browse(section, app: app)
            app?.noteAuxiliaryActivity(false)
        }
    }

    private func item(_ title: LocalizedStringKey, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // 侧栏图标也走 Beadline：Label(systemImage:) 渲染的是 SF，换自定义视图。
                flowIcon(systemName: symbol, size: 15)
                Text(title)
            }
                .flowType(.homeControl)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: isCompact ? 32 : 42)
                .background(active ? FlowColor.pressed : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct PlayerSearchField: View {
    @Bindable var model: MorphPresentationModel
    @Environment(\.app) private var app
    @FocusState private var focused: Bool

    var body: some View {
        content
            // 空态"去搜索"按钮 bump 这个计数器时，把焦点拉进输入框。
            .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
    }

    private var content: some View {
        HStack(spacing: 10) {
            FlowIconView(glyph: .search, size: 14).foregroundStyle(FlowColor.secondaryText)
            TextField("搜索歌名或歌手", text: Binding(get: { model.home.query }, set: {
                model.home.query = $0
                model.home.queryEdited()
            }))
            .textFieldStyle(.plain)
            .flowType(.homeControl)
            .focused($focused)
            .onSubmit(submit)
            .accessibilityIdentifier("home.search")
            if !model.home.query.isEmpty {
                FlowIconButton(systemName: "xmark.circle.fill", label: "清除搜索", size: 28,
                               symbolSize: 14, prominent: true) {
                    model.home.query = ""
                    model.home.queryEdited()
                }
            }
            if let manager = app?.sourceManager,
               manager.browsableSources.filter(\.descriptor.supportsSearch).count > 1 {
                Button {
                    manager.aggregateSearchEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        flowIcon(systemName: manager.aggregateSearchEnabled ? "square.stack.3d.up.fill" : "square.stack", size: 12)
                        Text(manager.aggregateSearchEnabled ? "全源" : "单源")
                            .flowType(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(manager.aggregateSearchEnabled ? Color.accentColor : FlowColor.secondaryText)
                    .background(FlowColor.pressed.opacity(manager.aggregateSearchEnabled ? 0.65 : 0.3),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.aggregateSearchEnabled
                      ? String(localized: "正在聚合搜索全部已启用音源")
                      : String(localized: "仅搜索当前选中音源"))
                .accessibilityIdentifier("home.search.aggregateToggle")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(FlowColor.hover, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(focused ? Color.primary.opacity(0.3) : .clear, lineWidth: 1)
        }
        .popover(isPresented: Binding(get: {
            focused && model.home.query.isEmpty && !model.home.recentSearches.isEmpty
        }, set: { if !$0 { focused = false } }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.home.recentSearches, id: \.self) { keyword in
                    Button { model.home.query = keyword; submit() } label: {
                        Label(keyword, systemImage: "clock")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Button("清除最近搜索") { model.home.clearRecentSearches() }
                    .buttonStyle(.plain).padding(10)
            }
            .flowType(.homeControl)
            .padding(8)
            .frame(width: 300)
        }
    }

    private func submit() {
        guard !model.home.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.showHome()
        model.home.submit(app: app)
        app?.noteAuxiliaryActivity(false)
        focused = false
    }
}
