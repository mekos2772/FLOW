import Foundation

/// 源无关的搜索请求。
struct SearchRequest: Hashable, Sendable {
    var query: String
    var limit: Int
    var offset: Int

    init(query: String, limit: Int = 20, offset: Int = 0) {
        self.query = query
        self.limit = max(1, limit)
        self.offset = max(0, offset)
    }
}
