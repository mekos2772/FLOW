import Foundation

/// 音色包管理（导入 `.voicepack` 目录或 `.onnx` 模型、版本切换、重命名、参数覆写与删除）。
final class VoicePackStore: @unchecked Sendable {
    let packsRoot: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    init(packsRoot: URL) {
        self.packsRoot = packsRoot
        try? fm.createDirectory(at: packsRoot, withIntermediateDirectories: true)
    }

    func allPacks() throws -> [VoicePackManifest] {
        try lock.withLock { try loadAllLocked() }
    }

    func manifest(packID: String) throws -> VoicePackManifest? {
        try lock.withLock {
            let url = packDirectory(packID: packID).appendingPathComponent("pack.json")
            guard fm.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(VoicePackManifest.self, from: data)
        }
    }

    func packDirectory(packID: String) -> URL {
        packsRoot.appendingPathComponent(packID, isDirectory: true)
    }

    func weightURL(for pack: VoicePackManifest, version: VoicePackVersion) -> URL {
        packDirectory(packID: pack.packID).appendingPathComponent(Self.safeFileName(version.weightFileName))
    }

    func indexURL(for pack: VoicePackManifest, version: VoicePackVersion) -> URL? {
        guard let name = version.indexFileName else { return nil }
        return packDirectory(packID: pack.packID).appendingPathComponent(Self.safeFileName(name))
    }

    func coverURL(for pack: VoicePackManifest) -> URL? {
        guard let name = pack.coverFileName else { return nil }
        let u = packDirectory(packID: pack.packID).appendingPathComponent(Self.safeFileName(name))
        return fm.fileExists(atPath: u.path) ? u : nil
    }

    /// 导入 `.voicepack` 目录或 `.onnx` 文件作为新音色包（同一模型文件可按同一 packID 幂等命中）。
    func importPack(
        weightURL: URL,
        indexURL: URL? = nil,
        coverURL: URL? = nil,
        displayName: String? = nil,
        engineID: String = "rvc",
        registry: VoiceEngineRegistry = .shared
    ) async throws -> VoicePackManifest {
        guard let adapter = registry.adapter(for: engineID) else {
            throw VoiceError.engineNotRegistered(engineID)
        }

        let resolved = try resolveSourceArtifacts(
            sourceURL: weightURL,
            explicitIndexURL: indexURL,
            explicitCoverURL: coverURL
        )

        // 先对索引做结构验证（若传入）
        if let srcIndex = resolved.indexURL {
            let ext = srcIndex.pathExtension.lowercased()
            guard ext == "f32bin" else {
                throw VoiceError.unsupportedModel(String(localized: "索引文件需要先转换成 .f32bin 才能使用（.index 是训练格式）。"))
            }
            let parsedIdx = try F32VectorIndex(url: srcIndex)
            let insp = try await adapter.inspect(modelURL: resolved.modelURL)
            if parsedIdx.dim != insp.embeddingDim {
                throw VoiceError.invalidManifest(reason: "索引维度 (\(parsedIdx.dim)) 与模型维度 (\(insp.embeddingDim)) 不一致")
            }
            return try lock.withLock {
                try importPackLocked(
                    sourceModelURL: resolved.modelURL,
                    sourceIndexURL: srcIndex,
                    sourceCoverURL: resolved.coverURL,
                    displayName: Self.resolvedTitle(preferred: displayName, converterName: resolved.converterName, url: weightURL),
                    engineID: engineID,
                    inspection: insp,
                    adapter: adapter
                )
            }
        }

        let inspection = try await adapter.inspect(modelURL: resolved.modelURL)
        let title = Self.resolvedTitle(preferred: displayName, converterName: resolved.converterName, url: weightURL)
        return try lock.withLock {
            try importPackLocked(
                sourceModelURL: resolved.modelURL,
                sourceIndexURL: nil,
                sourceCoverURL: resolved.coverURL,
                displayName: title,
                engineID: engineID,
                inspection: inspection,
                adapter: adapter
            )
        }
    }

