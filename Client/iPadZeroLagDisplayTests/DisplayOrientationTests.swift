import XCTest
@testable import iPadCasting

final class DisplayOrientationTests: XCTestCase {
    func testRejectedInitialDisplayRequestReleasesTouchSuppression() throws {
        var gate = DisplayRequestGate()
        let desired = DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)
        let request = try XCTUnwrap(gate.begin(desired))
        XCTAssertTrue(gate.isInputSuppressed)

        let next = gate.reject(DisplayConfigurationFailed(
            requestId: request.requestId, reason: .applyFailed))

        XCTAssertNil(next, "A rejected request must not silently retry itself")
        XCTAssertNil(gate.pending)
        XCTAssertNil(gate.latestDesired)
        XCTAssertFalse(gate.isInputSuppressed,
            "A terminal display rejection must not permanently block USB touch")
        XCTAssertNil(gate.effective, "Failure is not a successful display commit")
    }

    func testRepeatedSameDesiredModeDoesNotRetryAfterRejection() throws {
        var gate = DisplayRequestGate()
        let desired = DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)
        let request = try XCTUnwrap(gate.begin(desired))
        XCTAssertNil(gate.begin(desired))
        XCTAssertNil(gate.reject(DisplayConfigurationFailed(
            requestId: request.requestId, reason: .applyFailed)))
        XCTAssertFalse(gate.isInputSuppressed)
        XCTAssertNotNil(gate.begin(desired), "A later explicit request remains allowed")
    }

    func testRejectedRequestKeepsOnlyNewerDesiredModePendingUntilReady() throws {
        var gate = DisplayRequestGate()
        let first = try XCTUnwrap(gate.begin(DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)))
        XCTAssertNil(gate.begin(DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)))

        let next = try XCTUnwrap(gate.reject(DisplayConfigurationFailed(
            requestId: first.requestId, reason: .applyFailed)))
        XCTAssertNotEqual(next.requestId, first.requestId)
        XCTAssertEqual(next.orientation, .portrait)
        XCTAssertTrue(gate.isInputSuppressed)
        XCTAssertNil(gate.reject(DisplayConfigurationFailed(
            requestId: first.requestId, reason: .applyFailed)))
        XCTAssertEqual(gate.pending, next, "Stale rejection must not unlock input")

        XCTAssertNil(gate.accept(DisplayReady(
            width: next.width, height: next.height, refreshHz: next.refreshHz,
            orientation: next.orientation, requestId: next.requestId, generation: 2)))
        XCTAssertFalse(gate.isInputSuppressed)
        XCTAssertEqual(gate.effective?.orientation, .portrait)
    }

    func testRejectedChangePreservesLastEffectiveDisplay() throws {
        var gate = DisplayRequestGate()
        let first = try XCTUnwrap(gate.begin(DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)))
        let ready = DisplayReady(width: first.width, height: first.height,
            refreshHz: first.refreshHz, orientation: first.orientation,
            requestId: first.requestId, generation: 1)
        _ = gate.accept(ready)
        let change = try XCTUnwrap(gate.begin(DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)))
        XCTAssertTrue(gate.isInputSuppressed)
        XCTAssertNil(gate.reject(DisplayConfigurationFailed(
            requestId: change.requestId, reason: .applyFailed)))
        XCTAssertFalse(gate.isInputSuppressed)
        XCTAssertEqual(gate.effective, ready)
    }

    func testCommittedGeometryResolvesInitialOrientation() {
        XCTAssertNil(DisplayOrientationResolver.resolve(width: 0, height: 0))
        XCTAssertEqual(
            DisplayOrientationResolver.resolve(width: 1668, height: 2388),
            .portrait)
        XCTAssertEqual(
            DisplayOrientationResolver.resolve(width: 2388, height: 1668),
            .landscape)
    }

    func testCapabilitiesBeforeGeometryEmitsOnePortraitRequest() {
        var gate = DisplayRequestGate()
        let portrait = DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)

        // Capabilities may arrive before the first committed geometry. No
        // placeholder landscape request is allowed in that state.
        XCTAssertNil(gate.pending)
        let request = try! XCTUnwrap(gate.begin(portrait))
        XCTAssertEqual(request.width, 1668)
        XCTAssertEqual(request.height, 2388)
        XCTAssertNil(gate.begin(portrait))
    }

    func testGeometryBeforeCapabilitiesEmitsOnePortraitRequest() {
        var gate = DisplayRequestGate()
        let portrait = DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)

        let request = try! XCTUnwrap(gate.begin(portrait))
        _ = gate.accept(DisplayReady(
            width: request.width, height: request.height,
            refreshHz: request.refreshHz, orientation: request.orientation,
            requestId: request.requestId, generation: 1))
        XCTAssertNil(gate.begin(portrait))
    }

    func testRapidRequestsCoalesceToLatestAfterInFlightCompletes() {
        var gate = DisplayRequestGate()
        let landscape = DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)
        let portrait = DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)

        let first = try! XCTUnwrap(gate.begin(landscape))
        XCTAssertNil(gate.begin(portrait))
        XCTAssertNil(gate.begin(landscape))
        XCTAssertNil(gate.begin(portrait))

        let next = gate.accept(DisplayReady(
            width: first.width, height: first.height,
            refreshHz: first.refreshHz, orientation: first.orientation,
            requestId: first.requestId, generation: 1))
        XCTAssertEqual(next?.orientation, .portrait)
        XCTAssertEqual(gate.latestDesired?.orientation, .portrait)
    }

    func testLateObsoleteCompletionCannotReplaceLatestDesired() {
        var gate = DisplayRequestGate()
        let landscape = DisplayConfigurationRequest(
            width: 2388, height: 1668, refreshHz: 60,
            orientation: .landscape, requestId: 0)
        let portrait = DisplayConfigurationRequest(
            width: 1668, height: 2388, refreshHz: 60,
            orientation: .portrait, requestId: 0)
        let first = try! XCTUnwrap(gate.begin(landscape))
        XCTAssertNil(gate.begin(portrait))
        _ = gate.accept(DisplayReady(
            width: first.width, height: first.height,
            refreshHz: first.refreshHz, orientation: first.orientation,
            requestId: first.requestId, generation: 1))
        XCTAssertEqual(gate.pending?.orientation, .portrait)
        XCTAssertEqual(gate.latestDesired?.orientation, .portrait)
    }
}
