import Foundation

/// 运行时修复 RVC `.onnx` 合成器 `SineGen` 中的 Float32 静音相位漂移缺陷：
/// PyTorch 导出的 `tmp_over_one_idx = (tmp_over_one[:, 1:, :] - tmp_over_one[:, :-1, :]) < 0`
/// 在静音平段 (`f0 == 0` 且此前累计相位非零) 时，会因 ORT `Resize(linear)` 的 1-ULP 负向抖动 (`-1e-6`)
/// 持续触发 `-1.0` 累减，把 `CumSum` 推至 `-16384..-32768` (`ulp = 1/512`)，进而将整首歌的基频量化锁死到
/// `sr * k / 512`。将阈值常量从 `0.0` 原位修正为 `-0.5` 即可彻底消除漂移，同时完整保留 `uv = 0` 清音。
enum ONNXSineGenSanitizer {
    private static let replacementFloatBits: UInt32 = Float(-0.5).bitPattern.littleEndian

    private struct NodeInfo {
        let opType: String
        let name: String
        let inputs: [String]
        let outputs: [String]
        let constantZeroFloatOffsets: [Int]
    }

    static func defaultCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-voice-sanitized", isDirectory: true)
    }

    /// 若 `.onnx` 含有 `SineGen` 的 `< 0.0` 相位回绕判定常量，则生成（或命中缓存）`-0.5` 修正版副本；
    /// 否则原样返回 `modelURL`。APFS 下 `copyItem` 自动走 CoW 克隆，几乎不占额外磁盘与拷贝时间。
    static func sanitizeIfNeeded(
        modelURL: URL,
        cacheDirectory: URL = defaultCacheDirectory()
    ) throws -> URL {
        let mapped = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        let offsets = findSineGenZeroThresholdOffsets(in: mapped)
        guard !offsets.isEmpty else {
            return modelURL
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let attrs = try fm.attributesOfItem(atPath: modelURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(mapped.count)
        let mtimeMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        let pathHash = VoiceCacheManager.sha256Hex(Data(modelURL.path.utf8)).prefix(12)
        let cachedURL = cacheDirectory.appendingPathComponent(
            "sgen-\(pathHash)-\(fileSize)-\(mtimeMs).onnx",
            isDirectory: false
        )

        if fm.fileExists(atPath: cachedURL.path),
           isAlreadyPatched(at: cachedURL, offsets: offsets, expectedSize: fileSize) {
            return cachedURL
        }

        let stagingURL = cacheDirectory.appendingPathComponent(".\(UUID().uuidString).onnx", isDirectory: false)
        defer { try? fm.removeItem(at: stagingURL) }

        try fm.copyItem(at: modelURL, to: stagingURL)
        try applyPatchBytes(at: stagingURL, offsets: offsets)

        if fm.fileExists(atPath: cachedURL.path) {
            _ = try fm.replaceItemAt(cachedURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: cachedURL)
        }
        return cachedURL
    }

    /// 扫描 ONNX `ModelProto` 字节偏移（只解析 `GraphProto.node`，O(1) 跳过庞大 `initializer` 权重张量）。
    static func findSineGenZeroThresholdOffsets(in data: Data) -> [Int] {
        var result: [Int] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            for (field, wire, range) in iterFields(base: base, start: 0, end: count) {
                guard field == 7, wire == 2 else { continue } // ModelProto.graph
                let nodes = parseGraphNodes(base: base, start: range.lowerBound, end: range.upperBound)
                result.append(contentsOf: detectThresholdOffsets(in: nodes))
            }
        }
        return result
    }

    private static func isAlreadyPatched(at url: URL, offsets: [Int], expectedSize: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attrs[.size] as? NSNumber)?.int64Value ?? -1) == expectedSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        var expected = replacementFloatBits
        let expectedData = Data(bytes: &expected, count: 4)
        for offset in offsets {
            do {
                try handle.seek(toOffset: UInt64(offset))
                let slice = try handle.read(upToCount: 4)
                if slice != expectedData { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private static func applyPatchBytes(at url: URL, offsets: [Int]) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var bits = replacementFloatBits
        let bytes = Data(bytes: &bits, count: 4)
        for offset in offsets {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
        }
    }

    private static func parseGraphNodes(base: UnsafePointer<UInt8>, start: Int, end: Int) -> [NodeInfo] {
        var nodes: [NodeInfo] = []
        for (field, wire, range) in iterFields(base: base, start: start, end: end) {
            guard field == 1, wire == 2 else { continue } // GraphProto.node
            nodes.append(parseNode(base: base, start: range.lowerBound, end: range.upperBound))
        }
        return nodes
    }

    private static func parseNode(base: UnsafePointer<UInt8>, start: Int, end: Int) -> NodeInfo {
        var inputs: [String] = []
        var outputs: [String] = []
        var name = ""
        var opType = ""
        var attrRanges: [Range<Int>] = []

        for (field, wire, range) in iterFields(base: base, start: start, end: end) where wire == 2 {
            switch field {
            case 1:
                inputs.append(decodeString(base: base, range: range))
            case 2:
                outputs.append(decodeString(base: base, range: range))
            case 3:
                name = decodeString(base: base, range: range)
            case 4:
                opType = decodeString(base: base, range: range)
            case 5:
                attrRanges.append(range)
            default:
                break
            }
        }

        let zeroOffsets: [Int]
        if opType == "Constant" {
            zeroOffsets = attrRanges.flatMap { parseConstantZeroFloatOffsets(base: base, range: $0) }
        } else {
            zeroOffsets = []
        }
        return NodeInfo(
            opType: opType,
            name: name,
            inputs: inputs,
            outputs: outputs,
            constantZeroFloatOffsets: zeroOffsets
        )
    }

    private static func parseConstantZeroFloatOffsets(base: UnsafePointer<UInt8>, range: Range<Int>) -> [Int] {
        var offsets: [Int] = []
        for (af, aw, aRange) in iterFields(base: base, start: range.lowerBound, end: range.upperBound) {
            guard af == 5, aw == 2 else { continue } // AttributeProto.t (TensorProto)
            var dataType = 0
            var scalarZeroOffsets: [Int] = []
            for (tf, tw, tRange) in iterFields(base: base, start: aRange.lowerBound, end: aRange.upperBound) {
                if tf == 2, tw == 0, let dt = readVarintDirect(base: base, range: tRange) {
                    dataType = Int(dt)
                } else if (tf == 9 || tf == 4), tw == 2, tRange.count == 4 {
                    let bits = readUInt32LE(base: base, offset: tRange.lowerBound)
                    if bits == 0 || bits == 0x8000_0000 { // +0.0 或 -0.0 float32
                        scalarZeroOffsets.append(tRange.lowerBound)
                    }
                }
            }
            if dataType == 1 { // TensorProto.FLOAT
                offsets.append(contentsOf: scalarZeroOffsets)
            }
        }
        return offsets
    }

    private static func detectThresholdOffsets(in nodes: [NodeInfo]) -> [Int] {
        var producerByOutput: [String: NodeInfo] = [:]
        var consumersByInput: [String: [NodeInfo]] = [:]
        for node in nodes {
            for out in node.outputs { producerByOutput[out] = node }
            for inp in node.inputs { consumersByInput[inp, default: []].append(node) }
        }

        var offsets: [Int] = []
        for node in nodes where node.opType == "Less" && node.inputs.count == 2 {
            let rhsName = node.inputs[1]
            guard let rhsNode = producerByOutput[rhsName],
                  rhsNode.opType == "Constant",
                  !rhsNode.constantZeroFloatOffsets.isEmpty else {
                continue
            }
            // 双重锁定：节点名位于 SineGen 子图，或前驱为 Sub 且下游经 Cast/Mul 流向相位累加器
            let inSineGenByName = node.name.localizedCaseInsensitiveContains("sin_gen")
                || node.name.localizedCaseInsensitiveContains("SineGen")
            let lhsIsSub = producerByOutput[node.inputs[0]]?.opType == "Sub"
            let feedsCast = node.outputs.contains { out in
                (consumersByInput[out] ?? []).contains(where: { $0.opType == "Cast" })
            }
            if inSineGenByName || (lhsIsSub && feedsCast) {
                offsets.append(contentsOf: rhsNode.constantZeroFloatOffsets)
            }
        }
        return offsets
    }

    // MARK: - Protobuf Wire Primitives

    private static func iterFields(base: UnsafePointer<UInt8>, start: Int, end: Int) -> [(field: Int, wire: Int, payload: Range<Int>)] {
        var result: [(Int, Int, Range<Int>)] = []
        var i = start
        while i < end {
            guard let (tag, afterTag) = readVarint(base: base, index: i, end: end) else { break }
            i = afterTag
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x07)
            switch wire {
            case 0:
                guard let (_, next) = readVarint(base: base, index: i, end: end) else { return result }
                result.append((field, wire, i..<next))
                i = next
            case 1:
                let next = i + 8
                guard next <= end else { return result }
                result.append((field, wire, i..<next))
                i = next
            case 2:
                guard let (len, afterLen) = readVarint(base: base, index: i, end: end) else { return result }
                let lenInt = Int(len)
                guard lenInt >= 0, afterLen <= end - lenInt else { return result }
                let next = afterLen + lenInt
                result.append((field, wire, afterLen..<next))
                i = next
            case 5:
                let next = i + 4
                guard next <= end else { return result }
                result.append((field, wire, i..<next))
                i = next
            default:
                return result
            }
        }
        return result
    }

    private static func readVarint(base: UnsafePointer<UInt8>, index: Int, end: Int) -> (UInt64, Int)? {
        var i = index
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < end {
            let b = base[i]
            i += 1
            value |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return (value, i)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func readVarintDirect(base: UnsafePointer<UInt8>, range: Range<Int>) -> UInt64? {
        readVarint(base: base, index: range.lowerBound, end: range.upperBound)?.0
    }

    private static func decodeString(base: UnsafePointer<UInt8>, range: Range<Int>) -> String {
        let buffer = UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func readUInt32LE(base: UnsafePointer<UInt8>, offset: Int) -> UInt32 {
        UInt32(base[offset])
            | (UInt32(base[offset + 1]) << 8)
            | (UInt32(base[offset + 2]) << 16)
            | (UInt32(base[offset + 3]) << 24)
    }
}
