import Foundation

/// 第三方音源插件与声明式模板共用的域名白名单与 URL 安全策略，及通用 JSON 路径抽取工具。
enum SourceDomainPolicy {
    enum Violation: LocalizedError, Sendable {
        case networkDisabled
        case invalidURL(String)
        case disallowedScheme(String)
        case disallowedDomain(host: String, allowed: [String])

        var errorDescription: String? {
            switch self {
            case .networkDisabled:
                return String(localized: "联网已关闭")
            case .invalidURL(let raw):
                return String(localized: "无效的请求地址：\(raw)")
            case .disallowedScheme(let scheme):
                return String(localized: "禁止非 HTTP/HTTPS 请求协议：\(scheme)")
            case .disallowedDomain(let host, let allowed):
                let list = allowed.isEmpty ? "-" : allowed.joined(separator: ", ")
                return String(localized: "域名不在音源白名单内：\(host)（允许：\(list)）")
            }
        }
    }

    /// 校验 URL 必须为合法 http/https，且满足插件/模板声明的 `allowedDomains`。
    static func validate(url urlString: String, allowedDomains: [String]) throws -> URL {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Violation.invalidURL(urlString)
        }
        return try validate(url: url, allowedDomains: allowedDomains)
    }

    static func validate(url: URL, allowedDomains: [String]) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Violation.disallowedScheme(url.scheme ?? "unknown")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw Violation.invalidURL(url.absoluteString)
        }
        let normalizedRules = allowedDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if normalizedRules.isEmpty || normalizedRules.contains("*") {
            return url
        }
        for rule in normalizedRules {
            if matches(host: host, pattern: rule) {
                return url
            }
        }
        throw Violation.disallowedDomain(host: host, allowed: allowedDomains)
    }

    static func matches(host: String, pattern: String) -> Bool {
        if host == pattern { return true }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return false
    }

    /// 识别回环、链路本地与内网私有地址，用于阻止公网接口通过重定向访问本机或内网服务（SSRF）。
    static func isPrivateOrLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":"), host == "::1" || host == "::" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (0, _): return true
        case (169, 254): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func isSameOrigin(_ lhs: URL, as rhs: URL) -> Bool {
        guard let ls = lhs.scheme?.lowercased(), let rs = rhs.scheme?.lowercased(), ls == rs,
              let lh = lhs.host?.lowercased(), let rh = rhs.host?.lowercased(), lh == rh else {
            return false
        }
        let lp = lhs.port ?? (ls == "https" ? 443 : 80)
        let rp = rhs.port ?? (rs == "https" ? 443 : 80)
        return lp == rp
    }

    /// 为 GitHub `raw.githubusercontent.com` 链接生成自动 CDN 回退候选（首选原直链，失败自动切 jsDelivr CDN）。
    static func rawGitHubMirrorCandidates(for url: URL) -> [URL] {
        guard url.host?.lowercased() == "raw.githubusercontent.com",
              url.query == nil else {
            return [url]
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4 else { return [url] }
        let owner = parts[0]
        let repo = parts[1]
        let ref = parts[2]
        let subPath = parts.dropFirst(3).map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
        }.joined(separator: "/")
        let cdnString = "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)@\(ref)/\(subPath)"
        if let cdnURL = URL(string: cdnString), cdnURL != url {
            return [url, cdnURL]
        }
        return [url]
    }

    /// 规范化社区导入 URL：重写 GitHub/Gitee `blob` 网页链接为直链，并对未转义空格与中文路径做安全百分号编码。
    static func normalizeImportURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        let rewritten = rewriteRepositoryBlobURL(trimmed)
        if let direct = URL(string: rewritten), let scheme = direct.scheme?.lowercased(), !scheme.isEmpty {
            return direct
        }
        let escaped = escapeUnencodedCharacters(in: rewritten)
        guard let url = URL(string: escaped), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        return url
    }

    /// 解析订阅清单中的绝对或相对导入地址；相对路径会基于清单来源 URL 自动补全。
    static func resolveImportURL(_ raw: String, relativeTo originURL: URL?) -> URL? {
        if let direct = normalizeImportURL(raw) {
            return direct
        }
        guard let originURL else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        let escaped = escapeUnencodedCharacters(in: trimmed)
        guard let resolved = URL(string: escaped, relativeTo: originURL)?.absoluteURL else {
            return nil
        }
        return normalizeImportURL(resolved.absoluteString) ?? resolved
    }

    private static func rewriteRepositoryBlobURL(_ raw: String) -> String {
        if raw.hasPrefix("https://github.com/"),
           let range = raw.range(of: "/blob/") {
            let prefix = raw["https://github.com/".endIndex..<range.lowerBound]
            let rest = raw[range.upperBound...]
            return "https://raw.githubusercontent.com/\(prefix)/\(rest)"
        }
        if raw.hasPrefix("https://gitee.com/"),
           let range = raw.range(of: "/blob/") {
            let suffix = raw[range.upperBound...]
            let prefix = raw[..<range.lowerBound]
            return "\(prefix)/raw/\(suffix)"
        }
        return raw
    }

    private static func escapeUnencodedCharacters(in raw: String) -> String {
        let safeASCII = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if safeASCII.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if let encoded = String(scalar).addingPercentEncoding(withAllowedCharacters: safeASCII) {
                out.append(encoded)
            }
        }
        return out
    }

    /// 自动解包常见 `callback({...});` JSONP 响应体。
    static func stripJSONP(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return data
        }
        guard let openIdx = trimmed.firstIndex(of: "(") else { return data }
        let prefix = trimmed[..<openIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }) else {
            return data
        }
        var endIdx = trimmed.endIndex
        if trimmed.hasSuffix(");") {
            endIdx = trimmed.index(trimmed.endIndex, offsetBy: -2)
        } else if trimmed.hasSuffix(")") {
            endIdx = trimmed.index(before: trimmed.endIndex)
        } else {
            return data
        }
        let innerStart = trimmed.index(after: openIdx)
        guard innerStart < endIdx else { return data }
        let inner = trimmed[innerStart..<endIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix("{") || inner.hasPrefix("[") else { return data }
        return Data(inner.utf8)
    }

    /// 安全化插件/模板 ID，避免路径穿越字符或空 ID。
    static func sanitizeID(_ raw: String, fallbackPrefix: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if collapsed.isEmpty {
            return "\(fallbackPrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        }
        return collapsed.lowercased()
    }
}

