import Foundation

/// 淡入淡出。
///
/// 为什么需要：在线曲目每次切歌都是"新的一条流从 0 开始"，硬切会有明显的爆音/突兀感；
/// 本地曲目同样。0.12s 的等功率淡变能把这个毛刺抹掉，代价几乎为零。
///
/// 这里只做**曲线**和**调度**，不碰播放器：
/// 曲线是纯函数（可穷举测试），调度由一个 actor 按 20ms 步进调 `applyVolume`。
enum AudioFade {
    /// 是否启用淡变。默认开启；关闭后 `fadeDuration` 直接返回 0（等于硬切）。
    /// 存在 UserDefaults 而不是路由到会话：会话是 Sendable 值，拿不到 settings 依赖。
    static var isEnabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["SLP_DISABLE_FADE"] == "1" { return false }
            let defaults = RuntimeSandbox.defaults
            if defaults.object(forKey: "settings.audioFadeEnabled") == nil { return true }
            return defaults.bool(forKey: "settings.audioFadeEnabled")
        }
        set { RuntimeSandbox.defaults.set(newValue, forKey: "settings.audioFadeEnabled") }
    }


    enum Kind: Sendable, Equatable {
        case fadeIn
        case fadeOut
    }

    /// 等功率（sin/cos）曲线，比线性听起来更均匀。
    ///
    /// - Parameter progress: 0…1
    /// - Returns: 0…1 的增益系数
    static func gain(progress: Double, kind: Kind) -> Float {
        let clamped = max(0, min(1, progress))
        let angle = clamped * .pi / 2
        switch kind {
        case .fadeIn: return Float(sin(angle))
        case .fadeOut: return Float(cos(angle))
        }
    }

    /// 把一条淡变拆成若干步（步数由时长与步进间隔决定）。
    static func steps(duration: TimeInterval, interval: TimeInterval = 0.02) -> Int {
        guard duration > 0, interval > 0 else { return 0 }
        return max(1, Int((duration / interval).rounded()))
    }

    /// 每一步的增益序列。第一项是 0（起点），最后一项是 1（终点，针对淡入）。
    static func sequence(duration: TimeInterval, kind: Kind, interval: TimeInterval = 0.02) -> [Float] {
        let count = steps(duration: duration, interval: interval)
        guard count > 0 else { return [] }
        return (0...count).map { index in
            gain(progress: Double(index) / Double(count), kind: kind)
        }
    }
}

/// 音量淡变执行器。
///
/// 串行 actor：同一时刻只允许一条淡变在跑，新的淡变会取消旧的——
/// 快速连按播放/暂停时不会出现两条曲线互相打架。
actor AudioFadeRunner {
    private var task: Task<Void, Never>?
    private var currentVolume: Float = 1
    private(set) var isFading = false

    /// 淡变进行中改音量也要生效：每一步都按**最新**的基准音量算。
    func setBaseVolume(_ volume: Float) {
        currentVolume = max(0, min(1, volume))
    }

    /// 执行一次淡变。`apply` 会被逐步调用（应当是线程安全的音量设置）。
    func run(kind: AudioFade.Kind,
             duration: TimeInterval,
             target: Float,
             interval: TimeInterval = 0.02,
             apply: @escaping @Sendable (Float) async -> Void) async {
        task?.cancel()
        currentVolume = max(0, min(1, target))
        let sequence = AudioFade.sequence(duration: duration, kind: kind, interval: interval)
        guard !sequence.isEmpty else {
            task = nil
            isFading = false
            await apply(currentVolume)
            return
        }
        isFading = true
        let work = Task { [sequence, interval] in
            for gain in sequence {
                if Task.isCancelled { return }
                await apply(self.currentVolume * gain)
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
        task = work
        await work.value
        // 只有"自己还是最新那一条"才收尾。被新淡变顶掉的旧调用回到这里时，
        // 新的那条还在跑——这时把 `isFading` 清掉，音量滑杆的写入就会和淡变抢着改音量。
        if task == work {
            task = nil
            isFading = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isFading = false
    }
}
