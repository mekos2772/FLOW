import SwiftUI
import WidgetKit

struct PlaybackEntry: TimelineEntry {
    let date: Date
    let snapshot: PlaybackSnapshot
}

/// 时间线只提供"当前快照"一条，策略 `.never`。
/// 刷新靠主 App 在状态变化时调用 `WidgetCenter.reloadAllTimelines()`，
/// 不用定时器假装实时——这是 WidgetKit 的正确用法。
struct PlaybackProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        // 崩溃退出时快照会一直停在"正在播放"：过了 5 分钟就当作已暂停。
        completion(PlaybackEntry(date: .now, snapshot: SharedStateStore.read().freshnessAdjusted()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        let entry = PlaybackEntry(date: .now, snapshot: SharedStateStore.read().freshnessAdjusted())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct SpatialLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SpatialLyricsWidget", provider: PlaybackProvider()) { entry in
            WidgetEntryView(entry: entry)
                .containerBackground(.regularMaterial, for: .widget)
        }
        .configurationDisplayName("FLOW")
        .description("显示当前曲目、进度与队列片段。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct SpatialLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpatialLyricsWidget()
    }
}
