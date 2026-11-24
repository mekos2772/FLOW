import CommonCrypto
import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore
import Observation

/// 第三方插件声明的用户变量配置项（对应 MusicFree `userVariables` 协议）。
struct JSPluginUserVariable: Codable, Equatable, Hashable, Sendable, Identifiable {
    let key: String
    let name: String
    let hint: String?
    let isSecret: Bool

    var id: String { key }
}

/// 隔离执行第三方 CommonJS / MusicFree / LX 音源插件的 `JavaScriptCore` 运行时与适配层。
struct JSPluginCapabilities: Sendable {
    var hasSearch = false
    var hasGetMediaSource = false
    var hasGetLyric = false
    var hasGetMusicInfo = false
    var hasDiscover = false
    var hasTopLists = false
    var hasRecommendSheets = false
    var hasResolveQuery = false
    var hasGetRelated = false
    var hasAuth = false
    var hasAuthQR = false
    var isLXScript = false
    var supportedQualities: [AudioQualityTier] = []
    var supportedSearchTypes: [String] = []
}

struct JSPluginManifest: Sendable {
    let id: String
    let displayName: String
    let version: String
    let author: String?
    let description: String?
    let allowedDomains: [String]
    let userVariables: [JSPluginUserVariable]
    let lxSources: [String]
    let capabilities: JSPluginCapabilities

    var sourceID: SourceID {
        let sanitized = SourceDomainPolicy.sanitizeID(id.isEmpty ? displayName : id, fallbackPrefix: "js")
        return SourceID(rawValue: "js-\(sanitized)")
    }
}

final class JSPluginRuntime: @unchecked Sendable {
    private final class UncheckedJSBox: @unchecked Sendable {
        var vm: JSVirtualMachine?
        var context: JSContext?
        init(vm: JSVirtualMachine?, context: JSContext?) {
            self.vm = vm
            self.context = context
        }
    }

    private actor JSContextActor {
        private let box: UncheckedJSBox

        init(box: UncheckedJSBox) {
            self.box = box
        }

        func invoke(fnPath: String, argsJSON: String, callID: String) -> Bool {
            guard let ctx = box.context,
                  let fn = ctx.objectForKeyedSubscript("__flowInvoke") else {
                return false
            }
            fn.call(withArguments: [fnPath, argsJSON, callID])
            return true
        }

        func resolveHTTP(id: String, ok: Bool, payloadJSON: String, error: String) {
            box.context?.objectForKeyedSubscript("__flowResolveHTTP")?.call(withArguments: [id, ok, payloadJSON, error])
        }

        func fireTimer(id: String) {
            box.context?.objectForKeyedSubscript("__flowFireTimer")?.call(withArguments: [id])
        }

        func releaseContext() {
            box.context = nil
            box.vm = nil
        }
    }

    private(set) var manifest: JSPluginManifest

    private let session: URLSession
    private let secrets: any SecretStoring
    private let networkAllowed: @Sendable () -> Bool
    private let contextActor: JSContextActor
    private var isInvalidated = false
    private var resolvedAllowedDomains: [String] = []
    private var resolvedStorageNamespace: String = ""

    private let stateLock = NSLock()
    private var invocations: [String: (CheckedContinuation<Any?, Error>, Task<Void, Never>)] = [:]
    private var activeHTTPRequests: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var nextTimerID = 0

    init(scriptSource: String,
         fallbackID: String = "custom",
         session: URLSession = .shared,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         networkAllowed: @escaping @Sendable () -> Bool = { true }) throws {
        self.session = session
        self.secrets = secrets
        self.networkAllowed = networkAllowed
        self.resolvedStorageNamespace = "jsplugin.\(SourceDomainPolicy.sanitizeID(fallbackID, fallbackPrefix: "js"))"
        self.manifest = JSPluginManifest(
            id: fallbackID,
            displayName: fallbackID,
            version: "1.0.0",
            author: nil,
            description: nil,
            allowedDomains: [],
            userVariables: [],
            lxSources: [],
            capabilities: JSPluginCapabilities()
        )

        let vm = JSVirtualMachine()
        guard let ctx = JSContext(virtualMachine: vm) else {
            throw RemoteHTTPFailure(code: -1, message: String(localized: "无法初始化 JS 引擎上下文"), url: "js://init")
        }
        let box = UncheckedJSBox(vm: vm, context: ctx)
        self.contextActor = JSContextActor(box: box)

        let bridgeBox = RuntimeBridgeBox()
        bridgeBox.runtime = self
        let loaded = try Self.bootstrapAndLoad(
            context: ctx,
            scriptSource: scriptSource,
            fallbackID: fallbackID,
            runtimeBox: bridgeBox
        )
        let normalizedKey = SourceDomainPolicy.sanitizeID(loaded.id, fallbackPrefix: fallbackID)
        self.manifest = loaded
        self.resolvedAllowedDomains = loaded.allowedDomains
        self.resolvedStorageNamespace = "jsplugin.\(normalizedKey)"
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        let (pending, httpTasks, pendingTimers) = stateLock.withLock {
            isInvalidated = true
            let inv = invocations
            invocations.removeAll()
            let reqs = activeHTTPRequests
            activeHTTPRequests.removeAll()
            let tms = timers
            timers.removeAll()
            return (inv, reqs, tms)
        }
        for (_, item) in pendingTimers { item.cancel() }
        for (_, task) in httpTasks { task.cancel() }
        for (_, pair) in pending {
            pair.1.cancel()
            pair.0.resume(throwing: CancellationError())
        }
        let actor = contextActor
        Task {
            await actor.releaseContext()
        }
    }

