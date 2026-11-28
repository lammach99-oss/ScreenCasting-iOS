import XCTest
import Network
import UIKit
@testable import iPadCasting

final class SecureDesktopRecoveryTests: XCTestCase {
    func testSecureSoftwareScanMapping() {
        var events: [RemoteScanKeyCommand] = []
        let dropped = SecureSoftwareKeyboard.emit("aZ0!_? \u{8}\r\t\n", token: 7) { events.append($0) }
        XCTAssertEqual(dropped, 0)
        let strokes: [(UInt16, Bool)] = [(30,false),(44,true),(11,false),(2,true),(12,true),
                                         (53,true),(57,false),(14,false),(28,false),(15,false),(28,false)]
        var expected: [RemoteScanKeyCommand] = []
        for (scan, shifted) in strokes {
            if shifted { expected.append(.init(action: 0, flags: 0, scan: 42, token: 7)) }
            expected.append(.init(action: 0, flags: 0, scan: scan, token: 7))
            expected.append(.init(action: 1, flags: 0, scan: scan, token: 7))
            if shifted { expected.append(.init(action: 1, flags: 0, scan: 42, token: 7)) }
        }
        XCTAssertTrue(events == expected)
        for byte in UInt8(32)...126 {
            let symbol = String(UnicodeScalar(byte))
            var strokes = 0
            let drops = SecureSoftwareKeyboard.emit(symbol, token: 7) { _ in strokes += 1 }
            XCTAssertEqual(drops, 0)
            XCTAssertTrue(strokes == 2 || strokes == 4)
        }
    }

    func testMixedSecureInsertionRejectsOnceWithoutSendingAnyScans() {
        var notices = [String]()
        _ = SecureSoftwareKeyboard.emit("x\u{e9}y", token: 7, rejected: { notices.append($0) }) { _ in
            XCTFail("Rejected insertion emitted a scan")
        }
        XCTAssertEqual(notices, ["That character can't be typed on the sign-in screen."])
    }

    @MainActor func testSecureKeyboardShowsLayoutHintOnlyDuringSecureEntry() {
        let view = RemoteSoftwareKeyboardTextView(frame: .zero, textContainer: nil)
        view.secureEntry = true
        XCTAssertEqual((view.inputAccessoryView as? UILabel)?.text,
                       "Types with a US keyboard layout. Check Caps Lock on the PC.")
        view.secureEntry = false
        XCTAssertNil(view.inputAccessoryView)
    }

    func testSoftwareDispatchSelectsExactlyOneSink() {
        for route in [SecureSoftwareKeyboard.Route.committed, .blocked, .scan] {
            var scans = 0, commits = 0
            route.deliver("x", scan: { _ in scans += 1 }, commit: { _ in commits += 1 })
            XCTAssertEqual(scans, route == .scan ? 1 : 0)
            XCTAssertEqual(commits, route == .committed ? 1 : 0)
        }
    }

    @MainActor func testSecureSoftwareEntryBypassesCorrectionHistory() {
        let view = RemoteSoftwareKeyboardTextView(frame: .zero, textContainer: nil)
        view.secureEntry = true
        view.deliveryEnabled = true
        XCTAssertTrue(view.hasText)
        XCTAssertEqual(view.autocapitalizationType, .none)
        var emissions = 0
        view.onEmission = { _ in emissions += 1 }
        view.insertText("a")
        view.deleteBackward()
        XCTAssertEqual(emissions, 2)
        XCTAssertTrue(view.text.isEmpty)
    }

