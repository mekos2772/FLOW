import AppKit

/// App 生命周期。Phase 0 只保证：单实例、关窗不退、容器可构建。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statePersistenceTask: Task<Void, Never>?

    /// 单元测试的宿主进程也在跑这个 AppDelegate，默认会走 `.app` 分支去打开
    /// **用户真实的** SQLite 库。如果这时正式 App 也开着，两个进程并发写同一个库，
    /// SwiftData 会把它判成损坏并隔离——实测两小时内隔离了两次，收藏被清空。
    /// 测试宿主一律用内存库，绝不碰用户数据。
    private static var isRunningTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        // UI 测试跑的是**独立进程**（没有 XCTestConfigurationFilePath），
        // 但同样不能碰使用者数据。用启动参数显式标记。
        return ProcessInfo.processInfo.arguments.contains("-SLP_UITest")
    }

    private(set) lazy var container: AppContainer = {
        if Self.isRunningTests {
            return ContainerBuilder.makeFallback()
        }
        do {
            return try ContainerBuilder.make(.app)
        } catch {
            // 不允许静默降级。
            //
            // 这里**只**走 `RedactingLog`。原先后面还跟了一句 `NSLog(...)`，
            // 把原始错误直接写进系统日志——错误里可能带用户目录路径，
            // 绕过脱敏门面（工程自己的规矩：所有对外日志必须经过 `RedactingLog`）。
            RedactingLog.error("container build failed, running without the local store: \(error)")
            // 数据库打不开不该把整个播放器变成一个空壳：设置照常读写、在线音源照常可用，
            // 只是这次运行不落库。之前的兜底用的是内存设置 + 示例曲库，
            // 用户看到的是偏好全部失效、一首歌也搜不了。
            let container = (try? ContainerBuilder.make(.degraded)) ?? ContainerBuilder.makeFallback()
            container.degradedReason = "本地数据库这次没能打开：收藏、歌单和播放记录暂时不可用，这次的改动也不会保存；在线播放不受影响。数据文件原样保留，没有被改动。"
            return container
        }
    }()

    /// 这个进程是不是"后来的那一个"（已经有别的 FLOW 在跑，自己马上要退出）。
    ///
    /// 置位之后**不允许再碰 `container`**：它是 lazy 的，一碰就会打开数据库、
    /// 写一份空队列、做一次备份、给小组件发"已停止"——全都发生在正主还开着同一个库的时候。
    /// 单实例保护要防的恰恰就是这件事。
    private var isSecondaryInstance = false

    /// 深链与本地音频文件/目录入口：支持 Finder 打开音频或 `spatiallyrics://` 深链。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !isSecondaryInstance else { return }
        var localURLs: [URL] = []
        // 深链由路由统一处理（openPlayer 自己会展开），这里不要再补一次 expand——
        // 否则 `spatiallyrics://morph/capsule` 会先切成胶囊、立刻又被拉回完整形态。
        for url in urls {
            if url.isFileURL {
                localURLs.append(url)
            } else {
                _ = DeepLinkRouter.handle(url, floating: container.floatingLyrics, morph: container.morph)
            }
        }
        if !localURLs.isEmpty {
            let app = container
            Task { @MainActor in
                let opened = await app.sourceManager.openLocalAudioURLs(localURLs)
                if let first = opened.first {
                    app.playbackEngine.setQueue(opened, current: first)
                    await app.playback.load(first, autoplay: true)
                }
                app.morph.setMorphology(.expanded)
            }
        }
    }

    /// 调试：`SLP_DEBUG_PLAY_PATH=/path/to/song.m4a` 启动即打开本地音频（验收用，正式界面不感知）。
    private func playDebugTrackIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SLP_DEBUG_PLAY_PATH"], !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            let opened = await container.sourceManager.openLocalAudioURLs([url])
            if let track = opened.first {
                container.playbackEngine.setQueue(opened, current: track)
                await container.playback.load(track, autoplay: true)
            }
        }
    }

    /// 已经有别的 FLOW 在跑就把那个叫到前台，自己退出。返回 true 表示本进程要退出。
    ///
    /// **必须在最早的生命周期回调里做**：`application(_:open:)`（深链冷启动）
    /// 可能早于 `applicationDidFinishLaunching`，而它一碰到 `container`
    /// 就会打开 SQLite 库——那时再退出，两个进程已经同时碰过库了。
    private func enforceSingleInstance() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        guard let bundleID = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                  .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        else { return false }
        isSecondaryInstance = true
        other.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 最早能拦的地方。
        _ = enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：已经有别的 FLOW 在跑，就把那个叫到前台，自己退出。
        //
        // 注释里一直写着"保证单实例"，但从来没实现过。后果是实打实的：
        // `open -n` 能开出任意多个播放器，每个都有自己的播放引擎，
        // 并且**同时打开同一个 SQLite 库**——之前那次数据库被判损坏、收藏被清空，
        // 就是这么来的。
        if enforceSingleInstance() { return }

        // 隐藏 Dock 图标：设置里开了就用 accessory，否则常驻 Dock。
        // 这是公开 API，不需要私有手段；切换即时生效，不需要重启。
        NSApp.setActivationPolicy(container.settings.hideDockIcon ? .accessory : .regular)
        playDebugTrackIfRequested()
        // 调试钩子：强制浅/深色，用于截图复核两套外观（不影响任何业务逻辑）。
        switch ProcessInfo.processInfo.environment["SLP_DEBUG_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // 测试宿主在方法开头就已经 return 了（见上），这里不必再判一次。
        let fade = FadeDriver(playback: container.playback, clock: container.clock)
        let routeMonitor = AudioRouteMonitor(
            playback: container.playback,
            policy: AudioRoutePolicy(pauseOnHeadphoneUnplug: container.settings.pauseOnHeadphoneUnplug))
        container.attachAudioRouteMonitor(routeMonitor)
        routeMonitor.start()
        container.privacy.loadMeetingApps()
        Task { @MainActor in
            // 会议模式：前台应用变化时更新遮罩状态。用 NSWorkspace 通知，不轮询。
            for await _ in NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didActivateApplicationNotification) {
                container.privacy.updateFrontmost(bundleID: nil)
            }
        }
        container.attachSleepTimer(SleepTimerDriver(
            playback: container.playback,
            clock: container.clock,
            fade: fade,
            fadeOutDuration: .milliseconds(container.appearance.fadeOutMillis)))
        // 形态窗口：播放器这件东西在桌面上的唯一载体。
        container.morph.start()
        container.playback.setVolume(Float(container.settings.engineVolume))
        container.systemMedia.start()
        container.widgetBridge.start()

        // 冷启动恢复：队列 + 上次曲目 + 进度 + 播放模式。恢复后不自动播放。
        container.sessionPersistence.beginInitialRestore()
        Task { @MainActor in
            _ = await container.sessionPersistence.restore()
            // 小组件上点过的按钮要等现场恢复之后再执行：
            // 之前是先执行再恢复，"播放"落在一个空引擎上被直接丢掉，点了等于没点。
            container.widgetBridge.drainCommands()
        }

        // 调试播放默认静音：测试音轨不该从扬声器里出来
        // （之前用 440Hz 正弦波做样本，一播放把人吓了一跳）。
        if ProcessInfo.processInfo.environment["SLP_DEBUG_MUTE"] == "1" {
            container.playback.setVolume(0)
        }

        // 调试钩子：启动后播放库里的第一首（只读环境变量，走真实播放链路）。
        if ProcessInfo.processInfo.environment["SLP_DEBUG_PLAY"] == "1" {
            Task { @MainActor in
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(900))
                    let all = (try? await container.tracks.all()) ?? []
                    if let first = all.first {
                        await container.playbackEngine.load(first, autoplay: true)
                        return
                    }
                }
            }
        }

        // 状态变化时节流落库，避免每次播放/暂停都写一次数据库。
        statePersistenceTask = Task { @MainActor in
            for await _ in container.playback.stateUpdates() {
                container.sessionPersistence.scheduleSave()
            }
        }
        hasFinishedLaunching = true
        #if DEBUG
        // 验收驱动器：仅 Debug，且只在设了 `SLP_QA_DIR` 时存在（见 `QAHarness`）。
        if let harness = QAHarness(container: container) {
            harness.start()
            qaHarness = harness
        }
        #endif
    }

    #if DEBUG
    private var qaHarness: QAHarness?
    #endif

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasFinishedLaunching else { return }
        container.widgetBridge.drainCommands()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard hasFinishedLaunching else { return }
        container.sessionPersistence.saveNow()
    }

    /// 启动流程是否已经走完（第二个实例永远不会走完）。
    private var hasFinishedLaunching = false

    func applicationWillTerminate(_ notification: Notification) {
        // 没启动完（包括"后来的那个实例"）就什么都别收尾：没有东西可收，
        // 而一收尾就会去碰数据库（见 `isSecondaryInstance`）。
        guard hasFinishedLaunching, !isSecondaryInstance else { return }
        statePersistenceTask?.cancel()
        HotkeyCenter.shared.unregisterAll()
        container.morph.shutdown()
        container.voice?.shutdown()
        container.sessionPersistence.saveNow()
        // saveNow 只把队列/状态同步写进库；曲目落库派生在 async Task 里，
        // 这里一返回进程就可能被杀——新排的曲目写不进去，重启后队列缩水。
        // 限时等它落完（见 waitForPendingTrackSaves）。
        container.sessionPersistence.waitForPendingTrackSaves()
        // 退出前留一份健康快照。库文件此刻一定已经落盘，
        // 这是最可靠的备份时机（打开瞬间文件可能还没创建）。
        container.persistence.backUpStoreNow()
        // 小组件时间线是 `.never`：退出前必须发布"已停止"，否则它会一直显示在播放。
        container.widgetBridge.stop()
        container.widgetBridge.publishStoppedState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 没有标准主窗口之后，点击 Dock 图标必须回到完整播放器，
    /// 否则用户会以为应用没反应。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard hasFinishedLaunching else { return true }
        if container.morph.allowsActivationExpansion { container.morph.expand() }
        return true
    }
}
