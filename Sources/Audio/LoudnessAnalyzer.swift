import AVFoundation
import Foundation

/// 单首音频的实测响度与峰值档案，随音频文件按身份或缓存文件名持久化。
struct LoudnessProfile: Codable, Equatable, Sendable {
    var rms: Double
    var peak: Double
    var recommendedGain: Float
    var measuredAt: Date
}

/// 离线响度测量：按真实 PCM 采样计算活跃均方根（跳过静默门限 -55 dBFS）与峰值安全增益。
enum LoudnessAnalyzer {
    /// 目标均方根（约 -16.5 dBFS），接近主流流媒体响度标准，兼顾动态余量。
    static let defaultTargetRMS: Double = 0.15
    /// 静默门限：忽略 < -55 dBFS 的静音段，避免长前奏静音拉高整首增益。
    static let silenceFloor: Double = 0.0018
    /// 峰值安全上限（约 -1.0 dBFS），给 AAC 跨采样峰值与系统重采样预留 headroom，避免高潮段破音。
    static let peakSafetyCeiling: Double = 0.89
    static let gainRange: ClosedRange<Float> = 0.35...1.8

    static func computeProfile(rmsSquaredSum: Double, activeSamples: Int, peak: Double) -> LoudnessProfile? {
        guard activeSamples > 0, rmsSquaredSum > 0, peak > 0 else { return nil }
        let rms = sqrt(rmsSquaredSum / Double(activeSamples))
        guard rms.isFinite, rms > 0 else { return nil }
        let rawGain = defaultTargetRMS / rms
        let peakCeiling = peakSafetyCeiling / max(peak, 0.001)
        let clamped = Float(min(rawGain, peakCeiling))
        let safeGain = min(max(clamped, gainRange.lowerBound), gainRange.upperBound)
        return LoudnessProfile(rms: rms, peak: peak, recommendedGain: safeGain, measuredAt: Date())
    }

    static func analyzeSamples(_ samples: [Float]) -> LoudnessProfile? {
        var sumSq: Double = 0
        var active = 0
        var peak: Double = 0
        for sample in samples {
            guard sample.isFinite, abs(sample) < 1e4 else { continue }
            let v = Double(abs(sample))
            if v > peak { peak = v }
            if v >= silenceFloor {
                sumSq += v * v
                active += 1
            }
        }
        return computeProfile(rmsSquaredSum: sumSq, activeSamples: active, peak: peak)
    }

    /// 对本地音频文件解码采样并离线测出推荐响度增益。
    ///
    /// 默认扫描前 15 分钟（`maxSeconds = 900`），覆盖绝大多数完整歌曲（避免前奏轻柔、60 秒后副歌响亮的曲目
    /// 被低估峰值而推高增益导致破音），同时防止数小时长播客/合集在后台长时间解码；传 `0` 表示不限制时长。
    static func analyzeFile(at url: URL, maxSeconds: Double = 900) async -> LoudnessProfile? {
        await Task.detached(priority: .utility) {
            await readAndMeasure(url: url, maxSeconds: maxSeconds)
        }.value
    }

    private static func readAndMeasure(url: URL, maxSeconds: Double) async -> LoudnessProfile? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        if maxSeconds > 0, maxSeconds.isFinite {
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: maxSeconds, preferredTimescale: 600)
            )
        }
        guard reader.startReading() else { return nil }

        var sumSq: Double = 0
        var active = 0
        var peak: Double = 0
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                   let pointer {
                    let count = length / MemoryLayout<Float>.size
                    let floats = pointer.withMemoryRebound(to: Float.self, capacity: count) {
                        UnsafeBufferPointer(start: $0, count: count)
                    }
                    for sample in floats {
                        guard sample.isFinite, abs(sample) < 1e4 else { continue }
                        let v = Double(abs(sample))
                        if v > peak { peak = v }
                        if v >= silenceFloor {
                            sumSq += v * v
                            active += 1
                        }
                    }
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }
        return computeProfile(rmsSquaredSum: sumSq, activeSamples: active, peak: peak)
    }
}

/// 曲目响度元数据磁盘缓存（`loudness-v2.json`），二次播放立即可用。
///
/// v2 起改为全曲峰值与响度测量并预留 -1 dBFS 余量，自动作废早期仅测前 60 秒的 v1 缓存。
actor LoudnessCache {
    static let shared = LoudnessCache(
        fileURL: RuntimeSandbox.cachesDirectory().appendingPathComponent("FLOW/loudness-v2.json")
    )

    private struct Manifest: Codable, Sendable {
        var version: Int = 2
        var profiles: [String: LoudnessProfile] = [:]
    }

    private let fileURL: URL?
    private var profiles: [String: LoudnessProfile] = [:]
    private var inFlight: [String: Task<LoudnessProfile?, Never>] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
           decoded.version == 2 {
            self.profiles = decoded.profiles
        }
    }

    func cachedProfile(forKey key: String) -> LoudnessProfile? {
        profiles[key]
    }

    func store(_ profile: LoudnessProfile, forKey key: String) {
        profiles[key] = profile
        save()
    }

    func measureIfNeeded(key: String, url: URL) async -> LoudnessProfile? {
        if let existing = profiles[key] { return existing }
        if let task = inFlight[key] { return await task.value }
        let task = Task<LoudnessProfile?, Never> {
            await LoudnessAnalyzer.analyzeFile(at: url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            profiles[key] = result
            save()
        }
        return result
    }

    func clear() {
        profiles.removeAll()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func save() {
        guard let fileURL else { return }
        // 避免长期增长：保留最近测量过的前 1000 条记录。
        if profiles.count > 1000 {
            let trimmed = profiles.sorted { $0.value.measuredAt > $1.value.measuredAt }.prefix(800)
            profiles = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Manifest(profiles: profiles)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
