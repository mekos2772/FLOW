import Accelerate
import Foundation

/// 从 `.index` 离线提取的紧凑 float32 向量索引（`.f32bin`），使用 Accelerate BLAS 做快速 k-NN 检索融合。
final class F32VectorIndex: @unchecked Sendable {
    static let magic = Data("F32I".utf8)
    static let headerByteCount = 16

    let rows: Int
    let dim: Int
    private let vectors: [Float]          // row-major [rows, dim]
    private let vectorsTransposed: [Float] // row-major [dim, rows] 供 vDSP_mmul 使用
    private let rowNormsSq: [Float]       // [rows]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= Self.headerByteCount else {
            throw VoiceError.invalidManifest(reason: "索引文件过小：\(url.lastPathComponent)")
        }
        guard data.subdata(in: 0..<4) == Self.magic else {
            throw VoiceError.unsupportedModel("索引格式无效（期望 .f32bin）：\(url.lastPathComponent)")
        }

        let version = Self.readUInt32LE(data, offset: 4)
        guard version == 1 else {
            throw VoiceError.unsupportedModel("不支持的 .f32bin 版本 \(version)")
        }
        let r = Int(Self.readUInt32LE(data, offset: 8))
        let d = Int(Self.readUInt32LE(data, offset: 12))
        let expectedBytes = Self.headerByteCount + r * d * MemoryLayout<Float>.stride
        guard r > 0, d > 0, data.count == expectedBytes else {
            throw VoiceError.invalidManifest(reason: "索引数据长度不匹配 (\(r)x\(d))")
        }

        self.rows = r
        self.dim = d
        var floats = [Float](repeating: 0, count: r * d)
        _ = floats.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, from: Self.headerByteCount..<expectedBytes)
        }
        self.vectors = floats

        var transposed = [Float](repeating: 0, count: d * r)
        for row in 0..<r {
            let srcBase = row * d
            for col in 0..<d {
                transposed[col * r + row] = floats[srcBase + col]
            }
        }
        self.vectorsTransposed = transposed

        var norms = [Float](repeating: 0, count: r)
        floats.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<r {
                var sumSq: Float = 0
                vDSP_svesq(base + i * d, 1, &sumSq, vDSP_Length(d))
                norms[i] = sumSq
            }
        }
        self.rowNormsSq = norms
    }

    /// 用 Accelerate `vDSP_mmul` 计算 L2 最近 k=8 个索引向量的反平方加权融合，并按 `rate` 混回原始 HuBERT 特征。
    func searchAndBlend(features: [Float], frameCount: Int, rate: Float) throws -> [Float] {
        guard rate > 0, frameCount > 0, !vectors.isEmpty else {
            return features
        }
        guard features.count == frameCount * dim else {
            throw VoiceError.inferenceFailed("索引维度(\(dim))与 HuBERT 特征长度不匹配")
        }

        let m = frameCount
        let n = rows
        let kDim = dim
        let topK = min(8, n)

        // Query row norms
        var qNormsSq = [Float](repeating: 0, count: m)
        features.withUnsafeBufferPointer { qBuf in
            guard let base = qBuf.baseAddress else { return }
            for i in 0..<m {
                var sumSq: Float = 0
                vDSP_svesq(base + i * kDim, 1, &sumSq, vDSP_Length(kDim))
                qNormsSq[i] = sumSq
            }
        }

        // Dots [m, n] = Q [m, kDim] * X^T [kDim, n]
        var dots = [Float](repeating: 0, count: m * n)
        vDSP_mmul(
            features, 1,
            vectorsTransposed, 1,
            &dots, 1,
            vDSP_Length(m),
            vDSP_Length(n),
            vDSP_Length(kDim)
        )

        var out = features
        let oneMinusRate = 1.0 - rate
        var bestDist = [Float](repeating: 0, count: topK)
        var bestIdx = [Int](repeating: 0, count: topK)
        var weights = [Float](repeating: 0, count: topK)
        var blendedRow = [Float](repeating: 0, count: kDim)

        for i in 0..<m {
            let dotOffset = i * n
            let qNorm = qNormsSq[i]

            for t in 0..<topK {
                bestDist[t] = Float.greatestFiniteMagnitude
                bestIdx[t] = 0
            }

            for j in 0..<n {
                let d2 = max(qNorm + rowNormsSq[j] - 2.0 * dots[dotOffset + j], 1e-12)
                if d2 < bestDist[topK - 1] {
                    var pos = topK - 1
                    while pos > 0 && d2 < bestDist[pos - 1] {
                        bestDist[pos] = bestDist[pos - 1]
                        bestIdx[pos] = bestIdx[pos - 1]
                        pos -= 1
                    }
                    bestDist[pos] = d2
                    bestIdx[pos] = j
                }
            }

            // RVC pipeline.py: weight = (1 / score)^2, normalized
            var wSum: Float = 0
            for t in 0..<topK {
                let inv = 1.0 / bestDist[t]
                let w = inv * inv
                weights[t] = w
                wSum += w
            }
            if wSum > 0 {
                for t in 0..<topK { weights[t] /= wSum }
            }

            blendedRow.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            for t in 0..<topK {
                let w = weights[t]
                let vecOffset = bestIdx[t] * kDim
                for c in 0..<kDim {
                    blendedRow[c] += vectors[vecOffset + c] * w
                }
            }

            let outOffset = i * kDim
            for c in 0..<kDim {
                out[outOffset + c] = blendedRow[c] * rate + features[outOffset + c] * oneMinusRate
            }
        }

        return out
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}
