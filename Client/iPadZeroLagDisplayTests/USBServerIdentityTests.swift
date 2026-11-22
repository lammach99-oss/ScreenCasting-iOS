import XCTest
@testable import iPadCasting

#if targetEnvironment(simulator)
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
            host.cancel()
            try await waitUntil { session.manager.connectionState == .listening }
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
        let host = dial(try await start(session), tls: true)
        defer { host.cancel() }
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        try await waitUntil {
            switch host.state {
            case .failed, .waiting: return true
            default: return false
            }
        }
        XCTAssertNil(session.savedCredential()?.usbControlTLSSeen)
    }

    @MainActor func testRejectedProofClosesAdvertisedSocket() async throws {
        let session = try Session()
        defer { session.stop() }
        let host = dial(try await start(session), tls: true)
        defer { host.cancel() }
        try await authenticate(host, session: session, tls: true, accepted: false)
        try await waitUntil { session.manager.connectionState == Self.secureFailure }
        let remaining = await receive(host, count: 1)
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
        let remaining = await receive(host, count: 1)
        XCTAssertTrue(remaining?.isEmpty ?? true)
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
        let plaintext = await receive(usb, count: 1)
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
        let replacement = dial(usbPort, tls: true)
        defer { replacement.cancel() }
        try await authenticate(replacement, session: session, tls: true)
        manager.updateInterfaceOrientation(.landscape)
        try await advertiseConnectionControl(replacement)
        try await expectOptIn(replacement)
        try await finishRollback(replacement, manager: manager, route: .usb, reason: .connectionLost)
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
            let identity = try XCTUnwrap(USBServerIdentityStore.loadOrCreate())
            let peer = try XCTUnwrap(USBServerIdentityStore.simulatorPeerIdentity())
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
            USBServerIdentityStore.deleteSimulatorPeerIdentity()
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
        let probeReply = await receive(probe, count: 48)
        XCTAssertTrue(probeReply == Self.frame(.pong, pong, flags: 0x0400))
        let trailingPlaintext = await receive(probe, count: 1)
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
        let port = try await acceptWifiToUsb(session, incumbent: incumbent)
        let usb = dial(port, tls: tlsSeen)
        defer { usb.cancel() }

        let manager = session.manager
        try await authenticate(usb, session: session, tls: tlsSeen)
        manager.updateInterfaceOrientation(.landscape)
        try await advertiseConnectionControl(usb)
        let payload = try await read(usb, type: .connectionHello)
        let resume = try ConnectionHello.decode(payload)
        let expected = ConnectionProofContext(target: .usb, transaction: 1, owner: 1, revision: 2,
            token: Data(0..<16), challenge: Data(32..<64), secret: Data(64..<96)).resumeHello()
        XCTAssertTrue(resume == expected)
        try await waitUntil { manager.connectionSwitchState.actualRoute == .usb }
        XCTAssertEqual(session.savedCredential()?.usbControlTLSSeen, tlsSeen ? true : nil)
        try await send(usb, .connectionState,
                       ConnectionSwitchStateTests.snapshot(revision: 4, owner: 3, route: .usb).encode())
        let completed = ConnectionSelectResult(status: .completed, target: .usb, current: .usb, reason: .none,
            hostState: .ready, transaction: 1, originOwner: 1, revision: 4, routeOwner: 3, token: resume.token,
            firstFrame: 1, frameDomain: .scst)
        try await presentReplacement(usb, manager: manager, terminal: completed)
        XCTAssertEqual(manager.connectionSwitchState.phase, .completed)
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
        let ready = expectation(description: "USB listener ready")
        session.manager.connectionListenerReadyForTesting = { ready.fulfill() }
        session.manager.setRemoteClipboardSceneActive(true)
        session.manager.startListening(port: 0)
        await fulfillment(of: [ready], timeout: 3)
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

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TestError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func dial(_ port: NWEndpoint.Port, tls: Bool) -> NWConnection {
        let parameters = NWParameters.tcp
        if tls {
            parameters.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: HostTLSFramer.definition), at: 0)
        }
        let host = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
        host.start(queue: DispatchQueue.global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [weak host] in host?.cancel() }
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

    private func send(_ host: NWConnection, _ type: WireMessageType, _ data: Data, flags: UInt16 = 0,
                      sequence: UInt32 = 0) async throws {
        let error: NWError? = await withCheckedContinuation { continuation in
            host.send(content: Self.frame(type, data, flags: flags, sequence: sequence), completion: .contentProcessed {
                continuation.resume(returning: $0)
            })
        }
        if let error { throw error }
    }

    private func receive(_ host: NWConnection, count: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            host.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func read(_ host: NWConnection, type: WireMessageType, flags: UInt16 = 0,
                      rejectClipboardHello: Bool = false) async throws -> Data {
        for _ in 0..<20 {
            guard let header = await receive(host, count: 16), header.count == 16 else { throw TestError.closed }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
            guard header.prefix(5) == Data([0x53, 0x43, 0x53, 0x54, 1]), length <= 65_536 else {
                throw TestError.invalidFrame
            }
            let payload = length == 0 ? Data() : await receive(host, count: length)
            guard let payload, payload.count == length else { throw TestError.closed }
            if rejectClipboardHello { XCTAssertNotEqual(header[5], WireMessageType.castingClipboardHello.rawValue) }
            let actualFlags = UInt16(header[6]) | (UInt16(header[7]) << 8)
            if header[5] == type.rawValue, actualFlags == flags {
                return payload
            }
        }
        throw TestError.invalidFrame
    }

    private final class HostTLSFramer: NWProtocolFramerImplementation {
        static let label = "USB control TLS fake host"
        static let definition = NWProtocolFramer.Definition(implementation: HostTLSFramer.self)
        init(framer: NWProtocolFramer.Instance) {}

        func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
            framer.writeOutput(data: USBControlTLSIntegrationTests.frame(
                .ping, USBControlTLSIntegrationTests.readiness, flags: 0x2100))
            return .willMarkReady
        }

        func handleInput(framer: NWProtocolFramer.Instance) -> Int {
            let expected = USBControlTLSIntegrationTests.frame(
                .pong, USBControlTLSIntegrationTests.readiness, flags: 0x2080)
            var matched = false
            let parsed = framer.parseInput(minimumIncompleteLength: expected.count, maximumLength: expected.count) { bytes, _ in
                guard let bytes, bytes.count == expected.count else { return 0 }
                matched = Data(bytes) == expected
                return bytes.count
            }
            guard parsed else { return expected.count }
            guard matched, let peer = USBServerIdentityStore.simulatorPeerIdentity(),
                  let local = sec_identity_create(peer), let identity = USBServerIdentityStore.copy() else {
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
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
            return 0
        }

        func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                          messageLength: Int, isComplete: Bool) {}
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