    func testRemoteSecureDesktopOptInAndOldHostFallback() throws {
        for enabled in [false, true] {
            var features = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
            XCTAssertTrue(features.begin(now: 0))
            let request = try XCTUnwrap(features.pong(flags: 0x4000, now: 1, requestSecureDesktop: enabled))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, enabled ? 0xc1f : 0x1f)
            XCTAssertTrue(features.result(flags: 0, payload: RemoteFeaturesMessage(features: 0x1f).encode()))
            var secure = RemoteSecureDesktopState()
            XCTAssertNil(secure.begin(accepted: features.accepted, control: true))
            XCTAssertFalse(secure.covered)
            XCTAssertEqual(secure.softwareRoute, .committed)
            XCTAssertTrue(secure.canSas)
        }
    }

    func testPhoneKeyboardRequiresAdmittedScanInputOnWinlogon() {
        func enabled(_ route: SecureSoftwareKeyboard.Route, _ desktop: UInt8,
                     _ ready: Bool, _ features: UInt64 = 1) -> Bool {
            route.phoneKeyboardAvailable(desktop: desktop, features: features, ready: ready, legacy: true)
        }
        XCTAssertTrue(enabled(.committed, 1, false, 0))
        XCTAssertFalse(enabled(.committed, 2, true))
        XCTAssertFalse(enabled(.blocked, 2, true))
        XCTAssertFalse(enabled(.scan, 2, false))
        XCTAssertFalse(enabled(.scan, 2, true, 2))
        XCTAssertTrue(enabled(.scan, 2, true))
    }

    func testPhoneRequestsSecureFeaturesOnlyWithPreference() throws {
        let mask = ClientDeviceCapabilities.resolve(.phone).remoteInputFeatureMask
        for enabled in [false, true] {
            var features = RemoteFeatureNegotiation(requestedFeatures: mask)
            XCTAssertTrue(features.begin(now: 0))
            let request = try XCTUnwrap(features.pong(flags: 0x4000, now: 1, requestSecureDesktop: enabled))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, enabled ? 0xc17 : 0x17)
        }
    }

    func testRemoteSasAvailabilityGrantRequiresSecureDesktop() throws {
        for (grant, valid) in [(UInt64(0x400), true), (0xc00, true), (0x800, false)] {
            var features = RemoteFeatureNegotiation()
            XCTAssertTrue(features.begin(now: 0))
            _ = try XCTUnwrap(features.pong(flags: 0x4000, now: 1, requestSecureDesktop: true))
            XCTAssertEqual(features.result(flags: 0, payload: RemoteFeaturesMessage(features: grant).encode()), valid)
            XCTAssertEqual(features.accepted, valid ? grant : 0)
        }
    }

    func testDefaultSasRequiresCurrentAvailabilityAndControl() {
        var secure = RemoteSecureDesktopState()
        _ = secure.begin(accepted: 0xc00, control: false)
        XCTAssertFalse(secure.canSas)
        secure.updateSasAvailability(true)
        XCTAssertFalse(secure.canSas)
        _ = secure.setControl(true)
        XCTAssertFalse(secure.canSas)
        secure.updateSasAvailability(true)
        XCTAssertTrue(secure.canSas)
        secure.updateSasAvailability(false)
        XCTAssertFalse(secure.canSas)
        secure.updateSasAvailability(true)
        _ = secure.setControl(false)
        XCTAssertFalse(secure.canSas)
        _ = secure.setControl(true)
        XCTAssertFalse(secure.canSas)
        secure.updateSasAvailability(true)
        _ = secure.begin(accepted: 0xc00, control: true)
        XCTAssertFalse(secure.canSas)
        _ = secure.begin(accepted: 0x400, control: true)
        secure.updateSasAvailability(true)
        XCTAssertFalse(secure.canSas)
    }

    func testRemoteSecureDesktopRevealsAndAcknowledgesOnlyPresentedIDR() {
        var secure = RemoteSecureDesktopState()
        XCTAssertEqual(secure.begin(accepted: 0x400, control: true),
            .request(operation: .controlOn, videoSequence: 0, captureRevision: 0, sourceEpoch: 0))
        XCTAssertEqual(secure.receive(remoteState(.winlogon, .firstFrame, revision: 3, epoch: 7, sequence: 21),
            adaptiveOwner: false, timedVideo: false), .fence)
        XCTAssertEqual(secure.softwareRoute, .blocked)
        XCTAssertTrue(secure.covered)
        XCTAssertFalse(secure.canSas)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .barrier)
        XCTAssertTrue(secure.covered)
        XCTAssertEqual(secure.admit(sequence: 22, isIDR: false, decoder: 4), .drop)
        XCTAssertNil(secure.presented(sequence: 22, decoder: 4))
        XCTAssertNil(secure.presented(sequence: 21, decoder: 3))
        let ack = secure.presented(sequence: 21, decoder: 4)
        XCTAssertEqual(ack, .request(operation: .presented, videoSequence: 21, captureRevision: 3, sourceEpoch: 7))
        XCTAssertFalse(secure.covered)
        XCTAssertFalse(secure.canSas)
        XCTAssertEqual(secure.softwareRoute, .blocked)
        XCTAssertNotNil(ack)
        if let ack { XCTAssertTrue(secure.admitRequest(ack)) }
        XCTAssertTrue(secure.canSas)
        XCTAssertEqual(secure.softwareRoute, .scan)
        XCTAssertNil(secure.presented(sequence: 21, decoder: 4))
        XCTAssertEqual(secure.admit(sequence: 23, isIDR: false, decoder: 4), .drop)
        XCTAssertEqual(secure.admit(sequence: 24, isIDR: true, decoder: 4), .pass)
        _ = secure.receive(remoteState(.winlogon, .hidden, revision: 4, epoch: 7, sequence: 0),
                           adaptiveOwner: false, timedVideo: false)
        XCTAssertTrue(secure.covered)
        XCTAssertEqual(secure.softwareRoute, .blocked)
    }

    func testRemoteSecureDesktopRejectsWrongPairAndKeepsCoverOnRevocation() {
        var secure = RemoteSecureDesktopState()
        _ = secure.begin(accepted: 0x400, control: true)
        let first = remoteState(.winlogon, .firstFrame, revision: 3, epoch: 7, sequence: 21)
        _ = secure.receive(first, adaptiveOwner: false, timedVideo: false)
        XCTAssertEqual(secure.admit(sequence: 20, isIDR: true, decoder: 4), .invalid)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: false, decoder: 4), .invalid)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .barrier)
        XCTAssertEqual(secure.setControl(false),
            .request(operation: .controlOff, videoSequence: 0, captureRevision: 0, sourceEpoch: 0))
        XCTAssertNil(secure.presented(sequence: 21, decoder: 4))
        XCTAssertEqual(secure.softwareRoute, .blocked)
        _ = secure.setControl(true)
        XCTAssertEqual(secure.receive(first, adaptiveOwner: false, timedVideo: false), .unchanged)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .drop)
        XCTAssertTrue(secure.covered)
        XCTAssertFalse(secure.canSas)
    }

    func testRemoteSecureDesktopSasStaysDisabledForVideoOnlyGrant() throws {
        var secure = RemoteSecureDesktopState()
        _ = secure.begin(accepted: 0xc00, control: true)
        let publication = RemoteSecureDesktopProtocol.Message.state(
            desktop: .winlogon, phase: .firstFrame, backend: .dxgi, permissions: .video, reason: .none,
            captureRevision: 3, sourceEpoch: 7, firstVideoSequence: 21)
        XCTAssertEqual(secure.receive(publication, adaptiveOwner: false, timedVideo: false), .fence)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .barrier)
        let ack = try XCTUnwrap(secure.presented(sequence: 21, decoder: 4))
        XCTAssertTrue(secure.admitRequest(ack))
        secure.updateSasAvailability(true)
        XCTAssertFalse(secure.covered)
        XCTAssertFalse(secure.canSas)
        XCTAssertFalse(secure.allowsScanAndPointer)
        XCTAssertEqual(secure.softwareRoute, .blocked)
    }

    func testRemoteSecureDesktopReconnectsAdaptiveOwnerOrTimedVideo() {
        let hidden = remoteState(.winlogon, .hidden, revision: 2, epoch: 5, sequence: 0)
        for (adaptive, timed) in [(true, false), (false, true), (false, false)] {
            var secure = RemoteSecureDesktopState()
            _ = secure.begin(accepted: 0x400, control: false)
            XCTAssertEqual(secure.receive(hidden, adaptiveOwner: adaptive, timedVideo: timed),
                adaptive || timed ? .reconnect : .fence)
            XCTAssertEqual(secure.admit(sequence: 20, isIDR: true, decoder: 4), .drop)
        }
    }

    func testRemoteSecureDesktopUnrequestedGrantIsRejected() {
        var features = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
        XCTAssertTrue(features.begin(now: 0))
        XCTAssertNotNil(features.pong(flags: 0x4000, now: 1))
        XCTAssertFalse(features.result(flags: 0, payload: RemoteFeaturesMessage(features: 0x41f).encode()))
    }

    func testRemoteSecureDesktopControlOffDropsWinlogonPairButAllowsDefaultRecovery() {
        var secure = RemoteSecureDesktopState()
        _ = secure.begin(accepted: 0x400, control: false)
        XCTAssertEqual(secure.observeDesktop(.winlogon, adaptiveOwner: false, timedVideo: false), .fence)
        XCTAssertEqual(secure.admit(sequence: 20, isIDR: true, decoder: 4), .drop)
        _ = secure.receive(remoteState(.winlogon, .firstFrame, revision: 3, epoch: 7, sequence: 21),
            adaptiveOwner: false, timedVideo: false)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .drop)
        XCTAssertNil(secure.presented(sequence: 21, decoder: 4))
        XCTAssertTrue(secure.covered)

        _ = secure.receive(remoteState(.standard, .firstFrame, revision: 4, epoch: 8, sequence: 22),
            adaptiveOwner: false, timedVideo: false)
        XCTAssertEqual(secure.admit(sequence: 22, isIDR: true, decoder: 5), .barrier)
        XCTAssertEqual(secure.presented(sequence: 22, decoder: 5),
            .request(operation: .presented, videoSequence: 22, captureRevision: 4, sourceEpoch: 8))
        XCTAssertFalse(secure.covered)
        XCTAssertFalse(secure.canSas)
    }

    func testRemoteSecureDesktopRequiresAnActualHEVCIDR() {
        XCTAssertTrue(RemoteSecureDesktopState.hasIDR(Data([0, 0, 1, 38, 1, 0x80]), lengthPrefixed: false))
        XCTAssertTrue(RemoteSecureDesktopState.hasIDR(Data([0, 0, 0, 3, 40, 1, 0x80]), lengthPrefixed: true))
        XCTAssertFalse(RemoteSecureDesktopState.hasIDR(Data([0, 0, 1, 42, 1, 0x80]), lengthPrefixed: false))
        XCTAssertFalse(RemoteSecureDesktopState.hasIDR(Data([0, 0, 0, 4, 40, 1, 0x80]), lengthPrefixed: true))
    }

    func testRemoteSecureDesktopRetiresQueuedAckWhenPublicationChanges() throws {
        var secure = RemoteSecureDesktopState()
        _ = secure.begin(accepted: 0x400, control: true)
        _ = secure.receive(remoteState(.winlogon, .firstFrame, revision: 3, epoch: 7, sequence: 21),
            adaptiveOwner: false, timedVideo: false)
        XCTAssertEqual(secure.admit(sequence: 21, isIDR: true, decoder: 4), .barrier)
        let ack = try XCTUnwrap(secure.presented(sequence: 21, decoder: 4))
        _ = secure.receive(remoteState(.winlogon, .hidden, revision: 4, epoch: 7, sequence: 0),
            adaptiveOwner: false, timedVideo: false)
        XCTAssertFalse(secure.admitRequest(ack))
        XCTAssertTrue(secure.covered)
        XCTAssertFalse(secure.canSas)
    }

    func testRemoteSecureDesktopParserRequiresNegotiatedStateHeader() throws {
        let payload = try XCTUnwrap(RemoteSecureDesktopProtocol.encode(
            remoteState(.winlogon, .hidden, revision: 2, epoch: 5, sequence: 0)))
        let frame = ConnectionControlProtocol.frame(type: 109, payload: payload)
        let unnegotiated = WireStreamParser(generation: 1)
        var rejected = false
        unnegotiated.consume(Data(frame.prefix(WireProtocol.headerSize)), generation: 1) {
            if case .failure(.invalidHeader) = $0 { rejected = true }
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(unnegotiated.allocatedPayloadBytes, 0)

        let parser = WireStreamParser(generation: 1, allowsSecureDesktop: { true })
        var received = 0
        parser.consume(frame, generation: 1) {
            guard case let .message(message) = $0 else { return XCTFail("Expected DS7 State") }
            XCTAssertEqual(message.header.type, .remoteSecureDesktopState)
            XCTAssertEqual(message.payload, payload)
            received += 1
        }
        XCTAssertEqual(received, 1)

        let malformed = ConnectionControlProtocol.frame(type: 109, payload: Data(count: 31))
        parser.consume(Data(malformed.prefix(WireProtocol.headerSize)), generation: 1) {
            if case .failure(.invalidHeader) = $0 { received += 1 }
        }
        XCTAssertEqual(received, 2)
        XCTAssertEqual(parser.allocatedPayloadBytes, 0)
    }

    private func remoteState(_ desktop: RemoteSecureDesktopProtocol.Desktop, _ phase: RemoteSecureDesktopProtocol.Phase,
                             revision: UInt64, epoch: UInt64, sequence: UInt32) -> RemoteSecureDesktopProtocol.Message {
        .state(desktop: desktop, phase: phase, backend: phase == .firstFrame ? .dxgi : .none,
               permissions: phase == .firstFrame ? (desktop == .winlogon ? .videoAndInputAfterPresented : .video) : .none,
               reason: phase == .hidden ? .noControl : .none, captureRevision: revision,
               sourceEpoch: epoch, firstVideoSequence: sequence)
    }

    func testDecoderFenceDropsCompletedOldOutputAndAllowsOnlyPostResumeReceipt() {
        let decoder = DecoderManager(); decoder.beginSession(generation: 7)
        var delivered: [UInt32] = [], fences: [UInt64] = []
        decoder.onCaptureFenced = { fences.append($0) }
        decoder.deliverCaptureOutput(sequence: 99, generation: 7) { delivered.append(99) }
        decoder.fenceCaptureContinuation()
        XCTAssertEqual(fences, [7])
        decoder.deliverCaptureOutput(sequence: 100, generation: 7) { delivered.append(100) }
        XCTAssertEqual(delivered, [99])
        decoder.authorizeCaptureOutput(sequence: 101, generation: 7)
        decoder.deliverCaptureOutput(sequence: 101, generation: 8) { delivered.append(999) }
        decoder.deliverCaptureOutput(sequence: 101, generation: 7) { delivered.append(101) }
        XCTAssertEqual(delivered, [99, 101])
        decoder.beginSession(generation: 8)
        XCTAssertEqual(fences, [7, 8], "a decoder re-anchor must preserve the suspension fence")
        decoder.deliverCaptureOutput(sequence: 102, generation: 8) { delivered.append(102) }
        XCTAssertEqual(delivered, [99, 101])
        decoder.resetCaptureOutputFence()
        decoder.deliverCaptureOutput(sequence: 103, generation: 8) { delivered.append(103) }
        XCTAssertEqual(delivered, [99, 101, 103], "a disconnected generation cannot fence an old host forever")
    }
    func testRenderFenceRetiresQueuedAndTakenFramesButKeepsShownWatermark() throws {
        var tracker = RenderFreshnessTracker(); tracker.beginSession(generation: 7)
        _ = tracker.offer(99, generation: 7)
        let shown = try XCTUnwrap(tracker.takePending())
        XCTAssertTrue(tracker.markPresented(shown))
        _ = tracker.offer(100, generation: 7)
        let taken = try XCTUnwrap(tracker.takePending())
        _ = tracker.offer(101, generation: 7)
        tracker.fenceCaptureContinuation()
        XCTAssertEqual(tracker.sessionGeneration, 7)
        XCTAssertEqual(tracker.presentedSequence, 99)
        XCTAssertNil(tracker.takePending())
        XCTAssertFalse(tracker.isCurrent(taken)); XCTAssertFalse(tracker.markPresented(taken))
        _ = tracker.offer(102, generation: 7)
        let fresh = try XCTUnwrap(tracker.takePending())
        XCTAssertEqual(tracker.commitDecision(for: fresh), .commit)
    }

    func testActiveClockPausesEveryRoutePhaseAndResumesItsRemainingBudget() throws {
        for stage in 0...2 {
            var clock = CaptureReadinessClock()
            var state = ConnectionSwitchState(); state.begin(generation: 1)
            _ = state.advertise(flags: 0x0200, authenticated: true, generation: 1)
            _ = state.receive(try ConnectionSwitchStateTests.snapshot(), generation: 1, now: clock.now(at: 0))
            XCTAssertNotNil(state.select(.usb, now: clock.now(at: 0)))
            if stage > 0 {
                _ = state.preparing(try ConnectionSwitchStateTests.prepare(), generation: 1, now: clock.now(at: 1))
                _ = state.receive(try ConnectionSwitchStateTests.snapshot(revision: 3, hostState: .switching), generation: 1, now: clock.now(at: 1))
                XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.result(.accepted), generation: 1, now: clock.now(at: 1)))
            }
            if stage == 2 {
                XCTAssertTrue(state.bindReplacement(generation: 2, route: .usb, authenticated: true, now: clock.now(at: 2)))
                _ = state.advertise(flags: 0x0200, authenticated: true, generation: 2)
                _ = state.receive(try ConnectionSwitchStateTests.snapshot(revision: 3, owner: 2, route: .usb), generation: 2, now: clock.now(at: 2))
                XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.result(.completed), generation: 2, now: clock.now(at: 4)))
            }
            clock.setSuspended(true, at: 4)
            for wall in [100.0, 600, 900] {
                state.tick(now: clock.now(at: wall))
                XCTAssertNotNil(state.pending, "suspension must not expire any route phase")
            }
            // Remain paused through the resumed-picture wait, not merely wire state 0.
            XCTAssertEqual(clock.now(at: 1000), 4)
            clock.setSuspended(false, at: 1000)
            let remaining = stage == 0 ? 11.0 : stage == 1 ? 71.0 : 5.0
            state.tick(now: clock.now(at: 1000 + remaining - 0.01))
            XCTAssertNotNil(state.pending)
            state.tick(now: clock.now(at: 1000 + remaining))
            XCTAssertNil(state.pending); XCTAssertTrue(state.offersReconnect)
        }
    }

    func testDisconnectUnfreezesActiveClockWithoutBackwardsTimeForRetainedHandoff() {
        var clock = CaptureReadinessClock()
        clock.setSuspended(true, at: 10)
        XCTAssertEqual(clock.now(at: 610), 10)
        clock.setSuspended(false, at: 610)
        XCTAssertEqual(clock.now(at: 615), 15)
    }

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
            state.noteFrameReceived(sequence: 10)
            XCTAssertFalse(state.admitFrame(sequence: 10, decoder: 4, isIDR: false, generation: 7))
            state.noteFrameReceived(sequence: 11)
            XCTAssertTrue(state.admitFrame(sequence: 11, decoder: 4, isIDR: true, generation: 7))
            XCTAssertFalse(state.observeFrame(sequence: 11, decoder: 4, decoded: !presentationFirst, presented: presentationFirst, generation: 7))
            XCTAssertTrue(state.inputBlocked)
            XCTAssertTrue(state.observeFrame(sequence: 11, decoder: 4, decoded: presentationFirst, presented: !presentationFirst, generation: 7))
            XCTAssertFalse(state.inputBlocked); XCTAssertNil(state.notice)
        }
    }

    func testLatePrePauseIDRAndPreCapturingReceiptCannotProveResume() {
        var state = CaptureAvailabilityState(); state.begin(generation: 7)
        _ = state.hello(flags: 0x0040, authenticated: true, generation: 7)
        state.noteFrameReceived(sequence: 100)
        XCTAssertTrue(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        _ = state.receive(CaptureAvailabilityCommand(state: 1, reason: 2, sequence: 0).encode(), flags: 0, generation: 7)
        XCTAssertEqual(state.notice, "PC screen temporarily unavailable")
        state.noteFrameReceived(sequence: 100)
        XCTAssertFalse(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 100, decoder: 4, decoded: true, presented: true, generation: 7))
        state.noteFrameReceived(sequence: 101)
        XCTAssertTrue(state.admitFrame(sequence: 101, decoder: 4, isIDR: true, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 101, decoder: 3, decoded: true, presented: true, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 101, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertNotNil(state.notice)
        state.noteFrameReceived(sequence: 102)
        _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 1).encode(), flags: 0, generation: 7)
        state.noteFrameReceived(sequence: 102)
        XCTAssertTrue(state.admitFrame(sequence: 102, decoder: 4, isIDR: false, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 102, decoder: 4, decoded: true, presented: true, generation: 7))
        state.noteFrameReceived(sequence: 103)
        XCTAssertTrue(state.admitFrame(sequence: 103, decoder: 4, isIDR: false, generation: 7))
        XCTAssertFalse(state.observeFrame(sequence: 103, decoder: 4, decoded: true, presented: false, generation: 7))
        XCTAssertTrue(state.observeFrame(sequence: 103, decoder: 4, decoded: false, presented: true, generation: 7))
        XCTAssertNil(state.notice)
    }

    func testRouteSwitchRetainsSuspensionButNewAuthenticatedGenerationRequiresHelloAgain() {
        var state = suspended()
        state.noteFrameReceived(sequence: 100)
        XCTAssertTrue(state.admitFrame(sequence: 100, decoder: 4, isIDR: true, generation: 7))
        state.resetMediaDomain()
        XCTAssertEqual(state.lastSequence, 1); XCTAssertTrue(state.negotiated); XCTAssertTrue(state.inputBlocked)
        XCTAssertFalse(state.observeFrame(sequence: 100, decoder: 4, decoded: true, presented: true, generation: 7))
        _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 2).encode(), flags: 0, generation: 7)
        state.noteFrameReceived(sequence: 0)
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
        _ = state.receive(CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 3).encode(), flags: 0, generation: 7)
        state.noteFrameReceived(sequence: 1)
        XCTAssertTrue(state.admitFrame(sequence: 1, decoder: 4, isIDR: true, generation: 7))
        XCTAssertTrue(state.observeFrame(sequence: 1, decoder: 4, decoded: true, presented: true, generation: 7))
        XCTAssertEqual(state.receive(CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 4).encode(), flags: 0, generation: 7), .suspended(retireInput: true))
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
    @MainActor func testSourceTerminalDeadlinePausesThroughLongPromptAndPictureWait() async throws {
        let network = NetworkManager()
        var now: TimeInterval = 0
        var timers: [(TimeInterval, () -> Void)] = []
        network.connectionControlNowForTesting = { now }
        network.captureTargetScheduleForTesting = { timers.append(($0, $1)) }
        network.realtimeAudioPlaybackForTesting = { _ in XCTFail("no audio") }
        network.controlSendForAudioTesting = { _, done in done(nil) }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x7c40)
        receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 3, current: 1))
        await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
        await drain(network)
        let expire = try XCTUnwrap(timers.first { $0.0 == CaptureTargetProtocol.terminalWait }?.1)
        now = 4
        receive(.captureAvailability, CaptureAvailabilityCommand(state: 1, reason: 1, sequence: 1).encode())
        await drain(network)
        now = 600
        network.networkQueueForTesting.sync { expire() }
        await drain(network)
        XCTAssertNotNil(network.captureTargetState.pending)
        receive(.captureAvailability, CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 2).encode())
        await drain(network)
        now = 900
        network.networkQueueForTesting.sync { expire() }
        await drain(network)
        XCTAssertNotNil(network.captureTargetState.pending, "capturing alone cannot spend the picture-wait budget")
        let decoder = network.decoder.currentSessionGeneration
        network.networkQueueForTesting.sync {
            network.captureContinuationForTesting(sequence: 1, decoder: decoder, isIDR: true)
        }
        network.decoder.onDecodeCompleted?(1, decoder, true)
        network.recordCapturePresentation(sequence: 1, generation: decoder)
        await drain(network)
        XCTAssertFalse(network.captureInputBlocked)
        let terminalDeadline = 900 + CaptureTargetProtocol.terminalWait - 4
        now = terminalDeadline - 0.1
        network.networkQueueForTesting.sync { expire() }
        await drain(network); XCTAssertNotNil(network.captureTargetState.pending)
        now = terminalDeadline
        network.networkQueueForTesting.sync { expire() }
        await drain(network); XCTAssertNil(network.captureTargetState.pending)
    }

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
                state.noteFrameReceived(sequence: 1)
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
            // A delayed complete pre-pause IDR may seed decode, never presentation/input.
            video(1, idr: true); await drain(network)
            XCTAssertEqual(decoded.count, 2)
            network.decoder.onDecodeCompleted?(1, owner, true)
            network.recordCapturePresentation(sequence: 1, generation: owner); await drain(network)
            XCTAssertTrue(network.captureInputBlocked)
            XCTAssertFalse(writes.dropFirst(before).contains { $0[5] == 38 || $0[5] == 40 || $0[5] == 53 })
            receive(.captureAvailability, CaptureAvailabilityCommand(state: 0, reason: 0, sequence: 3).encode()); await drain(network)
            XCTAssertTrue(network.captureInputBlocked)
            network.recordCapturePresentation(sequence: 1, generation: owner); await drain(network)
            XCTAssertTrue(network.captureInputBlocked, "pre-capturing receipt cannot become causal retroactively")
            video(2, idr: false)
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
