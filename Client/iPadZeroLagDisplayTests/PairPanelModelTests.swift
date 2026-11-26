import XCTest
@testable import iPadCasting

final class PairPanelModelTests: XCTestCase {
    func testRemoteCandidatesAndIdentity() {
        let entries = [false, true].map { RecentRemoteHost(host: "", remoteControl: $0, lastUsed: Date()) }
        XCTAssertEqual(PairPanelModel.recent(entries), [entries[1]])
        XCTAssertNil(PairPanelModel.address(""))
        XCTAssertNil(PairPanelModel.address("usb://"))
        XCTAssertNil(PairPanelModel.address("[2001:db8::1]:27015"))
        XCTAssertNotNil(PairPanelModel.address("[2001:db8::1]:27020"))
        let peer = TrustedPeerReference(String(repeating: "a", count: 64))!
        XCTAssertFalse(PairPanelModel.accepts(first: peer, candidate: peer))
        XCTAssertTrue(PairPanelModel.accepts(first: peer, candidate: nil))
    }

    func testDisplayStates() {
        XCTAssertEqual([SlotPhase.active, .parked, .connecting, .offline, .refused].map(PairPanelModel.label),
                       ["Connected", "Paused", "Reconnecting", "Offline", "Refused"])
        XCTAssertEqual(PairPanelModel.switchLabel("PC 2"), "Switch to PC 2")
    }

    @MainActor func testFailoverNeedsOwnerTap() throws {
        let model = SessionSwitcher()
        XCTAssertTrue(model.claimSurface("first"))
        XCTAssertFalse(model.claimSurface("second"))
        let attempt = try XCTUnwrap(model.connect(.two, route: .wifi))
        XCTAssertTrue(model.authenticate(attempt, peer: TrustedPeerReference(String(repeating: "a", count: 64))!))
        model.drop(model[.one].ticket, error: .transport)
        XCTAssertEqual(model.selected, .one)
        XCTAssertNil(PairPanelModel.tapTarget(model, scene: "second"))
        XCTAssertEqual(PairPanelModel.tapTarget(model, scene: "first"), .two)
        _ = model.select(.two, scene: "first")
        XCTAssertNil(PairPanelModel.tapTarget(model, scene: "first"))
    }

    @MainActor func testSwapInFlightRejectsAnotherTapOnParkedPC() throws {
        let model = SessionSwitcher()
        XCTAssertTrue(model.claimSurface("scene"))
        for (slot, digit) in [(SlotOrdinal.one, "a"), (.two, "b")] {
            let ticket = try XCTUnwrap(model.connect(slot, route: .wifi))
            let peer = try XCTUnwrap(TrustedPeerReference(String(repeating: digit, count: 64)))
            XCTAssertTrue(model.authenticate(ticket, peer: peer))
        }
        let first = try XCTUnwrap(model.inFlight)
        _ = model.presented(first)
        _ = model.contextReady(first)
        XCTAssertEqual(PairPanelModel.tapTarget(model, scene: "scene"), .two)
        _ = model.select(.two, scene: "scene")
        XCTAssertEqual(model[.one].phase, .parked)
        XCTAssertNil(PairPanelModel.tapTarget(model, scene: "scene"))
    }
}
