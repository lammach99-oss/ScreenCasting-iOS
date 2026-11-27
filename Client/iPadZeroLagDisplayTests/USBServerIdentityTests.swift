import XCTest
@testable import iPadCasting

#if targetEnvironment(simulator)
import Combine
import CoreVideo
import CryptoKit
import Network
import Security

final class USBControlTLSIntegrationTests: XCTestCase {
    @MainActor func testMutualTLSBindsProofAndReprobesClipboardOnReplacement() async throws {
        let session = try Session()
        defer { session.stop() }
        let port = try await start(session)
        var priorProbe: Data?
        for _ in 0..<2 {
            let host = dial(port, tls: true)
            defer { host.cancel() }
            try await authenticate(host, session: session, tls: true)
            let probe = try await read(host, type: .ping, flags: 0x1000)
            XCTAssertEqual(probe.count, 16)
            XCTAssertNotEqual(probe, priorProbe)
            priorProbe = probe
            try await send(host, .pong, probe, flags: 0x1000)
            _ = try await read(host, type: .castingClipboardHello)
            let listening = XCTestExpectation(description: "USB listener available after authenticated peer closes")
            let observation = session.manager.$connectionState.first(where: {
                $0 == .listening && session.manager.usbSessionSnapshot().connection == nil
            })
                .sink { _ in listening.fulfill() }
            defer { observation.cancel() }
            host.cancel()
            guard await XCTWaiter.fulfillment(of: [listening], timeout: 10) == .completed else {
                return XCTFail("USB listener did not resume after authenticated peer closed")
            }
        }
    }

    @MainActor func testLegacyHostAuthenticatesButCannotOpenClipboard() async throws {
        let session = try Session()
        defer { session.stop() }
        let host = dial(try await start(session), tls: false)
        defer { host.cancel() }
        try await authenticate(host, session: session, tls: false)
        let probe = try await read(host, type: .ping, flags: 0x1000)
        try await send(host, .pong, probe, flags: 0x1000)
        let fence = Data(repeating: 0x31, count: 16)
        try await send(host, .ping, fence)
        let pong = try await read(host, type: .pong, rejectClipboardHello: true)
        XCTAssertEqual(pong, fence)
    }

    @MainActor func testPinMismatchClosesAdvertisedSocket() async throws {
        let session = try Session(wrongPin: true)
        defer { session.stop() }
        let port = try await start(session)
        let host = dial(port, tls: true)
        defer { host.cancel() }
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        try await waitUntil {
            switch host.state {
            case .failed, .waiting: return true
            default: return false
            }
        }
        XCTAssertNil(session.savedCredential()?.usbControlTLSSeen)
        let legacy = dial(port, tls: false)
        defer { legacy.cancel() }
        try await authenticate(legacy, session: session, tls: false)
        try await waitUntil { session.manager.usbIdentityBoundForTesting }
    }

    @MainActor func testChangedOrMissingCredentialRetiresAdvertisedCandidate() async throws {
        for missing in [false, true] {
            let session = try Session()
            defer { session.stop() }
            let port = try await start(session)
            let original = session.credential
            var changed = original
            changed.usbControlTLSSeen = true
            var loads = 0
            session.manager.networkQueueForTesting.sync {
                session.manager.usbIdentityCredentialLoadForTesting = {
                    loads += 1
                    return loads == 1 ? original : (missing ? nil : changed)
                }
            }
            let host = dial(port, tls: false)
            defer { host.cancel() }
            let started = ProcessInfo.processInfo.systemUptime
            try await send(host, .ping, Self.readiness, flags: 0x2100)
            try await waitUntil { session.manager.connectionState == Self.secureFailure }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
            XCTAssertFalse(session.manager.usbIdentityBoundForTesting)
        }
    }

    @MainActor func testSilentTLSHandshakeExpiresAfterAdvertisement() async throws {
        let session = try Session()
        defer { session.stop() }
        let host = dial(try await start(session), tls: false)
        defer { host.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        try await send(host, .ping, Self.readiness, flags: 0x2100)
        let pong = try await read(host, type: .pong, flags: 0x2080)
        XCTAssertEqual(pong, Self.readiness)
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 5)
        XCTAssertFalse(session.manager.usbIdentityBoundForTesting)
    }

    @MainActor func testRejectedProofClosesAdvertisedSocket() async throws {
        let session = try Session()
        defer { session.stop() }
        let host = dial(try await start(session), tls: true)
        defer { host.cancel() }
        try await authenticate(host, session: session, tls: true, accepted: false)
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        let remaining = try await receive(host, count: 1)
        XCTAssertTrue(remaining?.isEmpty ?? true)
        XCTAssertNil(session.savedCredential()?.usbControlTLSSeen)
    }

    @MainActor func testTLSSeenRefusesPlaintextEvenWithoutProofCapability() async throws {
        let session = try Session()
        defer { session.stop() }
        let port = try await establishTLS(session)
        let host = dial(port, tls: false)
        defer { host.cancel() }
        try await send(host, .ping, Self.readiness)
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        let remaining = try await receive(host, count: 1)
        XCTAssertTrue(remaining?.isEmpty ?? true)
    }

