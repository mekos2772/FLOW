import Foundation
import XCTest
@testable import SpatialLyricsPlayer

final class ProgressiveAudioStreamIOTests: XCTestCase {
    func testInitialSeekFailureCleansUpAndFailsWaiters() async throws {
        try await assertFailure(.seek, onCall: 1)
    }

    func testInitialWriteFailureCleansUpAndFailsWaiters() async throws {
        try await assertFailure(.write, onCall: 1)
    }

    func testChunkSeekFailureUnlocksAndFailsWaitersWithoutRetryingHTTP() async throws {
        try await assertFailure(.seek, onCall: 2)
    }

    func testChunkWriteFailureUnlocksAndFailsWaitersWithoutRetryingHTTP() async throws {
        try await assertFailure(.write, onCall: 2)
    }

    func testSynchronizeFailureUnlocksAndFailsWaiters() async throws {
        try await assertFailure(.synchronize, onCall: 1)
    }

    func testCloseFailureUnlocksAndFailsWaiters() async throws {
        try await assertFailure(.close, onCall: 1)
    }

    func testMoveFailureUnlocksAndFailsRegisteredWaiters() async throws {
        try await assertFailure(.move, onCall: 1)
    }

    func testSuccessfulFinalizationResumesWaitersAndAllowsListenerReentry() async throws {
        let fixture = try IOStreamFixture()
        defer { fixture.dispose() }
        let stream = fixture.makeStream()
        guard case .streaming = try await stream.start() else {
            return XCTFail("Expected a partial stream")
        }

        let completed = expectation(description: "Completion callback can reenter the stream")
        let listener = stream.addListener {
            XCTAssertTrue(stream.isCompleted)
            XCTAssertNil(stream.currentTerminalError)
            XCTAssertEqual(stream.readAvailable(offset: 0, maxLength: fixture.payload.count), fixture.payload)
            completed.fulfill()
        }
        let waiters = await startWaiters(stream, expectedURL: fixture.destinationURL)
        fixture.releaseDownloads()

        let result = await XCTWaiter.fulfillment(of: [completed] + waiters, timeout: 3)
        guard result == .completed else {
            return XCTFail("Finalization or a reentrant callback blocked: \(result)")
        }
        stream.removeListener(listener)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), fixture.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stream.partURL.path))
        let lateURL = await stream.waitForLocalFile()
        XCTAssertEqual(lateURL, fixture.destinationURL)
    }

    private func assertFailure(_ operation: IOFailure, onCall: Int,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try IOStreamFixture()
        defer { fixture.dispose() }
        let probe = IOFailureProbe(operation: operation, onCall: onCall)
        let completed = expectation(description: "Failure never reports successful completion")
        completed.isInverted = true
        let stream = fixture.makeStream(fileIO: probe.fileIO, onComplete: { _ in completed.fulfill() })
        let failed = expectation(description: "Failure listener can acquire the stream lock")
        let listener = stream.addListener {
            XCTAssertEqual(stream.currentTerminalError as? IOFailure, operation, file: file, line: line)
            XCTAssertFalse(stream.isCompleted, file: file, line: line)
            XCTAssertTrue(stream.readAvailable(offset: 0, maxLength: 1).isEmpty, file: file, line: line)
            failed.fulfill()
        }
        let waiters = await startWaiters(stream, expectedURL: nil)
        let initialFailure = onCall == 1 && (operation == .seek || operation == .write)
        do {
            let outcome = try await stream.start()
            XCTAssertFalse(initialFailure, "Initial I/O failure must be thrown", file: file, line: line)
            guard case .streaming = outcome else {
                return XCTFail("Expected a partial stream", file: file, line: line)
            }
        } catch {
            XCTAssertTrue(initialFailure, "Unexpected start failure: \(error)", file: file, line: line)
            XCTAssertEqual(error as? IOFailure, operation, file: file, line: line)
        }
        fixture.releaseDownloads()

        let result = await XCTWaiter.fulfillment(of: [failed] + waiters, timeout: 3)
        guard result == .completed else {
            return XCTFail("I/O failure stranded a waiter or left the stream locked: \(result)", file: file, line: line)
        }
        stream.removeListener(listener)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stream.partURL.path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path), file: file, line: line)
        if let handle = probe.handle {
            XCTAssertThrowsError(try handle.offset(), "Failure must close the partial file", file: file, line: line)
        }
        XCTAssertEqual(fixture.requestCount, initialFailure ? 1 : 2,
                       "Disk failures must not retry the HTTP request", file: file, line: line)
        let lateURL = await stream.waitForLocalFile()
        XCTAssertNil(lateURL, file: file, line: line)
        let cancellation = expectation(description: "Cancellation remains usable after I/O failure")
        DispatchQueue.global().async {
            stream.cancelAll()
            cancellation.fulfill()
        }
        let cancellationResult = await XCTWaiter.fulfillment(of: [cancellation], timeout: 1)
        XCTAssertEqual(cancellationResult, .completed, file: file, line: line)
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 0.02)
        XCTAssertEqual(completionResult, .completed, file: file, line: line)
    }

    private func startWaiters(_ stream: ProgressiveAudioStream, expectedURL: URL?) async -> [XCTestExpectation] {
        let started = expectation(description: "Completion waiters started before the next response")
        started.expectedFulfillmentCount = 2
        let finished = (0..<2).map { expectation(description: "Completion waiter \($0) resumed") }
        for done in finished {
            Task {
                started.fulfill()
                let result = await stream.waitForLocalFile()
                XCTAssertEqual(result, expectedURL)
                done.fulfill()
            }
        }
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(result, .completed)
        // The protocol holds all remaining bytes while these tasks suspend in waitForLocalFile().
        try? await Task.sleep(for: .milliseconds(20))
        return finished
    }
}

