import XCTest
import Network
@testable import iPadCasting

final class ConnectionControlIntegrationTests: XCTestCase {
    private final class Writes {
        private let lock = NSLock()
        private var storage: [Data] = []
        func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage.append(data) }
        var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    #if targetEnvironment(simulator)
    @MainActor private func drain(_ network: NetworkManager) async {
        for _ in 0..<4 {
            network.networkQueueForTesting.sync {}
            let done = expectation(description: "connection state publication")
            DispatchQueue.main.async { done.fulfill() }
            await fulfillment(of: [done], timeout: 2)
        }
    }
    @MainActor func testOldHostAndUnverifiedIdentityNeverReceiveExtensionTraffic() async {
        for verified in [true, false] {
            let network = NetworkManager(); let writes = Writes()
            network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting()
            network.setConnectionIdentityForTesting(verified: verified)
            network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes,
                flags: verified ? 0 : 0x0200, generation: peer.generation, connection: peer.connection)
            await drain(network)
            XCTAssertFalse(writes.snapshot.contains { (76...79).contains($0[5]) })
            network.stopForTesting()
        }
    }
    @MainActor func testPreparedListenerDoesNotRetireWifiOrChangeGeneration() async throws {
        let network = NetworkManager(); let writes = Writes()
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        network.connectionListenerPortForTesting = 0
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting(); network.setConnectionIdentityForTesting(verified: true)
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x0200)
        receive(.connectionState, try ConnectionSwitchStateTests.snapshot().encode()); await drain(network)
        let ready = expectation(description: "ordinary raw USB listener ready")
        network.connectionListenerReadyForTesting = { ready.fulfill() }
        network.requestConnectionRoute(.usb)
        await fulfillment(of: [ready], timeout: 3); await drain(network)
        let current = network.wifiSessionSnapshotForTesting()
        XCTAssertEqual(current.generation, peer.generation)
        XCTAssertTrue(network.connectionIncumbentIsCurrentForTesting(peer.connection))
        XCTAssertEqual(network.connectionSwitchState.actualRoute, .wifi)
        XCTAssertTrue(writes.snapshot.contains { $0[5] == 78 })
        XCTAssertFalse(writes.snapshot.contains { $0[5] == 76 && (1...3).contains($0[17]) })
    }
    @MainActor func testRawUsbIdentitySuccessBindsBeforeExtensionOptIn() async throws {
        let network = NetworkManager(); let writes = Writes()
        let credential = ConnectionControlProtocolTests.usbCredential
        network.usbIdentityCredentialLoadForTesting = { credential }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting(); network.configureUsbIdentityForTesting()
        network.receiveIdentityWireForTesting(type: .ping, payload: Data(0..<16), flags: 0x0100, sequence: 7)
        await drain(network)
        let pong = try XCTUnwrap(writes.snapshot.first { $0[5] == 7 })
        XCTAssertEqual(pong[6], 0x80); XCTAssertEqual(pong[7], 0)
        XCTAssertEqual(Data(pong.dropFirst(16)), Data(0..<16))
        XCTAssertTrue(writes.snapshot.contains { $0[5] == 21 }); XCTAssertFalse(network.usbIdentityBoundForTesting)
        network.receiveIdentityWireForTesting(type: .trustedDeviceChallenge, payload: ConnectionControlProtocolTests.usbChallenge)
        await drain(network)
        let proof = try XCTUnwrap(writes.snapshot.first { $0[5] == 24 })
        XCTAssertEqual(Data(proof.dropFirst(16)), ConnectionControlProtocolTests.bytes(
            "000102030405060708090a0b0c0d0e0fcc47d96d2e54d4ae4e418f0460e9b3b53556db88d5de9ae0201f3469b368f878"))
        network.receiveIdentityWireForTesting(type: .trustedAuthResult, payload: Data([1]) + Data("USB identity verified.".utf8))
        await drain(network); XCTAssertTrue(network.usbIdentityBoundForTesting)
        XCTAssertFalse(writes.snapshot.contains { $0[5] == 76 })
        network.receiveIdentityWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes, flags: 0x0200)
        await drain(network)
        XCTAssertEqual(writes.snapshot.filter { $0[5] == 76 }.count, 1)
        XCTAssertEqual(writes.snapshot.first { $0[5] == 76 }, ConnectionControlProtocolTests.hello)
    }
    @MainActor func testUsbOldHostNoCredentialAndWrongHostCannotEnableControl() async throws {
        for scenario in 0..<3 {
            let network = NetworkManager(); let writes = Writes()
            network.usbIdentityCredentialLoadForTesting = { scenario == 1 ? nil : ConnectionControlProtocolTests.usbCredential }
            network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
            _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting(); network.configureUsbIdentityForTesting()
            network.receiveIdentityWireForTesting(type: .ping, payload: Data(0..<16), flags: scenario == 0 ? 0 : 0x0100)
            await drain(network)
            if scenario == 2 {
                var wrong = ConnectionControlProtocolTests.usbChallenge; wrong[32] ^= 1
                network.receiveIdentityWireForTesting(type: .trustedDeviceChallenge, payload: wrong)
                await drain(network)
                network.receiveIdentityWireForTesting(type: .trustedAuthResult, payload: Data([1]))
            } else {
                XCTAssertFalse(writes.snapshot.contains { $0[5] == 21 || $0[5] == 24 })
                XCTAssertEqual(writes.snapshot.first { $0[5] == 7 }?[6], 0)
            }
            network.receiveIdentityWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes, flags: 0x0200)
            await drain(network)
            XCTAssertFalse(network.usbIdentityBoundForTesting)
            XCTAssertFalse(writes.snapshot.contains { (76...79).contains($0[5]) })
            XCTAssertFalse(writes.snapshot.contains { $0[5] == 24 })
            if scenario == 0 {
                // No identity offer: retain the original legacy auth-result dispatch.
                network.receiveIdentityWireForTesting(type: .trustedAuthResult, payload: Data([0]))
                await drain(network)
                XCTAssertEqual(network.connectionState, .authFailed(reason: "Trusted device authentication failed."))
            }
            network.stopForTesting()
        }
    }
    @MainActor func testPrematureUsbCredentialMessagesCannotCommitReadiness() async {
        for type in [WireMessageType.trustedDeviceChallenge, .trustedAuthResult] {
            for pongPending in [false, true] {
                let network = NetworkManager()
                // Keep the legacy readiness Pong in flight in the second case.
                network.controlSendForAudioTesting = { _, _ in }
                _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
                network.beginTransferWriterForTesting(); network.configureUsbIdentityForTesting()
                if pongPending {
                    network.receiveIdentityWireForTesting(type: .ping, payload: Data(0..<16))
                    await drain(network)
                }
                network.receiveIdentityWireForTesting(type: type,
                    payload: type == .trustedDeviceChallenge ? ConnectionControlProtocolTests.usbChallenge : Data([1]))
                await drain(network)
                XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration)
                XCTAssertFalse(network.usbIdentityBoundForTesting)
                network.stopForTesting()
            }
        }
    }
    @MainActor func testWifiToOrdinaryUsbSendsOnlyResumeAfterIdentityAndAdvertisement() async throws {
        let network = NetworkManager(); let writes = Writes()
        let credential = ConnectionControlProtocolTests.usbCredential
        network.usbIdentityCredentialLoadForTesting = { credential }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        network.connectionListenerPortForTesting = 0
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting(); network.setConnectionIdentityForTesting(verified: true)
        network.setConnectionCredentialForTesting(credential)
        network.receiveIdentityWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes, flags: 0x0200)
        network.receiveIdentityWireForTesting(type: .connectionState, payload: try ConnectionSwitchStateTests.snapshot().encode())
        await drain(network)
        let ready = expectation(description: "ordinary listener before request")
        network.connectionListenerReadyForTesting = { ready.fulfill() }
        network.requestConnectionRoute(.usb)
        await fulfillment(of: [ready], timeout: 3); await drain(network)
        network.receiveIdentityWireForTesting(type: .connectionState, payload: try ConnectionSwitchStateTests.prepare().encode())
        network.receiveIdentityWireForTesting(type: .connectionState,
            payload: try ConnectionSwitchStateTests.snapshot(revision: 3, hostState: .switching).encode())
        network.receiveIdentityWireForTesting(type: .connectionSelectResult, payload: try ConnectionSwitchStateTests.result(.accepted).encode())
        await drain(network)
        network.retireConnectionRouteForTesting()
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting(); network.configureUsbIdentityForTesting()
        network.receiveIdentityWireForTesting(type: .ping, payload: Data(0..<16), flags: 0x0100)
        await drain(network)
        network.receiveIdentityWireForTesting(type: .trustedDeviceChallenge, payload: ConnectionControlProtocolTests.usbChallenge)
        await drain(network)
        network.receiveIdentityWireForTesting(type: .trustedAuthResult, payload: Data([1]) + Data("USB identity verified.".utf8))
        await drain(network)
        let beforeAdvertisement = writes.snapshot.filter { $0[5] == 76 }.count
        network.receiveIdentityWireForTesting(type: .displayCapabilities, payload: CaptureTargetIntegrationTests.modes, flags: 0x0200)
        await drain(network)
        let hellos = writes.snapshot.filter { $0[5] == 76 }
        XCTAssertEqual(hellos.count, beforeAdvertisement + 1)
        let resume = try ConnectionHello.decode(Data(try XCTUnwrap(hellos.last).dropFirst(16)))
        XCTAssertEqual(resume.kind, .resumeProof); XCTAssertEqual(resume.target, .usb)
        XCTAssertEqual(resume.revision, 2); XCTAssertEqual(resume.owner, 1); XCTAssertEqual(resume.transaction, 1)
        let expected = ConnectionProofContext(target: .usb, transaction: 1, owner: 1, revision: 2,
            token: Data(0..<16), challenge: Data(32..<64), secret: Data(64..<96)).resumeHello()
        XCTAssertEqual(resume, expected); XCTAssertTrue(network.connectionSwitchState.inputBlocked)
        XCTAssertFalse(writes.snapshot.contains { $0[5] == 76 && (1...3).contains($0[17]) })
    }
    #endif
    func testRecommendationAndPermissionCopy() throws {
        var state = ConnectionSwitchState()
        XCTAssertEqual(ConnectScreenStatus.connectionRecommendation(state), "USB availability not checked")
        state.begin(generation: 1); _ = state.advertise(flags: 0x0200, authenticated: true, generation: 1)
        _ = state.receive(try ConnectionSwitchStateTests.snapshot(allowed: false), generation: 1, now: 0)
        XCTAssertEqual(state.recommendationText, "Wi-Fi/Tailscale recommended")
        XCTAssertEqual(state.disabledReason(for: .usb, hasWifiEndpoint: true), "Allow connection changes on the PC")
        XCTAssertEqual(CastingPermissionCopy.requestSent, "Request sent. Approve it in the pop-up on the PC.")
    }
    func testConnectionScreenKeepsSwitchProgressAndFailureAfterRetirement() throws {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        XCTAssertNil(ConnectScreenStatus.connectionChange(state))
        _ = state.advertise(flags: 0x0200, authenticated: true, generation: 1)
        _ = state.receive(try ConnectionSwitchStateTests.snapshot(), generation: 1, now: 0)
        _ = state.select(.usb, now: 0)
        XCTAssertEqual(ConnectScreenStatus.connectionChange(state)?.text, "Checking connection...")
        XCTAssertEqual(ConnectScreenStatus.connectionChange(state)?.tone, .busy)
        state.cancel(reason: .proofFailed)
        XCTAssertEqual(ConnectScreenStatus.connectionChange(state)?.text, "Connection change failed")
        XCTAssertEqual(ConnectScreenStatus.connectionChange(state)?.action, ConnectScreenStatus.Action.none)
        XCTAssertTrue(state.offersReconnect)
    }
}
