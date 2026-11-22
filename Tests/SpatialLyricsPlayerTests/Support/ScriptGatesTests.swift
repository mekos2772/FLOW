import XCTest
@testable import SpatialLyricsPlayer

/// 把仓库里的机械闸门纳入测试套件。
///
/// 之前 `dead-code-scan.py` 只是"我记得才会跑"——不跑就等于没有。
/// 纳入套件之后，每次 `xcodebuild test` 都会检查一遍：
/// 新长出来的零引用类型、架构分层越界，都会当场变红。
final class ScriptGatesTests: XCTestCase {

    private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    private var repoRoot: URL { RepositoryRoot.locate() }

    func testDeadCodeScanIsClean() throws {
        let script = repoRoot.appendingPathComponent("Scripts/dead-code-scan.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "扫描脚本不见了")
        let (status, output) = try run("/usr/bin/env", ["python3", script.path])
        XCTAssertEqual(status, 0, "存在疑似死代码或有零引用的类型：\n\(output)")
    }

    func testArchitectureLintIsClean() throws {
        let script = repoRoot.appendingPathComponent("Scripts/architecture-lint.sh")
        let (status, output) = try run("/bin/bash", [script.path])
        XCTAssertEqual(status, 0, "架构分层越界：\n\(output)")
    }
}
