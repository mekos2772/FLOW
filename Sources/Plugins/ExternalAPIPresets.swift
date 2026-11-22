import Foundation

/// 外部多 API 预设条目定义（默认均未启用，由用户在设置页或 GitHub 搜索页按需从外部获取并启用）。
struct ExternalAPIPreset: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: SourceID
    let displayName: String
    let summary: String
    let originBadge: String
    let localRelativePath: String
    let remoteURL: URL?
    let fallbackTemplateJSON: String?

    var localizedDisplayName: String {
        String(localized: String.LocalizationValue(displayName))
    }

    var localizedSummary: String {
        String(localized: String.LocalizationValue(summary))
    }

    var localizedOriginBadge: String {
        String(localized: String.LocalizationValue(originBadge))
    }
}

/// 外部多 API 预设目录与路径探测器。
///
/// 只收录公开、可合法直接播放的开放接口（开放音乐、公开电台、公共领域典藏）。
/// 抓取商业平台的脚本一律不进预设：用户要用自己的插件，走「选择文件导入」或 GitHub 搜源。
enum ExternalAPIPresetCatalog {
    static let presets: [ExternalAPIPreset] = [
        ExternalAPIPreset(
            id: "audius-open",
            sourceID: SourceID(rawValue: "json-audius-open"),
            displayName: "Audius（开放音乐）",
            summary: "开放音乐接口：热门趋势榜单、关键词搜索与直链音流播放。",
            originBadge: "外部配置 / flow-source-v1",
            localRelativePath: "examples/audius.flow.json",
            remoteURL: nil,
            fallbackTemplateJSON: audiusFallbackJSON
        ),
        ExternalAPIPreset(
            id: "radiobrowser-open",
            sourceID: SourceID(rawValue: "json-radiobrowser-open"),
            displayName: "Radio Browser（公开电台）",
            summary: "全球公开电台目录：热门电台发现、按名称搜索与在线流播放。",
            originBadge: "外部配置 / flow-source-v1",
            localRelativePath: "examples/radiobrowser.flow.json",
            remoteURL: nil,
            fallbackTemplateJSON: radioBrowserFallbackJSON
        ),
        ExternalAPIPreset(
            id: "internet-archive-audio",
            sourceID: SourceID(rawValue: "json-internet-archive-audio"),
            displayName: "Internet Archive（公共音频典藏）",
            summary: "公共领域音频典藏检索与直链播放。",
            originBadge: "外部配置 / flow-source-v1",
            localRelativePath: "examples/internetarchive.flow.json",
            remoteURL: nil,
            fallbackTemplateJSON: internetArchiveFallbackJSON
        ),
    ]

