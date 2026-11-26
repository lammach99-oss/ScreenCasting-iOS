import XCTest
@testable import iPadCasting

#if targetEnvironment(simulator)
final class FocusCoordinatorTests: XCTestCase {
    @MainActor func testReleaseUsesOldLeaseAndDelayedPresentationCannotAcquireNewLease() throws {
        let focus = FocusCoordinator.forTesting(primary: NetworkManager(role: .secondaryRemote))
        final class Sink {
            var packets = [Data]()
        }
        let sinks = [Sink(), Sink()]
        for (index, network) in [focus.primary, focus.secondary].enumerated() {
            let sink = sinks[index]
            network.controlSendForAudioTesting = { data, done in
                sink.packets.append(data)
                done(nil)
            }
            _ = network.beginRemoteClipboardForTesting()
        }
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        let a = try XCTUnwrap(focus.connect(.one, route: .wifi))
        let b = try XCTUnwrap(focus.connect(.two, route: .wifi))
        XCTAssertTrue(focus.authenticate(a, transport: focus.primary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "1", count: 64)))))
        XCTAssertTrue(focus.authenticate(b, transport: focus.secondary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "2", count: 64)))))
        focus.claimSurface("scene")
        let old = try XCTUnwrap(focus.binding)
        focus.contextReady(old)
        XCTAssertNil(focus.outputLease)
        focus.presented(old)
        XCTAssertEqual(focus.outputLease, old.ticket)
        XCTAssertTrue(focus.primary.acceptsFocusInput(old.ticket))
        let session = IPadInputSession(automaticallyTicks: false)
        // Install the old-peer sink exactly as the surface does. Generate a
        // held scan key; retireFocus must send the matching release to A.
        let oldNetwork = focus.primary
        session.configure(identity: "first", point: true, type: true, direct: true, zoom: false,
                          reason: nil) { event in
            guard case let .key(_, action) = event, oldNetwork.acceptsFocusInput(old.ticket) else { return }
            oldNetwork.sendRemoteScanKey(.init(action: action, flags: 0, scan: 30, token: 1),
                                         expectedGeneration: old.transport)
        }
        session.engine.hardware(usage: 4, down: true)
        oldNetwork.networkQueueForTesting.sync {}
        oldNetwork.networkQueueForTesting.sync {}
        focus.primary.retireFocusInput = { session.retireFocus() }
        let delayedText = { focus.performInput(old.ticket) { $0.sendTextCommit("test") } }
        let delayedPointer = { focus.performInput(old.ticket) {
            $0.sendRemotePointer(.init(kind: 2, button: 1, token: 1, a: 1, b: 0), expectedGeneration: old.transport)
        } }
        focus.select(.two, scene: "scene")
        func keyActions(_ network: NetworkManager, _ sink: Sink) -> [UInt8] {
            network.networkQueueForTesting.sync {}
            return network.networkQueueForTesting.sync {
                sink.packets.filter { $0.count >= 16 && $0[5] == WireMessageType.remoteScanKey.rawValue }
                    .compactMap { RemoteScanKeyCommand.decode(Data($0.dropFirst(16)))?.action }
            }
        }
        XCTAssertEqual(keyActions(oldNetwork, sinks[0]), [0, 1])
        XCTAssertFalse(focus.primary.acceptsFocusInput(old.ticket))
        let new = try XCTUnwrap(focus.binding)
        focus.contextReady(new)
        focus.presented(old)
        XCTAssertNil(focus.outputLease)
        focus.select(.one, scene: "scene")
        focus.select(.two, scene: "scene")
        focus.presented(new)
        XCTAssertEqual(focus.outputLease, new.ticket)
        XCTAssertTrue(focus.secondary.acceptsFocusInput(new.ticket))
        focus.performInput(old.ticket) { _ in XCTFail("Retired input reached a peer") }
        delayedText()
        delayedPointer()
        XCTAssertTrue(keyActions(focus.secondary, sinks[1]).isEmpty)
        for (index, network) in [oldNetwork, focus.secondary].enumerated() {
            network.networkQueueForTesting.sync {}
            network.networkQueueForTesting.sync {
                let forbidden = [WireMessageType.remoteCommittedText, .textCommit, .remotePointer]
                XCTAssertFalse(sinks[index].packets.contains { bytes in
                    bytes.count >= 16 && forbidden.contains { $0.rawValue == bytes[5] }
                })
            }
        }
        XCTAssertFalse(focus.primary.acceptsFocusInput(old.ticket))
    }

    func testAudioLeaseStopsPreviousOutputBeforeGrantAndRejectsDelayedCompletion() {
        let lease = RemoteAudioOutputLease()
        var events = [String]()
        let a = lease.acquire { events.append("stop A") }
        let delayed = { if lease.owns(a) { events.append("play A") } }
        let b = lease.acquire { events.append("stop B") }
        XCTAssertFalse(lease.owns(a))
        XCTAssertTrue(lease.owns(b))
        delayed()
        lease.release(a)
        XCTAssertTrue(lease.owns(b))
        lease.release(b)
        XCTAssertEqual(events, ["stop A", "stop B"])
    }

    @MainActor func testWatchdogRequiresTapForAlternate() throws {
        let focus = FocusCoordinator.forTesting(primary: NetworkManager(role: .secondaryRemote))
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        for (slot, digit) in [(SlotOrdinal.one, "1"), (.two, "2")] {
            let manager = focus.manager(slot)
            manager.controlSendForAudioTesting = { _, done in done(nil) }
            _ = manager.beginRemoteClipboardForTesting()
            let t = try XCTUnwrap(focus.connect(slot, route: .wifi))
            XCTAssertTrue(focus.authenticate(t, transport: manager.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: digit, count: 64)))))
        }
        focus.claimSurface("scene")
        let binding = try XCTUnwrap(focus.binding)
        focus.watchdog(binding, expired: false)
        XCTAssertNil(focus.outputLease)
        focus.watchdog(binding, expired: true)
        XCTAssertEqual(focus.model.offeredAlternate, .two)
        XCTAssertEqual(focus.model.selected, .one)
        XCTAssertTrue(focus.model[.one].retryRequested)
        focus.presented(binding)
        XCTAssertNil(focus.outputLease)
    }
}

