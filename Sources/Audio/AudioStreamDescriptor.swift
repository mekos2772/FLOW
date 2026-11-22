import Foundation

/// 源无关的音质偏好档位。
enum AudioQualityTier: String, CaseIterable, Sendable, Codable {
    case auto
    case standard
    case high
    case hifi
    case lossless
    case hiRes

    var displayName: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .standard: return String(localized: "标准")
        case .high: return String(localized: "高音质")
        case .hifi: return String(localized: "HiFi 无损")
        case .lossless: return String(localized: "无损 FLAC")
        case .hiRes: return String(localized: "Hi-Res")
        }
    }

    var prefersLossless: Bool {
        self == .hifi || self == .lossless || self == .hiRes
    }
}

/// 源无关的可播放音频流描述，供流式会话、缓存与离线下载共用。
struct AudioStreamDescriptor: Sendable, Equatable {
    let cacheKey: String
    let fileExtension: String
    let qualityTier: AudioQualityTier
    let qualityID: Int
    let codec: String
    let bandwidth: Int
    let sampleRate: Int?
    let isLossless: Bool
    let url: URL
    let backupURLs: [URL]
    let headers: [String: String]
    /// 若来自有限域音源/插件，保存白名单以便音频数据请求与重定向复用同一校验策略；空数组表示不额外限定域名。
    let allowedDomains: [String]

    init(cacheKey: String,
         fileExtension: String = "m4a",
         qualityTier: AudioQualityTier,
         qualityID: Int,
         codec: String,
         bandwidth: Int,
         sampleRate: Int? = nil,
         isLossless: Bool,
         url: URL,
         backupURLs: [URL] = [],
         headers: [String: String] = [:],
         allowedDomains: [String] = []) {
        self.cacheKey = cacheKey
        let cleanedExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        self.fileExtension = cleanedExt.isEmpty ? "m4a" : cleanedExt
        self.qualityTier = qualityTier
        self.qualityID = qualityID
        self.codec = codec
        self.bandwidth = bandwidth
        self.sampleRate = sampleRate
        self.isLossless = isLossless
        self.url = url
        self.backupURLs = backupURLs
        self.headers = headers
        self.allowedDomains = allowedDomains
    }

    var isHLSStream: Bool {
        fileExtension == "m3u8"
            || url.pathExtension.lowercased() == "m3u8"
            || url.path.lowercased().contains(".m3u8")
    }

    var bitrateDescription: String {
        if bandwidth >= 1_000_000 {
            return String(format: "%.2f Mbps", Double(bandwidth) / 1_000_000)
        }
        guard bandwidth > 0 else { return "" }
        return "\(Int((Double(bandwidth) / 1000).rounded())) kbps"
    }

    var describe: String {
        var parts = [codec]
        let bitrate = bitrateDescription
        if !bitrate.isEmpty {
            parts.append(bitrate)
        }
        if let sampleRate {
            parts.append(String(format: "%.1f kHz", Double(sampleRate) / 1000))
        }
        return parts.joined(separator: " · ")
    }
}
