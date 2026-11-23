import CryptoKit
import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证 `FLOW Source Spec v1` 标准、MusicFree / LX / JSON 多配置兼容与真实 GitHub 生态插件/开放接口实测。
final class MultiConfigCompatTests: XCTestCase {

    private final class MockHTTPProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.recordedRequests.append(request)
            do {
                let result = try Self.handler?(request) ?? (404, [:], Data())
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://invalid.local")!,
                    statusCode: result.0,
                    httpVersion: "HTTP/1.1",
                    headerFields: result.1
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.2)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        MockHTTPProtocol.handler = nil
        MockHTTPProtocol.recordedRequests = []
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-compat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockHTTPProtocol.handler = nil
        MockHTTPProtocol.recordedRequests = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testFetchTextJSONRequestAndResponseCompatibility() async throws {
        let requestBody = #"{"query":"音乐 & blues"}"#
        let responseBody = #"{"items":[{"id":"fetch-1","title":"Fetch Result"}]}"#
        MockHTTPProtocol.handler = { request in
            if request.url?.path == "/catalog" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "FLOW")
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream, body.isEmpty {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                XCTAssertEqual(String(data: body, encoding: .utf8), requestBody)
                return (201, ["Content-Type": "application/json", "X-Trace": "mock-trace"], Data(responseBody.utf8))
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
            return (200, ["Content-Type": "text/plain"], Data("plain 音乐".utf8))
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try JSPluginRuntime(scriptSource: #"""
            module.exports = {
                id: "fetch-compat",
                allowedDomains: ["fetch.example.test"],
                search() { return []; },
                async inspectJSON() {
                    const pending = fetch(new URL("https://fetch.example.test/catalog"), {
                        method: "POST",
                        headers: { "Content-Type": "application/json", "X-Client": "FLOW" },
                        body: JSON.stringify({ query: "音乐 & blues" })
                    });
                    const response = await pending;
                    const body = response.json();
                    return {
                        fetchIsPromise: typeof pending.then === "function",
                        bodyIsPromise: typeof body.then === "function",
                        ok: response.ok, status: response.status, statusText: response.statusText,
                        url: response.url,
                        contentType: response.headers.get("cOnTeNt-TyPe"),
                        trace: response.headers.get("X-TRACE"),
                        missing: response.headers.get("X-Missing"),
                        data: await body
                    };
                },
                async inspectText() {
                    const response = await fetch("https://fetch.example.test/text", {
                        headers: [["Accept", "text/plain"]]
                    });
                    const body = response.text();
                    return { ok: response.ok, bodyIsPromise: typeof body.then === "function", text: await body };
                }
            };
            """#, session: session, secrets: InMemorySecretStore())
        defer { runtime.invalidate() }

        let json = try await runtime.call("inspectJSON") as? [String: Any]
        XCTAssertEqual(json?["fetchIsPromise"] as? Bool, true)
        XCTAssertEqual(json?["bodyIsPromise"] as? Bool, true)
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["status"] as? Int, 201)
        XCTAssertEqual(json?["statusText"] as? String, "")
        XCTAssertEqual(json?["url"] as? String, "https://fetch.example.test/catalog")
        XCTAssertEqual(json?["contentType"] as? String, "application/json")
        XCTAssertEqual(json?["trace"] as? String, "mock-trace")
        XCTAssertTrue(json?["missing"] is NSNull)
        let data = json?["data"] as? [String: Any]
        XCTAssertEqual((data?["items"] as? [[String: Any]])?.first?["id"] as? String, "fetch-1")
        let text = try await runtime.call("inspectText") as? [String: Any]
        XCTAssertEqual(text?["ok"] as? Bool, true)
        XCTAssertEqual(text?["bodyIsPromise"] as? Bool, true)
        XCTAssertEqual(text?["text"] as? String, "plain 音乐")
        XCTAssertEqual(MockHTTPProtocol.recordedRequests.count, 2)
    }

    func testFetchHTTPErrorResolvesAndInvalidJSONRejectsAsynchronously() async throws {
        MockHTTPProtocol.handler = { _ in (503, ["Content-Type": "text/plain"], Data("maintenance".utf8)) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try JSPluginRuntime(scriptSource: #"""
            module.exports = {
                id: "fetch-errors",
                allowedDomains: ["fetch.example.test"],
                async search(mode) {
                    const response = await fetch("https://fetch.example.test/unavailable");
                    const result = { ok: response.ok, status: response.status };
                    if (mode === "text") {
                        result.text = await response.text();
                        return result;
                    }
                    let pending;
                    try { pending = response.json(); }
                    catch (_) { result.synchronousThrow = true; return result; }
                    result.synchronousThrow = false;
                    result.bodyIsPromise = typeof pending.then === "function";
                    try { await pending; result.rejected = false; }
                    catch (error) { result.rejected = true; result.errorName = error.name; }
                    return result;
                }
            };
            """#, session: session, secrets: InMemorySecretStore())
        defer { runtime.invalidate() }

        let text = try await runtime.call("search", args: ["text"]) as? [String: Any]
        XCTAssertEqual(text?["ok"] as? Bool, false)
        XCTAssertEqual(text?["status"] as? Int, 503)
        XCTAssertEqual(text?["text"] as? String, "maintenance")
        let json = try await runtime.call("search", args: ["json"]) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, false)
        XCTAssertEqual(json?["status"] as? Int, 503)
        XCTAssertEqual(json?["synchronousThrow"] as? Bool, false)
        XCTAssertEqual(json?["bodyIsPromise"] as? Bool, true)
        XCTAssertEqual(json?["rejected"] as? Bool, true)
        XCTAssertEqual(json?["errorName"] as? String, "SyntaxError")
    }

    func testFetchRejectsTransportFailure() async throws {
        MockHTTPProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let runtime = try JSPluginRuntime(scriptSource: #"""
            module.exports = {
                id: "fetch-transport-error",
                allowedDomains: ["fetch.example.test"],
                search() {
                    return fetch("https://fetch.example.test/offline").then(
                        () => ({ resolved: true }),
                        error => ({ resolved: false, isError: error instanceof Error, message: error.message })
                    );
                }
            };
            """#, session: session, secrets: InMemorySecretStore())
        defer { runtime.invalidate() }

        let result = try await runtime.call("search") as? [String: Any]
        XCTAssertEqual(result?["resolved"] as? Bool, false)
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertFalse((result?["message"] as? String ?? "").isEmpty)
        XCTAssertEqual(MockHTTPProtocol.recordedRequests.count, 1)
    }

    func testFetchNetworkAndDomainPolicyRejectionsNeverStartRequests() async throws {
        MockHTTPProtocol.handler = { _ in
            XCTFail("A rejected fetch must never reach URLSession's transport")
            return (200, [:], Data("{}".utf8))
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let cases = [
            ("https://fetch.example.test/catalog", false),
            ("https://blocked.example.test/catalog", true),
            ("file:///private/catalog", true)
        ]
        for (url, enabled) in cases {
            let runtime = try JSPluginRuntime(scriptSource: #"""
                module.exports = {
                    id: "fetch-gating",
                    allowedDomains: ["fetch.example.test"],
                    async search(url) { return (await fetch(url)).json(); }
                };
                """#, session: session, secrets: InMemorySecretStore(), networkAllowed: { enabled })
            defer { runtime.invalidate() }
            do {
                _ = try await runtime.call("search", args: [url])
                XCTFail("Fetch must reject \(url) when networkAllowed is \(enabled)")
            } catch let error as PlaybackError {
                XCTAssertFalse(enabled)
                XCTAssertEqual(error, .networkDisabled)
            } catch {
                XCTAssertTrue(enabled, "Disabled networking must preserve PlaybackError.networkDisabled")
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(MockHTTPProtocol.recordedRequests.isEmpty)
    }

    func testExplicitEmptySearchTypesDisableSearchButKeepCollectionImport() async throws {
        let source = try JSPluginSource(scriptSource: #"""
            module.exports = {
                id: "collection-only",
                supportedSearchType: [],
                search() {},
                importMusicSheet(url) {
                    return { data: [{ id: "collection-1", title: "Imported Collection", artist: "Mock", sourceURL: url }] };
                },
                getMediaSource(item) { return { url: "https://collection.example.test/" + item.id }; }
            };
            """#, secrets: InMemorySecretStore(), networkAllowed: { false })
        defer { source.runtime.invalidate() }

        XCTAssertFalse(source.manifest.capabilities.hasSearch)
        XCTAssertFalse(source.descriptor.supportsSearch)
        XCTAssertTrue(source.manifest.capabilities.supportedSearchTypes.isEmpty)
        XCTAssertTrue(source.manifest.capabilities.hasResolveQuery)
        XCTAssertTrue(source.manifest.capabilities.hasGetMediaSource)
        XCTAssertTrue(source.canHandleQuery("https://collection.example.test/sheet/1"))
        let search = try await source.search(SearchRequest(query: "unused"))
        XCTAssertTrue(search.isEmpty)
        let tracks = try await source.resolveQuery("https://collection.example.test/sheet/1")
        XCTAssertEqual(tracks.map(\.externalID), ["collection-1"])
        XCTAssertEqual(tracks.first?.title, "Imported Collection")
    }

    func testMissingAndNonemptySearchTypesRetainSearchCapability() async throws {
        for declaration in ["", "supportedSearchType: [\"music\"],"] {
            let source = try JSPluginSource(scriptSource: """
                module.exports = {
                    id: "search-types-compat",
                    \(declaration)
                    search(query, page, type) { return [{ id: type, title: query, artist: "Mock" }]; }
                };
                """, secrets: InMemorySecretStore(), networkAllowed: { false })
            defer { source.runtime.invalidate() }
            XCTAssertTrue(source.manifest.capabilities.hasSearch)
            XCTAssertTrue(source.descriptor.supportsSearch)
            let tracks = try await source.search(SearchRequest(query: "Available"))
            XCTAssertEqual(tracks.map(\.externalID), ["music"])
        }
    }

    func testTSCompiledMusicFreeNavidromePattern() async throws {
        let script = #"""
        "use strict";
        Object.defineProperty(exports, "__esModule", { value: true });
        const axios_1 = require("axios");
        const CryptoJs = require("crypto-js");
        async function httpGet(urlPath, params) {
            const userVariables = (env === null || env === void 0 ? void 0 : env.getUserVariables()) ?? {};
            let { url, username, password } = userVariables;
            if (!(url && username && password)) return null;
            const salt = "abcd1234";
            const preParams = {
                u: username,
                s: salt,
                t: CryptoJs.MD5(`${password}${salt}`).toString(CryptoJs.enc.Hex),
                c: "MusicFree",
                v: "1.14.1",
                f: "json",
            };
            return (await axios_1.default.get(`${url}/rest/${urlPath}`, {
                params: Object.assign({}, preParams, params),
            })).data;
        }
        module.exports = {
            platform: "NavidromeCompat",
            version: "0.0.1",
            userVariables: [
                { key: "url", name: "地址" },
                { key: "username", name: "用户名" },
                { key: "password", name: "密码", type: "password" },
            ],
            async search(query, page, type) {
                if (type !== "music") return { isEnd: true, data: [] };
                const data = await httpGet("search2", { query, songCount: 25, songOffset: (page - 1) * 25 });
                const songs = (data && data["subsonic-response"] && data["subsonic-response"].searchResult2.song) || [];
                return { isEnd: true, data: songs.map(s => ({ id: s.id, title: s.title, artist: s.artist, duration: s.duration })) };
            },
            getMediaSource(musicItem, quality) {
                const { url, username, password } = env.getUserVariables();
                const urlObj = new URL(`${url}/rest/stream`);
                urlObj.searchParams.append("u", username);
                urlObj.searchParams.append("s", "salt99");
                urlObj.searchParams.append("t", CryptoJs.MD5(`${password}salt99`).toString(CryptoJs.enc.Hex));
                urlObj.searchParams.append("q", quality);
                urlObj.searchParams.append("id", musicItem.id);
                return { url: urlObj.toString() };
            }
        };
        """#

        MockHTTPProtocol.handler = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("/rest/search2") {
                return (200, [:], Data(#"""
                {
                  "subsonic-response": {
                    "status": "ok",
                    "searchResult2": {
                      "song": [
                        { "id": "nd-1", "title": "Blue in Green", "artist": "Miles Davis", "duration": 327 }
                      ]
                    }
                  }
                }
                """#.utf8))
            }
            return (404, [:], Data())
        }

        let secrets = InMemorySecretStore()
        let source = try JSPluginSource(scriptSource: script, fallbackID: "navidrome-compat", session: makeSession(), secrets: secrets)
        XCTAssertEqual(source.manifest.userVariables.count, 3)
        XCTAssertTrue(source.manifest.userVariables[2].isSecret)

        source.runtime.saveUserVariables([
            "url": "https://navi.example.com",
            "username": "alice",
            "password": "secret",
        ])
        XCTAssertEqual(source.runtime.userVariableValues()["username"], "alice")

        let tracks = try await source.search(SearchRequest(query: "Blue", limit: 25))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.externalID, "nd-1")
        XCTAssertEqual(tracks.first?.artist, "Miles Davis")

        let rawMedia = try await source.runtime.call("getMediaSource", args: [["id": "nd-1"], "high"]) as? [String: Any]
        let streamURL = try XCTUnwrap(rawMedia?["url"] as? String)
        XCTAssertTrue(streamURL.contains("https://navi.example.com/rest/stream"))
        XCTAssertTrue(streamURL.contains("u=alice"))
        XCTAssertTrue(streamURL.contains("id=nd-1"))
    }

    func testCheerioHTMLAndHeDecoderPattern() async throws {
        // 参考 maotoumao/MusicFreePlugins `geciwang` + `geciqianxun` 编译输出结构
        let script = #"""
        "use strict";
        Object.defineProperty(exports, "__esModule", { value: true });
        const axios_1 = require("axios");
        const cheerio_1 = require("cheerio");
        const he = require("he");
        async function search(query, page, type) {
            const html = (await axios_1.default.get("https://lyrics.example.com/search", { params: { name: query } })).data;
            const $ = (0, cheerio_1.load)(html);
            const items = $(".table.table-striped > tbody").children("tr");
            const data = items.map((index, el) => {
                const tds = $(el).children();
                const link = $(tds.get(3)).children("a");
                return {
                    title: he.decode($(tds.get(0)).text().trim()),
                    artist: $(tds.get(1)).text().trim(),
                    album: $(tds.get(2)).text().trim(),
                    id: link.attr("href")
                };
            }).toArray();
            return { isEnd: true, data };
        }
        async function getLyric(musicItem) {
            const html = (await axios_1.default.get(musicItem.id)).data;
            const $ = (0, cheerio_1.load)(html);
            const tag = $(".resultWrap").children().first().prop("tagName");
            return { rawLrc: $("div#lyrics").text().trim() + "\n[00:10.00]TAG:" + tag };
        }
        module.exports = {
            platform: "LyricsScraperCompat",
            version: "0.0.1",
            supportedSearchType: ["lyric"],
            search,
            getLyric
        };
        """#

        MockHTTPProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/search") {
                let html = """
                <html><body>
                <table class="table table-striped"><tbody>
                  <tr><td>Night &amp; Day</td><td>Cole Porter</td><td>Standards</td><td><a href="https://lyrics.example.com/song/42">Go</a></td></tr>
                </tbody></table>
                </body></html>
                """
                return (200, ["Content-Type": "text/html"], Data(html.utf8))
            }
            if url.contains("/song/42") {
                let html = """
                <div class="resultWrap"><dl><dt><a>OK</a></dt></dl></div>
                <div id="lyrics">[00:01.00]Like the beat beat beat of the tom-tom</div>
                """
                return (200, ["Content-Type": "text/html"], Data(html.utf8))
            }
            return (404, [:], Data())
        }

        let source = try JSPluginSource(scriptSource: script, session: makeSession(), secrets: InMemorySecretStore())
        let tracks = try await source.search(SearchRequest(query: "Night"))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "Night & Day")
        XCTAssertEqual(tracks.first?.externalID, "https://lyrics.example.com/song/42")

        let lrc = try await source.lyrics(for: try XCTUnwrap(tracks.first))
        XCTAssertEqual(lrc?.lines.first?.text, "Like the beat beat beat of the tom-tom")
        XCTAssertEqual(lrc?.lines.last?.text, "TAG:DL")
    }

    func testCryptoJSHmacSHA1AESDayjsQsBigIntPattern() async throws {
        let script = #"""
        const CryptoJS = require("crypto-js");
        const dayjs = require("dayjs");
        const qs = require("qs");
        const bigInt = require("big-integer");
        const axios = require("axios");

        const api = axios.create({ baseURL: "https://crypto.example.com/v1", headers: { "X-Client": "FLOW" } });

        module.exports = {
            platform: "CryptoCompat",
            allowedDomains: ["crypto.example.com"],
            async search(query) {
                const key = CryptoJS.enc.Utf8.parse("1234567890abcdef");
                const iv = CryptoJS.enc.Utf8.parse("abcdef1234567890");
                const enc = CryptoJS.AES.encrypt(query, key, { iv, mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 });
                const cipherB64 = enc.toString();
                const dec = CryptoJS.AES.decrypt(cipherB64, key, { iv, mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 }).toString(CryptoJS.enc.Utf8);
                const sig = CryptoJS.HmacSHA1(dec + "|" + dayjs(1700000000000).format("YYYY-MM-DD"), "secret&").toString(CryptoJS.enc.Base64);
                const rsa = bigInt("5").modPow("3", "13").toString();
                const q = qs.stringify({ sig, rsa, tags: ["a", "b"] }, { arrayFormat: "brackets" });
                const res = await api.get("/find?" + q);
                return { isEnd: true, data: res.data.items };
            },
            async getMediaSource(item, quality) {
                return { url: "https://crypto.example.com/stream/" + item.id + ".mp3", quality };
            }
        };
        """#

        MockHTTPProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Client"), "FLOW")
            XCTAssertTrue(url.contains("rsa=8"))
            XCTAssertTrue(url.contains("sig="))
            return (200, [:], Data(#"{"items":[{"id":"c1","title":"DecryptedOK","artist":"Tester","duration":"03:05"}]}"#.utf8))
        }

        let source = try JSPluginSource(scriptSource: script, session: makeSession(), secrets: InMemorySecretStore())
        let tracks = try await source.search(SearchRequest(query: "hello-flow"))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "DecryptedOK")
        XCTAssertEqual(tracks.first?.duration, 185)
    }

    func testWebDAVCommonJSPluginPattern() async throws {
        let script = #"""
        "use strict";
        Object.defineProperty(exports, "__esModule", { value: true });
        const webdav_1 = require("webdav");
        function getClient() {
            const { url, username, password } = env.getUserVariables() ?? {};
            return (0, webdav_1.createClient)(url, { authType: webdav_1.AuthType.Password, username, password });
        }
        module.exports = {
            platform: "WebDAVCompat",
            async search(query) {
                const client = getClient();
                const items = (await client.getDirectoryContents("/music")).filter(it => it.type === "file" && it.mime.startsWith("audio"));
                return { isEnd: true, data: items.filter(it => it.basename.includes(query)).map(it => ({ id: it.filename, title: it.basename, artist: "NAS" })) };
            },
            getMediaSource(item) {
                return { url: getClient().getFileDownloadLink(item.id) };
            }
        };
        """#

        let propfindXML = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/music/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/music/Nocturne.flac</D:href>
            <D:propstat><D:prop><D:getcontentlength>2048000</D:getcontentlength></D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """#

        MockHTTPProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "PROPFIND")
            XCTAssertTrue((req.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Basic "))
            return (207, ["Content-Type": "application/xml"], Data(propfindXML.utf8))
        }

        let source = try JSPluginSource(scriptSource: script, session: makeSession(), secrets: InMemorySecretStore())
        source.runtime.saveUserVariables(["url": "https://nas.example.com", "username": "u1", "password": "p1"])
        let hits = try await source.search(SearchRequest(query: "Nocturne"))
        XCTAssertEqual(hits.map(\.externalID), ["/music/Nocturne.flac"])
        XCTAssertEqual(hits.first?.title, "Nocturne.flac")
    }

    func testLXMusicCustomScriptCompatibility() async throws {
        let lxScript = #"""
        /**
         * @name LX Demo Compat Source
         * @description LX custom source verification
         * @version 1.2.0
         * @author LXCommunity
         */
        const { EVENT_NAMES, request, on, send } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source, action, info }, cb) => {
            if (action === "musicUrl") {
                request(`https://lx.example.com/url?id=${info.musicInfo.id}&q=${info.type}`, (err, resp) => {
                    if (err) return cb(err);
                    cb(null, resp.body.playUrl);
                });
            } else if (action === "lyric") {
                cb(null, { rawLrc: "[00:02.00]LX Lyric Line" });
            }
        });
        send(EVENT_NAMES.inited, {
            sources: {
                wy: { name: "WY", type: "music", actions: ["musicUrl", "lyric"], qualitys: ["128k", "320k", "flac"] }
            }
        });
        """#

        MockHTTPProtocol.handler = { req in
            if req.url?.absoluteString.contains("/url") == true {
                return (200, [:], Data(#"{"playUrl":"https://cdn.example.com/lx-track.flac"}"#.utf8))
            }
            return (404, [:], Data())
        }

        let store = ImportedSourceStore(directory: tempDir, session: makeSession(), secrets: InMemorySecretStore())
        let lxURL = tempDir.appendingPathComponent("lx-demo.js")
        try lxScript.write(to: lxURL, atomically: true, encoding: .utf8)

        let imported = try await store.importFromURL(lxURL)
        guard case .js(let jsSource) = imported.first else {
            return XCTFail("应成功导入 LX 格式脚本")
        }
        XCTAssertEqual(jsSource.manifest.displayName, "LX Demo Compat Source")
        XCTAssertEqual(jsSource.manifest.version, "1.2.0")
        XCTAssertEqual(jsSource.manifest.author, "LXCommunity")
        XCTAssertTrue(jsSource.manifest.capabilities.isLXScript)

        let rawURL = try await jsSource.runtime.call("__lx.musicUrl", args: [["id": "m1"], "flac", "wy"]) as? [String: Any]
        XCTAssertEqual(rawURL?["url"] as? String, "https://cdn.example.com/lx-track.flac")

        let track = Track(sourceID: jsSource.descriptor.id, externalID: "m1", title: "Demo", artist: "Artist", duration: 180)
        let lrc = try await jsSource.lyrics(for: track)
        XCTAssertEqual(lrc?.lines.first?.text, "LX Lyric Line")
    }

    func testJSONMultiSchemaAudiusRadioArchiveAndJSONP() async throws {
        // 1. 测试 RadioBrowser 根数组 + JSONP 响应 + direct resolve + 回退路径
        let examplesDir = RepositoryRoot.locate().appendingPathComponent("external-plugins/examples")
        for filename in ["audius.flow.json", "radiobrowser.flow.json", "internetarchive.flow.json"] {
            let data = try Data(contentsOf: examplesDir.appendingPathComponent(filename))
            let def = try JSONDecoder().decode(JSONTemplateDefinition.self, from: data)
            let source = JSONTemplateSource(definition: def, session: makeSession())
            XCTAssertNoThrow(try source.validateDefinition(), "\(filename) 应通过模板校验")
        }

        MockHTTPProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("api.audius.co/v1/tracks/trending") {
                return (200, [:], Data(#"""
                callback({"data":[{"id":"a1","title":"Sunset","duration":180,"user":{"name":"Nova"},"artwork":{"480x480":"https://cdn.audius.co/art.jpg"}}]});
                """#.utf8))
            }
            if url.contains("de1.api.radio-browser.info/json/stations/search") {
                return (200, [:], Data(#"""
                [{"stationuuid":"rb1","name":"Cool Jazz FM","country":"FR","codec":"AAC","favicon":"https://radio.example.com/icon.png","url_resolved":"https://stream.example.com/jazz.aac"}]
                """#.utf8))
            }
            return (404, [:], Data())
        }

        let audiusData = try Data(contentsOf: examplesDir.appendingPathComponent("audius.flow.json"))
        let audius = JSONTemplateSource(definition: try JSONDecoder().decode(JSONTemplateDefinition.self, from: audiusData),
                                        session: makeSession())
        let audiusHits = try await audius.discoverTracks(limit: 5, progress: nil)
        XCTAssertEqual(audiusHits.first?.externalID, "a1")
        XCTAssertEqual(audiusHits.first?.artist, "Nova")
        XCTAssertEqual(audiusHits.first?.artwork?.media, .remote(URL(string: "https://cdn.audius.co/art.jpg")!))

        let rbData = try Data(contentsOf: examplesDir.appendingPathComponent("radiobrowser.flow.json"))
        let rb = JSONTemplateSource(definition: try JSONDecoder().decode(JSONTemplateDefinition.self, from: rbData),
                                    session: makeSession())
        let rbHits = try await rb.search(SearchRequest(query: "jazz & blues"))
        XCTAssertEqual(rbHits.first?.externalID, "rb1")
        XCTAssertEqual(rbHits.first?.artist, "FR")
        XCTAssertTrue(MockHTTPProtocol.recordedRequests.last?.url?.absoluteString.contains("jazz%20%26%20blues") == true)
    }

    func testSubscriptionURLNormalizationAndPartialResilience() async throws {
        // GitHub blob -> raw 重写与空格 URL 转义
        XCTAssertEqual(
            SourceDomainPolicy.normalizeImportURL("https://github.com/maotoumao/MusicFreePlugins/blob/master/plugins.json")?.absoluteString,
            "https://raw.githubusercontent.com/maotoumao/MusicFreePlugins/master/plugins.json"
        )
        XCTAssertEqual(
            SourceDomainPolicy.normalizeImportURL("https://cdn.jsdelivr.net/gh/qwerwhr/musicfree-plugins@main/QQ Vip.js")?.absoluteString,
            "https://cdn.jsdelivr.net/gh/qwerwhr/musicfree-plugins@main/QQ%20Vip.js"
        )

        MockHTTPProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/sub.json") {
                return (200, [:], Data(#"""
                {
                  "desc": "Community hub",
                  "plugins": [
                    { "name": "Dead Entry", "url": "https://hub.example.com/missing.js" },
                    { "name": "Valid Space Plugin", "url": "https://hub.example.com/My Source.js" }
                  ]
                }
                """#.utf8))
            }
            if url.contains("/My%20Source.js") {
                return (200, [:], Data(#"""
                module.exports = {
                    platform: "HubOK",
                    async search() { return []; },
                    async getMediaSource() { return { url: "https://hub.example.com/1.mp3" }; }
                };
                """#.utf8))
            }
            if url.contains("/server-array.json") {
                return (200, [:], Data(#"""
                [{ "schema": "flow-server-v1", "kind": "opensubsonic", "displayName": "Home Navi", "baseURL": "https://navi.example.com", "username": "u" }]
                """#.utf8))
            }
            return (404, [:], Data())
        }

        let store = ImportedSourceStore(directory: tempDir, session: makeSession(), secrets: InMemorySecretStore())
        // 即使订阅内第一项 404，也应继续导入第二项（含空格的脚本 URL）
        let imported = try await store.importFromURL(URL(string: "https://hub.example.com/sub.json")!)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.sourceID.rawValue, "js-hubok")

        let importedServers = try await store.importFromURL(URL(string: "https://hub.example.com/server-array.json")!)
        if case .server(let cfg, _)? = importedServers.first {
            XCTAssertEqual(cfg.kind, .openSubsonic)
            XCTAssertEqual(cfg.displayName, "Home Navi")
        } else {
            XCTFail("应能从 JSON 预设数组解析 OpenSubsonic 服务器配置")
        }
    }

    @MainActor
    func testParcelMultipleExportsAndDirectItemURLFallbackAndSourceManagerVars() async throws {
        // 1. Parcel 多导出 __esModule（参考 5sing.js）+ 省略 getMediaSource 直接用 track.url（参考 suno / GitCode）
        let sampleAudio = try Data(contentsOf: TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("audio"), name: "s.m4a", seconds: 2))
        let parcelScript = #"""
        Object.defineProperty(exports, "__esModule", { value: true });
        Object.defineProperty(exports, "pageSize", { get: () => 20, enumerable: true });
        Object.defineProperty(exports, "headers", { get: () => ({}), enumerable: true });
        Object.defineProperty(exports, "default", {
            get: () => ({
                platform: "DirectFeedCompat",
                userVariables: [{ key: "host", name: "Host", hint: "https://..." }],
                async search(query) {
                    const vars = env.getUserVariables();
                    const host = vars.host || "https://feed.example.com";
                    return {
                        isEnd: true,
                        data: [{ id: "df1", title: query, artist: "Indie", url: host + "/track.m4a" }]
                    };
                }
            }),
            enumerable: true
        });
        """#

        MockHTTPProtocol.handler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://cdn.direct.test/track.m4a")
            return (200, ["Content-Length": "\(sampleAudio.count)"], sampleAudio)
        }

        let app = try ContainerBuilder.make(.testing(inMemory: true))
        await app.settings.setEnableNetwork(true)
        let scriptFile = tempDir.appendingPathComponent("parcel-direct.js")
        try parcelScript.write(to: scriptFile, atomically: true, encoding: .utf8)

        let importedList = try await app.sourceManager.importSources(from: scriptFile)
        XCTAssertEqual(importedList.count, 1)
        let sourceID = try XCTUnwrap(importedList.first?.id)
        XCTAssertEqual(app.sourceManager.userVariableSpecs(for: sourceID).map(\.key), ["host"])

        app.sourceManager.updateJSPluginVariables(sourceID: sourceID, values: ["host": "https://cdn.direct.test"])
        XCTAssertEqual(app.sourceManager.userVariableValues(for: sourceID)["host"], "https://cdn.direct.test")

        let hits = try await app.sourceManager.search(query: "Morning", aggregate: false)
        XCTAssertEqual(hits.first?.title, "Morning")
        XCTAssertEqual(hits.first?.sourceID, sourceID)
        app.sourceManager.removeConfiguredSource(sourceID)

        // verify direct item.url fallback resolves and caches playable audio through isolated MediaAudioCache
        let isolatedCache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache"),
            offlineDirectory: tempDir.appendingPathComponent("offline"),
            session: makeSession()
        )
        let directProvider = try JSPluginSource(
            scriptSource: parcelScript,
            session: makeSession(),
            secrets: InMemorySecretStore(),
            audioCache: isolatedCache
        )
        directProvider.runtime.saveUserVariables(["host": "https://cdn.direct.test"])
        let directHits = try await directProvider.search(SearchRequest(query: "Morning"))
        let directTrack = try XCTUnwrap(directHits.first)
        let session = try await directProvider.makeSession(for: directTrack)
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
    }

    func testOAuth1SignatureAndParamsCompat() async throws {
        let script = #"""
        const axios = require("axios");
        const CryptoJS = require("crypto-js");

