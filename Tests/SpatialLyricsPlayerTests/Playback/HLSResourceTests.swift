import AVFoundation
import Foundation
import XCTest
@testable import SpatialLyricsPlayer

final class HLSResourceTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var enabled = true
        var requests: [String] { lock.withLock { paths } }
        var networkAllowed: Bool { lock.withLock { enabled } }
        func disable() { lock.withLock { enabled = false } }
        func record(_ path: String) { lock.withLock { paths.append(path) } }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }

    private func descriptor(_ url: URL, headers: [String: String] = [:]) -> AudioStreamDescriptor {
        AudioStreamDescriptor(cacheKey: "test::hls", fileExtension: "m3u8", qualityTier: .high,
                              qualityID: 1, codec: "AAC", bandwidth: 64_000, isLossless: false,
                              url: url, headers: headers, allowedDomains: ["127.0.0.1"])
    }

    private func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HLSResourceClient.Reply {
        HLSResourceClient.Reply(status: status, headers: headers, body: Data(text.utf8))
    }

    private func routedURLs(_ data: Data) throws -> [URL] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let regex = try NSRegularExpression(pattern: #"http://127\.0\.0\.1[^\s\"]+"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { URL(string: String(text[$0])) }
        }
    }

    func testAllPlaylistResourcesAreRewrittenAndFetchedThroughPolicy() async throws {
        let probe = Probe()
        let upstream = try HLSLoopbackServer { path, _, _ in
            probe.record(path)
            switch path {
            case "/master.m3u8":
                return HLSResourceClient.Reply(status: 200, headers: [:], body: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nlist.m3u8\n".utf8))
            case "/list.m3u8":
                return HLSResourceClient.Reply(status: 200, headers: [:], body: Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\nsegment.aac\n#EXT-X-ENDLIST\n".utf8))
            default: return HLSResourceClient.Reply(status: 200, headers: [:], body: Data(path.utf8))
            }
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("master.m3u8")), session: session(), networkAllowed: { true }))
        let root = try await client.startURL(baseURL: URL(string: "http://127.0.0.1:9000")!)
        let master = try await client.reply(path: root.path)
        let variant = try XCTUnwrap(routedURLs(master.body).first)
        let playlist = try await client.reply(path: variant.path)
        let resources = try routedURLs(playlist.body)
        XCTAssertEqual(resources.count, 3)
        for resource in resources { _ = try await client.reply(path: resource.path) }
        XCTAssertEqual(probe.requests, ["/master.m3u8", "/list.m3u8", "/key.bin", "/init.mp4", "/segment.aac"])
        XCTAssertTrue(resources.allSatisfy { $0.port == 9000 })
    }

    func testDisallowedSegmentAndKeyAreRejectedBeforePlayerSeesPlaylist() async throws {
        for tag in ["http://localhost:9999/secret.aac", "#EXT-X-KEY:METHOD=AES-128,URI=\"http://localhost:9999/key\""] {
            let upstream = try HLSLoopbackServer { _, _, _ in
                HLSResourceClient.Reply(status: 200, headers: [:], body: Data("#EXTM3U\n\(tag)\n".utf8))
            }
            let base = try await upstream.start()
            defer { upstream.invalidate() }
            let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { true }))
            let root = try await client.startURL(baseURL: base)
            do {
                _ = try await client.reply(path: root.path)
                XCTFail("白名单外的 HLS 子请求不能交给播放器")
            } catch let error as SourceDomainPolicy.Violation {
                guard case .disallowedDomain = error else { return XCTFail("错误策略：\(error)") }
            }
        }
    }

    func testRedirectToUnlistedHostIsRejected() async throws {
        let upstream = try HLSLoopbackServer { _, _, _ in
            HLSResourceClient.Reply(status: 302, headers: ["Location": "http://localhost:9999/forbidden"], body: Data())
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { true }))
        let root = try await client.startURL(baseURL: base)
        do { _ = try await client.reply(path: root.path); XCTFail("重定向必须受白名单校验") }
        catch is SourceDomainPolicy.Violation {}
    }

    func testDisablingNetworkBlocksNextRequestWithoutContactingUpstream() async throws {
        let probe = Probe()
        let upstream = try HLSLoopbackServer { path, _, _ in
            probe.record(path)
            return HLSResourceClient.Reply(status: 200, headers: [:], body: Data("#EXTM3U\nsegment.aac\n".utf8))
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { probe.networkAllowed }))
        let root = try await client.startURL(baseURL: base)
        let master = try await client.reply(path: root.path)
        let segment = try XCTUnwrap(routedURLs(master.body).first)
        probe.disable()
        do { _ = try await client.reply(path: segment.path); XCTFail("关闭联网后不能继续请求分片") }
        catch is SourceDomainPolicy.Violation {}
        XCTAssertEqual(probe.requests, ["/root.m3u8"])
    }

    func testTamperedProxyRouteCannotContactUpstream() async throws {
        let probe = Probe()
        let upstream = try HLSLoopbackServer { path, _, _ in
            probe.record(path)
            return HLSResourceClient.Reply(status: 200, headers: [:], body: Data())
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { true }))
        let root = try await client.startURL(baseURL: base)
        do { _ = try await client.reply(path: root.path.replacingOccurrences(of: ".m3u8", with: "x.m3u8")); XCTFail("篡改路由必须拒绝") }
        catch {}
        XCTAssertTrue(probe.requests.isEmpty)
    }

    func testRangeRequestsAndResponseLengthsArePreserved() async throws {
        let upstream = try HLSLoopbackServer { _, range, _ in
            HLSResourceClient.Reply(status: range == "bytes=4-7" ? 206 : 400,
                                    headers: ["Content-Range": "bytes 4-7/16"], body: Data([4, 5, 6, 7]))
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("segment.aac")), session: session(), networkAllowed: { true }))
        let root = try await client.startURL(baseURL: base)
        let result = try await client.reply(path: root.path, range: "bytes=4-7")
        XCTAssertEqual(result.status, 206)
        XCTAssertEqual(result.body, Data([4, 5, 6, 7]))
        XCTAssertEqual(result.headers["Content-Range"], "bytes 4-7/16")
    }

    func testCrossOriginHeadersDropAllCustomSecrets() {
        let origin = URL(string: "https://api.example.com/root.m3u8")!
        let headers = ["Authorization": "secret", "Cookie": "sid=1", "X-Client-Secret": "private", "User-Agent": "FLOW", "Referer": "https://api.example.com/?token=secret"]
        let cross = PluginHTTPClient.headers(headers, from: origin, to: URL(string: "https://cdn.example.com/segment")!)
        XCTAssertEqual(cross, ["User-Agent": "FLOW"])
        XCTAssertEqual(PluginHTTPClient.headers(headers, from: origin, to: origin), headers)
    }

    func testOversizedHLSResponseIsRejectedFromHeaders() async throws {
        let upstream = try HLSLoopbackServer { _, _, _ in
            HLSResourceClient.Reply(status: 200, headers: ["Content-Length": "20000000"], body: Data(repeating: 0, count: 20_000_000))
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { true }))
        let root = try await client.startURL(baseURL: base)
        do { _ = try await client.reply(path: root.path); XCTFail("超大响应必须在读取主体前拒绝") }
        catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
    }

    func testUnsupportedPlaylistNetworkExtensionsFailClosed() async throws {
        for line in ["#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://evil.example/steering\"",
                     "#EXT-X-DEFINE:NAME=\"host\",VALUE=\"https://evil.example\"",
                     "#EXT-X-KEY:METHOD=AES-128,URI=\"file:///tmp/key\""] {
            let upstream = try HLSLoopbackServer { _, _, _ in
                HLSResourceClient.Reply(status: 200, headers: [:], body: Data("#EXTM3U\n\(line)\n".utf8))
            }
            let base = try await upstream.start()
            defer { upstream.invalidate() }
            let client = HLSResourceClient(request: HLSStreamRequest(stream: descriptor(base.appendingPathComponent("root.m3u8")), session: session(), networkAllowed: { true }))
            let root = try await client.startURL(baseURL: base)
            do { _ = try await client.reply(path: root.path); XCTFail("不支持的网络入口不能交给播放器") }
            catch {}
        }
    }

    func testPublicCDNStartingWithIPv6PrefixIsNotPrivateAddress() {
        XCTAssertFalse(SourceDomainPolicy.isPrivateOrLoopbackHost("fcdn.example.com"))
        XCTAssertFalse(SourceDomainPolicy.isPrivateOrLoopbackHost("fd.example.com"))
        XCTAssertTrue(SourceDomainPolicy.isPrivateOrLoopbackHost("fd00::1"))
    }

    func testAudioCacheAndProgressiveRequestsRespectDisabledNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-audio-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaAudioCache(directory: directory, session: session())
        let stream = AudioStreamDescriptor(cacheKey: "blocked", fileExtension: "m4a", qualityTier: .high,
                                          qualityID: 1, codec: "AAC", bandwidth: 1, isLossless: false,
                                          url: URL(string: "https://audio.example.invalid/song.m4a")!)
        do { _ = try await cache.localFile(descriptor: stream, networkAllowed: { false }); XCTFail("不应下载") }
        catch is SourceDomainPolicy.Violation {}
        do { _ = try await cache.openMedia(descriptor: stream, networkAllowed: { false }); XCTFail("不应请求首片") }
        catch is SourceDomainPolicy.Violation {}
    }

    @MainActor
    func testRealAVPlayerPreparesAndPlaysHLSThroughLoopbackSilently() async throws {
        let probe = Probe()
        // ffmpeg 生成的一秒单声道静音 ADTS AAC，固定夹具不依赖外部工具或网络。
        let audio = try XCTUnwrap(Data(base64Encoded: "//FQQANf/NwATGF2YzYzLjEuMTAyAAIwQA7/8VBAAX/8ARggB//xUEABf/wBGCAH" + String(repeating: "//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH", count: 14) + "//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH"))
        let upstream = try HLSLoopbackServer { path, _, head in
            probe.record(path)
            if path == "/root.m3u8" {
                let list = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.045,\nsegment.aac\n#EXTINF:1.045,\nsegment.aac\n#EXTINF:1.045,\nsegment.aac\n#EXT-X-ENDLIST\n"
                return HLSResourceClient.Reply(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: head ? Data() : Data(list.utf8))
            }
            return HLSResourceClient.Reply(status: 200, headers: ["Content-Type": "audio/aac"], body: head ? Data() : audio)
        }
        let base = try await upstream.start()
        defer { upstream.invalidate() }
        let stream = descriptor(base.appendingPathComponent("root.m3u8"))
        let prepared = try await HLSResourceLoaderBridge.makeAsset(for: HLSStreamRequest(stream: stream, session: session(), networkAllowed: { true }))
        defer { prepared.invalidate() }
        let item = AVPlayerItem(asset: prepared.asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        await waitUntil("真实 HLS 准备完成", timeout: 8) { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        player.play()
        await waitUntil("静音真实播放位置推进", timeout: 5) { player.currentTime().seconds > 0.1 }
        XCTAssertTrue(probe.requests.contains("/segment.aac"))
    }
}