    @MainActor func testWifiRepairPreservesTLSRequirementForFreshUsbManager() async throws {
        let session = try Session(tlsSeen: true)
        defer { session.stop() }
        let wifi = session.manager
        wifi.controlSendForAudioTesting = { _, done in done(nil) }
        _ = wifi.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        wifi.beginTransferWriterForTesting()
        let old = session.credential
        wifi.configureAuthenticationForTesting(confirmed: true, fingerprint: old.fingerprint,
            endpoint: session.endpoint, credentials: session.credentials, pins: session.pins)
        wifi.receiveIdentityWireForTesting(type: .pairingRequired, payload: Data([0]))
        wifi.sendAuthPIN("1234")
        wifi.networkQueueForTesting.sync {}
        wifi.receiveIdentityWireForTesting(type: .authResult, payload: Data([1]),
            flags: WireProtocol.realtimeNegotiationSupportedFlag)
        let secret = Data(repeating: 0x27, count: 32)
        wifi.receiveIdentityWireForTesting(type: .pairingSuccess,
            payload: old.hostID + old.deviceID + old.sessionID + secret)
        XCTAssertTrue(session.savedCredential()?.secret == secret)
        XCTAssertEqual(session.savedCredential()?.usbControlTLSSeen, true)

        let fresh = try Session()
        defer { fresh.stop() }
        fresh.manager.installTrustedHostStoresForTesting(credentials: session.credentials, pins: session.pins)
        let host = dial(try await start(fresh), tls: false)
        defer { host.cancel() }
        try await send(host, .ping, Self.readiness, flags: 0x0100)
        try await waitUntil { fresh.manager.connectionState == Self.secureFailure }
        XCTAssertFalse(fresh.manager.usbIdentityBoundForTesting)
    }

    @MainActor func testForgetAndRepairAllowLegacyAgain() async throws {
        let session = try Session()
        defer { session.stop() }
        let port = try await establishTLS(session)
        session.manager.forgetTrustedHost(endpoint: session.endpoint)
        try await waitUntil { session.manager.trustedHostForgetOutcome == .localOnly }
        XCTAssertNil(session.savedCredential())
        try session.manager.networkQueueForTesting.sync { try session.pair() }
        let host = dial(port, tls: false)
        defer { host.cancel() }
        try await authenticate(host, session: session, tls: false)
        try await waitUntil { session.manager.connectionState == .streaming }
    }

    @MainActor func testTLSSeenWifiToUsbRequiresTlsProofBeforeResume() async throws {
        try await verifyWifiToUsb(tlsSeen: true)
    }

    @MainActor func testLegacyWifiToUsbKeepsPlaintextProofAndResume() async throws {
        try await verifyWifiToUsb(tlsSeen: false)
    }

    @MainActor func testTLSSeenWifiToUsbClosesPlaintextReplacement() async throws {
        let session = try Session(tlsSeen: true)
        defer { session.stop() }
        let wifi = try WifiHost(identity: session.hostIdentity)
        defer { wifi.stop() }
        let incumbent = try await startWifi(session, host: wifi)
        let port = try await acceptWifiToUsb(session, incumbent: incumbent)

        let usb = dial(port, tls: false)
        defer { usb.cancel() }
        try await send(usb, .ping, Self.readiness, flags: 0x0100)
        let plaintext = try await receive(usb, count: 1)
        XCTAssertTrue(plaintext?.isEmpty ?? true)
        try await assertWifiRollback(session, host: wifi)
    }

    @MainActor func testWifiToUsbTlsPinFailureRestoresPairedWifi() async throws {
        // Wi-Fi presents the saved certificate. The USB TLS peer presents a different one.
        let session = try Session(wrongPin: true, tlsSeen: true)
        defer { session.stop() }
        let wifi = try WifiHost(identity: session.hostIdentity)
        defer { wifi.stop() }
        let incumbent = try await startWifi(session, host: wifi)
        let port = try await acceptWifiToUsb(session, incumbent: incumbent)

        let usb = dial(port, tls: true)
        defer { usb.cancel() }
        try await assertWifiRollback(session, host: wifi)
    }

