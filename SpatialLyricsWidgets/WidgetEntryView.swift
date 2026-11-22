import SwiftUI
import WidgetKit

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlaybackEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallWidgetView(snapshot: entry.snapshot)
            case .systemMedium: MediumWidgetView(snapshot: entry.snapshot)
            default: LargeWidgetView(snapshot: entry.snapshot)
            }
        }
        // 点小组件空白处打开播放器。
        // 之前文档写着"点空白处打开主窗口"，但既没有 `widgetURL` 也没挂 intent——
        // 用户点了什么都不会发生。URL 与 `DeepLinkRouter` 共用同一处构造。
        .widgetURL(DeepLinkScheme.openPlayer)
    }
}

// MARK: - 小

struct SmallWidgetView: View {
    let snapshot: PlaybackSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork(size: 44)
            Spacer(minLength: 0)
            Text(snapshot.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Label(stateText, systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateText: String {
        switch snapshot.availability {
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .privacyHidden: return "正在播放"
        case .idle: return "空闲"
        }
    }

    private func artwork(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: snapshot.availability == .privacyHidden ? "lock.fill" : "music.note")
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
    }
}

// MARK: - 中

struct MediumWidgetView: View {
    let snapshot: PlaybackSnapshot

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: snapshot.availability == .privacyHidden ? "lock.fill" : "music.note")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                if let artist = snapshot.displayArtist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: snapshot.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                controls
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }
}

// MARK: - 大

struct LargeWidgetView: View {
    let snapshot: PlaybackSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: snapshot.availability == .privacyHidden ? "lock.fill" : "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.displayTitle).font(.headline).lineLimit(1)
                    if let artist = snapshot.displayArtist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView(value: snapshot.progress).controlSize(.mini)
                }
                Spacer(minLength: 0)
            }

            if let line = snapshot.lyricLine, snapshot.availability != .privacyHidden {
                Text(line)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            if snapshot.availability != .privacyHidden, !snapshot.upNext.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("接下来").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(snapshot.upNext.prefix(3).enumerated()), id: \.offset) { _, title in
                        Text(title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 18) {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
            }
            .font(.callout)
        }
    }
}
