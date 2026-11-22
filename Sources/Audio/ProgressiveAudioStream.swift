import AVFoundation
import Foundation

/// 已接入流式代理的 `AVURLAsset` 包装与清理句柄。
struct StreamingPreparedAsset: @unchecked Sendable {
    let asset: AVURLAsset
    let invalidate: @Sendable () -> Void
    /// 由宿主会话强持有，`AVAssetResourceLoader` 仅弱引用 delegate。
    let keepAlive: AnyObject
}

typealias StreamingAssetBuilder = @Sendable (ProgressiveAudioStream) -> StreamingPreparedAsset

/// 有序合并的字节区间集合，记录流式缓存中已落盘可读的偏移片段。
struct ByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    mutating func insert(_ newRange: Range<Int64>) {
        guard !newRange.isEmpty else { return }
        var start = newRange.lowerBound
        var end = newRange.upperBound
        var updated: [Range<Int64>] = []
        updated.reserveCapacity(ranges.count + 1)

        var inserted = false
        for current in ranges {
            if current.upperBound < start {
                updated.append(current)
            } else if current.lowerBound > end {
                if !inserted {
                    updated.append(start..<end)
                    inserted = true
                }
                updated.append(current)
            } else {
                start = min(start, current.lowerBound)
                end = max(end, current.upperBound)
            }
        }
        if !inserted {
            updated.append(start..<end)
        }
        ranges = updated
    }

    /// 从 `offset` 起连续可用的字节长度；尚未落盘则返回 `0`。
    func availableLength(from offset: Int64) -> Int64 {
        guard offset >= 0 else { return 0 }
        for range in ranges where range.contains(offset) {
            return range.upperBound - offset
        }
        return 0
    }

    /// 从 `offset` 起第一段尚未下载的字节区间（裁切至 `maxLength` 与 `totalLength`）。
    func nextMissingRange(from offset: Int64, maxLength: Int64, totalLength: Int64) -> Range<Int64>? {
        guard offset >= 0, offset < totalLength, maxLength > 0 else { return nil }
        var cursor = offset
        for range in ranges {
            if range.upperBound <= cursor { continue }
            if range.lowerBound > cursor {
                let end = min(range.lowerBound, min(totalLength, cursor + maxLength))
                return cursor < end ? (cursor..<end) : nil
            }
            cursor = range.upperBound
            if cursor >= totalLength { return nil }
        }
        let end = min(totalLength, cursor + maxLength)
        return cursor < end ? (cursor..<end) : nil
    }

    func isComplete(totalLength: Int64) -> Bool {
        totalLength > 0 && ranges == [0..<totalLength]
    }
}

/// B 站流式音频下载与边下边播引擎：先取首片验证响应并立刻供播放器起播，
/// 后台按 Range 续传到 `.part` 临时文件，全部完成后原子落盘为完整 `.m4a` 缓存。
final class ProgressiveAudioStream: @unchecked Sendable {
    enum OpenOutcome: Sendable {
        case localFile(URL)
        case streaming(ProgressiveAudioStream)
    }

    struct FileIO: Sendable {
        var seek: @Sendable (FileHandle, UInt64) throws -> Void = { try $0.seek(toOffset: $1) }
        var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
        var synchronize: @Sendable (FileHandle) throws -> Void = { try $0.synchronize() }
        var close: @Sendable (FileHandle) throws -> Void = { try $0.close() }
        var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    }

    static let defaultInitialChunkBytes = 256 * 1024
    static let defaultChunkBytes = 512 * 1024

    let remoteURL: URL
    let backupURLs: [URL]
    var destinationURL: URL { lock.withLock { _destinationURL } }
    let partURL: URL
    private(set) var totalLength: Int64 = 0