    /// 为已有音色包追加一个新模型版本（生成唯一 versionID 并在失败时回滚）。
    func addVersion(
        packID: String,
        weightURL: URL,
        indexURL: URL? = nil,
        versionName: String? = nil,
        registry: VoiceEngineRegistry = .shared
    ) async throws -> VoicePackManifest {
        guard let existing = try manifest(packID: packID) else {
            throw VoiceError.invalidManifest(reason: "音色包不存在：\(packID)")
        }
        guard let adapter = registry.adapter(for: existing.engineID) else {
            throw VoiceError.engineNotRegistered(existing.engineID)
        }

        let resolved = try resolveSourceArtifacts(
            sourceURL: weightURL,
            explicitIndexURL: indexURL,
            explicitCoverURL: nil
        )
        let inspection = try await adapter.inspect(modelURL: resolved.modelURL)

        if let srcIndex = resolved.indexURL {
            guard srcIndex.pathExtension.lowercased() == "f32bin" else {
                throw VoiceError.unsupportedModel("索引文件须为 .f32bin")
            }
            let parsedIdx = try F32VectorIndex(url: srcIndex)
            guard parsedIdx.dim == inspection.embeddingDim else {
                throw VoiceError.invalidManifest(reason: "索引维度 (\(parsedIdx.dim)) 与模型维度 (\(inspection.embeddingDim)) 不一致")
            }
        }

        return try lock.withLock {
            try addVersionLocked(
                packID: packID,
                sourceModelURL: resolved.modelURL,
                sourceIndexURL: resolved.indexURL,
                versionName: versionName,
                inspection: inspection
            )
        }
    }

    func selectVersion(packID: String, versionID: String) throws {
        try update(packID: packID) { manifest in
            guard manifest.versions.contains(where: { $0.id == versionID }) else { return }
            manifest.selectedVersionID = versionID
        }
    }

