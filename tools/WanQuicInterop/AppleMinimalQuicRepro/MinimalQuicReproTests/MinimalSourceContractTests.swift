import XCTest

final class MinimalSourceContractTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("MinimalQuicRepro/" + name + ".swift"), encoding: .utf8)
    }
    func testOneGroupAndOneExtractSite() throws {
        let source = try source("MinimalQuicSession")
        XCTAssertEqual(source.components(separatedBy: "NWConnectionGroup(with:").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "group.extract(connectionTo: nil, using: options)").count - 1, 1)
        XCTAssertTrue(source.contains("gate.requestControl()"))
    }
    func testNoDatagramOrTimingIntervention() throws {
        let source = try source("MinimalQuicSession")
        for forbidden in [".isDatagram = true", "receiveMessage", "Thread.sleep", "asyncAfter", "Timer", "Task.sleep", "NWConnection(from:"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("options.direction = .bidirectional"))
        XCTAssertTrue(source.contains("options.isDatagram = false"))
    }
    func testDedicatedAnchorAndExactSSLPolicy() throws {
        let source = try source("MinimalQuicSession")
        for required in ["SecPolicyCreateSSL(true, host as CFString)", "SecTrustSetAnchorCertificatesOnly(trust, true)", "SecTrustEvaluateWithError", "SecTrustSetAnchorCertificates"] {
            XCTAssertTrue(source.contains(required), required)
        }
    }
    func testNoProductionDependenciesOrPollingTimer() throws {
        for name in ["App", "MinimalQuicSession", "MinimalEvidence", "MinimalControlProtocol"] {
            let source = try source(name)
            for forbidden in ["import Metal", "import VideoToolbox", "import AVFoundation", "Timer.publish", "import UIKit"] {
                XCTAssertFalse(source.contains(forbidden), forbidden)
            }
        }
    }
}
