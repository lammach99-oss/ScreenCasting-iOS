import XCTest
@testable import iPadCasting

final class RemoteMonitorStateTests: XCTestCase {
    static let entries = [
        RemoteMonitorEntry(id: 1, left: -1920, top: -10, width: 1920, height: 1080, flags: 1, name: "Built-in display"),
        RemoteMonitorEntry(id: 2, left: 0, top: 0, width: 2560, height: 1440, flags: 0, name: "Panel B")]
    static func catalogue(epoch: UInt64 = 9, revision: UInt64 = 3, current: UInt64 = 1, state: UInt8 = 1) -> RemoteMonitorCatalogueCommand {
        RemoteMonitorCatalogueCommand(desktop: 1, state: state, epoch: epoch, revision: revision, currentId: current, entries: entries)
    }
    static func context(epoch: UInt64 = 9, target: Int = 0) -> RemoteInputContextCommand {
        let entry = entries[target]
        return RemoteInputContextCommand(state: 1, desktop: 1, token: epoch, desktopEpoch: epoch,
            left: entry.left, top: entry.top, width: entry.width, height: entry.height)
    }
    private func ready() -> RemoteMonitorState {
        var state = RemoteMonitorState(); let session = UUID()
        state.begin(session: session, acceptedFeatures: 7)
        _ = state.receiveCatalogue(Self.catalogue(), session: session)
        state.receiveContext(Self.context(), session: session)
        return state
    }
    func testNegotiationRequestsSevenAndFallsBackToThree() throws {
        for accepted in [UInt64(0), 1, 2, 3, 7] {
            var negotiation = RemoteFeatureNegotiation(requestedFeatures: 7)
            XCTAssertTrue(negotiation.begin(now: 0))
            let request = try XCTUnwrap(negotiation.pong(flags: 0x4000, now: 1))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, 7)
            XCTAssertTrue(negotiation.result(flags: 0, payload: RemoteFeaturesMessage(features: accepted).encode()))
            var state = RemoteMonitorState(); let session = UUID()
            state.begin(session: session, acceptedFeatures: negotiation.accepted)
            XCTAssertEqual(state.enabled, accepted == 7)
            XCTAssertEqual(state.catalogueRequest(session: session) != nil, accepted == 7)
            XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        }
        for accepted in [UInt64(4), 5, 6, 8] {
            var negotiation = RemoteFeatureNegotiation(requestedFeatures: 7)
            _ = negotiation.begin(now: 0); _ = negotiation.pong(flags: 0x4000, now: 1)
            XCTAssertFalse(negotiation.result(flags: 0, payload: RemoteFeaturesMessage(features: accepted).encode()))
        }
        var legacy = RemoteFeatureNegotiation(requestedFeatures: 7)
        _ = legacy.begin(now: 0); XCTAssertNil(legacy.pong(flags: 0, now: 1)); XCTAssertEqual(legacy.accepted, 0)
    }
    func testOnePendingSelectionAndNoOptimisticCurrentTile() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        XCTAssertEqual(request.expectedEpoch, 9); XCTAssertEqual(request.catalogueRevision, 3); XCTAssertEqual(request.targetId, 2)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: true)
        XCTAssertEqual(picker.tiles.map(\.status), [.showing, .switching]); XCTAssertTrue(picker.isSwitching)
        XCTAssertEqual(state.catalogue?.currentId, 1)
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session))
        XCTAssertNotNil(state.pending); XCTAssertEqual(state.catalogue?.currentId, 1)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: false).tiles.map(\.status), [.showing, .switching])
        _ = state.receiveCatalogue(Self.catalogue(epoch: 10, revision: 4, current: 2), session: session)
        XCTAssertNotNil(state.pending, "catalogue alone cannot confirm a mismatched context")
        state.receiveContext(Self.context(epoch: 10, target: 1), session: session)
        XCTAssertNil(state.pending)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: false).tiles.map(\.status), [.available, .showing])
    }
    func testCatalogueAndContextMayPrecedeAppliedResult() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        state.receiveContext(Self.context(epoch: 10, target: 1), session: session)
        _ = state.receiveCatalogue(Self.catalogue(epoch: 10, revision: 4, current: 2), session: session)
        XCTAssertNotNil(state.pending)
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session))
        XCTAssertNil(state.pending)
    }
    func testStaleRequestsFreshCatalogueBeforeAnotherSelection() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: 1, requestId: request.requestId,
            epoch: 9, catalogueRevision: 4, currentId: 1), session: session)
        XCTAssertEqual(state.issue, .stale); XCTAssertNil(state.pending); XCTAssertTrue(state.needsCatalogueRefresh)
        XCTAssertEqual(state.catalogueRequest(session: session)?.knownRevision, 0)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        XCTAssertFalse(state.needsCatalogueRefresh)
        XCTAssertNotNil(state.select(targetId: 2, catalogue: Self.catalogue(revision: 4), session: session))
    }
    func testFailureStatusesAndUnavailableSecureDesktopPresentation() throws {
        let cases: [(UInt8, RemoteMonitorState.Issue)] = [(2,.unavailable),(3,.denied),(4,.failed),(5,.busy)]
        for (status, issue) in cases {
            var state = ready(); let session = state.session
            let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
            _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: status, requestId: request.requestId,
                epoch: 9, catalogueRevision: 3, currentId: 1), session: session)
            XCTAssertNil(state.pending); XCTAssertEqual(state.issue, issue)
            XCTAssertNotNil(state.statusMessage)
        }
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(RemoteMonitorCatalogueCommand(desktop: 2, state: 0, epoch: 10,
            revision: 4, currentId: 0, entries: []), session: session)
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: false)
        XCTAssertEqual(picker.phase, .locked); XCTAssertEqual(picker.control, .unavailable)
        XCTAssertTrue(picker.tiles.isEmpty); XCTAssertFalse(picker.canAskPermission); XCTAssertNotNil(state.statusMessage)
    }
    func testRetiredCallbacksReconnectAndNewNegotiationCannotSettleSelection() throws {
        var state = ready(); let retired = state.session
        let old = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: retired))
        let current = UUID(); state.begin(session: current, acceptedFeatures: 7)
        XCTAssertNil(state.catalogue); XCTAssertNil(state.pending); XCTAssertNil(state.issue)
        _ = state.receiveCatalogue(Self.catalogue(), session: current)
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: current))
        XCTAssertEqual(old.requestId, request.requestId, "session identity, not counter alone, owns callbacks")
        let result = RemoteMonitorSelectResultCommand(status: 0, requestId: old.requestId, epoch: 10, catalogueRevision: 4, currentId: 2)
        XCTAssertFalse(state.receiveResult(result, session: retired))
        XCTAssertFalse(state.receiveCatalogue(Self.catalogue(epoch: 10, revision: 4, current: 2), session: retired))
        state.receiveContext(Self.context(epoch: 10, target: 1), session: retired)
        state.selectionFailed(requestId: old.requestId, session: retired)
        XCTAssertEqual(state.pending?.request, request); XCTAssertNil(state.issue)
        state.begin(session: UUID(), acceptedFeatures: 0)
        XCTAssertFalse(state.enabled); XCTAssertNil(state.catalogue); XCTAssertNil(state.pending)
    }
    func testUnmatchedResultsTimeoutOldCatalogueAndUnknownTargets() throws {
        var state = ready(); let session = state.session
        XCTAssertNil(state.select(targetId: 1, catalogue: Self.catalogue(), session: session))
        XCTAssertNil(state.select(targetId: 99, catalogue: Self.catalogue(), session: session))
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        XCTAssertFalse(state.receiveResult(RemoteMonitorSelectResultCommand(status: 4, requestId: request.requestId + 1,
            epoch: 9, catalogueRevision: 3, currentId: 1), session: session))
        XCTAssertFalse(state.receiveCatalogue(Self.catalogue(epoch: 8, revision: 2), session: session))
        state.selectionFailed(requestId: request.requestId, session: session)
        XCTAssertNil(state.pending); XCTAssertEqual(state.issue, .failed); XCTAssertTrue(state.needsCatalogueRefresh)
        XCTAssertFalse(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session))
    }
    func testPickerVisibilityAndSingleMonitorCastingRegression() throws {
        XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: true, mirror: true, acceptedFeatures: 3))
        XCTAssertTrue(ScreenPickerSnapshot.shouldShowPicker(remote: true, mirror: false, acceptedFeatures: 7))
        XCTAssertTrue(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: true, acceptedFeatures: 0))
        XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: false, acceptedFeatures: 7))
        let casting = MirrorMonitorCatalogue(revision: 3, selected: 1, allowed: true,
            monitors: [MirrorMonitorChoice(id: 1, label: "Built-in display")])
        let before = ScreenPickerSnapshot.make(catalogue: casting, state: nil, switchingTo: nil,
            switchPending: false, pickerSupported: true, permissionAsked: false)
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 9, revision: 4,
            currentId: 1, entries: [Self.entries[0]]), session: session)
        let remote = ScreenPickerSnapshot.make(remote: state, inputReady: true)
        XCTAssertEqual(remote.tiles, before.tiles); XCTAssertEqual(remote.phase, before.phase)
        XCTAssertEqual(remote.tiles.count, 1); XCTAssertEqual(remote.tiles.first?.status, .showing)
        XCTAssertEqual(WireMessageType.mirrorSwitchRequest.rawValue, 56)
    }
    func testStaleTapAndContradictoryAppliedCannotChooseAnotherMonitor() throws {
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session))
        XCTAssertEqual(state.issue, .stale); XCTAssertTrue(state.needsCatalogueRefresh)
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(revision: 4), session: session))
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 5, currentId: 1), session: session))
        XCTAssertEqual(state.issue, .failed); XCTAssertNil(state.pending)
        XCTAssertEqual(state.catalogue?.currentId, 1); XCTAssertTrue(state.needsCatalogueRefresh)
    }
    func testCurrentTileRequiresMatchingContextGeometryAndEpoch() {
        var state = ready(); let session = state.session
        state.receiveContext(Self.context(epoch: 8), session: session)
        XCTAssertEqual(state.confirmedCurrentId, 0)
        state.receiveContext(Self.context(target: 1), session: session)
        XCTAssertEqual(state.confirmedCurrentId, 0)
        state.receiveContext(Self.context(), session: session)
        XCTAssertEqual(state.confirmedCurrentId, 1)
        state.receiveContext(nil, session: session)
        XCTAssertEqual(state.confirmedCurrentId, 0)
    }
    func testExistingInputGateStillRequiresContextAndFirstKeyframe() throws {
        var negotiation = RemoteFeatureNegotiation(requestedFeatures: 7)
        _ = negotiation.begin(now: 0); _ = negotiation.pong(flags: 0x4000, now: 1)
        XCTAssertTrue(negotiation.result(flags: 0, payload: RemoteFeaturesMessage(features: 7).encode()))
        XCTAssertTrue(negotiation.receiveContext(flags: 0, payload: try XCTUnwrap(Self.context().encode())))
        XCTAssertFalse(negotiation.maySend(feature: 2, token: 9)); negotiation.keyframeArrived()
        XCTAssertTrue(negotiation.maySend(feature: 2, token: 9))
        let paused = RemoteInputContextCommand(state: 0, desktop: 1, token: 0, desktopEpoch: 10, left: 0, top: 0, width: 0, height: 0)
        XCTAssertTrue(negotiation.receiveContext(flags: 0, payload: try XCTUnwrap(paused.encode())))
        negotiation.keyframeArrived(); XCTAssertFalse(negotiation.maySend(feature: 2, token: 9))
        XCTAssertTrue(negotiation.receiveContext(flags: 0, payload: try XCTUnwrap(Self.context(epoch: 10, target: 1).encode())))
        XCTAssertFalse(negotiation.maySend(feature: 2, token: 10)); negotiation.keyframeArrived()
        XCTAssertTrue(negotiation.maySend(feature: 2, token: 10)); XCTAssertFalse(negotiation.maySend(feature: 2, token: 9))
    }
}