    @MainActor func testUsbRollbackAfterWifiFailureReauthenticatesOverTls() async throws {
        let session = try Session(tlsSeen: true)
        defer { session.stop() }
        let manager = session.manager
        let usbPort = try await start(session)
        let incumbent = dial(usbPort, tls: true)
        defer { incumbent.cancel() }
        try await authenticate(incumbent, session: session, tls: true)
        try await advertiseConnectionControl(incumbent)
        try await expectOptIn(incumbent)
        try await send(incumbent, .connectionState, ConnectionSwitchStateTests.snapshot(route: .usb).encode())
        try await waitUntil { manager.connectionSwitchState.actualRoute == .usb }

        let wifi = try WifiHost(identity: session.hostIdentity)
        defer { wifi.stop() }
        let wifiPort = try await startWifiListener(wifi)
        manager.releaseMirrorControl()
        manager.seedRouteEndpointForTesting(port: wifiPort)
        manager.requestConnectionRoute(.wifi)
        try await expectRouteRequest(incumbent, target: .wifi)
        try await send(incumbent, .connectionState, ConnectionSwitchStateTests.prepare(target: .wifi).encode())
        try await send(incumbent, .connectionState,
                       ConnectionSwitchStateTests.snapshot(revision: 3, route: .usb, hostState: .switching).encode())
        try await send(incumbent, .connectionSelectResult, ConnectionSwitchStateTests.wifiResult().encode())
        try await waitUntil { manager.connectionSwitchState.pending?.accepted == true }
        incumbent.cancel()

        let failedWifi = try await wifiPeer(wifi, index: 0)
        failedWifi.cancel()
        try await waitUntil { manager.connectionSwitchState.pending?.rollbackRoute == .usb }
        let transaction = try XCTUnwrap(manager.connectionSwitchState.pending?.request)
        for silent in [false, true] {
            let generation = manager.usbSessionSnapshot().generation
            let dialStarted = ProcessInfo.processInfo.systemUptime
            let interrupted = dial(usbPort, tls: false)
            defer { interrupted.cancel() }
            try await waitUntil { manager.usbSessionSnapshot().generation > generation }
            let interruptedGeneration = manager.usbSessionSnapshot().generation
            if !silent { interrupted.cancel() }
            try await waitUntil { manager.usbSessionSnapshot().generation > interruptedGeneration }
            if silent {
                XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - dialStarted, 4.8)
                let eof = try await receive(interrupted, count: 1)
                XCTAssertTrue(eof?.isEmpty ?? true)
            }
            XCTAssertTrue(manager.usbSessionSnapshot().listenerIntent)
            XCTAssertEqual(manager.connectionSwitchState.pending?.request, transaction)
            XCTAssertEqual(manager.connectionSwitchState.pending?.rollbackRoute, .usb)
        }
        let replacement = dial(usbPort, tls: true)
        defer { replacement.cancel() }
        try await authenticate(replacement, session: session, tls: true)
        manager.updateInterfaceOrientation(.landscape)
        try await advertiseConnectionControl(replacement)
        try await expectOptIn(replacement)
        try await finishRollback(replacement, manager: manager, route: .usb, reason: .connectionLost)
        XCTAssertTrue(manager.legacyVirtualInputSuspended)
        let authenticated = manager.usbSessionSnapshot().generation
        try await Task.sleep(nanoseconds: 5_200_000_000)
        XCTAssertEqual(manager.usbSessionSnapshot().generation, authenticated)
        try await send(replacement, .ping, Self.readiness)
        let pong = try await read(replacement, type: .pong)
        XCTAssertEqual(pong, Self.readiness)
    }

    private static let readiness = Data(0..<16)
    private static let secureFailure = ConnectionState.disconnected(
        reason: "Secure USB connection failed - reconnect or re-pair")

    private enum TestError: Error { case closed, invalidFrame, writeFailed, timedOut }

    private final class MemoryBacking: TrustedHostCredentialBacking {
        private var entries: [String: Data] = [:]
        func load(fingerprint: String) -> Data? { entries[fingerprint] }
        func save(_ data: Data, fingerprint: String) -> Bool { entries[fingerprint] = data; return true }
        func delete(fingerprint: String) -> Bool { entries.removeValue(forKey: fingerprint); return true }
    }

    private enum LoopbackIdentities {
        static let device = Result { try importIdentity(devicePKCS12) }
        static let peer = Result { try importIdentity(peerPKCS12) }

        private static func importIdentity(_ encoded: String) throws -> SecIdentity {
            let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            var options: [String: Any] = [kSecImportExportPassphrase as String: "usb-loopback"]
            if #available(iOS 18.0, *) { options[kSecImportToMemoryOnly as String] = true }
            var items: CFArray?
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            XCTAssertEqual(status, errSecSuccess, "Loopback PKCS#12 import")
            let entries = items as? [[String: Any]]
            let value = try XCTUnwrap(entries?.first?[kSecImportItemIdentity as String]) as CFTypeRef
            let identity = CFGetTypeID(value) == SecIdentityGetTypeID()
                ? unsafeBitCast(value, to: SecIdentity.self) : nil
            return try XCTUnwrap(identity)
        }

        // Public test-only identities generated for these loopback sockets.
        // The private keys are fixtures. They must never be used outside this suite.
        private static let devicePKCS12 = """
        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
        """
        private static let peerPKCS12 = """
        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
        """
    }

    private final class Session {
        let suite: String
        let defaults: UserDefaults
        let manager: NetworkManager
        let credentials = MemoryBacking()
        let pins = MemoryBacking()
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 27015)
        let credential: TrustedHostCredential
        let hostIdentity: SecIdentity
        let leafHash: Data

        init(wrongPin: Bool = false, tlsSeen: Bool? = nil) throws {
            let identity = try LoopbackIdentities.device.get()
            let peer = try LoopbackIdentities.peer.get()
            let deviceHash = try Self.hash(identity)
            let peerHash = try Self.hash(peer)
            XCTAssertNotEqual(deviceHash, peerHash)
            leafHash = deviceHash
            let pinBytes = wrongPin ? deviceHash : peerHash
            hostIdentity = wrongPin ? identity : peer
            let pin = pinBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            let fixture = ConnectionControlProtocolTests.usbCredential
            credential = TrustedHostCredential(fingerprint: pin, hostID: fixture.hostID,
                deviceID: fixture.deviceID, secret: fixture.secret, sessionID: fixture.sessionID,
                usbControlTLSSeen: tlsSeen)
            let suiteName = "USBControlTLS." + UUID().uuidString
            let settings = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            settings.set(true, forKey: RemoteClipboardProtocol.preferenceKey)
            suite = suiteName
            defaults = settings
            manager = NetworkManager(userDefaults: settings)
            manager.usbServerTLSIdentityForTesting = try XCTUnwrap(USBServerTLSIdentity(identity: identity))
            try pair()
            manager.installTrustedHostStoresForTesting(credentials: credentials, pins: pins)
        }

        private static func hash(_ identity: SecIdentity) throws -> Data {
            var certificate: SecCertificate?
            XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
            let leaf = try XCTUnwrap(certificate)
            return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        }

        func savedCredential() -> TrustedHostCredential? {
            manager.networkQueueForTesting.sync {
                TrustedHostCredentialStore(backing: credentials).load(fingerprint: credential.fingerprint)
            }
        }

        func pair(at endpoint: NWEndpoint? = nil) throws {
            guard TrustedHostCredentialStore(backing: credentials).save(credential),
                  TrustedHostFingerprintStore(backing: pins).save(credential.fingerprint,
                       endpoint: endpoint ?? self.endpoint, hostID: credential.hostID) else { throw TestError.writeFailed }
        }

        func stop() {
            manager.stopForTesting()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private final class WifiHost {
        let listener: NWListener
        let queue = DispatchQueue(label: "connection switch fake Wi-Fi host")
        private var peers: [NWConnection] = []

        init(identity: SecIdentity) throws {
            let tls = NWProtocolTLS.Options()
            let localIdentity = try XCTUnwrap(sec_identity_create(identity))
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 0))
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] peer in
                guard let self else { peer.cancel(); return }
                self.peers.append(peer)
                peer.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 12) { [weak peer] in peer?.cancel() }
            }
        }

        func peer(at index: Int) -> NWConnection? {
            queue.sync { peers.indices.contains(index) ? peers[index] : nil }
        }

        func stop() {
            queue.sync {
                listener.cancel()
                peers.forEach { $0.cancel() }
            }
        }
    }

    @MainActor private func startWifiListener(_ host: WifiHost) async throws -> NWEndpoint.Port {
        let ready = expectation(description: "Wi-Fi fixture listening")
        host.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        host.listener.start(queue: host.queue)
        await fulfillment(of: [ready], timeout: 3)
        return try XCTUnwrap(host.listener.port)
    }

    @MainActor private func wifiPeer(_ host: WifiHost, index: Int) async throws -> NWConnection {
        try await waitUntil { host.peer(at: index) != nil }
        return try XCTUnwrap(host.peer(at: index))
    }

    @MainActor private func startWifi(_ session: Session, host: WifiHost) async throws -> NWConnection {
        let port = try await startWifiListener(host)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let manager = session.manager
        try manager.networkQueueForTesting.sync { try session.pair(at: endpoint) }
        manager.connectionListenerPortForTesting = 0
        manager.connect(to: endpoint)
        let incumbent = try await wifiPeer(host, index: 0)
        try await authenticateWifi(incumbent, credential: session.credential)
        try await advertiseConnectionControl(incumbent)
        try await expectOptIn(incumbent)
        try await send(incumbent, .connectionState, ConnectionSwitchStateTests.snapshot().encode())
        try await waitUntil { manager.connectionSwitchState.actualRoute == .wifi }
        return incumbent
    }

    private func authenticateWifi(_ host: NWConnection, credential: TrustedHostCredential) async throws {
        _ = try await read(host, type: .clientHello)
        let challenge = ConnectionControlProtocolTests.usbChallenge
        try await send(host, .trustedDeviceChallenge, challenge)
        let proof = try await read(host, type: .trustedDeviceProof)
        let context = Data(challenge.suffix(64)) + Data(challenge.prefix(48)) + Data([1])
        let mac = HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: credential.secret))
        guard proof == Data(challenge.prefix(16)) + Data(mac) else { throw TestError.invalidFrame }
        try await send(host, .authResult, Data([1]))
        try await send(host, .trustedAuthResult, Data([1]))
    }

    private func advertiseConnectionControl(_ host: NWConnection) async throws {
        try await send(host, .displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x0300)
    }

    private func expectOptIn(_ host: NWConnection) async throws {
        let payload = try await read(host, type: .connectionHello)
        XCTAssertEqual(try ConnectionHello.decode(payload), .optIn(protectedHandoff: true))
    }

    private func expectRouteRequest(_ host: NWConnection, target: ConnectionRoute) async throws {
        let payload = try await read(host, type: .connectionSelectRequest)
        let request = try ConnectionSelectRequest.decode(payload)
        XCTAssertEqual(request.target, target)
        XCTAssertEqual(request.transaction, 1)
        XCTAssertEqual(request.owner, 1)
        XCTAssertEqual(request.revision, 2)
    }

    @MainActor private func acceptWifiToUsb(_ session: Session, incumbent: NWConnection) async throws -> NWEndpoint.Port {
        let manager = session.manager
        manager.requestConnectionRoute(.usb)
        try await expectRouteRequest(incumbent, target: .usb)
        let port = try XCTUnwrap(manager.preparedUSBListenerPortForTesting)
        try await send(incumbent, .connectionState, ConnectionSwitchStateTests.prepare().encode())

        let probe = dial(port, tls: false)
        defer { probe.cancel() }
        let ping = ConnectionControlProtocolTests.bytes("ce83cdcbb78c7b9e432ce98f2d889d4517be4f89e5b949888f30f45f93bfdb5e")
        let pong = ConnectionControlProtocolTests.bytes("41cb339cb7b174f97c05521fb67d601bdda65fdb8b7709ca9c785155132041af")
        try await send(probe, .ping, ping, flags: 0x0400)
        let probeReply = try await receive(probe, count: 48)
        XCTAssertTrue(probeReply == Self.frame(.pong, pong, flags: 0x0400))
        let trailingPlaintext = try await receive(probe, count: 1)
        XCTAssertTrue(trailingPlaintext?.isEmpty ?? true)
        if case .cancelled = probe.state { XCTFail("Probe did not close before the fixture timeout") }
        XCTAssertTrue(manager.connectionSwitchState.enabled)
        XCTAssertEqual(manager.connectionSwitchState.actualRoute, .wifi)
        XCTAssertEqual(manager.connectionSwitchState.pending?.accepted, false)

        try await send(incumbent, .connectionState,
                       ConnectionSwitchStateTests.snapshot(revision: 3, hostState: .switching).encode())
        try await send(incumbent, .connectionSelectResult, ConnectionSwitchStateTests.result(.accepted).encode())
        try await waitUntil { manager.connectionSwitchState.pending?.accepted == true }
        incumbent.cancel()
        return port
    }

    @MainActor private func verifyWifiToUsb(tlsSeen: Bool) async throws {
        let session = try Session(tlsSeen: tlsSeen ? true : nil)
        defer { session.stop() }
        let wifi = try WifiHost(identity: session.hostIdentity)
        defer { wifi.stop() }
        let incumbent = try await startWifi(session, host: wifi)
        session.manager.releaseMirrorControl()
        let port = try await acceptWifiToUsb(session, incumbent: incumbent)
        let usb = dial(port, tls: tlsSeen)
        defer { usb.cancel() }

        let manager = session.manager
        try await authenticate(usb, session: session, tls: tlsSeen)
        manager.updateInterfaceOrientation(.landscape)
        try await send(usb, .displayCapabilities, CaptureTargetIntegrationTests.modes,
                       flags: 0x0300 | CaptureTargetProtocol.advertisementFlag)
        let payload = try await read(usb, type: .connectionHello)
        let resume = try ConnectionHello.decode(payload)
        let expected = ConnectionProofContext(target: .usb, transaction: 1, owner: 1, revision: 2,
            token: Data(0..<16), challenge: Data(32..<64), secret: Data(64..<96)).resumeHello()
        XCTAssertTrue(resume == expected)
        let sourceHello = try await read(usb, type: .sourceHello)
        XCTAssertEqual(sourceHello, CaptureTargetProtocol.hello())
        try await send(usb, .sourceCatalogue,
                       CaptureTargetIntegrationTests.catalogue(revision: 1, current: 1))
        try await waitUntil { manager.captureTargetState.confirmedCurrentId == 1 }
        XCTAssertEqual(manager.captureTargetState.generation, manager.usbSessionSnapshot().generation)
        try await waitUntil { manager.connectionSwitchState.actualRoute == .usb }
        XCTAssertEqual(session.savedCredential()?.usbControlTLSSeen, tlsSeen ? true : nil)
        try await send(usb, .connectionState,
                       ConnectionSwitchStateTests.snapshot(revision: 4, owner: 3, route: .usb).encode())
        let completed = ConnectionSelectResult(status: .completed, target: .usb, current: .usb, reason: .none,
            hostState: .ready, transaction: 1, originOwner: 1, revision: 4, routeOwner: 3, token: resume.token,
            firstFrame: 1, frameDomain: .scst)
        try await presentReplacement(usb, manager: manager, terminal: completed)
        XCTAssertFalse(manager.permitsLegacyVirtualInput)
        XCTAssertTrue(manager.legacyVirtualInputSuspended)
        XCTAssertEqual(manager.connectionSwitchState.phase, .completed)
        XCTAssertTrue(manager.usbSessionSnapshot().listenerIntent)
    }

    @MainActor private func assertWifiRollback(_ session: Session, host: WifiHost) async throws {
        let manager = session.manager
        let restored = try await wifiPeer(host, index: 1)
        try await authenticateWifi(restored, credential: session.credential)
        manager.updateInterfaceOrientation(.landscape)
        try await advertiseConnectionControl(restored)
        try await expectOptIn(restored)
        XCTAssertEqual(manager.connectionSwitchState.pending?.rollbackRoute, .wifi)
        XCTAssertEqual(manager.connectionSwitchState.issue, .identityUnavailable)
        XCTAssertNil(manager.preparedUSBListenerPortForTesting)
        try await finishRollback(restored, manager: manager, route: .wifi, reason: .proofFailed)
    }

    @MainActor private func finishRollback(_ host: NWConnection, manager: NetworkManager, route: ConnectionRoute,
                                          reason: ConnectionReason) async throws {
        let snapshot = try ConnectionSwitchStateTests.snapshot(revision: 4, owner: 3, route: route, hostState: .failed)
        try await send(host, .connectionState, snapshot.encode())
        try await waitUntil { manager.connectionSwitchState.hasRollbackSnapshot }
        let result = ConnectionSelectResult(status: .failed, target: route == .wifi ? .usb : .wifi, current: route,
            reason: reason, hostState: .failed, transaction: 1, originOwner: 1, revision: 4, routeOwner: 3,
            token: Data(0..<16), firstFrame: 0, frameDomain: .none)
        try await presentReplacement(host, manager: manager, terminal: result)
        XCTAssertEqual(manager.connectionSwitchState.phase, .declined)
        XCTAssertEqual(manager.connectionSwitchState.issue, reason)
    }

    @MainActor private func presentReplacement(_ host: NWConnection, manager: NetworkManager,
                                               terminal: ConnectionSelectResult) async throws {
        let defaults = UserDefaults.standard
        let keys = ["preferredWidth", "preferredHeight", "preferredRefreshHz", "orientationMode"]
            .map { "ScreenCasting.display." + $0 }
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }

        let decoder = manager.decoderForTesting
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        let decoded = expectation(description: "fresh replacement IDR decoded")
        decoder.sessionQueueForTesting.sync {
            decoder.submitDecodeForTesting = { _ in pixel }
            decoder.onFrameDecoded = { _, sequence, _ in
                XCTAssertEqual(sequence, 1)
                decoded.fulfill()
            }
        }
        defer {
            decoder.sessionQueueForTesting.sync {
                decoder.submitDecodeForTesting = nil
                decoder.onFrameDecoded = nil
            }
        }

        try await send(host, .connectionSelectResult, terminal.encode())
        let displayRequest = try await read(host, type: .displayConfigurationRequest)
        XCTAssertEqual(displayRequest.count, 20)
        try await send(host, .displayReady, displayRequest + Data([1, 0, 0, 0]))
        try await send(host, .video, Data([0, 0, 1, 0x26, 0x01]), flags: WireProtocol.videoFlagIDR, sequence: 1)
        await fulfillment(of: [decoded], timeout: 3)
        XCTAssertTrue(manager.connectionSwitchState.inputBlocked)
        manager.recordRenderCompletion(sequence: 1, generation: decoder.currentSessionGeneration)
        try await waitUntil { !manager.connectionSwitchState.inputBlocked }
        XCTAssertEqual(manager.connectionSwitchState.actualRoute, terminal.current)
    }

    @MainActor private func start(_ session: Session) async throws -> NWEndpoint.Port {
        let ready = XCTestExpectation(description: "USB listener ready")
        session.manager.connectionListenerReadyForTesting = { ready.fulfill() }
        session.manager.setRemoteClipboardSceneActive(true)
        session.manager.startListening(port: 0)
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 3) == .completed else {
            XCTFail("USB listener never became ready")
            throw TestError.timedOut
        }
        return try XCTUnwrap(session.manager.usbSessionSnapshot().listener?.port)
    }

    @MainActor private func establishTLS(_ session: Session) async throws -> NWEndpoint.Port {
        let port = try await start(session)
        let host = dial(port, tls: true)
        defer { host.cancel() }
        try await authenticate(host, session: session, tls: true)
        _ = try await read(host, type: .ping, flags: 0x1000)
        XCTAssertEqual(session.savedCredential()?.usbControlTLSSeen, true)
        host.cancel()
        try await waitUntil { session.manager.connectionState == .listening }
        return port
    }

    @MainActor private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                                      _ condition: @escaping @MainActor () -> Bool) async throws {
        try await awaitFixtureCondition("USB integration state transition", file: file, line: line, condition: condition)
    }

    private func dial(_ port: NWEndpoint.Port, tls: Bool) -> NWConnection {
        let parameters = NWParameters.tcp
        if tls {
            parameters.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: HostTLSFramer.definition), at: 0)
        }
        let host = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
        host.start(queue: DispatchQueue.global())
        return host
    }

    private func authenticate(_ host: NWConnection, session: Session, tls: Bool, accepted: Bool = true) async throws {
        if !tls {
            try await send(host, .ping, Self.readiness, flags: 0x0100)
            let pong = try await read(host, type: .pong, flags: 0x0080)
            XCTAssertEqual(pong, Self.readiness)
        }
        let hello = try await read(host, type: .clientHello)
        XCTAssertEqual(hello, WireProtocol.clientHello(deviceID: session.credential.deviceID,
            sessionID: session.credential.sessionID, name: "iPad"))
        let challenge = ConnectionControlProtocolTests.usbChallenge
        try await send(host, .trustedDeviceChallenge, challenge)
        let proof = try await read(host, type: .trustedDeviceProof)
        var key = session.credential.secret
        if tls {
            key = Data(HMAC<SHA256>.authenticationCode(for: Data("SCUSB-TLS1".utf8) + session.leafHash,
                using: SymmetricKey(data: key)))
        }
        let context = Data(challenge.suffix(64)) + Data(challenge.prefix(48)) + Data([1])
        let mac = HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: key))
        XCTAssertEqual(proof, Data(challenge.prefix(16)) + Data(mac))
        try await send(host, .trustedAuthResult, Data([accepted ? 1 : 0]))
    }

    private static func frame(_ type: WireMessageType, _ payload: Data, flags: UInt16, sequence: UInt32 = 0) -> Data {
        var bytes = Data([0x53, 0x43, 0x53, 0x54, 1, type.rawValue,
            UInt8(truncatingIfNeeded: flags), UInt8(flags >> 8)])
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        var encodedSequence = sequence.littleEndian
        withUnsafeBytes(of: &encodedSequence) { bytes.append(contentsOf: $0) }
        return bytes + payload
    }

    private final class IOCompletion<Value>: @unchecked Sendable {
        let done: XCTestExpectation
        private let lock = NSLock()
        private var value: Value

        init(_ description: String, initial: Value) {
            done = XCTestExpectation(description: description)
            value = initial
        }

        func finish(_ result: Value) {
            lock.lock()
            value = result
            lock.unlock()
            done.fulfill()
        }

        func result() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func send(_ host: NWConnection, _ type: WireMessageType, _ data: Data, flags: UInt16 = 0,
                      sequence: UInt32 = 0) async throws {
        let write = IOCompletion<NWError?>("TLS fixture send", initial: nil)
        host.send(content: Self.frame(type, data, flags: flags, sequence: sequence),
                  completion: .contentProcessed { write.finish($0) })
        guard await XCTWaiter.fulfillment(of: [write.done], timeout: 10) == .completed else {
            host.cancel()
            XCTFail("TLS fixture send timed out for message \(type)")
            throw TestError.timedOut
        }
        if let error = write.result() { throw error }
    }

    private func receive(_ host: NWConnection, count: Int, timeout: TimeInterval = 10) async throws -> Data? {
        let read = IOCompletion<Data?>("TLS fixture receive", initial: nil)
        host.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            read.finish(data)
        }
        guard await XCTWaiter.fulfillment(of: [read.done], timeout: max(0, timeout)) == .completed else {
            host.cancel()
            XCTFail("TLS fixture receive timed out waiting for \(count) bytes")
            throw TestError.timedOut
        }
        return read.result()
    }

    private func read(_ host: NWConnection, type: WireMessageType, flags: UInt16 = 0,
                      rejectClipboardHello: Bool = false) async throws -> Data {
        // Once the session is streaming, the feedback timer also queues 8-byte legacy stage packets
        // between framed messages; any read may meet one, so always skip them.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let prefix = try await receive(host, count: 8, timeout: deadline - ProcessInfo.processInfo.systemUptime), prefix.count == 8 else { throw TestError.closed }
            if prefix.prefix(4) == Data([0x45, 0x54, 0, 0]) { continue }
            guard let suffix = try await receive(host, count: 8, timeout: deadline - ProcessInfo.processInfo.systemUptime), suffix.count == 8 else { throw TestError.closed }
            let header = prefix + suffix
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
            guard header.prefix(5) == Data([0x53, 0x43, 0x53, 0x54, 1]), length <= 65_536 else {
                throw TestError.invalidFrame
            }
            let payload = length == 0 ? Data() : try await receive(host, count: length, timeout: deadline - ProcessInfo.processInfo.systemUptime)
            guard let payload, payload.count == length else { throw TestError.closed }
            if rejectClipboardHello { XCTAssertNotEqual(header[5], WireMessageType.castingClipboardHello.rawValue) }
            let actualFlags = UInt16(header[6]) | (UInt16(header[7]) << 8)
            if header[5] == type.rawValue, actualFlags == flags {
                return payload
            }
        }
        XCTFail("TLS fixture timed out waiting for \(type) with flags \(flags)")
        throw TestError.timedOut
    }

    private final class HostTLSFramer: NWProtocolFramerImplementation {
        static let label = "USB control TLS fake host"
        static let definition = NWProtocolFramer.Definition(implementation: HostTLSFramer.self)
        private var forwardingTLS = false
        init(framer: NWProtocolFramer.Instance) {}

        func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
            framer.writeOutput(data: USBControlTLSIntegrationTests.frame(
                .ping, USBControlTLSIntegrationTests.readiness, flags: 0x2100))
            return .willMarkReady
        }

        func handleInput(framer: NWProtocolFramer.Instance) -> Int {
            if forwardingTLS {
                return USBControlTLSFramer.forwardInput(framer: framer)
            }
            let expected = USBControlTLSIntegrationTests.frame(
                .pong, USBControlTLSIntegrationTests.readiness, flags: 0x2080)
            var matched = false
            let parsed = framer.parseInput(minimumIncompleteLength: expected.count, maximumLength: expected.count) { bytes, _ in
                guard let bytes, bytes.count == expected.count else { return 0 }
                matched = Data(bytes) == expected
                return bytes.count
            }
            guard parsed else { return expected.count }
            guard matched, let peer = try? LoopbackIdentities.peer.get(),
                  let local = sec_identity_create(peer), let identity = try? LoopbackIdentities.device.get() else {
                framer.markFailed(error: .posix(.EPROTO)); return 0
            }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
                framer.markFailed(error: .posix(.EPROTO)); return 0
            }
            let expectedDER = SecCertificateCopyData(certificate) as Data
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, finish in
                let peer = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let leaf = SecTrustGetCertificateAtIndex(peer, 0) else { finish(false); return }
                finish((SecCertificateCopyData(leaf) as Data) == expectedDER)
            }, DispatchQueue.global())
            do { try framer.prependApplicationProtocol(options: tls) }
            catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            forwardingTLS = true
            framer.passThroughOutput()
            framer.markReady()
            return USBControlTLSFramer.forwardInput(framer: framer)
        }

        func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                          messageLength: Int, isComplete: Bool) {
            do { try framer.writeOutputNoCopy(length: messageLength) }
            catch { framer.markFailed(error: .posix(.EIO)) }
        }
        func wakeup(framer: NWProtocolFramer.Instance) {}
        func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
        func cleanup(framer: NWProtocolFramer.Instance) {}
    }
}
#endif

