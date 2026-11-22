import CryptoKit
import Foundation

/// UVR MDX-Net ONNX 模型的频谱与补偿参数。
struct MDXModelParams: Sendable, Hashable {
    let compensate: Float
    let dimF: Int
    let dimTLog2: Int
    let nFFT: Int
    let primaryStem: String

    var dimT: Int { 1 << dimTLog2 }
    var isVocalPrimary: Bool {
        primaryStem.lowercased().contains("vocal")
    }
}

/// UVR MDX-Net 已知模型参数目录（对齐 audio-separator `model_data_new.json` 的末 10MB MD5 查找表）。
enum MDXModelCatalog {
    static let bytesToHash = 10_000 * 1024 // 10,240,000 bytes

    static let knownByMD5: [String: MDXModelParams] = [
        "0ddfc0eb5792638ad5dc27850236c246": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "0f2a6bc5b49d87d64728ee40e23bceb1": MDXModelParams(compensate: 1.019, dimF: 2560, dimTLog2: 8, nFFT: 5120, primaryStem: "Instrumental"),
        "1c56ec0224f1d559c42fd6fd2a67b154": MDXModelParams(compensate: 1.025, dimF: 2048, dimTLog2: 8, nFFT: 5120, primaryStem: "Instrumental"),
        "1d64a6d2c30f709b8c9b4ce1366d96ee": MDXModelParams(compensate: 1.065, dimF: 2048, dimTLog2: 8, nFFT: 5120, primaryStem: "Instrumental"),
        "203f2a3955221b64df85a41af87cf8f0": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "26d308f91f3423a67dc69a6d12a8793d": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 9, nFFT: 8192, primaryStem: "Other"),
        "291c2049608edb52648b96e27eb80e95": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "2cdd429caac38f0194b133884160f2c6": MDXModelParams(compensate: 1.045, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "2f5501189a2f6db6349916fabe8c90de": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "398580b6d5d973af3120df54cee6759d": MDXModelParams(compensate: 1.75, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "488b3e6f8bd3717d9d7c428476be2d75": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "4910e7827f335048bdac11fa967772f9": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 7, nFFT: 4096, primaryStem: "Drums"),
        "53c4baf4d12c3e6c3831bb8f5b532b93": MDXModelParams(compensate: 1.043, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "55657dd70583b0fedfba5f67df11d711": MDXModelParams(compensate: 1.022, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "5d343409ef0df48c7d78cce9f0106781": MDXModelParams(compensate: 1.075, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "5f6483271e1efb9bfb59e4a3e6d4d098": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 9, nFFT: 6144, primaryStem: "Vocals"),
        "65ab5919372a128e4167f5e01a8fda85": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 8192, primaryStem: "Other"),
        "6703e39f36f18aa7855ee1047765621d": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 9, nFFT: 16384, primaryStem: "Bass"),
        "6b31de20e84392859a3d09d43f089515": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "73492b58195c3b52d34590d5474452f6": MDXModelParams(compensate: 1.043, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "77d07b2667ddf05b9e3175941b4454a0": MDXModelParams(compensate: 1.021, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "867595e9de46f6ab699008295df62798": MDXModelParams(compensate: 1.03, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "8a88db95c7fb5dbe6a095ff2ffb428b1": MDXModelParams(compensate: 1.026, dimF: 2048, dimTLog2: 8, nFFT: 5120, primaryStem: "Instrumental"),
        "94ff780b977d3ca07c7a343dab2e25dd": MDXModelParams(compensate: 1.039, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "970b3f9492014d18fefeedfe4773cb42": MDXModelParams(compensate: 1.009, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "a3cd63058945e777505c01d2507daf37": MDXModelParams(compensate: 1.03, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "b02be2d198d4968a121030cf8950b492": MDXModelParams(compensate: 1.02, dimF: 2560, dimTLog2: 8, nFFT: 5120, primaryStem: "No Crowd"),
        "b06327a00d5e5fbc7d96e1781bbdb596": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "b33d9b3950b6cbf5fe90a32608924700": MDXModelParams(compensate: 1.03, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "b6bccda408a436db8500083ef3491e8b": MDXModelParams(compensate: 1.02, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "b78da4afc6512f98e4756f5977f5c6b9": MDXModelParams(compensate: 1.021, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "c3b29bdce8c4fa17ec609e16220330ab": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 16384, primaryStem: "Bass"),
        "cb790d0c913647ced70fc6b38f5bea1a": MDXModelParams(compensate: 1.01, dimF: 2560, dimTLog2: 8, nFFT: 5120, primaryStem: "Instrumental"),
        "cc63408db3d80b4d85b0287d1d7c9632": MDXModelParams(compensate: 1.033, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "cd5b2989ad863f116c855db1dfe24e39": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 9, nFFT: 6144, primaryStem: "Reverb"),
        "ceed671467c1f64ebdfac8a2490d0d52": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "d2a1376f310e4f7fa37fb9b5774eb701": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "d7bff498db9324db933d913388cba6be": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "d94058f8c7f1fae4164868ae8ae66b20": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 8, nFFT: 6144, primaryStem: "Vocals"),
        "dc41ede5961d50f277eb846db17f5319": MDXModelParams(compensate: 1.035, dimF: 2048, dimTLog2: 9, nFFT: 4096, primaryStem: "Drums"),
        "e5572e58abf111f80d8241d2e44e7fa4": MDXModelParams(compensate: 1.028, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
        "e7324c873b1f615c35c1967f912db92a": MDXModelParams(compensate: 1.03, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Vocals"),
        "ead8d05dab12ec571d67549b3aab03fc": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 6144, primaryStem: "Instrumental"),
        "f2df6d6863d8f435436d8b561594ff49": MDXModelParams(compensate: 1.035, dimF: 3072, dimTLog2: 8, nFFT: 7680, primaryStem: "Instrumental"),
    ]

    /// 计算与 UVR / audio-separator 相同的模型末尾 10MB MD5。
    static func modelTailMD5(url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        if fileSize > UInt64(bytesToHash) {
            try fh.seek(toOffset: fileSize - UInt64(bytesToHash))
        } else {
            try fh.seek(toOffset: 0)
        }
        var md5 = Insecure.MD5()
        while let chunk = try fh.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func resolveParams(modelURL: URL, inputShape: [Int64]) -> MDXModelParams {
        if let hash = try? modelTailMD5(url: modelURL),
           let known = knownByMD5[hash] {
            return known
        }
        // 回退按输入张量维度 [batch, 4, dimF, dimT] 与文件名猜测合理默认值
        let dimF = inputShape.count >= 4 && inputShape[2] > 0 ? Int(inputShape[2]) : 3072
        let dimT = inputShape.count >= 4 && inputShape[3] > 0 ? Int(inputShape[3]) : 256
        let dimTLog2 = max(Int(round(log2(Double(max(dimT, 64))))), 6)
        let nFFT = dimF >= 3072 ? 7680 : (dimF >= 2560 ? 5120 : 6144)
        let lowerName = modelURL.lastPathComponent.lowercased()
        let stem = lowerName.contains("inst") ? "Instrumental" : "Vocals"
        return MDXModelParams(
            compensate: 1.035,
            dimF: dimF,
            dimTLog2: dimTLog2,
            nFFT: nFFT,
            primaryStem: stem
        )
    }
}