    /// 探测外部插件目录（绝不包含主 App Bundle 内部资源目录）。
    static func defaultExternalDirectories() -> [URL] {
        var directories: [URL] = []
        var seen = Set<String>()

        func appendIfDirectory(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            if seen.insert(standardized.path).inserted {
                directories.append(standardized)
            }
        }

        if let envDir = ProcessInfo.processInfo.environment["SLP_EXTERNAL_PLUGINS_DIR"], !envDir.isEmpty {
            appendIfDirectory(URL(fileURLWithPath: envDir, isDirectory: true))
        }

        if let appSupport = RuntimeSandbox.applicationSupportDirectory() {
            appendIfDirectory(appSupport.appendingPathComponent("FLOW/ExternalPlugins", isDirectory: true))
        }

        let roots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        for root in roots {
            var cursor = root.standardizedFileURL
            for _ in 0..<6 {
                appendIfDirectory(cursor.appendingPathComponent("external-plugins", isDirectory: true))
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return directories
    }

    static func resolveLocalPresetURL(_ preset: ExternalAPIPreset, in directories: [URL]) -> URL? {
        let filename = (preset.localRelativePath as NSString).lastPathComponent
        for dir in directories {
            let direct = dir.appendingPathComponent(preset.localRelativePath)
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            let flat = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: flat.path) {
                return flat
            }
        }
        return nil
    }

    // MARK: - 公开开放接口声明式模板兜底（仅用于无版权风险的公开 REST 目录）

    private static let audiusFallbackJSON = #"""
    {
      "schema": "flow-source-v1",
      "id": "audius-open",
      "name": "Audius (Open Music)",
      "version": "1.0.0",
      "allowedDomains": ["api.audius.co", "*.audius.co", "*.thestrangler.club", "*"],
      "headers": { "Accept": "application/json" },
      "discover": {
        "method": "GET",
        "url": "https://api.audius.co/v1/tracks/trending?limit={{limit}}&app_name=FLOW",
        "itemsPath": "data",
        "fields": {
          "id": "id",
          "title": "title",
          "artist": "user.name|user.handle",
          "album": "genre",
          "duration": "duration",
          "artwork": "artwork.480x480|artwork.150x150|cover_art",
          "streamUrlTemplate": "https://api.audius.co/v1/tracks/{{id}}/stream?app_name=FLOW"
        }
      },
      "search": {
        "method": "GET",
        "url": "https://api.audius.co/v1/tracks/search?query={{query}}&limit={{limit}}&app_name=FLOW",
        "itemsPath": "data",
        "fields": {
          "id": "id",
          "title": "title",
          "artist": "user.name|user.handle",
          "album": "genre",
          "duration": "duration",
          "artwork": "artwork.480x480|artwork.150x150|cover_art",
          "streamUrlTemplate": "https://api.audius.co/v1/tracks/{{id}}/stream?app_name=FLOW"
        }
      },
      "resolve": {
        "mode": "direct",
        "url": "https://api.audius.co/v1/tracks/{{id}}/stream?app_name=FLOW",
        "codec": "MP3",
        "fileExtension": "mp3",
        "bitrate": 320000
      }
    }
    """#

    private static let radioBrowserFallbackJSON = #"""
    {
      "schema": "flow-source-v1",
      "id": "radiobrowser-open",
      "name": "Radio Browser (Open Stations)",
      "version": "1.0.0",
      "allowedDomains": ["*"],
      "headers": {
        "Accept": "application/json",
        "User-Agent": "FLOW-Player/1.0"
      },
      "discover": {
        "method": "GET",
        "url": "https://de1.api.radio-browser.info/json/stations/topvote/{{limit}}",
        "fields": {
          "id": "stationuuid",
          "title": "name",
          "artist": "country|tags",
          "album": "codec",
          "artwork": "favicon",
          "streamUrl": "url_resolved|url"
        }
      },
      "search": {
        "method": "GET",
        "url": "https://de1.api.radio-browser.info/json/stations/search?name={{query}}&limit={{limit}}&hidebroken=true",
        "fields": {
          "id": "stationuuid",
          "title": "name",
          "artist": "country|tags",
          "album": "codec",
          "artwork": "favicon",
          "streamUrl": "url_resolved|url"
        }
      }
    }
    """#

    private static let internetArchiveFallbackJSON = #"""
    {
      "schema": "flow-source-v1",
      "id": "internet-archive-audio",
      "name": "Internet Archive Audio",
      "version": "1.0.0",
      "allowedDomains": ["archive.org", "*.archive.org", "*.us.archive.org"],
      "headers": { "Accept": "application/json" },
      "discover": {
        "method": "GET",
        "url": "https://archive.org/advancedsearch.php?q=mediatype%3Aaudio+AND+collection%3Anetlabels&fl%5B%5D=identifier,title,creator&sort%5B%5D=downloads+desc&rows={{limit}}&output=json",
        "itemsPath": "response.docs",
        "fields": {
          "id": "identifier",
          "title": "title|identifier",
          "artist": "creator.0|creator",
          "artworkTemplate": "https://archive.org/services/img/{{id}}",
          "streamUrlTemplate": "https://archive.org/download/{{id}}/{{id}}.mp3"
        }
      },
      "search": {
        "method": "GET",
        "url": "https://archive.org/advancedsearch.php?q=mediatype%3Aaudio+AND+({{query}})&fl%5B%5D=identifier,title,creator&rows={{limit}}&output=json",
        "itemsPath": "response.docs",
        "fields": {
          "id": "identifier",
          "title": "title|identifier",
          "artist": "creator.0|creator",
          "artworkTemplate": "https://archive.org/services/img/{{id}}"
        }
      },
      "resolve": {
        "mode": "direct",
        "url": "https://archive.org/download/{{id}}/{{id}}.mp3",
        "codec": "MP3",
        "fileExtension": "mp3"
      }
    }
    """#
}
