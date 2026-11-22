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
            packFolderName: "高松灯.voicepack",
            aliases: ["高松灯", "高松 灯", "灯", "tomori", "takamatsu tomori", "takamatsutomori"]
        ),
        CuratedVoice(
            id: "manbo",
            displayName: "曼波小马",
            work: "赛马娘 Pretty Derby",
            sourceRepo: "juzi45/RVC_Matikanetannhauser",
            packFolderName: "曼波小马.voicepack",
            aliases: ["曼波小马", "小马曼波", "曼波", "小马", "manbo", "mambo", "matikanetannhauser", "tannhauser"]
        ),
        CuratedVoice(
            id: "anon",
            displayName: "千早爱音",
            work: "BanG Dream! It's MyGO!!!!!",
            sourceRepo: "TogetsuDo/anon-rvc",
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
    static func localPackURL(for voice: CuratedVoice) -> URL {
        packsDirectory.appendingPathComponent(voice.packFolderName, isDirectory: true)
    }

    static func hasLocalPack(for voice: CuratedVoice) -> Bool {
        var isDirectory: ObjCBool = false
        let url = localPackURL(for: voice)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("pack.json").path)
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
