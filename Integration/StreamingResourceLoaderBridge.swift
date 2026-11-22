import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// `AVAssetResourceLoaderDelegate` 系统队列桥接：负责将 `ProgressiveAudioStream`
/// 接入 `AVURLAsset` 的自定义资源加载通道（Apple 框架要求提供 C 回调队列，故归入 `Integration/` 层）。
enum StreamingResourceLoaderBridge {
    static func makeAsset(for stream: ProgressiveAudioStream) -> StreamingPreparedAsset {
        let delegate = StreamingResourceLoaderDelegate(stream: stream)
        let asset = AVURLAsset(url: delegate.assetURL)
        asset.resourceLoader.setDelegate(delegate, queue: delegate.callbackQueue)
        return StreamingPreparedAsset(
            asset: asset,
            invalidate: { delegate.invalidate() },
            keepAlive: delegate
        )
    }
}

private final class StreamingResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let customScheme = "slp-stream"

    let stream: ProgressiveAudioStream
    let assetURL: URL
    let callbackQueue = DispatchQueue(label: "flow.audio.resource-loader")

    private let requestLock = NSLock()
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var listenerID: UUID?
    private var isInvalidated = false

    init(stream: ProgressiveAudioStream) {
        self.stream = stream
        var components = URLComponents()
        components.scheme = Self.customScheme
        components.host = "stream"
        components.path = "/\(stream.destinationURL.lastPathComponent)"
        self.assetURL = components.url ?? URL(string: "\(Self.customScheme)://stream/audio.m4a")!
        super.init()
        self.listenerID = stream.addListener { [weak self] in
            guard let self else { return }
            self.callbackQueue.async { self.drainPendingRequests() }
        }
    }

    func invalidate() {
        let idToRemove: UUID? = requestLock.withLock {
            isInvalidated = true
            let id = listenerID
            listenerID = nil
            return id
        }
        if let idToRemove {
            stream.removeListener(idToRemove)
        }
        callbackQueue.async { [self] in
            let requests = requestLock.withLock { () -> [AVAssetResourceLoadingRequest] in
                let copy = pendingRequests
                pendingRequests.removeAll()
                return copy
            }
            let err = CancellationError()
            for req in requests where !req.isFinished && !req.isCancelled {
                req.finishLoading(with: err)
            }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let invalidated = requestLock.withLock { isInvalidated }
        guard !invalidated else { return false }

        if let info = loadingRequest.contentInformationRequest {
            let ext = stream.destinationURL.pathExtension.lowercased()
            let contentUTType: UTType = switch ext {
            case "mp3": .mp3
            case "wav": .wav
            case "aiff", "aif": .aiff
            case "aac": UTType(filenameExtension: "aac") ?? .mpeg4Audio
            case "flac": UTType(filenameExtension: "flac") ?? .audio
            case "ogg": UTType(filenameExtension: "ogg") ?? .audio
            case "opus": UTType(filenameExtension: "opus") ?? .audio
            default: .mpeg4Audio
            }
            info.contentType = contentUTType.identifier
            info.isByteRangeAccessSupported = true
            info.contentLength = stream.totalLength
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let targetOffset = Int64(dataRequest.currentOffset)
        let remaining = dataRequest.requestsAllDataToEndOfResource
            ? max(0, stream.totalLength - targetOffset)
            : Int64(dataRequest.requestedLength)
        requestLock.withLock { pendingRequests.append(loadingRequest) }
        drainPendingRequests()
        let stillPending = requestLock.withLock { pendingRequests.contains { $0 === loadingRequest } }
        if stillPending {
            stream.ensureRangeRequested(offset: Int64(dataRequest.currentOffset), length: max(1, remaining))
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requestLock.withLock { pendingRequests.removeAll { $0 === loadingRequest } }
    }

    private func drainPendingRequests() {
        let state = requestLock.withLock { (isInvalidated, pendingRequests) }
        guard !state.0 else { return }
        let currentRequests = state.1

        if let error = stream.currentTerminalError {
            requestLock.withLock { pendingRequests.removeAll() }
            for req in currentRequests where !req.isFinished && !req.isCancelled {
                req.finishLoading(with: error)
            }
            return
        }

        var remaining: [AVAssetResourceLoadingRequest] = []
        remaining.reserveCapacity(currentRequests.count)

        for req in currentRequests {
            if req.isFinished || req.isCancelled { continue }
            guard let dataRequest = req.dataRequest else {
                req.finishLoading()
                continue
            }

            let total = stream.totalLength
            let endOffset: Int64 = dataRequest.requestsAllDataToEndOfResource
                ? total
                : min(total, Int64(dataRequest.requestedOffset) + Int64(dataRequest.requestedLength))

            while dataRequest.currentOffset < endOffset {
                let left = Int(min(Int64(256 * 1024), endOffset - Int64(dataRequest.currentOffset)))
                let chunk = stream.readAvailable(offset: Int64(dataRequest.currentOffset), maxLength: left)
                if chunk.isEmpty {
                    stream.ensureRangeRequested(offset: Int64(dataRequest.currentOffset), length: Int64(left))
                    break
                }
                dataRequest.respond(with: chunk)
            }

            if dataRequest.currentOffset >= endOffset {
                req.finishLoading()
            } else {
                remaining.append(req)
            }
        }

        requestLock.withLock {
            let stillActive = Set(pendingRequests.map { ObjectIdentifier($0) })
            pendingRequests = remaining.filter { stillActive.contains(ObjectIdentifier($0)) }
        }
    }
}
