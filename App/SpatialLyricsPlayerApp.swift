import SwiftUI

@main
struct SpatialLyricsPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 刻意没有 WindowGroup：播放器本身就是那一个窗口，
        // 由 `MorphWindowController` 持有并负责五种形态之间的连续变形。
        // 用 SwiftUI 的 WindowGroup 会拿到一个系统窗口，无法与悬浮形态共用一个实体。

        MenuBarExtra {
            MenuBarPanel()
                .environment(\.app, appDelegate.container)
        } label: {
            Label("FLOW", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(\.app, appDelegate.container)
                .tint(.primary)
        }
    }

    private var menuBarSymbol: String {
        let playback = appDelegate.container.playback
        if playback.state.isPlaying { return "waveform" }
        if playback.currentTrack != nil { return "pause.circle" }
        return "music.note"
    }
}
