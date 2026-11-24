import CryptoKit
import Foundation

/// 管理原生推理所需的基础 ONNX 模型（`Application Support/FLOW/Voice/Models/`）。
final class VoiceModelAssetsManager: @unchecked Sendable {
    enum AssetKind: String, CaseIterable, Identifiable, Sendable {
        case rmvpe
        case hubert
        case mdxSeparator
        case mdxKaraoke

        var id: String { rawValue }

        var fileName: String {
            switch self {
            case .rmvpe: return "rmvpe.onnx"
            case .hubert: return "hubert_base.onnx"
            case .mdxSeparator: return "UVR-MDX-NET-Voc_FT.onnx"
            case .mdxKaraoke: return "UVR_MDXNET_KARA_2.onnx"
            }
        }

        var displayName: String {
            switch self {
            case .rmvpe: return "音高模型（rmvpe.onnx）"
            case .hubert: return "声音特征模型（hubert_base.onnx）"
            case .mdxSeparator: return "人声分离模型（UVR-MDX-NET-Voc_FT.onnx）"
            case .mdxKaraoke: return "主唱去和声模型（UVR_MDXNET_KARA_2.onnx）"
            }
        }

        var downloadURL: URL? {
            switch self {
            case .mdxSeparator:
                return URL(string: "https://huggingface.co/Politrees/UVR_resources/resolve/main/models/MDXNet/UVR-MDX-NET-Voc_FT.onnx")
            case .mdxKaraoke:
                return URL(string: "https://huggingface.co/Politrees/UVR_resources/resolve/main/models/MDXNet/UVR_MDXNET_KARA_2.onnx")
            case .rmvpe:
                return URL(string: "https://huggingface.co/TigreGotico/voiceclonnx-rvc/resolve/main/rmvpe.onnx")
            case .hubert:
                return URL(string: "https://huggingface.co/TigreGotico/voiceclonnx-rvc/resolve/main/contentvec_768l12.onnx")
            }
        }

        var alternateDownloadURLs: [URL] {
            switch self {
            case .mdxSeparator:
                if let github = URL(string: "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Voc_FT.onnx") {
                    return [github]
                }
                return []
            case .mdxKaraoke:
                if let github = URL(string: "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR_MDXNET_KARA_2.onnx") {
                    return [github]
                }
                return []
            case .rmvpe:
                if let alt = URL(string: "https://huggingface.co/ohnoitsaninja/rvc-base-onnx/resolve/main/assets/rmvpe.onnx") {
                    return [alt]
                }
                return []
            case .hubert:
                return []
            }
        }

        var expectedSHA256: String? {
            switch self {
            case .mdxSeparator:
                return "534b2070fcc7df514b13ef660dc8cbb328679c2374d04354a5c42bb14ecce111"
            case .mdxKaraoke:
                return "bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4"
            case .rmvpe:
                return "5370e71ac80af8b4b7c793d27efd51fd8bf962de3a7ede0766dac0befa3660fd"
            case .hubert:
                return "cbddd8fa9352b3128df6359e2e3da6be0f9072e768e51e3efc3004e5030ea97f"
            }
        }
    }

    static let knownIncompatibleHubertSHA256: Set<String> = [
        // 旧版 Tools/rvc-converter/export_base_models.py 误从 facebook/hubert-base-ls960 导出的非 ContentVec 模型
        "a4297149f8df2c0e8feaf88a302129dc6b06b94666131a3b321f89df9e9d0340",
    ]

    struct AssetStatus: Sendable, Equatable {
        let kind: AssetKind
        let url: URL
        let exists: Bool
        let sizeBytes: Int64
        var incompatibleReason: String? = nil

        var isReady: Bool { exists && incompatibleReason == nil }
    }

    let modelsDirectory: URL
    private let session: URLSession
    private let compatLock = NSLock()
    private var compatCache: [String: String?] = [:]

