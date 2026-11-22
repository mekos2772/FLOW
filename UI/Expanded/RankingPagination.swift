import Foundation

/// 榜单分页的纯计算。
///
/// 抽出来是为了能直接测边界（池子只剩 1 条、正好一页、空池子），
/// 而不是把这段算术埋在视图里靠肉眼验。
enum RankingPagination {
    /// 一次铺多少条。
    static let pageSize = 24

    /// 「显示更多」之后应该显示多少条。
    static func nextCount(current: Int, pool: Int) -> Int {
        guard pool > 0 else { return 0 }
        return min(max(current, 0) + pageSize, pool)
    }

    static func canShowMore(current: Int, pool: Int) -> Bool {
        current < pool
    }
}
