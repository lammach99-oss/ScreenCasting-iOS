import XCTest
@testable import MinimalQuicRepro

final class MinimalProtocolTests: XCTestCase {
    func testExactRequestBytesAndALPN() {
        XCTAssertEqual(MinimalControlProtocol.alpn, "sc-wan-interop-v1")
        XCTAssertEqual([UInt8](MinimalControlProtocol.request(generation: 1)),
                       [0,0,0,17,1,1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0x5a])
    }
    func testReplyAtEveryFragmentBoundary() throws {
        var reply = MinimalControlProtocol.request(generation: 1)
        reply[5] = 2
        for split in 0..<reply.count {
            var decoder = MinimalControlProtocol.ReplyDecoder(generation: 1)
            XCTAssertFalse(try decoder.feed(Data(reply.prefix(split))))
            XCTAssertTrue(try decoder.feed(Data(reply.dropFirst(split))))
            try decoder.finish()
        }
    }
    func testRejectWrongGenerationAndOpcode() {
        var decoder = MinimalControlProtocol.ReplyDecoder(generation: 2)
        var reply = MinimalControlProtocol.request(generation: 1)
        reply[5] = 2
        XCTAssertThrowsError(try decoder.feed(reply))
        decoder = MinimalControlProtocol.ReplyDecoder(generation: 1)
        XCTAssertThrowsError(try decoder.feed(MinimalControlProtocol.request(generation: 1)))
    }
    func testRejectTruncatedAndDuplicateReply() throws {
        var decoder = MinimalControlProtocol.ReplyDecoder(generation: 1)
        XCTAssertThrowsError(try decoder.finish())
        var reply = MinimalControlProtocol.request(generation: 1)
        reply[5] = 2
        XCTAssertTrue(try decoder.feed(reply))
        XCTAssertThrowsError(try decoder.feed(reply))
    }
    func testRunIdentityNotGenerationRejectsStaleCallback() {
        let old = MinimalIdentity(generation: 1)
        let new = MinimalIdentity(generation: 1)
        var gate = MinimalRunGate(identity: old)
        XCTAssertTrue(gate.accepts(old))
        XCTAssertFalse(gate.accepts(new))
        gate.retire()
        XCTAssertFalse(gate.accepts(old))
        XCTAssertFalse(MinimalRunGate(identity: new).accepts(old))
    }
    func testRepeatedReadyCreatesOnlyOneControlRequest() {
        var gate = MinimalRunGate(identity: MinimalIdentity(generation: 1))
        XCTAssertTrue(gate.requestControl())
        XCTAssertFalse(gate.requestControl())
        gate.retire()
        XCTAssertFalse(gate.requestControl())
    }
    func testCompleteSummaryAndIdentity() throws {
        let identity = MinimalIdentity(generation: 1)
        let evidence = MinimalEvidence(identity: identity)
        XCTAssertTrue(evidence.record("run_started", identity: identity))
        XCTAssertFalse(evidence.record("stale", identity: MinimalIdentity(generation: 1)))
        XCTAssertEqual(evidence.records.count, 1)
        XCTAssertEqual(evidence.summary["captureComplete"] as? Bool, true)
        XCTAssertEqual(evidence.summary["recordCount"] as? Int, 2)
        XCTAssertNoThrow(try MinimalEvidence.encode(evidence.summary))
    }
    func testOptionalFloodReservesCriticalTerminalAndFailsClosed() {
        let identity = MinimalIdentity(generation: 1)
        let evidence = MinimalEvidence(identity: identity, limit: 6, optionalLimit: 2)
        for _ in 0..<10 { evidence.record("path", identity: identity, critical: false) }
        XCTAssertTrue(evidence.record("control_failed", identity: identity))
        XCTAssertTrue(evidence.record("run_retired", identity: identity))
        XCTAssertEqual(evidence.droppedDiagnostics, 8)
        XCTAssertFalse(evidence.captureComplete)
        XCTAssertEqual(evidence.summary["truncated"] as? Bool, true)
        XCTAssertTrue(evidence.records.contains { $0["event"] as? String == "control_failed" })
    }
    func testCriticalOverflowIsExplicitAndSummaryRemainsAvailable() {
        let identity = MinimalIdentity(generation: 1)
        let evidence = MinimalEvidence(identity: identity, limit: 4, optionalLimit: 1)
        for _ in 0..<8 { evidence.record("critical", identity: identity) }
        XCTAssertEqual(evidence.records.count, 3)
        XCTAssertEqual(evidence.droppedDiagnostics, 5)
        XCTAssertFalse(evidence.captureComplete)
        XCTAssertEqual(evidence.summary["event"] as? String, "capture_summary_detail")
    }
    func testStorageFailureFailsClosed() {
        let evidence = MinimalEvidence(identity: MinimalIdentity(generation: 1),
            fileURL: URL(fileURLWithPath: "/dev/null/impossible.jsonl"))
        XCTAssertNotNil(evidence.storageError)
        XCTAssertFalse(evidence.captureComplete)
    }
}
