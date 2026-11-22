import Foundation

/// 远端 HTTP/HTTPS 音频流的通用会话工厂：统一接入 `MediaAudioCache` 边下边播/缓存复用与 `HTTPStreamPlayerSession`。
enum RemoteStreamSessionFactory {
    static func makeSession(
        track: Track,
        stream: AudioStreamDescriptor,
        cache: MediaAudioCache = .shared,
        streamingAssetBuilder: StreamingAssetBuilder? = nil,
        hlsAssetBuilder: HLSAssetBuilder? = nil,
        session: URLSession = .shared,
        networkAllowed: @escaping @Sendable () -> Bool = { true }
    ) async throws -> HTTPStreamPlayerSession {
        let media: MediaAudioCache.MediaSource
        if stream.isHLSStream {
            guard networkAllowed() else { throw PlaybackError.networkDisabled }
            _ = try SourceDomainPolicy.validate(url: stream.url, allowedDomains: stream.allowedDomains)
            // 未装配受控 HLS 加载器时拒绝播放，不能退回 AVFoundation 直连外网。
            guard let hlsAssetBuilder else { throw PlaybackError.sourceUnavailable }
            media = .hls(try await hlsAssetBuilder(HLSStreamRequest(stream: stream, session: session, networkAllowed: networkAllowed)))
        } else if streamingAssetBuilder != nil {
            media = try await cache.openMedia(descriptor: stream, networkAllowed: networkAllowed)
        } else {
            media = .local(try await cache.localFile(descriptor: stream, networkAllowed: networkAllowed))
        }
        return try await MainActor.run {
            if Task.isCancelled {
                if case let .hls(prepared) = media { prepared.invalidate() }
                throw CancellationError()
            }
            return try HTTPStreamPlayerSession(
                stream: stream,
                media: media,
                title: track.title,
                cacheKey: stream.cacheKey,
                streamingAssetBuilder: streamingAssetBuilder,
                onEvictLocalURL: { url in
                    cache.evictIfCached(cacheKey: stream.cacheKey, url: url)
                }
            )
        }
    }
}
