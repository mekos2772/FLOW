import AppKit
import SwiftUI

/// 背景缩略图：用当前封面的调色板把每个场景离屏渲一张小静帧。
///
/// 不做实时小画面：四个场景同时跑就是四份 GPU 开销，而画廊只是用来"挑"的。
/// 换歌（调色板变了）才重渲，同一首歌反复打开画廊直接用缓存。
@MainActor
final class BackgroundThumbnails {
    static let shared = BackgroundThumbnails()

    private var palette: ImmersivePalette?
    private var images: [ImmersiveSceneKind: NSImage] = [:]
    private let renderer = ImmersiveRenderer(library: .shared, meter: AudioFeatureMeter())

    func image(for scene: ImmersiveSceneKind, palette: ImmersivePalette) -> NSImage? {
        if self.palette != palette {
            self.palette = palette
            images.removeAll()
        }
        if let cached = images[scene] { return cached }
        var configuration = ImmersiveRenderer.Configuration()
        configuration.scene = scene
        configuration.palette = palette
        renderer.update(configuration)
        renderer.settle()
        var u = ImmersiveUniforms.neutral
        let colors = palette.colors.map { SIMD4<Float>($0, 1) }
        u.palette0 = colors[0]; u.palette1 = colors[1]; u.palette2 = colors[2]
        u.palette3 = colors[3]; u.palette4 = colors[4]
        u.time = 40; u.flow = 36; u.energy = 0.5; u.lift = 0.6; u.seed = 0.37
        let width = 240, height = 150
        guard let cg = renderer.renderOffscreen(width: width, height: height, uniforms: u) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
        images[scene] = image
        return image
    }
}

/// 背景画廊：普通页列出纯色、封面取色和四个场景；沉浸页只列四个场景。
struct BackgroundGalleryView: View {
    enum Context {
        case player
        case immersive
    }

    let context: Context
    let palette: ImmersivePalette
    let selection: PlayerBackground
    let onSelect: (PlayerBackground) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var options: [PlayerBackground] {
        switch context {
        case .player: return PlayerBackground.allCases
        case .immersive: return PlayerBackground.allCases.filter { $0.scene != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("背景")
                .flowType(.homeControl)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 10), count: 3), spacing: 12) {
                ForEach(options, id: \.self) { option in
                    tile(option)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private func tile(_ option: PlayerBackground) -> some View {
        let selected = option == selection
        return Button { onSelect(option) } label: {
            VStack(alignment: .leading, spacing: 6) {
                preview(option)
                    .frame(width: 120, height: 75)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? Color.primary : FlowColor.hairline, lineWidth: selected ? 2 : 1)
                    )
                Text(option.displayName)
                    .flowType(.homeSecondary)
                    .foregroundStyle(selected ? Color.primary : FlowColor.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.displayName))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("background.\(option.rawValue)")
    }

    @ViewBuilder
    private func preview(_ option: PlayerBackground) -> some View {
        switch option {
        case .solid:
            Surface.windowBase(colorScheme)
        case .artwork:
            ArtworkBackdrop(palette: palette)
        default:
            if let scene = option.scene, let image = BackgroundThumbnails.shared.image(for: scene, palette: palette) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                palette.color(1)
            }
        }
    }
}

/// 封面取色背景：底色到主体色的竖向渐变，右上角一团很淡的点缀色光——安静、不抢字。
struct ArtworkBackdrop: View {
    let palette: ImmersivePalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.color(2), palette.color(1), palette.color(0)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [palette.color(3).opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
        }
    }
}
