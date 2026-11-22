import Foundation

/// 字节大小的显示。**全工程唯一实现**。
///
/// 之前完整播放器的设置页和 B 站账号页各写了一份一模一样的
/// `ByteCountFormatter`（在视图里每次渲染都新建一个）。
/// 这类格式化器构造不便宜，且两份实现迟早会漂移。
enum ByteText {
    /// 复用同一个 formatter。`ByteCountFormatter` 构造开销不小，放在静态属性里。
    /// 注意：它**不是**线程安全类型——当前调用方都在主 actor 上，所以这样声明；
    /// 若以后有非主线程调用方，要改成 per-call 构造或加锁。
    private nonisolated(unsafe) static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "—" }
        return formatter.string(fromByteCount: bytes)
    }
}
