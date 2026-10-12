import XCTest
@testable import WanQuicInterop

final class EvidenceRecorderTests: XCTestCase {
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