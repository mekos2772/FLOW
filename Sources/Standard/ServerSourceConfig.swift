import Foundation

/// 标准网络媒体服务器配置（OpenSubsonic / Navidrome / WebDAV），不含明文密码。
struct ServerSourceConfig: Codable, Equatable, Identifiable, Sendable {
    enum ProtocolKind: String, Codable, CaseIterable, Sendable {
        case openSubsonic
        case webDAV

        var displayName: String {
            switch self {
            case .openSubsonic: return "OpenSubsonic / Navidrome"
            case .webDAV: return "WebDAV"
            }
        }
    }

    let id: String
    var kind: ProtocolKind
    var displayName: String
    var baseURLString: String
    var username: String

    var sourceID: SourceID {
        SourceID(rawValue: "server-\(kind.rawValue)-\(id)")
    }

    var passwordAccountKey: String {
        "server.\(id).password"
    }

    var baseURL: URL? {
        Self.normalizedBaseURL(from: baseURLString)
    }

    var allowedDomains: [String] {
        guard let host = baseURL?.host?.lowercased(), !host.isEmpty else { return [] }
        return [host]
    }

    static func normalizedBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        while components.path.hasSuffix("/") && components.path.count > 1 {
            components.path.removeLast()
        }
        if components.path == "/" { components.path = "" }
        return components.url
    }
}

/// 持久化管理标准媒体服务器列表（密码单独存放于 `SecretStoring`）。
final class ServerSourceConfigStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let key = "sources.standardServers"
    private let lock = NSLock()

    init(defaults: UserDefaults = RuntimeSandbox.defaults,
         secrets: any SecretStoring = DefaultSecretStore.shared) {
        self.defaults = defaults
        self.secrets = secrets
    }

    func loadAll() -> [ServerSourceConfig] {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([ServerSourceConfig].self, from: data) else {
                return []
            }
            return decoded
        }
    }

    func upsert(_ config: ServerSourceConfig, password: String?) throws {
        if let password {
            try secrets.save(password, account: config.passwordAccountKey)
        }
        try lock.withLock {
            var current = loadAllUnlocked()
            if let index = current.firstIndex(where: { $0.id == config.id }) {
                current[index] = config
            } else {
                current.append(config)
            }
            try saveUnlocked(current)
        }
    }

    func remove(sourceID: SourceID) {
        lock.withLock {
            var current = loadAllUnlocked()
            let removed = current.filter { $0.sourceID == sourceID }
            current.removeAll { $0.sourceID == sourceID }
            for item in removed {
                secrets.remove(account: item.passwordAccountKey)
            }
            try? saveUnlocked(current)
        }
    }

    func password(for config: ServerSourceConfig) -> String {
        secrets.load(account: config.passwordAccountKey) ?? ""
    }

    private func loadAllUnlocked() -> [ServerSourceConfig] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerSourceConfig].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveUnlocked(_ configs: [ServerSourceConfig]) throws {
        let data = try JSONEncoder().encode(configs)
        defaults.set(data, forKey: key)
    }
}
