import Foundation

/// 主窗口全局拖放与快速打开文件的统一分类器。
enum UniversalFileClassifier {
    enum BaseModelHint: String, Equatable, Sendable {
        case rmvpe
        case hubert
        case mdxSeparator
    }

    enum Category: Equatable, Sendable {
        case audio(URL)
        case folder(URL)
        case lyric(URL)
        case sourcePlugin(URL)
        case voicePackOrModel(URL, baseModelHint: BaseModelHint?)
        case unsupported(URL)
    }

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "flac", "aac", "wav", "aiff", "aif", "alac", "opus", "ogg"
    ]
    static let lyricExtensions: Set<String> = ["lrc", "ttml"]
    static let sourceExtensions: Set<String> = ["js", "json"]

    static func classify(_ url: URL) -> Category {
        let standardized = url.standardizedFileURL
        let ext = standardized.pathExtension.lowercased()

        if ext == "voicepack" {
            return .voicePackOrModel(standardized, baseModelHint: nil)
        }
        if ext == "onnx" {
            return .voicePackOrModel(standardized, baseModelHint: baseAssetHint(forFilename: standardized.lastPathComponent))
        }
        if lyricExtensions.contains(ext) {
            return .lyric(standardized)
        }
        if sourceExtensions.contains(ext) {
            return .sourcePlugin(standardized)
        }
        if audioExtensions.contains(ext) {
            return .audio(standardized)
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue {
            return .folder(standardized)
        }
        return .unsupported(standardized)
    }

    static func baseAssetHint(forFilename filename: String) -> BaseModelHint? {
        let lower = filename.lowercased()
        if lower.contains("rmvpe") {
            return .rmvpe
        }
        if lower.contains("hubert") || lower.contains("contentvec") || lower.hasPrefix("vec-") {
            return .hubert
        }
        if lower.contains("uvr") || lower.contains("mdx") || lower.contains("voc_ft") {
            return .mdxSeparator
        }
        return nil
    }
}
