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
            XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
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
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        XCTAssertEqual(request.expectedEpoch, 9); XCTAssertEqual(request.catalogueRevision, 3); XCTAssertEqual(request.targetId, 2)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: true, controlEnabled: true)
        XCTAssertEqual(picker.tiles.map(\.status), [.showing, .switching]); XCTAssertTrue(picker.isSwitching)
        XCTAssertEqual(state.catalogue?.currentId, 1)
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session))
        XCTAssertNotNil(state.pending); XCTAssertEqual(state.catalogue?.currentId, 1)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true).tiles.map(\.status), [.showing, .switching])
        _ = state.receiveCatalogue(Self.catalogue(epoch: 10, revision: 4, current: 2), session: session)
        XCTAssertNotNil(state.pending, "catalogue alone cannot confirm a mismatched context")
        state.receiveContext(Self.context(epoch: 10, target: 1), session: session)
        XCTAssertNil(state.pending)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true).tiles.map(\.status), [.locked, .showing])
    }
    func testCatalogueAndContextMayPrecedeAppliedResult() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        state.receiveContext(Self.context(epoch: 10, target: 1), session: session)
        _ = state.receiveCatalogue(Self.catalogue(epoch: 10, revision: 4, current: 2), session: session)
        XCTAssertNotNil(state.pending)
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session))
        XCTAssertNil(state.pending)
    }
    func testStaleRequestsFreshCatalogueBeforeAnotherSelection() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: 1, requestId: request.requestId,
            epoch: 9, catalogueRevision: 4, currentId: 1), session: session)
        XCTAssertEqual(state.issue, .stale); XCTAssertNil(state.pending); XCTAssertTrue(state.needsCatalogueRefresh)
        XCTAssertEqual(state.catalogueRequest(session: session)?.knownRevision, 0)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        XCTAssertFalse(state.needsCatalogueRefresh)
        XCTAssertNotNil(state.select(targetId: 2, catalogue: Self.catalogue(revision: 4), session: session, inputReady: true, controlEnabled: true))
    }
    func testFailureStatusesAndUnavailableSecureDesktopPresentation() throws {
        let cases: [(UInt8, RemoteMonitorState.Issue)] = [(2,.unavailable),(3,.denied),(4,.failed),(5,.busy)]
        for (status, issue) in cases {
            var state = ready(); let session = state.session
            let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
            _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: status, requestId: request.requestId,
                epoch: 9, catalogueRevision: 3, currentId: 1), session: session)
            XCTAssertNil(state.pending); XCTAssertEqual(state.issue, issue)
            XCTAssertNotNil(state.statusMessage)
        }
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(RemoteMonitorCatalogueCommand(desktop: 2, state: 0, epoch: 10,
            revision: 4, currentId: 0, entries: []), session: session)
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true)
        XCTAssertEqual(picker.phase, .locked); XCTAssertEqual(picker.control, .unavailable)
        XCTAssertTrue(picker.tiles.isEmpty); XCTAssertFalse(picker.canAskPermission); XCTAssertNotNil(state.statusMessage)
    }
    func testRetiredCallbacksReconnectAndNewNegotiationCannotSettleSelection() throws {
        var state = ready(); let retired = state.session
        let old = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: retired, inputReady: true, controlEnabled: true))
        let current = UUID(); state.begin(session: current, acceptedFeatures: 7)
        XCTAssertNil(state.catalogue); XCTAssertNil(state.pending); XCTAssertNil(state.issue)
        _ = state.receiveCatalogue(Self.catalogue(), session: current)
        state.receiveContext(Self.context(), session: current)
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: current, inputReady: true, controlEnabled: true))
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
        XCTAssertNil(state.select(targetId: 1, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        XCTAssertNil(state.select(targetId: 99, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
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
        let remote = ScreenPickerSnapshot.make(remote: state, inputReady: true, controlEnabled: true)
        XCTAssertEqual(remote.tiles, before.tiles); XCTAssertEqual(remote.phase, before.phase)
        XCTAssertEqual(remote.tiles.count, 1); XCTAssertEqual(remote.tiles.first?.status, .showing)
        XCTAssertEqual(WireMessageType.mirrorSwitchRequest.rawValue, 56)
    }
    func testStaleTapAndContradictoryAppliedCannotChooseAnotherMonitor() throws {
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        XCTAssertEqual(state.issue, .stale); XCTAssertTrue(state.needsCatalogueRefresh)
        _ = state.receiveCatalogue(Self.catalogue(revision: 4), session: session)
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(revision: 4), session: session, inputReady: true, controlEnabled: true))
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

    private func inputGate(_ context: RemoteInputContextCommand? = RemoteMonitorStateTests.context(), keyframe: Bool = true) -> RemoteFeatureNegotiation {
        var gate = RemoteFeatureNegotiation(requestedFeatures: 7)
        _ = gate.begin(now: 0); _ = gate.pong(flags: 0x4000, now: 1)
        _ = gate.result(flags: 0, payload: RemoteFeaturesMessage(features: 7).encode())
        if let context, let payload = context.encode() { _ = gate.receiveContext(flags: 0, payload: payload) }
        if keyframe { gate.keyframeArrived() }
        return gate
    }
    func testPausedContextDisablesSelectionEvenWithReadyArgument() {
        var state = ready(); let session = state.session
        let paused = RemoteInputContextCommand(state: 0, desktop: 1, token: 0, desktopEpoch: 9,
            left: 0, top: 0, width: 0, height: 0)
        state.receiveContext(paused, session: session)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: true, controlEnabled: true)
        XCTAssertEqual(picker.control, .unavailable); XCTAssertFalse(picker.tiles.contains { $0.canSelect })
        XCTAssertNotNil(state.selectionStatus(inputReady: true, controlEnabled: true))
        _ = state.receiveCatalogue(Self.catalogue(revision: 4, current: 0), session: session)
        XCTAssertFalse(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: false).tiles.contains { $0.status == .showing })
    }
    func testPreKeyframeSelectionReopensWithExistingInputGate() {
        var state = ready(); let session = state.session; var gate = inputGate(keyframe: false)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: gate.inputReady, controlEnabled: true))
        let blocked = ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true)
        XCTAssertEqual(blocked.control, .viewOnly); XCTAssertEqual(blocked.tiles.map(\.status), [.showing, .locked])
        XCTAssertFalse(blocked.tiles.contains { $0.canSelect })
        XCTAssertEqual(state.selectionStatus(inputReady: gate.inputReady, controlEnabled: true), "Waiting for the remote picture.")
        gate.keyframeArrived()
        let ready = ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true)
        XCTAssertEqual(ready.control, .on); XCTAssertTrue(ready.tiles[1].canSelect)
        XCTAssertNotNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: gate.inputReady, controlEnabled: true))
    }
    func testAppliedAndNewContextRemainDisabledUntilNewKeyframe() throws {
        var state = ready(); let session = state.session; var gate = inputGate()
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: gate.inputReady, controlEnabled: true))
        _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 4, currentId: 2), session: session)
        let next = Self.catalogue(epoch: 10, revision: 4, current: 2), context = Self.context(epoch: 10, target: 1)
        _ = state.receiveCatalogue(next, session: session)
        XCTAssertTrue(gate.receiveContext(flags: 0, payload: try XCTUnwrap(context.encode())))
        state.receiveContext(context, session: session); XCTAssertNil(state.pending)
        XCTAssertNil(state.select(targetId: 1, catalogue: next, session: session, inputReady: gate.inputReady, controlEnabled: true))
        let picker = ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true)
        XCTAssertEqual(picker.tiles.map(\.status), [.locked, .showing]); XCTAssertFalse(picker.tiles.contains { $0.canSelect })
        gate.keyframeArrived()
        XCTAssertNotNil(state.select(targetId: 1, catalogue: next, session: session, inputReady: gate.inputReady, controlEnabled: true))
    }
    func testReplacementContextWithoutKeyframeRetiresSelectionReadiness() throws {
        var state = ready(); let session = state.session; var gate = inputGate()
        let replacement = Self.context(epoch: 10)
        XCTAssertTrue(gate.receiveContext(flags: 0, payload: try XCTUnwrap(replacement.encode())))
        state.receiveContext(replacement, session: session)
        let next = Self.catalogue(epoch: 10, revision: 4)
        _ = state.receiveCatalogue(next, session: session)
        XCTAssertNil(state.select(targetId: 2, catalogue: next, session: session, inputReady: gate.inputReady, controlEnabled: true))
        gate.keyframeArrived()
        XCTAssertTrue(ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true).tiles[1].canSelect)
    }
    func testViewOnlyAndUnavailableRetainReadOnlyCatalogueAndCurrentTile() {
        for control in [false, true] {
            var state = ready(); let session = state.session
            let gate = inputGate(keyframe: control)
            let picker = ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: false)
            XCTAssertEqual(picker.control, .viewOnly); XCTAssertEqual(picker.tiles.count, 2)
            XCTAssertEqual(picker.tiles.first?.status, .showing); XCTAssertFalse(picker.tiles.contains { $0.canSelect })
            XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: gate.inputReady, controlEnabled: false))
            XCTAssertEqual(state.selectionStatus(inputReady: gate.inputReady, controlEnabled: false), "Turn Control on to choose a screen.")
            if gate.inputReady {
                XCTAssertTrue(ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true).tiles[1].canSelect)
                XCTAssertNotNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: gate.inputReady, controlEnabled: true))
            }
        }
        var state = ready(); state.receiveContext(nil, session: state.session)
        XCTAssertFalse(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: false).tiles.contains { $0.canSelect })
        XCTAssertEqual(state.catalogue?.currentId, 1)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: false).tiles.first?.status, .showing)
    }
    func testFinalModelAdmissionRejectsControlOrContextRetirement() throws {
        var state = ready(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.catalogue(), session: session, inputReady: true, controlEnabled: true))
        XCTAssertTrue(state.mayWriteSelection(request, session: session, inputReady: true, controlEnabled: true))
        XCTAssertFalse(state.mayWriteSelection(request, session: session, inputReady: true, controlEnabled: false))
        XCTAssertFalse(state.mayWriteSelection(request, session: session, inputReady: false, controlEnabled: true))
        state.receiveContext(nil, session: session)
        XCTAssertFalse(state.mayWriteSelection(request, session: session, inputReady: true, controlEnabled: true))
    }
    func testRemoteAdmissionChangesLeaveCastingAndCaptureTargetsUnchanged() throws {
        let casting = MirrorMonitorCatalogue(revision: 3, selected: 1, allowed: true,
            monitors: Self.entries.map { MirrorMonitorChoice(id: $0.id, label: $0.name) })
        let mirror = ScreenPickerSnapshot.make(catalogue: casting, state: nil, switchingTo: nil,
            switchPending: false, pickerSupported: true, permissionAsked: false)
        XCTAssertEqual(mirror.tiles.map(\.status), [.showing, .available]); XCTAssertTrue(mirror.tiles[1].canSelect)
        var typed = CaptureTargetState(); typed.begin(generation: 7)
        _ = typed.advertise(flags: 0x7c00, generation: 7)
        let catalogue = CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: 3, currentId: 1, epoch: 5,
            entries: [CaptureTargetEntry(id: 1, kind: .extend, name: "Extend iPad"), CaptureTargetEntry(id: 4, kind: .physical, name: "Panel")])
        _ = typed.receiveCatalogue(catalogue, session: typed.session)
        let snapshot = ScreenPickerSnapshot.make(captureTargets: typed, state: nil)
        XCTAssertEqual(snapshot.tiles.map(\.isExtend), [true, false]); XCTAssertTrue(snapshot.tiles.allSatisfy { $0.canSelect })
        XCTAssertNotNil(typed.select(4, catalogue: catalogue, session: typed.session))
    }

    static func recoveryCatalogue(entries: [RemoteMonitorEntry]? = nil) -> RemoteMonitorCatalogueCommand {
        RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 9, revision: 4, currentId: 0,
            entries: entries ?? [Self.entries[1]])
    }
    static func pausedContext() -> RemoteInputContextCommand {
        RemoteInputContextCommand(state: 0, desktop: 1, token: 0, desktopEpoch: 9,
            left: 0, top: 0, width: 0, height: 0)
    }
    private func recovery() -> RemoteMonitorState {
        var state = ready(); let session = state.session
        _ = state.receiveCatalogue(Self.recoveryCatalogue(), session: session)
        state.receiveContext(Self.pausedContext(), session: session)
        return state
    }
    func testNoSourceRecoveryAdmitsSurvivorAndEncodesSelection() throws {
        for hasContext in [false, true] {
            var state = recovery(); let session = state.session
            if !hasContext { state.receiveContext(nil, session: session) }
            let gate = inputGate(hasContext ? Self.pausedContext() : nil, keyframe: false)
            XCTAssertFalse(gate.inputReady)
            let picker = ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true)
            XCTAssertEqual(picker.control, .on); XCTAssertEqual(picker.tiles.map(\.status), [.available])
            XCTAssertTrue(picker.tiles[0].canSelect); XCTAssertNil(picker.currentLabel)
            XCTAssertEqual(state.displayCurrentId, 0)
            XCTAssertEqual(state.selectionStatus(inputReady: false, controlEnabled: true), "Choose a screen to restore the picture.")
            let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(), session: session,
                inputReady: gate.inputReady, controlEnabled: true))
            XCTAssertEqual(request.expectedEpoch, 9); XCTAssertEqual(request.catalogueRevision, 4)
            XCTAssertEqual(request.targetId, 2); XCTAssertEqual(WireMessageType.remoteMonitorSelectRequest.rawValue, 70)
            XCTAssertEqual(RemoteMonitorSelectCommand.decode(try XCTUnwrap(request.encode())), request)
            XCTAssertTrue(state.mayWriteSelection(request, session: session, inputReady: false, controlEnabled: true))
        }
    }
    func testNoSourceRecoveryWithViewOnlyOrEmptyCatalogueIsBlocked() {
        var state = recovery(); let session = state.session
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(), session: session, inputReady: false, controlEnabled: false))
        let viewOnly = ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: false)
        XCTAssertEqual(viewOnly.control, .viewOnly); XCTAssertEqual(viewOnly.tiles.count, 1)
        XCTAssertFalse(viewOnly.tiles[0].canSelect); XCTAssertEqual(viewOnly.tiles[0].status, .locked)
        _ = state.receiveCatalogue(Self.recoveryCatalogue(entries: []), session: session)
        XCTAssertFalse(state.selectionReady(inputReady: false, controlEnabled: true))
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(entries: []), session: session, inputReady: false, controlEnabled: true))
        XCTAssertTrue(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true).tiles.isEmpty)
    }
    func testNoSourceRecoveryPendingAndBusyStillBlockAnotherSelection() throws {
        var state = recovery(); let session = state.session
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(), session: session,
            inputReady: false, controlEnabled: true))
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(), session: session, inputReady: false, controlEnabled: true))
        let pending = ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true)
        XCTAssertTrue(pending.isSwitching); XCTAssertFalse(pending.tiles.contains { $0.canSelect })
        XCTAssertTrue(state.receiveResult(RemoteMonitorSelectResultCommand(status: 5, requestId: request.requestId,
            epoch: 9, catalogueRevision: 4, currentId: 0), session: session))
        XCTAssertTrue(state.needsCatalogueRefresh)
        XCTAssertNil(state.select(targetId: 2, catalogue: Self.recoveryCatalogue(), session: session, inputReady: false, controlEnabled: true))
        XCTAssertFalse(ScreenPickerSnapshot.make(remote: state, inputReady: false, controlEnabled: true).tiles.contains { $0.canSelect })
    }
    func testLiveSourcePausedAndPreKeyframeDoNotUseRecoveryException() {
        for paused in [false, true] {
            var state = ready(); let session = state.session
            let context = paused ? Self.pausedContext() : Self.context()
            let gate = inputGate(context, keyframe: false)
            state.receiveContext(context, session: session)
            XCTAssertFalse(state.selectionReady(inputReady: gate.inputReady, controlEnabled: true))
            XCTAssertNil(state.select(targetId: 2, catalogue: Self.catalogue(), session: session,
                inputReady: gate.inputReady, controlEnabled: true))
            XCTAssertFalse(ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true).tiles.contains { $0.canSelect })
        }
    }
    func testRecoveryAppliedReturnsToNormalFirstKeyframeGate() throws {
        var state = recovery(); let session = state.session
        let third = RemoteMonitorEntry(id: 3, left: 2560, top: 0, width: 800, height: 600, flags: 0, name: "Panel C")
        let entries = [Self.entries[1], third], catalogue = Self.recoveryCatalogue(entries: [Self.entries[1], third])
        _ = state.receiveCatalogue(catalogue, session: session)
        let request = try XCTUnwrap(state.select(targetId: 2, catalogue: catalogue, session: session, inputReady: false, controlEnabled: true))
        _ = state.receiveResult(RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId,
            epoch: 10, catalogueRevision: 5, currentId: 2), session: session)
        XCTAssertNil(state.select(targetId: 3, catalogue: catalogue, session: session, inputReady: false, controlEnabled: true))
        let applied = RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 10, revision: 5, currentId: 2, entries: entries)
        _ = state.receiveCatalogue(applied, session: session)
        let context = Self.context(epoch: 10, target: 1); var gate = inputGate(context, keyframe: false)
        state.receiveContext(context, session: session); XCTAssertNil(state.pending)
        XCTAssertNil(state.select(targetId: 3, catalogue: applied, session: session, inputReady: gate.inputReady, controlEnabled: true))
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: state, inputReady: gate.inputReady, controlEnabled: true).tiles.map(\.status), [.showing, .locked])
        gate.keyframeArrived()
        XCTAssertNotNil(state.select(targetId: 3, catalogue: applied, session: session, inputReady: gate.inputReady, controlEnabled: true))
    }
}
