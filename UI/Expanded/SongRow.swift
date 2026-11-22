import SwiftUI

/// 首页、收藏与歌单共用同一行排版，原始视频标题不进入视图。
struct SongRow: View {
    let track: Track
    var isCurrent = false
    var isFavorite = false
    var isOffline = false
    var isDownloadingOffline = false
    var sourceBadge: String? = nil
    var onFavorite: (() -> Void)?
    var onToggleOffline: (() -> Void)?
    var onRemove: (() -> Void)?
    var removeLabel: LocalizedStringKey = "从歌单移除"
    var removeSymbol = "minus.circle"
    let onPlay: () -> Void
    @State private var hovered = false
    /// 本行封面落盘的信号：decorate 是逐张写盘的，用 identity 过滤后
    /// 只有**自己那张**写好才重取——不会像整列 revision 那样 60 行一起重建。
    @State private var artworkToken = 0

    var body: some View {
        let display = MorphPresentationModel.display(track)
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    ArtworkSlab(image: { _ = artworkToken; return ArtworkStore.shared.image(forIdentity: track.identity) }(),
                                ambient: nil, side: 44, cornerRadius: 8, showsAmbientGlow: false)
                        .overlay {
                            if hovered || isCurrent {
                                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.38))
                                flowIcon(systemName: isCurrent && !hovered ? "waveform" : "play.fill", size: 15)
                                    .foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.title).flowType(.homeTitle).lineLimit(1)
                        HStack(spacing: 6) {
                            if let artist = display.artist {
                                Text(artist).flowType(.homeSecondary)
                                    .foregroundStyle(FlowColor.secondaryText).lineLimit(1)
                            }
                            if let badge = sourceBadge, !badge.isEmpty {
                                Text(verbatim: badge)
                                    .flowType(.caption)
                                    .foregroundStyle(FlowColor.tertiaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(FlowColor.hover, in: Capsule())
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(DurationText.clock(track.duration))
                        .flowType(.homeSecondary).monospacedDigit()
                        .foregroundStyle(FlowColor.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("播放：\(display.title)"))
            if isDownloadingOffline {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .accessibilityLabel(Text("正在离线保存"))
            } else if let onToggleOffline {
                FlowIconButton(systemName: isOffline ? "arrow.down.circle.fill" : "arrow.down.circle",
                               label: isOffline ? "移除离线" : "离线保存", isActive: isOffline,
                               size: 34, symbolSize: 15, prominent: true, action: onToggleOffline)
            }
            if let onFavorite {
                FlowIconButton(systemName: isFavorite ? "star.fill" : "star",
                               label: isFavorite ? "取消收藏" : "收藏", isActive: isFavorite,
                               size: 34, symbolSize: 15, prominent: true, action: onFavorite)
            }
            if let onRemove {
                FlowIconButton(systemName: removeSymbol, label: removeLabel,
                               size: 34, symbolSize: 15, prominent: true, action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovered || isCurrent ? FlowColor.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.control))
        .onHover { hovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkStore.didStoreNotification,
                                                        object: ArtworkStore.shared)) { note in
            guard (note.userInfo?[ArtworkStore.identityKey] as? TrackIdentity) == track.identity else { return }
            artworkToken &+= 1
        }
    }
}
