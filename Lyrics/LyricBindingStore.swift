import CryptoKit
import Foundation
import Observation

/// 持久化歌词绑定格式。保留原文格式避免丢失 AMLL 逐字时间轴、双语译文或罗马音。
enum LyricPayloadFormat: String, Codable, Sendable {
    case lrc
    case ttml
}

/// 按 `TrackIdentity` 持久化的手动绑定歌词记录。
struct BoundLyricRecord: Codable, Equatable, Sendable {
    let version: Int
    let identity: TrackIdentity
    var sourceIdentifier: String? = nil
    let providerName: String
    let trackName: String
    let artistName: String
    let albumName: String
    let format: LyricPayloadFormat
    let payload: String
    let boundAt: Date

    var describe: String {
        [trackName, artistName, albumName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 手动歌词绑定仓库：按 `(sourceID, externalID)` 永久记住用户挑选的版本，优先级高于一切自动匹配与缓存。
@MainActor
@Observable
final class LyricBindingStore {
    private(set) var revision: Int = 0

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var records: [TrackIdentity: BoundLyricRecord] = [:]

    /// 传入 `nil` 目录时仅存内存，供单测与预览环境隔离使用。
    init(directory: URL? = nil) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            loadFromDisk(directory)
        }
    }

    func binding(for identity: TrackIdentity) -> BoundLyricRecord? {
        records[identity]
    }

    func save(_ record: BoundLyricRecord) {
        records[record.identity] = record
        persist(record)
        revision &+= 1
    }

    func remove(for identity: TrackIdentity) {
        guard records.removeValue(forKey: identity) != nil else { return }
        if let file = fileURL(for: identity) {
            try? FileManager.default.removeItem(at: file)
        }
        revision &+= 1
    }

    /// 将持久化记录还原为可直接播放展示的简体/保留假名歌词文档。
    func document(for track: Track) -> LyricsDocument? {
        guard let record = records[track.identity] else { return nil }
        return Self.parseDocument(from: record, trackIdentity: track.identity)
    }

    static func parseDocument(from record: BoundLyricRecord, trackIdentity: TrackIdentity) -> LyricsDocument? {
        switch record.format {
        case .ttml:
            let lines = AMLLTTMLParser.parse(record.payload)
            guard !lines.isEmpty else { return nil }
            return TextNormalizer.simplified(document: LyricsDocument(
                trackIdentity: trackIdentity,
                lines: lines,
                source: .external,
                synchronization: .synced
            ))
        case .lrc:
            guard let parsed = LRCParser.parse(record.payload), !parsed.lines.isEmpty else { return nil }
            return TextNormalizer.simplified(document: LyricsDocument(
                trackIdentity: trackIdentity,
                lines: parsed.lines,
                metadata: parsed.metadata,
                source: .external,
                synchronization: parsed.synchronization
            ))
        }
    }

    // MARK: - 磁盘读写

    private func fileURL(for identity: TrackIdentity) -> URL? {
        guard let directory else { return nil }
        let key = TrackIdentity.storageKey(identity)
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        return directory.appendingPathComponent("\(digest).json")
    }

    private func persist(_ record: BoundLyricRecord) {
        guard let file = fileURL(for: record.identity) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func loadFromDisk(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(BoundLyricRecord.self, from: data),
                  record.version == 1,
                  !record.payload.isEmpty else { continue }
            records[record.identity] = record
        }
    }
}