    private let session: URLSession
    private let headers: [String: String]
    private let allowedDomains: [String]
    private let networkAllowed: @Sendable () -> Bool
    private let initialChunkBytes: Int
    private let chunkBytes: Int
    private let minimumUsefulBytes: Int
    private let fileIO: FileIO
    private let onComplete: (@Sendable (URL) -> Void)?
    private let onAbandon: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var _destinationURL: URL
    private var ranges = ByteRangeSet()
    private var writeHandle: FileHandle?
    private var completedURL: URL?
    private var terminalError: Error?
    private var consumerCount = 0
    private var isCancelled = false
    private var inFlightRanges: [UUID: Range<Int64>] = [:]
    private var sequentialTask: Task<Void, Never>?
    private var demandTasks: [UUID: Task<Void, Never>] = [:]
    private var dataListeners: [UUID: @Sendable () -> Void] = [:]
    private var completionWaiters: [UUID: CheckedContinuation<URL?, Never>] = [:]

    init(remoteURL: URL,
         backupURLs: [URL] = [],
         destinationURL: URL,
         session: URLSession = .shared,
         headers: [String: String],
         allowedDomains: [String] = [],
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         initialChunkBytes: Int = ProgressiveAudioStream.defaultInitialChunkBytes,
         chunkBytes: Int = ProgressiveAudioStream.defaultChunkBytes,
         minimumUsefulBytes: Int = MediaAudioCache.minimumUsefulBytes,
         fileIO: FileIO = FileIO(),
         onComplete: (@Sendable (URL) -> Void)? = nil,
         onAbandon: (@Sendable () -> Void)? = nil) {
        self.remoteURL = remoteURL
        self.backupURLs = backupURLs
        self._destinationURL = destinationURL
        let parent = destinationURL.deletingLastPathComponent()
        self.partURL = parent.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).part")
        self.session = session
        self.headers = headers
        self.allowedDomains = allowedDomains
        self.networkAllowed = networkAllowed
        self.initialChunkBytes = max(1024, initialChunkBytes)
        self.chunkBytes = max(1024, chunkBytes)
        self.minimumUsefulBytes = minimumUsefulBytes
        self.fileIO = fileIO
        self.onComplete = onComplete
        self.onAbandon = onAbandon
    }

    var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return completedURL != nil
    }

    var currentTerminalError: Error? {
        lock.lock(); defer { lock.unlock() }
        return terminalError
    }

    /// 发起首片探测：
    /// - HTTP 200（或总长 <= 首片大小）直接整段写盘并返回 `.localFile`；
    /// - HTTP 206 写完首片并开启后台续传，立刻返回 `.streaming`。
    func start() async throws -> OpenOutcome {
        let candidates = [remoteURL] + backupURLs
        var lastError: Error?

        for url in candidates {
            try Task.checkCancellation()
            do {
                return try await openCandidate(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        let error = lastError ?? PlaybackError.sourceUnavailable
        fail(with: error)
        throw error
    }

    private func openCandidate(url: URL) async throws -> OpenOutcome {
        let initialEnd = Int64(initialChunkBytes - 1)
        let (data, http) = try await fetchData(url: url, range: 0..<(initialEnd + 1))

        if let detectedExt = MediaAudioCache.sniffAudioExtension(
            data: data,
            mimeType: http.mimeType,
            suggestedFilename: http.suggestedFilename
        ) {
            lock.withLock {
                if _destinationURL.pathExtension.lowercased() != detectedExt {
                    _destinationURL = _destinationURL.deletingPathExtension().appendingPathExtension(detectedExt)
                }
            }
        }
        let targetURL = destinationURL

        if http.statusCode == 200 {
            guard data.count > minimumUsefulBytes else {
                throw RemoteHTTPFailure(
                    code: -1,
                    message: "音频分片过小（\(data.count) 字节）",
                    url: url.absoluteString
                )
            }
            try writeCompleteFile(data, to: targetURL)
            onComplete?(targetURL)
            return .localFile(targetURL)
        }

        guard http.statusCode == 206 else {
            throw RemoteHTTPFailure(
                code: http.statusCode,
                message: "音频流加载失败（HTTP \(http.statusCode)）",
                url: url.absoluteString
            )
        }

        guard let parsed = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
              parsed.total > Int64(minimumUsefulBytes),
              !data.isEmpty else {
            throw RemoteHTTPFailure(
                code: -1,
                message: "无效的分片响应头",
                url: url.absoluteString
            )
        }

        if parsed.start == 0, Int64(data.count) >= parsed.total {
            try writeCompleteFile(data, to: targetURL)
            onComplete?(targetURL)
            return .localFile(targetURL)
        }

        try preparePartFile(totalLength: parsed.total, initialOffset: parsed.start, initialData: data)
        startSequentialDownload(from: parsed.start + Int64(data.count), primaryURL: url)
        return .streaming(self)
    }

    private func writeCompleteFile(_ data: Data, to targetURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: targetURL.path) { return }
        try data.write(to: targetURL, options: .atomic)
    }

    private func preparePartFile(totalLength: Int64, initialOffset: Int64, initialData: Data) throws {
        MediaAudioCache.pin(partURL)
        var handle: FileHandle?
        do {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let openedHandle = try FileHandle(forUpdating: partURL)
            handle = openedHandle
            try fileIO.seek(openedHandle, UInt64(initialOffset))
            try fileIO.write(openedHandle, initialData)

            lock.withLock {
                self.totalLength = totalLength
                self.writeHandle = openedHandle
                self.ranges.insert(initialOffset..<(initialOffset + Int64(initialData.count)))
                self.consumerCount = max(self.consumerCount, 1)
            }
        } catch {
            try? handle?.close()
            MediaAudioCache.unpin(partURL)
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
    }

    func retainConsumer() {
        lock.lock()
        consumerCount += 1
        lock.unlock()
    }

    func releaseConsumer() {
        let shouldAbort: Bool = {
            lock.lock(); defer { lock.unlock() }
            consumerCount = max(0, consumerCount - 1)
            return consumerCount == 0 && completedURL == nil && !isCancelled
        }()
        if shouldAbort {
            cancelAll()
        }
    }

    func cancelAll() {
        let cleanup: (FileHandle?, [Task<Void, Never>], [@Sendable () -> Void], [CheckedContinuation<URL?, Never>]) = {
            lock.lock(); defer { lock.unlock() }
            isCancelled = true
            let seq = sequentialTask
            sequentialTask = nil
            var tasks = Array(demandTasks.values)
            if let seq { tasks.append(seq) }
            demandTasks.removeAll()
            inFlightRanges.removeAll()
            let handle = writeHandle
            writeHandle = nil
            let listeners = Array(dataListeners.values)
            dataListeners.removeAll()
            let waiters = Array(completionWaiters.values)
            completionWaiters.removeAll()
            return (handle, tasks, listeners, waiters)
        }()

        for task in cleanup.1 { task.cancel() }
        try? cleanup.0?.close()
        MediaAudioCache.unpin(partURL)
        try? FileManager.default.removeItem(at: partURL)
        for listener in cleanup.2 { listener() }
        for waiter in cleanup.3 { waiter.resume(returning: nil) }
        onAbandon?()
    }

    @discardableResult
    func addListener(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        dataListeners[id] = listener
        lock.unlock()
        return id
    }

    func removeListener(_ id: UUID) {
        lock.lock()
        dataListeners.removeValue(forKey: id)
        lock.unlock()
    }

    /// 等待整首音频流彻底写盘并转为正式缓存文件（用于流式播放完成后异步补测响度）。
    func waitForLocalFile() async -> URL? {
        if let completed = currentCompletedURL() { return completed }
        if isCancelledOrFailed() { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediate: URL??
                lock.lock()
                if let url = completedURL {
                    immediate = .some(url)
                } else if isCancelled || terminalError != nil {
                    immediate = .some(nil)
                } else {
                    completionWaiters[id] = continuation
                }
                lock.unlock()

                if let resolved = immediate {
                    continuation.resume(returning: resolved)
                }
            }
        } onCancel: {
            let orphan: CheckedContinuation<URL?, Never>? = {
                lock.lock(); defer { lock.unlock() }
                return completionWaiters.removeValue(forKey: id)
            }()
            orphan?.resume(returning: nil)
        }
    }

    private func currentCompletedURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return completedURL
    }

    private func isCancelledOrFailed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled || terminalError != nil
    }

    /// 从当前已缓存区间读取从 `offset` 开始最多 `maxLength` 字节。
    func readAvailable(offset: Int64, maxLength: Int) -> Data {
        guard maxLength > 0, offset >= 0 else { return Data() }

        lock.lock()
        let finishedURL = completedURL
        let length = totalLength
        if finishedURL == nil {
            guard !isCancelled, let handle = writeHandle else {
                lock.unlock()
                return Data()
            }
            let avail = ranges.availableLength(from: offset)
            let count = Int(min(Int64(maxLength), avail))
            guard count > 0 else {
                lock.unlock()
                return Data()
            }
            try? handle.seek(toOffset: UInt64(offset))
            let slice = (try? handle.read(upToCount: count)) ?? Data()
            lock.unlock()
            return slice
        }
        lock.unlock()

        guard let finishedURL else { return Data() }
        let avail = max(0, length - offset)
        let count = Int(min(Int64(maxLength), avail))
        guard count > 0, let readHandle = try? FileHandle(forReadingFrom: finishedURL) else { return Data() }
        defer { try? readHandle.close() }
        try? readHandle.seek(toOffset: UInt64(offset))
        return (try? readHandle.read(upToCount: count)) ?? Data()
    }

    /// 播放器请求跳转到尚未到达的字节偏移时，按真实区间去重并优先拉取目标分片（支持秒拖/EOF probe）。
    func ensureRangeRequested(offset: Int64, length: Int64) {
        let scheduled: (id: UUID, range: Range<Int64>)? = {
            lock.lock(); defer { lock.unlock() }
            guard !isCancelled, completedURL == nil, terminalError == nil, totalLength > 0 else { return nil }
            let span = max(length, Int64(chunkBytes))
            guard let candidate = ranges.nextMissingRange(from: offset, maxLength: span, totalLength: totalLength) else {
                return nil
            }
            guard !inFlightRanges.values.contains(where: { $0.contains(candidate.lowerBound) }) else {
                return nil
            }
            let id = UUID()
            let requestEnd = min(totalLength, candidate.lowerBound + Int64(chunkBytes))
            let target = candidate.lowerBound..<requestEnd
            inFlightRanges[id] = target
            return (id, target)
        }()

        guard let (taskID, targetRange) = scheduled else { return }
        let candidates = [remoteURL] + backupURLs

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock {
                    _ = self.inFlightRanges.removeValue(forKey: taskID)
                    _ = self.demandTasks.removeValue(forKey: taskID)
                }
            }
            do {
                try await self.downloadChunkWithRetry(range: targetRange, urls: candidates)
            } catch is CancellationError {
                return
            } catch {
                self.fail(with: error)
            }
        }
        lock.withLock { demandTasks[taskID] = task }
    }

    private func startSequentialDownload(from startOffset: Int64, primaryURL: URL) {
        let urls = [primaryURL] + backupURLs.filter { $0 != primaryURL }
        let task = Task { [weak self] in
            guard let self else { return }
            var cursor = startOffset
            while !Task.isCancelled {
                let nextStep: (id: UUID, range: Range<Int64>)? = self.lock.withLock {
                    guard !self.isCancelled, self.completedURL == nil, self.terminalError == nil else { return nil }
                    guard let range = self.ranges.nextMissingRange(
                        from: cursor,
                        maxLength: Int64(self.chunkBytes),
                        totalLength: self.totalLength
                    ) else { return nil }
                    let id = UUID()
                    self.inFlightRanges[id] = range
                    return (id, range)
                }
                guard let (rangeID, range) = nextStep else { break }

                let succeeded: Bool = await {
                    defer { self.lock.withLock { _ = self.inFlightRanges.removeValue(forKey: rangeID) } }
                    do {
                        try await self.downloadChunkWithRetry(range: range, urls: urls)
                        cursor = range.upperBound
                        return true
                    } catch is CancellationError {
                        return false
                    } catch {
                        self.fail(with: error)
                        return false
                    }
                }()
                if !succeeded { return }
            }
        }
        lock.withLock { sequentialTask = task }
    }

    private func downloadChunkWithRetry(range: Range<Int64>, urls: [URL]) async throws {
        var lastError: Error?
        for url in urls {
            for attempt in 0..<2 {
                try Task.checkCancellation()
                let chunk: (offset: Int64, data: Data)
                do {
                    let (data, http) = try await fetchData(url: url, range: range)
                    guard http.statusCode == 206 || http.statusCode == 200 else {
                        throw RemoteHTTPFailure(
                            code: http.statusCode,
                            message: "音频流加载失败（HTTP \(http.statusCode)）",
                            url: url.absoluteString
                        )
                    }
                    let writeOffset: Int64
                    if http.statusCode == 206,
                       let parsed = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")) {
                        writeOffset = parsed.start
                    } else if http.statusCode == 200 {
                        writeOffset = 0
                    } else {
                        writeOffset = range.lowerBound
                    }
                    chunk = (writeOffset, data)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    if attempt == 0 {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    continue
                }
                // Disk failures are terminal; retrying the HTTP request cannot repair them.
                try recordChunk(offset: chunk.offset, data: chunk.data)
                return
            }
        }
        throw lastError ?? PlaybackError.sourceUnavailable
    }

    private func recordChunk(offset: Int64, data: Data) throws {
        guard !data.isEmpty else { return }

        var finishedFileToNotify: URL?
        var listenersToWake: [@Sendable () -> Void] = []
        var waitersToWake: [CheckedContinuation<URL?, Never>] = []

        try lock.withLock {
            guard !isCancelled, terminalError == nil, completedURL == nil, let handle = writeHandle else { return }
            let clippedCount: Int
            if totalLength > 0, offset < totalLength {
                clippedCount = min(data.count, Int(totalLength - offset))
            } else {
                clippedCount = 0
            }
            if clippedCount > 0 {
                let slice = clippedCount == data.count ? data : data.prefix(clippedCount)
                try fileIO.seek(handle, UInt64(offset))
                try fileIO.write(handle, slice)
                ranges.insert(offset..<(offset + Int64(clippedCount)))
            }
            listenersToWake = Array(dataListeners.values)
            if ranges.isComplete(totalLength: totalLength) {
                // Keep the handle and waiters reachable by fail(with:) until every I/O step succeeds.
                try fileIO.synchronize(handle)
                try fileIO.close(handle)
                let finalDest = _destinationURL
                let manager = FileManager.default
                if manager.fileExists(atPath: finalDest.path) {
                    try manager.removeItem(at: partURL)
                } else {
                    try fileIO.move(partURL, finalDest)
                }
                MediaAudioCache.unpin(partURL)
                writeHandle = nil
                completedURL = finalDest
                finishedFileToNotify = finalDest
                waitersToWake = Array(completionWaiters.values)
                completionWaiters.removeAll()
            }
        }

        if let finishedFileToNotify {
            onComplete?(finishedFileToNotify)
            for waiter in waitersToWake { waiter.resume(returning: finishedFileToNotify) }
        }
        for listener in listenersToWake { listener() }
    }

    private func fail(with error: Error) {
        let info: ([Task<Void, Never>], FileHandle?, [@Sendable () -> Void], [CheckedContinuation<URL?, Never>]) = {
            lock.lock(); defer { lock.unlock() }
            if terminalError == nil { terminalError = error }
            let seq = sequentialTask
            sequentialTask = nil
            var tasks = Array(demandTasks.values)
            if let seq { tasks.append(seq) }
            demandTasks.removeAll()
            inFlightRanges.removeAll()
            let handle = writeHandle
            writeHandle = nil
            let listeners = Array(dataListeners.values)
            let waiters = Array(completionWaiters.values)
            completionWaiters.removeAll()
            return (tasks, handle, listeners, waiters)
        }()

        for task in info.0 { task.cancel() }
        try? info.1?.close()
        MediaAudioCache.unpin(partURL)
        try? FileManager.default.removeItem(at: partURL)
        for listener in info.2 { listener() }
        for waiter in info.3 { waiter.resume(returning: nil) }
    }

    private func fetchData(url: URL, range: Range<Int64>) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = NetworkTimeouts.audioDownload

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: allowedDomains,
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.networkUnavailable
        }
        return (data, http)
    }

    /// 解析 HTTP `Content-Range: bytes <start>-<end>/<total>`。
    static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst("bytes ".count)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let span = parts[0].split(separator: "-", maxSplits: 1)
        guard span.count == 2,
              let start = Int64(span[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(span[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}
