import AVFoundation
import XCTest
@testable import SpatialLyricsPlayer

/// 原生 Accelerate DSP（STFT/ISTFT/MelSpectrogram/Butterworth/RMS/M4A）与 VoicePackStore 单元测试。
final class VoiceAudioDSPAndPackTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-dsp-pack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - DSP 往返与 Python 数值一致性

    func testMDXSTFTAndISTFTRoundTripOnMixedRadixFFTSizes() throws {
        for (nFFT, hop) in [(1024, 256), (4096, 1024), (6144, 1024), (7680, 1024)] {
            let nSamples = 16_384
            var left = [Float](repeating: 0, count: nSamples)
            var right = [Float](repeating: 0, count: nSamples)
            for i in 0..<nSamples {
                left[i] = 0.6 * sinf(Float(i) * 0.073) + 0.25 * cosf(Float(i) * 0.21)
                right[i] = 0.5 * cosf(Float(i) * 0.091) - 0.3 * sinf(Float(i) * 0.17)
            }

            let dimF = nFFT / 2 + 1
            let (spec, frames) = try VoiceAudioDSP.mdxSTFT(
                left: left,
                right: right,
                nFFT: nFFT,
                hopLength: hop,
                dimF: dimF
            )
            XCTAssertGreaterThan(frames, 10)
            let inv = try VoiceAudioDSP.mdxISTFT(
                tensor: spec,
                dimF: dimF,
                frames: frames,
                nFFT: nFFT,
                hopLength: hop,
                targetLength: nSamples
            )

            var maxErr: Float = 0
            // 排除极短末端截断边距
            for i in 64..<(nSamples - 64) {
                maxErr = max(maxErr, abs(left[i] - inv.left[i]), abs(right[i] - inv.right[i]))
            }
            XCTAssertLessThan(maxErr, 1e-4, "nFFT=\(nFFT) STFT/ISTFT 往返误差超标: \(maxErr)")
        }
    }

    func testWAVAndM4AWriteDecodeRoundTripIncluding40kResample() throws {
        let sr = 40_000.0
        let count = 20_000 // 0.5 秒
        var mono = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mono[i] = 0.4 * sinf(2.0 * Float.pi * 440.0 * Float(i) / Float(sr))
        }

        let wavURL = tempDir.appendingPathComponent("test.wav")
        try VoiceAudioDSP.writeWAV(left: mono, right: nil, sampleRate: sr, to: wavURL)
        let decWav = try VoiceAudioDSP.decodeMono(url: wavURL, targetSampleRate: 16_000)
        XCTAssertEqual(decWav.count, 8_000, accuracy: 200)

        let m4aURL = tempDir.appendingPathComponent("test.m4a")
        let written = try VoiceAudioDSP.writeM4A(left: mono, right: mono, sampleRate: sr, to: m4aURL)
        XCTAssertEqual(written.sampleRate, 44_100, "40kHz 应自动重采样至 AAC 支持的 44.1kHz")
        XCTAssertEqual(written.duration, 0.5, accuracy: 0.05)

        let m4aFile = try AVAudioFile(forReading: m4aURL)
        XCTAssertGreaterThan(m4aFile.length, 18_000)
    }

    func testMixVocalAndInstrumentalClipsAt099() {
        let vocal = [Float](repeating: 0.8, count: 100)
        let inst = [Float](repeating: 0.8, count: 120)
        let mixed = VoiceAudioDSP.mixVocalAndInstrumental(
            vocalLeft: vocal,
            vocalRight: nil,
            instLeft: inst,
            instRight: inst
        )
        XCTAssertEqual(mixed.left.count, 120)
        XCTAssertEqual(mixed.left[0], 0.99, accuracy: 1e-5)
    }

    func testParityAgainstPythonReferenceWhenFixturePresent() throws {
        let refURL = URL(fileURLWithPath: "/tmp/voice_ref/ref_vectors.json")
        let wavURL = URL(fileURLWithPath: "/tmp/voice_ref/input_song.wav")
        guard FileManager.default.fileExists(atPath: refURL.path),
              FileManager.default.fileExists(atPath: wavURL.path) else {
            return
        }

        struct Ref: Decodable {
            let audio_len: Int
            let audio_hp_rms: Double
            let mel_shape: [Int]
            let mel_sample_row0: [Float]
            let mel_sample_row64: [Float]
        }
        let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: refURL))

        var audio = try VoiceAudioDSP.decodeMono(url: wavURL, targetSampleRate: 16_000)
        XCTAssertEqual(audio.count, ref.audio_len, accuracy: 160)
        let absMax = audio.reduce(Float(0)) { max($0, abs($1)) }
        let normDiv = absMax / 0.95
        if normDiv > 1.0 {
            for i in 0..<audio.count { audio[i] /= normDiv }
        }
        let hp = VoiceAudioDSP.butterworthHighPass48Hz16k(audio)
        let hpRMS = sqrt(Double(hp.reduce(0) { $0 + $1 * $1 }) / Double(hp.count))
        XCTAssertEqual(hpRMS, ref.audio_hp_rms, accuracy: 0.01)

        let pad = VoiceAudioDSP.reflectPad1D(hp, pad: 16_000)
        let (mel, frames) = try VoiceAudioDSP.rmvpeLogMelSpectrogram(audio16k: pad)
        XCTAssertEqual(frames, ref.mel_shape[1], accuracy: 2)
        for k in 0..<min(8, frames) {
            XCTAssertEqual(mel[k], ref.mel_sample_row0[k], accuracy: 0.15)
            XCTAssertEqual(mel[64 * frames + k], ref.mel_sample_row64[k], accuracy: 0.15)
        }
    }

    // MARK: - VoicePackStore

    func testVoicePackImportVersionSwitchingRenameDelete() async throws {
        let packsRoot = tempDir.appendingPathComponent("Packs", isDirectory: true)
        let store = VoicePackStore(packsRoot: packsRoot)

        // 构造 .voicepack + .f32bin
        let vpURL = tempDir.appendingPathComponent("Singer.voicepack", isDirectory: true)
        try FileManager.default.createDirectory(at: vpURL, withIntermediateDirectories: true)
        let v2Data = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64))
        try v2Data.write(to: vpURL.appendingPathComponent("model.onnx"))
        let meta = """
        {"name":"Alpha","engine":"rvc","architecture":"v2","hasF0":true,"sampleRate":40000,"embeddingDim":768,"modelFile":"model.onnx"}
        """
        try Data(meta.utf8).write(to: vpURL.appendingPathComponent("pack.json"))

        let manifest = try await store.importPack(weightURL: vpURL)
        XCTAssertEqual(manifest.displayName, "Alpha")
        XCTAssertEqual(manifest.versions.count, 1)
        XCTAssertEqual(manifest.selectedVersion?.architectureHint, "v2")

        // 追加第二个版本 (.onnx 单文件)
        let secondONNX = tempDir.appendingPathComponent("alt_48k.onnx")
        try v2Data.write(to: secondONNX)
        let updated = try await store.addVersion(
            packID: manifest.packID,
            weightURL: secondONNX,
            versionName: "take2"
        )
        XCTAssertEqual(updated.versions.count, 2)
        XCTAssertEqual(updated.selectedVersionID, "take2")

        try store.selectVersion(packID: manifest.packID, versionID: "v1")
        XCTAssertEqual(try store.manifest(packID: manifest.packID)?.selectedVersionID, "v1")

        try store.rename(packID: manifest.packID, displayName: "Beta")
        XCTAssertEqual(try store.manifest(packID: manifest.packID)?.displayName, "Beta")

        try store.delete(packID: manifest.packID)
        XCTAssertTrue(try store.allPacks().isEmpty)
    }

    // MARK: - ONNX SineGen 相位修复 & ContentVec 兼容性校验

    func testONNXSineGenSanitizerPatchesZeroThresholdWithoutTouchingNonSineGenLess() throws {
        func encodeVarint(_ value: UInt64) -> Data {
            var v = value
            var out = Data()
            while v >= 0x80 {
                out.append(UInt8((v & 0x7F) | 0x80))
                v >>= 7
            }
            out.append(UInt8(v))
            return out
        }

        func fieldBytes(fieldNumber: Int, wireType: Int, payload: Data) -> Data {
            var data = encodeVarint(UInt64((fieldNumber << 3) | wireType))
            if wireType == 2 {
                data.append(encodeVarint(UInt64(payload.count)))
            }
            data.append(payload)
            return data
        }

        func makeFloatConstantNode(name: String, output: String, value: Float) -> Data {
            var bits = value.bitPattern.littleEndian
            let rawFloat = Data(bytes: &bits, count: 4)
            // TensorProto: data_type=1 (FLOAT), raw_data=rawFloat
            var tensor = fieldBytes(fieldNumber: 2, wireType: 0, payload: encodeVarint(1))
            tensor.append(fieldBytes(fieldNumber: 9, wireType: 2, payload: rawFloat))
            // AttributeProto: name="value", t=tensor (field 5)
            var attr = fieldBytes(fieldNumber: 1, wireType: 2, payload: Data("value".utf8))
            attr.append(fieldBytes(fieldNumber: 5, wireType: 2, payload: tensor))
            // NodeProto: output(2), name(3), op_type(4), attribute(5)
            var node = fieldBytes(fieldNumber: 2, wireType: 2, payload: Data(output.utf8))
            node.append(fieldBytes(fieldNumber: 3, wireType: 2, payload: Data(name.utf8)))
            node.append(fieldBytes(fieldNumber: 4, wireType: 2, payload: Data("Constant".utf8)))
            node.append(fieldBytes(fieldNumber: 5, wireType: 2, payload: attr))
            return node
        }

        func makeNode(opType: String, name: String, inputs: [String], outputs: [String]) -> Data {
            var node = Data()
            for inp in inputs {
                node.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: Data(inp.utf8)))
            }
            for out in outputs {
                node.append(fieldBytes(fieldNumber: 2, wireType: 2, payload: Data(out.utf8)))
            }
            node.append(fieldBytes(fieldNumber: 3, wireType: 2, payload: Data(name.utf8)))
            node.append(fieldBytes(fieldNumber: 4, wireType: 2, payload: Data(opType.utf8)))
            return node
        }

        // 构造含无关 Less(< 0.0) 与 SineGen Less(< 0.0) 的最小 ModelProto
        var graph = Data()
        let unrelatedConst = makeFloatConstantNode(name: "/enc/Constant_other", output: "c_other", value: 0.0)
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: unrelatedConst))
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: makeNode(
            opType: "Less", name: "/enc/Less_other", inputs: ["x", "c_other"], outputs: ["y_other"]
        )))
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: makeNode(
            opType: "Sub", name: "/dec/m_source/l_sin_gen/Sub_2", inputs: ["a", "b"], outputs: ["sub_out"]
        )))
        let sineGenConst = makeFloatConstantNode(name: "/dec/m_source/l_sin_gen/Constant_51", output: "c_sg", value: 0.0)
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: sineGenConst))
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: makeNode(
            opType: "Less", name: "/dec/m_source/l_sin_gen/Less", inputs: ["sub_out", "c_sg"], outputs: ["less_out"]
        )))
        graph.append(fieldBytes(fieldNumber: 1, wireType: 2, payload: makeNode(
            opType: "Cast", name: "/dec/m_source/l_sin_gen/Cast", inputs: ["less_out"], outputs: ["cast_out"]
        )))

        let modelBytes = fieldBytes(fieldNumber: 7, wireType: 2, payload: graph)
        let offsets = ONNXSineGenSanitizer.findSineGenZeroThresholdOffsets(in: modelBytes)
        XCTAssertEqual(offsets.count, 1, "只应命中 SineGen 的阈值常量，不能误改普通 Less 常量")

        let srcURL = tempDir.appendingPathComponent("mock_rvc.onnx")
        let cacheDir = tempDir.appendingPathComponent("sanitized_cache", isDirectory: true)
        try modelBytes.write(to: srcURL)

        let patchedURL = try ONNXSineGenSanitizer.sanitizeIfNeeded(modelURL: srcURL, cacheDirectory: cacheDir)
        XCTAssertNotEqual(patchedURL, srcURL)

        let patchedData = try Data(contentsOf: patchedURL)
        XCTAssertEqual(patchedData.count, modelBytes.count)
        XCTAssertTrue(ONNXSineGenSanitizer.findSineGenZeroThresholdOffsets(in: patchedData).isEmpty)

        let patchOffset = offsets[0]
        var expectedBits = Float(-0.5).bitPattern.littleEndian
        let expectedBytes = Data(bytes: &expectedBits, count: 4)
        XCTAssertEqual(patchedData[patchOffset..<(patchOffset + 4)], expectedBytes)
        XCTAssertEqual(patchedData[..<patchOffset], modelBytes[..<patchOffset])
        XCTAssertEqual(patchedData[(patchOffset + 4)...], modelBytes[(patchOffset + 4)...])

        // 再次调用应幂等命中缓存，且不含 SineGen 的 ONNX 直接返回原路径
        let cachedHit = try ONNXSineGenSanitizer.sanitizeIfNeeded(modelURL: srcURL, cacheDirectory: cacheDir)
        XCTAssertEqual(cachedHit, patchedURL)
        let untouched = try ONNXSineGenSanitizer.sanitizeIfNeeded(modelURL: patchedURL, cacheDirectory: cacheDir)
        XCTAssertEqual(untouched, patchedURL)
    }

    @MainActor
    func testHubertCompatibilityCheckRejectsVanillaHubertAndCorruptedLargeONNX() async throws {
        XCTAssertTrue(
            VoiceModelAssetsManager.knownIncompatibleHubertSHA256.contains(
                "a4297149f8df2c0e8feaf88a302129dc6b06b94666131a3b321f89df9e9d0340"
            )
        )

        let dummyURL = tempDir.appendingPathComponent("hubert_base.onnx")
        let okStatus = VoiceModelAssetsManager.AssetStatus(
            kind: .hubert,
            url: dummyURL,
            exists: true,
            sizeBytes: 2048,
            incompatibleReason: nil
        )
        XCTAssertTrue(okStatus.isReady)
        let badStatus = VoiceModelAssetsManager.AssetStatus(
            kind: .hubert,
            url: dummyURL,
            exists: true,
            sizeBytes: 2048,
            incompatibleReason: "not contentvec"
        )
        XCTAssertFalse(badStatus.isReady)

        // 大于 1MB 的伪造损坏 ONNX 应被识别并拒绝导入及标记未就绪
        let assets = VoiceModelAssetsManager(voiceRoot: tempDir.appendingPathComponent("VoiceAssets", isDirectory: true))
        let corruptedONNX = tempDir.appendingPathComponent("corrupted_hubert.onnx")
        try Data(repeating: 0xAA, count: 1_050_000).write(to: corruptedONNX)

        XCTAssertThrowsError(try assets.importAsset(from: corruptedONNX, kind: .hubert)) { err in
            XCTAssertFalse(err.localizedDescription.isEmpty)
        }

        // 若旧文件已留在默认目录，后台校验应检测出不兼容并把缺失底座标记出来
        let installedURL = assets.url(for: .hubert)
        try Data(repeating: 0xAA, count: 1_050_000).write(to: installedURL)
        let detectedIncompatible = await assets.verifyHubertCompatibilityIfNeeded()
        XCTAssertTrue(detectedIncompatible)
        XCTAssertTrue(assets.missingRequiredAssets(requiresF0: true, requiresSeparation: true).contains(.hubert))
        XCTAssertNotNil(assets.statusSummary().first { $0.kind == .hubert }?.incompatibleReason)
    }
}
