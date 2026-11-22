import CryptoKit
import Foundation

typealias HLSAssetBuilder = @Sendable (HLSStreamRequest) async throws -> StreamingPreparedAsset

struct HLSStreamRequest: Sendable {
    let stream: AudioStreamDescriptor
    let session: URLSession
    let networkAllowed: @Sendable () -> Bool
}

/// HLS 的所有网络入口由播放器的本机代理转回此处；路由用 HMAC 认证，不能构造任意代理目标。
actor HLSResourceClient {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private let request: HLSStreamRequest
    private let key = SymmetricKey(size: .bits256)
    private let token = UUID().uuidString
    private var baseURL: URL?
    private var activeRequests = 0
    private var invalidated = false
    private static let maximumBytes = 16 * 1024 * 1024
    private static let uriPattern = try? NSRegularExpression(pattern: #"\bURI="([^"\r\n]*)""#)

    init(request: HLSStreamRequest) { self.request = request }

    func startURL(baseURL: URL) throws -> URL {
        self.baseURL = baseURL
        return try route(request.stream.url, playlist: true)
    }

    func invalidate() { invalidated = true }

    func reply(path: String, range: String? = nil, head: Bool = false) async throws -> Reply {
        guard !invalidated, activeRequests < 8 else { throw URLError(.cancelled) }
        guard request.networkAllowed() else { throw SourceDomainPolicy.Violation.networkDisabled }
        let url = try target(path)
        try validate(url)
        activeRequests += 1
        defer { activeRequests -= 1 }
        var upstream = URLRequest(url: url)
        upstream.httpShouldHandleCookies = false
        upstream.allHTTPHeaderFields = PluginHTTPClient.headers(request.stream.headers, from: request.stream.url, to: url)
        if let range {
            guard range.range(of: #"^bytes=[0-9]+-[0-9]*$"#, options: .regularExpression) != nil else {
                throw URLError(.badURL)
            }
            upstream.setValue(range, forHTTPHeaderField: "Range")
        }
        let (data, response) = try await PluginHTTPClient.data(
            for: upstream, session: request.session, allowedDomains: request.stream.allowedDomains,
            networkAllowed: request.networkAllowed, maximumBytes: Self.maximumBytes
        )
        try Task.checkCancellation()
        guard !invalidated, request.networkAllowed() else { throw URLError(.cancelled) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let finalURL = http.url ?? url
        try validate(finalURL)
        var body = data
        var contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let isPlaylist = data.starts(with: Data("#EXTM3U".utf8))
            || String(data: data.prefix(16), encoding: .utf8)?.hasPrefix("\u{feff}#EXTM3U") == true
        if isPlaylist {
            guard data.count <= 1024 * 1024, let playlist = String(data: data, encoding: .utf8) else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            body = Data(try rewrite(playlist, relativeTo: finalURL).utf8)
            contentType = "application/vnd.apple.mpegurl"
        } else if url.pathExtension.lowercased() == "m3u8" {
            throw URLError(.cannotParseResponse)
        }
        var headers = ["Content-Type": contentType, "Content-Length": String(body.count), "Cache-Control": "no-store"]
        if !isPlaylist {
            for name in ["Content-Range", "Accept-Ranges"] {
                if let value = http.value(forHTTPHeaderField: name) { headers[name] = value }
            }
        }
        return Reply(status: isPlaylist ? 200 : http.statusCode, headers: headers, body: head ? Data() : body)
    }

    private func validate(_ url: URL) throws {
        _ = try SourceDomainPolicy.validate(url: url, allowedDomains: request.stream.allowedDomains)
        if let host = url.host, !SourceDomainPolicy.isSameOrigin(request.stream.url, as: url),
           !SourceDomainPolicy.isPrivateOrLoopbackHost(request.stream.url.host ?? ""),
           SourceDomainPolicy.isPrivateOrLoopbackHost(host) {
            throw SourceDomainPolicy.Violation.disallowedDomain(host: host, allowed: request.stream.allowedDomains)
        }
        guard url.user == nil, url.password == nil else { throw URLError(.badURL) }
    }

    private func route(_ url: URL, playlist: Bool = false) throws -> URL {
        try validate(url)
        guard let baseURL else { throw URLError(.badURL) }
        let payload = Data(url.absoluteString.utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        let ext = playlist ? "m3u8" : url.pathExtension.lowercased()
        let suffix = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "bin"
        return baseURL.appendingPathComponent(token).appendingPathComponent(Self.encode(signature))
            .appendingPathComponent("\(Self.encode(payload)).\(suffix)")
    }

    private func target(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == token,
              let signature = Self.decode(String(parts[1])),
              let data = Self.decode((String(parts[2]) as NSString).deletingPathExtension),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: key),
              let raw = String(data: data, encoding: .utf8), let url = URL(string: raw) else {
            throw URLError(.noPermissionsToReadFile)
        }
        return url
    }

    private func rewrite(_ playlist: String, relativeTo origin: URL) throws -> String {
        guard let uriPattern = Self.uriPattern else { throw URLError(.cannotParseResponse) }
        var lines: [String] = []
        var nextIsPlaylist = false
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 动态变量和内容引导会引入未经过路由的第二套 URL 解析，暂不支持，拒绝直连降级。
            guard !line.hasPrefix("#EXT-X-CONTENT-STEERING:"), !line.hasPrefix("#EXT-X-DEFINE:") else {
                throw URLError(.unsupportedURL)
            }
            if line.isEmpty { lines.append(""); continue }
            if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
                lines.append(try route(url, playlist: nextIsPlaylist).absoluteString)
                nextIsPlaylist = false
                continue
            }
            var rewritten = line
            let matches = uriPattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: rewritten),
                      let url = URL(string: String(rewritten[range]), relativeTo: origin)?.absoluteURL else {
                    throw URLError(.badURL)
                }
                let isPlaylist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                    || line.hasPrefix("#EXT-X-RENDITION-REPORT:")
                rewritten.replaceSubrange(range, with: try route(url, playlist: isPlaylist).absoluteString)
            }
            // 非法或未识别的 URI 属性不得原样流到 AVFoundation。
            if line.contains("URI="), matches.isEmpty { throw URLError(.cannotParseResponse) }
            nextIsPlaylist = line.hasPrefix("#EXT-X-STREAM-INF:") || nextIsPlaylist
            lines.append(rewritten)
        }
        return lines.joined(separator: "\n")
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ string: String) -> Data? {
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}
