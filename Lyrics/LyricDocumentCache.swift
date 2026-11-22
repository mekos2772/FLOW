import Foundation

/// 外部歌词的磁盘缓存（源无关）。
///
/// 文件按「曲目缓存键 + 歌名」分文件名保存，并约束总字节长度防止 APFS 255 字节写盘失败。
struct LyricDocumentCache: Sendable {
    static let shared = LyricDocumentCache()

    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? RuntimeSandbox.cachesDirectory()
            .appendingPathComponent("FLOW/Lyrics", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func url(identity: String, title: String) -> URL {
        let name = "\(Self.safeComponent(identity))_\(Self.safeComponent(title)).lrc"
        return directory.appendingPathComponent(name)
    }

    static func safeComponent(_ raw: String, maxBytes: Int = 80) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "#", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "untitled" }
        guard cleaned.utf8.count > maxBytes else { return cleaned }

        var truncated = ""
        var used = 0
        for character in cleaned {
            let size = String(character).utf8.count
            if used + size > maxBytes - 9 { break }
            truncated.append(character)
            used += size
        }
        let digest = Self.shortDigest(cleaned)
        return truncated + "-" + digest
    }

    private static func shortDigest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(hex.prefix(8)).padding(toLength: 8, withPad: "0", startingAt: 0)
    }

    func load(identity: String, title: String) -> String? {
        try? String(contentsOf: url(identity: identity, title: title), encoding: .utf8)
    }

    func loadAny(identity: String) -> String? {
        let matched = matchingFiles(identity: identity)
            .max { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate < rDate
            }
        guard let matched else { return nil }
        return try? String(contentsOf: matched, encoding: .utf8)
    }

    func remove(identity: String) {
        for file in matchingFiles(identity: identity) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func matchingFiles(identity: String) -> [URL] {
        let prefix = Self.safeComponent(identity) + "_"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "lrc" }
    }

    func store(identity: String, title: String, lrc: String) {
        try? lrc.write(to: url(identity: identity, title: title), atomically: true, encoding: .utf8)
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func count() -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil)) ?? []).count
    }
}
