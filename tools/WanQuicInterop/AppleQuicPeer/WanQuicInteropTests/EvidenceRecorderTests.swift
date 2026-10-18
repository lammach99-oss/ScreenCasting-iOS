import XCTest
import Network
@testable import WanQuicInterop

final class EvidenceRecorderTests: XCTestCase {
    func testRetiredRunCannotContaminateReplacementWithSameGeneration() throws {
        let oldIdentity = EventLog.beginRun(generation: 1)
        let retiredOwner = QuicConnectionOwner(generation: 1, evidenceIdentity: oldIdentity)
        retiredOwner.trace("session_owner_detail", details: [:])
        retiredOwner.retire()
        EventLog.beginRun(generation: 1)
        let before = EventLog.snapshot()
        let bytes = try Data(contentsOf: XCTUnwrap(before.fileURL))
        EventLog.write("control_reply", identity: oldIdentity)
        retiredOwner.trace("lane_failed", details: [:])
        XCTAssertEqual(EventLog.snapshot().controlReplies, 0)
        XCTAssertEqual(EventLog.snapshot().lastEvent, before.lastEvent)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(before.fileURL)), bytes)
    }
    func testRecorderRejectsEveryMismatchedIdentityBeforeMutation() throws {
        let recorder = EvidenceRecorder(directory: try directory())
        let identity = EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 1)
        let url = try recorder.beginRun(generation: 1, identity: identity)
        for invalid in [
            EvidenceIdentity(runID: UUID(), ownerID: identity.ownerID, generation: 1),
            EvidenceIdentity(runID: identity.runID, ownerID: UUID(), generation: 1),
            EvidenceIdentity(runID: identity.runID, ownerID: identity.ownerID, generation: 2)
        ] {
            XCTAssertFalse(recorder.append(json: Data("{}".utf8), event: "control_reply", identity: invalid, value: 0))
        }
        XCTAssertEqual(recorder.snapshot().controlReplies, 0)
        XCTAssertTrue(try Data(contentsOf: url).isEmpty)
        XCTAssertTrue(recorder.append(json: Data("{}".utf8), event: "control_reply", identity: identity, value: 0))
        XCTAssertEqual(recorder.snapshot().controlReplies, 1)
    }
    func testExperimentMatrixPreservesOneVariableAndOnceOnlyStartup() {
        var baseline = ControlLaneExperiment(mode: .baselineConcurrent)
        XCTAssertEqual(baseline.groupReady(), [.concurrentLanes])
        XCTAssertEqual(baseline.groupReady(), [])
        XCTAssertEqual(baseline.controlState(.ready), [])
        var only = ControlLaneExperiment(mode: .controlOnly)
        XCTAssertEqual(only.groupReady(), [.controlOnly])
        XCTAssertEqual(only.controlState(.ready), [])
        var serialized = ControlLaneExperiment(mode: .serializedControlThenDatagram)
        XCTAssertEqual(serialized.controlState(.ready), []) // no group authority yet
        XCTAssertEqual(serialized.groupReady(), [.controlOnly])
        for state in [NWConnection.State.setup, .preparing, .waiting(.posix(.ENETDOWN)), .failed(.posix(.ENETDOWN)), .cancelled] {
            XCTAssertEqual(serialized.controlState(state), [])
        }
        XCTAssertEqual(serialized.controlState(.ready), [.datagramOnly])
        XCTAssertEqual(serialized.controlState(.ready), [])
        var deferred = ControlLaneExperiment(mode: .deferredControlOneQueueTurn)
        XCTAssertEqual(deferred.groupReady(), [.deferControl])
        XCTAssertEqual(deferred.groupReady(), [])
        XCTAssertEqual(deferred.controlState(.ready), [])
    }
    func testAllExperimentConfigurationsAreExplicitAndControlConstructionIsUnchanged() {
        XCTAssertEqual(ControlLaneExperimentMode.allCases.count, 4) // no speculative A4
        for mode in ControlLaneExperimentMode.allCases {
            let fields = ControlLaneExperiment(mode: mode).fields
            XCTAssertEqual(fields["experimentMode"] as? String, mode.rawValue)
            XCTAssertEqual(fields["controlConstructionAPI"] as? String, "extract(connectionTo:using:)")
            XCTAssertEqual(fields["controlDirection"] as? String, "bidirectional")
            XCTAssertEqual(fields["datagramEnabled"] as? Bool,
                mode == .baselineConcurrent || mode == .serializedControlThenDatagram)
            XCTAssertEqual(fields["controlStartPolicy"] as? String,
                mode == .deferredControlOneQueueTurn ? "one_serial_queue_turn" : "synchronous_group_ready")
        }
        XCTAssertEqual(ControlLaneExperiment(mode: .serializedControlThenDatagram).fields["datagramStartPolicy"] as? String, "after_control_ready")
        XCTAssertEqual(ControlLaneExperiment(mode: .controlOnly).fields["datagramStartPolicy"] as? String, "suppressed")
    }
    func testDefaultExperimentEvidenceIdentifiesUnchangedConcurrentBaseline() throws {
        EventLog.beginRun(generation: 73)
        let export = try EventLog.export()
        let events = try String(contentsOf: export, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let config = try XCTUnwrap(events.first { $0["event"] as? String == "experiment_config_detail" })
        XCTAssertEqual(config["experimentMode"] as? String, "A0_baseline")
        XCTAssertEqual(config["datagramEnabled"] as? Bool, true)
        XCTAssertEqual(config["controlStartPolicy"] as? String, "synchronous_group_ready")
        XCTAssertEqual(config["datagramStartPolicy"] as? String, "concurrent_baseline")
        XCTAssertEqual(config["controlConstructionAPI"] as? String, "extract(connectionTo:using:)")
        XCTAssertEqual(config["groupReadyOrdinal"] as? Int, 0)
        XCTAssertEqual(config["controlReadyOrdinal"] as? Int, 0)
    }
    func testCausalLaneEvidenceIncludesExtractContract() {
        let options = NWProtocolQUIC.Options(alpn: [TestProtocol.alpn])
        options.direction = .bidirectional
        let fields = LaneEvidence.extractFields(role: "control", laneID: UUID(), options: options)
        XCTAssertEqual(fields["extractEndpoint"] as? String, "nil")
        XCTAssertEqual(fields["direction"] as? String, "bidirectional")
        XCTAssertEqual(fields["isDatagram"] as? Bool, false)
        XCTAssertNotNil(fields["optionsALPN"] as? String)
    }
    func testLaneFailureEvidenceRequiresRoleIdentityAndNativeError() throws {
        let identity = EventLog.beginRun(generation: 70)
        let lane = UUID()
        EventLog.write("lane_failed", identity: identity, details:
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
        let identity = EventLog.beginRun(generation: 72)
        let owner = QuicConnectionOwner(generation: 72, evidenceIdentity: identity)
        for _ in 0..<100 { owner.trace("lane_state_detail", details: [:]) }
        owner.retire(reason: "lane_failed", initiator: "test")
        let export = try EventLog.export()
        let lines = try String(contentsOf: export, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 35) // run + experiment config + bounded trace + retirement
    }
    func testRetirementEvidenceIdentifiesFirstOwnerAndDoesNotDuplicate() throws {
        let identity = EventLog.beginRun(generation: 71)
        let owner = QuicConnectionOwner(generation: 71, evidenceIdentity: identity)
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
    private let recorderIdentity = EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 7)
    private func append(_ recorder: EvidenceRecorder, event: String = "control_reply", sequence: Int = 0) throws {
        let json = try JSONSerialization.data(withJSONObject: ["event": event, "sequence": sequence])
        _ = recorder.append(json: json, event: event, identity: recorderIdentity, value: sequence)
    }
    func testPersistsExactJSONLinesAndUpdatesCounters() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 4096)
        let url = try recorder.beginRun(generation: 7, identity: recorderIdentity)
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
        let url = try recorder.beginRun(generation: 7, identity: recorderIdentity)
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
        let first = try recorder.beginRun(generation: 7, identity: recorderIdentity); try append(recorder)
        let second = try recorder.beginRun(generation: 8, identity: EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 8))
        XCTAssertNotEqual(first, second); XCTAssertFalse(try Data(contentsOf: first).isEmpty)
        XCTAssertEqual(recorder.snapshot().generation, 8)
        _ = try recorder.beginRun(generation: 9, identity: EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 9))
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(logs.count, 2)
    }
    func testExportIsImmutableAfterMoreEvents() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 4096)
        _ = try recorder.beginRun(generation: 7, identity: recorderIdentity); try append(recorder)
        let export = try recorder.export(to: try directory())
        let original = try Data(contentsOf: export)
        try append(recorder, sequence: 1)
        XCTAssertEqual(try Data(contentsOf: export), original)
    }
    func testConcurrentWritesRemainWholeJSONLines() throws {
        let recorder = EvidenceRecorder(directory: try directory(), maximumBytes: 65536)
        let url = try recorder.beginRun(generation: 7, identity: recorderIdentity)
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let json = try! JSONSerialization.data(withJSONObject: ["event": "control_reply", "sequence": i])
            _ = recorder.append(json: json, event: "control_reply", identity: recorderIdentity, value: i)
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