    func rename(packID: String, displayName: String) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update(packID: packID) { $0.displayName = trimmed }
    }

    func setParameterOverrides(packID: String, overrides: [String: VoiceParameterValue]) throws {
        try update(packID: packID) { $0.parameterOverrides = overrides }
    }

    @discardableResult
    func delete(packID: String) throws -> VoicePackManifest {
        try lock.withLock {
            let dir = packDirectory(packID: packID)
            let manifestURL = dir.appendingPathComponent("pack.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(VoicePackManifest.self, from: data) else {
                throw VoiceError.invalidManifest(reason: "音色包不存在：\(packID)")
            }
            try fm.removeItem(at: dir)
            return manifest
        }
    }

    func totalPacksBytes() -> Int64 {
        lock.withLock { directorySizeLocked(packsRoot) }
    }

    /// 删除 `Packs/` 下所有音色包目录与文件，返回释放的字节数。
    @discardableResult
    func deleteAll() throws -> Int64 {
        try lock.withLock {
            let freed = directorySizeLocked(packsRoot)
            if let items = try? fm.contentsOfDirectory(at: packsRoot, includingPropertiesForKeys: nil) {
                for item in items {
                    try fm.removeItem(at: item)
                }
            }
            return freed
        }
    }

    private func directorySizeLocked(_ dir: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if vals?.isRegularFile == true {
                total += Int64(vals?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Private

    private struct ResolvedSource {
        let modelURL: URL
        let indexURL: URL?
        let coverURL: URL?
        let converterName: String?
    }

    private func resolveSourceArtifacts(
        sourceURL: URL,
        explicitIndexURL: URL?,
        explicitCoverURL: URL?
    ) throws -> ResolvedSource {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw VoiceError.io("找不到选择的音色文件：\(sourceURL.lastPathComponent)")
        }
        if isDir.boolValue {
            let metaURL = sourceURL.appendingPathComponent("pack.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap {
                try? JSONDecoder().decode(VoicePackConverterManifest.self, from: $0)
            }
            let modelName = meta?.modelFile ?? "model.onnx"
            let onnxURL = sourceURL.appendingPathComponent(Self.safeFileName(modelName))
            guard fm.fileExists(atPath: onnxURL.path) else {
                throw VoiceError.invalidManifest(reason: "音色包内缺少 \(modelName)")
            }

            var resolvedIndex = explicitIndexURL
            if resolvedIndex == nil {
                let candidateName = meta?.indexFile ?? "index.f32bin"
                let candidate = sourceURL.appendingPathComponent(Self.safeFileName(candidateName))
                if fm.fileExists(atPath: candidate.path) {
                    resolvedIndex = candidate
                }
            }

            var resolvedCover = explicitCoverURL
            if resolvedCover == nil {
                for ext in ["png", "jpg", "jpeg", "webp"] {
                    let c = sourceURL.appendingPathComponent("cover.\(ext)")
                    if fm.fileExists(atPath: c.path) {
                        resolvedCover = c
                        break
                    }
                }
            }
            return ResolvedSource(
                modelURL: onnxURL,
                indexURL: resolvedIndex,
                coverURL: resolvedCover,
                converterName: meta?.name
            )
        }

        // 单文件：必须为 .onnx
        return ResolvedSource(
            modelURL: sourceURL,
            indexURL: explicitIndexURL,
            coverURL: explicitCoverURL,
            converterName: nil
        )
    }

    private func importPackLocked(
        sourceModelURL: URL,
        sourceIndexURL: URL?,
        sourceCoverURL: URL?,
        displayName: String,
        engineID: String,
        inspection: VoiceModelInspection,
        adapter: any VoiceEngineAdapter
    ) throws -> VoicePackManifest {
        let slug = Self.slug(displayName)
        let packID = "\(slug)-\(inspection.fingerprint.prefix(8))"
        let packDir = packDirectory(packID: packID)
        let manifestURL = packDir.appendingPathComponent("pack.json")

        // 幂等性：相同指纹的包已存在时直接返回现有 manifest
        if fm.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let existing = try? JSONDecoder().decode(VoicePackManifest.self, from: data) {
            return existing
        }

        let createdDir = !fm.fileExists(atPath: packDir.path)
        var copiedFiles: [URL] = []
        do {
            try fm.createDirectory(at: packDir, withIntermediateDirectories: true)

            let versionID = "v1"
            let weightName = "model-\(inspection.architectureHint)-\(versionID).onnx"
            let dstWeight = packDir.appendingPathComponent(weightName)
            try copyReplacing(from: sourceModelURL, to: dstWeight)
            copiedFiles.append(dstWeight)

            var indexName: String?
            var indexFP: String?
            if let srcIdx = sourceIndexURL {
                let name = "index-\(versionID).f32bin"
                let dstIdx = packDir.appendingPathComponent(name)
                try copyReplacing(from: srcIdx, to: dstIdx)
                copiedFiles.append(dstIdx)
                indexName = name
                indexFP = try VoiceModelAssetsManager.sha256File(url: dstIdx)
            }

            var coverName: String?
            if let srcCover = sourceCoverURL {
                let ext = srcCover.pathExtension.lowercased()
                let safeExt = ["png", "jpg", "jpeg", "webp"].contains(ext) ? ext : "png"
                let name = "cover.\(safeExt)"
                let dstCover = packDir.appendingPathComponent(name)
                try copyReplacing(from: srcCover, to: dstCover)
                copiedFiles.append(dstCover)
                coverName = name
            }

            let version = VoicePackVersion(
                id: versionID,
                weightFileName: weightName,
                indexFileName: indexName,
                weightFingerprint: inspection.fingerprint,
                indexFingerprint: indexFP,
                sampleRate: inspection.sampleRate,
                architectureHint: inspection.architectureHint,
                hasF0: inspection.hasF0,
                embeddingDim: inspection.embeddingDim,
                interChannels: inspection.interChannels,
                speakerCount: inspection.speakerCount,
                importedAt: Date()
            )
            let manifest = VoicePackManifest(
                packID: packID,
                displayName: displayName,
                engineID: engineID,
                versions: [version],
                selectedVersionID: versionID,
                coverFileName: coverName,
                parameterOverrides: adapter.normalizeParameters([:])
            )
            try persistManifestLocked(manifest, to: manifestURL)
            return manifest
        } catch {
            // 拷贝或持久化失败时精准回滚，避免留下空壳/坏包
            if createdDir {
                try? fm.removeItem(at: packDir)
            } else {
                for f in copiedFiles { try? fm.removeItem(at: f) }
            }
            throw error
        }
    }

    private func addVersionLocked(
        packID: String,
        sourceModelURL: URL,
        sourceIndexURL: URL?,
        versionName: String?,
        inspection: VoiceModelInspection
    ) throws -> VoicePackManifest {
        let packDir = packDirectory(packID: packID)
        let manifestURL = packDir.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(VoicePackManifest.self, from: data) else {
            throw VoiceError.invalidManifest(reason: "音色包不存在或损坏：\(packID)")
        }

        let uniqueBase = versionName.map { Self.slug($0) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "v-\(UUID().uuidString.prefix(8).lowercased())"
        var versionID = uniqueBase
        var suffix = 2
        while manifest.versions.contains(where: { $0.id == versionID }) {
            versionID = "\(uniqueBase)-\(suffix)"
            suffix += 1
        }

        var copiedFiles: [URL] = []
        do {
            let weightName = "model-\(versionID).onnx"
            let dstWeight = packDir.appendingPathComponent(weightName)
            try copyReplacing(from: sourceModelURL, to: dstWeight)
            copiedFiles.append(dstWeight)

            var indexName: String?
            var indexFP: String?
            if let srcIdx = sourceIndexURL {
                let name = "index-\(versionID).f32bin"
                let dstIdx = packDir.appendingPathComponent(name)
                try copyReplacing(from: srcIdx, to: dstIdx)
                copiedFiles.append(dstIdx)
                indexName = name
                indexFP = try VoiceModelAssetsManager.sha256File(url: dstIdx)
            }

            let ver = VoicePackVersion(
                id: versionID,
                weightFileName: weightName,
                indexFileName: indexName,
                weightFingerprint: inspection.fingerprint,
                indexFingerprint: indexFP,
                sampleRate: inspection.sampleRate,
                architectureHint: inspection.architectureHint,
                hasF0: inspection.hasF0,
                embeddingDim: inspection.embeddingDim,
                interChannels: inspection.interChannels,
                speakerCount: inspection.speakerCount,
                importedAt: Date()
            )
            manifest.versions.append(ver)
            manifest.selectedVersionID = versionID
            try persistManifestLocked(manifest, to: manifestURL)
            return manifest
        } catch {
            for f in copiedFiles { try? fm.removeItem(at: f) }
            throw error
        }
    }

    private func loadAllLocked() throws -> [VoicePackManifest] {
        guard fm.fileExists(atPath: packsRoot.path) else { return [] }
        let dirs = try fm.contentsOfDirectory(
            at: packsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let dec = JSONDecoder()
        var out: [VoicePackManifest] = []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent("pack.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? dec.decode(VoicePackManifest.self, from: data) else {
                continue
            }
            out.append(manifest)
        }
        return out.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func update(packID: String, _ mutate: (inout VoicePackManifest) -> Void) throws {
        try lock.withLock {
            let manifestURL = packDirectory(packID: packID).appendingPathComponent("pack.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? JSONDecoder().decode(VoicePackManifest.self, from: data) else {
                throw VoiceError.invalidManifest(reason: "音色包不存在：\(packID)")
            }
            mutate(&manifest)
            try persistManifestLocked(manifest, to: manifestURL)
        }
    }

    private func persistManifestLocked(_ manifest: VoicePackManifest, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: url, options: .atomic)
    }

    private func copyReplacing(from src: URL, to dst: URL) throws {
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private static func resolvedTitle(preferred: String?, converterName: String?, url: URL) -> String {
        if let p = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        if let c = converterName?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            return c
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "未命名音色" : stem
    }

    private static func safeFileName(_ name: String) -> String {
        URL(fileURLWithPath: name).lastPathComponent
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        let collapsed = out.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "voice" : String(collapsed.prefix(32))
    }
}
