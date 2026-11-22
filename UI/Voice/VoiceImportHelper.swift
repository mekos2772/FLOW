import AppKit
import Foundation
import SwiftUI

/// 音色包头像 / 封面缩略图：若 `.voicepack` 内附带封面图则异步加载展示，否则显示统一声纹占位图标。
struct VoicePackAvatarView: View {
    let coverURL: URL?
    var isSelected: Bool = false
    var size: CGFloat = 24
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.wave.2")
                    .font(.system(size: max(10, size * 0.48), weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : FlowColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(isSelected ? 0.12 : 0.06))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.25), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(5, size * 0.25), style: .continuous)
                .strokeBorder(FlowColor.hairline, lineWidth: 1)
        )
        .task(id: coverURL) {
            guard let coverURL else {
                image = nil
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: coverURL)
            }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

/// 拖拽导入遮罩提示：拖拽 `.voicepack` / `.onnx` 文件悬停时高亮显示。
struct VoiceDropHighlightOverlay: View {
    let isTargeted: Bool
    var cornerRadius: CGFloat = 12

    var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .overlay {
                    Label("松开导入音色", systemImage: "square.and.arrow.down")
                        .flowType(.homeControl)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// 支持把 `.voicepack` 文件夹或 `.onnx` / `.f32bin` 文件直接拖入面板完成导入。
    func voicePackDropDestination(
        into voice: VoiceManager,
        targetPackID: String? = nil,
        isTargeted: Binding<Bool>,
        onError: @escaping @MainActor (String) -> Void
    ) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { @MainActor in
                do {
                    try await VoiceImportHelper.importPack(
                        from: urls,
                        into: voice,
                        targetPackIDForNewVersion: targetPackID
                    )
                } catch {
                    onError(error.localizedDescription)
                }
            }
            return true
        } isTargeted: { hovering in
            isTargeted.wrappedValue = hovering
        }
    }
}

/// 共用的安全域音色包与基础 ONNX 模型导入辅助（消除多个视图中的重复文件选择逻辑）。
enum VoiceImportHelper {
    /// 解析用户在文件选择器选中的 URL（支持 `.voicepack` 目录，或 `.onnx` + 可选 `.f32bin`），
    /// 并安全持有 Sandbox Security-Scoped 资源访问权限完成导入。
    @MainActor
    static func importPack(
        from urls: [URL],
        into voice: VoiceManager,
        targetPackIDForNewVersion: String? = nil
    ) async throws {
        guard !urls.isEmpty else { return }

        var scopedURLs: [URL] = []
        for u in urls where u.startAccessingSecurityScopedResource() {
            scopedURLs.append(u)
        }
        defer {
            for u in scopedURLs { u.stopAccessingSecurityScopedResource() }
        }

        let voicepackDir = urls.first { url in
            var isDir: ObjCBool = false
            return url.pathExtension.lowercased() == "voicepack"
                || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
        }
        let onnxURL = urls.first { $0.pathExtension.lowercased() == "onnx" }
        let indexURL = urls.first { $0.pathExtension.lowercased() == "f32bin" }
        let legacyPth = urls.first { ["pth", "pt", "ckpt"].contains($0.pathExtension.lowercased()) }

        if legacyPth != nil {
            throw VoiceError.unsupportedModel(
                String(localized: "这是训练用的 .pth 文件，App 不能直接使用，需要先在电脑上转换成音色包。")
            )
        }

        guard let primaryURL = voicepackDir ?? onnxURL else {
            throw VoiceError.invalidManifest(reason: "请选择 .voicepack 文件夹，或 .onnx 模型文件（可选附带 .f32bin 索引）")
        }

        if let packID = targetPackIDForNewVersion {
            _ = try await voice.addVersion(
                packID: packID,
                versionName: nil,
                weightURL: primaryURL,
                indexURL: indexURL
            )
        } else {
            _ = try await voice.importPack(
                weightURL: primaryURL,
                displayName: nil,
                indexURL: indexURL,
                coverURL: nil
            )
        }
    }

    @MainActor
    static func importBaseAsset(
        from urls: [URL],
        kind: VoiceModelAssetsManager.AssetKind,
        into voice: VoiceManager
    ) async throws {
        guard let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        try await voice.importBaseAsset(from: url, kind: kind)
    }
}
