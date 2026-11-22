import Foundation

/// 沉浸播放模式的场景。原始值用于持久化，改名要做迁移。
enum ImmersiveSceneKind: String, CaseIterable, Codable, Sendable, Equatable {
    /// 流光：暗房里被侧光照着、缓慢起伏的缎面（默认，适配任何封面）。
    case silk
    /// 雨窗：夜里隔着带雨的玻璃看街灯。
    case rain
    /// 远山：日落后的层峦、山谷雾与湖面。
    case ridge
    /// 光影：午后窗光与树影落在灰泥墙上。
    case light

    static let `default`: ImmersiveSceneKind = .silk

    var displayName: String {
        switch self {
        case .silk: return String(localized: "流光")
        case .rain: return String(localized: "雨窗")
        case .ridge: return String(localized: "远山")
        case .light: return String(localized: "光影")
        }
    }

    /// 对应的片元着色器函数名（见 `ImmersiveShaderSource`）。
    var fragmentFunction: String { "scene_\(rawValue)" }

    /// 内部渲染分辨率相对屏幕像素的比例。画面越柔，越可以低分辨率渲染再放大，
    /// 省下的 GPU 时间远比肉眼能看出的差别多；歌词是另一层，始终按屏幕分辨率绘制。
    var renderScale: Double {
        switch self {
        case .silk: return 0.5
        case .rain: return 0.75
        case .ridge: return 0.75
        case .light: return 0.66
        }
    }

    /// 循环切换时的下一个场景。
    var next: ImmersiveSceneKind {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// 画面随音乐变化的幅度。
enum ImmersiveResponse: String, CaseIterable, Codable, Sendable, Equatable {
    /// 不跟随音乐：画面按固定的慢节奏流动。
    case off
    /// 轻柔：幅度减半，适合长时间开着。
    case gentle
    /// 标准。
    case standard

    static let `default`: ImmersiveResponse = .standard

    var displayName: String {
        switch self {
        case .off: return String(localized: "不跟随")
        case .gentle: return String(localized: "轻柔")
        case .standard: return String(localized: "标准")
        }
    }

    /// 音频特征进入场景前乘的系数。
    var gain: Float {
        switch self {
        case .off: return 0
        case .gentle: return 0.5
        case .standard: return 1
        }
    }
}

/// 画面跟节拍走的程度。节拍动作都是顺滑的摆动，不做闪光；节拍不稳时自动淡出。
enum ImmersiveBeatSync: String, CaseIterable, Codable, Sendable, Equatable {
    case off
    /// 克制：每拍的波小一些，主要是小节第一拍那一下。
    case subtle
    /// 适中：每拍一道看得清的波（缎子起伏、倒影荡、涟漪、树影被推）。
    case standard
    /// 明显：波更大，小节第一拍那一下尤其明显。
    case strong

    static let `default`: ImmersiveBeatSync = .standard

    var displayName: String {
        switch self {
        case .off: return String(localized: "关")
        case .subtle: return String(localized: "克制")
        case .standard: return String(localized: "适中")
        case .strong: return String(localized: "明显")
        }
    }

    /// 小节第一拍额外加强的幅度。
    var barGain: Float {
        switch self {
        case .off: return 0
        case .subtle: return 0.6
        case .standard: return 1
        case .strong: return 1.3
        }
    }

    /// 每拍那道波的幅度。
    var beatGain: Float {
        switch self {
        case .off: return 0
        case .subtle: return 0.35
        case .standard: return 1
        case .strong: return 1.5
        }
    }
}

/// 播放页（普通形态）的背景。场景背景和沉浸共用同一套画面，选中某个场景时沉浸也换成它。
enum PlayerBackground: String, CaseIterable, Codable, Sendable, Equatable {
    /// 纯色：原来的黑白版面。
    case solid
    /// 封面取色：用封面的颜色铺一层安静的渐变。
    case artwork
    case silk
    case rain
    case ridge
    case light

    static let `default`: PlayerBackground = .solid

    init(scene: ImmersiveSceneKind) {
        self = PlayerBackground(rawValue: scene.rawValue) ?? .silk
    }

    /// 动态场景背景对应的场景；纯色、封面取色没有。
    var scene: ImmersiveSceneKind? { ImmersiveSceneKind(rawValue: rawValue) }

    var displayName: String {
        switch self {
        case .solid: return String(localized: "纯色")
        case .artwork: return String(localized: "封面取色")
        default: return scene?.displayName ?? rawValue
        }
    }
}
