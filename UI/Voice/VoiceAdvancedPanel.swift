import SwiftUI
import UniformTypeIdentifiers

/// 二级高级面板：音色包版本管理、实时参数微调与风格预设。
struct VoiceAdvancedPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let voice: VoiceManager
    var track: Track?

    @State private var renamingPackID: String?
    @State private var renameText = ""
    @State private var showImporter = false
    @State private var showFetchSheet = false
    @State private var versionImportTargetPackID: String?
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            FlowDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !voice.baseModelsReady {
                        missingBaseNotice
                        FlowDivider()
                    }
                    packSection
                    FlowDivider()
                    parameterSection
                    FlowDivider()
                    presetSection
                }
                .padding(18)
            }
        }
        .frame(width: 400, height: 520)
        .overlay {
            VoiceDropHighlightOverlay(isTargeted: isDropTargeted, cornerRadius: 12)
        }
        .voicePackDropDestination(into: voice, isTargeted: $isDropTargeted) { message in
            errorMessage = message
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: true
        ) { result in
            let targetID = versionImportTargetPackID
            versionImportTargetPackID = nil
            handleImport(result, targetPackID: targetID)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showFetchSheet) {
            VoiceModelFetchSheet()
        }
    }

    private var header: some View {
        HStack {
            Text("FLOW Voice").flowType(.homeTitle)
            Spacer()
            Button {
                showFetchSheet = true
            } label: {
                Label("在线获取", systemImage: "icloud.and.arrow.down")
                    .flowType(.homeControl)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            Button {
                versionImportTargetPackID = nil
                showImporter = true
            } label: {
                Label("导入音色", systemImage: "plus")
                    .flowType(.homeControl)
            }
            .buttonStyle(.plain)
            Button("完成") {
                dismiss()
            }
            .buttonStyle(.plain)
            .flowType(.homeSecondary)
            .foregroundStyle(FlowColor.secondaryText)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var missingBaseNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: voice.isEnabled ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(voice.isEnabled ? .orange : FlowColor.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text("还没有下载所需模型").flowType(.homeControl)
                Text(voice.isNetworkEnabled
                     ? "第一次生成时会自动下载，耗时较长；也可以先在 设置 → 音色 里一键下载。"
                     : "需要联网下载，或在 设置 → 音色 里导入本地模型文件。")
                    .flowType(.caption)
                    .foregroundStyle(FlowColor.secondaryText)
            }
            Spacer(minLength: 6)
            Button("去设置") {
                dismiss()
                SettingsNavigation.request(SettingsNavigation.voicePane)
                openSettings()
            }
            .buttonStyle(.plain)
            .flowType(.caption)
            .foregroundStyle(Color.primary)
        }
    }

    // MARK: - 音色包管理

    private var packSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("音色包")
            if voice.packs.isEmpty {
                Text("还没有音色。可以在 设置 → 音色 里点「在线获取…」，或把 .voicepack 文件夹 / .onnx 文件拖到这里。")
                    .flowType(.homeSecondary)
                    .foregroundStyle(FlowColor.secondaryText)
            } else {
                ForEach(voice.packs, id: \.packID) { pack in
                    packRow(pack)
                }
            }
        }
    }

    private func packRow(_ pack: VoicePackManifest) -> some View {
        let isSelected = pack.packID == voice.selectedPack?.packID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VoicePackAvatarView(coverURL: voice.coverURL(for: pack), isSelected: isSelected, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    if renamingPackID == pack.packID {
                        TextField("名称", text: $renameText)
                            .textFieldStyle(.plain)
                            .flowType(.homeControl)
                            .onSubmit {
                                do {
                                    try voice.renamePack(pack.packID, to: renameText)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                                renamingPackID = nil
                            }
                    } else {
                        Text(pack.displayName).flowType(.homeControl).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("\(pack.versions.count) 个版本").flowType(.caption)
                            .foregroundStyle(FlowColor.tertiaryText)
                        if let v = pack.selectedVersion {
                            Text("· \(v.architectureHint.uppercased()) · \(v.sampleRate / 1000)kHz")
                                .flowType(.caption)
                                .foregroundStyle(FlowColor.tertiaryText)
                        }
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary)
                } else {
                    Button("使用") {
                        voice.selectPack(pack.packID)
                        if let track {
                            Task { await voice.refreshRenderAvailability(for: track) }
                        }
                    }
                    .buttonStyle(.plain).flowType(.homeControl)
                }
                Menu {
                    Button("添加版本…") {
                        versionImportTargetPackID = pack.packID
                        showImporter = true
                    }
                    Button("重命名") {
                        renamingPackID = pack.packID
                        renameText = pack.displayName
                    }
                    Button("删除", role: .destructive) {
                        do {
                            try voice.deletePack(pack.packID)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowColor.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if pack.versions.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pack.versions, id: \.id) { ver in
                        let active = ver.id == pack.selectedVersionID
                        Button {
                            do {
                                try voice.selectVersion(packID: pack.packID, versionID: ver.id)
                                if let track {
                                    Task { await voice.refreshRenderAvailability(for: track) }
                                }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        } label: {
                            Text(ver.id)
                                .flowType(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(active ? Color.primary.opacity(0.14) : FlowColor.hover, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 转换参数

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("转换参数")
            if let pack = voice.selectedPack {
                let specs = voice.parameterSpecs(for: pack)
                ForEach(specs, id: \.key) { spec in
                    paramRow(spec, packID: pack.packID)
                }
                if let track, voice.canStartGeneration {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("按当前参数生成") {
                            Task {
                                do {
                                    voice.isEnabled = true
                                    _ = try await voice.requestRender(for: track, force: true)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .flowType(.homeSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(FlowColor.hover, in: Capsule())

                        if voice.isEnabled {
                            Button("切回原曲") {
                                Task { await voice.switchToOriginalPlayback(for: track, autoplay: false) }
                            }
                            .buttonStyle(.plain)
                            .flowType(.homeSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(FlowColor.hover, in: Capsule())
                        } else {
                            Button("播放 AI 版") {
                                Task {
                                    do { try await voice.switchToVoicePlayback(for: track, autoplay: true) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.plain)
                            .flowType(.homeSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(FlowColor.hover, in: Capsule())
                        }
                    }
                }
            } else {
                Text("选中音色后这里会出现它的参数。")
                    .flowType(.homeSecondary)
                    .foregroundStyle(FlowColor.secondaryText)
            }
        }
    }

    private func paramRow(_ spec: VoiceParameterSpec, packID: String) -> some View {
        let current = voice.parameterValue(packID: packID, key: spec.key, default: spec.defaultValue)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.title).flowType(.homeSecondary)
                Spacer()
                Text(valueText(current)).flowType(.homeSecondary)
                    .monospacedDigit()
                    .foregroundStyle(FlowColor.tertiaryText)
            }
            switch spec.control {
            case .slider:
                Slider(value: Binding(
                    get: { current.doubleValue ?? spec.min ?? 0 },
                    set: { voice.setParameterOverride(packID: packID, key: spec.key, value: .double($0)) }
                ), in: (spec.min ?? 0)...(spec.max ?? 1))
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { current.boolValue ?? false },
                    set: { voice.setParameterOverride(packID: packID, key: spec.key, value: .bool($0)) }
                ))
                .toggleStyle(.switch).controlSize(.mini)
            case .stepper:
                Stepper("", value: Binding(
                    get: { current.intValue ?? 0 },
                    set: { voice.setParameterOverride(packID: packID, key: spec.key, value: .int($0)) }
                ), in: Int(spec.min ?? -12)...Int(spec.max ?? 12))
            case .picker:
                Picker("", selection: Binding(
                    get: { current.stringValue ?? spec.defaultValue.stringValue ?? "" },
                    set: { voice.setParameterOverride(packID: packID, key: spec.key, value: .string($0)) }
                )) {
                    ForEach(spec.options ?? [], id: \.self) { opt in
                        Text(optionDisplayTitle(opt)).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
    }

    private func optionDisplayTitle(_ opt: String) -> String {
        switch opt {
        case "mdx-lead-vocals": return String(localized: "MDX 主唱精分（去和声）")
        case "mdx-vocals": return String(localized: "MDX 标准人声分离")
        case "none": return String(localized: "直通原曲（不分离）")
        default: return opt
        }
    }

    private func valueText(_ v: VoiceParameterValue) -> String {
        switch v {
        case let .double(x): return String(format: "%.2f", x)
        case let .int(x): return "\(x)"
        case let .bool(x): return x ? "开" : "关"
        case let .string(s): return optionDisplayTitle(s)
        }
    }

    // MARK: - 预设

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("预设")
            HStack(spacing: 8) {
                ForEach(voice.presetStore.all, id: \.id) { preset in
                    Button {
                        do {
                            try voice.applyPreset(preset)
                            if let track {
                                Task { await voice.refreshRenderAvailability(for: track) }
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Text(preset.displayName)
                            .flowType(.homeSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(FlowColor.hover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionTitle(_ t: LocalizedStringKey) -> some View {
        Text(t).flowType(.homeSecondary).foregroundStyle(FlowColor.tertiaryText)
    }

    private func handleImport(_ result: Result<[URL], Error>, targetPackID: String?) {
        switch result {
        case .failure(let err):
            errorMessage = err.localizedDescription
        case .success(let urls):
            Task {
                do {
                    try await VoiceImportHelper.importPack(
                        from: urls,
                        into: voice,
                        targetPackIDForNewVersion: targetPackID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