/// 点分路径 JSON 值解析工具（支持 `data.list.0.url` 以及 `artwork.480x480|artwork.150x150` 回退链）。
enum JSONPathResolver {
    static func value(at path: String?, in root: Any?) -> Any? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return root
        }
        for candidate in path.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            if let resolved = singleValue(at: candidate, in: root) {
                return resolved
            }
        }
        return nil
    }

    private static func singleValue(at path: String, in root: Any?) -> Any? {
        var current: Any? = root
        for part in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let array = current as? [Any], let index = Int(part), index >= 0, index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func string(at path: String?, in root: Any?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return extractString(from: root)
        }
        for candidate in path.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            if let resolved = extractString(from: singleValue(at: candidate, in: root)) {
                return resolved
            }
        }
        return nil
    }

    private static func extractString(from raw: Any?) -> String? {
        guard let raw else { return nil }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let num = raw as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    static func double(at path: String?, in root: Any?) -> Double? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return extractDouble(from: root)
        }
        for candidate in path.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            if let resolved = extractDouble(from: singleValue(at: candidate, in: root)) {
                return resolved
            }
        }
        return nil
    }

    private static func extractDouble(from raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = Double(trimmed) { return val }
            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":").compactMap { Double($0) }
                if !parts.isEmpty {
                    return parts.reduce(0) { $0 * 60 + $1 }
                }
            }
        }
        return nil
    }
}
