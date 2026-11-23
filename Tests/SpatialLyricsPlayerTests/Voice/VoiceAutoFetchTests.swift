import CryptoKit
import XCTest
@testable import SpatialLyricsPlayer

/// 各处"自动获取"的行为：转换好的音色包自动导入、一键补齐底座模型、GitHub 上的 LFS 模型、转换命令。
final class VoiceAutoFetchTests: XCTestCase {
    private var tempDirs: [URL] = []
    private var userDefaultsSuites: [String] = []

    override func tearDown() {
        MockVoiceURLProtocol.reset()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        for suite in userDefaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-autofetch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "VoiceAutoFetchTests-\(UUID().uuidString)"
        userDefaultsSuites.append(suiteName)
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    @MainActor
    private func makeManager(root: URL, defaults: UserDefaults, session: URLSession = .shared) async -> VoiceManager {
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        await settings.setEnableNetwork(true)
        return VoiceManager(
            settings: settings,
            packStore: VoicePackStore(packsRoot: root.appendingPathComponent("Packs", isDirectory: true)),
            cache: VoiceCacheManager(rootURL: root),
            assets: VoiceModelAssetsManager(voiceRoot: root, session: session),
            presetStore: VoicePresetStore(directory: root),
            discovery: VoiceModelDiscovery(session: session)
        )
    }

    /// 在"下载目录"里放一个转换好的音色包（`pack.json` 带模型 SHA256，和转换工具的输出一致）。
    private func writePreparedPack(_ item: CuratedVoice, model: Data, in directory: URL) throws {
        let packDir = CuratedVoiceCatalog.localPackURL(for: item, in: directory)
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try model.write(to: packDir.appendingPathComponent("model.onnx"))
        let sha = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
        let meta: [String: Any] = ["name": item.displayName, "modelFile": "model.onnx", "onnxSha256": sha]
        try JSONSerialization.data(withJSONObject: meta).write(to: packDir.appendingPathComponent("pack.json"))
    }

    // MARK: - 转换好的音色包自动导入

    @MainActor
    func testAutoImportKeepsCurrentVoiceAndNeverBringsBackADeletedOne() async throws {
        let root = try makeTempDir()
        let prepared = root.appendingPathComponent("FLOW-VoicePacks", isDirectory: true)
        let defaults = try makeDefaults()
        let voice = await makeManager(root: root, defaults: defaults)
        let v1 = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV1NoF0Base64))
        let v2 = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64))

        // 用户正在用自己导入的音色。
        let ownModel = root.appendingPathComponent("mine.onnx")
        try v1.write(to: ownModel)
        let mine = try await voice.importPack(weightURL: ownModel, displayName: "我的音色")
        XCTAssertEqual(voice.selectedPackID, mine.packID)

        let item = try XCTUnwrap(CuratedVoiceCatalog.all.first)
        try writePreparedPack(item, model: v2, in: prepared)

        let first = await voice.autoImportPreparedPacks(in: prepared, defaults: defaults)
        XCTAssertEqual(first.imported.map(\.displayName), [item.displayName])
        XCTAssertNil(first.firstError)
        XCTAssertEqual(voice.selectedPackID, mine.packID, "打开获取面板不该把正在用的音色换掉")

        // 改名后仍认得出是同一个包：不重复导入、卡片显示已导入。
        let importedID = try XCTUnwrap(first.imported.first?.packID)
        try voice.renamePack(importedID, to: "灯")
        XCTAssertEqual(voice.importedPack(for: item, in: prepared)?.packID, importedID)
        let afterRename = await voice.autoImportPreparedPacks(in: prepared, defaults: defaults)
        XCTAssertTrue(afterRename.imported.isEmpty)
        XCTAssertEqual(voice.packs.count, 2)

        // 用户删掉它：下次打开面板不会自己冒回来，手动点「导入」仍然可以。
        try voice.deletePack(importedID)
        let afterDelete = await voice.autoImportPreparedPacks(in: prepared, defaults: defaults)
        XCTAssertTrue(afterDelete.imported.isEmpty, "删掉的音色不该被自动导入装回来")
        XCTAssertEqual(voice.packs.map(\.packID), [mine.packID])

        let manual = try await voice.importPreparedPack(item, in: prepared, defaults: defaults)
        XCTAssertEqual(voice.selectedPackID, manual.packID, "手动导入的音色直接选中")

        // 重新转换出不同的模型：算新的一份，照常自动导入。
        try voice.deletePack(manual.packID)
        try FileManager.default.removeItem(at: CuratedVoiceCatalog.localPackURL(for: item, in: prepared))
        try writePreparedPack(item, model: v1, in: prepared)
        try voice.deletePack(mine.packID)
        let reconverted = await voice.autoImportPreparedPacks(in: prepared, defaults: defaults)
        XCTAssertEqual(reconverted.imported.count, 1)
        XCTAssertEqual(voice.selectedPackID, reconverted.imported.first?.packID, "一个音色都没有时，自动导入的那个成为当前音色")
    }

    // MARK: - 一键补齐底座模型

    @MainActor
    func testDownloadAllMissingAssetsTriesEveryModelBeforeReportingFailure() async throws {
        let root = try makeTempDir()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockVoiceURLProtocol.self]
        let session = URLSession(configuration: config)
        // 全部 404：以前第一个模型失败就停，后面的模型连试都不试。
        MockVoiceURLProtocol.register { request in
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let voice = await makeManager(root: root, defaults: try makeDefaults(), session: session)

        do {
            try await voice.downloadAllMissingBaseAssets()
            XCTFail("全部下载失败应报错")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let requestedFiles = Set(MockVoiceURLProtocol.recordedURLs.map(\.lastPathComponent))
        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            let name = try XCTUnwrap(kind.downloadURL?.lastPathComponent)
            XCTAssertTrue(requestedFiles.contains(name), "\(kind.fileName) 没有尝试下载：\(requestedFiles)")
        }
        XCTAssertFalse(voice.isDownloadingAllBaseAssets)
    }

    // MARK: - GitHub 上用 Git LFS 存的模型

    func testGitHubLFSPointerUsesMediaURLAndIsDetectedAfterDownload() throws {
        XCTAssertTrue(VoiceModelDiscovery.looksLikeLFSPointer(path: "voices/luna.onnx", size: 134))
        XCTAssertFalse(VoiceModelDiscovery.looksLikeLFSPointer(path: "voices/luna.onnx", size: 110_000_000))
        XCTAssertFalse(VoiceModelDiscovery.looksLikeLFSPointer(path: "voices/luna.onnx", size: nil))
        XCTAssertFalse(VoiceModelDiscovery.looksLikeLFSPointer(path: "pack.json", size: 134))

        XCTAssertEqual(
            VoiceModelDiscovery.githubRawURL(repoID: "a/b", branch: "main", relativePath: "voices/luna v2.onnx", lfs: true)?.absoluteString,
            "https://media.githubusercontent.com/media/a/b/main/voices/luna%20v2.onnx"
        )
        XCTAssertEqual(
            VoiceModelDiscovery.githubRawURL(repoID: "a/b", branch: "main", relativePath: "voices/luna.onnx")?.host,
            "raw.githubusercontent.com"
        )

        let dir = try makeTempDir()
        let pointer = dir.appendingPathComponent("pointer.onnx")
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 110532584\n".utf8).write(to: pointer)
        XCTAssertTrue(VoiceModelDiscovery.isLFSPointerFile(at: pointer))
        let real = dir.appendingPathComponent("real.onnx")
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: real)
        XCTAssertFalse(VoiceModelDiscovery.isLFSPointerFile(at: real))
    }

    // MARK: - 转换命令

    func testConversionCommandUsesTheRepositorysRealFileNames() throws {
        // 2026-11-24 核对过三个仓库的文件列表；曼波小马的仓库不按卡片 id 命名。
        let manbo = try XCTUnwrap(CuratedVoiceCatalog.voice(id: "manbo"))
        let command = CuratedVoiceCatalog.conversionCommand(for: manbo)
        XCTAssertTrue(command.contains("resolve/main/uma-Matikane_Tannhauser.pth"), command)
        XCTAssertTrue(command.contains("resolve/main/added_IVF1310_Flat_nprobe_1_uma-Matikane_Tannhauser_v2.index"), command)
        XCTAssertFalse(command.contains("resolve/main/manbo.pth"))
        XCTAssertTrue(command.contains("curl -fL"), "文件名不对时要直接报错，不能把 404 页面存成 .pth")

        for voice in CuratedVoiceCatalog.all {
            XCTAssertTrue(voice.weightFile.hasSuffix(".pth"))
            XCTAssertTrue(voice.indexFile.hasSuffix(".index"))
        }
    }
}
