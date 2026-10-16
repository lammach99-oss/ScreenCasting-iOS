import XCTest
import Network
@testable import WanQuicInterop

final class EvidenceRecorderTests: XCTestCase {
    func testLaneFailureEvidenceRequiresRoleIdentityAndNativeError() throws {
        EventLog.beginRun(generation: 70)
        let owner = UUID()
        let lane = UUID()
        EventLog.write("lane_failed", generation: 70, owner: owner, details:
            LaneEvidence.fields(role: "datagram", laneID: lane, state: "failed", error: .posix(.ECONNREFUSED)))
        let export = try EventLog.export()
        let lines = try String(contentsOf: export, encoding: .utf8).split(separator: "\n")
        let events = try lines.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let detail = try XCTUnwrap(events.first { $0["event"] as? String == "lane_failed" })
        XCTAssertNotNil(detail["laneRole"] as? String)
        XCTAssertNotNil(detail["laneID"] as? String)
        XCTAssertNotNil(detail["nativeErrorDomain"] as? String)
        XCTAssertNotNil(detail["nativeErrorCode"] as? Int)
        XCTAssertEqual(detail["laneRole"] as? String, "datagram")
        XCTAssertEqual(detail["laneID"] as? String, lane.uuidString)
        XCTAssertEqual(detail["nativeErrorDomain"] as? String, "POSIX")
        XCTAssertEqual(detail["nativeErrorCode"] as? Int, Int(POSIXErrorCode.ECONNREFUSED.rawValue))
    }
    func testNativeTLSAndDNSCodesAndDiagnosticBound() throws {
        XCTAssertEqual(LaneEvidence.fields(role: "control", laneID: UUID(), state: "failed", error: .tls(-9807))["nativeErrorCode"] as? Int, -9807)
        XCTAssertEqual(LaneEvidence.fields(role: "datagram", laneID: UUID(), state: "failed", error: .dns(-65537))["nativeErrorDomain"] as? String, "DNS")
        EventLog.beginRun(generation: 72)
        let owner = QuicConnectionOwner(generation: 72)
        for _ in 0..<100 { owner.trace("lane_state_detail", details: [:]) }
        owner.retire(reason: "lane_failed", initiator: "test")
        let export = try EventLog.export()
        let lines = try String(contentsOf: export, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 34)
    }
    func testRetirementEvidenceIdentifiesFirstOwnerAndDoesNotDuplicate() throws {
        EventLog.beginRun(generation: 71)
        let owner = QuicConnectionOwner(generation: 71)
        owner.retire()
        owner.retire()
        let export = try EventLog.export()
        let lines = try String(contentsOf: export, encoding: .utf8).split(separator: "\n")
        let events = try lines.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let retirements = events.filter { $0["event"] as? String == "owner_retired_detail" }
        XCTAssertEqual(retirements.count, 1)
        let first = try XCTUnwrap(retirements.first)
        XCTAssertEqual(first["owner"] as? String, owner.id.uuidString)
        XCTAssertEqual(first["generation"] as? Int, 71)
        XCTAssertNotNil(first["retirementReason"] as? String)
        XCTAssertNotNil(first["initiator"] as? String)
        XCTAssertFalse(owner.accepts(71))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func append(_ recorder: EvidenceRecorder, event: String = "control_reply", sequence: Int = 0) throws {
        let json = try JSONSerialization.data(withJSONObject: ["event": event, "sequence": sequence])
        _ = recorder.append(json: json, event: event, generation: 7, value: sequence)
    }
    func testPersistsExactJSONLinesAndUpdatesCounters() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 4096)
        let url = try recorder.beginRun(generation: 7)
        try append(recorder)
        try append(recorder, event: "host_datagram_received")
        try append(recorder, event: "send_rejected")
        try append(recorder, event: "apple_capacity", sequence: 1200)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        let s = recorder.snapshot()
        XCTAssertEqual(s.generation, 7); XCTAssertEqual(s.controlReplies, 1)
        XCTAssertEqual(s.hostDatagrams, 1); XCTAssertEqual(s.sendErrors, 1)
        XCTAssertEqual(s.appleCapacity, 1200); XCTAssertNil(s.storageError)
    }
    func testHardBoundAndClear() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 160)
        let url = try recorder.beginRun(generation: 7)
        for i in 0..<20 { try append(recorder, sequence: i) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 160)
        XCTAssertTrue(recorder.snapshot().truncated)
        try recorder.clear()
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertFalse(recorder.snapshot().truncated)
        XCTAssertEqual(recorder.snapshot().controlReplies, 0)
        try append(recorder)
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
    }
    func testNewRunDoesNotOverwritePreviousAndRetentionIsBounded() throws {
        let root = try directory()
        let recorder = EvidenceRecorder(directory: root, maximumBytes: 4096, retainedRuns: 2)
        let first = try recorder.beginRun(generation: 7); try append(recorder)
        let second = try recorder.beginRun(generation: 8)
        XCTAssertNotEqual(first, second); XCTAssertFalse(try Data(contentsOf: first).isEmpty)
        XCTAssertEqual(recorder.snapshot().generation, 8)
        _ = try recorder.beginRun(generation: 9)
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(logs.count, 2)
    }
    func testExportIsImmutableAfterMoreEvents() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 4096)
        _ = try recorder.beginRun(generation: 7); try append(recorder)
        let export = try recorder.export(to: try directory())
        let original = try Data(contentsOf: export)
        try append(recorder, sequence: 1)
        XCTAssertEqual(try Data(contentsOf: export), original)
    }
    func testConcurrentWritesRemainWholeJSONLines() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 65536)
        let url = try recorder.beginRun(generation: 7)
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let json = try! JSONSerialization.data(withJSONObject: ["event": "control_reply", "sequence": i])
            _ = recorder.append(json: json, event: "control_reply", generation: 7, value: i)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let sequences = try lines.map { line -> Int in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return object["sequence"] as! Int
        }
        XCTAssertEqual(Set(sequences).count, 100)
        XCTAssertEqual(recorder.snapshot().controlReplies, 100)
    }
}