extension FocusCoordinatorTests {
    @MainActor func testUnnegotiatedParkDropsVideoBeforeDecodeAndSingleSlotKeepsOriginalAdmission() throws {
        let primary = NetworkManager(role: .secondaryRemote)
        let focus = FocusCoordinator.forTesting(primary: primary)
        XCTAssertFalse(primary.focusManaged)
        XCTAssertTrue(primary.acceptsFocusInput(nil))
        for manager in [primary, focus.secondary] { manager.controlSendForAudioTesting = { _, done in done(nil) } }
        defer { primary.stopForTesting(); focus.secondary.stopForTesting() }
        _ = primary.beginRemoteClipboardForTesting()
        let oldHost = focus.secondary.beginRemoteClipboardForTesting()
        let first = try XCTUnwrap(focus.connect(.one, route: .wifi))
        XCTAssertTrue(focus.authenticate(first, transport: focus.primary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "3", count: 64)))))
        XCTAssertFalse(primary.focusManaged)
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        XCTAssertTrue(focus.authenticate(second, transport: focus.secondary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "4", count: 64)))))
        var decoded = [UInt32]()
        focus.secondary.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
        func sendVideo(_ sequence: UInt32) {
            focus.secondary.receiveCaptureTargetWireForTesting(type: .video, payload: Data([0,0,0,2,38,1]),
                flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed, sequence: sequence,
                generation: oldHost.generation, connection: oldHost.connection)
        }
        sendVideo(1)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertNil(focus.thumbnail(for: .two))
        focus.claimSurface("scene")
        focus.presented(try XCTUnwrap(focus.binding))
        focus.select(.two, scene: "scene")
        sendVideo(2)
        XCTAssertEqual(decoded, [2])
    }
}
#endif
