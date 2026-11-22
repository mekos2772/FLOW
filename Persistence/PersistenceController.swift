import Foundation
import SQLite3
import SwiftData

/// 持久化入口。全工程只有这里创建 `ModelContainer`。
@MainActor
final class PersistenceController {
    let container: ModelContainer
    let isInMemory: Bool
    private let activeStoreURL: URL?
    /// 这次启动是否因为数据库损坏而重建过。页面与诊断需要如实告知用户。
    private(set) var recoveredFromCorruption: Bool
    /// 被隔离的损坏库文件名（在应用支持目录下），nil 表示没有发生隔离。
    private(set) var quarantinedFileName: String?
    /// 这次启动是否从**备份**恢复过数据。诊断页要如实告知。
    private(set) var restoredFromBackup = false

    /// 保留几份滚动备份。
    static let backupLimit = 3
    /// 备份目录名（在库文件旁边）。
    static let backupDirectoryName = "Backups"

    /// 当前 schema 版本，供设置页展示与诊断。
    static var currentSchemaVersion: String { "3.0.0" }

    /// 存储位置。
    ///
    /// 不用 SwiftData 的默认 `default.store`：那个名字是全局共享的，
    /// 两个没做好配置的 App 会互相踩同一份数据库。这里固定到应用自己的子目录。
    static func storeURL() throws -> URL {
        let directory: URL
        if let sandbox = RuntimeSandbox.dataDirectory {
            // 验收/截图用的隔离目录：绝不碰使用者真实的曲目库。
            directory = sandbox
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = base.appendingPathComponent("SpatialLyricsPlayer", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SpatialLyrics.store")
    }

    convenience init(inMemory: Bool) throws { try self.init(inMemory: inMemory, storeURL: nil) }

    /// - Parameter storeURL: 显式指定库路径（测试注入）。nil 时用应用私有目录。
    init(inMemory: Bool, storeURL: URL?) throws {
        let schema = Schema(versionedSchema: SpatialLyricsSchemaV3.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                "SpatialLyrics",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true
            )
        } else {
            // **必须**用注入的路径。之前这里写死 `Self.storeURL()`，
            // 于是测试传进来的临时路径被忽略——整个测试套件一直在往使用者的
            // 真实数据库里写（这正是早先"收藏被清空"的真正来源）。
            configuration = ModelConfiguration(
                "SpatialLyrics",
                schema: schema,
                url: try storeURL ?? Self.storeURL(),
                allowsSave: true
            )
        }
        // 实际使用的库路径。**所有**检查都认它——之前文件头检查绑的是 `storeURL` 这个参数，
        // 而正式运行时参数是 nil（路径走默认值），于是那段检查只在测试里跑过。
        let resolvedURL: URL? = inMemory ? nil : (try storeURL ?? Self.storeURL())
        // 主库不存在（首次启动，或刚被隔离走）时，清掉可能残留的侧车文件，
        // 免得新库把旧 WAL 的帧重放进去。
        if let url = resolvedURL {
            Self.removeOrphanSidecars(for: url)
        }
        var preRestored: (container: ModelContainer, restored: Bool)?
        // 打开前先做文件头检查：SwiftData/SQLite 打开后不一定立刻报错，
        // 等真正读写才炸，那时更难判断。这里先确定性地识别明显损坏。
        if let url = resolvedURL, Self.isCorruptedFile(at: url) {
            self.quarantinedFileName = try Self.quarantineStore(at: url)?.lastPathComponent
            self.recoveredFromCorruption = true
            // 隔离之后从新→旧逐份尝试并实测打开备份：避免最新备份同坏时直接抹成空库。
            if let hit = Self.restoreFirstHealthyBackupContainer(at: url, schema: schema) {
                self.restoredFromBackup = true
                preRestored = (hit, true)
            } else {
                self.restoredFromBackup = false
            }
            RedactingLog.error("store header invalid, quarantined before open")
        } else {
            self.quarantinedFileName = nil
            self.recoveredFromCorruption = false
        }

        do {
            self.container = try preRestored?.container ?? ModelContainer(
                for: schema,
                migrationPlan: SpatialLyricsMigrationPlan.self,
                configurations: configuration
            )
            self.isInMemory = inMemory
            self.activeStoreURL = resolvedURL
            if let url = resolvedURL {
                Self.writeBackupIfChanged(of: url)
                // 健康启动时也清一次旧的隔离文件：否则历史遗留要等"下次再损坏"才被处理，
                // 而那种时候用户已经在处理别的问题了。
                Self.pruneQuarantinedFiles(near: url)
            }
        } catch {
            guard let url = resolvedURL else { throw error }

            guard Self.isStructurallyDamaged(at: url) else {
                RedactingLog.error("store open failed but the file is intact; left untouched")
                throw error
            }

            // 真的坏了：不能直接删库，先整组隔离，让用户还有机会人工抢救。
            let quarantined = try Self.quarantineStore(at: url)

            // 隔离之后**逐份试备份**（新→旧）：直接建空库等于把用户收藏清零
            // （这个工程真的发生过两次，收藏全丢）。某一份打不开就换下一份。
            let opened = Self.restoreFirstHealthyBackupContainer(at: url, schema: schema)
            let restored = (opened != nil)

            self.container = try opened ?? ModelContainer(
                for: schema,
                migrationPlan: SpatialLyricsMigrationPlan.self,
                configurations: ModelConfiguration("SpatialLyrics", schema: schema, url: url, allowsSave: true)
            )
            self.isInMemory = false
            self.activeStoreURL = url
            self.recoveredFromCorruption = true
            self.restoredFromBackup = restored
            self.quarantinedFileName = quarantined?.lastPathComponent
            RedactingLog.error("store open failed, quarantined to \(quarantined?.lastPathComponent ?? "?")")
        }
    }

    /// 库文件**本身**是否损坏（而不是"这个版本的模型读不了它"）。
    ///
    /// 用 SQLite 自己的 `quick_check` 判断：能打开、体检结果是 `ok` 就是健康的。
    /// 只有明确的"不是数据库 / 页结构损坏"才算坏；权限、占用之类打不开的情况一律按
    /// **没坏**处理——判断不了的时候，宁可让应用降级运行，也不去动用户的数据。
    static func isStructurallyDamaged(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if isCorruptedFile(at: url) { return true }

        var handle: OpaquePointer?
        // 只读打开：这是体检，不能顺手改动用户的库（读写连接关闭时会把 WAL 并回主文件）。
        let openResult = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        guard openResult == SQLITE_OK, let handle else {
            return openResult == SQLITE_NOTADB || openResult == SQLITE_CORRUPT
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check(1);", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            let code = sqlite3_errcode(handle)
            return code == SQLITE_NOTADB || code == SQLITE_CORRUPT
        }
        return String(cString: text) != "ok"
    }

    /// 删掉库路径上的主文件与侧车（只用于撤掉"刚拷回来却打不开"的那份备份副本）。
    private static func removeStoreFiles(at url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// SQLite 文件必须以 `SQLite format 3\0` 开头。空文件视为新库，不算损坏。
    static func isCorruptedFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        if header.isEmpty { return false }
        return header != Data("SQLite format 3\0".utf8)
    }

    /// 隔离文件最多保留几组。用得越久、损坏次数越多，`-corrupt-` 文件会一直堆着。
    static let quarantineLimit = 3

    /// 清理旧的隔离文件，只留最近 `quarantineLimit` 组。
    static func pruneQuarantinedFiles(near storeURL: URL) {
        let manager = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let stamps = Set(names.compactMap { name -> Int? in
            guard let range = name.range(of: "-corrupt-") else { return nil }
            let digits = name[range.upperBound...].prefix(while: { $0.isNumber })
            return Int(digits)
        }).sorted(by: >)
        guard stamps.count > quarantineLimit else { return }
        let stale = stamps.dropFirst(quarantineLimit)
        let prefix = storeURL.deletingPathExtension().lastPathComponent
        for stamp in stale {
            for suffix in [".store", ".store-wal", ".store-shm"] {
                let path = directory.appendingPathComponent("\(prefix)-corrupt-\(stamp)\(suffix)")
                try? manager.removeItem(at: path)
            }
        }
    }

    /// 把损坏的库连同 -wal/-shm 一起改名保存，返回主文件名。
    /// SwiftData(SQLite) 的三个文件必须一起挪走，否则新建的库会读到旧的 WAL。
    private static func quarantineStore(at url: URL) throws -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-corrupt-\(stamp).store")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.moveItem(at: url, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.moveItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
            }
        }
        // 侧车移动是 `try?`：万一失败，旧 WAL 会留在原主库旁边。
        removeOrphanSidecars(for: url)
        pruneQuarantinedFiles(near: url)
        return destination
    }

    /// 清掉主库不存在时残留的 `-wal` / `-shm`。
    ///
    /// SQLite 打开一个**新建**的空库时，如果旁边有旧的 `-wal`，会把里面的帧重放进去——
    /// 等于让"已被隔离的坏数据"通过侧车文件回到新库里。
    /// 隔离时侧车是 `try?` 移动的，移动失败就可能留下这种孤儿。
    static func removeOrphanSidecars(for storeURL: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: storeURL.path) else { return }
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    /// 立刻对**当前使用中的库**写一份快照。
    ///
    /// 打开瞬间库文件可能还没创建，所以真正的可靠时机是"保存之后"——
    /// 退出、失活、以及诊断页手动触发都会调这里。
    func backUpStoreNow() {
        guard !isInMemory, let url = activeStoreURL else { return }
        Self.writeBackupIfChanged(of: url)
    }

    /// 只在库**相对上一份备份有变化**时才写新备份。
    ///
    /// 备份只留 `backupLimit`（3）份，而每次运行会在打开和退出时各写一次。
    /// 不去重的话，打开-退出两轮之后三份备份全是同一天、几乎同一刻的内容——
    /// 没有任何时间纵深，前一天的状态已经被挤掉。内容没变就不占名额。
    static func writeBackupIfChanged(of storeURL: URL, at date: Date = Date()) {
        if let latest = latestBackup(for: storeURL), isSameContent(storeURL, latest) { return }
        writeBackup(of: storeURL, at: date)
    }

    /// 主文件与 `-wal` 都逐字节相同才算同一份内容。
    private static func isSameContent(_ store: URL, _ backup: URL) -> Bool {
        let manager = FileManager.default
        guard manager.contentsEqual(atPath: store.path, andPath: backup.path) else { return false }
        let storeWAL = store.path + "-wal"
        let backupWAL = backup.path + "-wal"
        let hasStoreWAL = (try? manager.attributesOfItem(atPath: storeWAL)[.size] as? Int).map { $0 > 0 } ?? false
        let hasBackupWAL = (try? manager.attributesOfItem(atPath: backupWAL)[.size] as? Int).map { $0 > 0 } ?? false
        if !hasStoreWAL && !hasBackupWAL { return true }
        guard hasStoreWAL == hasBackupWAL else { return false }
        return manager.contentsEqual(atPath: storeWAL, andPath: backupWAL)
    }

    private static var defaultStoreURL: URL {
        (try? storeURL()) ?? URL(fileURLWithPath: "/dev/null")
    }

    // MARK: - 滚动备份

    /// 备份目录：与库文件同级，避免和"损坏隔离"混在一起。
    static func backupDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    /// 成功打开后写一份快照，并只保留最近 `backupLimit` 份。
    ///
    /// 为什么在"打开成功"时写：只有这时才能确认文件是健康的。
    /// 写失败一律忽略——备份是保险，不该让启动失败。
    static func writeBackup(of storeURL: URL, at date: Date = Date()) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: storeURL.path) else { return }
        let directory = backupDirectory(for: storeURL)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Int(date.timeIntervalSince1970)
        let name = "\(storeURL.deletingPathExtension().lastPathComponent)-\(stamp).store"
        let target = directory.appendingPathComponent(name)
        guard !manager.fileExists(atPath: target.path) else { return }

        // 先拷到临时名再改名：中途崩溃不会留下半个"看起来完整"的备份。
        let temporary = directory.appendingPathComponent(name + ".partial")
        try? manager.removeItem(at: temporary)
        do {
            try manager.copyItem(at: storeURL, to: temporary)
            // 侧车文件也要跟着改名：只把 `-wal` 拷成 `.partial-wal` 而不改名，
            // 备份打开时会缺掉未 checkpoint 的数据（实测：备份里查不到刚写进去的行）。
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: storeURL.path + suffix)
                guard manager.fileExists(atPath: sidecar.path) else { continue }
                try manager.copyItem(at: sidecar,
                                     to: URL(fileURLWithPath: temporary.path + suffix))
            }
            try manager.moveItem(at: temporary, to: target)
            for suffix in ["-wal", "-shm"] {
                let from = URL(fileURLWithPath: temporary.path + suffix)
                guard manager.fileExists(atPath: from.path) else { continue }
                try manager.moveItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        } catch {
            // 失败可能发生在两个阶段：
            // a) 还在 `.partial`（主库没换成正式名）——删掉临时文件就够；
            // b) 主库已经改名成正式名、但侧车改名失败——这时目录里会留下一份
            //    "看着完整、其实少了 WAL" 的备份。它会被 `latestBackup` 当成最新，
            //    恢复时静默丢掉最近写入（正是这条注释上面警告过的现象）。
            // 所以两个名字都要清：宁可没有这份备份，也不要留一份缺数据的。
            try? manager.removeItem(at: temporary)
            try? manager.removeItem(at: target)
            for suffix in ["-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: target.path + suffix))
                try? manager.removeItem(at: URL(fileURLWithPath: temporary.path + suffix))
            }
            return
        }
        pruneBackups(for: storeURL)
    }

    /// 逐份从新到旧尝试恢复备份并用 `ModelContainer` 验证打开，成功返回可用容器；全数不可用返回 nil。
    private static func restoreFirstHealthyBackupContainer(at url: URL, schema: Schema) -> ModelContainer? {
        for backup in backups(for: url) {
            guard restore(backup: backup, to: url) else { continue }
            if let container = try? ModelContainer(
                for: schema,
                migrationPlan: SpatialLyricsMigrationPlan.self,
                configurations: ModelConfiguration("SpatialLyrics", schema: schema, url: url, allowsSave: true)
            ) {
                RedactingLog.error("store restored from backup \(backup.lastPathComponent)")
                return container
            }
            removeStoreFiles(at: url)
        }
        return nil
    }

    /// 用最新备份恢复库文件；成功返回 true。
    @discardableResult
    static func restoreFromLatestBackup(at storeURL: URL) -> Bool {
        guard let backup = latestBackup(for: storeURL) else { return false }
        guard restore(backup: backup, to: storeURL) else { return false }
        RedactingLog.error("store restored from backup \(backup.lastPathComponent)")
        return true
    }

    /// 现有的备份（按时间从新到旧）。
    static func backups(for storeURL: URL) -> [URL] {
        let directory = backupDirectory(for: storeURL)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".store") }
            .compactMap { name -> (URL, Int)? in
                let url = directory.appendingPathComponent(name)
                // 文件名里的时间戳排序，比依赖文件系统时间可靠。
                // 形如 `SpatialLyrics-1794745597.store`：先去掉扩展名，再取最后一段。
                let stem = name.replacingOccurrences(of: ".store", with: "")
                guard let digits = stem.split(separator: "-").last, Int(digits) != nil else { return nil }
                return (url, Int(digits)!)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func latestBackup(for storeURL: URL) -> URL? {
        backups(for: storeURL).first
    }

    private static func pruneBackups(for storeURL: URL) {
        let all = backups(for: storeURL)
        guard all.count > backupLimit else { return }
        for url in all.dropFirst(backupLimit) {
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
    }

    /// 把备份拷回库路径。失败返回 false，调用方继续走"建空库"。
    @discardableResult
    static func restore(backup: URL, to storeURL: URL) -> Bool {
        let manager = FileManager.default
        // 目标位置此刻应当已经被隔离走了；若还在，说明状态异常，放弃恢复。
        guard !manager.fileExists(atPath: storeURL.path) else { return false }
        do {
            // 先清掉目标位置可能残留的侧车文件。
            // 场景：上次隔离中途被打断，主库被移走但 `-wal` 留下；
            // 而这份备份本身没有侧车（当时正是 checkpoint 过的干净状态）。
            // 不清的话，SQLite 打开恢复后的主库时会把**旧 WAL** 重放上去 —— 数据错乱。
            for suffix in ["-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            try manager.copyItem(at: backup, to: storeURL)
            // 侧车拷贝失败**必须计入失败**而不是 `try?`：
            // 备份的 `-wal` 里有未 checkpoint 的最近事务，缺了它恢复出的库会
            // 静默丢那段数据——"主文件新、缺 WAL"的半恢复态比"这份备份没成"更难查。
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: backup.path + suffix)
                if manager.fileExists(atPath: source.path) {
                    try manager.copyItem(at: source, to: URL(fileURLWithPath: storeURL.path + suffix))
                }
            }
            return true
        } catch {
            // 主文件或侧车任一拷贝失败：不留半成品，让调用方走下一份备份。
            try? manager.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            return false
        }
    }

    func makeTrackRepository() -> any TrackRepository {

        SwiftDataTrackRepository(modelContainer: container)
    }
}
