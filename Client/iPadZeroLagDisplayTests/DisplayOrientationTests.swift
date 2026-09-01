import XCTest
@testable import iPadCasting

final class DisplayOrientationTests: XCTestCase {
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