    func call(_ functionPath: String,
              args: [Any] = [],
              timeoutSeconds: TimeInterval = 20) async throws -> Any? {
        let argsData = try JSONSerialization.data(withJSONObject: args, options: [])
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let callID = UUID().uuidString

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    self?.completeInvocation(
                        id: callID,
                        ok: false,
                        resultJSON: "",
                        errorMessage: String(localized: "插件调用超时")
                    )
                }
                let registered = stateLock.withLock { () -> Bool in
                    guard !isInvalidated else { return false }
                    invocations[callID] = (continuation, timeoutTask)
                    return true
                }
                guard registered else {
                    timeoutTask.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let actor = contextActor
                Task { [weak self] in
                    let invoked = await actor.invoke(fnPath: functionPath, argsJSON: argsJSON, callID: callID)
                    if !invoked {
                        self?.completeInvocation(
                            id: callID,
                            ok: false,
                            resultJSON: "",
                            errorMessage: "JS runtime missing dispatcher"
                        )
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.completeInvocation(id: callID, ok: false, resultJSON: "", errorMessage: "__CANCELLED__")
        }
    }

    fileprivate func completeInvocation(id: String, ok: Bool, resultJSON: String, errorMessage: String) {
        let removed = stateLock.withLock { () -> (CheckedContinuation<Any?, Error>, Task<Void, Never>)? in
            invocations.removeValue(forKey: id)
        }
        guard let (continuation, timeout) = removed else { return }
        timeout.cancel()

        if !ok {
            if errorMessage == "__CANCELLED__" {
                continuation.resume(throwing: CancellationError())
            } else if errorMessage == "NETWORK_DISABLED" {
                continuation.resume(throwing: PlaybackError.networkDisabled)
            } else {
                continuation.resume(throwing: RemoteHTTPFailure(code: -1, message: errorMessage, url: "js://call"))
            }
            return
        }
        guard !resultJSON.isEmpty, resultJSON != "null", resultJSON != "undefined" else {
            continuation.resume(returning: nil)
            return
        }
        let data = Data(resultJSON.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        continuation.resume(returning: parsed)
    }

    private struct HTTPRequestSpec: Sendable {
        let url: String
        let method: String
        let timeout: TimeInterval
        let headers: [String: String]
        let params: [(String, String)]
        let bodyData: Data?
        let defaultContentTypeJSON: Bool
        let wantText: Bool

        init(options: [String: Any]) {
            self.url = (options["url"] as? String) ?? ""
            self.method = (options["method"] as? String ?? "GET").uppercased()
            if let timeoutMs = options["timeout"] as? Double, timeoutMs > 0 {
                self.timeout = min(60, max(1, timeoutMs / 1000.0))
            } else {
                self.timeout = NetworkTimeouts.api
            }
            var hdrs: [String: String] = [:]
            if let dict = options["headers"] as? [String: Any] {
                for (k, v) in dict where !(v is NSNull) { hdrs[k] = "\(v)" }
            }
            if let auth = options["auth"] as? [String: Any],
               let user = auth["username"] as? String,
               let pass = auth["password"] as? String,
               hdrs.keys.allSatisfy({ $0.lowercased() != "authorization" }) {
                let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
                hdrs["Authorization"] = "Basic \(encoded)"
            }
            self.headers = hdrs

            var queryPairs: [(String, String)] = []
            if let rawParams = options["params"] as? [String: Any] {
                for (k, v) in rawParams.sorted(by: { $0.key < $1.key }) where !(v is NSNull) {
                    if let arr = v as? [Any] {
                        for element in arr where !(element is NSNull) {
                            queryPairs.append((k, Self.stringifyParamValue(element)))
                        }
                    } else {
                        queryPairs.append((k, Self.stringifyParamValue(v)))
                    }
                }
            }
            self.params = queryPairs

            let bodyValue = options["body"] ?? options["data"]
            if let bodyStr = bodyValue as? String {
                self.bodyData = Data(bodyStr.utf8)
                self.defaultContentTypeJSON = false
            } else if let bodyObj = bodyValue, !(bodyObj is NSNull), JSONSerialization.isValidJSONObject(bodyObj) {
                self.bodyData = try? JSONSerialization.data(withJSONObject: bodyObj)
                self.defaultContentTypeJSON = true
            } else {
                self.bodyData = nil
                self.defaultContentTypeJSON = false
            }
            self.wantText = (options["responseType"] as? String)?.lowercased() == "text"
        }

        private static func stringifyParamValue(_ value: Any) -> String {
            // JSC 的 toDictionary() 会把 JS Boolean 桥接成 CFBoolean(NSNumber)，直接插值会变成 "1"/"0"
            if let num = value as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue ? "true" : "false"
                }
                return num.stringValue
            }
            return "\(value)"
        }
    }

