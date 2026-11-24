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
    func testTypedExtendCyclesToPhysicalAndModeChoiceUsesOnlyConfirmedIdentity() {
        var model = negotiated()
        let extended = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
        let extendCycle = extended.cycle(kind: .castingExtend)
        XCTAssertEqual(extendCycle.count, 1)
        XCTAssertNil(extendCycle.position)
        XCTAssertEqual(extendCycle.currentLabel, "Extend iPad")
        XCTAssertTrue(extendCycle.enabled)
        XCTAssertEqual(extendCycle.nextTargetId, 4)
        XCTAssertEqual(extendCycle.hint, "Switch to Mirror and show Panel")
        let modes = CaptureModePresentation.make(targets: model, kind: .castingExtend, lastPhysicalId: nil)
        XCTAssertTrue(modes.extend.selected); XCTAssertFalse(modes.extend.enabled)
        XCTAssertTrue(modes.mirror.enabled); XCTAssertEqual(modes.mirror.targetId, 4)
        _ = model.select(4, catalogue: catalogue(), session: model.session)
        let pending = CaptureModePresentation.make(targets: model, kind: .castingExtend, lastPhysicalId: nil)
        XCTAssertTrue(pending.extend.selected); XCTAssertFalse(pending.mirror.selected)
        XCTAssertFalse(pending.extend.enabled); XCTAssertFalse(pending.mirror.enabled)
    }

    func testTypedCycleSkipsExtendAndPreservesReceivedPhysicalOrder() {
        var model = negotiated()
        let entries = [CaptureTargetEntry(id: 4, kind: .physical, name: "Screen"),
                       CaptureTargetEntry(id: 1, kind: .extend, name: "Extend iPad"),
                       CaptureTargetEntry(id: 8, kind: .physical, name: "Screen"),
                       CaptureTargetEntry(id: 6, kind: .physical, name: "Screen")]
        for (revision, current, next) in [(UInt64(4), UInt64(4), UInt64(8)), (5, 1, 4), (6, 8, 6), (7, 6, 4)] {
            let list = CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: revision,
                currentId: current, epoch: 5, entries: entries)
            _ = model.receiveCatalogue(list, session: model.session)
            let picker = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
            let cycle = picker.cycle(kind: .castingMirror)
            XCTAssertEqual(cycle.count, 3); XCTAssertEqual(cycle.nextTargetId, next)
            if current == 1 {
                XCTAssertEqual(cycle.currentLabel, "Extend iPad")
                XCTAssertNil(cycle.position)
                XCTAssertEqual(picker.cycle(kind: .castingMirror, lastPhysicalId: 6).nextTargetId, 6)
            }
            XCTAssertTrue(cycle.enabled)
        }
    }

    func testMirrorReturnsToLastConfirmedPhysicalAndFallsBackWhenItDisappears() {
        var model = negotiated(); var memory = ConfirmedPhysicalScreen()
        let entries = [CaptureTargetEntry(id: 8, kind: .physical, name: "Screen 1")] + catalogue().entries
        for (revision, current) in [(UInt64(4), UInt64(4)), (5, 1)] {
            _ = model.receiveCatalogue(CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: revision,
                currentId: current, epoch: 5, entries: entries), session: model.session)
            memory.observe(model)
        }
        XCTAssertEqual(memory.id, 4)
        XCTAssertEqual(CaptureModePresentation.make(targets: model, kind: .castingExtend, lastPhysicalId: memory.id).mirror.targetId, 4)
        _ = model.receiveCatalogue(CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: 6,
            currentId: 1, epoch: 5, entries: entries.filter { $0.id != 4 }), session: model.session)
        memory.observe(model); XCTAssertNil(memory.id)
        XCTAssertEqual(CaptureModePresentation.make(targets: model, kind: .castingExtend, lastPhysicalId: memory.id).mirror.targetId, 8)
    }

    func testUnknownOutcomeAllowsOnePhysicalSurvivorOnlyAfterFreshCatalogue() {
        var model = negotiated()
        _ = model.select(4, catalogue: catalogue(), session: model.session)
        XCTAssertTrue(model.expire(transaction: 1, session: model.session))
        XCTAssertFalse(ScreenPickerSnapshot.make(captureTargets: model, state: nil).cycle(kind: .castingUnknown).enabled)
        _ = model.receiveCatalogue(catalogue(revision: 4, current: 4), session: model.session)
        let picker = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
        XCTAssertNil(picker.currentLabel)
        let cycle = picker.cycle(kind: .castingUnknown)
        XCTAssertEqual(cycle.count, 1); XCTAssertTrue(cycle.enabled)
        XCTAssertEqual(cycle.currentLabel, "Choose a screen"); XCTAssertEqual(cycle.nextTargetId, 4)
        XCTAssertNotNil(model.select(4, catalogue: catalogue(revision: 4, current: 4), session: model.session))
    }

    func testUnknownExtendCanBeReactivatedWithoutBypassingUnavailableStates() {
        var model = negotiated()
        _ = model.select(4, catalogue: catalogue(), session: model.session)
        _ = model.expire(transaction: 1, session: model.session)
        _ = model.receiveCatalogue(catalogue(revision: 4), session: model.session)
        let choices = CaptureModePresentation.make(targets: model, kind: .castingUnknown, lastPhysicalId: nil)
        XCTAssertTrue(choices.extend.selected); XCTAssertTrue(choices.extend.enabled)
        XCTAssertEqual(choices.explanation, "Choose Extend again to restore the picture.")
        let unavailable = CaptureTargetCatalogue(state: 3, allowed: true, owner: 2, revision: 5,
            currentId: 0, epoch: 5, entries: catalogue().entries)
        _ = model.receiveCatalogue(unavailable, session: model.session)
        let blocked = CaptureModePresentation.make(targets: model, kind: .castingUnknown, lastPhysicalId: nil)
        XCTAssertFalse(blocked.extend.enabled); XCTAssertFalse(blocked.mirror.enabled)
        XCTAssertFalse(ScreenPickerSnapshot.make(captureTargets: model, state: nil).cycle(kind: .castingUnknown).enabled)
    }

    func testPhysicalMemoryRetiresWithSessionAndOnlyRecordsConfirmedPhysicalScreens() {
        var model = negotiated(); var memory = ConfirmedPhysicalScreen()
        memory.observe(model); XCTAssertNil(memory.id)
        _ = model.receiveCatalogue(catalogue(revision: 4, current: 4), session: model.session)
        memory.observe(model); XCTAssertEqual(memory.id, 4)
        _ = model.receiveCatalogue(catalogue(revision: 5), session: model.session)
        memory.observe(model); XCTAssertEqual(memory.id, 4)
        model.retireRoute(); memory.observe(model); XCTAssertNil(memory.id)
    }

    func testScreenPermissionDoesNotDependOnControlAndApprovalDoesNotCreateARequest() {
        var model = negotiated()
        _ = model.receiveCatalogue(catalogue(revision: 4, current: 4, allowed: false), session: model.session)
        let locked = ScreenPickerSnapshot.make(captureTargets: model, state: nil)
        XCTAssertEqual(locked.control, .unavailable); XCTAssertTrue(locked.canAskPermission)
        XCTAssertFalse(locked.cycle(kind: .castingMirror).enabled)
        XCTAssertFalse(ScreenPickerSnapshot.make(captureTargets: model, state: nil, permissionAsked: true).canAskPermission)
        _ = model.receiveCatalogue(catalogue(revision: 5), session: model.session)
        XCTAssertNil(model.pending)
        XCTAssertTrue(CaptureModePresentation.make(targets: model, kind: .castingExtend, lastPhysicalId: nil).mirror.enabled)
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
        let busy = CaptureTargetCatalogue(state: 2, allowed: false, owner: 2, revision: 4,
            currentId: 0, epoch: 5, entries: Array(catalogue().entries.prefix(1)))
        XCTAssertTrue(model.receiveCatalogue(busy, session: session))
        _=model.receiveResult(result(.failed, revision: 5), session: session)
        XCTAssertEqual(model.confirmedCurrentId, 0)
        XCTAssertTrue(model.inputBlocked);XCTAssertTrue(model.needsCatalogueRefresh)
        let cycle = ScreenPickerSnapshot.make(captureTargets: model, state: nil).cycle(kind: .castingUnknown)
        XCTAssertEqual(cycle.count, 1)
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingUnknown, cycle: cycle))
        XCTAssertFalse(cycle.pending)
        XCTAssertFalse(cycle.enabled)
    }

    func testFailedExtendKeepsPickerVisibleAndRestoresExtendModeChoiceOnSingleMirror() throws {
        var model = negotiated()
        let session = model.session
        let mirror = catalogue(revision: 4, current: 4)
        XCTAssertTrue(model.receiveCatalogue(mirror, session: session))

        func cycle() -> ScreenCyclePresentation {
            ScreenPickerSnapshot.make(captureTargets: model, state: nil).cycle(kind: .castingMirror)
        }
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingMirror, cycle: cycle()))
        XCTAssertNil(cycle().position)
        XCTAssertEqual(cycle().nextTargetId, 4)
        XCTAssertFalse(cycle().enabled)
        XCTAssertNotNil(model.select(1, catalogue: mirror, session: session))
        XCTAssertTrue(model.receiveResult(result(.accepted, revision: 4), session: session))
        let busy = CaptureTargetCatalogue(state: 2, allowed: false, owner: 2, revision: 5,
            currentId: 0, epoch: 5, entries: Array(mirror.entries.prefix(1)))
        XCTAssertTrue(model.receiveCatalogue(busy, session: session))
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingUnknown, cycle: cycle()))
        XCTAssertFalse(cycle().enabled)

        let restored = CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: 6,
            currentId: 14, epoch: 6, entries: [.init(id: 11, kind: .extend, name: "Extend iPad"),
                .init(id: 14, kind: .physical, name: "Panel")])
        XCTAssertTrue(model.receiveCatalogue(restored, session: session))
        let failed = CaptureTargetResult(status: .failed, state: 1, kind: .physical, transaction: 1,
            owner: 2, revision: 6, currentId: 14, epoch: 6, source: 7, firstFrame: 1)
        XCTAssertTrue(model.receiveResult(failed, session: session))
        XCTAssertEqual(model.issue, .failed)
        XCTAssertTrue(model.inputBlocked, "the restored decoder still owes a rendered frame")
        XCTAssertFalse(cycle().pending)
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingMirror, cycle: cycle()))
        XCTAssertFalse(cycle().enabled)
        XCTAssertEqual(cycle().nextTargetId, 14)
        XCTAssertTrue(CaptureModePresentation.make(targets: model, kind: .castingMirror,
            lastPhysicalId: nil).extend.enabled)
        XCTAssertTrue(model.observeRendered(sequence: 1, session: session))
    }
    func testUnknownDeadlineRequiresExplicitReselectionAndRetiredCallbacksCannotSettle() {
        var model = negotiated(); let oldSession = model.session
        _ = model.select(4, catalogue: catalogue(), session: oldSession)
        XCTAssertEqual(CaptureTargetProtocol.terminalWait, 75)
        XCTAssertTrue(model.expire(transaction: 1, session: oldSession))
        XCTAssertTrue(model.inputBlocked); XCTAssertNotNil(model.statusMessage)
        let timedOut = ScreenPickerSnapshot.make(captureTargets: model, state: nil).cycle(kind: .castingUnknown)
        XCTAssertFalse(timedOut.pending)
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingUnknown, cycle: timedOut))
        XCTAssertFalse(timedOut.enabled)
        XCTAssertFalse(model.receiveResult(result(.applied), session: oldSession))
        _ = model.receiveCatalogue(catalogue(revision: 4), session: oldSession)
        XCTAssertTrue(CaptureModePresentation.make(targets: model, kind: .castingUnknown, lastPhysicalId: nil).mirror.enabled)
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
