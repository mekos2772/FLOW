import Foundation

/// 找到仓库根目录。
///
/// 之前多处测试用写死的 `deletingLastPathComponent()` 层级去定位源码目录，
/// 一旦测试文件被挪进子目录就全断（这次按模块分组就断了）。
/// 改成从 `#filePath` 向上找"有 .xcodeproj 的那一层"，与文件位置无关。
enum RepositoryRoot {
    static func locate(from filePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let manager = FileManager.default
        for _ in 0..<12 {
            if let contents = try? manager.contentsOfDirectory(atPath: url.path),
               contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "Package.swift" }) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return URL(fileURLWithPath: filePath).deletingLastPathComponent()
    }
}