    fileprivate func handleHTTPRequest(id: String, options: [String: Any]) {
        let spec = HTTPRequestSpec(options: options)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.withLock { _ = self.activeHTTPRequests.removeValue(forKey: id) }
            }
            do {
                let payload = try await self.executeHTTP(spec: spec)
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                let json = String(data: data, encoding: .utf8) ?? "{}"
                self.deliverHTTPResult(id: id, ok: true, payloadJSON: json, error: "")
            } catch let violation as SourceDomainPolicy.Violation {
                let msg = (violation as LocalizedError).errorDescription ?? "Domain policy violation"
                let wireMsg = if case .networkDisabled = violation { "NETWORK_DISABLED" } else { msg }
                self.deliverHTTPResult(id: id, ok: false, payloadJSON: "", error: wireMsg)
            } catch {
                self.deliverHTTPResult(id: id, ok: false, payloadJSON: "", error: error.localizedDescription)
            }
        }
        stateLock.withLock {
            if !isInvalidated {
                activeHTTPRequests[id] = task
            } else {
                task.cancel()
            }
        }
    }

    private func deliverHTTPResult(id: String, ok: Bool, payloadJSON: String, error: String) {
        let actor = contextActor
        Task {
            await actor.resolveHTTP(id: id, ok: ok, payloadJSON: payloadJSON, error: error)
        }
    }

    private func executeHTTP(spec: HTTPRequestSpec) async throws -> [String: Any] {
        guard networkAllowed() else {
            throw SourceDomainPolicy.Violation.networkDisabled
        }
        let baseValidated = try SourceDomainPolicy.validate(url: spec.url, allowedDomains: resolvedAllowedDomains)

        var finalURL = baseValidated
        if !spec.params.isEmpty,
           var components = URLComponents(url: baseValidated, resolvingAgainstBaseURL: false) {
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encodedPairs = spec.params.map { k, v -> String in
                let ek = k.addingPercentEncoding(withAllowedCharacters: unreserved) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v
                return "\(ek)=\(ev)"
            }
            let existing = components.percentEncodedQuery
            let appended = encodedPairs.joined(separator: "&")
            components.percentEncodedQuery = (existing?.isEmpty == false)
                ? "\(existing!)&\(appended)"
                : appended
            if let rebuilt = components.url {
                finalURL = try SourceDomainPolicy.validate(url: rebuilt, allowedDomains: resolvedAllowedDomains)
            }
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = spec.method
        request.timeoutInterval = spec.timeout
        // 插件自行通过 Cookie 请求头管理登录态，避免共享 URLSession Cookie 罐在退出登录后继续携带旧凭据。
        request.httpShouldHandleCookies = false
        for (k, v) in spec.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let bodyData = spec.bodyData {
            request.httpBody = bodyData
            if spec.defaultContentTypeJSON, request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            session: session,
            allowedDomains: resolvedAllowedDomains,
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.sourceUnavailable
        }
        var responseHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            responseHeaders[String(describing: k).lowercased()] = String(describing: v)
        }
        let bodyString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        let cleanedData = SourceDomainPolicy.stripJSONP(data)
        let parsedData: Any
        if spec.wantText {
            parsedData = bodyString
        } else if let jsonObj = try? JSONSerialization.jsonObject(with: cleanedData, options: [.fragmentsAllowed]) {
            parsedData = jsonObj
        } else {
            parsedData = bodyString
        }
        return [
            "ok": (200...299).contains(http.statusCode),
            "status": http.statusCode,
            "statusCode": http.statusCode,
            "url": response.url?.absoluteString ?? finalURL.absoluteString,
            "headers": responseHeaders,
            "data": parsedData,
            "body": parsedData,
            "rawBody": bodyString,
        ]
    }

    func userVariableValues() -> [String: String] {
        var result: [String: String] = [:]
        if let rawJSON = secrets.load(account: "\(resolvedStorageNamespace).vars"),
           let data = rawJSON.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            result = dict
        }
        for spec in manifest.userVariables where result[spec.key] == nil {
            if let individual = secrets.load(account: "\(resolvedStorageNamespace).var.\(spec.key)") {
                result[spec.key] = individual
            }
        }
        return result
    }

    func saveUserVariables(_ values: [String: String]) {
        if let data = try? JSONEncoder().encode(values),
           let json = String(data: data, encoding: .utf8) {
            try? secrets.save(json, account: "\(resolvedStorageNamespace).vars")
        }
        for (k, v) in values {
            try? secrets.save(v, account: "\(resolvedStorageNamespace).var.\(k)")
        }
        let actor = contextActor
        Task {
            await actor.fireTimer(id: "__varsUpdated__")
        }
    }

    /// 移除音源时清掉保存在 Keychain 里的参数（账号、口令等），不留残渣。
    func clearUserVariables() {
        secrets.remove(account: "\(resolvedStorageNamespace).vars")
        for spec in manifest.userVariables {
            secrets.remove(account: "\(resolvedStorageNamespace).var.\(spec.key)")
        }
    }

    fileprivate func storageGet(key: String) -> String? {
        secrets.load(account: "\(resolvedStorageNamespace).\(key)")
    }

    fileprivate func storageSet(key: String, value: String?) {
        let fullKey = "\(resolvedStorageNamespace).\(key)"
        if let value {
            try? secrets.save(value, account: fullKey)
        } else {
            secrets.remove(account: fullKey)
        }
    }

    fileprivate func scheduleTimer(ms: Double) -> String {
        let timerID = stateLock.withLock { () -> String in
            nextTimerID += 1
            return "t\(nextTimerID)"
        }
        // 永不对 Infinity/NaN 执行 `Int(ms)`，避免插件传入无穷大时宿主直接 trap 崩溃。
        guard ms.isFinite else {
            return timerID
        }
        let clampedMs = min(max(0, ms), 86_400_000)
        let delayMs = Int(clampedMs)
        let actor = contextActor
        let item = Task { [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            guard !Task.isCancelled else { return }
            if let self {
                _ = self.stateLock.withLock { self.timers.removeValue(forKey: timerID) }
            }
            await actor.fireTimer(id: timerID)
        }
        stateLock.withLock {
            if !isInvalidated { timers[timerID] = item }
        }
        return timerID
    }

    fileprivate func cancelTimer(id: String) {
        let item = stateLock.withLock { timers.removeValue(forKey: id) }
        item?.cancel()
    }

    // MARK: - Bootstrap & CommonJS Wrapper

    private final class RuntimeBridgeBox: @unchecked Sendable {
        weak var runtime: JSPluginRuntime?
    }

    private static func bootstrapAndLoad(context: JSContext,
                                         scriptSource: String,
                                         fallbackID: String,
                                         runtimeBox: RuntimeBridgeBox) throws -> JSPluginManifest {
        var scriptErrorMessage: String?
        context.exceptionHandler = { _, exception in
            scriptErrorMessage = exception?.toString() ?? "Unknown JS error"
        }

        // Native Swift 桥梁函数
        let nativeHTTP: @convention(block) (String, Any?) -> Void = { id, rawOpts in
            let dict = (rawOpts as? [String: Any]) ?? [:]
            runtimeBox.runtime?.handleHTTPRequest(id: id, options: dict)
        }
        let nativeComplete: @convention(block) (String, Bool, String, String) -> Void = { id, ok, json, err in
            runtimeBox.runtime?.completeInvocation(id: id, ok: ok, resultJSON: json, errorMessage: err)
        }
        let nativeLog: @convention(block) (String, String) -> Void = { level, message in
            RedactingLog.info("[JSPlugin:\(level)] \(message)")
        }
        let nativeStorageGet: @convention(block) (String) -> Any = { key in
            runtimeBox.runtime?.storageGet(key: key) ?? NSNull()
        }
        let nativeStorageSet: @convention(block) (String, Any?) -> Void = { key, value in
            let str: String? = (value is NSNull) ? nil : (value.map { "\($0)" })
            runtimeBox.runtime?.storageSet(key: key, value: str)
        }
        let nativeSetTimeout: @convention(block) (Double) -> String = { ms in
            runtimeBox.runtime?.scheduleTimer(ms: ms) ?? ""
        }
        let nativeClearTimeout: @convention(block) (String) -> Void = { id in
            runtimeBox.runtime?.cancelTimer(id: id)
        }
        let nativeHash: @convention(block) (String, String) -> String = { alg, hexInput in
            JSPluginCryptoBridge.hashHex(algorithm: alg, hexInput: hexInput)
        }
        let nativeHmac: @convention(block) (String, String, String) -> String = { alg, hexInput, hexKey in
            JSPluginCryptoBridge.hmacHex(algorithm: alg, hexInput: hexInput, hexKey: hexKey)
        }
        let nativeAES: @convention(block) (Bool, String, String, String, String, String) -> String = { enc, dataHex, keyHex, ivHex, mode, pad in
            JSPluginCryptoBridge.aesCryptHex(encrypt: enc, dataHex: dataHex, keyHex: keyHex, ivHex: ivHex, mode: mode, padding: pad)
        }
        let nativeBase64Enc: @convention(block) (String) -> String = { text in
            Data(text.utf8).base64EncodedString()
        }
        let nativeBase64Dec: @convention(block) (String) -> String = { b64 in
            guard let data = Data(base64Encoded: b64) else { return "" }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        let nativeHexToBase64: @convention(block) (String) -> String = { hex in
            JSPluginCryptoBridge.hexToBase64(hex)
        }
        let nativeBase64ToHex: @convention(block) (String) -> String = { b64 in
            JSPluginCryptoBridge.base64ToHex(b64)
        }

        context.setObject(unsafeBitCast(nativeHTTP, to: AnyObject.self), forKeyedSubscript: "__flowNativeHTTP" as NSString)
        context.setObject(unsafeBitCast(nativeComplete, to: AnyObject.self), forKeyedSubscript: "__flowCompleteInvoke" as NSString)
        context.setObject(unsafeBitCast(nativeLog, to: AnyObject.self), forKeyedSubscript: "__flowNativeLog" as NSString)
        context.setObject(unsafeBitCast(nativeStorageGet, to: AnyObject.self), forKeyedSubscript: "__flowStorageGet" as NSString)
        context.setObject(unsafeBitCast(nativeStorageSet, to: AnyObject.self), forKeyedSubscript: "__flowStorageSet" as NSString)
        context.setObject(unsafeBitCast(nativeSetTimeout, to: AnyObject.self), forKeyedSubscript: "__flowNativeSetTimeout" as NSString)
        context.setObject(unsafeBitCast(nativeClearTimeout, to: AnyObject.self), forKeyedSubscript: "__flowNativeClearTimeout" as NSString)
        context.setObject(unsafeBitCast(nativeHash, to: AnyObject.self), forKeyedSubscript: "__flowNativeHash" as NSString)
        context.setObject(unsafeBitCast(nativeHmac, to: AnyObject.self), forKeyedSubscript: "__flowNativeHmac" as NSString)
        context.setObject(unsafeBitCast(nativeAES, to: AnyObject.self), forKeyedSubscript: "__flowNativeAES" as NSString)
        context.setObject(unsafeBitCast(nativeBase64Enc, to: AnyObject.self), forKeyedSubscript: "__flowNativeBase64Enc" as NSString)
        context.setObject(unsafeBitCast(nativeBase64Dec, to: AnyObject.self), forKeyedSubscript: "__flowNativeBase64Dec" as NSString)
        context.setObject(unsafeBitCast(nativeHexToBase64, to: AnyObject.self), forKeyedSubscript: "__flowNativeHexToBase64" as NSString)
        context.setObject(unsafeBitCast(nativeBase64ToHex, to: AnyObject.self), forKeyedSubscript: "__flowNativeBase64ToHex" as NSString)

        context.evaluateScript(JSPluginBootstrapScripts.combinedBootstrapJS)
        if let scriptErrorMessage {
            throw RemoteHTTPFailure(code: -1, message: scriptErrorMessage, url: "js://bootstrap")
        }

        var cleanScript = scriptSource
        if cleanScript.hasPrefix("\u{FEFF}") {
            cleanScript.removeFirst()
        }
        let headerMeta = JSPluginMetadataParser.parseHeader(from: cleanScript)

        let escapedData = try JSONSerialization.data(withJSONObject: [cleanScript], options: [])
        let wrappedLiteral = String(data: escapedData, encoding: .utf8) ?? "[\"\"]"
        context.evaluateScript("__flowLoadModule(\(wrappedLiteral)[0]);")
        if let scriptErrorMessage {
            throw RemoteHTTPFailure(code: -1, message: scriptErrorMessage, url: "js://plugin")
        }

        guard let summaryValue = context.evaluateScript("__flowInspectExports()")?.toDictionary() else {
            throw RemoteHTTPFailure(code: -1, message: String(localized: "JS 插件必须通过 module.exports 导出对象"), url: "js://exports")
        }

        let rawID = (summaryValue["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawPlatform = (summaryValue["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headerName = headerMeta["name"] ?? ""
        let id = [rawID, rawPlatform, headerMeta["id"] ?? "", headerName, fallbackID]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallbackID
        let displayName = [rawPlatform, headerName, id]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallbackID
        let exportedVersion = (summaryValue["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = exportedVersion.isEmpty ? (headerMeta["version"] ?? "1.0.0") : exportedVersion
        let exportedAuthor = (summaryValue["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorStr = exportedAuthor.isEmpty ? headerMeta["author"] : exportedAuthor
        let exportedDesc = (summaryValue["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let descStr = exportedDesc.isEmpty ? headerMeta["description"] : exportedDesc
        let allowedDomains = (summaryValue["allowedDomains"] as? [String]) ?? []

        let rawVars = (summaryValue["userVariables"] as? [[String: Any]]) ?? []
        let userVariables: [JSPluginUserVariable] = rawVars.compactMap { item in
            guard let key = (item["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return nil }
            let varName = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = (item["hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let typeStr = (item["type"] as? String)?.lowercased() ?? "text"
            return JSPluginUserVariable(
                key: key,
                name: (varName?.isEmpty == false ? varName : nil) ?? key,
                hint: (hint?.isEmpty == false) ? hint : nil,
                isSecret: typeStr == "password" || typeStr == "secret" || key.lowercased().contains("pass") || key.lowercased().contains("token")
            )
        }

        let lxSources = (summaryValue["lxSources"] as? [String]) ?? []
        let isLX = (summaryValue["isLX"] as? Bool) ?? false

        let caps = JSPluginCapabilities(
            hasSearch: (summaryValue["hasSearch"] as? Bool) ?? false,
            hasGetMediaSource: (summaryValue["hasGetMediaSource"] as? Bool) ?? false,
            hasGetLyric: (summaryValue["hasGetLyric"] as? Bool) ?? false,
            hasGetMusicInfo: (summaryValue["hasGetMusicInfo"] as? Bool) ?? false,
            hasDiscover: (summaryValue["hasDiscover"] as? Bool) ?? false,
            hasTopLists: (summaryValue["hasTopLists"] as? Bool) ?? false,
            hasRecommendSheets: (summaryValue["hasRecommendSheets"] as? Bool) ?? false,
            hasResolveQuery: (summaryValue["hasResolveQuery"] as? Bool) ?? false,
            hasGetRelated: (summaryValue["hasGetRelated"] as? Bool) ?? false,
            hasAuth: (summaryValue["hasAuth"] as? Bool) ?? false,
            hasAuthQR: (summaryValue["hasAuthQR"] as? Bool) ?? false,
            isLXScript: isLX,
            supportedQualities: ((summaryValue["supportedQualities"] as? [String]) ?? [])
                .compactMap { AudioQualityTier(rawValue: $0) },
            supportedSearchTypes: (summaryValue["supportedSearchTypes"] as? [String]) ?? []
        )

        let hasCatalogEntry = caps.hasSearch || caps.hasDiscover || caps.hasTopLists || caps.hasRecommendSheets || caps.hasResolveQuery || caps.isLXScript
        let hasMediaOrLyrics = caps.hasGetMediaSource || caps.hasGetLyric || caps.isLXScript || caps.hasSearch || caps.hasTopLists || caps.hasRecommendSheets || caps.hasDiscover
        guard hasCatalogEntry, hasMediaOrLyrics else {
            throw RemoteHTTPFailure(
                code: -1,
                message: String(localized: "插件缺少必需的 search / discover 或 getMediaSource 导出方法"),
                url: "js://exports"
            )
        }

        return JSPluginManifest(
            id: id,
            displayName: displayName,
            version: version,
            author: (authorStr?.isEmpty == false) ? authorStr : nil,
            description: (descStr?.isEmpty == false) ? descStr : nil,
            allowedDomains: allowedDomains,
            userVariables: userVariables,
            lxSources: lxSources,
            capabilities: caps
        )
    }
}

/// 将 `JSPluginRuntime` 封装为标准的 `PlaybackSourceProvider` + 可选多源扩展能力协议。
final class JSPluginSource:
    PlaybackSourceProvider,
    OfflineStreamDescriptorProviding,
    DiscoverableSourceProvider,
    URLResolvableSourceProvider,
    RelatedRadioSourceProvider,
    @unchecked Sendable
{
    let runtime: JSPluginRuntime
    let manifest: JSPluginManifest

    private let session: URLSession
    private let networkAllowed: @Sendable () -> Bool
    private let audioCache: MediaAudioCache
    private let streamingAssetBuilder: StreamingAssetBuilder?
    private let hlsAssetBuilder: HLSAssetBuilder?
    private let lock = NSLock()
    private var preferredQuality: AudioQualityTier = .auto
    private var lastActualQuality: String?
    private var onActualQualityChanged: (@Sendable (String?) -> Void)?
    private var rawItemCache: [TrackIdentity: [String: Any]] = [:]
    private var queryPrefixCache: [String: Bool] = [:]

    init(scriptSource: String,
         fallbackID: String = "custom",
         session: URLSession = .shared,
         secrets: any SecretStoring = DefaultSecretStore.shared,
         networkAllowed: @escaping @Sendable () -> Bool = { true },
         audioCache: MediaAudioCache = .shared,
         streamingAssetBuilder: StreamingAssetBuilder? = nil,
         hlsAssetBuilder: HLSAssetBuilder? = nil) throws {
        let runtime = try JSPluginRuntime(
            scriptSource: scriptSource,
            fallbackID: fallbackID,
            session: session,
            secrets: secrets,
            networkAllowed: networkAllowed
        )
        self.runtime = runtime
        self.manifest = runtime.manifest
        self.session = session
        self.networkAllowed = networkAllowed
        self.audioCache = audioCache
        self.streamingAssetBuilder = streamingAssetBuilder
        self.hlsAssetBuilder = hlsAssetBuilder
    }

    var descriptor: SourceDescriptor {
        SourceDescriptor(
            id: manifest.sourceID,
            displayName: manifest.displayName,
            kind: .jsPlugin,
            requiresNetwork: true,
            supportsSearch: manifest.capabilities.hasSearch,
            supportsLyrics: manifest.capabilities.hasGetLyric || manifest.capabilities.isLXScript,
            supportsDiscover: manifest.capabilities.hasDiscover || manifest.capabilities.hasTopLists || manifest.capabilities.hasRecommendSheets,
            supportsAccount: manifest.capabilities.hasAuth,
            supportsRelatedRadio: manifest.capabilities.hasGetRelated,
            supportsQualitySelection: !manifest.capabilities.supportedQualities.isEmpty
                || manifest.capabilities.isLXScript
                || manifest.capabilities.hasGetMediaSource,
            allowedDomains: manifest.allowedDomains
        )
    }

    var currentQuality: AudioQualityTier { lock.withLock { preferredQuality } }
    var actualQualityDescription: String? { lock.withLock { lastActualQuality } }
    func updateQuality(_ tier: AudioQualityTier) { lock.withLock { preferredQuality = tier } }
    func setOnActualQualityChanged(_ handler: (@Sendable (String?) -> Void)?) {
        lock.withLock { onActualQualityChanged = handler }
    }

    func cacheRawItems(from tracks: [(Track, [String: Any])]) {
        lock.withLock {
            for (track, raw) in tracks {
                rawItemCache[track.identity] = raw
            }
        }
    }

    // MARK: - PlaybackSourceProvider

    func search(_ request: SearchRequest) async throws -> [Track] {
        guard manifest.capabilities.hasSearch else {
            if manifest.capabilities.hasDiscover || manifest.capabilities.hasTopLists || manifest.capabilities.hasRecommendSheets {
                return try await discoverTracks(limit: request.limit, progress: nil)
            }
            return []
        }
        let page = max(1, (request.offset / max(1, request.limit)) + 1)
        let searchType = manifest.capabilities.supportedSearchTypes.contains("music") || manifest.capabilities.supportedSearchTypes.isEmpty
            ? "music"
            : (manifest.capabilities.supportedSearchTypes.first ?? "music")
        let raw = try await runtime.call("search", args: [request.query, page, searchType])
        return parseTrackList(from: raw)
    }

    func resolve(_ track: Track) async -> Track {
        guard manifest.capabilities.hasGetMusicInfo else { return track }
        let item = rawDictionary(for: track)
        guard let enriched = try? await runtime.call("getMusicInfo", args: [item]) as? [String: Any] else {
            return track
        }
        let nextTitle = ((enriched["title"] as? String) ?? (enriched["name"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextArtist = ((enriched["artist"] as? String) ?? (enriched["singer"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAlbum = (enriched["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextArt = ((enriched["artwork"] as? String) ?? (enriched["pic"] as? String) ?? (enriched["cover"] as? String))
            .flatMap { URL(string: $0) }
            .map { ArtworkReference(.remote(Self.upgradingHTTPSIfKnownCDN($0))) }
        let nextDuration = parseDuration(enriched["duration"]) ?? track.duration
        var mergedRaw = item
        for (k, v) in enriched {
            mergedRaw[k] = v
        }
        let nextHint = Self.encodePersistentHint(from: mergedRaw) ?? track.persistentIdentifier
        let resolvedTrack = Track(
            id: track.id,
            sourceID: track.sourceID,
            externalID: track.externalID,
            title: (nextTitle?.isEmpty == false ? nextTitle : nil) ?? track.title,
            artist: (nextArtist?.isEmpty == false ? nextArtist : nil) ?? track.artist,
            album: (nextAlbum?.isEmpty == false ? nextAlbum : nil) ?? track.album,
            duration: max(0, nextDuration),
            artwork: nextArt ?? track.artwork,
            lyrics: track.lyrics,
            persistentIdentifier: nextHint
        )
        lock.withLock {
            rawItemCache[resolvedTrack.identity] = mergedRaw
        }
        return resolvedTrack
    }

    func discoverTracks(limit: Int, progress: (@Sendable (TrackListBatch) -> Void)?) async throws -> [Track] {
        let tracks: [Track]
        if manifest.capabilities.hasDiscover {
            let raw = try await runtime.call("discover", args: [limit])
            tracks = Array(parseTrackList(from: raw).prefix(limit))
        } else if manifest.capabilities.hasTopLists {
            let listsRaw = try await runtime.call("getTopLists", args: [])
            guard let firstList = extractTopListCandidate(from: listsRaw) else { return [] }
            let detailRaw = try await runtime.call("getTopListDetail", args: [firstList, 1])
            tracks = Array(parseTrackList(from: detailRaw).prefix(limit))
        } else if manifest.capabilities.hasRecommendSheets {
            let tagsRaw = try? await runtime.call("getRecommendSheetTags", args: [])
            let firstTag = extractFirstTag(from: tagsRaw) ?? ["id": "", "title": "推荐"]
            let sheetsRaw = try await runtime.call("getRecommendSheetsByTag", args: [firstTag, 1])
            guard let sheetItem = extractFirstSheet(from: sheetsRaw) else { return [] }
            let detailRaw = try await runtime.call("getMusicSheetInfo", args: [sheetItem, 1])
            tracks = Array(parseTrackList(from: detailRaw).prefix(limit))
        } else {
            return []
        }
        progress?(TrackListBatch(tracks: tracks, checked: tracks.count, total: tracks.count))
        return tracks
    }

    func canHandleQuery(_ query: String) -> Bool {
        guard manifest.capabilities.hasResolveQuery else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let cached = lock.withLock({ queryPrefixCache[trimmed] }) {
            return cached
        }
        let lower = trimmed.lowercased()
        let looksLikeURLOrToken = lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.contains("://")
            || (trimmed.count >= 6 && trimmed.range(of: #"^[A-Za-z0-9_-]{6,64}$"#, options: .regularExpression) != nil)
        return looksLikeURLOrToken
    }

    func resolveQuery(_ query: String) async throws -> [Track] {
        guard manifest.capabilities.hasResolveQuery else { return [] }
        if let canHandle = try? await runtime.call("canHandleQuery", args: [query]) as? Bool {
            lock.withLock { queryPrefixCache[query] = canHandle }
            guard canHandle else { return [] }
            let raw = try await runtime.call("resolveQuery", args: [query])
            return parseTrackList(from: raw)
        }
        if let sheetRaw = try? await runtime.call("importMusicSheet", args: [query]) {
            let list = parseTrackList(from: sheetRaw)
            if !list.isEmpty { return list }
        }
        if let itemRaw = try? await runtime.call("importMusicItem", args: [query]) {
            let list = parseTrackList(from: itemRaw)
            if !list.isEmpty { return list }
        }
        return []
    }

    func relatedTracks(for track: Track, limit: Int) async throws -> [Track] {
        guard manifest.capabilities.hasGetRelated, track.sourceID == manifest.sourceID else { return [] }
        let item = rawDictionary(for: track)
        let raw = try await runtime.call("getRelated", args: [item, limit])
        return Array(parseTrackList(from: raw).prefix(limit))
    }

    var supportsGaplessPrewarm: Bool { true }

    func makeSession(for track: Track) async throws -> any PlaybackSession {
        try await makeSession(for: track, reportActualQuality: true)
    }

    func makePrewarmSession(for track: Track) async throws -> any PlaybackSession {
        try await makeSession(for: track, reportActualQuality: false)
    }

    func noteSessionPromoted(_ session: any PlaybackSession) {
        guard let httpSession = session as? HTTPStreamPlayerSession else { return }
        reportActualQuality(for: httpSession.stream)
    }

    private func makeSession(for track: Track, reportActualQuality: Bool) async throws -> any PlaybackSession {
        let quality = lock.withLock { preferredQuality }
        let descriptor = try await makeStreamDescriptor(for: track, quality: quality)
        let session = try await RemoteStreamSessionFactory.makeSession(
            track: track,
            stream: descriptor,
            cache: audioCache,
            streamingAssetBuilder: streamingAssetBuilder,
            hlsAssetBuilder: hlsAssetBuilder,
            session: self.session,
            networkAllowed: networkAllowed
        )
        if reportActualQuality {
            self.reportActualQuality(for: descriptor)
        }
        return session
    }

    private func reportActualQuality(for descriptor: AudioStreamDescriptor) {
        let (actualText, callback): (String, (@Sendable (String?) -> Void)?) = lock.withLock {
            let desc = descriptor.describe
            let resolved = desc.isEmpty ? descriptor.qualityTier.displayName : desc
            lastActualQuality = resolved
            return (resolved, onActualQualityChanged)
        }
        callback?(actualText)
    }

    func offlineStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor? {
        try await makeStreamDescriptor(for: track, quality: quality)
    }

    private func makeStreamDescriptor(for track: Track, quality: AudioQualityTier) async throws -> AudioStreamDescriptor {
        guard track.sourceID == manifest.sourceID else {
            throw PlaybackError.sourceUnavailable
        }
        guard networkAllowed() else { throw PlaybackError.networkDisabled }
        let item = rawDictionary(for: track)
        let raw: Any?
        if !manifest.capabilities.hasSearch && manifest.capabilities.isLXScript {
            let sourceKey = manifest.lxSources.first ?? "custom"
            raw = try await runtime.call("__lx.musicUrl", args: [item, mappedLXQuality(for: quality), sourceKey])
        } else if manifest.capabilities.hasGetMediaSource {
            let primaryQuality = mappedPluginQuality(for: quality)
            var candidates: [String] = [primaryQuality]
            if manifest.capabilities.supportedQualities.isEmpty || quality == .auto {
                for fallback in ["standard", "low", "high", "super"] where !candidates.contains(fallback) {
                    candidates.append(fallback)
                }
            }
            var resolvedRaw: Any?
            for candidateQuality in candidates {
                let candidate = try await runtime.call("getMediaSource", args: [item, candidateQuality])
                if let dict = candidate as? [String: Any],
                   let u = dict["url"] as? String, !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedRaw = dict
                    break
                }
                if let s = candidate as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedRaw = s
                    break
                }
            }
            if resolvedRaw == nil, manifest.capabilities.isLXScript {
                let sourceKey = manifest.lxSources.first ?? "custom"
                raw = try await runtime.call("__lx.musicUrl", args: [item, mappedLXQuality(for: quality), sourceKey])
            } else {
                raw = resolvedRaw ?? (item["url"] as? String).map { ["url": $0] }
            }
        } else if let directURL = item["url"] as? String, !directURL.isEmpty {
            var directDict: [String: Any] = ["url": directURL]
            if let directHeaders = item["headers"] { directDict["headers"] = directHeaders }
            raw = directDict
        } else if manifest.capabilities.isLXScript {
            let sourceKey = manifest.lxSources.first ?? "custom"
            raw = try await runtime.call("__lx.musicUrl", args: [item, mappedLXQuality(for: quality), sourceKey])
        } else {
            raw = nil
        }

        let dict: [String: Any]
        if let d = raw as? [String: Any] {
            dict = d
        } else if let directURL = raw as? String, !directURL.isEmpty {
            dict = ["url": directURL]
        } else {
            throw PlaybackError.sourceUnavailable
        }

        guard let urlString = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else {
            throw PlaybackError.sourceUnavailable
        }
        let validatedURL = try SourceDomainPolicy.validate(url: urlString, allowedDomains: manifest.allowedDomains)
        let (streamURL, embeddedAuth) = stripBasicAuthFromURL(validatedURL)

        var headers: [String: String] = [:]
        if let rawHeaders = dict["headers"] as? [String: Any] {
            for (k, v) in rawHeaders { headers[k] = "\(v)" }
        }
        if let ua = dict["userAgent"] as? String, !ua.isEmpty, headers["User-Agent"] == nil {
            headers["User-Agent"] = ua
        }
        if let embeddedAuth, headers.keys.allSatisfy({ $0.lowercased() != "authorization" }) {
            headers["Authorization"] = embeddedAuth
        }
        let codec = (dict["codec"] as? String) ?? "AUDIO"
        let bitrate = (dict["bitrate"] as? NSNumber)?.intValue ?? 0
        let sampleRate = (dict["sampleRate"] as? NSNumber)?.intValue
        let rawExt = (dict["fileExtension"] as? String)
            ?? (dict["ext"] as? String)
            ?? (item["suffix"] as? String)
            ?? (streamURL.pathExtension.isEmpty ? nil : streamURL.pathExtension)
        let ext = (rawExt?.isEmpty == false ? rawExt!.lowercased() : "m4a")
        let isLossless = (dict["isLossless"] as? Bool) ?? (ext == "flac" || ext == "wav")
        let actualTier = (dict["quality"] as? String).flatMap(AudioQualityTier.init(rawValue:)) ?? quality
        let explicitQualityID = (dict["qualityID"] as? NSNumber)?.intValue
            ?? (dict["qualityId"] as? NSNumber)?.intValue
            ?? 0
        let fallbackTierID: Int = switch actualTier {
        case .auto: 0
        case .standard: 1
        case .high: 2
        case .hifi: 3
        case .lossless: 4
        case .hiRes: 5
        }
        let qualityID = explicitQualityID != 0 ? explicitQualityID : (bitrate == 0 ? fallbackTierID : 0)
        let rawBackupStrings = (dict["backupUrls"] as? [String]) ?? (dict["backupURLs"] as? [String]) ?? []
        let backupURLs: [URL] = rawBackupStrings.compactMap { rawBackup in
            let trimmed = rawBackup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let validated = try? SourceDomainPolicy.validate(url: trimmed, allowedDomains: manifest.allowedDomains) else {
                return nil
            }
            return stripBasicAuthFromURL(validated).0
        }

        return AudioStreamDescriptor(
            cacheKey: TrackIdentity.storageKey(track.identity),
            fileExtension: ext,
            qualityTier: actualTier,
            qualityID: qualityID,
            codec: codec,
            bandwidth: bitrate,
            sampleRate: sampleRate,
            isLossless: isLossless,
            url: streamURL,
            backupURLs: backupURLs,
            headers: headers,
            allowedDomains: manifest.allowedDomains
        )
    }

    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession {
        session
    }

    func artwork(for reference: ArtworkReference) async throws -> Data? {
        guard case .remote(let rawURL) = reference.media else { return nil }
        guard networkAllowed() else { return nil }
        let url = Self.upgradingHTTPSIfKnownCDN(rawURL)
        do {
            return try await fetchArtworkData(from: url)
        } catch let urlError as URLError
            where urlError.code == .appTransportSecurityRequiresSecureConnection && url.scheme?.lowercased() == "http" {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "https"
            guard let httpsURL = components.url else { return nil }
            return try await fetchArtworkData(from: httpsURL)
        }
    }

    private func fetchArtworkData(from url: URL) async throws -> Data? {
        _ = try SourceDomainPolicy.validate(url: url, allowedDomains: manifest.allowedDomains)
        let (data, response) = try await PluginHTTPClient.data(
            for: URLRequest(url: url),
            session: session,
            allowedDomains: manifest.allowedDomains,
            networkAllowed: networkAllowed
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return data
    }

    func lyrics(for track: Track) async throws -> LyricsDocument? {
        if manifest.capabilities.hasGetLyric {
            let item = rawDictionary(for: track)
            let raw = try await runtime.call("getLyric", args: [item])
            return parseLyrics(from: raw, identity: track.identity)
        }
        if manifest.capabilities.isLXScript {
            let item = rawDictionary(for: track)
            let sourceKey = manifest.lxSources.first ?? "custom"
            let raw = try? await runtime.call("__lx.lyric", args: [item, sourceKey])
            return parseLyrics(from: raw, identity: track.identity)
        }
        return nil
    }

    func map(_ error: any Error) -> PlaybackError {
        if let playback = error as? PlaybackError { return playback }
        if let violation = error as? SourceDomainPolicy.Violation {
            if case .networkDisabled = violation { return .networkDisabled }
            return .sourceUnavailable
        }
        return defaultMap(error)
    }

    // MARK: - 解析辅助

    private func mappedPluginQuality(for tier: AudioQualityTier) -> String {
        if !manifest.capabilities.supportedQualities.isEmpty {
            return tier.rawValue
        }
        switch tier {
        case .standard: return "standard"
        case .auto, .high: return "high"
        case .hifi, .lossless, .hiRes: return "super"
        }
    }

    private func mappedLXQuality(for tier: AudioQualityTier) -> String {
        switch tier {
        case .standard: return "128k"
        case .auto, .high: return "320k"
        case .hifi, .lossless: return "flac"
        case .hiRes: return "flac24bit"
        }
    }

    private func stripBasicAuthFromURL(_ url: URL) -> (URL, String?) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = components.user, !user.isEmpty else {
            return (url, nil)
        }
        let pass = components.password ?? ""
        let header = "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        components.user = nil
        components.password = nil
        return (components.url ?? url, header)
    }

    private func extractFirstTag(from raw: Any?) -> Any? {
        if let dict = raw as? [String: Any] {
            if let pinned = dict["pinned"] as? [Any], let first = pinned.first { return first }
            if let data = dict["data"] as? [[String: Any]], let first = data.first,
               let inner = first["data"] as? [Any], let item = inner.first {
                return item
            }
        }
        return nil
    }

    private func extractFirstSheet(from raw: Any?) -> Any? {
        if let dict = raw as? [String: Any], let data = dict["data"] as? [Any] {
            return data.first
        }
        if let arr = raw as? [Any] {
            return arr.first
        }
        return nil
    }

    private func parseDuration(_ raw: Any?) -> Double? {
        if let num = raw as? NSNumber {
            let value = num.doubleValue
            return value > 36_000 ? value / 1000.0 : value
        }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = Double(trimmed) {
                return direct > 36_000 ? direct / 1000.0 : direct
            }
            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":").compactMap { Double($0) }
                if !parts.isEmpty {
                    return parts.reduce(0) { $0 * 60 + $1 }
                }
            }
        }
        return nil
    }

    private func parseArtist(from item: [String: Any]) -> String {
        if let str = (item["artist"] as? String) ?? (item["singer"] as? String) ?? (item["author"] as? String) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let user = item["user"] as? [String: Any], let name = user["name"] as? String {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let list = item["artists"] as? [[String: Any]] {
            let names = list.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !names.isEmpty { return names.joined(separator: " / ") }
        }
        return ""
    }

    func parseTrackList(from raw: Any?) -> [Track] {
        let items: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            items = arr
        } else if let dict = raw as? [String: Any] {
            if let dataArr = dict["data"] as? [[String: Any]] {
                items = dataArr
            } else if let musicList = dict["musicList"] as? [[String: Any]] {
                items = musicList
            } else if let songs = dict["songs"] as? [[String: Any]] {
                items = songs
            } else if let result = dict["result"] as? [[String: Any]] {
                items = result
            } else if dict["id"] != nil || dict["bvid"] != nil || dict["songmid"] != nil {
                items = [dict]
            } else {
                items = []
            }
        } else {
            items = []
        }

        var tracks: [Track] = []
        var rawPairs: [(Track, [String: Any])] = []
        for item in items {
            let idVal = item["id"] ?? item["bvid"] ?? item["songmid"] ?? item["hash"]
            guard let rawID = idVal.map({ "\($0)" }), !rawID.isEmpty else { continue }
            let title = ((item["title"] as? String) ?? (item["name"] as? String) ?? rawID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = parseArtist(from: item)
            let album = ((item["album"] as? String) ?? (item["albumName"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = parseDuration(item["duration"]) ?? 0
            let artStr = (item["artwork"] as? String)
                ?? (item["pic"] as? String)
                ?? (item["cover"] as? String)
                ?? (item["artworkUrl"] as? String)
                ?? (item["coverImgUrl"] as? String)
            let artRef = artStr
                .flatMap { URL(string: $0) }
                .map { ArtworkReference(.remote(Self.upgradingHTTPSIfKnownCDN($0))) }

            let persistentHint = Self.encodePersistentHint(from: item)

            let track = Track(
                sourceID: manifest.sourceID,
                externalID: rawID,
                title: title.isEmpty ? rawID : title,
                artist: artist,
                album: (album?.isEmpty == false) ? album : nil,
                duration: max(0, duration),
                artwork: artRef,
                lyrics: manifest.capabilities.hasGetLyric ? LyricsReference(.opaque(rawID)) : nil,
                persistentIdentifier: persistentHint
            )
            tracks.append(track)
            rawPairs.append((track, item))
        }
        cacheRawItems(from: rawPairs)
        return tracks
    }

    private func extractTopListCandidate(from raw: Any?) -> Any? {
        if let arr = raw as? [[String: Any]], let first = arr.first {
            if let data = first["data"] as? [[String: Any]], let inner = data.first {
                return inner
            }
            return first
        }
        return nil
    }

    private func rawDictionary(for track: Track) -> [String: Any] {
        if let cached = lock.withLock({ rawItemCache[track.identity] }) {
            return cached
        }
        var fallback: [String: Any] = [
            "id": track.externalID,
            "title": track.title,
            "artist": track.artist,
            "duration": track.duration,
        ]
        if let album = track.album { fallback["album"] = album }
        if let hint = track.persistentIdentifier,
           let data = hint.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rawItem = decoded["_item"] as? [String: Any] {
                for (k, v) in rawItem where fallback[k] == nil {
                    fallback[k] = v
                }
                if let meta = decoded["_meta"] ?? rawItem["_meta"] {
                    fallback["_meta"] = meta
                }
            } else if decoded["_meta"] != nil {
                for (k, v) in decoded where fallback[k] == nil {
                    fallback[k] = v
                }
            } else {
                // 兼容早期版本仅把 `_meta` 本身存进 persistentIdentifier 的格式。
                fallback["_meta"] = decoded
            }
        }
        // 兼容未写入 `_item` 的老数据库记录（例如切换原曲或跨重启重放已收藏/队列中的 B 站稿件）：
        // 若缺少 bvid/aid，从 externalID（或 album 中的 BV 号）补全，避免插件因缺少 bvid 调无参 view 接口失败。
        if fallback["bvid"] == nil {
            if let bv = Self.extractBVID(from: track.externalID) {
                fallback["bvid"] = bv
            } else if let album = track.album, let bv = Self.extractBVID(from: album) {
                fallback["bvid"] = bv
            }
        }
        if fallback["bvid"] == nil,
           fallback["aid"] == nil,
           track.sourceID.rawValue.lowercased().contains("bili") {
            if let aid = track.album?.trimmingCharacters(in: .whitespacesAndNewlines),
               !aid.isEmpty, aid.allSatisfy(\.isNumber) {
                fallback["aid"] = aid
            } else if !track.externalID.isEmpty, track.externalID.allSatisfy(\.isNumber) {
                fallback["aid"] = track.externalID
            }
        }
        return fallback
    }

    private static let hintIgnoredKeys: Set<String> = [
        "rawLrc", "lrc", "lyric", "lyrics", "translation", "translatedLrc",
        "description", "desc", "intro", "content", "_meta",
    ]
    private static let fallbackCompactKeys: [String] = [
        "id", "bvid", "aid", "cid", "songmid", "mid", "strMediaMid", "mediaMid",
        "hash", "albumId", "albumid", "albummid", "rid", "url", "platform", "source",
    ]

    private static func encodePersistentHint(from item: [String: Any]) -> String? {
        var payload: [String: Any] = [:]
        if let meta = item["_meta"] as? [String: Any] {
            payload["_meta"] = meta
        }
        var compact: [String: Any] = [:]
        for (key, value) in item where !hintIgnoredKeys.contains(key) {
            guard !(value is NSNull), JSONSerialization.isValidJSONObject([key: value]) else { continue }
            if let str = value as? String, str.count > 1024 { continue }
            if let data = try? JSONSerialization.data(withJSONObject: [key: value]), data.count > 2048 { continue }
            compact[key] = value
        }
        if !compact.isEmpty {
            payload["_item"] = compact
        }
        guard !payload.isEmpty else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           data.count <= 8192,
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 超长项降级只保留核心标识字段与 _meta
        var minimal: [String: Any] = [:]
        if let meta = item["_meta"] as? [String: Any] {
            minimal["_meta"] = meta
        }
        var minimalItem: [String: Any] = [:]
        for key in fallbackCompactKeys {
            if let val = item[key], !(val is NSNull), JSONSerialization.isValidJSONObject([key: val]) {
                minimalItem[key] = val
            }
        }
        if !minimalItem.isEmpty { minimal["_item"] = minimalItem }
        guard !minimal.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: minimal),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func extractBVID(from raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIndex = token.firstIndex(of: "#") {
            token = String(token[..<hashIndex])
        }
        guard token.count >= 10,
              token.count <= 16,
              token.uppercased().hasPrefix("BV"),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return "BV" + token.dropFirst(2)
    }

    private static func upgradingHTTPSIfKnownCDN(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "biliimg.com" || host.hasSuffix(".biliimg.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func parseLyrics(from raw: Any?, identity: TrackIdentity) -> LyricsDocument? {
        guard let raw else { return nil }
        if let lrcText = raw as? String, !lrcText.isEmpty {
            return parseLRCString(lrcText, translation: nil, identity: identity)
        }
        guard let dict = raw as? [String: Any] else { return nil }
        if let rawLines = dict["lines"] as? [[String: Any]], !rawLines.isEmpty {
            let lines: [LyricLine] = rawLines.compactMap { item in
                guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let start = (item["start"] as? NSNumber)?.doubleValue
                    ?? (item["time"] as? NSNumber)?.doubleValue
                    ?? 0
                let end = (item["end"] as? NSNumber)?.doubleValue
                let trans = (item["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return LyricLine(start: start, end: end, text: text, translation: trans?.isEmpty == false ? trans : nil)
            }
            guard !lines.isEmpty else { return nil }
            let synced = (dict["synced"] as? Bool) ?? true
            return LyricsDocument(
                trackIdentity: identity,
                lines: lines,
                source: .external,
                synchronization: synced ? .synced : .unsynced
            )
        }
        let primaryText = (dict["rawLrc"] as? String) ?? (dict["lrc"] as? String) ?? ""
        let translationText = (dict["translation"] as? String) ?? (dict["translatedLrc"] as? String)
        guard !primaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parseLRCString(primaryText, translation: translationText, identity: identity)
    }

    private func parseLRCString(_ text: String, translation: String?, identity: TrackIdentity) -> LyricsDocument? {
        guard let parsed = LRCParser.parse(text), !parsed.lines.isEmpty else { return nil }
        let transParsed = translation.flatMap { LRCParser.parse($0) }
        let merged: [LyricLine]
        if let transLines = transParsed?.lines, !transLines.isEmpty {
            merged = parsed.lines.map { line in
                let matched = transLines.first { abs($0.start - line.start) <= 0.5 }
                return LyricLine(
                    start: line.start,
                    end: line.end,
                    text: line.text,
                    segments: line.segments,
                    translation: line.translation ?? matched?.text
                )
            }
        } else {
            merged = parsed.lines
        }
        return LyricsDocument(
            trackIdentity: identity,
            lines: merged,
            metadata: parsed.metadata,
            source: .external,
            synchronization: parsed.synchronization
        )
    }
}

/// 可选能力适配：插件提供 `auth` 对象时的登录与个人曲库控制器。
@MainActor
@Observable
final class JSPluginAccountController: SourceAccountController {
    @ObservationIgnored private let source: JSPluginSource
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private(set) var authState: SourceAuthState = .signedOut
    private(set) var accountDetailText: String?

    init(source: JSPluginSource) {
        self.source = source
    }

    var supportsQRLogin: Bool {
        source.manifest.capabilities.hasAuthQR
    }

    var isSigningIn: Bool {
        switch authState {
        case .showingQR, .scanned: return true
        default: return false
        }
    }

    func refreshAuthStatus() async {
        do {
            let raw = try await source.runtime.call("auth.status", args: [])
            applyStatusPayload(raw)
        } catch {
            // 保持当前状态，不打断用户扫码。
        }
    }

    func beginQRLogin() async {
        cancelLogin()
        do {
            let raw = try await source.runtime.call("auth.beginQRLogin", args: [])
            guard let dict = raw as? [String: Any],
                  let url = dict["url"] as? String, !url.isEmpty else {
                authState = .failed(String(localized: "未返回有效二维码"))
                return
            }
            let hint = (dict["hint"] as? String) ?? String(localized: "请扫码确认登录")
            authState = .showingQR(url: url, hint: hint)
            let token = dict["token"] ?? NSNull()
            startPolling(token: token)
        } catch {
            authState = .failed(SourceErrorPresentation.friendly(error))
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        if isSigningIn {
            authState = .signedOut
        }
    }

    func signOut() {
        cancelLogin()
        Task {
            _ = try? await source.runtime.call("auth.signOut", args: [])
            authState = .signedOut
            accountDetailText = nil
        }
    }

    func collections() async throws -> [SourceCollection] {
        let raw = try await source.runtime.call("auth.collections", args: [])
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"].map({ "\($0)" }),
                  let title = item["title"] as? String else { return nil }
            let kindStr = (item["kind"] as? String) ?? "playlists"
            let kind = SourceCollection.Kind(rawValue: kindStr) ?? .playlists
            return SourceCollection(id: id, title: title, kind: kind)
        }
    }

    func tracks(in collection: SourceCollection) async throws -> [Track] {
        let payload: [String: Any] = [
            "id": collection.id,
            "title": collection.title,
            "kind": collection.kind.rawValue,
        ]
        let raw = try await source.runtime.call("auth.collectionTracks", args: [payload])
        return source.parseTrackList(from: raw)
    }

    private func startPolling(token: Any) {
        pollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                do {
                    let raw = try await self.source.runtime.call("auth.pollQRLogin", args: [token])
                    if self.applyStatusPayload(raw) {
                        return
                    }
                } catch {
                    self.authState = .failed(SourceErrorPresentation.friendly(error))
                    return
                }
            }
            self.authState = .expired(hint: String(localized: "二维码已过期"))
        }
    }

    @discardableResult
    private func applyStatusPayload(_ raw: Any?) -> Bool {
        guard let dict = raw as? [String: Any], let state = dict["state"] as? String else {
            return false
        }
        let hint = (dict["hint"] as? String) ?? ""
        switch state {
        case "signedIn":
            let summary = (dict["summary"] as? String) ?? String(localized: "已登录")
            let detail = dict["detail"] as? String
            accountDetailText = detail
            authState = .signedIn(summary: summary, detail: detail)
            return true
        case "scanned":
            authState = .scanned(hint: hint.isEmpty ? String(localized: "已扫码，等待确认") : hint)
            return false
        case "expired":
            authState = .expired(hint: hint.isEmpty ? String(localized: "二维码已过期") : hint)
            return true
        case "failed":
            authState = .failed(hint.isEmpty ? String(localized: "登录失败") : hint)
            return true
        default:
            if state == "signedOut" {
                authState = .signedOut
                accountDetailText = nil
            }
            return false
        }
    }
}

/// 可选能力适配：插件支持音质选择时的控制器。
///
/// 必须可观察：设置页的音质下拉框与「当前实际音质」直接读这里的可观察属性，切换或起播后实时刷新。
@MainActor
@Observable
final class JSPluginQualityController: QualitySelectableSourceController {
    @ObservationIgnored private let source: JSPluginSource
    private(set) var currentQualityTier: AudioQualityTier
    private(set) var lastActualQualityText: String?

    init(source: JSPluginSource) {
        self.source = source
        self.currentQualityTier = source.currentQuality
        self.lastActualQualityText = source.actualQualityDescription
        source.setOnActualQualityChanged { [weak self] text in
            Task { @MainActor [weak self] in
                self?.lastActualQualityText = text
            }
        }
    }

    var availableQualityTiers: [AudioQualityTier] {
        let declared = source.manifest.capabilities.supportedQualities
        return declared.isEmpty ? AudioQualityTier.allCases : declared
    }

    func qualityRequirementHint(for tier: AudioQualityTier) -> String? {
        if tier.prefersLossless, source.manifest.capabilities.hasAuth {
            return String(localized: "将优先向插件「\(source.manifest.displayName)」请求「\(tier.displayName)」音轨；需要对应账号权益且曲目提供无损流，不可用时自动降级。")
        }
        return String(localized: "将优先向插件「\(source.manifest.displayName)」请求「\(tier.displayName)」音轨。")
    }

    func applyQuality(_ tier: AudioQualityTier) async -> String? {
        currentQualityTier = tier
        source.updateQuality(tier)
        return nil
    }
}
