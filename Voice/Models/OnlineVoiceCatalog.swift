import Foundation
import Observation

/// 「精选」页的可直接下载音色卡片。
///
/// 内置一份核实过的种子清单（含 SHA256）：国内连不上 huggingface.co 的检索接口时卡片照样显示，
/// 下载走 `/resolve/` 镜像。打开面板时再从 HuggingFace 检索补充新出现的音色。
enum OnlineVoiceCatalog {
    struct Seed: Sendable {
        let repo: String
        let path: String
        let size: Int64
        let sha256: String
    }

    static let seeds: [Seed] = [
        Seed(repo: "ozada/onnx_rvc", path: "beyonce.onnx", size: 110532584, sha256: "6f73df2cd4a8f3a9c443d28e4c2546d13aadbc4b68738fd43ca07623aeb790f0"),
        Seed(repo: "ozada/onnx_rvc", path: "donaldtrump.onnx", size: 110925800, sha256: "7ff2a49c3f0ffff9e7101593d83f0f029eaa71d61c0e37ec81cb451d7a269ba0"),
        Seed(repo: "ozada/onnx_rvc", path: "drake.onnx", size: 110532584, sha256: "96a07a541ad831e65b1e6b370f718596dff082f5c866a814954fbe179e30429e"),
        Seed(repo: "ozada/onnx_rvc", path: "lana.onnx", size: 110925800, sha256: "e457328e346e7cad5fcceb2e030a8045aafc0aff7905375ffb916bfdbdceccb2"),
        Seed(repo: "ozada/onnx_rvc", path: "sabrina.onnx", size: 110532584, sha256: "2b1b8c47177fb7120f440e6e0af35fb4ae42b1ded67ff091b0a49004f6b4d653"),
        Seed(repo: "ozada/onnx_rvc", path: "travisscottv2.onnx", size: 110925800, sha256: "b10c1c4d56c068fc35bbde50489da86f1766c5112acaccf294dd93e952f81740"),
        Seed(repo: "ozada/onnx_rvc", path: "woman_1.onnx", size: 110925800, sha256: "dade8e8c5b1e637fc934fbfa706262ac855c267c2b3c826dd71f0df6d9317db1"),
        Seed(repo: "ozada/onnx_rvc", path: "woman_2.onnx", size: 110925800, sha256: "fad68092dfaf6c19dad0c4974a2b052269cf41afeb19833243c6b3048c859613"),
        Seed(repo: "ozada/onnx_rvc", path: "woman_3.onnx", size: 115644712, sha256: "c6c9910893c15cf5bdf9a23ac1428e6973ba9f775028f31ce0241133b32fb5f6"),
        Seed(repo: "ozada/onnx_rvc", path: "woman_4.onnx", size: 110532584, sha256: "b5bab800131cd0c3105fc9781820de1ee42dd2b9b5bc7e7eb6e8bf79b47afdd1"),
        Seed(repo: "DogManTC/test-rvc-onnx", path: "GuraTalkV2.onnx", size: 110900195, sha256: "c13d815167ba9a39f6d045f89d64eb5e6f85120890e6684642ec46d7549d3a1d"),
    ]

    /// 自动获取时用的检索词；结果按仓库去重后逐个读详情。
    static let searchQueries = ["rvc onnx", "voicepack"]

    static var seedFiles: [VoiceModelRemoteFile] {
        seeds.compactMap { seed in
            let listing = VoiceModelDiscovery.repoListing([
                .init(path: seed.path, size: seed.size, sha256: seed.sha256)
            ])
            return VoiceModelDiscovery.remoteFiles(from: listing, repoID: seed.repo, platform: .huggingFace) {
                VoiceModelDiscovery.hfResolveURL(repoID: seed.repo, relativePath: $0)
            }.first
        }
    }

    /// 种子在前、保持顺序（有线上新数据时用线上的），线上新发现的接在后面。
    static func merged(seed: [VoiceModelRemoteFile], discovered: [VoiceModelRemoteFile]) -> [VoiceModelRemoteFile] {
        let fresh = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let seedIDs = Set(seed.map(\.id))
        return seed.map { fresh[$0.id] ?? $0 } + discovered.filter { !seedIDs.contains($0.id) }
    }
}