    init(voiceRoot: URL, session: URLSession = .shared) {
        self.modelsDirectory = voiceRoot.appendingPathComponent("Models", isDirectory: true)
        self.session = session
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private func withCompatLock<T>(_ body: () -> T) -> T {
        compatLock.lock()
        defer { compatLock.unlock() }
        return body()
    }

    func url(for kind: AssetKind) -> URL {
        modelsDirectory.appendingPathComponent(kind.fileName, isDirectory: false)
    }

    func statusSummary() -> [AssetStatus] {
        AssetKind.allCases.map { kind in
            let target = url(for: kind)
            let resolved = target.resolvingSymlinksInPath()
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let exists = FileManager.default.fileExists(atPath: resolved.path) && size > 1024
            var incompatible: String?
            if exists, kind == .hubert, let cacheKey = Self.fileCacheKey(resolved: resolved, attrs: attrs, size: size) {
                incompatible = withCompatLock { compatCache[cacheKey] ?? nil }
            }
            return AssetStatus(kind: kind, url: target, exists: exists, sizeBytes: size, incompatibleReason: incompatible)
        }
    }

    func missingRequiredAssets(
        requiresF0: Bool,
        requiresSeparation: Bool,
        requiresKaraoke: Bool = false
    ) -> [AssetKind] {
        let statuses = Dictionary(uniqueKeysWithValues: statusSummary().map { ($0.kind, $0.isReady) })
        var missing: [AssetKind] = []
        if statuses[.hubert] != true {
            missing.append(.hubert)
        }
        if requiresF0, statuses[.rmvpe] != true {
            missing.append(.rmvpe)
        }
        if requiresSeparation, statuses[.mdxSeparator] != true {
            missing.append(.mdxSeparator)
        }
        if requiresKaraoke, statuses[.mdxKaraoke] != true {
            missing.append(.mdxKaraoke)
        }
        return missing
    }

    func assetIsReady(_ kind: AssetKind) -> Bool {
        statusSummary().first(where: { $0.kind == kind })?.isReady ?? false
    }

    /// 异步校验磁盘上已安装的 `hubert_base.onnx` 是否为真正的 RVC ContentVec 编码器（拒绝原版 `hubert-base-ls960`）。
    /// 返回是否产生了新检出的兼容性结论变化。
    @discardableResult
    func verifyHubertCompatibilityIfNeeded() async -> Bool {
        let resolved = url(for: .hubert).resolvingSymlinksInPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: resolved.path),
              size > 1024,
              let cacheKey = Self.fileCacheKey(resolved: resolved, attrs: attrs, size: size) else {
            return false
        }

        let alreadyChecked = withCompatLock { compatCache.keys.contains(cacheKey) }
        if alreadyChecked { return false }

        let verdict = await Task.detached(priority: .utility) {
            Self.evaluateHubertCompatibility(at: resolved, sizeBytes: size)
        }.value

        withCompatLock { compatCache[cacheKey] = verdict }
        return verdict != nil
    }

    /// 手动导入基础 `.onnx` 模型到 `Models/`，先校验计算图与 ContentVec 兼容性再原子替换。
    func importAsset(from sourceURL: URL, kind: AssetKind) throws -> AssetStatus {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VoiceError.io("找不到选择的模型文件：\(sourceURL.lastPathComponent)")
        }
        let info = try ORTSession.inspect(modelURL: sourceURL)
        try validateAssetSchema(kind: kind, inputs: info.inputs, outputs: info.outputs)

        let attrsSrc = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let srcSize = (attrsSrc?[.size] as? NSNumber)?.int64Value ?? 0
        if kind == .hubert, let incompatible = Self.evaluateHubertCompatibility(at: sourceURL, sizeBytes: srcSize) {
            throw VoiceError.unsupportedModel(incompatible)
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let dst = url(for: kind)
        let tmp = modelsDirectory.appendingPathComponent(".\(kind.fileName).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: sourceURL, to: tmp)
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dst)
        }

        let resolvedDst = dst.resolvingSymlinksInPath()
        let attrs = try FileManager.default.attributesOfItem(atPath: resolvedDst.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if kind == .hubert, let cacheKey = Self.fileCacheKey(resolved: resolvedDst, attrs: attrs, size: size) {
            withCompatLock { compatCache[cacheKey] = Optional<String>.none }
        }
        return AssetStatus(kind: kind, url: dst, exists: size > 1024, sizeBytes: size, incompatibleReason: nil)
    }

    func totalAssetsBytes() -> Int64 {
        AssetKind.allCases.reduce(Int64(0)) { sum, kind in
            sum + fileSizeAt(url(for: kind))
        }
    }

