import Foundation
import Security

/// 通用敏感凭据存储契约（密码、Token、插件私有会话凭据仅允许存放在此类存储器中，禁止进入 `UserDefaults` 与日志）。
protocol SecretStoring: AnyObject, Sendable {
    func load(account: String) -> String?
    func save(_ secret: String, account: String) throws
    func remove(account: String)
}

/// 系统 Keychain 存储实现。
final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String

    init(service: String = "com.yg.spatiallyrics.sources") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { return }
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func remove(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// 内存隔离实现（用于测试与 `RuntimeSandbox` 环境）。
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func load(account: String) -> String? {
        lock.withLock { values[account] }
    }

    func save(_ secret: String, account: String) throws {
        lock.withLock { values[account] = secret }
    }

    func remove(account: String) {
        lock.withLock { _ = values.removeValue(forKey: account) }
    }
}

/// 运行期默认密钥仓库：沙盒测试模式自动隔离到内存，生产环境走系统 Keychain。
enum DefaultSecretStore {
    static let shared: any SecretStoring = RuntimeSandbox.isActive
        ? InMemorySecretStore()
        : KeychainSecretStore()
}
