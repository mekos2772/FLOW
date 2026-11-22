import Foundation
import XCTest
@testable import SpatialLyricsPlayer

/// 验证第三阶段内置标准合规音源：`LocalLibrarySource`、`OpenSubsonicSource`、`WebDAVSource` 及凭据存储隔离。
final class StandardSourcesTests: XCTestCase {

    private final class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
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

    private var tempDir: URL!

    override func setUpWithError() throws {
        StubHTTPProtocol.handler = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-phase3-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubHTTPProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTPProtocol.self]
        return URLSession(configuration: config)
    }

    func testLocalLibraryScansAudioSidecarLrcCoverAndPlays() async throws {
        let folder = tempDir.appendingPathComponent("Albums/Ambient", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let generated = try TestAudioFixture.makeM4A(in: folder)
        let audioURL = folder.appendingPathComponent("Night Drive.m4a")
        try FileManager.default.moveItem(at: generated, to: audioURL)

        let lrcURL = folder.appendingPathComponent("Night Drive.lrc")
        try "[00:01.00]City lights fade out\n[00:04.50]Only the baseline stays".write(
            to: lrcURL, atomically: true, encoding: .utf8
        )
        let coverURL = folder.appendingPathComponent("cover.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: coverURL)

        let suite = "flow.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let local = LocalLibrarySource(defaults: defaults)
        let count = await local.addFolder(folder)
        XCTAssertEqual(count, 1)

        let searched = try await local.search(SearchRequest(query: "Night"))
        XCTAssertEqual(searched.count, 1)
        let track = try XCTUnwrap(searched.first)
        XCTAssertEqual(track.sourceID, .localFile)
        XCTAssertEqual(track.title, "Night Drive")

        let docs = try await local.lyrics(for: track)
        XCTAssertEqual(docs?.lines.count, 2)
        XCTAssertEqual(docs?.lines.first?.text, "City lights fade out")

        let artRef = try XCTUnwrap(track.artwork)
        let artData = try await local.artwork(for: artRef)
        XCTAssertEqual(artData, Data([0xFF, 0xD8, 0xFF, 0xD9]))

        let session = try await local.makeSession(for: track)
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
    }

    func testIndividuallyOpenedFilesPersistRestoreAndSurviveRescan() async throws {
        let audioURL = try TestAudioFixture.makeM4A(in: tempDir, name: "Direct.m4a", seconds: 2)
        let unsupportedURL = tempDir.appendingPathComponent("notes.txt")
        try "not audio".write(to: unsupportedURL, atomically: true, encoding: .utf8)
        let suite = "flow.local.files.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var original: LocalLibrarySource? = LocalLibrarySource(defaults: defaults)
        let added = await original!.addFiles([audioURL, unsupportedURL, audioURL])
        XCTAssertEqual(added.count, 2)
        let track = try XCTUnwrap(added.first)
        XCTAssertNotNil(track.persistentIdentifier)
        XCTAssertTrue(original!.configuredFolderPaths.isEmpty)
        original = nil

        let restored = LocalLibrarySource(defaults: defaults)
        XCTAssertTrue(restored.hasConfiguredLocations, "Persisted files must count as configured before scanning")
        await restored.restoreIfNeeded()
        await restored.restoreIfNeeded()
        let discovered = try await restored.discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(discovered.map(\.identity), [track.identity], "Repeated opens and restores must not duplicate files")
        XCTAssertNotNil(discovered.first?.persistentIdentifier)
        let count = await restored.rescanAllFolders()
        XCTAssertEqual(count, 1, "Folder rescans must preserve individually opened files")
        let searched = try await restored.search(SearchRequest(query: "Direct"))
        XCTAssertEqual(searched.map(\.identity), [track.identity])
        let session = try await restored.makeSession(for: track)
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
    }

    func testFileBookmarkResolvesMovedURLAndPersistsStaleRefresh() async throws {
        let audioURL = try TestAudioFixture.makeM4A(in: tempDir, name: "Before.m4a", seconds: 2)
        let suite = "flow.local.moved.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original: LocalLibrarySource? = LocalLibrarySource(defaults: defaults)
        let added = await original!.addFiles([audioURL])
        let track = try XCTUnwrap(added.first)
        let oldBookmark = try XCTUnwrap(track.persistentIdentifier.flatMap { Data(base64Encoded: $0) })
        original = nil

        let movedURL = tempDir.appendingPathComponent("After.m4a")
        try FileManager.default.moveItem(at: audioURL, to: movedURL)
        try "[00:01.00]Moved sidecar".write(
            to: movedURL.deletingPathExtension().appendingPathExtension("lrc"),
            atomically: true, encoding: .utf8
        )
        var stale = false
        let resolved = try URL(resolvingBookmarkData: oldBookmark,
                               options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertTrue(stale, "Renaming the file should exercise stale bookmark refresh")
        XCTAssertEqual(resolved.standardizedFileURL.path, movedURL.resolvingSymlinksInPath().path)

        let restored = LocalLibrarySource(defaults: defaults)
        let session = try await restored.makeSession(for: track)
        let http = try XCTUnwrap(session as? HTTPStreamPlayerSession)
        XCTAssertEqual(http.stream.url.standardizedFileURL.path, resolved.standardizedFileURL.path,
                       "Playback must use the resolved URL rather than the original external ID")
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
        let lyrics = try await restored.lyrics(for: track)
        XCTAssertEqual(lyrics?.lines.first?.text, "Moved sidecar")

        let data = try XCTUnwrap(defaults.data(forKey: "sources.localLibraryFiles"))
        let bookmarks = try JSONDecoder().decode([String: Data].self, from: data)
        let refreshed = try XCTUnwrap(bookmarks[track.externalID])
        XCTAssertNotEqual(refreshed, oldBookmark)
        var refreshedIsStale = false
        _ = try URL(resolvingBookmarkData: refreshed, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &refreshedIsStale)
        XCTAssertFalse(refreshedIsStale)

        let relaunched = LocalLibrarySource(defaults: defaults)
        let discovered = try await relaunched.discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(discovered.map(\.identity), [track.identity], "Moving a file must preserve its source identity")
        XCTAssertEqual(discovered.first?.persistentIdentifier, refreshed.base64EncodedString())
    }

    func testTrackFileBookmarkRestoresWithoutSavedLibraryIndex() async throws {
        let audioURL = try TestAudioFixture.makeM4A(in: tempDir, name: "Queue.m4a", seconds: 2)
        let suite = "flow.local.queue.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original: LocalLibrarySource? = LocalLibrarySource(defaults: defaults)
        let added = await original!.addFiles([audioURL])
        let track = try XCTUnwrap(added.first)
        original = nil
        defaults.removePersistentDomain(forName: suite)
        let movedURL = tempDir.appendingPathComponent("Moved Queue.m4a")
        try FileManager.default.moveItem(at: audioURL, to: movedURL)

        let restored = LocalLibrarySource(defaults: defaults)
        let session = try await restored.makeSession(for: track)
        let http = try XCTUnwrap(session as? HTTPStreamPlayerSession)
        XCTAssertEqual(http.stream.url.standardizedFileURL.path, movedURL.resolvingSymlinksInPath().path)
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
        XCTAssertTrue(restored.hasConfiguredLocations)
        let discovered = try await LocalLibrarySource(defaults: defaults).discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(discovered.map(\.identity), [track.identity])
    }

    func testFolderBookmarkResolvesAudioAfterFolderMove() async throws {
        let folder = tempDir.appendingPathComponent("Before", isDirectory: true)
        _ = try TestAudioFixture.makeM4A(in: folder, name: "Folder Song.m4a", seconds: 2)
        let suite = "flow.local.folder.move.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original: LocalLibrarySource? = LocalLibrarySource(defaults: defaults)
        _ = await original!.addFolder(folder)
        let tracks = try await original!.search(SearchRequest(query: ""))
        let track = try XCTUnwrap(tracks.first)
        original = nil
        let movedFolder = tempDir.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: movedFolder)

        let restored = LocalLibrarySource(defaults: defaults)
        let session = try await restored.makeSession(for: track)
        let http = try XCTUnwrap(session as? HTTPStreamPlayerSession)
        let expected = movedFolder.appendingPathComponent("Folder Song.m4a").resolvingSymlinksInPath()
        XCTAssertEqual(http.stream.url.standardizedFileURL.path, expected.path,
                       "A folder bookmark must resolve to the audio file inside the moved folder")
        try await session.prepare()
        XCTAssertGreaterThan(session.duration, 0)
        await session.invalidate()
        let folderData = try XCTUnwrap(defaults.data(forKey: "sources.localLibraryFolders"))
        let entries = try JSONDecoder().decode([LocalLibrarySource.FolderEntry].self, from: folderData)
        let bookmark = try XCTUnwrap(entries.first?.bookmarkData)
        var stale = false
        _ = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertFalse(stale)
    }

    func testMissingPersistedFileDoesNotHideOtherFilesOrFolders() async throws {
        let firstURL = try TestAudioFixture.makeM4A(in: tempDir, name: "Keep.m4a", seconds: 2)
        let missingURL = try TestAudioFixture.makeM4A(in: tempDir, name: "Missing.m4a", seconds: 2)
        let folder = tempDir.appendingPathComponent("Album", isDirectory: true)
        _ = try TestAudioFixture.makeM4A(in: folder, name: "Album Song.m4a", seconds: 2)
        let suite = "flow.local.missing.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original: LocalLibrarySource? = LocalLibrarySource(defaults: defaults)
        _ = await original!.addFiles([firstURL, missingURL])
        _ = await original!.addFolder(folder)
        original = nil
        try FileManager.default.removeItem(at: missingURL)

        let restored = LocalLibrarySource(defaults: defaults)
        let tracks = try await restored.discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(Set(tracks.map(\.title)), ["Keep", "Album Song"])
        let data = try XCTUnwrap(defaults.data(forKey: "sources.localLibraryFiles"))
        XCTAssertEqual(try JSONDecoder().decode([String: Data].self, from: data).count, 2,
                       "Temporarily unavailable files should retain their bookmarks")
    }

    @MainActor
    func testLocalProviderPrewarmPromotesPreparedSession() async throws {
        let audioURL = try TestAudioFixture.makeM4A(in: tempDir, seconds: 2)
        let suite = "flow.local.prewarm.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = LocalLibrarySource(defaults: defaults)
        let tracks = await source.addFiles([audioURL])
        let track = try XCTUnwrap(tracks.first)
        let registry = SourceRegistry()
        registry.register(source)
        let coordinator = PlaybackCoordinator(registry: registry)
        XCTAssertTrue(source.supportsGaplessPrewarm)

        coordinator.prewarm(track: track)
        await waitUntil("local provider prewarm is ready") { coordinator.prewarmedTrackID == track.id }
        let duration = try await coordinator.beginLoading(track: track, startAt: 0, preferGaplessTransition: true)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(coordinator.standbyHitCount, 1)
        XCTAssertTrue(coordinator.lastLoadWasGaplessHit)
        await coordinator.teardown()
    }

    @MainActor
    func testWebDAVProviderPrewarmPromotesWithoutDuplicateDownload() async throws {
        let audio = try Data(contentsOf: TestAudioFixture.makeM4A(in: tempDir))
        let secrets = InMemorySecretStore()
        let config = ServerSourceConfig(id: "dav-prewarm", kind: .webDAV,
                                        displayName: "Prewarm DAV",
                                        baseURLString: "https://dav.example.local/music", username: "alice")
        try secrets.save("dav-pass", account: config.passwordAccountKey)
        var audioRequests = 0
        StubHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/music/Next.m4a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Basic \(Data("alice:dav-pass".utf8).base64EncodedString())")
            audioRequests += 1
            return (200, ["Content-Type": "audio/mp4", "Content-Length": "\(audio.count)"], audio)
        }
        let session = makeMockSession()
        let cache = MediaAudioCache(directory: tempDir.appendingPathComponent("dav-cache"), session: session)
        let source = WebDAVSource(config: config, secrets: secrets, session: session, audioCache: cache)
        let registry = SourceRegistry()
        registry.register(source)
        let coordinator = PlaybackCoordinator(registry: registry)
        let track = Track(sourceID: config.sourceID, externalID: "https://dav.example.local/music/Next.m4a",
                          title: "Next", artist: "", duration: 8)
        XCTAssertTrue(source.supportsGaplessPrewarm)

        coordinator.prewarm(track: track)
        await waitUntil("WebDAV provider prewarm is ready") { coordinator.prewarmedTrackID == track.id }
        XCTAssertEqual(audioRequests, 1)
        let duration = try await coordinator.beginLoading(track: track, startAt: 0, preferGaplessTransition: true)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(coordinator.standbyHitCount, 1)
        XCTAssertTrue(coordinator.lastLoadWasGaplessHit)
        XCTAssertEqual(audioRequests, 1, "Promotion must reuse the prepared session")
        await coordinator.teardown()
    }

    func testOpenSubsonicAuthSearchStructuredLyricsAndConfigPersistence() async throws {
        let suite = "flow.subsonic.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let secrets = InMemorySecretStore()
        let config = ServerSourceConfig(
            id: "navidrome-1",
            kind: .openSubsonic,
            displayName: "Home Navidrome",
            baseURLString: "https://music.example.local",
            username: "alice"
        )
        let store = ServerSourceConfigStore(defaults: defaults, secrets: secrets)
        try store.upsert(config, password: "secret-pass")

        // 凭据不能以明文落在 UserDefaults 里。
        let defaultsDump = defaults.persistentDomain(forName: suite)?.description ?? ""
        XCTAssertFalse(defaultsDump.contains("secret-pass"))
        XCTAssertEqual(store.loadAll(), [config])

        var seenEndpoints: [String] = []
        StubHTTPProtocol.handler = { request in
            let url = request.url!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let q = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["u"], "alice")
            XCTAssertEqual(q["v"], "1.16.1")
            XCTAssertFalse((q["t"] ?? "").isEmpty)
            XCTAssertFalse((q["s"] ?? "").isEmpty)
            seenEndpoints.append(url.lastPathComponent)

            switch url.lastPathComponent {
            case "ping.view":
                return (200, [:], Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
            case "search3.view":
                return (200, [:], Data(#"""
                {"subsonic-response":{"status":"ok","searchResult3":{"song":[
                  {"id":"s-101","title":"Aurora","artist":"Nils","album":"Signals","duration":245,"coverArt":"al-9"}
                ]}}}
                """#.utf8))
            case "getRandomSongs.view":
                return (200, [:], Data(#"""
                {"subsonic-response":{"status":"ok","randomSongs":{"song":[
                  {"id":"s-202","title":"Drift","artist":"Kiasmos","duration":300}
                ]}}}
                """#.utf8))
            case "getLyricsBySongId.view":
                return (200, [:], Data(#"""
                {"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[
                  {"synced":true,"lang":"en","line":[{"start":1200,"value":"Northern sky"}]},
                  {"synced":true,"lang":"zh","line":[{"start":1200,"value":"北方夜空"}]}
                ]}}}
                """#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let source = OpenSubsonicSource(config: config, secrets: secrets, session: makeMockSession())
        try await source.testConnection()

        let tracks = try await source.search(SearchRequest(query: "Aurora"))
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.title, "Aurora")
        XCTAssertEqual(track.album, "Signals")

        let lyrics = try await source.lyrics(for: track)
        XCTAssertEqual(lyrics?.lines.first?.text, "Northern sky")
        XCTAssertEqual(lyrics?.lines.first?.translation, "北方夜空")
        XCTAssertEqual(lyrics?.lines.first?.start ?? 0, 1.2, accuracy: 0.01)

        let discovered = try await source.discoverTracks(limit: 10, progress: nil)
        XCTAssertEqual(discovered.first?.externalID, "s-202")
        XCTAssertTrue(seenEndpoints.contains("ping.view"))
    }

    func testWebDAVPropfindDiscoveryLrcAndBasicAuth() async throws {
        let secrets = InMemorySecretStore()
        let config = ServerSourceConfig(
            id: "nas-dav",
            kind: .webDAV,
            displayName: "Synology NAS",
            baseURLString: "https://nas.example.local/music",
            username: "alice"
        )
        try secrets.save("dav-pass", account: config.passwordAccountKey)

        var sawBasicAuth = false
        StubHTTPProtocol.handler = { request in
            if let auth = request.value(forHTTPHeaderField: "Authorization"),
               auth == "Basic \(Data("alice:dav-pass".utf8).base64EncodedString())" {
                sawBasicAuth = true
            }
            if request.httpMethod == "PROPFIND" {
                let xml = """
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response>
                    <D:href>/music/</D:href>
                    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
                  </D:response>
                  <D:response>
                    <D:href>/music/Ryuichi%20-%20Solitude.flac</D:href>
                    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
                  </D:response>
                  <D:response>
                    <D:href>/music/Ryuichi%20-%20Solitude.lrc</D:href>
                    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
                  </D:response>
                  <D:response>
                    <D:href>/music/cover.jpg</D:href>
                    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
                  </D:response>
                </D:multistatus>
                """
                return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
            }
            if request.url?.lastPathComponent == "Ryuichi - Solitude.lrc" {
                return (200, [:], Data("[00:05.00]Quiet piano".utf8))
            }
            return (404, [:], Data())
        }

        let dav = WebDAVSource(config: config, secrets: secrets, session: makeMockSession())
        let tracks = try await dav.discoverTracks(limit: 20, progress: nil)
        XCTAssertTrue(sawBasicAuth)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.artist, "Ryuichi")
        XCTAssertEqual(track.title, "Solitude")
        XCTAssertNotNil(track.artwork)

        let docs = try await dav.lyrics(for: track)
        XCTAssertEqual(docs?.lines.first?.text, "Quiet piano")
    }
}
