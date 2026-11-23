import CommonCrypto
import CryptoKit
import Foundation

/// 原生 Swift 密码学与脚本头元信息解析桥接（供 `JSPluginRuntime` 注入沙箱）。
enum JSPluginCryptoBridge {
    static func data(fromHex hex: String) -> Data {
        var bytes: [UInt8] = []
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if next == clean.index(index, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex,
               let byte = UInt8(clean[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return Data(bytes)
    }

    static func hexToBase64(_ hex: String) -> String {
        data(fromHex: hex).base64EncodedString()
    }

    static func base64ToHex(_ base64: String) -> String {
        guard let decoded = Data(base64Encoded: base64) else { return "" }
        return hexString(from: decoded)
    }

    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hashHex(algorithm: String, hexInput: String) -> String {
        let input = data(fromHex: hexInput)
        switch algorithm.lowercased() {
        case "md5":
            return Insecure.MD5.hash(data: input).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            return Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return SHA512.hash(data: input).map { String(format: "%02x", $0) }.joined()
        default:
            return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func hmacHex(algorithm: String, hexInput: String, hexKey: String) -> String {
        let input = data(fromHex: hexInput)
        let key = SymmetricKey(data: data(fromHex: hexKey))
        switch algorithm.lowercased() {
        case "md5":
            let mac = HMAC<Insecure.MD5>.authenticationCode(for: input, using: key)
            return Data(mac).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: input, using: key)
            return Data(mac).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            let mac = HMAC<SHA512>.authenticationCode(for: input, using: key)
            return Data(mac).map { String(format: "%02x", $0) }.joined()
        default:
            let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
            return Data(mac).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func aesCryptHex(encrypt: Bool,
                            dataHex: String,
                            keyHex: String,
                            ivHex: String,
                            mode: String,
                            padding: String) -> String {
        let input = data(fromHex: dataHex)
        let rawKey = data(fromHex: keyHex)
        guard !rawKey.isEmpty else { return "" }

        let targetKeySize: Int
        if rawKey.count <= 16 {
            targetKeySize = kCCKeySizeAES128
        } else if rawKey.count <= 24 {
            targetKeySize = kCCKeySizeAES192
        } else {
            targetKeySize = kCCKeySizeAES256
        }

        var normalizedKey = Data(count: targetKeySize)
        normalizedKey.withUnsafeMutableBytes { dst in
            rawKey.withUnsafeBytes { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                memcpy(dstBase, srcBase, min(rawKey.count, targetKeySize))
            }
        }

        let isECB = mode.lowercased() == "ecb"
        var ivData = Data(count: kCCBlockSizeAES128)
        let rawIV = data(fromHex: ivHex)
        if !isECB && !rawIV.isEmpty {
            ivData.withUnsafeMutableBytes { dst in
                rawIV.withUnsafeBytes { src in
                    guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                    memcpy(dstBase, srcBase, min(rawIV.count, kCCBlockSizeAES128))
                }
            }
        }

        var options: CCOptions = 0
        if padding.lowercased() != "nopadding" {
            options |= CCOptions(kCCOptionPKCS7Padding)
        }
        if isECB {
            options |= CCOptions(kCCOptionECBMode)
        }

        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let outCapacity = input.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)
        var outLength = 0

        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                normalizedKey.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPtr.baseAddress,
                            targetKeySize,
                            isECB ? nil : ivPtr.baseAddress,
                            inPtr.baseAddress,
                            input.count,
                            outPtr.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return "" }
        outData.removeSubrange(outLength..<outData.count)
        return hexString(from: outData)
    }
}

/// 解析脚本头部 JSDoc 元数据（兼容 `@name`、`@version`、`@author`、`@description`、`@homepage`）。
enum JSPluginMetadataParser {
    static func parseHeader(from scriptSource: String) -> [String: String] {
        var clean = scriptSource
        if clean.hasPrefix("\u{FEFF}") {
            clean.removeFirst()
        }
        let headerWindow = String(clean.prefix(2400))
        var result: [String: String] = [:]
        let keys = ["name", "version", "author", "description", "homepage", "id"]
        for rawLine in headerWindow.components(separatedBy: .newlines) {
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/*"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("@") else { continue }
            let body = String(line.dropFirst())
            let parts = body.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard let keyPart = parts.first else { continue }
            let key = String(keyPart).lowercased()
            guard keys.contains(key), parts.count > 1 else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && result[key] == nil {
                result[key] = value
            }
        }
        return result
    }
}

/// 组装隔离沙箱内的标准 Web API 与社区 CommonJS 兼容垫片（MusicFree / LX / CommonJS）。
enum JSPluginBootstrapScripts {
    static let combinedBootstrapJS: String = [
        runtimeGlobalsJS,
        urlAndQueryJS,
        axiosAndFlowJS,
        cryptoAndEncodingJS,
        dayjsAndCheerioJS,
        webdavAndLXBridgeJS,
        moduleLoaderJS,
    ].joined(separator: "\n")

    private static let runtimeGlobalsJS = #"""
    var __flowHttpSeq = 0;
    var __flowPendingHttp = {};
    var __flowTimers = {};
    var module = { exports: {} };
    var exports = module.exports;
    if (typeof globalThis === "undefined") { var globalThis = this; }
    var global = globalThis;
    var self = globalThis;
    var window = globalThis;

    function setTimeout(fn, delay) {
        var id = __flowNativeSetTimeout(Number(delay) || 0);
        __flowTimers[id] = fn;
        return id;
    }
    function clearTimeout(id) {
        delete __flowTimers[id];
        if (id) __flowNativeClearTimeout(String(id));
    }
    function __flowFireTimer(id) {
        var fn = __flowTimers[id];
        delete __flowTimers[id];
        if (typeof fn === "function") fn();
    }
    function __flowResolveHTTP(id, ok, payloadJson, errMsg) {
        var p = __flowPendingHttp[id];
        delete __flowPendingHttp[id];
        if (!p) return;
        if (!ok) {
            p.reject(new Error(errMsg || "HTTP error"));
            return;
        }
        try {
            p.resolve(JSON.parse(payloadJson));
        } catch (e) {
            p.reject(e);
        }
    }

    var console = {
        log: function() { __flowNativeLog("info", Array.prototype.slice.call(arguments).join(" ")); },
        info: function() { __flowNativeLog("info", Array.prototype.slice.call(arguments).join(" ")); },
        debug: function() { __flowNativeLog("debug", Array.prototype.slice.call(arguments).join(" ")); },
        warn: function() { __flowNativeLog("warn", Array.prototype.slice.call(arguments).join(" ")); },
        error: function() { __flowNativeLog("error", Array.prototype.slice.call(arguments).join(" ")); }
    };

    function btoa(s) { return __flowNativeBase64Enc(String(s)); }
    function atob(s) { return __flowNativeBase64Dec(String(s)); }

    function __flowUtf8ToHex(str) {
        var encoded = unescape(encodeURIComponent(String(str)));
        var hex = "";
        for (var i = 0; i < encoded.length; i++) {
            var h = encoded.charCodeAt(i).toString(16);
            hex += (h.length < 2 ? "0" + h : h);
        }
        return hex;
    }
    function __flowHexToUtf8(hex) {
        var s = "";
        hex = String(hex || "").replace(/[^0-9a-fA-F]/g, "");
        for (var i = 0; i + 1 < hex.length; i += 2) {
            s += "%" + hex.slice(i, i + 2);
        }
        try { return decodeURIComponent(s); } catch (e) { return s; }
    }
    function __flowLatin1ToHex(str) {
        var hex = "";
        str = String(str);
        for (var i = 0; i < str.length; i++) {
            var h = (str.charCodeAt(i) & 0xff).toString(16);
            hex += (h.length < 2 ? "0" + h : h);
        }
        return hex;
    }
    function __flowHexToLatin1(hex) {
        var out = "";
        hex = String(hex || "").replace(/[^0-9a-fA-F]/g, "");
        for (var i = 0; i + 1 < hex.length; i += 2) {
            out += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16));
        }
        return out;
    }
    function __flowHexToBase64(hex) {
        return __flowNativeHexToBase64(String(hex || ""));
    }
    function __flowBase64ToHex(b64) {
        return __flowNativeBase64ToHex(String(b64 || ""));
    }

    var Buffer = {
        from: function(input, enc) {
            var hex;
            if (typeof input === "string") {
                var e = String(enc || "utf8").toLowerCase();
                if (e === "base64") hex = __flowBase64ToHex(input);
                else if (e === "hex") hex = input.replace(/[^0-9a-fA-F]/g, "");
                else hex = __flowUtf8ToHex(input);
            } else if (Array.isArray(input)) {
                hex = input.map(function(b) { var h = (b & 0xff).toString(16); return h.length < 2 ? "0" + h : h; }).join("");
            } else {
                hex = "";
            }
            return {
                __hex: hex,
                length: hex.length / 2,
                toString: function(outEnc) {
                    var o = String(outEnc || "utf8").toLowerCase();
                    if (o === "hex") return hex;
                    if (o === "base64") return __flowHexToBase64(hex);
                    return __flowHexToUtf8(hex);
                }
            };
        }
    };
    """#

    private static let urlAndQueryJS = #"""
    function URLSearchParams(init) {
        this._pairs = [];
        this._onChange = null;
        if (typeof init === "string") {
            var q = init.replace(/^\?/, "");
            if (q) {
                q.split("&").forEach(function(part) {
                    if (!part) return;
                    var idx = part.indexOf("=");
                    var rawK = idx >= 0 ? part.slice(0, idx) : part;
                    var rawV = idx >= 0 ? part.slice(idx + 1) : "";
                    this._pairs.push([
                        decodeURIComponent(rawK.replace(/\+/g, " ")),
                        decodeURIComponent(rawV.replace(/\+/g, " "))
                    ]);
                }, this);
            }
        } else if (init && typeof init === "object") {
            Object.keys(init).forEach(function(k) {
                this._pairs.push([String(k), String(init[k])]);
            }, this);
        }
    }
    URLSearchParams.prototype._notify = function() {
        if (typeof this._onChange === "function") this._onChange();
    };
    URLSearchParams.prototype.append = function(k, v) {
        this._pairs.push([String(k), String(v)]);
        this._notify();
    };
    URLSearchParams.prototype.set = function(k, v) {
        var key = String(k), val = String(v), replaced = false, next = [];
        for (var i = 0; i < this._pairs.length; i++) {
            if (this._pairs[i][0] === key) {
                if (!replaced) { next.push([key, val]); replaced = true; }
            } else {
                next.push(this._pairs[i]);
            }
        }
        if (!replaced) next.push([key, val]);
        this._pairs = next;
        this._notify();
    };
    URLSearchParams.prototype.get = function(k) {
        var key = String(k);
        for (var i = 0; i < this._pairs.length; i++) {
            if (this._pairs[i][0] === key) return this._pairs[i][1];
        }
        return null;
    };
    URLSearchParams.prototype.has = function(k) { return this.get(k) !== null; };
    URLSearchParams.prototype.delete = function(k) {
        var key = String(k);
        this._pairs = this._pairs.filter(function(p) { return p[0] !== key; });
        this._notify();
    };
    URLSearchParams.prototype.keys = function() { return this._pairs.map(function(p) { return p[0]; }); };
    URLSearchParams.prototype.values = function() { return this._pairs.map(function(p) { return p[1]; }); };
    URLSearchParams.prototype.forEach = function(cb) {
        for (var i = 0; i < this._pairs.length; i++) cb(this._pairs[i][1], this._pairs[i][0], this);
    };
    URLSearchParams.prototype.toString = function() {
        return this._pairs.map(function(p) {
            return encodeURIComponent(p[0]) + "=" + encodeURIComponent(p[1]);
        }).join("&");
    };

    function URL(input, base) {
        var str = String(input || "").trim();
        if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(str)) {
            var b = base instanceof URL ? base : new URL(String(base));
            if (str.startsWith("//")) str = b.protocol + str;
            else if (str.startsWith("/")) str = b.origin + str;
            else {
                var dir = b.pathname.replace(/\/[^\/]*$/, "/");
                str = b.origin + dir + str;
            }
        }
        var m = str.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/(?:([^:@\/?#]+)(?::([^@\/?#]*))?@)?([^:\/?#]+|\[[^\]]+\])(?::(\d+))?([^?#]*)(\?[^#]*)?(#.*)?$/);
        if (!m) throw new TypeError("Invalid URL: " + input);
        this.protocol = m[1].toLowerCase();
        this.username = m[2] || "";
        this.password = m[3] || "";
        this.hostname = m[4] || "";
        this.port = m[5] || "";
        this.pathname = m[6] || "/";
        this._search = m[7] || "";
        this.hash = m[8] || "";
        var selfUrl = this;
        this.searchParams = new URLSearchParams(this._search);
        this.searchParams._onChange = function() {
            var qsStr = selfUrl.searchParams.toString();
            selfUrl._search = qsStr ? ("?" + qsStr) : "";
        };
    }
    Object.defineProperty(URL.prototype, "host", {
        get: function() { return this.port ? (this.hostname + ":" + this.port) : this.hostname; }
    });
    Object.defineProperty(URL.prototype, "origin", {
        get: function() { return this.protocol + "//" + this.host; }
    });
    Object.defineProperty(URL.prototype, "search", {
        get: function() { return this._search; },
        set: function(v) {
            var s = String(v || "");
            this._search = s && !s.startsWith("?") ? ("?" + s) : s;
            this.searchParams = new URLSearchParams(this._search);
            var selfUrl = this;
            this.searchParams._onChange = function() {
                var qsStr = selfUrl.searchParams.toString();
                selfUrl._search = qsStr ? ("?" + qsStr) : "";
            };
        }
    });
    Object.defineProperty(URL.prototype, "href", {
        get: function() { return this.toString(); }
    });
    URL.prototype.toString = function() {
        var auth = this.username ? (this.username + (this.password ? ":" + this.password : "") + "@") : "";
        var qsStr = this.searchParams.toString();
        var s = qsStr ? ("?" + qsStr) : "";
        return this.protocol + "//" + auth + this.host + this.pathname + s + this.hash;
    };

    var __flowQs = {
        stringify: function(obj, opts) {
            if (!obj || typeof obj !== "object") return "";
            var parts = [];
            Object.keys(obj).forEach(function(k) {
                var v = obj[k];
                if (v === undefined || v === null) return;
                if (Array.isArray(v)) {
                    var fmt = opts && opts.arrayFormat;
                    v.forEach(function(item, idx) {
                        var keyName = fmt === "brackets" ? (k + "[]") : (fmt === "indices" ? (k + "[" + idx + "]") : k);
                        parts.push(encodeURIComponent(keyName) + "=" + encodeURIComponent(String(item)));
                    });
                } else {
                    parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)));
                }
            });
            return parts.join("&");
        },
        parse: function(str) {
            var out = {};
            new URLSearchParams(String(str || ""))._pairs.forEach(function(p) {
                out[p[0]] = p[1];
            });
            return out;
        }
    };
    """#

    private static let axiosAndFlowJS = #"""
    var flow = {
        request: function(opts) {
            return new Promise(function(resolve, reject) {
                __flowHttpSeq += 1;
                var id = "h" + __flowHttpSeq;
                __flowPendingHttp[id] = { resolve: resolve, reject: reject };
                __flowNativeHTTP(id, opts || {});
            });
        },
        storage: {
            get: function(key) { return __flowStorageGet(String(key)); },
            set: function(key, val) { __flowStorageSet(String(key), val == null ? null : String(val)); },
            remove: function(key) { __flowStorageSet(String(key), null); }
        },
        crypto: {
            md5: function(s) { return __flowNativeHash("md5", __flowUtf8ToHex(String(s))); },
            sha1: function(s) { return __flowNativeHash("sha1", __flowUtf8ToHex(String(s))); },
            sha256: function(s) { return __flowNativeHash("sha256", __flowUtf8ToHex(String(s))); },
            sha512: function(s) { return __flowNativeHash("sha512", __flowUtf8ToHex(String(s))); },
            hmacSha256: function(s, k) { return __flowNativeHmac("sha256", __flowUtf8ToHex(String(s)), __flowUtf8ToHex(String(k))); },
            hmacSha1: function(s, k) { return __flowNativeHmac("sha1", __flowUtf8ToHex(String(s)), __flowUtf8ToHex(String(k))); },
            hmacMd5: function(s, k) { return __flowNativeHmac("md5", __flowUtf8ToHex(String(s)), __flowUtf8ToHex(String(k))); },
            base64Encode: function(s) { return __flowNativeBase64Enc(String(s)); },
            base64Decode: function(s) { return __flowNativeBase64Dec(String(s)); },
            createHash: function(alg) {
                var acc = "";
                return {
                    update: function(chunk) { acc += String(chunk); return this; },
                    digest: function(enc) {
                        var h = __flowNativeHash(String(alg), __flowUtf8ToHex(acc));
                        return String(enc || "hex").toLowerCase() === "base64" ? __flowHexToBase64(h) : h;
                    }
                };
            },
            createHmac: function(alg, key) {
                var acc = "";
                return {
                    update: function(chunk) { acc += String(chunk); return this; },
                    digest: function(enc) {
                        var h = __flowNativeHmac(String(alg), __flowUtf8ToHex(acc), __flowUtf8ToHex(String(key)));
                        return String(enc || "hex").toLowerCase() === "base64" ? __flowHexToBase64(h) : h;
                    }
                };
            },
            randomBytes: function(n) {
                var hex = "";
                for (var i = 0; i < (n || 16); i++) {
                    var b = Math.floor(Math.random() * 256).toString(16);
                    hex += (b.length < 2 ? "0" + b : b);
                }
                return Buffer.from(hex, "hex");
            }
        }
    };

    // Text/JSON fetch compatibility shares the native bridge and all of its network policies.
    function fetch(input, init) {
        return Promise.resolve().then(function() {
            var opts = init || {};
            var headers = {};
            if (Array.isArray(opts.headers)) {
                opts.headers.forEach(function(pair) { headers[String(pair[0])] = String(pair[1]); });
            } else if (opts.headers && typeof opts.headers.forEach === "function") {
                opts.headers.forEach(function(value, name) { headers[String(name)] = String(value); });
            } else {
                Object.keys(opts.headers || {}).forEach(function(name) { headers[name] = String(opts.headers[name]); });
            }
            return flow.request({
                url: String(input),
                method: opts.method || "GET",
                headers: headers,
                body: opts.body == null ? undefined : String(opts.body),
                responseType: "text"
            });
        }).then(function(res) {
            var body = String(res.rawBody == null ? "" : res.rawBody);
            var headers = res.headers || {};
            return {
                ok: !!res.ok,
                status: res.status,
                statusText: res.statusText || "",
                url: res.url || "",
                headers: {
                    get: function(name) {
                        var key = String(name).toLowerCase();
                        return Object.prototype.hasOwnProperty.call(headers, key) ? String(headers[key]) : null;
                    }
                },
                text: function() { return Promise.resolve(body); },
                json: function() { return Promise.resolve().then(function() { return JSON.parse(body); }); }
            };
        });
    }

    var env = {
        os: "macos",
        appVersion: "1.0.0",
        isDesktop: true,
        getUserVariables: function() {
            var raw = __flowStorageGet("vars");
            if (!raw) return {};
            try { return JSON.parse(raw) || {}; } catch (e) { return {}; }
        },
        setUserVariables: function(obj) {
            __flowStorageSet("vars", obj ? JSON.stringify(obj) : null);
        }
    };

    function __flowNormalizeAxiosCfg(configOrUrl, maybeConfig, baseDefaults) {
        var cfg;
        if (typeof configOrUrl === "string") {
            var extra = maybeConfig || {};
            var stdKeys = ["headers","params","timeout","data","body","method","url","baseURL","responseType","auth","withCredentials","maxRedirects","validateStatus"];
            var extraKeys = (extra && typeof extra === "object" && !Array.isArray(extra)) ? Object.keys(extra) : [];
            var looksLikeRawHeaders = extraKeys.length > 0 && extraKeys.every(function(k) {
                return stdKeys.indexOf(k) === -1 && (typeof extra[k] === "string" || typeof extra[k] === "number");
            });
            cfg = looksLikeRawHeaders ? { url: configOrUrl, headers: extra } : Object.assign({}, extra, { url: configOrUrl });
        } else {
            cfg = Object.assign({}, configOrUrl || {});
        }
        var defHeaders = (baseDefaults && baseDefaults.headers) ? Object.assign({}, baseDefaults.headers.common || {}, baseDefaults.headers) : {};
        delete defHeaders.common;
        cfg.headers = Object.assign({}, defHeaders, cfg.headers || {});
        if (baseDefaults && baseDefaults.baseURL && cfg.url && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(cfg.url)) {
            var b = baseDefaults.baseURL.replace(/\/+$/, "");
            var p = cfg.url.replace(/^\/+/, "");
            cfg.url = b + "/" + p;
        }
        if (baseDefaults && baseDefaults.timeout && !cfg.timeout) cfg.timeout = baseDefaults.timeout;
        if (baseDefaults && baseDefaults.params) cfg.params = Object.assign({}, baseDefaults.params, cfg.params || {});
        return cfg;
    }

    function __flowBuildAxios(baseDefaults) {
        var reqHooks = [];
        var resHooks = [];
        function instance(configOrUrl, maybeConfig) {
            var cfg = __flowNormalizeAxiosCfg(configOrUrl, maybeConfig, instance.defaults);
            var p = Promise.resolve(cfg);
            reqHooks.forEach(function(h) {
                p = p.then(h.fulfilled, h.rejected);
            });
            p = p.then(function(finalCfg) {
                return flow.request(finalCfg).then(function(res) {
                    res.config = finalCfg;
                    res.request = { responseURL: res.url || finalCfg.url || "" };
                    if (!res.ok) {
                        var err = new Error("Request failed with status code " + res.status);
                        err.response = res;
                        err.config = finalCfg;
                        throw err;
                    }
                    return res;
                });
            });
            resHooks.forEach(function(h) {
                p = p.then(h.fulfilled, h.rejected);
            });
            return p;
        }
        instance.defaults = Object.assign({ timeout: 15000, headers: { common: {} } }, baseDefaults || {});
        instance.interceptors = {
            request: { use: function(fulfilled, rejected) { reqHooks.push({ fulfilled: fulfilled, rejected: rejected }); return reqHooks.length - 1; } },
            response: { use: function(fulfilled, rejected) { resHooks.push({ fulfilled: fulfilled, rejected: rejected }); return resHooks.length - 1; } }
        };
        instance.get = function(url, cfg) { return instance(__flowNormalizeAxiosCfg(url, cfg, { method: "GET" })); };
        instance.delete = function(url, cfg) { return instance(Object.assign(__flowNormalizeAxiosCfg(url, cfg), { method: "DELETE" })); };
        instance.head = function(url, cfg) { return instance(Object.assign(__flowNormalizeAxiosCfg(url, cfg), { method: "HEAD" })); };
        instance.post = function(url, data, cfg) { return instance(Object.assign(__flowNormalizeAxiosCfg(url, cfg), { method: "POST", data: data })); };
        instance.put = function(url, data, cfg) { return instance(Object.assign(__flowNormalizeAxiosCfg(url, cfg), { method: "PUT", data: data })); };
        instance.request = function(cfg) { return instance(cfg); };
        instance.create = function(opts) { return __flowBuildAxios(opts); };
        instance.default = instance;
        return instance;
    }
    var axios = __flowBuildAxios({});
    """#

    private static let cryptoAndEncodingJS = #"""
    function __flowWrapWordArray(hexStr) {
        var clean = String(hexStr || "").replace(/[^0-9a-fA-F]/g, "");
        return {
            __hex: clean,
            sigBytes: clean.length / 2,
            toString: function(encoder) {
                if (encoder && typeof encoder.stringify === "function") {
                    return encoder.stringify(this);
                }
                return clean;
            }
        };
    }
    function __flowInputToHex(input) {
        if (input && typeof input === "object" && typeof input.__hex === "string") return input.__hex;
        return __flowUtf8ToHex(String(input == null ? "" : input));
    }

    var CryptoJS = {
        enc: {
            Utf8: {
                parse: function(s) { return __flowWrapWordArray(__flowUtf8ToHex(String(s))); },
                stringify: function(w) { return __flowHexToUtf8(w && w.__hex != null ? w.__hex : String(w)); }
            },
            Hex: {
                parse: function(s) { return __flowWrapWordArray(String(s)); },
                stringify: function(w) { return String(w && w.__hex != null ? w.__hex : String(w)); }
            },
            Base64: {
                parse: function(s) { return __flowWrapWordArray(__flowBase64ToHex(String(s))); },
                stringify: function(w) { return __flowHexToBase64(w && w.__hex != null ? w.__hex : __flowUtf8ToHex(String(w))); }
            },
            Latin1: {
                parse: function(s) { return __flowWrapWordArray(__flowLatin1ToHex(String(s))); },
                stringify: function(w) { return __flowHexToLatin1(w && w.__hex != null ? w.__hex : String(w)); }
            }
        },
        mode: { ECB: "ecb", CBC: "cbc" },
        pad: { Pkcs7: "pkcs7", ZeroPadding: "pkcs7", NoPadding: "nopadding" },
        MD5: function(s) { return __flowWrapWordArray(__flowNativeHash("md5", __flowInputToHex(s))); },
        SHA1: function(s) { return __flowWrapWordArray(__flowNativeHash("sha1", __flowInputToHex(s))); },
        SHA256: function(s) { return __flowWrapWordArray(__flowNativeHash("sha256", __flowInputToHex(s))); },
        SHA512: function(s) { return __flowWrapWordArray(__flowNativeHash("sha512", __flowInputToHex(s))); },
        HmacMD5: function(s, k) { return __flowWrapWordArray(__flowNativeHmac("md5", __flowInputToHex(s), __flowInputToHex(k))); },
        HmacSHA1: function(s, k) { return __flowWrapWordArray(__flowNativeHmac("sha1", __flowInputToHex(s), __flowInputToHex(k))); },
        HmacSHA256: function(s, k) { return __flowWrapWordArray(__flowNativeHmac("sha256", __flowInputToHex(s), __flowInputToHex(k))); },
        HmacSHA512: function(s, k) { return __flowWrapWordArray(__flowNativeHmac("sha512", __flowInputToHex(s), __flowInputToHex(k))); },
        AES: {
            encrypt: function(data, key, cfg) {
                var c = cfg || {};
                var ivHex = c.iv ? __flowInputToHex(c.iv) : "";
                var hex = __flowNativeAES(true, __flowInputToHex(data), __flowInputToHex(key), ivHex, String(c.mode || "cbc"), String(c.padding || "pkcs7"));
                var wa = __flowWrapWordArray(hex);
                return {
                    ciphertext: wa,
                    toString: function(fmt) {
                        if (fmt && typeof fmt.stringify === "function") return fmt.stringify(wa);
                        return __flowHexToBase64(hex);
                    }
                };
            },
            decrypt: function(cipher, key, cfg) {
                var c = cfg || {};
                var cipherHex;
                if (typeof cipher === "string") cipherHex = __flowBase64ToHex(cipher);
                else if (cipher && cipher.ciphertext && cipher.ciphertext.__hex) cipherHex = cipher.ciphertext.__hex;
                else if (cipher && cipher.__hex) cipherHex = cipher.__hex;
                else cipherHex = "";
                var ivHex = c.iv ? __flowInputToHex(c.iv) : "";
                var hex = __flowNativeAES(false, cipherHex, __flowInputToHex(key), ivHex, String(c.mode || "cbc"), String(c.padding || "pkcs7"));
                return __flowWrapWordArray(hex);
            }
        }
    };

    var __flowHtmlEntities = {
        amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", copy: "©", reg: "®",
        middot: "·", mdash: "—", ndash: "–", hellip: "…", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”"
    };
    var __flowHe = {
        decode: function(str) {
            return String(str || "").replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, function(m, body) {
                if (body[0] === "#") {
                    var code = (body[1] === "x" || body[1] === "X") ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
                    return isNaN(code) ? m : String.fromCharCode(code);
                }
                return __flowHtmlEntities.hasOwnProperty(body) ? __flowHtmlEntities[body] : m;
            });
        },
        encode: function(str) {
            return String(str || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
        }
    };
    __flowHe.unescape = __flowHe.decode;
    __flowHe.escape = __flowHe.encode;

    function __flowBigIntWrap(val, radix) {
        var b = (typeof val === "bigint") ? val : BigInt(radix ? parseInt(String(val), radix) : String(val || 0));
        return {
            value: b,
            add: function(x) { return __flowBigIntWrap(b + __flowBigIntWrap(x).value); },
            subtract: function(x) { return __flowBigIntWrap(b - __flowBigIntWrap(x).value); },
            multiply: function(x) { return __flowBigIntWrap(b * __flowBigIntWrap(x).value); },
            divide: function(x) { return __flowBigIntWrap(b / __flowBigIntWrap(x).value); },
            mod: function(x) { return __flowBigIntWrap(b % __flowBigIntWrap(x).value); },
            pow: function(x) { return __flowBigIntWrap(b ** __flowBigIntWrap(x).value); },
            modPow: function(exp, mod) {
                var e = __flowBigIntWrap(exp).value, m = __flowBigIntWrap(mod).value;
                var res = 1n, base = ((b % m) + m) % m;
                while (e > 0n) {
                    if (e & 1n) res = (res * base) % m;
                    e >>= 1n;
                    base = (base * base) % m;
                }
                return __flowBigIntWrap(res);
            },
            toString: function(r) { return b.toString(r || 10); }
        };
    }
    """#

    private static let dayjsAndCheerioJS = #"""
    function __flowPad2(n) { return (n < 10 ? "0" : "") + n; }
    function dayjs(input) {
        var d = (input instanceof Date) ? new Date(input.getTime())
            : (input && input._d instanceof Date) ? new Date(input._d.getTime())
            : (typeof input === "number") ? new Date(input)
            : (typeof input === "string" && input) ? new Date(input)
            : new Date();
        return {
            _d: d,
            unix: function() { return Math.floor(d.getTime() / 1000); },
            valueOf: function() { return d.getTime(); },
            year: function() { return d.getFullYear(); },
            month: function() { return d.getMonth(); },
            date: function() { return d.getDate(); },
            hour: function() { return d.getHours(); },
            minute: function() { return d.getMinutes(); },
            second: function() { return d.getSeconds(); },
            add: function(n, unit) {
                var copy = new Date(d.getTime());
                var u = String(unit || "ms").toLowerCase();
                if (u.startsWith("d")) copy.setDate(copy.getDate() + n);
                else if (u.startsWith("h")) copy.setHours(copy.getHours() + n);
                else if (u.startsWith("m")) copy.setMinutes(copy.getMinutes() + n);
                else if (u.startsWith("s")) copy.setSeconds(copy.getSeconds() + n);
                else if (u.startsWith("y")) copy.setFullYear(copy.getFullYear() + n);
                return dayjs(copy);
            },
            subtract: function(n, unit) { return this.add(-n, unit); },
            format: function(tpl) {
                var f = tpl || "YYYY-MM-DDTHH:mm:ss";
                return f.replace(/YYYY/g, String(d.getFullYear()))
                    .replace(/MM/g, __flowPad2(d.getMonth() + 1))
                    .replace(/DD/g, __flowPad2(d.getDate()))
                    .replace(/HH/g, __flowPad2(d.getHours()))
                    .replace(/mm/g, __flowPad2(d.getMinutes()))
                    .replace(/ss/g, __flowPad2(d.getSeconds()));
            },
            isBefore: function(other) { return d.getTime() < dayjs(other).valueOf(); },
            isAfter: function(other) { return d.getTime() > dayjs(other).valueOf(); }
        };
    }
    dayjs.unix = function(sec) { return dayjs(Number(sec) * 1000); };

    var __flowVoidTags = { area:1, base:1, br:1, col:1, embed:1, hr:1, img:1, input:1, link:1, meta:1, param:1, source:1, track:1, wbr:1 };
    function __flowParseAttrs(raw) {
        var attrs = {};
        if (!raw) return attrs;
        var re = /([a-zA-Z0-9_:-]+)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
        var m;
        while ((m = re.exec(raw)) !== null) {
            var k = m[1].toLowerCase();
            var v = m[2] !== undefined ? m[2] : (m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : ""));
            attrs[k] = __flowHe.decode(v);
        }
        return attrs;
    }
    function __flowParseHTML(html) {
        var root = { tag: "#root", attrs: {}, children: [], parent: null, text: null };
        var stack = [root];
        var cleaned = String(html || "").replace(/<!--[\s\S]*?-->/g, "");
        var tokenRe = /<(script|style)([^>]*)>([\s\S]*?)<\/\1>|<(\/?)([a-zA-Z0-9_:-]+)([^>]*)>|([^<]+)/gi;
        var m;
        while ((m = tokenRe.exec(cleaned)) !== null) {
            if (m[1] !== undefined) {
                var rawTag = m[1].toLowerCase();
                var rawEl = { tag: rawTag, attrs: __flowParseAttrs(m[2] || ""), children: [], parent: stack[stack.length - 1], text: null };
                if (m[3]) rawEl.children.push({ tag: "#text", attrs: {}, children: [], parent: rawEl, text: m[3] });
                stack[stack.length - 1].children.push(rawEl);
                continue;
            }
            if (m[7] !== undefined) {
                var txt = __flowHe.decode(m[7]);
                if (txt) stack[stack.length - 1].children.push({ tag: "#text", attrs: {}, children: [], parent: stack[stack.length - 1], text: txt });
                continue;
            }
            var isClose = m[4] === "/";
            var tag = m[5].toLowerCase();
            var rawAttrs = m[6] || "";
            if (isClose) {
                for (var i = stack.length - 1; i >= 1; i--) {
                    if (stack[i].tag === tag) { stack.length = i; break; }
                }
            } else {
                var selfClose = rawAttrs.trim().endsWith("/") || __flowVoidTags[tag];
                var node = { tag: tag, attrs: __flowParseAttrs(rawAttrs.replace(/\/$/, "")), children: [], parent: stack[stack.length - 1], text: null };
                stack[stack.length - 1].children.push(node);
                if (!selfClose) stack.push(node);
            }
        }
        return root;
    }
    function __flowNodeMatchesSimple(node, simple) {
        if (!node || !node.tag || node.tag.startsWith("#")) return false;
        var s = simple.trim();
        var eqM = s.match(/:eq\((\d+)\)|:(first|last)$/);
        if (eqM) s = s.slice(0, eqM.index);
        var attrChecks = [];
        s = s.replace(/\[([^\]=]+)(?:=([^\]]+))?\]/g, function(_, k, v) {
            attrChecks.push([k.trim().toLowerCase(), v ? v.replace(/^['"]|['"]$/g, "") : null]);
            return "";
        });
        var tagM = s.match(/^([a-zA-Z0-9_-]+|\*)/);
        if (tagM) {
            if (tagM[1] !== "*" && node.tag !== tagM[1].toLowerCase()) return false;
            s = s.slice(tagM[0].length);
        }
        var idM = s.match(/#([a-zA-Z0-9_-]+)/);
        if (idM && node.attrs.id !== idM[1]) return false;
        var clsRe = /\.([a-zA-Z0-9_-]+)/g;
        var cm;
        while ((cm = clsRe.exec(s)) !== null) {
            var classes = (node.attrs.class || "").split(/\s+/);
            if (classes.indexOf(cm[1]) === -1) return false;
        }
        for (var i = 0; i < attrChecks.length; i++) {
            var ak = attrChecks[i][0], av = attrChecks[i][1];
            if (!node.attrs.hasOwnProperty(ak)) return false;
            if (av !== null && node.attrs[ak] !== av) return false;
        }
        return true;
    }
    function __flowQueryChain(contexts, selector) {
        var parts = String(selector || "").split(",");
        var out = [];
        parts.forEach(function(part) {
            var tokens = part.trim().replace(/\s*>\s*/g, " > ").split(/\s+/).filter(Boolean);
            if (!tokens.length) return;
            var current = contexts.slice();
            var directOnly = false;
            tokens.forEach(function(tok) {
                if (tok === ">") { directOnly = true; return; }
                var next = [];
                function collect(node) {
                    var children = node.children || [];
                    for (var i = 0; i < children.length; i++) {
                        var ch = children[i];
                        if (__flowNodeMatchesSimple(ch, tok)) next.push(ch);
                        if (!directOnly) collect(ch);
                    }
                }
                current.forEach(collect);
                var eqM = tok.match(/:eq\((\d+)\)$/);
                if (eqM) { var idx = parseInt(eqM[1], 10); next = next[idx] ? [next[idx]] : []; }
                else if (tok.endsWith(":first")) { next = next.length ? [next[0]] : []; }
                else if (tok.endsWith(":last")) { next = next.length ? [next[next.length - 1]] : []; }
                current = next;
                directOnly = false;
            });
            current.forEach(function(n) { if (out.indexOf(n) === -1) out.push(n); });
        });
        return out;
    }
    function __flowNodeText(node) {
        if (!node) return "";
        if (node.tag === "#text") return node.text || "";
        return (node.children || []).map(__flowNodeText).join("");
    }
    function __flowNodeHTML(node) {
        if (!node) return "";
        if (node.tag === "#text") return node.text || "";
        var inner = (node.children || []).map(__flowNodeHTML).join("");
        if (node.tag === "#root") return inner;
        return "<" + node.tag + ">" + inner + "</" + node.tag + ">";
    }
    var cheerio = {
        load: function(html) {
            var root = __flowParseHTML(html);
            function wrap(nodes) {
                var list = (Array.isArray(nodes) ? nodes : (nodes ? [nodes] : [])).filter(Boolean);
                var api = {
                    length: list.length,
                    _nodes: list,
                    get: function(i) { return i === undefined ? list.slice() : list[i]; },
                    toArray: function() { return list.slice(); },
                    eq: function(i) { return wrap(list[i] ? [list[i]] : []); },
                    first: function() { return wrap(list.length ? [list[0]] : []); },
                    last: function() { return wrap(list.length ? [list[list.length - 1]] : []); },
                    parent: function() { return wrap(list.map(function(n) { return n.parent; }).filter(function(n) { return n && n.tag !== "#root"; })); },
                    children: function(sel) {
                        var ch = [];
                        list.forEach(function(n) {
                            (n.children || []).forEach(function(c) {
                                if (!c.tag.startsWith("#") && (!sel || __flowNodeMatchesSimple(c, sel))) ch.push(c);
                            });
                        });
                        return wrap(ch);
                    },
                    find: function(sel) { return wrap(__flowQueryChain(list, sel)); },
                    filter: function(sel) {
                        if (typeof sel === "function") return wrap(list.filter(function(n, idx) { return sel(idx, n); }));
                        return wrap(list.filter(function(n) { return __flowNodeMatchesSimple(n, sel); }));
                    },
                    each: function(fn) { list.forEach(function(n, i) { fn(i, n); }); return api; },
                    map: function(fn) { return wrapArrayResult(list.map(function(n, i) { return fn(i, n); })); },
                    text: function() { return list.map(__flowNodeText).join(""); },
                    html: function() { return list.length ? (list[0].children || []).map(__flowNodeHTML).join("") : ""; },
                    attr: function(name) { return list.length ? list[0].attrs[String(name).toLowerCase()] : undefined; },
                    prop: function(name) {
                        if (!list.length) return undefined;
                        if (String(name).toLowerCase() === "tagname") return list[0].tag.toUpperCase();
                        return list[0].attrs[String(name).toLowerCase()];
                    }
                };
                for (var idx = 0; idx < list.length; idx++) api[idx] = list[idx];
                return api;
            }
            function wrapArrayResult(arr) {
                return {
                    length: arr.length,
                    toArray: function() { return arr; },
                    get: function(i) { return i === undefined ? arr : arr[i]; }
                };
            }
            var $ = function(sel, ctx) {
                if (!sel) return wrap([]);
                if (typeof sel !== "string") {
                    if (sel._nodes) return sel;
                    return wrap(sel);
                }
                var baseNodes = ctx ? (typeof ctx === "string" ? __flowQueryChain([root], ctx) : (ctx._nodes || [ctx])) : [root];
                return wrap(__flowQueryChain(baseNodes, sel));
            };
            $.html = function() { return __flowNodeHTML(root); };
            return $;
        }
    };
    """#

    private static let webdavAndLXBridgeJS = #"""
    function __flowInferAudioMime(name) {
        var lower = String(name || "").toLowerCase();
        if (lower.endsWith(".mp3")) return "audio/mpeg";
        if (lower.endsWith(".flac")) return "audio/flac";
        if (lower.endsWith(".m4a")) return "audio/mp4";
        if (lower.endsWith(".aac")) return "audio/aac";
        if (lower.endsWith(".wav")) return "audio/wav";
        if (lower.endsWith(".ogg")) return "audio/ogg";
        if (lower.endsWith(".opus")) return "audio/opus";
        return "application/octet-stream";
    }
    function __flowStripXmlTag(block, tag) {
        var re = new RegExp("<(?:[a-zA-Z0-9_-]+:)?" + tag + "(?:\\s[^>]*)?>([\\s\\S]*?)<\\/(?:[a-zA-Z0-9_-]+:)?" + tag + ">", "i");
        var m = block.match(re);
        return m ? __flowHe.decode(m[1].trim()) : "";
    }
    var __flowWebdav = {
        AuthType: { Password: "password", None: "none", Digest: "digest" },
        createClient: function(baseUrl, options) {
            var cleanBase = String(baseUrl || "").replace(/\/+$/, "");
            var opts = options || {};
            var authHeader = "";
            if (opts.username || opts.password) {
                authHeader = "Basic " + btoa((opts.username || "") + ":" + (opts.password || ""));
            }
            function targetURL(remotePath) {
                var p = String(remotePath || "/");
                if (!p.startsWith("/")) p = "/" + p;
                var encodedPath = p.split("/").map(function(seg) { return encodeURIComponent(decodeURIComponent(seg)); }).join("/");
                return cleanBase + encodedPath;
            }
            return {
                getDirectoryContents: async function(remotePath) {
                    var reqHeaders = { Depth: "1", "Content-Type": "application/xml" };
                    if (authHeader) reqHeaders.Authorization = authHeader;
                    var res = await flow.request({
                        url: targetURL(remotePath),
                        method: "PROPFIND",
                        headers: reqHeaders,
                        responseType: "text"
                    });
                    var xml = String(res.rawBody || res.data || "");
                    var reqPathname = "";
                    try { reqPathname = decodeURIComponent(new URL(targetURL(remotePath)).pathname).replace(/\/+$/, ""); } catch (e) {}
                    var blocks = xml.match(/<(?:[a-zA-Z0-9_-]+:)?response(?:\s[^>]*)?>[\s\S]*?<\/(?:[a-zA-Z0-9_-]+:)?response>/gi) || [];
                    var items = [];
                    blocks.forEach(function(blk) {
                        var href = __flowStripXmlTag(blk, "href");
                        if (!href) return;
                        var pathname = href;
                        try { pathname = href.startsWith("http") ? new URL(href).pathname : href; } catch (e) {}
                        var decodedPath = decodeURIComponent(pathname);
                        var trimmedPath = decodedPath.replace(/\/+$/, "");
                        if (trimmedPath === reqPathname) return;
                        var isDir = /<(?:[a-zA-Z0-9_-]+:)?collection\s*\/?>/i.test(blk) || decodedPath.endsWith("/");
                        var parts = trimmedPath.split("/").filter(Boolean);
                        var basename = parts.length ? parts[parts.length - 1] : trimmedPath;
                        var mime = __flowStripXmlTag(blk, "getcontenttype");
                        if (!mime && !isDir) mime = __flowInferAudioMime(basename);
                        items.push({
                            filename: trimmedPath || "/",
                            basename: basename,
                            type: isDir ? "directory" : "file",
                            mime: mime || "",
                            size: parseInt(__flowStripXmlTag(blk, "getcontentlength") || "0", 10) || 0
                        });
                    });
                    return items;
                },
                getFileDownloadLink: function(remotePath) {
                    if (!opts.username && !opts.password) return targetURL(remotePath);
                    var u = new URL(targetURL(remotePath));
                    u.username = encodeURIComponent(opts.username || "");
                    u.password = encodeURIComponent(opts.password || "");
                    return u.toString();
                }
            };
        }
    };

    var __flowLxState = { inited: null, requestHandler: null };
    globalThis.lx = {
        version: "2.0.0",
        env: "desktop",
        EVENT_NAMES: { inited: "inited", request: "request", updateAlert: "updateAlert" },
        on: function(eventName, cb) {
            if (eventName === "request" && typeof cb === "function") {
                __flowLxState.requestHandler = cb;
            }
        },
        send: function(eventName, data) {
            if (eventName === "inited") {
                __flowLxState.inited = data || {};
            }
        },
        request: function(url, options, callback) {
            var cb = typeof options === "function" ? options : callback;
            var opts = typeof options === "function" ? {} : (options || {});
            var cancelToken = function() {};
            flow.request(Object.assign({}, opts, { url: url })).then(function(res) {
                if (typeof cb === "function") {
                    cb(null, { statusCode: res.status, headers: res.headers, body: res.data, rawBody: res.rawBody }, res.data);
                }
            }, function(err) {
                if (typeof cb === "function") cb(err, null, null);
            });
            return cancelToken;
        },
        utils: {
            buffer: Buffer,
            crypto: flow.crypto
        }
    };
    """#

    private static let moduleLoaderJS = #"""
    function require(name) {
        var pkg;
        switch (String(name)) {
        case "axios": pkg = axios; break;
        case "crypto": pkg = flow.crypto; break;
        case "crypto-js": pkg = CryptoJS; break;
        case "cheerio": pkg = cheerio; break;
        case "he": pkg = __flowHe; break;
        case "dayjs": pkg = dayjs; break;
        case "qs":
        case "querystring": pkg = __flowQs; break;
        case "big-integer": pkg = __flowBigIntWrap; break;
        case "webdav": pkg = __flowWebdav; break;
        default:
            throw new Error("Module not permitted in plugin sandbox: " + name);
        }
        if (pkg && !pkg.default) pkg.default = pkg;
        return pkg;
    }

    function __flowResolvedExports() {
        var ex = module.exports;
        if (ex && typeof ex === "object" && ex.default && typeof ex.default === "object") {
            var d = ex.default;
            if (d.platform || d.search || d.getMediaSource || d.getTopLists || d.discover || d.getRecommendSheetsByTag || d.getLyric) {
                return d;
            }
        }
        return ex || {};
    }

    function __flowLoadModule(source) {
        __flowLxState = { inited: null, requestHandler: null };
        module = { exports: {} };
        exports = module.exports;
        var fn = new Function("module", "exports", "require", "flow", "env", source);
        fn(module, exports, require, flow, env);
    }

    function __flowInvokeLX(action, sourceKey, musicInfo, quality) {
        return new Promise(function(resolve, reject) {
            if (typeof __flowLxState.requestHandler !== "function") {
                return reject(new Error("Missing LX request listener"));
            }
            var payload = {
                source: sourceKey || __flowFirstLXSourceKey(),
                action: action,
                info: { musicInfo: musicInfo || {}, type: quality || "320k" }
            };
            Promise.resolve(__flowLxState.requestHandler(payload, function(err, data) {
                if (err) reject(err);
                else resolve(data);
            })).then(function(maybePromiseVal) {
                if (maybePromiseVal !== undefined) resolve(maybePromiseVal);
            }, reject);
        });
    }

    function __flowFirstLXSourceKey() {
        var sources = (__flowLxState.inited && __flowLxState.inited.sources) || {};
        var keys = Object.keys(sources);
        return keys.length ? keys[0] : "custom";
    }

    function __flowInvoke(fnPath, argsJson, callID) {
        try {
            var ex = __flowResolvedExports();
            var args = JSON.parse(argsJson || "[]");
            if (fnPath === "__lx.musicUrl") {
                __flowInvokeLX("musicUrl", args[2], args[0], args[1]).then(function(res) {
                    var normalized = typeof res === "string" ? { url: res } : res;
                    __flowCompleteInvoke(callID, true, JSON.stringify(normalized === undefined ? null : normalized), "");
                }, function(err) {
                    __flowCompleteInvoke(callID, false, "", String((err && (err.message || err.toString())) || "LX execution failed"));
                });
                return;
            }
            if (fnPath === "__lx.lyric") {
                __flowInvokeLX("lyric", args[1], args[0], null).then(function(res) {
                    __flowCompleteInvoke(callID, true, JSON.stringify(res === undefined ? null : res), "");
                }, function(err) {
                    __flowCompleteInvoke(callID, false, "", String((err && (err.message || err.toString())) || "LX lyric failed"));
                });
                return;
            }
            var parts = String(fnPath).split(".");
            var target = ex;
            var thisArg = ex;
            for (var i = 0; i < parts.length; i++) {
                if (target == null) throw new Error("Missing plugin method: " + fnPath);
                thisArg = target;
                target = target[parts[i]];
            }
            if (typeof target !== "function") throw new Error("Export is not callable: " + fnPath);
            Promise.resolve(target.apply(thisArg, args)).then(function(res) {
                __flowCompleteInvoke(callID, true, JSON.stringify(res === undefined ? null : res), "");
            }, function(err) {
                var detail = (err && err.response && err.response.data) ? (" — " + (typeof err.response.data === "string" ? err.response.data : JSON.stringify(err.response.data)).slice(0, 240)) : "";
                var msg = ((err && (err.message || err.toString())) || "Plugin execution failed") + detail;
                __flowCompleteInvoke(callID, false, "", String(msg));
            });
        } catch (err) {
            var msg = (err && (err.message || err.toString())) || "Plugin execution failed";
            __flowCompleteInvoke(callID, false, "", String(msg));
        }
    }

    function __flowInspectExports() {
        var ex = __flowResolvedExports();
        var name = ex.platform || ex.name || ex.id || "";
        var domains = Array.isArray(ex.allowedDomains) ? ex.allowedDomains.map(String) : [];
        var qualities = Array.isArray(ex.supportedQualities) ? ex.supportedQualities.map(String) : [];
        var hasDeclaredSearchTypes = Array.isArray(ex.supportedSearchType);
        var searchTypes = hasDeclaredSearchTypes ? ex.supportedSearchType.map(String) : [];
        var userVars = Array.isArray(ex.userVariables) ? ex.userVariables.map(function(v) {
            return {
                key: String(v.key || ""),
                name: String(v.name || v.key || ""),
                hint: v.hint ? String(v.hint) : "",
                type: v.type ? String(v.type) : "text"
            };
        }).filter(function(v) { return !!v.key; }) : [];
        var lxSourcesObj = (__flowLxState.inited && __flowLxState.inited.sources) || {};
        var lxKeys = Object.keys(lxSourcesObj);
        var isLX = typeof __flowLxState.requestHandler === "function" && lxKeys.length > 0;
        var hasQueryResolver = (typeof ex.canHandleQuery === "function" && typeof ex.resolveQuery === "function")
            || typeof ex.importMusicSheet === "function"
            || typeof ex.importMusicItem === "function";
        return {
            id: ex.id ? String(ex.id) : "",
            name: String(name),
            version: ex.version ? String(ex.version) : "",
            author: ex.author ? String(ex.author) : "",
            description: ex.description ? String(ex.description) : "",
            allowedDomains: domains,
            supportedQualities: qualities,
            supportedSearchTypes: searchTypes,
            userVariables: userVars,
            lxSources: lxKeys,
            isLX: isLX,
            hasSearch: typeof ex.search === "function" && (!hasDeclaredSearchTypes || searchTypes.length > 0),
            hasGetMediaSource: typeof ex.getMediaSource === "function" || isLX,
            hasGetLyric: typeof ex.getLyric === "function",
            hasGetMusicInfo: typeof ex.getMusicInfo === "function",
            hasDiscover: typeof ex.discover === "function",
            hasTopLists: typeof ex.getTopLists === "function" && typeof ex.getTopListDetail === "function",
            hasRecommendSheets: typeof ex.getRecommendSheetsByTag === "function",
            hasResolveQuery: hasQueryResolver,
            hasGetRelated: typeof ex.getRelated === "function",
            hasAuth: !!(ex.auth && typeof ex.auth === "object"),
            hasAuthQR: !!(ex.auth && typeof ex.auth.beginQRLogin === "function" && typeof ex.auth.pollQRLogin === "function")
        };
    }
    """#
}
