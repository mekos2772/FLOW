import SwiftUI
import UniformTypeIdentifiers

/// 歌词空态或加载失败时的显式快捷操作栏，供滚动歌词与编辑式歌词复用。
struct LyricQuickActionsBar: View {
    @Bindable var model: MorphPresentationModel
    @Environment(\.app) private var app
    @State private var showsFileImporter = false
    @State private var importHint: String?

    private static var allowedTypes: [UTType] {
        var list: [UTType] = [.plainText, .xml]
        if let lrc = UTType(filenameExtension: "lrc") { list.insert(lrc, at: 0) }
        if let ttml = UTType(filenameExtension: "ttml") { list.insert(ttml, at: 0) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                FlowTextButton(
                    title: "手动搜词 / 换一版",
                    symbolName: "text.magnifyingglass",
                    prominent: true
                ) {
                    model.showsLyricPicker = true
                }

                FlowTextButton(
                    title: "导入本地歌词…",
                    symbolName: "doc.badge.plus",
                    prominent: true
                ) {
                    importHint = nil
                    showsFileImporter = true
                }
            }

            if let importHint {
                FlowCaption(verbatim: importHint)
                    .foregroundStyle(FlowColor.secondaryText)
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let track = model.track, let coordinator = app?.lyricVariants else { return }
            switch result {
            case .failure(let err):
                importHint = err.localizedDescription
            case .success(let urls):
                guard let first = urls.first else { return }
                if coordinator.applyLocalLyricFile(at: first, for: track) == nil {
                    importHint = String(localized: "无法解析该歌词文件，请确认其为有效 .lrc 或 .ttml")
                } else {
                    importHint = nil
                }
            }
        }
    }
}
