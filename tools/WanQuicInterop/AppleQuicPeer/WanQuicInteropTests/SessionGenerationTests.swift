import XCTest
@testable import WanQuicInterop
final class SessionGenerationTests: XCTestCase {
    func testRetirementAndLateCompletionCannotMutateReplacement() {
        let old = QuicConnectionOwner(generation: 7, evidenceIdentity: EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 7))
        let next = QuicConnectionOwner(generation: 8, evidenceIdentity: EvidenceIdentity(runID: UUID(), ownerID: UUID(), generation: 8))
        XCTAssertTrue(old.accepts(7)); XCTAssertFalse(old.accepts(8))
        old.retire(); old.retire()
        var delivered = 0
        let lateCallback = { if old.accepts(7) { delivered += 1 } }
        lateCallback()
        XCTAssertEqual(delivered, 0); XCTAssertTrue(next.accepts(8))
        XCTAssertFalse(next.accepts(7)); XCTAssertEqual(next.pendingSends, 0)
    }
    func testDirectionalCapacityBoundaryProbeIsBounded() {
        let sizes = DatagramLane.sizes(capacity: 1200)
        XCTAssertEqual(Array(sizes.suffix(3)), [1181,1182,1183])
        XCTAssertLessThanOrEqual(sizes.count, 8)
    }
}
