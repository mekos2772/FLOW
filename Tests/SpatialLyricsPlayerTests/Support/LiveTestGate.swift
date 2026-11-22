import Foundation
import XCTest

enum LiveTestGate {
    static func skipUnlessLive(_ reason: String) throws {
        let enabled = ProcessInfo.processInfo.environment["SLP_LIVE_TEST"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/bili-live-test")
        try XCTSkipUnless(enabled, reason)
    }
}
