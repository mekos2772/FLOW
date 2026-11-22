import Foundation

/// 确定性虚拟曲库。同一 seed 生成结果逐字段一致，测试可重复。
enum MockCatalog {
    static let titles = [
        "Spatial Drift", "Nocturne for a Window", "Glass Ceiling",
        "Foreground Noise", "Quiet Menu Bar", "Second Display",
        "Anchor Point", "Edge Snap", "Transparent Panel",
        "Notch", "Safe Area", "Fade In",
    ]

    static let artists = [
        "Mock Ensemble", "Phase Zero", "Little Code Sauce",
        "Alignment Chorus", "The Compositors",
    ]

    /// 生成曲库。
    /// - Parameters:
    ///   - count: 曲目数量（上限为标题表长度）。
    ///   - sourceID: 归属源。
    static func tracks(count: Int = 12, sourceID: SourceID = .mock) -> [Track] {
        let n = max(0, min(count, titles.count * 4))
        return (0..<n).map { index in
            let title = titles[index % titles.count]
            let suffix = index >= titles.count ? " (\(index / titles.count + 1))" : ""
            return Track(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                sourceID: sourceID,
                externalID: "mock-\(String(format: "%03d", index + 1))",
                title: title + suffix,
                artist: artists[index % artists.count],
                album: "Phase 0 Sessions",
                duration: TimeInterval(180 + 37 * (index % 4)),
                artwork: nil,
                lyrics: LyricsReference(.opaque("mock-lyrics-\(index + 1)"))
            )
        }
    }
}