        function _encode(e) {
            return e ? encodeURIComponent(e).replace(/[!'()]/g, escape).replace(/\*/g, "%2A") : "";
        }
        function _decode(e) { return e ? decodeURIComponent(e) : ""; }
        function u(e) { (this._parameters = {}), this._loadParameters(e || {}); }
        u.prototype = {
            _loadParameters: function(e) { if ("object" == typeof e) this._loadParametersFromObject(e); },
            _loadParametersFromObject: function(e) {
                for (var n in e) if (e.hasOwnProperty(n)) {
                    var r = this._getStringFromParameter(e[n]);
                    this._addParameter(n, r);
                }
            },
            _getStringFromParameter: function(e) {
                var n = e || "";
                ("number" == typeof e || "boolean" == typeof e) && (n = e.toString());
                return n;
            },
            _addParameter: function(e, n) { (this._parameters[e] || (this._parameters[e] = [])).push(n); },
            get: function() { return this._parameters; }
        };
        function getNormalizedParams(parameters) {
            const sortedKeys = [];
            const normalizedParameters = [];
            for (let e in parameters) sortedKeys.push(_encode(e));
            sortedKeys.sort();
            for (let idx = 0; idx < sortedKeys.length; idx++) {
                const e = sortedKeys[idx];
                const i = _decode(e), a = parameters[i];
                a.sort();
                for (let n = 0; n < a.length; n++) normalizedParameters.push(e + "=" + _encode(a[n]));
            }
            return normalizedParameters.join("&");
        }
        function getSignature(method, urlPath, params, secret) {
            const r = new u(params).get();
            const l = _encode(method.toUpperCase()) + "&" + _encode(urlPath) + "&" + _encode(getNormalizedParams(r));
            return CryptoJS.HmacSHA1(l, secret + "&").toString(CryptoJS.enc.Base64);
        }

        module.exports = {
            platform: "OAuth1Compat",
            allowedDomains: ["oauth.example.com"],
            async search(query) {
                const params = {
                    hq: true,
                    oauth_consumer_key: "audiomack-js",
                    oauth_nonce: "FIXEDNONCE123",
                    oauth_signature_method: "HMAC-SHA1",
                    oauth_timestamp: 1795186000,
                    oauth_version: "1.0",
                    q: query,
                    type: "song"
                };
                const url = "https://oauth.example.com/v1/music/trending/page/1";
                const oauth_signature = getSignature("GET", url, params, "f3ac5b086f3eab260520d8e3049561e6");
                const res = await axios.get(url, { params: Object.assign({}, params, { oauth_signature }) });
                return { isEnd: true, data: res.data.results };
            },
            async getMediaSource(item) {
                return { url: "https://oauth.example.com/play/" + item.id + ".mp3" };
            }
        };
        """#

        var capturedQuery: String = ""
        MockHTTPProtocol.handler = { req in
            capturedQuery = req.url?.query(percentEncoded: true) ?? ""
            return (200, [:], Data(#"{"results":[{"id":"t1","title":"OAuthOK","artist":"Tester","duration":120}]}"#.utf8))
        }

        let source = try JSPluginSource(scriptSource: script, session: makeSession(), secrets: InMemorySecretStore())
        let tracks = try await source.search(SearchRequest(query: "a+b/c"))
        XCTAssertEqual(tracks.count, 1)

        // 验证期望 OAuth1 HMAC-SHA1 Base64（与 Swift CryptoKit 对拍）
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0 }
        let normPairs = [
            ("hq", "true"),
            ("oauth_consumer_key", "audiomack-js"),
            ("oauth_nonce", "FIXEDNONCE123"),
            ("oauth_signature_method", "HMAC-SHA1"),
            ("oauth_timestamp", "1795186000"),
            ("oauth_version", "1.0"),
            ("q", "a+b/c"),
            ("type", "song"),
        ].map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        let baseStr = "GET&\(enc("https://oauth.example.com/v1/music/trending/page/1"))&\(enc(normPairs))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(baseStr.utf8),
            using: SymmetricKey(data: Data("f3ac5b086f3eab260520d8e3049561e6&".utf8))
        )
        let expectedSig = Data(mac).base64EncodedString()
        XCTAssertTrue(capturedQuery.contains("hq=true"), "Boolean true 必须序列化为 hq=true，实际 query: \(capturedQuery)")
        XCTAssertTrue(capturedQuery.contains("oauth_timestamp=1795186000"), "整数时间戳不应带 .0，实际 query: \(capturedQuery)")
        XCTAssertTrue(capturedQuery.contains("q=a%2Bb%2Fc"), "RFC3986 query 参数需编码 + / =，实际 query: \(capturedQuery)")
        XCTAssertTrue(capturedQuery.contains("oauth_signature=\(enc(expectedSig))"), "签名不匹配，实际 query: \(capturedQuery)")
    }

    func testAudioContainerSniffingQualityDowngradeAndHLSRouting() async throws {
        // 1. 容器魔数嗅探 + MIME 回退（解决 Navidrome 等无后缀 `/rest/stream` 被误存为 .m4a 导致 AVPlayer -12848 的问题）
        func pad(_ prefix: [UInt8]) -> Data {
            var bytes = prefix
            if bytes.count < 64 { bytes.append(contentsOf: repeatElement(0, count: 64 - bytes.count)) }
            return Data(bytes)
        }
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: pad([0x66, 0x4C, 0x61, 0x43])), "flac")
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: pad([0x49, 0x44, 0x33, 0x03])), "mp3")
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: pad([0xFF, 0xFB, 0x90, 0x64])), "mp3")
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: pad([0xFF, 0xF1, 0x50, 0x80])), "aac")
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: pad([0x4F, 0x67, 0x67, 0x53])), "ogg")
        var opusBytes = [UInt8](pad([0x4F, 0x67, 0x67, 0x53]))
        opusBytes.replaceSubrange(28..<36, with: Array("OpusHead".utf8))
        XCTAssertEqual(MediaAudioCache.sniffAudioExtension(data: Data(opusBytes)), "opus")
        XCTAssertEqual(
            MediaAudioCache.sniffAudioExtension(data: Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])),
            "wav"
        )
        XCTAssertEqual(
            MediaAudioCache.sniffAudioExtension(data: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])),
            "m4a"
        )
        XCTAssertEqual(
            MediaAudioCache.sniffAudioExtension(data: Data(repeating: 0x11, count: 16), mimeType: "audio/mpeg"),
            "mp3"
        )
        XCTAssertEqual(
            MediaAudioCache.sniffAudioExtension(data: Data(repeating: 0x11, count: 16), mimeType: "audio/flac"),
            "flac"
        )

        // 2. 验证 HLS 识别；未装配受控 HLS 加载器时拒绝外网直连降级。
        let hlsURL = try XCTUnwrap(URL(string: "https://hls.example.com/live/master.m3u8?token=abc"))
        let hlsDescriptor = AudioStreamDescriptor(
            cacheKey: "hls_item",
            fileExtension: "m3u8",
            qualityTier: .standard,
            qualityID: 0,
            codec: "hls",
            bandwidth: 128_000,
            sampleRate: 44100,
            isLossless: false,
            url: hlsURL,
            headers: ["Referer": "https://hls.example.com"]
        )
        XCTAssertTrue(hlsDescriptor.isHLSStream)
        let nonHLSDescriptor = AudioStreamDescriptor(
            cacheKey: "mp3_item",
            fileExtension: "mp3",
            qualityTier: .standard,
            qualityID: 0,
            codec: "mp3",
            bandwidth: 320_000,
            sampleRate: 44100,
            isLossless: false,
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/song.mp3"))
        )
        XCTAssertFalse(nonHLSDescriptor.isHLSStream)

        let cache = MediaAudioCache(
            directory: tempDir.appendingPathComponent("cache"),
            offlineDirectory: tempDir.appendingPathComponent("offline"),
            session: makeSession()
        )
        let hlsSource = try JSPluginSource(
            scriptSource: #"""
            module.exports = {
                platform: "HLSRoute",
                allowedDomains: ["hls.example.com"],
                async search(q) { return { isEnd: true, data: [{ id: "h1", title: q, artist: "TV" }] }; },
                async getMediaSource() {
                    return { url: "https://hls.example.com/live/master.m3u8?token=abc", headers: { Referer: "https://hls.example.com" } };
                }
            };
            """#,
            session: makeSession(),
            secrets: InMemorySecretStore(),
            audioCache: cache
        )
        let hlsTracks = try await hlsSource.search(SearchRequest(query: "News"))
        do {
            _ = try await hlsSource.makeSession(for: try XCTUnwrap(hlsTracks.first))
            XCTFail("缺少受控 HLS 加载器时不能退回外网直连")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .sourceUnavailable)
        }
        XCTAssertTrue(MockHTTPProtocol.recordedRequests.isEmpty, "HLS 不应被当成单文件下载")

        // 3. 验证音质降级回退 + 无后缀 `/rest/stream` 端到端下载解码
        let sampleAudio = try Data(contentsOf: TestAudioFixture.makeM4A(in: tempDir.appendingPathComponent("audio"), name: "s.m4a", seconds: 8))
        let script = #"""
        module.exports = {
            platform: "DowngradeCompat",
            allowedDomains: ["stream.example.com"],
            async search(query) {
                return {
                    isEnd: true,
                    data: [{ id: "42", title: query, artist: "Tester", duration: 8 }]
                };
            },
            async getMediaSource(item, quality) {
                if (quality !== "standard") {
                    return null;
                }
                return { url: "https://stream.example.com/rest/stream?id=" + item.id };
            }
        };
        """#

        MockHTTPProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/rest/stream")
            return (
                200,
                ["Content-Type": "audio/mp4", "Content-Length": "\(sampleAudio.count)"],
                sampleAudio
            )
        }

        let source = try JSPluginSource(
            scriptSource: script,
            session: makeSession(),
            secrets: InMemorySecretStore(),
            audioCache: cache
        )
        let hits = try await source.search(SearchRequest(query: "Tone"))
        let track = try XCTUnwrap(hits.first)
        let session = try await source.makeSession(for: track)
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
    }

    func testLiveGitHubMusicFreePluginsAndOpenAPIs() async throws {
        try LiveTestGate.skipUnlessLive("实网 GitHub 与公开开放接口兼容性测试，需设置 SLP_LIVE_TEST=1")

        // 1. 拉取真实 GitHub 仓库插件与社区脚本并直接加载进 JSPluginSource 沙箱
        let urls = [
            ("navidrome", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/navidrome/index.js"),
            ("webdav", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/webdav/index.js"),
            ("geciwang", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/geciwang/index.js"),
            ("geciqianxun", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/geciqianxun/index.js"),
            ("audiomack", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/audiomack/index.js"),
            ("maoerfm", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/maoerfm/index.js"),
            ("suno", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/suno/index.js"),
            ("udio", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/udio/index.js"),
            ("youtube", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/youtube/index.js"),
            ("mf-bili", "https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/bilibili/index.js"),
            ("cctv", "https://github.com/qwerwhr/musicfree-plugins/blob/main/CCTV听音.js"),
            ("gitcode", "https://github.com/qwerwhr/musicfree-plugins/blob/main/GitCode.js"),
            ("5sing", "https://github.com/qwerwhr/musicfree-plugins/blob/main/5sing.js"),
        ]
        for (fallbackID, rawLink) in urls {
            let url = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL(rawLink), "链接归一化失败：\(rawLink)")
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "下载失败：\(rawLink)")
            let script = try XCTUnwrap(String(data: data, encoding: .utf8))
            let source = try JSPluginSource(scriptSource: script, fallbackID: fallbackID, secrets: InMemorySecretStore())
            XCTAssertFalse(source.descriptor.displayName.isEmpty, "插件未识别名称：\(fallbackID)")
        }

        // 2. 验证真实公开开放 API 模板：Audius + RadioBrowser + Internet Archive
        let examplesDir = RepositoryRoot.locate().appendingPathComponent("external-plugins/examples")
        let audiusData = try Data(contentsOf: examplesDir.appendingPathComponent("audius.flow.json"))
        let audius = JSONTemplateSource(definition: try JSONDecoder().decode(JSONTemplateDefinition.self, from: audiusData))
        let audiusTracks = try await audius.discoverTracks(limit: 3, progress: nil)
        XCTAssertFalse(audiusTracks.isEmpty, "Audius 实时榜单应返回曲目")
        let audiusSearch = try await audius.search(SearchRequest(query: "lofi", limit: 2))
        XCTAssertFalse(audiusSearch.isEmpty, "Audius 实时搜索应返回曲目")
        let firstAudius = try XCTUnwrap(audiusTracks.first)
        let audiusSession = try await audius.makeSession(for: firstAudius)
        try await audiusSession.prepare()
        XCTAssertGreaterThan(audiusSession.duration, 0, "Audius 真实音流 prepare 应拿到有效时长")
        await audiusSession.invalidate()

        let rbData = try Data(contentsOf: examplesDir.appendingPathComponent("radiobrowser.flow.json"))
        let rb = JSONTemplateSource(definition: try JSONDecoder().decode(JSONTemplateDefinition.self, from: rbData))
        let rbStations = try await rb.search(SearchRequest(query: "jazz", limit: 3))
        XCTAssertFalse(rbStations.isEmpty, "RadioBrowser 实时搜索应返回电台流")

        let iaData = try Data(contentsOf: examplesDir.appendingPathComponent("internetarchive.flow.json"))
        let ia = JSONTemplateSource(definition: try JSONDecoder().decode(JSONTemplateDefinition.self, from: iaData))
        let iaItems = try await ia.search(SearchRequest(query: "jazz", limit: 2))
        XCTAssertFalse(iaItems.isEmpty, "Internet Archive 实时检索应返回公共音频条目")
    }

    func testLiveGitHubEndToEndSearchDiscoverLyricsAndPlaybackAcrossRepos() async throws {
        try LiveTestGate.skipUnlessLive("实网 GitHub 不同音源端到端搜播/歌词测试，需设置 SLP_LIVE_TEST=1")

        // 源 A1：内置 OpenSubsonic 协议直连 GitHub navidrome/navidrome 官方演示服务 (demo.navidrome.org)
        let naviConfig = ServerSourceConfig(
            id: "live-demo-navidrome",
            kind: .openSubsonic,
            displayName: "Navidrome Demo",
            baseURLString: "https://demo.navidrome.org",
            username: "demo"
        )
        let naviSecrets = InMemorySecretStore()
        try naviSecrets.save("demo", account: naviConfig.passwordAccountKey)
        let openSubsonic = OpenSubsonicSource(config: naviConfig, secrets: naviSecrets)
        try await openSubsonic.testConnection()
        let naviDiscover = try await openSubsonic.discoverTracks(limit: 3, progress: nil)
        XCTAssertFalse(naviDiscover.isEmpty, "demo.navidrome.org 随机发现应返回真实曲目")
        let naviSearch = try await openSubsonic.search(SearchRequest(query: "Trail", limit: 3))
        XCTAssertFalse(naviSearch.isEmpty, "demo.navidrome.org 搜索应命中曲目")
        let subSession = try await openSubsonic.makeSession(for: try XCTUnwrap(naviDiscover.first))
        try await subSession.prepare()
        XCTAssertGreaterThan(subSession.duration, 0, "OpenSubsonic 真实音流应解码成功并拿到时长")
        await subSession.invalidate()

        // 源 A2：GitHub `maotoumao/MusicFreePlugins` 的 Navidrome JS 插件 + userVariables 对接同一真实服务器
        do {
            let naviPluginURL = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL("https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/navidrome/index.js"))
            let (naviJSData, _) = try await URLSession.shared.data(from: naviPluginURL)
            let naviJS = try JSPluginSource(
                scriptSource: try XCTUnwrap(String(data: naviJSData, encoding: .utf8)),
                fallbackID: "navidrome-js",
                secrets: InMemorySecretStore()
            )
            naviJS.runtime.saveUserVariables([
                "url": "https://demo.navidrome.org",
                "username": "demo",
                "password": "demo",
            ])
            let naviJSHits = try await naviJS.search(SearchRequest(query: "Trail", limit: 3))
            XCTAssertFalse(naviJSHits.isEmpty, "GitHub MusicFree Navidrome JS 插件实网搜索应返回曲目")
            let naviJSSession = try await naviJS.makeSession(for: try XCTUnwrap(naviJSHits.first))
            try await naviJSSession.prepare()
            XCTAssertGreaterThan(naviJSSession.duration, 0, "GitHub MusicFree Navidrome JS 插件真实取流解码应成功")
            await naviJSSession.invalidate()
        } catch {
            XCTFail("源 A2 (Navidrome JS) 失败: \(error)")
        }

        // 源 B：GitHub `maotoumao/MusicFreePlugins` 猫耳 FM（验证自动降级 standard 档位与流地址解析；部分曲目为 FairPlay DRM，不绕过 DRM）
        do {
            let maoerURL = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL("https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/maoerfm/index.js"))
            let (maoerData, _) = try await URLSession.shared.data(from: maoerURL)
            let maoerJS = try JSPluginSource(
                scriptSource: try XCTUnwrap(String(data: maoerData, encoding: .utf8)),
                fallbackID: "maoerfm",
                secrets: InMemorySecretStore()
            )
            let maoerHits = try await maoerJS.search(SearchRequest(query: "夜", limit: 5))
            XCTAssertFalse(maoerHits.isEmpty, "GitHub 猫耳FM 插件实网搜索应返回音频条目")
            let maoerFirst = try XCTUnwrap(maoerHits.first)
            // 验证从默认 auto/high 降级到 standard 后能解析到真实流地址（不强行解码加密 DRM skd:// 流）
            let rawHigh = try await maoerJS.runtime.call("getMediaSource", args: [["id": maoerFirst.externalID], "high"])
            XCTAssertNil(rawHigh)
            let rawStandard = try await maoerJS.runtime.call("getMediaSource", args: [["id": maoerFirst.externalID], "standard"]) as? [String: Any]
            let resolvedURL = try XCTUnwrap(rawStandard?["url"] as? String)
            XCTAssertTrue(resolvedURL.hasPrefix("https://"), "猫耳FM 降级 standard 后应返回有效流地址")
        } catch {
            XCTFail("源 B (猫耳FM) 失败: \(error)")
        }

        // 源 C：GitHub `maotoumao/MusicFreePlugins` 歌词网（cheerio HTML 选择器实网抓词）
        do {
            let geciwangURL = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL("https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/geciwang/index.js"))
            let (geciData, _) = try await URLSession.shared.data(from: geciwangURL)
            let geciwangJS = try JSPluginSource(
                scriptSource: try XCTUnwrap(String(data: geciData, encoding: .utf8)),
                fallbackID: "geciwang",
                secrets: InMemorySecretStore()
            )
            let geciHits = try await geciwangJS.search(SearchRequest(query: "夜曲", limit: 5))
            if let firstLyricHit = geciHits.first {
                let lrc = try await geciwangJS.lyrics(for: firstLyricHit)
                XCTAssertNotNil(lrc)
                XCTAssertFalse(lrc?.lines.isEmpty ?? true, "GitHub 歌词网插件经 cheerio 解析应提取到歌词行")
            }
        } catch {
            XCTFail("源 C (歌词网) 失败: \(error)")
        }

        // 源 D：GitHub `qwerwhr/musicfree-plugins` CCTV 听音（recommendSheet -> 曲目 -> 公开 HLS 流真实解码）
        do {
            let cctvURL = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL("https://github.com/qwerwhr/musicfree-plugins/blob/main/CCTV听音.js"))
            let (cctvData, _) = try await URLSession.shared.data(from: cctvURL)
            let cctvJS = try JSPluginSource(
                scriptSource: try XCTUnwrap(String(data: cctvData, encoding: .utf8)),
                fallbackID: "cctv",
                secrets: InMemorySecretStore(),
                hlsAssetBuilder: HLSResourceLoaderBridge.makeAsset
            )
            let cctvTracks = try await cctvJS.discoverTracks(limit: 5, progress: nil)
            XCTAssertFalse(cctvTracks.isEmpty, "GitHub qwerwhr/CCTV听音 经 getRecommendSheetTags/getMusicSheetInfo 发现应返回曲目")
            if let firstCCTV = cctvTracks.first {
                let cctvSession = try await cctvJS.makeSession(for: firstCCTV)
                try await cctvSession.prepare()
                XCTAssertGreaterThan(cctvSession.duration, 0, "GitHub CCTV听音 真实 HLS 流应解码成功并拿到时长")
                await cctvSession.invalidate()
            }
        } catch {
            XCTFail("源 D (CCTV听音) 失败: \(error)")
        }

        // 源 E：GitHub `maotoumao/MusicFreePlugins` Audiomack（验证 CryptoJS HmacSHA1 OAuth 签名 + 榜单与流解析）
        do {
            let amURL = try XCTUnwrap(SourceDomainPolicy.normalizeImportURL("https://github.com/maotoumao/MusicFreePlugins/blob/v0.1/dist/audiomack/index.js"))
            let (amData, _) = try await URLSession.shared.data(from: amURL)
            let amJS = try JSPluginSource(
                scriptSource: try XCTUnwrap(String(data: amData, encoding: .utf8)),
                fallbackID: "audiomack",
                secrets: InMemorySecretStore()
            )
            let amHits = try await amJS.discoverTracks(limit: 3, progress: nil)
            XCTAssertFalse(amHits.isEmpty, "GitHub Audiomack 插件经 HmacSHA1 签名实网发现应返回曲目")
            let amSession = try await amJS.makeSession(for: try XCTUnwrap(amHits.first))
            try await amSession.prepare()
            XCTAssertGreaterThan(amSession.duration, 0, "GitHub Audiomack 插件真实音频流应解码成功")
            await amSession.invalidate()
        } catch {
            XCTFail("源 E (Audiomack) 失败: \(error)")
        }
    }
}
