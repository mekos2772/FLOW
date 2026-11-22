import AVFoundation
import Foundation
import Network

/// AVFoundation 通过标准 HTTP 读取 HLS；仅在回环地址接收请求，外部请求统一交给受控客户端。
enum HLSResourceLoaderBridge {
    static func makeAsset(for request: HLSStreamRequest) async throws -> StreamingPreparedAsset {
        let client = HLSResourceClient(request: request)
        let server = try HLSLoopbackServer { path, range, head in
            try await client.reply(path: path, range: range, head: head)
        }
        do {
            let baseURL = try await server.start()
            let url = try await client.startURL(baseURL: baseURL)
            try Task.checkCancellation()
            return StreamingPreparedAsset(asset: AVURLAsset(url: url), invalidate: {
                server.invalidate()
                Task { await client.invalidate() }
            }, keepAlive: server)
        } catch {
            server.invalidate()
            await client.invalidate()
            throw error
        }
    }
}

/// 每个会话独立的短生命周期服务器；不允许绝对 URL、任意 Host、非 GET/HEAD 或无认证资源路径。
final class HLSLoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (String, String?, Bool) async throws -> HLSResourceClient.Reply
    private let listener: NWListener
    private let queue = DispatchQueue(label: "flow.audio.hls-loopback")
    private let handler: Handler
    private let lock = NSLock()
    private var invalidated = false
    private var startWaiter: CheckedContinuation<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var timeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock { () -> Bool in
                    if invalidated { return true }
                    startWaiter = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                            self.finishStart(.failure(URLError(.cannotConnectToHost)))
                            return
                        }
                        self.finishStart(.success(url))
                    case .failed(let error), .waiting(let error): self.finishStart(.failure(error))
                    case .cancelled: self.finishStart(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
                listener.start(queue: queue)
            }
        } onCancel: { self.invalidate() }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { startWaiter = nil }
            return startWaiter
        }
        waiter?.resume(with: result)
    }

    func invalidate() {
        let pending = lock.withLock { () -> ([NWConnection], [Task<Void, Never>]) in
            invalidated = true
            let result = (Array(connections.values), Array(tasks.values) + Array(timeouts.values))
            connections.removeAll()
            tasks.removeAll()
            timeouts.removeAll()
            return result
        }
        finishStart(.failure(CancellationError()))
        listener.cancel()
        for task in pending.1 { task.cancel() }
        for connection in pending.0 { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = lock.withLock { () -> Bool in
            guard !invalidated, connections.count < 12 else { return false }
            connections[id] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.start(queue: queue)
        let timeout = Task { [weak self, weak connection] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            if let connection { self?.close(connection) }
        }
        lock.withLock { timeouts[id] = timeout }
        receive(connection, buffer: Data())
    }

    private func close(_ connection: NWConnection) {
        let pending = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            let id = ObjectIdentifier(connection)
            connections[id] = nil
            return (tasks.removeValue(forKey: id), timeouts.removeValue(forKey: id))
        }
        pending.0?.cancel()
        pending.1?.cancel()
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192 else { self.close(connection); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete, error == nil { self.receive(connection, buffer: buffer) }
                else { self.close(connection) }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            let hostLines = lines.filter { $0.lowercased().hasPrefix("host:") }
            guard first.count == 3, first[0] == "GET" || first[0] == "HEAD",
                  first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("?"),
                  hostLines.count == 1, let port = self.listener.port,
                  hostLines[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port.rawValue)" else {
                self.send(status: 400, headers: [:], body: Data(), to: connection)
                return
            }
            let path = String(first[1])
            let range = lines.first { $0.lowercased().hasPrefix("range:") }?.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let head = first[0] == "HEAD"
            // 任务先登记再运行，避免 invalidate 与刚接收的请求交错后继续联网。
            self.lock.withLock {
                guard !self.invalidated else { connection.cancel(); return }
                self.tasks[ObjectIdentifier(connection)] = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    do {
                        let reply = try await self.handler(path, range, head)
                        guard !Task.isCancelled else { return }
                        self.send(status: reply.status, headers: reply.headers, body: reply.body, to: connection)
                    } catch {
                        self.send(status: 502, headers: [:], body: Data(), to: connection)
                    }
                }
            }
        }
    }

    private func send(status: Int, headers: [String: String], body: Data, to connection: NWConnection) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(body.count) }
        headers["Connection"] = "close"
        var response = Data("HTTP/1.1 \(status) Response\r\n".utf8)
        for (name, value) in headers where !name.contains("\r") && !name.contains("\n") && !value.contains("\r") && !value.contains("\n") {
            response.append(Data("\(name): \(value)\r\n".utf8))
        }
        response.append(Data("\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }

    deinit { listener.cancel() }
}