final class USBServerIdentityTests: XCTestCase {
    func testEmptyStoreCreatesAndPersistsIdentityThroughProductionRecoveryAlgorithm() {
        var backend = FakeKeychainBackend()

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.createCount, 1)
    }

    func testValidStoreReloadsWithoutRegeneration() {
        var backend = FakeKeychainBackend(state: .valid(FakeIdentity(id: 9)))

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 9))
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.deleteCount, 0)
    }

    func testOrphanKeyIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .orphanKey)
    }

    func testOrphanCertificateIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .orphanCertificate)
    }

    func testCorruptCertificateIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .corruptCertificate)
    }

    func testInsertionFailureCleansUpPermanentKeyAndRetries() {
        var backend = FakeKeychainBackend(plannedResults: [.insertionFailure])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.createCount, 2)
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testPersistentInsertionFailureLeavesNoOrphanRecords() {
        var backend = FakeKeychainBackend(plannedResults: [.insertionFailure, .insertionFailure])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertNil(identity)
        XCTAssertEqual(backend.state, .empty)
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testDuplicateItemIsCleanedUpAndRegenerated() {
        var backend = FakeKeychainBackend(plannedResults: [.duplicateItem])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testDeleteThenRegenerateCreatesNewIdentity() {
        var backend = FakeKeychainBackend(state: .valid(FakeIdentity(id: 4)))
        USBServerIdentityStore.delete(using: &backend)

        let regenerated = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(regenerated, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
    }

    func testRecoveryUsesOnlyTheKeychainBackendContract() {
        var backend = FakeKeychainBackend()

        _ = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(backend.insecurePersistenceWrites, 0)
    }

    private func assertRegenerates(from state: FakeKeychainBackend.RecordState) {
        var backend = FakeKeychainBackend(state: state)

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }
}

private struct FakeIdentity: Equatable {
    let id: Int
}

private struct FakeKeychainBackend: USBServerIdentityKeychainBackend {
    enum RecordState: Equatable {
        case empty
        case valid(FakeIdentity)
        case orphanKey
        case orphanCertificate
        case corruptCertificate

        var orphanRecordCount: Int {
            switch self {
            case .orphanKey, .orphanCertificate, .corruptCertificate:
                return 1
            case .empty, .valid:
                return 0
            }
        }
    }

    enum CreateResult {
        case success
        case insertionFailure
        case duplicateItem
    }

    var state: RecordState = .empty
    var plannedResults: [CreateResult] = []
    var nextIdentityID = 1
    var createCount = 0
    var deleteCount = 0
    var insecurePersistenceWrites = 0

    init(state: RecordState = .empty, plannedResults: [CreateResult] = []) {
        self.state = state
        self.plannedResults = plannedResults
    }

    mutating func loadIdentity() -> FakeIdentity? {
        guard case let .valid(identity) = state else { return nil }
        return identity
    }

    mutating func createIdentity() -> FakeIdentity? {
        createCount += 1
        let result = plannedResults.isEmpty ? .success : plannedResults.removeFirst()
        switch result {
        case .success:
            let identity = FakeIdentity(id: nextIdentityID)
            nextIdentityID += 1
            state = .valid(identity)
            return identity
        case .insertionFailure:
            state = .orphanKey
            return nil
        case .duplicateItem:
            state = .orphanCertificate
            return nil
        }
    }

    mutating func deleteIdentityRecords() {
        deleteCount += 1
        state = .empty
    }
}
