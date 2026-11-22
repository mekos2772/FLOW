import Foundation
@testable import SpatialLyricsPlayer

/// 拦截 `URLSession` 的假传输层：按 host+path 返回预置 JSON，并记录请求。
///
/// B 站链路之前无法离线测，因为 `BiliService` 内部自建 `URLSession`。
/// 现在 `BiliService.init(client:)` 可以注入，配这个假层就能跑通整条逻辑。
final class FakeBiliTransport: URLProtocol {

    /// path 关键字 → 响应体（`nil` 表示 404）。
    /// 响应体可以是对象也可以是数组（LRCLIB 的 `/search` 返回的就是数组）。
    nonisolated(unsafe) static var routes: [(match: String, body: Any?)] = []
    /// 已发出的请求（完整 URL，含 query，按顺序）。
    ///
    /// 记完整 URL 而不是路径：像"分P 取流必须带 cid=300"这种断言，
    /// 只看路径是验不出来的（会退化成"调用过就算通过"的假测试）。
    nonisolated(unsafe) static var requested: [String] = []

    static func reset() {
        routes = []
        requested = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeBiliTransport.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let full = request.url?.absoluteString ?? ""
        FakeBiliTransport.requested.append(full)

        // 按**完整 URL** 匹配：`aisubtitle` / `lrclib.net` 这些关键字出现在 host 上，
        // 只看 path 永远匹配不到（第一版就栽在这里）。
        guard let route = FakeBiliTransport.routes.first(where: { full.contains($0.match) }),
              let body = route.body else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // 支持三种响应体：原始 Data、纯文本、JSON 对象/数组。
        // 之前只支持 JSON 且用了 `try!`——传字符串会直接崩掉整个测试进程。
        let data: Data
        if let raw = body as? Data {
            data = raw
        } else if let text = body as? String {
            data = Data(text.utf8)
        } else if let json = try? JSONSerialization.data(withJSONObject: body) {
            data = json
        } else {
            data = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
