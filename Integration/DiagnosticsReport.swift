import Foundation

/// 诊断信息报告（规格 14「高级 → 诊断信息 / 日志导出」）。
///
/// 只渲染调用方给的事实，不主动去读用户数据；所有字符串最后统一过
/// `RedactingLog.sanitize`，保证导出的文件里不会出现用户目录或令牌。
struct DiagnosticsReport {
    struct Facts: Sendable {
        var appVersion: String
        var osVersion: String
        var schemaVersion: String
        var accessibilityState: String
        var queueCount: Int
        var floatingShape: String
        var privacyModeEnabled: Bool
        var sleepTimerArmed: Bool
        /// 存储健康状态：正常 / 曾从备份恢复 / 隔离过损坏文件。
        /// 数据被恢复过这件事**必须**让用户能看到——备份可能落后几次改动。
        var storageState: String
        /// 运行模式：正常 / 降级（临时设置 + 示例曲库，不写盘）。
        var runtimeMode: String
        /// 小组件共享容器是否可用（App Group 需要签名与描述文件）。
        var widgetShared: String
    }

    /// 纯函数：同样的输入永远生成同样的文本，方便测试逐行断言。
    @MainActor static func render(_ facts: Facts) -> String {
        let lines = [
            "Spatial Lyrics Player 诊断信息",
            "生成时间: \(timestamp())",
            "应用版本: \(facts.appVersion)",
            "macOS: \(facts.osVersion)",
            "数据库 Schema: \(facts.schemaVersion)",
            "辅助功能权限: \(facts.accessibilityState)",
            "播放队列: \(facts.queueCount) 首",
            "悬浮形态: \(facts.floatingShape)",
            "隐私模式: \(facts.privacyModeEnabled ? "开启" : "关闭")",
            "睡眠定时: \(facts.sleepTimerArmed ? "已设定" : "未设定")",
            "本地存储: \(facts.storageState)",
            "运行模式: \(facts.runtimeMode)",
            "小组件数据共享: \(facts.widgetShared)",
        ]
        return RedactingLog.sanitize(lines.joined(separator: "\n")) + "\n"
    }

    /// 时间戳。可注入是为了测试能固定它；用 @MainActor 隔离，
    /// 避免 Swift 6 把可变全局状态当成并发风险。
    @MainActor static var timestampProvider: @Sendable () -> String = {
        ISO8601DateFormatter().string(from: Date())
    }

    @MainActor private static func timestamp() -> String { timestampProvider() }
}
