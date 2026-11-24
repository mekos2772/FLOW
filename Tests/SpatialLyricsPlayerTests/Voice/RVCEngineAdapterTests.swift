import XCTest
@testable import SpatialLyricsPlayer

/// RVCEngineAdapter：ONNX 计算图探测、注册表默认可用性与参数规范化。
final class RVCEngineAdapterTests: XCTestCase {
    static let tinyV2F0Base64 =
        "CAg6zQIKOgoDcm5kEglhdWRpb19taWQiClJlZHVjZU1lYW4qCwoEYXhlc0ABoAEHKg8KCGtlZXBkaW1zGAGgAQIKJQoJYXVkaW9fbWlkCglhdWRpb19taWQSCGF1ZGlvX3NxIgNNdWwKIQoJYXVkaW9fbWlkCghhdWRpb19zcRIFYXVkaW8iA1N1YhIHVGlueVJWQ1odCgVwaG9uZRIUChIIARIOCgIIAQoDEgFUCgMIgAZaGwoNcGhvbmVfbGVuZ3RocxIKCggIBxIECgIIAVoYCgVwaXRjaBIPCg0IBxIJCgIIAQoDEgFUWhgKBW5zZmYwEg8KDQgBEgkKAggBCgMSAVRaEQoDc2lkEgoKCAgHEgQKAggBWhsKA3JuZBIUChIIARIOCgIIAQoDCMABCgMSAVRiHAoFYXVkaW8SEwoRCAESDQoCCAEKAggBCgMSAVRCBAoAEBE="
    static let tinyV1NoF0Base64 =
        "CAg6mQIKOgoDcm5kEglhdWRpb19taWQiClJlZHVjZU1lYW4qCwoEYXhlc0ABoAEHKg8KCGtlZXBkaW1zGAGgAQIKJQoJYXVkaW9fbWlkCglhdWRpb19taWQSCGF1ZGlvX3NxIgNNdWwKIQoJYXVkaW9fbWlkCghhdWRpb19zcRIFYXVkaW8iA1N1YhIHVGlueVJWQ1odCgVwaG9uZRIUChIIARIOCgIIAQoDEgFUCgMIgAJaGwoNcGhvbmVfbGVuZ3RocxIKCggIBxIECgIIAVoRCgNzaWQSCgoICAcSBAoCCAFaGwoDcm5kEhQKEggBEg4KAggBCgMIwAEKAxIBVGIcCgVhdWRpbxITChEIARINCgIIAQoCCAEKAxIBVEIECgAQEQ=="

    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-adapter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTinyModel(_ b64: String, name: String) throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testRegistryPreRegistersDefaultRVCEngine() {
        let adapter = VoiceEngineRegistry.shared.adapter(for: "rvc")
        XCTAssertNotNil(adapter, "默认注册表必须自动注册 rvc 引擎")
    }

    func testInspectDetectsV2F0ONNXAndVoicePackMetadata() async throws {
        let packDir = tempDir.appendingPathComponent("singer.voicepack", isDirectory: true)
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let modelData = try XCTUnwrap(Data(base64Encoded: Self.tinyV2F0Base64))
        try modelData.write(to: packDir.appendingPathComponent("model.onnx"))
        let packJSON = """
        {
          "format": "flow-voicepack-v1",
          "name": "TestSinger",
          "engine": "rvc",
          "architecture": "v2",
          "hasF0": true,
          "sampleRate": 48000,
          "embeddingDim": 768,
          "interChannels": 192,
          "speakerCount": 2,
          "modelFile": "model.onnx"
        }
        """
        try Data(packJSON.utf8).write(to: packDir.appendingPathComponent("pack.json"))

        let insp = try await RVCEngineAdapter().inspect(modelURL: packDir)
        XCTAssertEqual(insp.architectureHint, "v2")
        XCTAssertEqual(insp.embeddingDim, 768)
        XCTAssertEqual(insp.interChannels, 192)
        XCTAssertEqual(insp.sampleRate, 48_000)
        XCTAssertTrue(insp.hasF0)
        XCTAssertEqual(insp.speakerCount, 2)
        XCTAssertEqual(insp.fingerprint.count, 64)
        XCTAssertTrue(insp.fingerprint.allSatisfy(\.isHexDigit))
    }

    func testInspectDetectsV1NoF0FromBareONNX() async throws {
        let url = try writeTinyModel(Self.tinyV1NoF0Base64, name: "singer_32k.onnx")
        let insp = try await RVCEngineAdapter().inspect(modelURL: url)
        XCTAssertEqual(insp.architectureHint, "v1")
        XCTAssertEqual(insp.embeddingDim, 256)
        XCTAssertEqual(insp.sampleRate, 32_000)
        XCTAssertFalse(insp.hasF0)
    }

    func testInspectRejectsLegacyPthCheckpoint() async throws {
        let legacy = tempDir.appendingPathComponent("legacy.pth")
        try Data("fake-pth".utf8).write(to: legacy)
        do {
            _ = try await RVCEngineAdapter().inspect(modelURL: legacy)
            XCTFail("应明确拒绝 .pth 遗留权重")
        } catch let err as VoiceError {
            if case .unsupportedModel = err { /* expected */ }
            else { XCTFail("期望 unsupportedModel，实际 \(err)") }
        }
    }

    // MARK: - 参数规范化

    func testNormalizeFillsDefaults() {
        let out = RVCEngineAdapter().normalizeParameters([:])
        XCTAssertEqual(out["f0_up_key"], .int(0))
        XCTAssertEqual(out["separation_model"], .string("mdx-lead-vocals"))
        XCTAssertEqual(out["duet_pitch_adapt"], .bool(true))
        XCTAssertEqual(out["index_rate"], .double(0.75))
        XCTAssertEqual(out["filter_radius"], .int(3))
        XCTAssertEqual(out["rms_mix_rate"], .double(0.25))
        XCTAssertEqual(out["protect"], .double(0.33))
    }

    func testNormalizeClampsOutOfRange() {
        let out = RVCEngineAdapter().normalizeParameters([
            "f0_up_key": .int(99),      // 上限 12
            "index_rate": .double(-3),  // 下限 0
            "protect": .double(1.0),    // 上限 0.5
        ])
        XCTAssertEqual(out["f0_up_key"], .int(12))
        XCTAssertEqual(out["index_rate"], .double(0))
        XCTAssertEqual(out["protect"], .double(0.5))
    }

    func testNormalizeRejectsBadPickerValue() {
        let out = RVCEngineAdapter().normalizeParameters([
            "separation_model": .string("unsupported-separator")
        ])
        XCTAssertEqual(out["separation_model"], .string("mdx-lead-vocals"))
    }

    func testNormalizePassesThroughUnknownKeys() {
        let out = RVCEngineAdapter().normalizeParameters([
            "custom_flag": .bool(true)
        ])
        XCTAssertEqual(out["custom_flag"], .bool(true))
    }
}