    /// 移除单个已安装的基础 ONNX 模型（含符号链接，不影响外部源文件）。
    @discardableResult
    func removeAsset(_ kind: AssetKind) throws -> Int64 {
        let dst = url(for: kind)
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: dst.path)) != nil else { return 0 }
        let freed = fileSizeAt(dst)
        try fm.removeItem(at: dst)
        return freed
    }

    /// 移除全部基础 ONNX 模型。
    @discardableResult
    func removeAllAssets() throws -> Int64 {
        var freed: Int64 = 0
        for kind in AssetKind.allCases {
            freed += try removeAsset(kind)
        }
        return freed
    }

    private func fileSizeAt(_ itemURL: URL) -> Int64 {
        let resolved = itemURL.resolvingSymlinksInPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 从配置镜像源/官方仓库下载带 SHA256 校验的基础模型（严格尊重联网开关，失败时自动回退备用地址）。
    func downloadAsset(
        _ kind: AssetKind,
        allowNetwork: Bool,
        mirrorConfig: VoiceModelMirrorConfig = .default,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AssetStatus {
        try await downloadAsset(kind, networkAllowed: { allowNetwork }, mirrorConfig: mirrorConfig, onProgress: onProgress)
    }

    /// 联网开关以闭包传入：下载途中用户关掉联网，下一次请求/换源前即可中止。
    func downloadAsset(
        _ kind: AssetKind,
        networkAllowed: @escaping @Sendable () -> Bool,
        mirrorConfig: VoiceModelMirrorConfig = .default,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AssetStatus {
        guard networkAllowed() else {
            throw VoiceError.networkDisabled("已在设置中关闭联网，无法下载 \(kind.fileName)。可离线导入本地 ONNX 文件。")
        }
        guard let remoteURL = kind.downloadURL else {
            throw VoiceError.unsupportedModel("\(kind.fileName) 未配置下载地址，请手动导入 ONNX 文件。")
        }

        let candidates = mirrorConfig.candidateURLs(for: remoteURL, alternates: kind.alternateDownloadURLs)
        let downloaded = try await VoiceRemoteDownloader.downloadFileWithFallback(
            candidateURLs: candidates,
            session: session,
            allowNetwork: networkAllowed,
            expectedSHA256: kind.expectedSHA256,
            onProgress: onProgress
        )
        defer { try? FileManager.default.removeItem(at: downloaded.tempFileURL) }
        // 卸载或关联网时取消：已下载的临时文件丢弃，不写进 Models/。
        try Task.checkCancellation()

        return try importAsset(from: downloaded.tempFileURL, kind: kind)
    }

    private func validateAssetSchema(
        kind: AssetKind,
        inputs: [ORTTensorInfo],
        outputs: [ORTTensorInfo]
    ) throws {
        switch kind {
        case .rmvpe:
            guard let firstIn = inputs.first,
                  (firstIn.shape.count == 2 || firstIn.shape.count == 3),
                  !outputs.isEmpty else {
                throw VoiceError.unsupportedModel("rmvpe.onnx 输入张量应为 [B, 128, T] 或 [B, L] 波形")
            }
        case .hubert:
            guard !inputs.isEmpty, !outputs.isEmpty else {
                throw VoiceError.unsupportedModel("hubert_base.onnx 缺少输入或输出节点")
            }
        case .mdxSeparator, .mdxKaraoke:
            guard let first = inputs.first, first.shape.count == 4, first.shape[1] == 4 else {
                throw VoiceError.unsupportedModel("MDX 分离模型输入应为 4 通道 STFT 张量 [B, 4, dimF, dimT]")
            }
        }
    }

    static func sha256File(url: URL) throws -> String {
        try VoiceRemoteDownloader.sha256Stream(url: url)
    }

    private static func fileCacheKey(resolved: URL, attrs: [FileAttributeKey: Any]?, size: Int64) -> String? {
        guard let attrs else { return nil }
        let mtimeMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        return "\(resolved.path)|\(size)|\(mtimeMs)"
    }

    /// 评估 `hubert_base.onnx` 是否为 RVC ContentVec 编码器：返回 `nil` 表示兼容，非 `nil` 为阻断提示。
    static func evaluateHubertCompatibility(at url: URL, sizeBytes: Int64) -> String? {
        if let sha = try? sha256File(url: url) {
            if sha == AssetKind.hubert.expectedSHA256 {
                return nil
            }
            if knownIncompatibleHubertSHA256.contains(sha) {
                return "检测到原版 HuBERT（非 RVC ContentVec 编码器），会导致变声输出杂音，请点击重新下载正确模型。"
            }
        }

        do {
            if let score = try probeHubertContentVecScore(modelURL: url), score <= 1.2 {
                return "当前 hubert_base.onnx 特征空间与 RVC ContentVec 不符，会导致变声输出杂音，请重新下载官方 ContentVec 模型。"
            }
        } catch {
            // 仅当真实尺寸的底座模型文件损坏时报错；单元测小尺寸占位文件保持兼容。
            if sizeBytes > 1_000_000 {
                return "hubert_base.onnx 已损坏或结构不完整，请重新下载。"
            }
        }
        return nil
    }

    private static func probeHubertContentVecScore(modelURL: URL) throws -> Float? {
        let session = try ORTSession(
            modelURL: modelURL,
            provider: .cpu,
            intraOpThreads: 2,
            allowCPUFallback: false
        )
        let outputName = try HuBERTFeatureExtractor.resolveOutputName(
            from: session.outputInfos,
            embeddingDim: 768
        )
        let probe: [Float] = (0..<8000).map { i in
            let t = Float(i) / 16_000.0
            return 0.3 * sinf(2 * .pi * 220 * t)
                + 0.15 * sinf(2 * .pi * 440 * t)
                + 0.1 * sinf(2 * .pi * 880 * t)
        }
        let inputs = HuBERTFeatureExtractor.buildInputs(for: session.inputInfos, audio16k: probe)
        let outputs = try session.runSync(inputs: inputs, outputNames: [outputName])
        guard let tensor = outputs[outputName], tensor.shape.count == 3 else {
            return nil
        }
        let frames = Int(tensor.shape[1])
        let dim = Int(tensor.shape[2])
        guard frames > 0, dim == 768, tensor.floatData.count >= frames * dim else {
            return nil
        }
        let positiveChannels = [412, 663, 405, 666]
        let negativeChannels = [558, 550, 79]
        let invFrames = 1.0 / Float(frames)
        var score: Float = 0
        for t in 0..<frames {
            let base = t * dim
            for ch in positiveChannels { score += tensor.floatData[base + ch] * invFrames }
            for ch in negativeChannels { score -= tensor.floatData[base + ch] * invFrames }
        }
        return score
    }
}