private enum IOFailure: Error, Hashable {
    case seek, write, synchronize, close, move
}

private final class IOFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: IOFailure
    private let onCall: Int
    private var calls: [IOFailure: Int] = [:]
    private var lastHandle: FileHandle?

    init(operation: IOFailure, onCall: Int) {
        self.operation = operation
        self.onCall = onCall
    }

    var handle: FileHandle? { lock.withLock { lastHandle } }

    private func check(_ operation: IOFailure, handle: FileHandle? = nil) throws {
        try lock.withLock {
            if let handle { lastHandle = handle }
            calls[operation, default: 0] += 1
            if operation == self.operation, calls[operation, default: 0] >= onCall {
                throw operation
            }
        }
    }

    var fileIO: ProgressiveAudioStream.FileIO {
        ProgressiveAudioStream.FileIO(
            seek: { handle, offset in
                try self.check(.seek, handle: handle)
                try handle.seek(toOffset: offset)
            },
            write: { handle, data in
                try self.check(.write, handle: handle)
                try handle.write(contentsOf: data)
            },
            synchronize: { handle in
                try self.check(.synchronize, handle: handle)
                try handle.synchronize()
            },
            close: { handle in
                try self.check(.close, handle: handle)
                try handle.close()
            },
            move: { source, destination in
                try self.check(.move)
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
    }
}

private final class IOStreamFixture: @unchecked Sendable {
    let payload = Data((0..<2048).map { UInt8($0 & 0xFF) })
    let directory: URL
    let remoteURL: URL
    let destinationURL: URL
    let session: URLSession
    private let lock = NSLock()
    private var requests = 0
    private var released = false
    private var pending: [@Sendable () -> Void] = []

    init() throws {
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("slp-stream-io-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destinationURL = directory.appendingPathComponent("audio.m4a")
        remoteURL = URL(string: "https://progressive-io.test/\(id)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IOStreamURLProtocol.self]
        session = URLSession(configuration: configuration)
        IOStreamURLProtocol.register(self)
    }

    var requestCount: Int { lock.withLock { requests } }

    func makeStream(fileIO: ProgressiveAudioStream.FileIO = .init(),
                    onComplete: (@Sendable (URL) -> Void)? = nil) -> ProgressiveAudioStream {
        ProgressiveAudioStream(remoteURL: remoteURL, destinationURL: destinationURL,
                               session: session, headers: [:], initialChunkBytes: 1024,
                               chunkBytes: 1024, minimumUsefulBytes: 0,
                               fileIO: fileIO, onComplete: onComplete)
    }

    func respond(to request: IOStreamURLProtocol) {
        let header = request.request.value(forHTTPHeaderField: "Range") ?? "bytes=0-1023"
        let start = Int(header.dropFirst("bytes=".count).split(separator: "-")[0]) ?? 0
        let end = min(start + 1024, payload.count)
        let data = payload.subdata(in: start..<end)
        let response = HTTPURLResponse(url: remoteURL, statusCode: 206, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes \(start)-\(end - 1)/\(payload.count)"])!
        let deliver: @Sendable () -> Void = { [weak request] in
            guard let request else { return }
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
        let deliverNow = lock.withLock {
            requests += 1
            if start == 0 || released { return true }
            pending.append(deliver)
            return false
        }
        if deliverNow { deliver() }
    }

    func releaseDownloads() {
        let responses = lock.withLock {
            released = true
            let responses = pending
            pending.removeAll()
            return responses
        }
        for response in responses { response() }
    }

    func dispose() {
        session.invalidateAndCancel()
        IOStreamURLProtocol.unregister(self)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class IOStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: IOStreamFixture] = [:]

    static func register(_ fixture: IOStreamFixture) {
        lock.withLock { fixtures[fixture.remoteURL] = fixture }
    }

    static func unregister(_ fixture: IOStreamFixture) {
        _ = lock.withLock { fixtures.removeValue(forKey: fixture.remoteURL) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.respond(to: self)
    }

    override func stopLoading() {}
}