/// 音色名的英文整理与中文译名。
///
/// 文件名先整理成英文名（`GuraTalkV2` → `Gura Talk V2`）；只由通用词组成的直接查表翻译
/// （`woman_1` → `女声 1`），人名交给系统翻译，结果按英文名缓存在音色数据目录里。
enum VoiceNameLocalizer {
    static func englishName(fromFileName raw: String) -> String {
        var stem = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
        if stem.lowercased().hasSuffix(".voicepack") || (raw as NSString).pathExtension.lowercased() == "voicepack" {
            stem = (stem as NSString).deletingPathExtension
        }
        var spaced = ""
        var previous: Character?
        for char in stem {
            if char == "_" || char == "-" || char == "." {
                spaced.append(" ")
            } else {
                if let previous, previous.isLowercase, char.isUppercase { spaced.append(" ") }
                spaced.append(char)
            }
            previous = char
        }
        // 结尾的版本号：`travisscottv2` → `travisscott V2`
        var words = spaced.split(separator: " ").map(String.init)
        if let last = words.last, let versionRange = last.range(of: #"v\d+$"#, options: [.regularExpression, .caseInsensitive]),
           versionRange.lowerBound != last.startIndex {
            words[words.count - 1] = String(last[..<versionRange.lowerBound])
            words.append(last[versionRange].uppercased())
        }
        let titled = words.map { word -> String in
            guard let first = word.first, first.isLowercase else { return word }
            return first.uppercased() + word.dropFirst()
        }
        let joined = titled.joined(separator: " ")
        return joined.isEmpty ? raw : joined
    }

    private static let glossary: [String: String] = [
        "woman": "女声", "women": "女声", "female": "女声",
        "man": "男声", "men": "男声", "male": "男声",
        "girl": "女孩", "boy": "男孩",
        "talk": "说话版", "speech": "说话版", "speaking": "说话版",
        "sing": "唱歌版", "singing": "唱歌版", "singer": "歌手",
        "voice": "音色",
    ]

    /// 名字只由通用词、数字和版本号组成时直接给出中文；含人名等专有名词返回 nil，交给系统翻译。
    static func glossaryName(for english: String) -> String? {
        let words = english.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var hasWord = false
        var output: [String] = []
        for word in words {
            if let hit = glossary[word.lowercased()] {
                output.append(hit)
                hasWord = true
            } else if word.allSatisfy(\.isNumber) || word.range(of: #"^v\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                output.append(word.uppercased())
            } else {
                return nil
            }
        }
        return hasWord ? output.joined(separator: " ") : nil
    }

    /// 系统翻译结果是否可用：必须真的含中文，不能原样返回英文。
    static func isUsableTranslation(_ translated: String, of source: String) -> Bool {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(source) != .orderedSame else { return false }
        return trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 界面语言是中文时才翻译（英文界面直接显示英文名）。
    static var wantsChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
    }
}

/// 系统翻译得到的中文音色名缓存（英文名 → 中文名），落盘在音色数据目录。
@MainActor
@Observable
final class VoiceNameTranslations {
    private(set) var names: [String: String]
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded
        } else {
            names = [:]
        }
    }

    /// 中文译名：先查词表，再查系统翻译缓存；都没有返回 nil。
    func chineseName(for english: String) -> String? {
        VoiceNameLocalizer.glossaryName(for: english) ?? names[english]
    }

    /// 给人看的名字：界面是中文且有译名时用中文，否则用整理后的英文名。
    func displayName(for english: String) -> String {
        guard VoiceNameLocalizer.wantsChinese else { return english }
        return chineseName(for: english) ?? english
    }

    /// 还需要交给系统翻译的英文名（去重、跳过词表能翻的和已缓存的）。
    func pending(_ englishNames: [String]) -> [String] {
        var seen = Set<String>()
        return englishNames.filter { name in
            guard seen.insert(name).inserted else { return false }
            return chineseName(for: name) == nil
        }
    }

    func store(_ translated: [String: String]) {
        let usable = translated.filter { VoiceNameLocalizer.isUsableTranslation($0.value, of: $0.key) }
        guard !usable.isEmpty else { return }
        names.merge(usable) { _, new in new }
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
