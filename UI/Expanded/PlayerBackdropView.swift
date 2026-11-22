import SwiftUI

/// 普通播放页的背景层：纯色（原来的黑白版面）、封面取色，或和沉浸共用的动态场景。
///
/// 场景背景铺在整页界面后面，上面压一层暗色保证文字、按钮读得清；
/// 省电档运行（24 帧、降分辨率），窗口被遮挡时照旧暂停。
struct PlayerBackdropView: View {
    @Bindable var model: MorphPresentationModel
    let background: PlayerBackground
    let palette: ImmersivePalette

    @Environment(\.app) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch background {
        case .solid:
            Surface.windowBase(colorScheme)
        case .artwork:
            ArtworkBackdrop(palette: palette)
                .overlay(Color.black.opacity(0.28))
        default:
            if let scene = background.scene {
                ZStack {
                    ImmersiveSceneView(configuration: configuration(scene),
                                       mediaClock: { [weak playback = app?.playback] in playback?.currentPosition })
                    // 普通页满是文字和控件，比沉浸页压得更暗；上沿再深一点托住顶栏。
                    LinearGradient(colors: [Color.black.opacity(0.62), Color.black.opacity(0.46)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .onAppear { AudioFeatureMeter.shared.acquire() }
                .onDisappear { AudioFeatureMeter.shared.release() }
            }
        }
    }

    private func configuration(_ scene: ImmersiveSceneKind) -> ImmersiveRenderer.Configuration {
        ImmersiveRenderer.Configuration(
            scene: scene,
            palette: palette,
            seed: ImmersivePlayerView.seed(for: model.track),
            isPlaying: model.isPlaying && !model.isMuted && model.volume > 0.001,
            response: app?.appearance.immersiveResponse ?? .default,
            reduceMotion: reduceMotion,
            powerSaving: true,
            lyricZone: .zero,
            beatSync: app?.appearance.immersiveBeatSync ?? .default,
            isAdvancing: model.isPlaying
        )
    }
}
