import Foundation

/// 处理预设：把一组引擎参数打包为可复用的音色风格档位。
struct VoiceProcessingPreset: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var parameters: [String: VoiceParameterValue]
    var suggestedQualityMode: String?
    var isBuiltIn: Bool

    static let builtIns: [VoiceProcessingPreset] = [
        .init(
            id: "clean",
            displayName: "干净人声",
            parameters: [
                "separation_model": .string("mdx-lead-vocals"),
                "duet_pitch_adapt": .bool(true),
                "index_rate": .double(0.75),
                "filter_radius": .int(3),
                "protect": .double(0.33),
                "rms_mix_rate": .double(0.25),
            ],
            suggestedQualityMode: "balanced",
            isBuiltIn: true
        ),
        .init(
            id: "stage",
            displayName: "高精降噪",
            parameters: [
                "separation_model": .string("mdx-lead-vocals"),
                "duet_pitch_adapt": .bool(true),
                "index_rate": .double(0.55),
                "filter_radius": .int(4),
                "protect": .double(0.45),
                "rms_mix_rate": .double(0.4),
            ],
            suggestedQualityMode: "best",
            isBuiltIn: true
        ),
        .init(
            id: "raw",
            displayName: "直通干声",
            parameters: [
                "separation_model": .string("none"),
                "duet_pitch_adapt": .bool(false),
                "index_rate": .double(0.8),
                "filter_radius": .int(0),
                "protect": .double(0.25),
                "rms_mix_rate": .double(0.15),
            ],
            suggestedQualityMode: "fast",
            isBuiltIn: true
        ),
    ]
}

/// 预设仓库：内置预设 + 用户自定义（持久化到 `Application Support/FLOW/Voice/presets.json`）。
final class VoicePresetStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var custom: [VoiceProcessingPreset] = []

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("presets.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let arr = try? JSONDecoder().decode([VoiceProcessingPreset].self, from: data) {
            custom = arr
        }
    }

    var all: [VoiceProcessingPreset] {
        lock.withLock { VoiceProcessingPreset.builtIns + custom }
    }

    func preset(id: String) -> VoiceProcessingPreset? {
        all.first { $0.id == id }
    }

    @discardableResult
    func save(_ preset: VoiceProcessingPreset) throws -> VoiceProcessingPreset {
        try lock.withLock {
            var p = preset
            p.isBuiltIn = false
            let previous = custom
            custom.removeAll { $0.id == p.id }
            custom.append(p)
            do {
                try persistLocked()
            } catch {
                custom = previous
                throw error
            }
            return p
        }
    }

    func delete(id: String) throws {
        try lock.withLock {
            let previous = custom
            custom.removeAll { $0.id == id }
            do {
                try persistLocked()
            } catch {
                custom = previous
                throw error
            }
        }
    }

    /// 清除所有用户自定义预设并删除 `presets.json`。
    func resetCustomPresets() throws {
        try lock.withLock {
            custom.removeAll()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func persistLocked() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(custom).write(to: fileURL, options: .atomic)
    }
}
