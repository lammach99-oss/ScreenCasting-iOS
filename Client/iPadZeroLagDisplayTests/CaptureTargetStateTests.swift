import XCTest
@testable import iPadCasting

final class CaptureTargetStateTests: XCTestCase {
    private func catalogue(revision: UInt64 = 3, current: UInt64 = 1, allowed: Bool = true) -> CaptureTargetCatalogue {
        CaptureTargetCatalogue(state: 1, allowed: allowed, owner: 2, revision: revision, currentId: current, epoch: 5,
            entries: [CaptureTargetEntry(id: 1, kind: .extend, name: "Extend iPad"),
                      CaptureTargetEntry(id: 4, kind: .physical, name: "Panel")])
    }
    private func negotiated() -> CaptureTargetState {
        var model = CaptureTargetState(); model.begin(generation: 7)
        _ = model.advertise(flags: 0x7c00, generation: 7)
        _ = model.receiveCatalogue(catalogue(), session: model.session)
        return model
    }
    private func result(_ status: CaptureTargetStatus, transaction: UInt64 = 1, revision: UInt64 = 4,
                        kind: CaptureTargetKind? = .physical, current: UInt64 = 4) -> CaptureTargetResult {
        CaptureTargetResult(status: status, state: status == .accepted ? 2 : 1,
            kind: status == .accepted ? nil : kind, transaction: transaction, owner: 2, revision: revision,
            currentId: status == .accepted ? 0 : current, epoch: 5, source: 6, firstFrame: 0)
    }
    func testFourPeerCombinationsKeepLegacyHelloAndOnlyAdvertisedTypedOptIn() {
        for newHost in [false, true] {
            for newClient in [false, true] {
                let flags: UInt16 = newHost ? 0x7c00 : 0x7800
                let mirror = MirrorClientControl(); mirror.beginSession(7)
                XCTAssertEqual(mirror.helloIfAdvertised(session: 7, flags: flags), Data([1,0,0,0,7,0,0,0]))
                var model = CaptureTargetState(); model.begin(generation: 7)
                let hello = newClient ? model.advertise(flags: flags, generation: 7) : nil
                XCTAssertEqual(hello != nil, newHost && newClient)
                XCTAssertEqual(model.refresh(session: model.session) != nil, newHost && newClient)
            }
        }
    }
    func testPickerContainsExtendAndPhysicalInBothModesAndLegacyVisibilityIsUnchanged() {
        for current in [UInt64(1), 4] {
            var model = negotiated(); _ = model.receiveCatalogue(catalogue(revision: 4, current: current), session: model.session)
            let picker = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
            XCTAssertEqual(picker.tiles.map(\.label), ["Extend iPad", "Panel"])
            XCTAssertEqual(picker.tiles.first(where: { $0.status == .showing })?.id, current)
            XCTAssertTrue(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: current == 4,
                acceptedFeatures: 0, typedSources: true))
        }
        XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: false, acceptedFeatures: 0))
        XCTAssertTrue(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: true, acceptedFeatures: 0))
        XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: true, mirror: true, acceptedFeatures: 3, typedSources: true))
    }
    func testPendingTapNeverMarksTargetCurrentAndAcceptedIsNotTerminal() throws {
        var model = negotiated(); let session = model.session
        XCTAssertNotNil(model.select(4, catalogue: catalogue(), session: session))
        XCTAssertTrue(model.inputBlocked)
        var picker = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
        XCTAssertEqual(picker.tiles.map(\.status), [.showing, .switching])
        XCTAssertNil(model.select(1, catalogue: catalogue(), session: session))
        XCTAssertFalse(model.receiveResult(result(.busy, transaction: 2), session: session))
        XCTAssertNotNil(model.pending)
        XCTAssertTrue(model.receiveResult(result(.accepted, revision: 3), session: session))
        XCTAssertNotNil(model.pending); XCTAssertTrue(model.inputBlocked)
        picker = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
        XCTAssertFalse(picker.tiles.contains(where: { $0.status == .showing }))
    }
    func testTerminalUsesMatchingRevisionAndNeverOverwritesNewerCatalogue() throws {
        var model = negotiated(); let session = model.session
        _ = model.select(4, catalogue: catalogue(), session: session)
        _ = model.receiveCatalogue(catalogue(revision: 4, current: 4), session: session)
        _ = model.receiveCatalogue(catalogue(revision: 5, current: 1), session: session)
        XCTAssertTrue(model.receiveResult(result(.applied), session: session))
        XCTAssertEqual(model.catalogue?.revision, 5); XCTAssertEqual(model.confirmedCurrentId, 1)
        XCTAssertTrue(model.inputBlocked); XCTAssertNil(model.pending)
        XCTAssertFalse(model.observeRendered(sequence: UInt32.max, session: session))
        XCTAssertTrue(model.observeRendered(sequence: 0, session: session))
        XCTAssertFalse(model.inputBlocked)
    }
    func testFailuresAreExplicitAndStaleRefreshesWithoutRetry() throws {
        for status in [CaptureTargetStatus.stale, .notAvailable, .denied, .failed, .busy, .administratorRequired, .timedOut, .cancelled] {
            var model = negotiated(); let session = model.session
            _ = model.select(4, catalogue: catalogue(), session: session)
            _ = model.receiveCatalogue(catalogue(revision: 4, current: 4), session: session)
            XCTAssertTrue(model.receiveResult(result(status), session: session))
            XCTAssertNil(model.pending); XCTAssertTrue(model.inputBlocked)
            XCTAssertNotNil(model.statusMessage)
            if status == .stale { XCTAssertTrue(model.needsCatalogueRefresh); XCTAssertNotNil(model.refresh(session: session)) }
            if status == .timedOut { XCTAssertTrue(model.needsCatalogueRefresh) }
            if status == .administratorRequired {
                XCTAssertTrue(model.statusMessage?.contains("administrator required on the PC") == true)
            }
        }
    }
    func testFailureWithoutTerminalCatalogueNeverClaimsRetiredSourceIsCurrent() {
        var model=negotiated();let session=model.session
        _=model.select(4, catalogue: catalogue(), session: session)
        _=model.receiveResult(result(.accepted, revision: 3), session: session)
        _=model.receiveResult(result(.failed), session: session)
        XCTAssertEqual(model.confirmedCurrentId, 0)
        XCTAssertTrue(model.inputBlocked);XCTAssertTrue(model.needsCatalogueRefresh)
    }
    func testUnknownDeadlineRequiresExplicitReselectionAndRetiredCallbacksCannotSettle() {
        var model = negotiated(); let oldSession = model.session
        _ = model.select(4, catalogue: catalogue(), session: oldSession)
        XCTAssertEqual(CaptureTargetProtocol.terminalWait, 65)
        XCTAssertTrue(model.expire(transaction: 1, session: oldSession))
        XCTAssertTrue(model.inputBlocked); XCTAssertNotNil(model.statusMessage)
        XCTAssertFalse(model.receiveResult(result(.applied), session: oldSession))
        _ = model.receiveCatalogue(catalogue(revision: 4), session: oldSession)
        XCTAssertNotNil(model.select(1, catalogue: catalogue(revision: 4), session: oldSession), "current tile is a real fresh-frame transaction")
        XCTAssertEqual(model.pending?.request.transaction, 2)
        model.begin(generation: 8)
        XCTAssertNil(model.catalogue); XCTAssertNil(model.pending); XCTAssertFalse(model.enabled)
        XCTAssertNil(model.advertise(flags: 0x7c00, generation: 7))
        _ = model.advertise(flags: 0x7c00, generation: 8)
        _ = model.receiveCatalogue(catalogue(), session: model.session)
        _ = model.select(4, catalogue: catalogue(), session: model.session)
        XCTAssertFalse(model.receiveResult(result(.applied), session: oldSession))
        XCTAssertFalse(model.expire(transaction: 1, session: oldSession)); XCTAssertNotNil(model.pending)
    }
    func testOwnerMismatchAndMissingResultRevisionFailClosed() {
        var model = negotiated(); let session = model.session
        _ = model.select(4, catalogue: catalogue(), session: session)
        let wrong=CaptureTargetResult(status: .applied, state: 1, kind: .physical, transaction: 1,
            owner: 9, revision: 4, currentId: 4, epoch: 5, source: 6, firstFrame: 0)
        XCTAssertFalse(model.receiveResult(wrong, session: session));XCTAssertNotNil(model.pending)
        XCTAssertTrue(model.receiveResult(result(.applied), session: session))
        XCTAssertNil(model.applied); XCTAssertTrue(model.inputBlocked); XCTAssertNotNil(model.statusMessage)
    }
    func testPresentationUnknownRejectsLateRenderAndRouteKeepsIncreasingTransaction() {
        var model=negotiated();let session=model.session
        _=model.select(4, catalogue: catalogue(), session: session)
        _=model.receiveCatalogue(catalogue(revision: 4, current: 4), session: session)
        _=model.receiveResult(result(.applied), session: session)
        XCTAssertFalse(model.canSelect, "one local operation includes its pending presentation")
        model.abandonPresentation(session: session)
        XCTAssertFalse(model.observeRendered(sequence: 0, session: session));XCTAssertTrue(model.inputBlocked)
        model.retireRoute();let replacement=model.session
        XCTAssertNotEqual(replacement, session);XCTAssertTrue(model.enabled)
        XCTAssertNil(model.catalogue);XCTAssertTrue(model.inputBlocked)
        XCTAssertFalse(model.receiveCatalogue(catalogue(revision: 3), session: replacement), "old route catalogue cannot recover authority")
        _=model.receiveCatalogue(catalogue(revision: 5), session: replacement)
        XCTAssertEqual(model.select(1, catalogue: catalogue(revision: 5), session: replacement)?.transaction, 2)
        XCTAssertFalse(model.receiveResult(result(.applied, transaction: 2), session: session))
    }
    func testListTimeoutNeverRetiresInputAndReadyCurrentTileCanBeReselected() {
        var model=CaptureTargetState();model.begin(generation: 7)
        _=model.advertise(flags: 0x7c00, generation: 7)
        model.markListUnavailable(session: model.session)
        XCTAssertTrue(model.listUnavailable);XCTAssertFalse(model.inputBlocked)
        _=model.receiveCatalogue(catalogue(), session: model.session)
        XCTAssertFalse(model.listUnavailable)
        XCTAssertTrue(ScreenPickerSnapshot.make(captureTargets: model, state: nil).tiles[0].canSelect)
        XCTAssertEqual(model.select(1, catalogue: catalogue(), session: model.session)?.targetId, 1)
    }
    func testCandidateBufferPreservesBootstrapAndDropsOrphanDeltasAndOverflows() {
        var buffer=CaptureTargetVideoBuffer()
        func frame(_ sequence: UInt32, _ idr: Bool, bytes: Int = 1) -> CaptureTargetVideoBuffer.Frame {
            CaptureTargetVideoBuffer.Frame(data: Data(repeating: 0, count: bytes), sequence: sequence,
                isIDR: idr, lengthPrefixed: true, receivedAt: 0)
        }
        buffer.append(frame(UInt32.max, false));XCTAssertTrue(buffer.frames.isEmpty)
        buffer.append(frame(UInt32.max, true));buffer.append(frame(0, false))
        XCTAssertEqual(buffer.take(firstFrame: UInt32.max).map(\.sequence), [UInt32.max, 0])
        buffer.append(frame(UInt32.max, true));XCTAssertTrue(buffer.take(firstFrame: 0).isEmpty)
        buffer.append(frame(0, true))
        for value in 1...120 { buffer.append(frame(UInt32(value), false)) }
        XCTAssertTrue(buffer.frames.isEmpty);XCTAssertEqual(buffer.byteCount, 0)
        buffer.append(frame(1, true, bytes: CaptureTargetVideoBuffer.maximumBytes + 1))
        XCTAssertTrue(buffer.frames.isEmpty)
        buffer.append(frame(1, true));buffer.append(frame(2, true));buffer.append(frame(3, false))
        XCTAssertEqual(buffer.take(firstFrame: 1).map(\.sequence), [2, 3])
    }
    func testRemoteControlPickerRetainsIndependentFeatureAndCatalogueRules() {
        var remote = RemoteMonitorState(); remote.begin(session: UUID(), acceptedFeatures: 3)
        XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: true, mirror: false, acceptedFeatures: 3))
        XCTAssertTrue(ScreenPickerSnapshot.make(remote: remote, inputReady: false).tiles.isEmpty)
        remote.begin(session: UUID(), acceptedFeatures: 7)
        _ = remote.receiveCatalogue(RemoteMonitorStateTests.catalogue(), session: remote.session)
        XCTAssertEqual(ScreenPickerSnapshot.make(remote: remote, inputReady: false).tiles.count, 2)
    }
}
