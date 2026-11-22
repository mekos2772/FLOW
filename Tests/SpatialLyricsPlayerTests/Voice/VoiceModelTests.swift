import XCTest
@testable import SpatialLyricsPlayer

/// FLOW Voice 基础值类型、ONNX Runtime 会话与 Accelerate F32 向量索引测试。
final class VoiceParameterValueTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let values: [VoiceParameterValue] = [.int(-7), .double(0.33), .bool(true), .string("mdx-vocals")]
        let data = try JSONEncoder().encode(values)
        let back = try JSONDecoder().decode([VoiceParameterValue].self, from: data)
        XCTAssertEqual(back, values)
    }

    func testDecodeTypeCoercion() throws {
        XCTAssertEqual(VoiceParameterValue.int(3).doubleValue, 3.0)
        XCTAssertEqual(VoiceParameterValue.double(4.8).intValue, 4)
        XCTAssertNil(VoiceParameterValue.string("x").intValue)
        XCTAssertEqual(VoiceParameterValue.bool(true).boolValue, true)
    }
}

final class ORTSessionAndBackendTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ort-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testORTEnvironmentVersionAndBackends() {
        let ver = ORTEnvironment.runtimeVersion
        XCTAssertFalse(ver.isEmpty)
        XCTAssertNotEqual(ver, "unknown")

        let caps = VoiceBackendRegistry.shared.capabilities()
        XCTAssertEqual(caps.map(\.id), ["onnx-coreml", "onnx-cpu"])
        XCTAssertTrue(caps.contains(where: { $0.id == "onnx-cpu" && $0.available }))
    }

    func testORTSessionRunsDynamicShapes() async throws {
        let onnxURL = tempDir.appendingPathComponent("tiny_v2.onnx")
        let data = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64))
        try data.write(to: onnxURL)

        let session = try ORTSession(modelURL: onnxURL, provider: .cpu, intraOpThreads: 1, allowCPUFallback: false)
        for length in [10, 42] {
            let phone = [Float](repeating: 0.25, count: length * 768)
            let rnd = [Float](repeating: 0.5, count: 192 * length)
            let pitch = [Int64](repeating: 120, count: length)
            let nsff0 = [Float](repeating: 220, count: length)
            let outputs = try await session.run(inputs: [
                "phone": .float32(data: phone, shape: [1, Int64(length), 768]),
                "phone_lengths": .int64(data: [Int64(length)], shape: [1]),
                "pitch": .int64(data: pitch, shape: [1, Int64(length)]),
                "nsff0": .float32(data: nsff0, shape: [1, Int64(length)]),
                "sid": .int64(data: [0], shape: [1]),
                "rnd": .float32(data: rnd, shape: [1, 192, Int64(length)]),
            ])
            let audio = try XCTUnwrap(outputs["audio"])
            XCTAssertEqual(audio.shape, [1, 1, Int64(length)])
            XCTAssertEqual(audio.floatData.count, length)
            // TinyRVC 计算 rnd_mean - rnd_mean^2 = 0.5 - 0.25 = 0.25
            XCTAssertEqual(audio.floatData[0], 0.25, accuracy: 1e-5)
        }
    }

    func testF32VectorIndexKNNBlending() throws {
        let rows = 4
        let dim = 4
        var bin = Data("F32I".utf8)
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { bin.append(contentsOf: $0) }
        }
        appendUInt32(1)
        appendUInt32(UInt32(rows))
        appendUInt32(UInt32(dim))

        let matrix: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        matrix.withUnsafeBufferPointer { buf in
            bin.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                count: matrix.count * MemoryLayout<Float>.stride
            ))
        }

        let idxURL = tempDir.appendingPathComponent("test.f32bin")
        try bin.write(to: idxURL)

        let index = try F32VectorIndex(url: idxURL)
        XCTAssertEqual(index.rows, 4)
        XCTAssertEqual(index.dim, 4)

        let query: [Float] = [0.99, 0.01, 0, 0]
        let out = try index.searchAndBlend(features: query, frameCount: 1, rate: 1.0)
        // 最近向量是 [1, 0, 0, 0]，第一维应显著高于其余维度
        XCTAssertGreaterThan(out[0], 0.99)
    }
}
