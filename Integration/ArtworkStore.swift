import AppKit
import CryptoKit
import Foundation

/// 封面落盘与内存缓存。
///
/// 只存引用（文件名）在 Track 上，图片本身放 Application Support/Artwork，
/// 避免把二进制塞进数据库；内存侧用 NSCache 限制数量，防止长播放把内存吃满。
@MainActor
final class ArtworkStore {
    static let shared = ArtworkStore()

    private let cache = NSCache<NSString, NSImage>()
    private let directory: URL?

    /// 生产环境用 Application Support 下的共享目录。
    ///
    /// 测试必须显式传一个临时目录：`clear()` 会删掉目录里**所有**文件，
    /// 而单测调 `clear()` 原本删的是用户真实缓存（跑一次测试就清空一次封面）。
    init(directory override: URL? = nil) {
        cache.countLimit = 32
        directory = override ?? Self.makeDirectory()
    }

    private static func makeDirectory() -> URL? {
        // 隔离运行时落在隔离目录里（见 `RuntimeSandbox`）。
        let dir: URL
        if let sandbox = RuntimeSandbox.dataDirectory {
            dir = sandbox.appendingPathComponent("Artwork", isDirectory: true)
        } else {
            guard let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ) else { return nil }
            dir = base.appendingPathComponent("SpatialLyricsPlayer/Artwork", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 写入图片并按内容哈希命名，返回可用于 `Track.artworkReference` 的文件名。
    @discardableResult
    func store(_ data: Data) -> String? {
        guard let directory, !data.isEmpty else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32)
        let name = "artwork-\(hash).img"
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            trimIfNeeded()
        }
        return name
    }

    /// 磁盘上限（按内容哈希命名，同一张封面只会存一份）。
    ///
    /// 内存侧有 `countLimit = 32`，磁盘侧原本**没有任何上限**：搜过的每首歌的封面都会
    /// 永久留在 Application Support 里。单张封面不大（几十 KB），所以这里设一个
    /// **最后手段**的阈值——正常使用永远碰不到；真碰到时按最久未用淘汰，
    /// 被淘汰的封面在界面上会退回占位图（数据不会丢，只是要重新取）。
    static let maxDiskBytes = 512 * 1024 * 1024

    /// 测试用入口：把上限压小以便触发淘汰。
    func performTrimForTesting(maxBytes: Int) { trimIfNeeded(maxBytes: maxBytes) }

    private func trimIfNeeded(maxBytes: Int = ArtworkStore.maxDiskBytes) {
        guard let directory else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        var entries: [(url: URL, size: Int, used: Date)] = []
        var total = 0
        for name in names where name.hasSuffix(".img") {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int else { continue }
            let used = (attributes[.modificationDate] as? Date) ?? .distantPast
            entries.append((url, size, used))
            total += size
        }
        guard total > maxBytes else { return }

        let target = Int(Double(maxBytes) * 0.8)
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > target else { break }
            if (try? manager.removeItem(at: entry.url)) != nil {
                cache.removeObject(forKey: entry.url.lastPathComponent as NSString)
                total -= entry.size
            }
        }
    }

    /// 按 `ArtworkReference` 解析封面。
    /// `.embedded` 直接用内存数据；`.file` 读磁盘；`.opaque` 当作本 store 的文件名；
    /// `.remote` 一律返回 nil——没接网络就绝不偷偷下载。
    func image(for reference: ArtworkReference?) -> NSImage? {
        guard let media = reference?.media else { return nil }
        switch media {
        case let .embedded(data):
            guard let image = NSImage(data: data) else { return nil }
            return image
        case let .file(url):
            return NSImage(contentsOf: url)
        case let .opaque(name):
            return image(named: name)
        case .remote:
            // 远程引用本身不含数据；真正下载回来的图由 `store(_:for:)` 按身份落盘，
            // 调用方应先查 `image(forIdentity:)`。这里仍然不发起任何网络请求。
            return nil
        }
    }

    // MARK: - 按曲目身份缓存（远程封面）

    /// 远程封面下载完成后落盘的命名前缀。
    private static let identityPrefix = "artwork-id-"

    /// 封面按**曲目身份**命名的文件名。同一首曲子不论标题/时长怎么变都命中同一张图。
    private func identityFileName(_ identity: TrackIdentity) -> String {
        let raw = "\(identity.sourceID.rawValue)|\(identity.externalID)"
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return "\(Self.identityPrefix)\(hash).img"
    }

    /// 把远程下载回来的封面按曲目身份落盘。
    ///
    /// 之前远程封面只进了 `SystemMediaIntegration` 自己的一张内存字典（喂给控制中心），
    /// **从不回写这里**，而界面只读这里，于是"控制中心有图、播放器里永远是灰音符"。
    @discardableResult
    func store(_ data: Data, for identity: TrackIdentity) -> String? {
        guard let directory, !data.isEmpty else { return nil }
        let name = identityFileName(identity)
        let url = directory.appendingPathComponent(name)
        // 已经有一份**能解开**的图就不重写；写了一半/解不开的旧文件要能被替换掉
        // （之前是"存在就跳过"，一次写坏之后这首歌永远是灰音符）。
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed, NSImage(contentsOf: url) != nil { return name }
        // 不是图片的数据不落盘（错误页、被截断的响应）。
        guard NSImage(data: data) != nil else { return nil }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        // 这条路径是界面实际在用的：以前只有另一条没人调用的 `store(_:)` 会做容量控制。
        trimIfNeeded()
        // 先写盘再清缓存：同一首曲子换了封面时不要读到旧的那张。
        cache.removeObject(forKey: name as NSString)
        // 带上 `object: self`：观察者可以据此过滤。
        // 之前传 nil，测试里的观察者会听见**全进程**所有 store 的通知（互相串），
        // 生产端用 `object: nil` 订阅的代码不受影响。
        NotificationCenter.default.post(name: ArtworkStore.didStoreNotification,
                                        object: self,
                                        userInfo: [ArtworkStore.identityKey: identity])
        return name
    }

    /// 按曲目身份取封面（远程封面在界面上的唯一入口）。
    func image(forIdentity identity: TrackIdentity) -> NSImage? {
        image(named: identityFileName(identity))
    }

    /// 离线读取已落盘封面的原始字节（用于控制中心与系统媒体投影）。
    func data(forIdentity identity: TrackIdentity) -> Data? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(identityFileName(identity))
        return try? Data(contentsOf: url)
    }

    /// 封面写好之后的通知名与 userInfo 键。
    ///
    /// 必须 `nonisolated`：观察者在 `NotificationCenter` 的 `@Sendable` 回调里读它们，
    /// 而 `ArtworkStore` 是 `@MainActor`，静态常量默认也带上主线程隔离。
    nonisolated static let didStoreNotification = Notification.Name("FlowArtworkStoreDidStore")
    nonisolated static let identityKey = "identity"

    func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    func clear() {
        cache.removeAllObjects()
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
