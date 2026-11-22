import Foundation

/// 源注册表。依赖容器持有它，播放内核按 `SourceID` 取源，从不 import 具体实现。
final class SourceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [SourceID: any PlaybackSourceProvider] = [:]
    private var registrationOrder: [SourceID] = []

    init() {}

    func register(_ provider: any PlaybackSourceProvider) {
        lock.lock()
        defer { lock.unlock() }
        if providers[provider.descriptor.id] == nil {
            registrationOrder.append(provider.descriptor.id)
        }
        providers[provider.descriptor.id] = provider
    }

    func unregister(_ id: SourceID) {
        lock.lock()
        defer { lock.unlock() }
        providers[id] = nil
        registrationOrder.removeAll { $0 == id }
    }

    func provider(for id: SourceID) -> (any PlaybackSourceProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    var descriptors: [SourceDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return registrationOrder.compactMap { providers[$0]?.descriptor }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers.isEmpty
    }
}
