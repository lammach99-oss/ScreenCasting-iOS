import XCTest
import Network
import UIKit
@testable import iPadCasting

final class SecureDesktopRecoveryTests: XCTestCase {
    func testGoldenCodecsAndStrictWhitelist() {
        XCTAssertEqual(CaptureAvailabilityProtocol.hello, Data([1, 0, 0, 0]))
        let suspended = CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1)
        XCTAssertEqual(suspended.encode(), Data([1, 1, 0, 0, 1, 0, 0, 0]))
        XCTAssertEqual(CaptureAvailabilityCommand.decode(suspended.encode()), suspended)
        XCTAssertEqual(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 3).encode(), Data([0, 0, 0, 0, 3, 0, 0, 0]))
        for invalid in [Data(), Data([1, 1, 0, 0, 1, 0, 0]), Data([2, 1, 0, 0, 1, 0, 0, 0]),
                        Data([0, 1, 0, 0, 1, 0, 0, 0]), Data([1, 0, 0, 0, 1, 0, 0, 0]),
                        Data([1, 1, 1, 0, 1, 0, 0, 0]), Data([1, 1, 0, 1, 1, 0, 0, 0])] {
            XCTAssertNil(CaptureAvailabilityCommand.decode(invalid))
        }
    }

    func testHelloRequiresAdvertisedAuthenticatedCurrentGenerationOnce() {
        var state = CaptureAvailabilityState()
        state.begin(generation: 7)
        XCTAssertNil(state.hello(flags: 0, authenticated: true, generation: 7))
        XCTAssertNil(state.hello(flags: 0x0040, authenticated: false, generation: 7))
        XCTAssertNil(state.hello(flags: 0x0040, authenticated: true, generation: 6))
        XCTAssertEqual(state.hello(flags: 0x0040, authenticated: true, generation: 7), CaptureAvailabilityProtocol.hello)
        XCTAssertNil(state.hello(flags: 0x0040, authenticated: true, generation: 7))
        state.begin(generation: 8)
        XCTAssertFalse(state.inputBlocked)
        XCTAssertNil(state.notice)
        XCTAssertEqual(state.hello(flags: 0x0040, authenticated: true, generation: 8), CaptureAvailabilityProtocol.hello)
    }

    func testUnnegotiatedMalformedAndStaleStateHaveNoSideEffects() {
        var state = CaptureAvailabilityState()
        state.begin(generation: 7)
        let pause = CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1).encode()
        XCTAssertEqual(state.receive(pause, flags: 0, generation: 7), .ignored("unnegotiated"))
        _ = state.hello(flags: 0x0040, authenticated: true, generation: 7)
        XCTAssertEqual(state.receive(pause, flags: 1, generation: 7), .ignored("malformed"))
        XCTAssertEqual(state.receive(pause, flags: 0, generation: 6), .ignored("generation"))
        XCTAssertEqual(state.receive(pause, flags: 0, generation: 7), .suspended(retireInput: true))
        XCTAssertTrue(state.inputBlocked)
        XCTAssertEqual(state.notice, "Windows security prompt on PC")
        XCTAssertEqual(state.receive(pause, flags: 0, generation: 7), .ignored("stale"))
        XCTAssertEqual(state.receive(Data(), flags: 0, generation: 7), .ignored("malformed"))
        XCTAssertEqual(state.notice, "Windows security prompt on PC")
    }

    private func suspended() -> CaptureAvailabilityState {
        var state = CaptureAvailabilityState(); state.begin(generation: 7)
        _ = state.hello(flags: 0x0040, authenticated: true, generation: 7)
        _ = state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1).encode(), flags: 0, generation: 7)
        return state
    }

    func testResumeRequiresBothDecodeAndPresentationOfAdmittedFreshFrame() {
        for presentationFirst in [false, true] {
            var state = suspended()
            _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 2).encode(), flags: 0, generation: 7)
            XCTAssertTrue(state.inputBlocked)
            XCTAssertFalse(state.observeFrame(sequence: 9, decoder: 4, decoded: true, presented: true, generation: 7))
            XCTAssertFalse(state.admitFrame(sequence: 10, decoder: 4, isIDR: false, generation: 7))
            XCTAssertTrue(state.admitFrame(sequence: 11, decoder: 4, isIDR: true, generation: 7))
            XCTAssertFalse(state.observeFrame(sequence: 11, decoder: 4, decoded: !presentationFirst, presented: presentationFirst, generation: 7))
            XCTAssertTrue(state.inputBlocked)
            XCTAssertTrue(state.observeFrame(sequence: 11, decoder: 4, decoded: presentationFirst, presented: !presentationFirst, generation: 7))
            XCTAssertFalse(state.inputBlocked); XCTAssertNil(state.notice)
        }
    }

    func testFreshPresentedIDRCanResumeBeforeLateControlMessageButOldCompletionsCannot() {
        var state = CaptureAvailabilityState(); state.begin(generation: 7)
        _ = state.hello(flags: 0x0040, authenticated: true, generation: 7)
        XCTAssertTrue(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        _ = state.receive(CaptureAvailabilityCommand(state: 1, reason: 2, sequence: 0).encode(), flags: 0, generation: 7)
        XCTAssertEqual(state.notice, "PC screen temporarily unavailable")
        XCTAssertFalse(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 100, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertTrue(state.admitFrame(sequence: 101, decoder: 4, isIDR: true, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 101, decoder: 3, decoded: true, presented: true, generation: 7))
        XCTAssertTrue(state.observeFrame(sequence: 101, decoder: 4, decoded: true, presented: true, generation: 7))
        _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 1).encode(), flags: 0, generation: 7)
        XCTAssertNil(state.notice)
    }

    func testRouteSwitchRetainsSuspensionButNewAuthenticatedGenerationRequiresHelloAgain() {
        var state = suspended()
        XCTAssertTrue(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        state.resetMediaDomain()
        XCTAssertEqual(state.lastSequence, 1); XCTAssertTrue(state.negotiated); XCTAssertTrue(state.inputBlocked)
        XCTAssertFalse(state.observeFrame(sequence: 100, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertTrue(state.admitFrame(sequence: 0, decoder: 5, isIDR: true, generation: 7))
        XCTAssertTrue(state.observeFrame(sequence: 0, decoder: 5, decoded: true, presented: true, generation: 7))
        state.begin(generation: 8)
        XCTAssertNil(state.notice); XCTAssertFalse(state.negotiated)
        XCTAssertEqual(state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 2).encode(), flags: 0, generation: 7), .ignored("generation"))
        XCTAssertEqual(state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 0).encode(), flags: 0, generation: 8), .ignored("unnegotiated"))
    }

    func testRepeatedSuspensionRetiresOncePerEpisodeAndFencesEarlierResumeEvidence() {
        var state = suspended()
        XCTAssertEqual(state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 2).encode(), flags: 0, generation: 7), .suspended(retireInput: false))
        XCTAssertTrue(state.admitFrame(sequence: 1, decoder: 4, isIDR: true, generation: 7))
        XCTAssertTrue(state.observeFrame(sequence: 1, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertEqual(state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 3).encode(), flags: 0, generation: 7), .suspended(retireInput: true))
        XCTAssertFalse(state.observeFrame(sequence: 1, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertTrue(state.inputBlocked)
    }

    func testCatalogueRestoresConfirmedSameSourceOnlyWhenOptedInAndWaitsForFreshIDR() throws {
        for optedIn in [false, true] {
            var model = CaptureTargetState(); model.begin(generation: 7)
            _ = model.advertise(flags: 0x0400, generation: 7)
            func catalogue(_ revision: UInt64, epoch: UInt64 = 5, current: UInt64 = 4) -> CaptureTargetCatalogue {
                CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: revision, currentId: current,
                    epoch: epoch, entries: [CaptureTargetEntry(id: 4, kind: .physical, name: "Panel")])
            }
            _ = model.receiveCatalogue(catalogue(1), session: model.session)
            _ = model.select(4, catalogue: catalogue(1), session: model.session)
            _ = model.receiveCatalogue(catalogue(2), session: model.session)
            let applied = CaptureTargetResult(status: .applied, state: 1, kind: .physical, transaction: 1,
                owner: 2, revision: 2, currentId: 4, epoch: 5, source: 6, firstFrame: 20)
            XCTAssertTrue(model.receiveResult(applied, session: model.session))
            model.abandonPresentation(session: model.session, allowSameSourceReattach: optedIn)
            _ = model.receiveCatalogue(catalogue(3), session: model.session)
            XCTAssertEqual(model.applied != nil, optedIn)
            if optedIn {
                XCTAssertNil(model.pending); XCTAssertTrue(model.inputBlocked)
                XCTAssertFalse(model.observeRendered(sequence: 20, session: model.session))
                XCTAssertFalse(model.anchorReattachedSource(sequence: 21, isIDR: false))
                XCTAssertTrue(model.anchorReattachedSource(sequence: 22, isIDR: true))
                XCTAssertEqual(model.applied?.source, 6)
                XCTAssertEqual(model.applied?.transaction, 1)
                XCTAssertTrue(model.observeRendered(sequence: 22, session: model.session))
                model.abandonPresentation(session: model.session, allowSameSourceReattach: true)
                _ = model.receiveCatalogue(catalogue(4, current: 0), session: model.session)
                _ = model.receiveCatalogue(catalogue(5), session: model.session)
                XCTAssertNil(model.applied, "a different current target cannot resurrect an earlier owner")
            }
        }
    }

    func testCaptureFenceKeepsMirrorGrantAndOwnedTerminalsButRejectsNewInput() throws {
        let control = MirrorClientControl(); control.beginSession(7)
        _ = control.helloIfAdvertised(session: 7, flags: 0x4000)
        let geometry = MirrorGeometry(left: 0, top: 0, width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080)
        let active = MirrorControlState(revision: 1, epoch: 5, source: 6, mode: .active,
            token: MirrorToken(low: 7, high: 8), geometry: geometry, firstFrame: 0, lastSent: 10)
        _ = try control.receiveState(session: 7, data: MirrorControlCodec.encodeState(active))
        _ = control.observeRendered(session: 7, sequence: 0)
        let ticket = try XCTUnwrap(control.captureTicket())
        let pairs: [(MirrorInputKind, Data, Data)] = [
            (.keyboard, Data([1, 0, 17, 0]), Data([1, 1, 17, 0])),
            (.pointer, PointerInputCommand(action: .leftDown, x: 3, y: 4).encode(),
                PointerInputCommand(action: .leftUp, x: 3, y: 4).encode()),
            (.directTouch, DirectTouchContactCommand(phase: .down, pressure: 1, contactID: 9, x: 3, y: 4).encode(),
                DirectTouchContactCommand(phase: .cancel, pressure: 0, contactID: 9, x: 3, y: 4).encode()),
            (.pencil, NetworkManager.mirrorPencilPayload(type: .down, x: 3, y: 4, pressure: 1),
                NetworkManager.mirrorPencilPayload(type: .up, x: 3, y: 4, pressure: 0))]
        for (kind, down, _) in pairs { _ = try control.encodeInput(ticket: ticket, kind: kind, payload: down) }
        control.setCaptureSuspended(true)
        XCTAssertEqual(control.currentState, active); XCTAssertNil(control.captureTicket())
        for (kind, down, up) in pairs {
            XCTAssertThrowsError(try control.encodeInput(ticket: ticket, kind: kind, payload: down))
            XCTAssertNoThrow(try control.encodeInput(ticket: ticket, kind: kind, payload: up))
            XCTAssertThrowsError(try control.encodeInput(ticket: ticket, kind: kind, payload: up))
        }
        control.setCaptureSuspended(false)
        XCTAssertNotNil(control.captureTicket())
        for (kind, down, _) in pairs {
            XCTAssertThrowsError(try control.encodeInput(ticket: ticket, kind: kind, payload: down))
        }
    }

    func testNoticeAnnouncesOncePerEpisodeIncludingReasonChanges() {
        var announcement = CaptureAvailabilityAnnouncement()
        XCTAssertNil(announcement.update(nil))
        XCTAssertEqual(announcement.update("Windows security prompt on PC"), "Windows security prompt on PC")
        XCTAssertNil(announcement.update("Windows security prompt on PC"))
        XCTAssertNil(announcement.update("PC screen temporarily unavailable"))
        XCTAssertNil(announcement.update(nil))
        XCTAssertEqual(announcement.update("PC screen temporarily unavailable"), "PC screen temporarily unavailable")
    }

    func testTransientSameIdentityUnavailableMirrorDescriptorKeepsPictureButCannotRestoreInputGrant() throws {
        let control = MirrorClientControl(); control.beginSession(7)
        _ = control.helloIfAdvertised(session: 7, flags: 0x4000)
        let geometry = MirrorGeometry(left: 0, top: 0, width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080)
        func state(_ revision: UInt64, _ mode: MirrorControlMode) throws -> Data {
            try MirrorControlCodec.encodeState(MirrorControlState(revision: revision, epoch: 5, source: 6, mode: mode,
                token: MirrorToken(low: 0, high: 0), geometry: mode == .unavailable ? nil : geometry,
                firstFrame: mode == .unavailable ? nil : 0, lastSent: mode == .unavailable ? nil : 10))
        }
        _ = try control.receiveState(session: 7, data: state(1, .viewOnly))
        control.setCaptureSuspended(true)
        XCTAssertNil(try control.receiveState(session: 7, data: state(2, .unavailable)))
        XCTAssertTrue(control.permitsVideoSequence(1))
        control.setCaptureSuspended(false)
        XCTAssertNil(control.captureTicket())
        XCTAssertNotNil(try control.receiveState(session: 7, data: state(3, .viewOnly)))
    }

    func testMediaRouteRetainsAppliedSourceWithoutSelectingAgainAndOldOwnerCannotReattach() {
        var model = CaptureTargetState(); model.begin(generation: 7)
        _ = model.advertise(flags: 0x0400, generation: 7)
        func catalogue(_ revision: UInt64) -> CaptureTargetCatalogue {
            CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: revision, currentId: 4, epoch: 5,
                entries: [CaptureTargetEntry(id: 4, kind: .physical, name: "Panel")])
        }
        _ = model.receiveCatalogue(catalogue(1), session: model.session)
        _ = model.select(4, catalogue: catalogue(1), session: model.session)
        _ = model.receiveCatalogue(catalogue(2), session: model.session)
        _ = model.receiveResult(CaptureTargetResult(status: .applied, state: 1, kind: .physical, transaction: 1,
            owner: 2, revision: 2, currentId: 4, epoch: 5, source: 6, firstFrame: 100), session: model.session)
        let oldSession = model.session
        model.retireRoute(preserveAppliedSource: true)
        XCTAssertNotEqual(model.session, oldSession); XCTAssertEqual(model.applied?.source, 6)
        XCTAssertEqual(model.applied?.transaction, 1); XCTAssertFalse(model.unknownOutcome)
        XCTAssertNil(model.pending); XCTAssertTrue(model.inputBlocked)
        XCTAssertFalse(model.observeRendered(sequence: 100, session: oldSession))
        XCTAssertTrue(model.anchorReattachedSource(sequence: 0, isIDR: true))
        XCTAssertTrue(model.observeRendered(sequence: 0, session: model.session))
    }

    #if targetEnvironment(simulator)
    func testIntentionalSilenceDoesNotStartRecoveryOrSpendEpisodesAtAnyFakeTime() {
        let queue = DispatchQueue(label: "test.capture.availability.feedback")
        let receiver = WifiMediaReceiver(networkQueue: queue, decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in XCTFail("no audio") }, onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in XCTFail("capture silence is not transport failure") })
        queue.sync {
            receiver.simulateActivePacketSequenceForTesting(100, generation: 7)
            receiver.beginRecoveryEpisodeForTesting(at: 0)
            let episode = receiver.recoveryEpisodeForTesting
            receiver.setCaptureSuspended(true)
            for time in [0.1, 1, 5, 30, 600] {
                receiver.feedbackTimerTickForTesting(at: time)
                receiver.requestImmediateRecoveryFeedback(generation: 7)
                receiver.beginRecoveryEpisodeForTesting(at: time)
            }
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode)
            XCTAssertNil(receiver.recoveryEpisodeStartedAtForTesting)
            receiver.setCaptureSuspended(false)
            receiver.requestImmediateRecoveryFeedback(generation: 7)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode + 1)
        }
    }

    func testDecoderSuspensionFenceKeepsSessionAndNeverClearsRendererImage() {
        let decoder = DecoderManager(); decoder.beginSession(generation: 7)
        var rendererResets = 0
        decoder.onSessionBegan = { _ in rendererResets += 1 }
        let starts = decoder.sessionBeganCountForTesting, invalidations = decoder.invalidateCountForTesting
        decoder.fenceCaptureContinuation()
        XCTAssertEqual(decoder.currentSessionGeneration, 7)
        XCTAssertEqual(decoder.sessionBeganCountForTesting, starts)
        XCTAssertEqual(decoder.invalidateCountForTesting, invalidations)
        XCTAssertEqual(rendererResets, 0)
    }
    #endif

    func testSuspendedUnavailableCatalogueKeepsConfirmedPictureButActualRemovalWins() {
        var model = CaptureTargetState(); model.begin(generation: 7)
        _ = model.advertise(flags: 0x0400, generation: 7)
        let entry = CaptureTargetEntry(id: 4, kind: .physical, name: "Panel")
        func catalogue(_ revision: UInt64, available: Bool, entries: [CaptureTargetEntry]) -> CaptureTargetCatalogue {
            CaptureTargetCatalogue(state: available ? 1 : 3, allowed: true, owner: 2, revision: revision,
                currentId: available ? 4 : 0, epoch: 5, entries: entries)
        }
        let first = catalogue(1, available: true, entries: [entry])
        _ = model.receiveCatalogue(first, session: model.session)
        _ = model.select(4, catalogue: first, session: model.session)
        _ = model.receiveCatalogue(catalogue(2, available: true, entries: [entry]), session: model.session)
        let applied = CaptureTargetResult(status: .applied, state: 1, kind: .physical, transaction: 1, owner: 2,
            revision: 2, currentId: 4, epoch: 5, source: 6, firstFrame: 0)
        _ = model.receiveResult(applied, session: model.session)
        XCTAssertFalse(model.receiveCatalogue(catalogue(3, available: false, entries: [entry]), session: model.session,
            preservingSuspendedPresentation: true))
        XCTAssertEqual(model.applied, applied); XCTAssertEqual(model.confirmedCurrentId, 4)
        XCTAssertFalse(model.unknownOutcome)
        XCTAssertTrue(model.receiveCatalogue(catalogue(4, available: false, entries: []), session: model.session,
            preservingSuspendedPresentation: true))
    }

    func testQueuedInputPurgedAtSuspensionKeepsTerminalAndUnrelatedControlBehindActiveWrite() {
        let queue = DispatchQueue(label: "test.capture.availability.writer")
        var writes: [Data] = [], completions: [(NWError?) -> Void] = []
        let writer = ControlChannelWriter(queue: queue, sender: { data, _, done in writes.append(data); completions.append(done) })
        let text = ConnectionControlProtocol.frame(type: 40, payload: TextCommitCommand(text: "discard").encode()!)
        let down = ConnectionControlProtocol.frame(type: 38, payload: Data([1, 0, 17, 0]))
        let up = ConnectionControlProtocol.frame(type: 38, payload: Data([1, 1, 17, 0]))
        let ping = ConnectionControlProtocol.frame(type: 6, payload: Data(repeating: 0, count: 16))
        queue.sync {
            writer.begin(generation: 7)
            writer.enqueue(ping); writer.enqueue(down); writer.enqueue(text); writer.enqueue(up); writer.enqueue(ping)
            writer.discardPending(where: CaptureAvailabilityProtocol.isNewInputPacket)
            completions[0](nil)
        }
        queue.sync {}
        XCTAssertEqual(writes, [ping, up])
        completions[1](nil); queue.sync {}
        XCTAssertEqual(writes, [ping, up, ping])
    }

    func testOnlyPositiveFiniteDrawablePresentationTimeConfirmsOnscreenFrame() {
        for time in [0, -1, Double.infinity, Double.nan] {
            XCTAssertFalse(CapturePresentationPolicy.confirmed(time: time))
        }
        XCTAssertTrue(CapturePresentationPolicy.confirmed(time: 1))
    }

    func testSimulatorCompletionFallbackCannotResumeFailedOrSupersededFrameOrSkipDecode() {
        for succeeded in [false, true] {
            for current in [false, true] {
                var state = suspended()
                _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 2).encode(), flags: 0, generation: 7)
                XCTAssertTrue(state.admitFrame(sequence: 1, decoder: 4, isIDR: true, generation: 7))
                let presented = CapturePresentationPolicy.simulatorCompleted(succeeded: succeeded, current: current)
                XCTAssertFalse(state.observeFrame(sequence: 1, decoder: 4, decoded: false, presented: presented, generation: 7))
                XCTAssertTrue(state.inputBlocked, "GPU completion alone cannot skip decode evidence")
                XCTAssertEqual(state.observeFrame(sequence: 1, decoder: 4, decoded: true, presented: false, generation: 7), succeeded && current)
                XCTAssertEqual(state.inputBlocked, !(succeeded && current))
            }
        }
    }

    func testSharedRawTouchLayoutPurgesStartsButKeepsOwnedTerminalLane() {
        XCTAssertEqual(TouchWireProtocol.magic, 0x5449)
        XCTAssertEqual(TouchWireProtocol.packetSize, 8)
        let down = NetworkManager.mirrorPencilPayload(type: .down, x: 3, y: 4, pressure: 1)
        let up = NetworkManager.mirrorPencilPayload(type: .up, x: 3, y: 4, pressure: 0)
        XCTAssertEqual(down.count, TouchWireProtocol.packetSize)
        XCTAssertTrue(CaptureAvailabilityProtocol.isNewInputPacket(down))
        XCTAssertFalse(CaptureAvailabilityProtocol.isNewInputPacket(up))
    }

    func testParserDrainsMalformedAvailabilityAndContinues() {
        let parser = WireStreamParser(generation: 7)
        var failures = 0, discarded = 0, messages = 0
        let malformed = ConnectionControlProtocol.frame(type: 81, payload: Data([1, 1, 0]))
        let valid = ConnectionControlProtocol.frame(type: 81, payload: Data([1, 1, 0, 0, 1, 0, 0, 0]))
        parser.consume(malformed + valid, generation: 7) { event in
            switch event {
            case .failure: failures += 1
            case .discardedFixedControl: discarded += 1
            case .message: messages += 1
            }
        }
        XCTAssertEqual(failures, 0); XCTAssertEqual(discarded, 1); XCTAssertEqual(messages, 1)
    }
    #if targetEnvironment(simulator)
    @MainActor private func drain(_ network: NetworkManager) async {
        for _ in 0..<4 {
            network.networkQueueForTesting.sync {}
            let done = expectation(description: "availability publication")
            DispatchQueue.main.async { done.fulfill() }
            await fulfillment(of: [done], timeout: 2)
        }
        network.networkQueueForTesting.sync {}
    }

    @MainActor func testActualTypedPauseKeepsDecoderAndSourceOnBothVideoPathsAndResumesOnlyAfterPresentation() async throws {
        for rtp in [false, true] {
          for physical in [false, true] {
            let network = NetworkManager(); var writes: [Data] = [], decoded: [(UInt32, UInt64)] = []
            network.realtimeAudioPlaybackForTesting = { _ in XCTFail("capture availability tests must never start audio") }
            network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
            network.captureTargetDecodeForTesting = { _, sequence, decoder in decoded.append((sequence, decoder)) }
            network.captureTargetScheduleForTesting = { _, _ in }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: rtp ? RealtimeTransportMode.wifiRTP : RealtimeTransportMode.legacyTLS)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags, sequence: sequence,
                    generation: peer.generation, connection: peer.connection)
            }
            receive(.displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x7c40)
            receive(.displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x7c40)
            receive(.mirrorState, try CaptureTargetIntegrationTests.mode(revision: 1, epoch: 2, physical: false))
            receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 3, current: 1))
            await drain(network)
            XCTAssertEqual(writes.filter { $0[5] == 80 }.count, 1)
            network.requestCaptureTarget(physical ? 4 : 1, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
            await drain(network)
            receive(.sourceSwitchResult, CaptureTargetIntegrationTests.result(status: 9, revision: 3, current: 0))
            receive(.mirrorState, try CaptureTargetIntegrationTests.mode(revision: 2, epoch: physical ? 5 : 3, physical: physical))
            receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 4, current: physical ? 14 : 11, virtualId: 11, physicalId: 14))
            receive(.sourceSwitchResult, CaptureTargetIntegrationTests.result(kind: physical ? 1 : 0, current: physical ? 14 : 11))
            func video(_ sequence: UInt32, idr: Bool) {
                if rtp {
                    network.receiveCaptureTargetVideoForTesting(Data([1]), sequence: sequence, isIDR: idr,
                        generation: peer.generation, connection: peer.connection)
                } else { receive(.video, Data([1]), flags: idr ? 3 : 2, sequence: sequence) }
            }
            video(0, idr: true)
            let owner = try XCTUnwrap(decoded.first?.1)
            network.recordRenderCompletion(sequence: 0, generation: owner); await drain(network)
            if physical {
                receive(.mirrorState, try CaptureTargetIntegrationTests.mode(revision: 3, epoch: 5, physical: true, active: true))
                await drain(network)
            }
            let ticket = network.mirrorTicketAtRegistration
            XCTAssertEqual(ticket != nil, physical)
            let applied = network.captureTargetState.applied
            let starts = network.decoder.sessionBeganCountForTesting, invalidations = network.decoder.invalidateCountForTesting
            var retired = 0
            network.captureTargetRetireInput = {
                retired += 1
                let up = KeyboardInputCommand(action: .keyUp, virtualKey: 17)
                if let ticket { network.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: up.encode()) }
                else { network.sendKeyboardInput(up) }
            }
            let down = KeyboardInputCommand(action: .keyDown, virtualKey: 17)
            if let ticket { network.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: down.encode()) }
            else { network.sendKeyboardInput(down) }
            await drain(network)
            receive(.captureAvailability, CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1).encode()); await drain(network)
            receive(.captureAvailability, CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 2).encode()); await drain(network)
            XCTAssertEqual(retired, 1); XCTAssertEqual(network.captureTargetState.applied, applied)
            XCTAssertEqual(network.captureTargetDecoderForTesting, owner)
            XCTAssertEqual(network.decoder.sessionBeganCountForTesting, starts)
            XCTAssertEqual(network.decoder.invalidateCountForTesting, invalidations)
            XCTAssertTrue(network.captureInputBlocked); XCTAssertFalse(network.permitsLegacyVirtualInput)
            XCTAssertEqual(network.captureAvailabilityNotice, "Windows security prompt on PC")
            let before = writes.count
            network.sendKeyboardInput(KeyboardInputCommand(action: .keyDown, virtualKey: 65)); network.sendTextCommit("discard")
            if let ticket { network.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: down.encode()) }
            video(1, idr: false); await drain(network)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertFalse(writes.dropFirst(before).contains { $0[5] == 38 || $0[5] == 40 || $0[5] == 53 })
            receive(.captureAvailability, CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 3).encode()); await drain(network)
            XCTAssertTrue(network.captureInputBlocked)
            video(2, idr: true)
            network.decoder.onDecodeCompleted?(2, owner, true); await drain(network)
            XCTAssertTrue(network.captureInputBlocked)
            network.recordRenderCompletion(sequence: 2, generation: owner); await drain(network)
            XCTAssertTrue(network.captureInputBlocked, "GPU completion alone is not onscreen presentation")
            network.recordCapturePresentation(sequence: 2, generation: owner); await drain(network)
            XCTAssertNil(network.captureAvailabilityNotice); XCTAssertFalse(network.captureInputBlocked)
            XCTAssertEqual(network.permitsLegacyVirtualInput, !physical); XCTAssertEqual(network.captureTargetState.applied, applied)
            XCTAssertEqual(writes.filter { $0[5] == 74 }.count, 1)
            let keys = writes.compactMap { data -> Data? in
                if data[5] == 38 { return Data(data.dropFirst(16)) }
                if data[5] == 53 { return Data(data.suffix(4)) }
                return nil
            }
            XCTAssertEqual(keys, [Data([1, 0, 17, 0]), Data([1, 1, 17, 0])])
            // Exercise the former abandonPresentation trap through real dispatch: the
            // refreshed catalogue still names the confirmed target/source, with no new tap.
            if physical {
                receive(.mirrorState, try CaptureTargetIntegrationTests.mode(revision: 4, epoch: 6, physical: true))
            } else {
                receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 5, current: 11, epoch: 6,
                    virtualId: 11, physicalId: 14))
            }
            receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 6, current: physical ? 14 : 11,
                epoch: 6, virtualId: 11, physicalId: 14))
            await drain(network)
            XCTAssertNil(network.captureTargetState.pending)
            XCTAssertFalse(network.captureTargetState.unknownOutcome)
            XCTAssertEqual(network.captureTargetState.applied?.source, applied?.source)
            XCTAssertEqual(network.captureTargetState.applied?.currentId, applied?.currentId)
            XCTAssertEqual(network.captureTargetState.applied?.transaction, applied?.transaction)
            video(3, idr: true)
            let reattached = try XCTUnwrap(decoded.last?.1)
            XCTAssertNotEqual(reattached, owner)
            network.recordRenderCompletion(sequence: 3, generation: reattached); await drain(network)
            XCTAssertFalse(network.captureTargetState.inputBlocked)
            XCTAssertEqual(writes.filter { $0[5] == 74 }.count, 1)
          }
        }
    }

    @MainActor func testActualSuspensionSpansMediaRouteAndReconnectWithFreshNegotiationAndStaleCallbackFence() async {
        let network = NetworkManager(); var writes: [Data] = []
        network.realtimeAudioPlaybackForTesting = { _ in XCTFail("no audio") }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        let first = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes,
            flags: 0x0040, generation: first.generation, connection: first.connection)
        network.receiveCaptureTargetWireForTesting(type: .captureAvailability,
            payload: CaptureAvailabilityCommand(state: 1, reason: 2, sequence: 5).encode(),
            generation: first.generation, connection: first.connection)
        await drain(network)
        network.setCommittedRealtimeModeForTesting(RealtimeTransportMode.wifiRTP); await drain(network)
        XCTAssertTrue(network.captureInputBlocked)
        XCTAssertEqual(network.captureAvailabilityNotice, "PC screen temporarily unavailable")
        network.receiveCaptureTargetWireForTesting(type: .captureAvailability,
            payload: CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 4).encode(),
            generation: first.generation, connection: first.connection)
        await drain(network); XCTAssertTrue(network.captureInputBlocked)
        network.stopForTesting(); await drain(network)
        let next = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting(); await drain(network)
        XCTAssertNil(network.captureAvailabilityNotice); XCTAssertFalse(network.captureInputBlocked)
        network.receiveCaptureTargetWireForTesting(type: .captureAvailability,
            payload: CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 6).encode(),
            generation: first.generation, connection: first.connection)
        await drain(network); XCTAssertNil(network.captureAvailabilityNotice)
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes,
            flags: 0x0040, generation: next.generation, connection: next.connection)
        network.receiveCaptureTargetWireForTesting(type: .captureAvailability,
            payload: CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 0).encode(),
            generation: next.generation, connection: next.connection)
        await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == 80 }.count, 2)
        XCTAssertEqual(network.captureAvailabilityNotice, "Windows security prompt on PC")
    }

    @MainActor func testQueuedTextIsDiscardedAcrossCompleteLocalPauseBeforeQueueAdmission() async {
        let network = NetworkManager(); var writes: [Data] = []
        network.realtimeAudioPlaybackForTesting = { _ in XCTFail("no audio") }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.networkQueueForTesting.sync {
            network.sendTextCommit("discard")
            network.setMirrorInputForeground(false)
            network.setMirrorInputForeground(true)
        }
        await drain(network)
        XCTAssertFalse(writes.contains { $0[5] == 40 })
    }

    @MainActor func testActualOldHostNeverNegotiatesOrFencesOnUnsolicitedAvailability() async {
        let network = NetworkManager(); var writes: [Data] = []
        network.realtimeAudioPlaybackForTesting = { _ in XCTFail("no audio") }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes,
            generation: peer.generation, connection: peer.connection)
        network.receiveCaptureTargetWireForTesting(type: .captureAvailability,
            payload: CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1).encode(),
            generation: peer.generation, connection: peer.connection)
        await drain(network)
        XCTAssertFalse(writes.contains { $0[5] == 80 }); XCTAssertNil(network.captureAvailabilityNotice)
        XCTAssertFalse(network.captureInputBlocked)
    }
    #endif

}
