#if DEBUG
import AppKit
import SwiftUI

/// 验收用的**进程内驱动器**。只存在于 Debug 构建，且只在设了 `SLP_QA_DIR` 时启动。
///
/// 为什么需要：逐页验收要"看得见、点得到"，而截屏和合成鼠标事件分别要屏幕录制与
/// 辅助功能两项系统权限——没有权限的环境里（CI、远程会话）这两条路都走不通。
/// 应用给**自己的**窗口截图、往**自己的**事件队列里投点击，不需要任何权限，
/// 走的又是真实的命中测试与 SwiftUI 手势链路。
///
/// 协议很土：往目录里丢 `<序号>.cmd`（一行指令），执行完写回 `<序号>.out`。
@MainActor
final class QAHarness {
    private let directory: URL
    private unowned let container: AppContainer
    private var task: Task<Void, Never>?
    private var processed = Set<String>()

    init?(container: AppContainer) {
        guard let raw = ProcessInfo.processInfo.environment["SLP_QA_DIR"], !raw.isEmpty else { return nil }
        directory = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.container = container
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                await self?.drain()
            }
        }
    }

    private func drain() async {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".cmd") && !processed.contains($0) }
            .sorted()
        for name in names {
            processed.insert(name)
            let url = directory.appendingPathComponent(name)
            let line = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result = await run(line)
            let out = directory.appendingPathComponent(name.replacingOccurrences(of: ".cmd", with: ".out"))
            try? result.write(to: out, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 指令

    private func run(_ line: String) async -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return "ERR empty" }
        let rest = parts.count > 1 ? parts[1] : ""
        let args = rest.split(separator: " ").map(String.init)

        switch verb {
        case "windows":
            return NSApp.windows.map { describe($0) }.joined(separator: "\n")
        case "shot":
            // shot <文件名> [main|settings|menubar|sheet|front] [light|dark|clear]
            guard let name = args.first else { return "ERR name" }
            // 只允许安全文件名：`../` 会写到 SLP_QA_DIR 外。
            guard name.range(of: #"^[A-Za-z0-9_-]+(\.png)?$"#, options: .regularExpression) != nil else {
                return "ERR unsafe name"
            }
            let target = args.count > 1 ? args[1] : "main"
            let backdrop = args.count > 2 ? args[2] : "clear"
            guard let window = window(named: target) else { return "ERR no window \(target)" }
            guard let data = snapshot(window, backdrop: backdrop) else { return "ERR snapshot failed" }
            let url = directory.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
            do { try data.write(to: url) } catch { return "ERR write \(error)" }
            return "OK \(url.path) \(Int(window.frame.width))x\(Int(window.frame.height))"
        case "click", "rclick", "dclick":
            // click <x> <y> [窗口]  —— 坐标是窗口内的点，原点在左上角
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { return "ERR args" }
            guard let window = window(named: args.count > 2 ? args[2] : "main") else { return "ERR no window" }
            click(window, x: x, y: y, right: verb == "rclick", count: verb == "dclick" ? 2 : 1)
            return "OK"
        case "hover":
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { return "ERR args" }
            guard let window = window(named: args.count > 2 ? args[2] : "main") else { return "ERR no window" }
            hover(window, x: x, y: y)
            return "OK"
        case "type":
            return insertText(rest) ? "OK" : "ERR no text responder"
        case "replace":
            return insertText(rest, replacingAll: true) ? "OK" : "ERR no text responder"
        case "key":
            guard let code = args.first.flatMap(UInt16.init) else { return "ERR keycode" }
            key(code, modifiers: Array(args.dropFirst()))
            return "OK"
        case "scroll":
            guard args.count >= 3, let x = Double(args[0]), let y = Double(args[1]), let dy = Double(args[2]) else {
                return "ERR args"
            }
            guard let window = window(named: args.count > 3 ? args[3] : "main") else { return "ERR no window" }
            return scroll(window, x: x, y: y, dy: dy)
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            window(named: "main")?.makeKeyAndOrderFront(nil)
            return "OK"
        case "morph":
            guard let morphology = args.first.flatMap(PlayerMorphology.init(rawValue:)) else { return "ERR morph" }
            container.morph.setMorphology(morphology)
            return "OK"
        case "shape":
            guard let shape = args.first.flatMap(LyricsShape.init(rawValue:)) else { return "ERR shape" }
            container.morph.setFloatingShape(shape)
            return "OK"
        case "frame":
            // frame <x> <y> <w> <h>  —— 直接摆主窗口（屏幕坐标，左下原点）
            guard args.count == 4, let x = Double(args[0]), let y = Double(args[1]),
                  let w = Double(args[2]), let h = Double(args[3]),
                  let window = window(named: "main") else { return "ERR args" }
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            return "OK"
        case "immersive":
            // immersive on|off —— 走窗口控制器的真实入口（含全屏进出）
            guard let controller = container.morph as? MorphWindowController else { return "ERR" }
            controller.setImmersive(args.first != "off")
            return "OK immersive=\(controller.model.isImmersive)"
        case "player-background":
            // 不带参数时读回当前背景和沉浸场景（验收真实点击画廊后核对用）。
            guard let raw = args.first else {
                return "background=\(container.appearance.playerBackground.rawValue) scene=\(container.appearance.immersiveScene.rawValue)"
            }
            guard let background = PlayerBackground(rawValue: raw) else { return "ERR background" }
            container.appearance.setPlayerBackground(background)
            return "OK"
        case "mode":
            // mode normal|floating|immersive —— 走右上角三档的同一个入口
            guard let mode = args.first.flatMap(PlayerMode.init(rawValue:)),
                  let controller = container.morph as? MorphWindowController else { return "ERR mode" }
            controller.setPlayerMode(mode)
            return "OK mode=\(controller.playerMode.rawValue)"
        case "immersive-fullscreen":
            // 验收时用户可能正在用电脑：关掉"进入时全屏"，沉浸在窗口里进行，不切桌面空间。
            container.appearance.setImmersiveEntersFullScreen(args.first != "off")
            return "OK fullscreen=\(container.appearance.immersiveEntersFullScreen)"
        case "immersive-scene":
            guard let scene = args.first.flatMap(ImmersiveSceneKind.init(rawValue:)) else { return "ERR scene" }
            container.appearance.setImmersiveScene(scene)
            return "OK"
        case "immersive-state":
            return ImmersiveRenderer.active?.debugSummary ?? "ERR no renderer"
        case "immersive-onsets":
            // 电平表里的起音格子：歌曲时间是否连续、格长是否稳定（节拍跟踪靠它们）。
            var frames: [AudioOnsetFrame] = []
            _ = AudioFeatureMeter.shared.onsets(after: 0, into: &frames)
            guard frames.count > 2 else { return "onsets=\(frames.count)" }
            let raw = zip(frames, frames.dropFirst()).map { $1.mediaTime - $0.mediaTime }
            let gaps = raw.sorted()
            let hop = frames.last!.duration
            // 最近一段（最后一次大跳之后）的格子数与时间跨度：格子是否连续、有没有丢。
            let lastJump = raw.lastIndex { abs($0) > 0.5 } ?? -1
            let tail = frames[(lastJump + 1)...]
            let backwards = raw.filter { $0 < hop * 0.5 }.count
            let skips = raw.filter { $0 > hop * 1.5 && $0 < 0.5 }.count
            return String(format: "onsets=%d first=%.3f last=%.3f hop=%.4f gapMin=%.4f gapMedian=%.4f gapMax=%.4f tail=%d span=%.3f backwards=%d skips=%d position=%.3f",
                          frames.count, frames.first!.mediaTime, frames.last!.mediaTime, hop,
                          gaps.first!, gaps[gaps.count / 2], gaps.last!, tail.count,
                          (tail.last?.mediaTime ?? 0) - (tail.first?.mediaTime ?? 0), backwards, skips,
                          container.playback.currentPosition)
        case "immersive-beats":
            // 最近 20 秒强起音与预测拍点（含半拍）的对齐情况，实机验收节拍跟踪用。
            guard let d = ImmersiveRenderer.active?.beatDiagnostics else { return "ERR no renderer" }
            return String(format: "tempo=%.1f confidence=%.2f strongOnsets=%d aligned=%.2f meanOffset=%+.0fms",
                          d.tempo, d.confidence, d.strongOnsets, d.alignedRatio, d.meanOffsetMilliseconds)
        case "drawer":
            guard let controller = container.morph as? MorphWindowController else { return "ERR" }
            let panel = args.first.flatMap(AuxiliaryPanel.init(rawValue:))
            controller.model.auxiliary = panel
            container.noteAuxiliaryActivity(panel != nil)
            return "OK"
        case "settings":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return "OK"
        case "menubar":
            return openMenuBarExtra() ? "OK" : "ERR no status item"
        case "appearance":
            switch args.first {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
            return "OK"
        case "play":
            guard let target = args.first else { return "ERR arg" }
            if target.hasPrefix("/") || target.hasPrefix("file://") {
                let url = target.hasPrefix("file://") ? (URL(string: target) ?? URL(fileURLWithPath: target)) : URL(fileURLWithPath: target)
                let opened = await container.sourceManager.openLocalAudioURLs([url])
                guard let track = opened.first else { return "ERR local" }
                container.playback.setQueue(opened, current: track)
                await container.playback.load(track, autoplay: true)
                return "OK"
            }
            guard let source = container.sourceManager.activeBrowseSource else { return "ERR no-source" }
            let found = (try? await container.sourceManager.search(query: target, aggregate: false)) ?? []
            let track = found.first ?? Track(sourceID: source.id, externalID: target, title: target, artist: "", album: nil, duration: 0)
            container.playback.setQueue([track], current: track)
            await container.playback.load(track, autoplay: true)
            return "OK"
        case "toggle": await container.playback.togglePlayback(); return "OK"
        case "pause": await container.playback.pause(); return "OK"
        case "next": await container.playback.skip(.next); return "OK"
        case "prev": await container.playback.skip(.previous); return "OK"
        case "stop": await container.playback.stop(); return "OK"
        case "seek":
            guard let seconds = args.first.flatMap(Double.init) else { return "ERR seconds" }
            await container.playback.seek(to: seconds)
            return "OK"
        case "volume":
            guard let value = args.first.flatMap(Float.init) else { return "ERR value" }
            container.playback.setVolume(value)
            return "OK"
        case "privacy":
            container.privacy.setEnabled(args.first == "on")
            return "OK"
        case "state":
            return state()
        case "wait":
            let ms = args.first.flatMap(Int.init) ?? 300
            try? await Task.sleep(for: .milliseconds(ms))
            return "OK"
        case "quit":
            NSApp.terminate(nil)
            return "OK"
        default:
            return "ERR unknown verb \(verb)"
        }
    }

    // MARK: - 窗口

    private func describe(_ window: NSWindow) -> String {
        let f = window.frame
        return "\(type(of: window)) title=\"\(window.title)\" visible=\(window.isVisible) key=\(window.isKeyWindow) "
            + "level=\(window.level.rawValue) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) "
            + "sheets=\(window.sheets.count) id=\(window.identifier?.rawValue ?? "-") number=\(window.windowNumber)"
    }

    private func window(named name: String) -> NSWindow? {
        let main = (container.morph as? MorphWindowController)?.debugPanel
        switch name {
        case "main": return main
        case "sheet": return NSApp.windows.first { !$0.sheets.isEmpty }?.sheets.last
            ?? NSApp.windows.first { $0.isSheet }
        case "settings":
            return NSApp.windows.first { window in
                window !== main && window.isVisible && !window.isSheet
                    && (window.identifier?.rawValue.contains("Settings") == true
                        || String(describing: type(of: window)).contains("Settings"))
            } ?? NSApp.windows.first { window in
                window !== main && window.isVisible && window.styleMask.contains(.titled)
                    && !String(describing: type(of: window)).contains("MenuBarExtra")
            }
        case "menubar":
            return NSApp.windows.first { String(describing: type(of: $0)).contains("MenuBarExtra") && $0.isVisible }
        case "popover":
            return NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        case "front":
            return NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                ?? NSApp.keyWindow ?? NSApp.orderedWindows.first
        default:
            return NSApp.windows.first { $0.title == name }
        }
    }

    /// 给自己的窗口截图。`backdrop` 决定透明区域垫什么底（悬浮形态是透明窗）。
    private func snapshot(_ window: NSWindow, backdrop: String) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard backdrop != "clear" else { return rep.representation(using: .png, properties: [:]) }

        let image = NSImage(size: bounds.size)
        image.lockFocus()
        (backdrop == "dark" ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.80, alpha: 1)).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let composed = NSBitmapImageRep(data: tiff) else { return nil }
        return composed.representation(using: .png, properties: [:])
    }

    // MARK: - 输入

    private func point(in window: NSWindow, x: Double, y: Double) -> NSPoint {
        NSPoint(x: x, y: Double(window.frame.height) - y)
    }

    private func click(_ window: NSWindow, x: Double, y: Double, right: Bool, count: Int) {
        let location = point(in: window, x: x, y: y)
        let down: NSEvent.EventType = right ? .rightMouseDown : .leftMouseDown
        let up: NSEvent.EventType = right ? .rightMouseUp : .leftMouseUp
        // 进事件队列而不是直接 `sendEvent`：SwiftUI 的按钮在 mouseDown 里会进一个
        // 跟踪循环，自己从队列里等 mouseUp；同步发送的话 mouseUp 永远排不上。
        for clicks in 1...count {
            for type in [down, up] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: clicks, pressure: type == down ? 1 : 0) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func hover(_ window: NSWindow, x: Double, y: Double) {
        let location = point(in: window, x: x, y: y)
        window.acceptsMouseMovedEvents = true
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func insertText(_ text: String, replacingAll: Bool = false) -> Bool {
        let responder = (window(named: "popover")?.firstResponder as? NSTextView)
            ?? (NSApp.keyWindow?.firstResponder as? NSTextView)
        guard let responder else { return false }
        if replacingAll { responder.selectAll(nil) }
        responder.insertText(text, replacementRange: responder.selectedRange())
        return true
    }

    private func key(_ code: UInt16, modifiers: [String]) {
        var flags: NSEvent.ModifierFlags = []
        for name in modifiers {
            switch name {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        let characters: String
        switch code {
        case 36: characters = "\r"
        case 49: characters = " "
        case 53: characters = "\u{1B}"
        default: characters = ""
        }
        guard let window = window(named: "front") else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func scroll(_ window: NSWindow, x: Double, y: Double, dy: Double) -> String {
        guard let root = window.contentView else { return "ERR no content" }
        let location = root.convert(point(in: window, x: x, y: y), from: nil)
        var view = root.hitTest(location)
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView, let document = scrollView.documentView else {
            return "ERR no scroll view at point"
        }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(clip.bounds.origin.y + (document.isFlipped ? dy : -dy), 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        return "OK offset=\(Int(target)) of \(Int(maxY))"
    }

    private func openMenuBarExtra() -> Bool {
        for window in NSApp.windows {
            guard let button = findStatusButton(in: window.contentView) else { continue }
            button.performClick(nil)
            return true
        }
        return false
    }

    private func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews {
            if let found = findStatusButton(in: child) { return found }
        }
        return nil
    }

    // MARK: - 状态

    private func state() -> String {
        guard let controller = container.morph as? MorphWindowController else { return "ERR" }
        let model = controller.model
        let playback = container.playback
        let queue = playback.queueSnapshot
        var lines: [String] = []
        lines.append("morphology=\(model.morphology.rawValue) transitioning=\(model.isTransitioning) animating=\(model.isAnimatingGeometry)")
        lines.append("frame=\(controller.currentFrame)")
        lines.append("playback=\(playback.state.debugLabel) position=\(String(format: "%.1f", playback.currentPosition)) duration=\(String(format: "%.1f", playback.duration))")
        lines.append("volume=\(playback.volume) muted=\(playback.isMuted) gain=\(playback.outputGain)")
        if let track = playback.currentTrack {
            let display = MorphPresentationModel.display(track)
            lines.append("track.raw=\(track.title) | \(track.artist) | \(track.externalID)")
            lines.append("track.display=\(display.title) | \(display.artist ?? "-")")
        } else {
            lines.append("track=nil")
        }
        lines.append("queue items=\(queue.items.count) nextUp=\(queue.nextUp.count) later=\(queue.later.count) repeat=\(queue.repeatMode.rawValue) shuffle=\(queue.isShuffling)")
        lines.append("lyrics=\(container.lyricEngine.state) lines=\(container.lyricEngine.document?.lines.count ?? 0) current=\(model.lyric.current?.text ?? "-")")
        lines.append("error=\(model.error.map { "\($0.title) / \($0.detail)" } ?? "-")")
        lines.append("auxiliary=\(model.auxiliary?.rawValue ?? "-") masked=\(model.isMasked) favorite=\(model.isFavorite)")
        let activeSources = container.sourceManager.enabledSources.map(\.id.rawValue).joined(separator: ",")
        lines.append("sources=\(activeSources.isEmpty ? "none" : activeSources) degraded=\(container.degradedReason ?? "-")")
        return lines.joined(separator: "\n")
    }
}
#endif
