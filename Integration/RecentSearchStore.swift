import Foundation

/// 最近搜索过的关键词。
///
/// QQ 音乐/网易云在搜索框为空时会列出"最近搜索"，FLOW 之前什么都没有——
/// 搜过的词一走就没了，下次还得重新打。
///
/// 只存**关键词**，不存时间、不存结果：搜索词本身就是用户打出来的东西，
/// 没有必要为它留更多元数据。
struct RecentSearchStore {
    let defaults: UserDefaults
    var key = "search.recent"
    /// 最多留几条。太多了会挤掉搜索框下面的空间。
    static let limit = 8

    init(defaults: UserDefaults = RuntimeSandbox.defaults) {
        self.defaults = defaults
    }

    var all: [String] {
        (defaults.stringArray(forKey: key) ?? []).filter { !$0.isEmpty }
    }

    /// 记一条。同一个词再搜一次会移到最前，而不是出现两次。
    @discardableResult
    func record(_ raw: String) -> [String] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        var list = all.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        defaults.set(list, forKey: key)
        return list
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
