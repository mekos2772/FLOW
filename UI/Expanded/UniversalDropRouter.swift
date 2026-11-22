import SwiftUI

/// 主窗口全局拖放提示浮层。
struct UniversalDropOverlay: View {
    var isTargeted: Bool

    var body: some View {
        if isTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(
                        RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.6))
                    )
                    .padding(10)

                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("松开即可导入并自动处理")
                        .flowType(.homeTitle)
                    Text("支持音频 / 音乐目录、.lrc / .ttml 歌词、.js / .json 音源与 .onnx / .voicepack 音色")
                        .flowType(.caption)
                        .foregroundStyle(FlowColor.secondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// 主窗口全局拖放路由器：自动识别音频/目录、歌词、音源脚本/配置、RVC 模型。
@MainActor
enum UniversalDropRouter {
    static func handle(
        urls: [URL],
        app: AppContainer,
        model: MorphPresentationModel
    ) async -> String? {
        var audioAndFolders: [URL] = []
        var lyrics: [URL] = []
        var sources: [URL] = []
        var voiceModels: [(URL, UniversalFileClassifier.BaseModelHint?)] = []

        for url in urls {
            switch UniversalFileClassifier.classify(url) {
            case .audio(let u), .folder(let u):
                audioAndFolders.append(u)
            case .lyric(let u):
                lyrics.append(u)
            case .sourcePlugin(let u):
                sources.append(u)
            case .voicePackOrModel(let u, let hint):
                voiceModels.append((u, hint))
            case .unsupported:
                break
            }
        }

        var notes: [String] = []

        if !audioAndFolders.isEmpty {
            let scoped = audioAndFolders.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (u, ok) in scoped where ok { u.stopAccessingSecurityScopedResource() }
            }
            let tracks = await app.sourceManager.openLocalAudioURLs(audioAndFolders)
            if let first = tracks.first {
                model.showPlayer()
                app.noteAuxiliaryActivity(false)
                app.playback.setQueue(tracks, current: first)
                await app.playback.load(first, autoplay: true)
                notes.append(String(localized: "已添加并播放：\(first.title)"))
            } else {
                notes.append(String(localized: "已添加本地目录，正在扫描歌曲"))
            }
        }

        if let firstLyric = lyrics.first {
            if let track = model.track {
                if app.lyricVariants.applyLocalLyricFile(at: firstLyric, for: track) != nil {
                    notes.append(String(localized: "已绑定本地歌词：\(firstLyric.lastPathComponent)"))
                } else {
                    notes.append(String(localized: "未能解析歌词文件：\(firstLyric.lastPathComponent)"))
                }
            } else {
                notes.append(String(localized: "请先播放一首歌曲，再拖入歌词文件绑定"))
            }
        }

        if !sources.isEmpty {
            var importedNames: [String] = []
            for sourceURL in sources {
                let ok = sourceURL.startAccessingSecurityScopedResource()
                defer { if ok { sourceURL.stopAccessingSecurityScopedResource() } }
                do {
                    let list = try await app.sourceManager.importSources(from: sourceURL)
                    importedNames.append(contentsOf: list.map(\.descriptor.displayName))
                } catch {
                    notes.append(SourceErrorPresentation.friendly(error))
                }
            }
            if !importedNames.isEmpty {
                let joinedNames = importedNames.joined(separator: "、")
                notes.append(String(localized: "已导入音源：\(joinedNames)"))
            }
        }

        if !voiceModels.isEmpty, let voice = app.voice {
            var packURLs: [URL] = []
            var installedBases: [String] = []
            for (url, hint) in voiceModels {
                if let hint {
                    let kind = mapBaseHint(hint)
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if (try? await voice.importBaseAsset(from: url, kind: kind)) != nil {
                        installedBases.append(kind.fileName)
                    }
                } else {
                    packURLs.append(url)
                }
            }
            if !packURLs.isEmpty {
                do {
                    try await VoiceImportHelper.importPack(from: packURLs, into: voice)
                    notes.append(String(localized: "已导入音色模型，可在播放栏音色开关切换"))
                } catch {
                    notes.append(error.localizedDescription)
                }
            }
            if !installedBases.isEmpty {
                notes.append(String(localized: "已安装底座模型：\(installedBases.joined(separator: "、"))"))
            }
        }

        if notes.isEmpty && !urls.isEmpty {
            return String(localized: "不支持该文件类型，可拖入音频、歌词、音源脚本或音色模型")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "；")
    }

    private static func mapBaseHint(_ hint: UniversalFileClassifier.BaseModelHint) -> VoiceModelAssetsManager.AssetKind {
        switch hint {
        case .rmvpe: return .rmvpe
        case .hubert: return .hubert
        case .mdxSeparator: return .mdxSeparator
        }
    }
}
