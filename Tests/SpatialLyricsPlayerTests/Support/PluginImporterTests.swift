import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证第四阶段第三方可扩展导入器：`JSPluginEngine`（`JavaScriptCore` 沙盒、`axios`/Crypto 垫片、
/// 白名单域名校验、扫码鉴权适配）、`JSONTemplateSource` 与 `ImportedSourceStore` 持久化导入/卸载。
final class PluginImporterTests: XCTestCase {

    private final class PluginStubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let result = Self.handler?(request) ?? (404, [:], Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.local")!,
                statusCode: result.0,
                httpVersion: "HTTP/1.1",
                headerFields: result.1
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.2)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class MutableFlag: @unchecked Sendable {
        var value = true
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        PluginStubProtocol.handler = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-phase4-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PluginStubProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PluginStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testSourceDomainPolicyExactWildcardAndRejections() throws {
        XCTAssertNoThrow(try SourceDomainPolicy.validate(url: "https://api.example.com/v1", allowedDomains: ["api.example.com"]))
        XCTAssertNoThrow(try SourceDomainPolicy.validate(url: "https://cn-edge01.cdn.example.com/audio.m4a", allowedDomains: ["*.cdn.example.com"]))

        XCTAssertThrowsError(try SourceDomainPolicy.validate(url: "file:///etc/passwd", allowedDomains: ["*"]))
        XCTAssertThrowsError(try SourceDomainPolicy.validate(url: "https://evil.org/steal", allowedDomains: ["api.example.com"]))
    }

    func testJSPluginSandboxAxiosCryptoStorageSearchLyricsAndDomainEnforcement() async throws {
        let networkFlag = MutableFlag()
        let secrets = InMemorySecretStore()

        PluginStubProtocol.handler = { request in
            let url = request.url!
            if url.host == "api.allowed.test", url.path == "/search" {
                let payload = #"""
                {
                  "items": [
                    {
                      "id": "track-42",
                      "title": "Sandboxed Waltz",
                      "artist": "JS Composer",
                      "duration": 215,
                      "extraToken": "xyz-999"
                    }
                  ]
                }
                """#
                return (200, ["Content-Type": "application/json"], Data(payload.utf8))
            }
            return (404, [:], Data())
        }

        let script = #"""
        const axios = require("axios");
        const CryptoJS = require("crypto-js");

        module.exports = {
          id: "allowed-js-demo",
          platform: "Allowed JS Demo",
          version: "1.0.0",
          author: "Test",
          allowedDomains: ["api.allowed.test", "*.media.allowed.test"],
          supportedQualities: ["auto", "high", "lossless"],

          async search(query, page) {
            const sig = CryptoJS.MD5(query).toString();
            flow.storage.set("lastSig", sig);
            const res = await axios.get("https://api.allowed.test/search", {
              params: { q: query, page: page, sig: sig }
            });
            return {
              isEnd: true,
              data: res.data.items.map(function(it) {
                return {
                  id: it.id,
                  title: it.title,
                  artist: it.artist,
                  duration: it.duration,
                  _meta: { extraToken: it.extraToken, savedSig: flow.storage.get("lastSig") }
                };
              })
            };
          },

          async discover(limit) {
            return [{ id: "disc-1", title: "Featured Ambient", artist: "Curator", duration: 180 }];
          },

          async getMediaSource(musicItem, quality) {
            if (musicItem.id === "blocked") {
              await axios.get("https://forbidden.other.test/secret");
            }
            const token = (musicItem._meta && musicItem._meta.extraToken) || "";
            return {
              url: "https://edge1.media.allowed.test/stream/" + musicItem.id + ".m4a?t=" + token + "&q=" + quality,
              headers: { "Referer": "https://api.allowed.test" },
              codec: "AAC",
              bitrate: 256000
            };
          },

          async getLyric(musicItem) {
            return {
              rawLrc: "[00:02.00]Sandboxed sky",
              translation: "[00:02.00]沙盒夜空"
            };
          },

          auth: {
            async status() {
              return { state: "signedIn", summary: "User #1", detail: "Standard" };
            },
            async beginQRLogin() {
              return { url: "https://api.allowed.test/qr?k=1", hint: "Scan now", token: "tok1" };
            },
            async pollQRLogin(tok) {
              return { state: "signedIn", summary: "Confirmed-" + tok, detail: "Pro" };
            },
            async collections() {
              return [{ id: "fav-1", title: "Favorites", kind: "favorites" }];
            },
            async collectionTracks(col) {
              return [{ id: "track-42", title: "Sandboxed Waltz", artist: "JS Composer", duration: 215 }];
            }
          }
        };
        """#

        let source = try JSPluginSource(
            scriptSource: script,
            session: makeSession(),
            secrets: secrets,
            networkAllowed: { networkFlag.value }
        )

        XCTAssertEqual(source.descriptor.id.rawValue, "js-allowed-js-demo")
        XCTAssertEqual(source.descriptor.kind, .jsPlugin)
        XCTAssertTrue(source.descriptor.supportsDiscover)
        XCTAssertTrue(source.descriptor.supportsAccount)

        let results = try await source.search(SearchRequest(query: "waltz"))
        XCTAssertEqual(results.count, 1)
        let track = try XCTUnwrap(results.first)
        XCTAssertEqual(track.title, "Sandboxed Waltz")
        XCTAssertNotNil(secrets.load(account: "jsplugin.allowed-js-demo.lastSig"))

        let lyrics = try await source.lyrics(for: track)
        XCTAssertEqual(lyrics?.lines.first?.text, "Sandboxed sky")
        XCTAssertEqual(lyrics?.lines.first?.translation, "沙盒夜空")

        // 非白名单域名必须被拦截。
        let blockedTrack = Track(sourceID: source.descriptor.id, externalID: "blocked", title: "Blocked", artist: "", duration: 10)
        do {
            _ = try await source.makeSession(for: blockedTrack)
            XCTFail("应拒绝访问未列入 allowedDomains 的域名")
        } catch {
            // 预期拦截异常。
        }

        // 关闭联网开关后，插件请求应被阻断。
        networkFlag.value = false
        do {
            _ = try await source.search(SearchRequest(query: "offline"))
            XCTFail("关网状态下不应允许插件发起搜索请求")
        } catch let playbackError as PlaybackError {
            XCTAssertEqual(playbackError, .networkDisabled)
        } catch {
            XCTFail("Expected PlaybackError.networkDisabled, got \(error)")
        }
        networkFlag.value = true

        // 账号适配控制器。
        let account = await MainActor.run { JSPluginAccountController(source: source) }
        await account.refreshAuthStatus()
        let cols = try await account.collections()
        XCTAssertEqual(cols.first?.title, "Favorites")
        let colTracks = try await account.tracks(in: try XCTUnwrap(cols.first))
        XCTAssertEqual(colTracks.first?.externalID, "track-42")
    }

    func testJSONTemplateSourceResolvesTracksAndLyricsAndRejectsDisallowedHost() async throws {
        PluginStubProtocol.handler = { request in
            let url = request.url!
            if url.path == "/v1/tracks" {
                let json = #"""
                {
                  "data": {
                    "list": [
                      {
                        "id": "j-1",
                        "name": "Template Song",
                        "creator": "Open API",
                        "seconds": 195,
                        "cover": "https://tpl.example.test/cover.jpg"
                      }
                    ]
                  }
                }
                """#
                return (200, [:], Data(json.utf8))
            }
            if url.path == "/v1/lyrics" {
                return (200, [:], Data(#"{"lrc":"[00:01.00]Template lyrics line"}"#.utf8))
            }
            return (404, [:], Data())
        }

        let definition = JSONTemplateDefinition(
            schema: "flow-source-v1",
            id: "open-catalog",
            name: "Open Catalog",
            allowedDomains: ["tpl.example.test"],
            search: JSONTemplateDefinition.ListEndpoint(
                url: "https://tpl.example.test/v1/tracks?q={{query}}",
                itemsPath: "data.list",
                fields: JSONTemplateDefinition.TrackFieldMap(
                    id: "id",
                    title: "name",
                    artist: "creator",
                    duration: "seconds",
                    artwork: "cover"
                )
            ),
            lyrics: JSONTemplateDefinition.LyricsEndpoint(
                url: "https://tpl.example.test/v1/lyrics?id={{id}}",
                textPath: "lrc"
            )
        )

        let source = JSONTemplateSource(definition: definition, session: makeSession())
        try source.validateDefinition()

        let tracks = try await source.search(SearchRequest(query: "template"))
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.title, "Template Song")
        XCTAssertEqual(track.artist, "Open API")

        let lyrics = try await source.lyrics(for: track)
        XCTAssertEqual(lyrics?.lines.first?.text, "Template lyrics line")

        // 非法域名模板应校验失败。
        var badDef = definition
        badDef.search.url = "https://other-untrusted.test/tracks"
        let badSource = JSONTemplateSource(definition: badDef, session: makeSession())
        XCTAssertThrowsError(try badSource.validateDefinition())
    }

    @MainActor
    func testImportedSourceStorePersistenceAndSubscriptionManifest() async throws {
        let suite = "flow.importstore.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storeDir = tempDir.appendingPathComponent("ImportedSources", isDirectory: true)
        let secrets = InMemorySecretStore()

        let pluginURL = tempDir.appendingPathComponent("remote-demo.js")
        let pluginJS = #"""
        module.exports = {
          id: "sub-demo",
          platform: "Sub Demo",
          allowedDomains: ["sub.example.test"],
          async search(q) { return [{ id: "1", title: q, artist: "A", duration: 100 }]; },
          async getMediaSource(item) { return { url: "https://sub.example.test/1.mp3" }; }
        };
        """#
        try pluginJS.write(to: pluginURL, atomically: true, encoding: .utf8)

        PluginStubProtocol.handler = { _ in
            (200, [:], Data(pluginJS.utf8))
        }

        // 先测本地 .js 文件导入与重启恢复。
        let registry1 = SourceRegistry()
        let manager1 = SourceManager(
            registry: registry1,
            defaults: defaults,
            secrets: secrets,
            importedSourcesDirectory: storeDir,
            session: makeSession()
        )
        let managed = try await manager1.importSource(from: pluginURL)
        XCTAssertEqual(managed.descriptor.displayName, "Sub Demo")

        // 模拟重新冷启动后的恢复。
        let registry2 = SourceRegistry()
        let manager2 = SourceManager(
            registry: registry2,
            defaults: defaults,
            secrets: secrets,
            importedSourcesDirectory: storeDir,
            session: makeSession()
        )
        await manager2.restoreStandardSources()
        XCTAssertNotNil(manager2.managedSource(for: managed.id))

        // 移除后应同步从磁盘索引清除。
        manager2.removeConfiguredSource(managed.id)
        XCTAssertNil(manager2.managedSource(for: managed.id))

        // 再测 MusicFree 风格订阅清单 .json URL 导入。
        let manifestURL = tempDir.appendingPathComponent("plugins-sub.json")
        let subJSON = #"{"plugins":[{"name":"Remote Demo","url":"https://plugins.example.test/remote-demo.js"}]}"#
        try subJSON.write(to: manifestURL, atomically: true, encoding: .utf8)

        let importedFromSub = try await manager2.importSource(from: manifestURL)
        XCTAssertEqual(importedFromSub.descriptor.displayName, "Sub Demo")
    }

    @MainActor
    func testJSPluginRestoresBvidAndMetaAcrossRestartAndUpgradesBiliArtwork() async throws {
        let m4aURL = try TestAudioFixture.makeM4A(in: tempDir)
        let m4aData = try Data(contentsOf: m4aURL)
        let secrets = InMemorySecretStore()
        let lock = NSLock()
        var artworkSchemes: [String] = []

        PluginStubProtocol.handler = { request in
            let url = try? XCTUnwrap(request.url)
            if url?.host == "i0.hdslb.com" {
                lock.lock()
                artworkSchemes.append(url?.scheme ?? "")
                lock.unlock()
                return (200, ["Content-Type": "image/jpeg"], Data([0xFF, 0xD8, 0xFF, 0xD9]))
            }
            if url?.path == "/audio.m4a" {
                return (200, ["Content-Length": "\(m4aData.count)", "Accept-Ranges": "bytes"], m4aData)
            }
            return (404, [:], Data())
        }

        let script = #"""
        module.exports = {
          id: "bilibili",
          platform: "B站测试",
          allowedDomains: ["i0.hdslb.com", "cdn.bili.test"],
          async search(query, page) {
            return {
              isEnd: true,
              data: [{
                id: "998877",
                bvid: "BV1624y1M7rG",
                album: "BV1624y1M7rG",
                title: "My Love",
                artist: "JLRS",
                duration: 235,
                artwork: "http://i0.hdslb.com/cover.jpg",
                _meta: { extraToken: "tok-reborn" }
              }]
            };
          },
          async getMediaSource(musicItem, quality) {
            if (!musicItem.bvid || musicItem.bvid !== "BV1624y1M7rG") {
              throw new Error("missing bvid");
            }
            return {
              url: "https://cdn.bili.test/audio.m4a?bv=" + musicItem.bvid + "&cid=" + (musicItem.cid || "") + "&t=" + ((musicItem._meta && musicItem._meta.extraToken) || ""),
              codec: "AAC",
              bitrate: 192000
            };
          }
        };
        """#

        let audioCache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache1", isDirectory: true),
            offlineDirectory: tempDir.appendingPathComponent("offline1", isDirectory: true),
            session: makeSession()
        )
        let source1 = try JSPluginSource(
            scriptSource: script,
            session: makeSession(),
            secrets: secrets,
            audioCache: audioCache
        )
        let searched = try await source1.search(SearchRequest(query: "My Love"))
        let firstTrack = try XCTUnwrap(searched.first)
        if case let .remote(artURL) = firstTrack.artwork?.media {
            XCTAssertEqual(artURL.scheme, "https", "已知支持 HTTPS 的 hdslb 封面链接应直接升级")
        } else {
            XCTFail("期望远程封面引用")
        }
        XCTAssertNotNil(firstTrack.persistentIdentifier)

        // 用新的 JSPluginSource（空 rawItemCache）模拟 App 重启后从持久化曲目切回原曲
        let source2 = try JSPluginSource(
            scriptSource: script,
            session: makeSession(),
            secrets: secrets,
            audioCache: MediaAudioCache(
                directory: tempDir.appendingPathComponent("cache2", isDirectory: true),
                offlineDirectory: tempDir.appendingPathComponent("offline2", isDirectory: true),
                session: makeSession()
            )
        )
        let restoredSession = try await source2.makeSession(for: firstTrack)
        await restoredSession.invalidate()

        // 再验证老数据库里 persistentIdentifier == nil 的历史记录：能从 externalID / album 兜底识别 BV 号
        let legacyTrack = Track(
            sourceID: source2.descriptor.id,
            externalID: "BV1624y1M7rG",
            title: "Legacy Track",
            artist: "JLRS",
            album: "BV1624y1M7rG",
            duration: 235,
            artwork: ArtworkReference(.remote(try XCTUnwrap(URL(string: "http://i0.hdslb.com/legacy.jpg")))),
            persistentIdentifier: nil
        )
        let legacySession = try await source2.makeSession(for: legacyTrack)
        await legacySession.invalidate()

        // 传入遗留 http://i0.hdslb.com 封面引用时也应自动走 https 获取成功
        let fetchedArt = try await source2.artwork(for: try XCTUnwrap(legacyTrack.artwork))
        XCTAssertNotNil(fetchedArt)
        let capturedSchemes = lock.withLock { artworkSchemes }
        XCTAssertEqual(capturedSchemes, ["https"])
    }
}
