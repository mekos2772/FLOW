import Foundation

/// 精选音色：把社区里常用的角色音色固定成中文卡片，避免用户在海量英文仓库里找。
///
/// 这些角色的公开源目前都只提供 PyTorch `.pth`，不能由 App 直接运行；
/// 卡片查找的是桌面转换工具输出的 `.voicepack`，存在时一键导入。
struct CuratedVoice: Identifiable, Hashable, Sendable {
    let id: String
    /// 卡片上显示的中文名。
    let displayName: String
    /// 出处作品。
    let work: String
    /// 公开权重仓库（owner/repo）。
    let sourceRepo: String
    /// 仓库里训练权重与检索索引的文件名（各仓库命名不一，不能按卡片 id 猜）。
    let weightFile: String
    let indexFile: String
    /// 转换后的音色包文件夹名。
    let packFolderName: String
    /// 搜索时可直接命中的别名（中文、罗马字、英文）。
    let aliases: [String]
}

enum CuratedVoiceCatalog {
    /// 桌面转换工具的默认输出目录；用户可以把 `.voicepack` 放在这里。
    /// 沙盒里 `homeDirectoryForCurrentUser` 指向容器目录，这里取真实的用户主目录；
    /// 读取依赖 `com.apple.security.files.downloads.read-only` 权限。
    static var packsDirectory: URL {
        realHomeDirectory.appendingPathComponent("Downloads/FLOW-VoicePacks", isDirectory: true)
    }

    /// 给界面看的路径（`~/Downloads/FLOW-VoicePacks`）。
    static var packsDirectoryDisplayPath: String {
        let home = realHomeDirectory.path
        let path = packsDirectory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static let all: [CuratedVoice] = [
        CuratedVoice(
            id: "tomori",
            displayName: "高松灯",
            work: "BanG Dream! It's MyGO!!!!!",
            sourceRepo: "TogetsuDo/tomori-rvc",
            weightFile: "tomori.pth",
            indexFile: "tomori.index",
            packFolderName: "高松灯.voicepack",
            aliases: ["高松灯", "高松 灯", "灯", "tomori", "takamatsu tomori", "takamatsutomori"]
        ),
        CuratedVoice(
            id: "manbo",
            displayName: "曼波小马",
            work: "赛马娘 Pretty Derby",
            sourceRepo: "juzi45/RVC_Matikanetannhauser",
            weightFile: "uma-Matikane_Tannhauser.pth",
            indexFile: "added_IVF1310_Flat_nprobe_1_uma-Matikane_Tannhauser_v2.index",
            packFolderName: "曼波小马.voicepack",
            aliases: ["曼波小马", "小马曼波", "曼波", "小马", "manbo", "mambo", "matikanetannhauser", "tannhauser"]
        ),
        CuratedVoice(
            id: "anon",
            displayName: "千早爱音",
            work: "BanG Dream! It's MyGO!!!!!",
            sourceRepo: "TogetsuDo/anon-rvc",
            weightFile: "anon.pth",
            indexFile: "anon.index",
            packFolderName: "千早爱音.voicepack",
            aliases: ["千早爱音", "千早 爱音", "爱音", "anon", "chihaya anon", "chihayaanon"]
        ),
    ]

    static func voice(id: String) -> CuratedVoice? {
        all.first { $0.id == id }
    }

    /// 中文名 / 罗马字精确命中某个精选音色时，返回它对应的仓库，方便检索框直接出结果。
    static func sourceRepo(matchingQuery raw: String) -> String? {
        let query = normalized(raw)
        guard !query.isEmpty else { return nil }
        return all.first { voice in
            voice.aliases.contains { normalized($0) == query }
        }?.sourceRepo
    }

    /// 已转换好的音色包目录（不保证存在）。
    static func localPackURL(for voice: CuratedVoice, in directory: URL = packsDirectory) -> URL {
        directory.appendingPathComponent(voice.packFolderName, isDirectory: true)
    }

    static func hasLocalPack(for voice: CuratedVoice, in directory: URL = packsDirectory) -> Bool {
        var isDirectory: ObjCBool = false
        let url = localPackURL(for: voice, in: directory)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("pack.json").path)
    }

    /// 转换工具写在 `pack.json` 里的模型 SHA256（小写）；旧版转换包没有这一项时返回 nil。
    /// 用它认"这个包导入过没有"，用户给音色改了名也认得出来。
    static func localModelSHA256(for voice: CuratedVoice, in directory: URL = packsDirectory) -> String? {
        let metaURL = localPackURL(for: voice, in: directory).appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(VoicePackConverterManifest.self, from: data),
              let sha = meta.onnxSha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !sha.isEmpty else { return nil }
        return sha
    }

    /// 标识"这一份转换结果"：自动导入过一次就记下，用户删掉音色后不再自动装回来；
    /// 重新转换（模型或 `pack.json` 变了）会得到新的标识，照常自动导入。
    static func autoImportKey(for voice: CuratedVoice, in directory: URL = packsDirectory) -> String {
        if let sha = localModelSHA256(for: voice, in: directory) {
            return "\(voice.packFolderName)|\(sha)"
        }
        let metaURL = localPackURL(for: voice, in: directory).appendingPathComponent("pack.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: metaURL.path)[.modificationDate]) as? Date
        return "\(voice.packFolderName)|\(Int64((modified?.timeIntervalSince1970 ?? 0) * 1000))"
    }

    /// 「下载训练权重 → 转成音色包」的终端命令。
    ///
    /// `curl -f`：文件名不对时直接报错，不会把 404 页面存成 `.pth` 再让转换脚本报一个看不懂的错。
    static func conversionCommand(for voice: CuratedVoice) -> String {
        func remote(_ file: String) -> String {
            VoiceModelDiscovery.hfResolveURL(repoID: voice.sourceRepo, relativePath: file)?.absoluteString
                ?? "https://huggingface.co/\(voice.sourceRepo)/resolve/main/\(file)"
        }
        return """
        # \(voice.displayName)：先下载训练权重，再转成音色包
        curl -fL -o ~/Downloads/\(voice.id).pth  "\(remote(voice.weightFile))"
        curl -fL -o ~/Downloads/\(voice.id).index "\(remote(voice.indexFile))"
        python3 Tools/rvc-converter/convert_to_voicepack.py \\
          --pth ~/Downloads/\(voice.id).pth \\
          --index ~/Downloads/\(voice.id).index \\
          --name "\(voice.displayName)" \\
          --output ~/Downloads/FLOW-VoicePacks
        """
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
