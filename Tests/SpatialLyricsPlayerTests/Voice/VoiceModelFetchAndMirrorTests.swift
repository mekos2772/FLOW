import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import SpatialLyricsPlayer

final class VoiceModelFetchAndMirrorTests: XCTestCase {
    private var tempDirs: [URL] = []
    private var userDefaultsSuites: [String] = []

    override func tearDown() {
        MockVoiceURLProtocol.reset()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        for suite in userDefaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-fetch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockVoiceURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 镜像配置与回退策略

    func testMirrorConfigDefaultsAndCandidateURLRewrites() {
        let defaultConfig = VoiceModelMirrorConfig.default
        XCTAssertEqual(defaultConfig.mode, .hfMirror)
        XCTAssertEqual(defaultConfig.activeHuggingFaceBaseURLString, "https://hf-mirror.com")

        let officialHF = URL(string: "https://huggingface.co/TigreGotico/voiceclonnx-rvc/resolve/main/rmvpe.onnx")!
        let candidates = defaultConfig.candidateURLs(for: officialHF)
        XCTAssertEqual(candidates.first?.host, "hf-mirror.com")
        XCTAssertTrue(candidates.contains(where: { $0.host == "huggingface.co" }))
        XCTAssertEqual(candidates.first?.path, officialHF.path)

        let officialConfig = VoiceModelMirrorConfig(mode: .official)
        let officialCandidates = officialConfig.candidateURLs(for: officialHF)
        XCTAssertEqual(officialCandidates.first?.host, "huggingface.co")
        XCTAssertEqual(officialCandidates.last?.host, "hf-mirror.com")

        let customConfig = VoiceModelMirrorConfig(
            mode: .custom,
            customHFMirrorBase: "custom-hf.example.org/",
            customGitHubPrefix: "https://ghproxy.example.com/"
        )
        XCTAssertEqual(customConfig.customHFMirrorBase, "https://custom-hf.example.org")
        XCTAssertEqual(customConfig.customGitHubPrefix, "https://ghproxy.example.com")

        let ghRaw = URL(string: "https://github.com/TRvlvr/model_repo/releases/download/v1/model.onnx")!
        let ghCandidates = customConfig.candidateURLs(for: ghRaw)
        XCTAssertEqual(
            ghCandidates.first?.absoluteString,
            "https://ghproxy.example.com/https://github.com/TRvlvr/model_repo/releases/download/v1/model.onnx"
        )
        XCTAssertTrue(ghCandidates.contains(ghRaw))
    }

    // MARK: - 底座模型（RMVPE / HuBERT / MDX）全量自动获取配置与校验

    func testAllBaseAssetsHaveDownloadURLsAndSHA256AndRespectNetworkFlag() async throws {
        let root = try makeTempDir()
        let assets = VoiceModelAssetsManager(voiceRoot: root, session: makeMockSession())

        for kind in VoiceModelAssetsManager.AssetKind.allCases {
            let url = try XCTUnwrap(kind.downloadURL, "\(kind.fileName) 应提供默认下载地址")
            let sha = try XCTUnwrap(kind.expectedSHA256, "\(kind.fileName) 应提供 SHA256 校验值")
            XCTAssertEqual(sha.count, 64, "\(kind.fileName) SHA256 长度应为 64 位十六进制")
            XCTAssertEqual(url.scheme, "https")

            do {
                _ = try await assets.downloadAsset(kind, allowNetwork: false)
                XCTFail("\(kind.fileName) 在关闭联网时应拒绝下载")
            } catch let VoiceError.networkDisabled(msg) {
                XCTAssertFalse(msg.isEmpty)
            } catch {
                XCTFail("关闭联网应返回 VoiceError.networkDisabled，实际收到：\(error)")
            }
        }
    }

    func testBaseAssetDownloadUsesMirrorFirstFallsBackToOfficialAndRejectsBadSHA256() async throws {
        let root = try makeTempDir()
        let assets = VoiceModelAssetsManager(voiceRoot: root, session: makeMockSession())

        MockVoiceURLProtocol.register { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "hf-mirror.com" {
                let resp = HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            if url.host == "huggingface.co" {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data("corrupted-model-bytes".utf8))
            }
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        do {
            _ = try await assets.downloadAsset(.rmvpe, allowNetwork: true, mirrorConfig: .default)
            XCTFail("损坏的 SHA256 应被拒绝写入")
        } catch let VoiceError.invalidManifest(reason) {
            XCTAssertTrue(reason.contains("SHA256"), "异常信息应明确提示 SHA256 校验失败: \(reason)")
        } catch {
            XCTFail("预期 invalidManifest(SHA256)，实际：\(error)")
        }

        let requestedHosts = MockVoiceURLProtocol.recordedURLs.compactMap(\.host)
        XCTAssertGreaterThanOrEqual(requestedHosts.count, 2)
        XCTAssertEqual(requestedHosts[0], "hf-mirror.com", "默认应优先请求 hf-mirror.com")
        XCTAssertEqual(requestedHosts[1], "huggingface.co", "镜像失败时应回退到 huggingface.co")
        XCTAssertFalse(assets.assetIsReady(.rmvpe), "校验失败后不得保留脏文件")
    }

    // MARK: - 音色自动搜索、底座过滤、索引配对与 URL 纠偏

    func testDiscoveryNormalizationBaseFilterAndRepoInspection() async throws {
        XCTAssertEqual(
            VoiceModelDiscovery.parseDirectRepoIdentifier(from: "ozada/onnx_rvc")?.repoID,
            "ozada/onnx_rvc"
        )
        XCTAssertEqual(
            VoiceModelDiscovery.parseDirectRepoIdentifier(from: "https://hf-mirror.com/ozada/onnx_rvc/tree/main")?.platform,
            .huggingFace
        )
        XCTAssertEqual(
            VoiceModelDiscovery.parseDirectRepoIdentifier(from: "https://github.com/someone/rvc-models.git")?.repoID,
            "someone/rvc-models"
        )

        XCTAssertEqual(
            VoiceModelDiscovery.normalizedDirectModelURL(from: "https://huggingface.co/ozada/onnx_rvc/blob/main/beyonce.onnx")?.absoluteString,
            "https://huggingface.co/ozada/onnx_rvc/resolve/main/beyonce.onnx"
        )
        XCTAssertEqual(
            VoiceModelDiscovery.normalizedDirectModelURL(from: "https://github.com/demo/voices/blob/main/singer.voicepack")?.absoluteString,
            "https://raw.githubusercontent.com/demo/voices/main/singer.voicepack"
        )

        XCTAssertTrue(VoiceModelDiscovery.isBaseInfrastructureFileName("rmvpe.onnx"))
        XCTAssertTrue(VoiceModelDiscovery.isBaseInfrastructureFileName("contentvec_768l12.onnx"))
        XCTAssertTrue(VoiceModelDiscovery.isBaseInfrastructureFileName("UVR-MDX-NET-Voc_FT.onnx"))
        XCTAssertFalse(VoiceModelDiscovery.isBaseInfrastructureFileName("beyonce.onnx"))
        XCTAssertFalse(VoiceModelDiscovery.isBaseInfrastructureFileName("rmvpe_singer.voicepack"))

        let searchJSON = #"""
        [
          {
            "id": "ozada/onnx_rvc",
            "downloads": 1200,
            "tags": ["rvc", "onnx"],
            "siblings": [
              { "rfilename": "rmvpe.onnx" },
              { "rfilename": "beyonce.onnx" }
            ]
          },
          {
            "id": "demo/unrelated-pth-only",
            "downloads": 9999,
            "tags": ["audio"],
            "siblings": [
              { "rfilename": "weights.pth" }
            ]
          }
        ]
        """#

        let detailJSON = #"""
        {
          "id": "ozada/onnx_rvc",
          "siblings": [
            { "rfilename": "rmvpe.onnx", "size": 361688443 },
            { "rfilename": "vec-768-layer-12.onnx", "size": 377755911 },
            { "rfilename": "voices/luna_v2.onnx", "size": 55123456, "lfs": { "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 55123456, "pointerSize": 134 } },
            { "rfilename": "voices/luna_v2.f32bin", "size": 102400 },
            { "rfilename": "packs/高松灯.voicepack/pack.json", "size": 512 },
            { "rfilename": "packs/高松灯.voicepack/model.onnx", "size": 1000, "lfs": { "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size": 1000, "pointerSize": 134 } },
            { "rfilename": "packs/高松灯.voicepack/index.f32bin", "size": 2000 },
            { "rfilename": "packs/高松灯.voicepack/README.md", "size": 10 }
          ]
        }
        """#

        MockVoiceURLProtocol.register { request in
            let url = try XCTUnwrap(request.url)
            // hf-mirror 的 /api 会 308 回官方站，检索直接走 huggingface.co
            XCTAssertNotEqual(url.host, "hf-mirror.com", "默认镜像模式下检索接口不应先绕一趟 hf-mirror")
            if url.path == "/api/models", url.host == "huggingface.co" {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(searchJSON.utf8))
            }
            if url.path == "/api/models/ozada/onnx_rvc", url.host == "huggingface.co" {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(detailJSON.utf8))
            }
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let discovery = VoiceModelDiscovery(session: makeMockSession())
        let repos = try await discovery.searchRepositories(
            query: "rvc onnx",
            platform: .huggingFace,
            mirrorConfig: .default,
            allowNetwork: { true }
        )
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.repoID, "ozada/onnx_rvc")
        XCTAssertEqual(repos.first?.onnxFileCount, 1, "底座模型 rmvpe.onnx 不应计入音色数")
        XCTAssertEqual(repos.first?.summary.contains("1 个音色"), true, "摘要应直接给出可辨认的音色名")
        XCTAssertEqual(repos.first?.summary.contains("beyonce"), true)
        XCTAssertFalse(repos.contains { $0.repoID == "demo/unrelated-pth-only" },
                       "只有 .pth 的仓库不该出现在可下载列表里")

        let files = try await discovery.inspectRepository(
            repos[0],
            mirrorConfig: .default,
            allowNetwork: { true }
        )
        XCTAssertEqual(files.count, 2, "音色包文件夹算一个音色，里面的 model.onnx 不能被拆成名叫 model 的音色")
        let pack = try XCTUnwrap(files.first { $0.packFiles != nil })
        XCTAssertEqual(pack.displayName, "高松灯")
        XCTAssertEqual(pack.fileName, "高松灯.voicepack")
        XCTAssertEqual(Set(pack.packFiles?.map(\.name) ?? []), ["pack.json", "model.onnx", "index.f32bin"],
                       "README 之类的文件不下载")
        XCTAssertEqual(pack.packFiles?.first { $0.name == "model.onnx" }?.sha256,
                       "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(pack.sizeBytes, 3512)

        let luna = try XCTUnwrap(files.first { $0.packFiles == nil })
        XCTAssertEqual(luna.fileName, "luna_v2.onnx")
        XCTAssertEqual(luna.displayName, "luna v2")
        XCTAssertEqual(luna.sha256, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                       "HF 详情接口的哈希字段是 lfs.sha256，读不到就等于从不校验")
        XCTAssertEqual(
            luna.companionIndexURL?.absoluteString,
            "https://huggingface.co/ozada/onnx_rvc/resolve/main/voices/luna_v2.f32bin"
        )
    }

    func testHFSearchUnreachableExplainsMirrorOnlySpeedsUpDownloads() async throws {
        MockVoiceURLProtocol.register { _ in throw URLError(.timedOut) }
        let discovery = VoiceModelDiscovery(session: makeMockSession())
        do {
            _ = try await discovery.searchRepositories(
                query: "rvc onnx", platform: .huggingFace, mirrorConfig: .default, allowNetwork: { true }
            )
            XCTFail("连不上时应抛出说明")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("huggingface.co"), error.localizedDescription)
        }
    }

    func testCustomMirrorKeepsPathPrefixAndApiCandidates() {
        let custom = VoiceModelMirrorConfig(mode: .custom, customHFMirrorBase: "https://mirror.example/hf")
        let official = URL(string: "https://huggingface.co/a/b/resolve/main/x.onnx")!
        XCTAssertEqual(custom.candidateURLs(for: official).first?.absoluteString,
                       "https://mirror.example/hf/a/b/resolve/main/x.onnx")
        XCTAssertEqual(custom.officialURL(for: URL(string: "https://mirror.example/hf/a/b/resolve/main/x.onnx")!), official)
        let api = URL(string: "https://huggingface.co/api/models?search=rvc")!
        XCTAssertEqual(VoiceModelMirrorConfig.default.apiCandidateURLs(for: api), [api])
        XCTAssertEqual(custom.apiCandidateURLs(for: api).first?.host, "mirror.example")
    }

    // MARK: - 下载并直接自动导入（无需手动选择文件）

    @MainActor
    func testVoiceManagerDownloadsViaMirrorAndAutoImportsIntoPackStore() async throws {
        let root = try makeTempDir()
        let suiteName = "VoiceFetchTests-\(UUID().uuidString)"
        userDefaultsSuites.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        await settings.setEnableNetwork(true)

        let modelBytes = try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64))
        let modelSHA = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
        let mockSession = makeMockSession()

        MockVoiceURLProtocol.register { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "hf-mirror.com", url.path.hasSuffix("/luna_v2.onnx") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, modelBytes)
            }
            if url.path.hasSuffix("/bad_hash.onnx") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, modelBytes)
            }
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let voice = VoiceManager(
            settings: settings,
            packStore: VoicePackStore(packsRoot: root.appendingPathComponent("Packs", isDirectory: true)),
            cache: VoiceCacheManager(rootURL: root),
            assets: VoiceModelAssetsManager(voiceRoot: root, session: mockSession),
            presetStore: VoicePresetStore(directory: root),
            discovery: VoiceModelDiscovery(session: mockSession)
        )

        XCTAssertEqual(voice.mirrorMode, .hfMirror)
        XCTAssertTrue(voice.packs.isEmpty)

        let remoteFile = VoiceModelRemoteFile(
            id: "hf:demo/voices::luna_v2.onnx",
            repoID: "demo/voices",
            platform: .huggingFace,
            fileName: "luna_v2.onnx",
            relativePath: "luna_v2.onnx",
            displayName: "Luna Test",
            downloadURL: URL(string: "https://huggingface.co/demo/voices/resolve/main/luna_v2.onnx")!,
            sizeBytes: Int64(modelBytes.count),
            sha256: modelSHA,
            companionIndexURL: nil
        )

        let imported = try await voice.downloadAndImportRemoteModel(remoteFile)
        XCTAssertEqual(imported.displayName, "Luna Test")
        XCTAssertEqual(voice.packs.count, 1, "下载完成后应自动导入 VoicePackStore，无需用户二次操作")
        XCTAssertEqual(voice.packs.first?.packID, imported.packID)
        XCTAssertTrue(voice.downloadingRemoteModelIDs.isEmpty)
        XCTAssertTrue(voice.remoteModelDownloadProgress.isEmpty)
        XCTAssertEqual(MockVoiceURLProtocol.recordedURLs.first?.host, "hf-mirror.com")

        // 错误 SHA256 的远端文件必须被拒绝且不会污染 packs
        let tamperedFile = VoiceModelRemoteFile(
            id: "hf:demo/voices::bad_hash.onnx",
            repoID: "demo/voices",
            platform: .huggingFace,
            fileName: "bad_hash.onnx",
            relativePath: "bad_hash.onnx",
            displayName: "Tampered",
            downloadURL: URL(string: "https://huggingface.co/demo/voices/resolve/main/bad_hash.onnx")!,
            sizeBytes: Int64(modelBytes.count),
            sha256: String(repeating: "0", count: 64),
            companionIndexURL: nil
        )
        do {
            _ = try await voice.downloadAndImportRemoteModel(tamperedFile)
            XCTFail("SHA256 不匹配的远端音色应被拒绝")
        } catch let VoiceError.invalidManifest(reason) {
            XCTAssertTrue(reason.contains("SHA256"))
        }
        XCTAssertEqual(voice.packs.count, 1, "失败导入不得污染已导入音色列表")

        // URL 直链下载自动导入
        let directURL = URL(string: "https://huggingface.co/demo/voices/blob/main/luna_v2.onnx")!
        let directImported = try await voice.downloadAndImportPack(from: directURL, displayName: "Luna Direct")
        XCTAssertEqual(directImported.displayName, "Luna Direct")
        XCTAssertEqual(voice.packs.count, 2)
    }

    // MARK: - 镜像设置持久化 & 配置备份

    @MainActor
    func testMirrorSettingsParityAndBackupRoundtrip() async throws {
        let suiteName = "VoiceMirrorSettings-\(UUID().uuidString)"
        userDefaultsSuites.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let udStore = UserDefaultsSettingsStore(defaults: defaults)
        let memStore = InMemorySettingsStore()

        XCTAssertEqual(udStore.voiceMirrorModeRaw, VoiceMirrorMode.hfMirror.rawValue)
        XCTAssertEqual(memStore.voiceMirrorModeRaw, VoiceMirrorMode.hfMirror.rawValue)

        for (mode, hf, gh) in [
            ("invalid_mode", "  ", ""),
            ("official", "mirror.test.local/", "proxy.test.local/"),
            ("custom", "https://my-hf.mirror.cn///", "https://gh.mirror.cn/")
        ] {
            await udStore.setVoiceMirrorModeRaw(mode)
            await memStore.setVoiceMirrorModeRaw(mode)
            await udStore.setVoiceCustomHFMirror(hf)
            await memStore.setVoiceCustomHFMirror(hf)
            await udStore.setVoiceCustomGitHubMirror(gh)
            await memStore.setVoiceCustomGitHubMirror(gh)

            XCTAssertEqual(udStore.voiceMirrorModeRaw, memStore.voiceMirrorModeRaw)
            XCTAssertEqual(udStore.voiceCustomHFMirror, memStore.voiceCustomHFMirror)
            XCTAssertEqual(udStore.voiceCustomGitHubMirror, memStore.voiceCustomGitHubMirror)
        }

        let snapshot = SettingsBackup.snapshot(from: udStore)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: data)
        let restored = InMemorySettingsStore()
        try await decoded.apply(to: restored)

        XCTAssertEqual(restored.voiceMirrorModeRaw, "custom")
        XCTAssertEqual(restored.voiceCustomHFMirror, "https://my-hf.mirror.cn")
        XCTAssertEqual(restored.voiceCustomGitHubMirror, "https://gh.mirror.cn")
    }

    // MARK: - 运行时社区 ONNX 多构型兼容

    func testHuBERTAndRMVPECommunityONNXCompatibilityHelpers() {
        let legacyInputs = HuBERTFeatureExtractor.buildInputs(
            for: [ORTTensorInfo(name: "source", elementType: .float32, shape: [1, -1])],
            audio16k: [0.1, -0.2, 0.3]
        )
        XCTAssertEqual(legacyInputs.count, 1)
        if case .float32(let data, let shape)? = legacyInputs["source"] {
            XCTAssertEqual(shape, [1, 3])
            XCTAssertEqual(data.count, 3)
        } else {
            XCTFail("缺少 source float32 张量")
        }

        let maskedInputs = HuBERTFeatureExtractor.buildInputs(
            for: [
                ORTTensorInfo(name: "source", elementType: .float32, shape: [1, -1]),
                ORTTensorInfo(name: "padding_mask", elementType: .bool, shape: [1, -1])
            ],
            audio16k: [0.1, -0.2, 0.3, 0.4]
        )
        XCTAssertEqual(maskedInputs.count, 2)
        if case .bool(let mask, let shape)? = maskedInputs["padding_mask"] {
            XCTAssertEqual(shape, [1, 4])
            XCTAssertEqual(mask, [false, false, false, false])
        } else {
            XCTFail("缺少 padding_mask bool 张量")
        }

        let melInfos = [ORTTensorInfo(name: "mel", elementType: .float32, shape: [1, 128, -1])]
        XCTAssertEqual(RMVPEPitchExtractor.detectInputSchema(from: melInfos), .mel)

        let waveInfos = [
            ORTTensorInfo(name: "waveform", elementType: .float32, shape: [1, -1]),
            ORTTensorInfo(name: "thred", elementType: .float32, shape: [1])
        ]
        XCTAssertEqual(RMVPEPitchExtractor.detectInputSchema(from: waveInfos), .waveform)
        let builtWave = RMVPEPitchExtractor.buildInputs(
            schema: .waveform,
            inputInfos: waveInfos,
            primaryName: "waveform",
            melInput: [],
            nBins: 128,
            paddedFrames: 0,
            audio16k: [0.5, -0.5],
            threshold: 0.03
        )
        if case .float32(let tData, _)? = builtWave["thred"] {
            XCTAssertEqual(tData, [0.03])
        } else {
            XCTFail("应自动注入阈值 thred 张量")
        }

        let extractor = RMVPEPitchExtractor()
        let directF0Tensor = ORTTensorOutput(
            shape: [1, 3],
            elementType: .float32,
            floatData: [220.0, 440.0, 0.0],
            int64Data: []
        )
        XCTAssertEqual(extractor.decodeOutput(tensor: directF0Tensor, nFrames: 3, threshold: 0.03), [220.0, 440.0, 0.0])
    }

    // MARK: - UI 离线渲染探针

    @MainActor
    func testVoiceModelFetchSheetAndAdvancedPanelRenderOffscreen() throws {
        let container = try ContainerBuilder.make(.testing(inMemory: true))

        let fetchSheet = VoiceModelFetchSheet()
            .environment(\.app, container)
            .environment(\.colorScheme, .dark)
        let sheetRenderer = ImageRenderer(content: fetchSheet)
        sheetRenderer.scale = 1
        let sheetImage = try XCTUnwrap(sheetRenderer.cgImage)
        XCTAssertGreaterThan(sheetImage.width, 0)
        XCTAssertGreaterThan(sheetImage.height, 0)

        let voice = try XCTUnwrap(container.voice)
        let panel = VoiceAdvancedPanel(voice: voice)
            .environment(\.app, container)
            .environment(\.colorScheme, .dark)
        let panelRenderer = ImageRenderer(content: panel)
        panelRenderer.scale = 1
        let panelImage = try XCTUnwrap(panelRenderer.cgImage)
        XCTAssertGreaterThan(panelImage.width, 0)
        XCTAssertGreaterThan(panelImage.height, 0)
    }

    // MARK: - 精选音色卡片

    func testCuratedCatalogMapsChineseAndRomanizedNamesToRepos() {
        XCTAssertEqual(CuratedVoiceCatalog.sourceRepo(matchingQuery: "高松灯"), "TogetsuDo/tomori-rvc")
        XCTAssertEqual(CuratedVoiceCatalog.sourceRepo(matchingQuery: "Tomori"), "TogetsuDo/tomori-rvc")
        XCTAssertEqual(CuratedVoiceCatalog.sourceRepo(matchingQuery: "小马曼波"), "juzi45/RVC_Matikanetannhauser")
        XCTAssertEqual(CuratedVoiceCatalog.sourceRepo(matchingQuery: "tannhauser"), "juzi45/RVC_Matikanetannhauser")
        XCTAssertEqual(CuratedVoiceCatalog.sourceRepo(matchingQuery: "千早爱音"), "TogetsuDo/anon-rvc")
        XCTAssertNil(CuratedVoiceCatalog.sourceRepo(matchingQuery: "beyonce"))
        XCTAssertEqual(Set(CuratedVoiceCatalog.all.map(\.id)).count, CuratedVoiceCatalog.all.count)
    }

    func testCuratedVoiceCardsAreFullyLocalized() throws {
        for voice in CuratedVoiceCatalog.all {
            XCTAssertFalse(voice.displayName.isEmpty)
            XCTAssertFalse(voice.work.isEmpty)
            XCTAssertTrue(voice.packFolderName.hasSuffix(".voicepack"))
            XCTAssertFalse(voice.aliases.isEmpty)
        }
    }

    /// 三个精选角色的源仓库都只发布 `.pth` + `.index`，没有任何可运行格式。
    ///
    /// 这条把"到底能不能直接下载"钉成事实：搜索这几个角色时，结果里不该出现可下载音色，
    /// 界面必须走"需转换"分支，而不是给一个点了就失败的下载按钮。
    func testCuratedVoiceSourcesPublishNoRunnableModel() async throws {
        try LiveTestGate.skipUnlessLive("真实 HuggingFace 仓库清单，需设置 SLP_LIVE_TEST=1")
        let discovery = VoiceModelDiscovery()
        for voice in CuratedVoiceCatalog.all {
            let summary = VoiceModelRepoSummary(
                id: "hf:\(voice.sourceRepo)", platform: .huggingFace, repoID: voice.sourceRepo,
                title: voice.sourceRepo, summary: "", downloadsOrStars: 0, onnxFileCount: 0,
                tags: [], pageURL: URL(string: "https://huggingface.co/\(voice.sourceRepo)")!,
                defaultBranch: "main", isRecommended: true
            )
            let files = try await discovery.inspectRepository(summary, allowNetwork: { true })
            XCTAssertTrue(files.isEmpty,
                          "\(voice.sourceRepo) 不该有可直接下载的 .onnx / .voicepack：\(files.map(\.fileName))")
            XCTAssertFalse(CuratedVoiceCatalog.hasLocalPack(for: voice),
                           "测试环境不该读到用户下载目录里的音色包")
        }
    }

    /// 转换命令必须指向真实存在的源文件，并且输出到应用会自动扫描的目录。
    func testCuratedConversionCommandTargetsRealSourceFiles() {
        for voice in CuratedVoiceCatalog.all {
            XCTAssertTrue(voice.sourceRepo.contains("/"))
            XCTAssertTrue(voice.id.allSatisfy { $0.isLetter || $0.isNumber })
            XCTAssertEqual(CuratedVoiceCatalog.localPackURL(for: voice).lastPathComponent, voice.packFolderName)
            XCTAssertTrue(CuratedVoiceCatalog.packsDirectoryDisplayPath.hasSuffix("Downloads/FLOW-VoicePacks"))
        }
    }

    // MARK: - 直链分类

    func testDirectLinkClassification() {
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("https://huggingface.co/a/b/resolve/main/x.onnx"),
            .modelFile(URL(string: "https://huggingface.co/a/b/resolve/main/x.onnx")!)
        )
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("https://huggingface.co/a/b/blob/main/x.pth"),
            .requiresConversion(ext: "pth")
        )
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("https://example.com/pack.zip"),
            .requiresConversion(ext: "zip")
        )
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("https://huggingface.co/a/b"),
            .repository(repoID: "a/b", platform: .huggingFace)
        )
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("https://huggingface.co/a/b/tree/main/x.voicepack"),
            .repository(repoID: "a/b", platform: .huggingFace),
            ".voicepack 是文件夹，不能当单文件下载，转到仓库检索整组下载"
        )
        XCTAssertEqual(
            VoiceModelDiscovery.normalizedDirectModelURL(from: "https://huggingface.co/datasets/a/b/blob/main/v.onnx")?.absoluteString,
            "https://huggingface.co/datasets/a/b/resolve/main/v.onnx"
        )
        XCTAssertEqual(
            VoiceModelDiscovery.classifyDirectLink("a/b"),
            .repository(repoID: "a/b", platform: nil)
        )
        XCTAssertEqual(VoiceModelDiscovery.classifyDirectLink("rvc onnx"), .invalid)
        XCTAssertEqual(VoiceModelDiscovery.classifyDirectLink("   "), .invalid)
    }

    func testHFResolveLinkSuggestsSiblingF32BinIndex() {
        let model = URL(string: "https://huggingface.co/a/b/resolve/main/voice/model.onnx")!
        XCTAssertEqual(
            VoiceModelDiscovery.inferredCompanionIndexURL(for: model),
            URL(string: "https://huggingface.co/a/b/resolve/main/voice/model.f32bin")
        )
        XCTAssertNil(VoiceModelDiscovery.inferredCompanionIndexURL(
            for: URL(string: "https://example.com/model.onnx")!))
    }

    // MARK: - 实网可选探针（需 SLP_LIVE_TEST=1）

    /// 关键词搜索（而非 owner/repo 直达）走的是 `/api/models?search=...`，与仓库详情是两条不同链路。
    func testLiveHFKeywordSearchReturnsRepos() async throws {
        try LiveTestGate.skipUnlessLive("实网 HuggingFace 关键词搜索，需设置 SLP_LIVE_TEST=1")
        let discovery = VoiceModelDiscovery()
        do {
            let repos = try await discovery.searchRepositories(
                query: "rvc onnx",
                platform: .huggingFace,
                mirrorConfig: .default,
                allowNetwork: { true }
            )
            XCTAssertFalse(repos.isEmpty, "关键词搜索应返回仓库")
            XCTAssertTrue(repos.contains { $0.onnxFileCount > 0 }, "至少一个结果应含可下载 ONNX")
        } catch {
            XCTFail("关键词搜索失败：\(error)")
        }
    }

    func testLiveHFMirrorDiscoveryAndInspect() async throws {
        try LiveTestGate.skipUnlessLive("实网 hf-mirror RVC 仓库发现与文件解析测试，需设置 SLP_LIVE_TEST=1")
        let discovery = VoiceModelDiscovery()
        let repos = try await discovery.searchRepositories(
            query: "ozada/onnx_rvc",
            platform: .huggingFace,
            mirrorConfig: .default,
            allowNetwork: { true }
        )
        XCTAssertFalse(repos.isEmpty)
        let files = try await discovery.inspectRepository(
            repos[0],
            mirrorConfig: .default,
            allowNetwork: { true }
        )
        XCTAssertFalse(files.isEmpty, "ozada/onnx_rvc 应解析出可运行 RVC ONNX 音色")
        XCTAssertFalse(files.contains(where: { VoiceModelDiscovery.isBaseInfrastructureFileName($0.fileName) }))
    }
}

// MARK: - Isolated Mock URLProtocol

private final class MockVoiceProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MockVoiceURLProtocol.Handler?
    private var requests: [URL] = []

    var recordedURLs: [URL] {
        lock.withLock { requests }
    }

    func register(_ handler: @escaping MockVoiceURLProtocol.Handler) {
        lock.withLock {
            self.handler = handler
            self.requests = []
        }
    }

    func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    func takeHandler(recording url: URL?) -> MockVoiceURLProtocol.Handler? {
        lock.withLock {
            if let url { requests.append(url) }
            return handler
        }
    }
}

private final class MockVoiceURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let state = MockVoiceProtocolState()

    static var recordedURLs: [URL] {
        state.recordedURLs
    }

    static func register(_ handler: @escaping Handler) {
        state.register(handler)
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.state.takeHandler(recording: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 「精选」页自动获取的卡片与中文译名。
@MainActor
final class OnlineVoiceCardTests: XCTestCase {
    func testEnglishNamesAreReadableFromFileNames() {
        XCTAssertEqual(VoiceNameLocalizer.englishName(fromFileName: "GuraTalkV2.onnx"), "Gura Talk V2")
        XCTAssertEqual(VoiceNameLocalizer.englishName(fromFileName: "travisscottv2.onnx"), "Travisscott V2")
        XCTAssertEqual(VoiceNameLocalizer.englishName(fromFileName: "woman_1.onnx"), "Woman 1")
        XCTAssertEqual(VoiceNameLocalizer.englishName(fromFileName: "beyonce.onnx"), "Beyonce")
        XCTAssertEqual(VoiceNameLocalizer.englishName(fromFileName: "高松灯.voicepack"), "高松灯")
    }

    func testGlossaryTranslatesGenericNamesOnly() {
        XCTAssertEqual(VoiceNameLocalizer.glossaryName(for: "Woman 1"), "女声 1")
        XCTAssertEqual(VoiceNameLocalizer.glossaryName(for: "Male Singing V2"), "男声 唱歌版 V2")
        XCTAssertNil(VoiceNameLocalizer.glossaryName(for: "Beyonce"), "人名交给系统翻译")
        XCTAssertNil(VoiceNameLocalizer.glossaryName(for: "Gura Talk V2"))
        XCTAssertNil(VoiceNameLocalizer.glossaryName(for: "2"), "纯数字不是名字")
    }

    func testTranslationCacheKeepsOnlyRealChineseAndPersists() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("names-\(UUID().uuidString)/name-translations.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = VoiceNameTranslations(fileURL: file)
        XCTAssertEqual(cache.pending(["Beyonce", "Woman 1", "Beyonce", "Drake"]), ["Beyonce", "Drake"],
                       "词表能翻的和重复的不送去系统翻译")
        cache.store(["Beyonce": "碧昂丝", "Drake": "Drake", "Lana": "  "])
        XCTAssertEqual(cache.chineseName(for: "Beyonce"), "碧昂丝")
        XCTAssertNil(cache.chineseName(for: "Drake"), "原样返回英文的不算译名")
        XCTAssertEqual(VoiceNameTranslations(fileURL: file).chineseName(for: "Beyonce"), "碧昂丝", "译名要落盘")
    }

    func testSeedCardsAreDownloadableWithChecksums() {
        let seeds = OnlineVoiceCatalog.seedFiles
        XCTAssertEqual(seeds.count, OnlineVoiceCatalog.seeds.count)
        for file in seeds {
            XCTAssertEqual(file.sha256?.count, 64, "内置卡片必须带 SHA256：\(file.fileName)")
            XCTAssertEqual(file.downloadURL.host, "huggingface.co")
            XCTAssertTrue(file.downloadURL.path.contains("/resolve/main/"))
        }
        let mirrored = VoiceModelMirrorConfig.default.candidateURLs(for: seeds[0].downloadURL)
        XCTAssertEqual(mirrored.first?.host, "hf-mirror.com", "卡片下载默认走镜像")
    }

    func testMergedCardsKeepSeedOrderAndAppendNewOnes() {
        let seeds = OnlineVoiceCatalog.seedFiles
        let fresh = VoiceModelRemoteFile(
            id: "hf:someone/new::new_voice.onnx", repoID: "someone/new", platform: .huggingFace,
            fileName: "new_voice.onnx", relativePath: "new_voice.onnx", displayName: "new voice",
            downloadURL: URL(string: "https://huggingface.co/someone/new/resolve/main/new_voice.onnx")!,
            sizeBytes: 1, sha256: nil, companionIndexURL: nil
        )
        let merged = OnlineVoiceCatalog.merged(seed: seeds, discovered: [seeds[2], fresh])
        XCTAssertEqual(merged.count, seeds.count + 1)
        XCTAssertEqual(merged.prefix(seeds.count).map(\.id), seeds.map(\.id))
        XCTAssertEqual(merged.last?.id, fresh.id)
    }

    func testImportedCardIsRecognisedBySHA256EvenAfterRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = VoiceManager(
            settings: InMemorySettingsStore(enableNetwork: false),
            packStore: VoicePackStore(packsRoot: root.appendingPathComponent("Packs")),
            cache: VoiceCacheManager(rootURL: root),
            assets: VoiceModelAssetsManager(voiceRoot: root),
            presetStore: VoicePresetStore(directory: root)
        )
        let model = root.appendingPathComponent("beyonce.onnx")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTUnwrap(Data(base64Encoded: RVCEngineAdapterTests.tinyV2F0Base64)).write(to: model)
        let pack = try await manager.importPack(weightURL: model, displayName: "碧昂丝")
        try manager.renamePack(pack.packID, to: "我的音色")
        let sha = try XCTUnwrap(manager.packs.first?.selectedVersion?.weightFingerprint)

        let card = VoiceModelRemoteFile(
            id: "hf:x/y::beyonce.onnx", repoID: "x/y", platform: .huggingFace,
            fileName: "beyonce.onnx", relativePath: "beyonce.onnx", displayName: "beyonce",
            downloadURL: URL(string: "https://huggingface.co/x/y/resolve/main/beyonce.onnx")!,
            sizeBytes: nil, sha256: sha.uppercased(), companionIndexURL: nil
        )
        XCTAssertEqual(manager.importedPack(for: card)?.packID, pack.packID)

        let offline = await manager.discoverOnlineVoices()
        XCTAssertFalse(offline.reachable, "关了联网不检索，界面用内置清单")
        XCTAssertTrue(offline.files.isEmpty)
    }
}
