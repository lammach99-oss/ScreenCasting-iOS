import XCTest
import Network
import Metal
import Combine
@testable import iPadCasting

#if targetEnvironment(simulator)
final class PairingReconnectRegressionTests: XCTestCase {
    private final class Backing: TrustedHostCredentialBacking {
        private var records: [String: Data] = [:]
        var canDelete = true
        var rejectDelete: (String) -> Bool = { _ in false }
        var rejectRead: (String) -> Bool = { _ in false }
        func load(fingerprint: String) -> Data? { records[fingerprint] }
        func read(fingerprint: String) -> TrustedHostBackingRead {
            if rejectRead(fingerprint) { return .failed }
            return records[fingerprint].map { .found($0) } ?? .missing
        }
        func save(_ data: Data, fingerprint: String) -> Bool { records[fingerprint] = data; return true }
        func delete(fingerprint: String) -> Bool {
            guard canDelete, !rejectDelete(fingerprint) else { return false }
            records.removeValue(forKey: fingerprint)
            return true
        }
    }

    private struct Fixture {
        let defaults: UserDefaults
        let network: NetworkManager
        let credentials = Backing()
        let pins = Backing()

        init(defaults: UserDefaults) {
            self.defaults = defaults
            network = NetworkManager(userDefaults: defaults)
            network.installTrustedHostStoresForTesting(credentials: credentials, pins: pins)
        }

        @discardableResult
        func pair(_ endpoint: NWEndpoint, identity: UInt8) -> TrustedHostCredential {
            let credential = TrustedHostCredential(fingerprint: "fixture-pin-\(identity)",
                hostID: Data(repeating: identity, count: 16), deviceID: Data(repeating: identity, count: 16),
                secret: Data(repeating: 0, count: 32), sessionID: Data(repeating: 0, count: 16))
            XCTAssertTrue(TrustedHostCredentialStore(backing: credentials).save(credential))
            XCTAssertTrue(TrustedHostFingerprintStore(backing: pins).save(
                credential.fingerprint, endpoint: endpoint, hostID: credential.hostID))
            return credential
        }

        func saveTarget(_ endpoint: NWEndpoint) throws {
            WifiReconnectTargetStore.save(try XCTUnwrap(WifiReconnectTargetPolicy.target(from: endpoint)), defaults: defaults)
        }

        func connect(_ endpoint: NWEndpoint, credential: TrustedHostCredential) {
            _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.setPairedHostForTesting(endpoint: endpoint, credential: credential)
            network.beginTransferWriterForTesting()
        }

        func isPaired(_ credential: TrustedHostCredential) -> Bool {
            network.networkQueueForTesting.sync {
                TrustedHostCredentialStore(backing: credentials).load(fingerprint: credential.fingerprint) != nil
            }
        }
    }

    @MainActor func testForgetWaitsForTheAuthenticatedHostResult() async throws {
        for accepted in [true, false] {
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let fixture = Fixture(defaults: defaults)
            let endpoint = service("Fixture A")
            let credential = fixture.pair(endpoint, identity: 1)
            try fixture.saveTarget(endpoint)
            let sent = expectation(description: "Fake host receives Forget")
            fixture.network.controlSendForAudioTesting = { bytes, complete in
                if bytes[5] == WireMessageType.forgetDevice.rawValue {
                    XCTAssertEqual(Data(bytes.dropFirst(WireProtocol.headerSize)), Data([1]) + credential.deviceID)
                    sent.fulfill()
                }
                complete(nil)
            }
            fixture.connect(endpoint, credential: credential)
            fixture.network.receiveIdentityWireForTesting(type: .forgetDeviceResult, payload: Data([1, 1]))
            XCTAssertTrue(fixture.isPaired(credential), "An unsolicited reply cannot remove pairing")
            fixture.network.forgetTrustedHost()
            await fulfillment(of: [sent], timeout: 2)
            XCTAssertTrue(fixture.isPaired(credential))
            fixture.network.receiveIdentityWireForTesting(type: .forgetDeviceResult, payload: Data([1, 2]))
            XCTAssertTrue(fixture.isPaired(credential), "A malformed reply cannot settle Forget")
            fixture.network.receiveIdentityWireForTesting(type: .forgetDeviceResult,
                payload: Data([1, accepted ? 1 : 0]))
            await drainMainQueue()
            XCTAssertFalse(fixture.isPaired(credential))
            XCTAssertFalse(fixture.network.hasReconnectTarget)
            XCTAssertEqual(fixture.network.trustedHostForgetOutcome, accepted ? .both : .localOnly)
        }
    }

    @MainActor func testForgetTimesOutLocallyWhenHostNeverReplies() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let endpoint = service("Fixture A")
        let credential = fixture.pair(endpoint, identity: 1)
        try fixture.saveTarget(endpoint)
        fixture.network.controlSendForAudioTesting = { _, complete in complete(nil) }
        fixture.connect(endpoint, credential: credential)
        let done = expectation(description: "Local-only outcome after missing reply")
        let observation = fixture.network.$trustedHostForgetOutcome.sink { outcome in
            if outcome == .localOnly { done.fulfill() }
        }
        fixture.network.forgetTrustedHost()
        await fulfillment(of: [done], timeout: 5)
        observation.cancel()
        XCTAssertFalse(fixture.isPaired(credential))
        XCTAssertFalse(fixture.network.hasReconnectTarget)
    }

    @MainActor func testForgettingAnotherPCPreservesSavedTargetAndIncumbent() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let address = NWEndpoint.Host.ipv4(.loopback)
        let forgotten = NWEndpoint.hostPort(host: address, port: 27015), retained = service("Fixture B")
        let old = fixture.pair(forgotten, identity: 1)
        let current = fixture.pair(retained, identity: 2)
        try fixture.saveTarget(retained)
        fixture.network.controlSendForAudioTesting = { _, complete in complete(nil) }
        fixture.connect(retained, credential: current)
        defer { fixture.network.stopForTesting() }
        let generation = fixture.network.wifiSessionSnapshotForTesting().committedGeneration
        fixture.network.forgetTrustedHost(host: String(describing: address), port: 27015)
        fixture.network.networkQueueForTesting.sync {}
        await drainMainQueue()
        XCTAssertFalse(fixture.isPaired(old))
        XCTAssertTrue(fixture.isPaired(current))
        XCTAssertEqual(WifiReconnectTargetStore.load(defaults: defaults)?.endpoint, retained)
        XCTAssertTrue(fixture.network.hasReconnectTarget)
        XCTAssertEqual(fixture.network.wifiSessionSnapshotForTesting().committedGeneration, generation)
        XCTAssertEqual(fixture.network.trustedHostForgetOutcome, .localOnly)
    }

    @MainActor func testForgetReportsLocalStorageFailure() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let endpoint = service("Fixture A")
        let credential = fixture.pair(endpoint, identity: 1)
        try fixture.saveTarget(endpoint)
        fixture.credentials.canDelete = false
        fixture.network.forgetTrustedHost()
        fixture.network.networkQueueForTesting.sync {}
        await drainMainQueue()
        XCTAssertTrue(fixture.isPaired(credential))
        XCTAssertTrue(fixture.network.hasReconnectTarget)
        XCTAssertEqual(fixture.network.trustedHostForgetOutcome, .localFailed(pcConfirmed: false))
    }

    @MainActor func testPartialForgetSurvivesRelaunchAndRetriesKeychainCleanup() async throws {
        for failedKey in ["identity.", "endpoint.", "index.", "selected-identity", "selected-host"] {
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let fixture = Fixture(defaults: defaults)
            let endpoint = service("Fixture A")
            let credential = fixture.pair(endpoint, identity: 1)
            try fixture.saveTarget(endpoint)
            fixture.network.networkQueueForTesting.sync {
                _ = fixture.pins.save(Data(credential.fingerprint.utf8), fingerprint: "selected-host")
                fixture.pins.rejectDelete = { $0.hasPrefix(failedKey) }
            }

            fixture.network.forgetTrustedHost()
            fixture.network.networkQueueForTesting.sync {}
            await drainMainQueue()
            XCTAssertFalse(fixture.isPaired(credential))
            XCTAssertFalse(fixture.network.hasReconnectTarget)
            XCTAssertEqual(fixture.network.trustedHostForgetOutcome, .cleanupIncomplete(pcConfirmed: false))

            let relaunched = NetworkManager(userDefaults: defaults)
            relaunched.installTrustedHostStoresForTesting(credentials: fixture.credentials, pins: fixture.pins)
            XCTAssertEqual(relaunched.trustedHostForgetOutcome, .cleanupIncomplete(pcConfirmed: false))
            if failedKey == "identity." || failedKey == "endpoint." {
                try fixture.saveTarget(endpoint)
                relaunched.reconnectRouteForTesting = { _, _ in XCTFail("Pending cleanup allowed a reconnect") }
                relaunched.reconnectLastPC()
                relaunched.networkQueueForTesting.sync {}
            }
            relaunched.networkQueueForTesting.sync { fixture.pins.rejectDelete = { _ in false } }
            relaunched.retryTrustedHostCleanup()
            relaunched.networkQueueForTesting.sync {}
            await drainMainQueue()
            XCTAssertEqual(relaunched.trustedHostForgetOutcome, .localOnly)
            XCTAssertFalse(relaunched.hasReconnectTarget)
            relaunched.networkQueueForTesting.sync {
                let index = "index." + credential.fingerprint
                XCTAssertNil(fixture.pins.load(fingerprint: index))
                XCTAssertNil(TrustedHostFingerprintStore(backing: fixture.pins).load(endpoint: endpoint))
                XCTAssertNil(TrustedHostFingerprintStore(backing: fixture.pins).fingerprintForCleanup(endpoint: endpoint))
                XCTAssertNil(TrustedHostFingerprintStore(backing: fixture.pins).load())
            }
        }
    }

    func testUnreadableIndexPreventsPinSaveAndPreservesCleanupInventory() throws {
        let pins = Backing()
        let store = TrustedHostFingerprintStore(backing: pins)
        let fingerprint = "fixture-pin"
        let index = "index." + fingerprint
        let hostID = Data(repeating: 1, count: 16)
        let first = service("Fixture A")
        let second = service("Fixture B")
        XCTAssertTrue(store.save(fingerprint, endpoint: first, hostID: hostID))
        let originalIndex = try XCTUnwrap(pins.load(fingerprint: index))
        pins.rejectRead = { $0 == index }
        XCTAssertFalse(store.save(fingerprint, endpoint: second, hostID: hostID) {
            XCTFail("Unreadable index allowed a credential write")
            return true
        })
        XCTAssertFalse(store.delete(fingerprint: fingerprint))
        XCTAssertEqual(pins.load(fingerprint: index), originalIndex)
        pins.rejectRead = { _ in false }
        XCTAssertTrue(store.delete(fingerprint: fingerprint))
        for key in try JSONDecoder().decode([String].self, from: originalIndex) {
            XCTAssertNil(pins.load(fingerprint: key))
        }
    }

    @MainActor func testForgettingCurrentSessionPreservesAnotherPCsReconnectTarget() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let current = service("Fixture A"), saved = service("Fixture B")
        let active = fixture.pair(current, identity: 1)
        let retained = fixture.pair(saved, identity: 2)
        try fixture.saveTarget(saved)
        let sent = expectation(description: "Current PC receives Forget")
        fixture.network.controlSendForAudioTesting = { bytes, complete in
            if bytes[5] == WireMessageType.forgetDevice.rawValue {
                XCTAssertEqual(Data(bytes.dropFirst(WireProtocol.headerSize)), Data([1]) + active.deviceID)
                sent.fulfill()
            }
            complete(nil)
        }
        fixture.connect(current, credential: active)
        fixture.network.forgetCurrentTrustedHost()
        await fulfillment(of: [sent], timeout: 2)
        fixture.network.receiveIdentityWireForTesting(type: .forgetDeviceResult, payload: Data([1, 1]))
        await drainMainQueue()
        XCTAssertFalse(fixture.isPaired(active))
        XCTAssertTrue(fixture.isPaired(retained))
        XCTAssertEqual(WifiReconnectTargetStore.load(defaults: defaults)?.endpoint, saved)
        XCTAssertEqual(fixture.network.trustedHostForgetOutcome, .both)
    }

    @MainActor func testForgettingAnAliasClearsTheSamePCsSavedTarget() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let manual = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 27015)
        let bonjour = service("Fixture A")
        fixture.pair(manual, identity: 1)
        fixture.pair(bonjour, identity: 1)
        try fixture.saveTarget(manual)
        fixture.network.forgetTrustedHost(endpoint: bonjour)
        fixture.network.networkQueueForTesting.sync {}
        await drainMainQueue()
        XCTAssertFalse(fixture.network.hasReconnectTarget)
        XCTAssertEqual(fixture.network.trustedHostForgetOutcome, .localOnly)
    }

    func testReconnectPrefersVerifiedBonjourAndFallsBackToManual() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let manual = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 27015)
        let bonjour = service("Fixture A"), other = service("Fixture B")
        let trusted = fixture.pair(manual, identity: 1)
        fixture.pair(bonjour, identity: 1)
        fixture.pair(other, identity: 2)
        try fixture.saveTarget(manual)
        fixture.network.updateDiscoveredWifiEndpoints([other, bonjour])
        var attempted: [NWEndpoint] = []
        fixture.network.reconnectRouteForTesting = { endpoint, fingerprint in
            XCTAssertEqual(fingerprint, trusted.fingerprint)
            attempted.append(endpoint)
        }
        fixture.network.reconnectLastPC()
        fixture.network.reconnectLastPC()
        fixture.network.networkQueueForTesting.sync {}
        XCTAssertEqual(attempted, [bonjour, manual])
        XCTAssertEqual(WifiReconnectTargetStore.load(defaults: defaults)?.endpoint, manual)
    }

    func testRemoteReconnectPrefersKnownDNSAliasWithoutChangingThePort() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: NetworkManager.remoteControlPort))
        let manual = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let dns = NWEndpoint.hostPort(host: RemoteHostAddress.networkHost(UUID().uuidString.lowercased() + ".example"), port: port)
        let bonjour = service("Fixture A")
        let trusted = fixture.pair(manual, identity: 1)
        fixture.pair(dns, identity: 1)
        fixture.pair(bonjour, identity: 1)
        try fixture.saveTarget(manual)
        fixture.network.updateDiscoveredWifiEndpoints([bonjour])
        var attempted: [NWEndpoint] = []
        fixture.network.reconnectRouteForTesting = { endpoint, fingerprint in
            XCTAssertEqual(fingerprint, trusted.fingerprint)
            attempted.append(endpoint)
        }
        fixture.network.reconnectLastPC()
        fixture.network.reconnectLastPC()
        fixture.network.networkQueueForTesting.sync {}
        XCTAssertEqual(attempted, [dns, manual])
    }

    func testRetryProbesNewBonjourRouteUsingTheSavedIdentity() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Fixture(defaults: defaults)
        let manual = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 27015)
        let newRoute = service("Fixture A"), other = service("Fixture B")
        let trusted = fixture.pair(manual, identity: 1)
        fixture.pair(other, identity: 2)
        try fixture.saveTarget(manual)
        var attempted: [NWEndpoint] = []
        fixture.network.reconnectRouteForTesting = { endpoint, fingerprint in
            XCTAssertEqual(fingerprint, trusted.fingerprint)
            attempted.append(endpoint)
        }
        fixture.network.reconnectLastPC()
        fixture.network.updateDiscoveredWifiEndpoints([other, newRoute])
        fixture.network.reconnectLastPC()
        fixture.network.networkQueueForTesting.sync {}
        XCTAssertEqual(attempted, [manual, newRoute])
    }

    private func service(_ fixture: String) -> NWEndpoint {
        .service(name: fixture, type: "_screencasting._tcp", domain: "local.", interface: nil)
    }

    @MainActor private func drainMainQueue() async {
        let done = expectation(description: "Pairing outcome published")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }
}
#endif

final class AuthenticationStageRegressionTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testSessionResumeResultAcceptsNewAndResumedAfterPairingOnly() {
        let cases: [(UInt8, Int, UInt16, Bool, Bool)] = [
            (0, 17, 0, true, true), (1, 17, 0, true, true),
            (2, 17, 0, true, false), (1, 16, 0, true, false), (0, 18, 0, true, false),
            (1, 17, 1, true, false), (0, 17, 0, false, false), (1, 17, 0, false, false)
        ]
        for (value, length, flags, paired, accepted) in cases {
            let network = NetworkManager(), credentials = MemoryBacking(), pins = MemoryBacking()
            defer { network.stopForTesting() }
            let endpoint = NWEndpoint.service(name: "fixture", type: "_fixture._tcp", domain: "local", interface: nil)
            network.controlSendForAudioTesting = { _, done in done(nil) }
            _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting()
            network.configureAuthenticationForTesting(confirmed: true, fingerprint: "fixture-pin",
                endpoint: endpoint, credentials: credentials, pins: pins)
            if paired {
                network.receiveIdentityWireForTesting(type: .pairingRequired, payload: Data([0]))
                network.sendAuthPIN("1234")
                network.networkQueueForTesting.sync {}
                network.receiveIdentityWireForTesting(type: .authResult, payload: Data([1]),
                    flags: WireProtocol.realtimeNegotiationSupportedFlag)
                let pairing = Data(repeating: 1, count: 16) + network.authenticationDeviceIDForTesting +
                    Data(repeating: 2, count: 16) + Data(repeating: 3, count: 32)
                network.receiveIdentityWireForTesting(type: .pairingSuccess, payload: pairing)
            }
            network.receiveIdentityWireForTesting(type: .sessionResumeResult,
                payload: Data([value]) + Data(repeating: 4, count: length - 1), flags: flags)
            network.networkQueueForTesting.sync {
                let sessionID = TrustedHostCredentialStore(backing: credentials).load(fingerprint: "fixture-pin")?.sessionID
                let expected: Data? = paired ? Data(repeating: accepted ? 4 : 2, count: 16) : nil
                XCTAssertEqual(sessionID, expected)
            }
        }
    }

    @MainActor func testDuplicatePINSubmissionsWriteOnceAndRejectedPINCanRetry() async {
        let network = NetworkManager(), credentials = MemoryBacking(), pins = MemoryBacking()
        defer { network.stopForTesting() }
        var pinWrites = 0
        network.controlSendForAudioTesting = { data, done in
            if data.count == 8 { pinWrites += 1 }
            done(nil)
        }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.configureAuthenticationForTesting(confirmed: true, fingerprint: "fixture-pin",
            endpoint: .service(name: "fixture", type: "_fixture._tcp", domain: "local", interface: nil),
            credentials: credentials, pins: pins)
        network.receiveIdentityWireForTesting(type: .pairingRequired, payload: Data([0]))

        func submitTwice() {
            network.sendAuthPIN("1234")
            network.sendAuthPIN("1234")
            network.networkQueueForTesting.sync {}
            network.networkQueueForTesting.sync {}
        }
        submitTwice()
        network.networkQueueForTesting.sync { XCTAssertEqual(pinWrites, 1) }
        network.receiveIdentityWireForTesting(type: .authResult, payload: Data([0]))
        let rejected = expectation(description: "Retryable PIN result published")
        DispatchQueue.main.async { rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(network.connectionState, .authFailed(reason: "Incorrect PIN. Please try again."))
        submitTwice()
        network.networkQueueForTesting.sync { XCTAssertEqual(pinWrites, 2) }
    }

    func testQueuedButUnsentPINCannotAuthorizeASuccess() {
        let network = NetworkManager(), credentials = MemoryBacking(), pins = MemoryBacking()
        // Keep Hello in flight so the PIN can be queued but cannot reach the sender.
        network.controlSendForAudioTesting = { _, _ in }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.configureAuthenticationForTesting(confirmed: true, fingerprint: "fixture-pin",
            endpoint: .service(name: "fixture", type: "_fixture._tcp", domain: "local", interface: nil),
            credentials: credentials, pins: pins)
        network.receiveIdentityWireForTesting(type: .pairingRequired, payload: Data([0]))
        network.sendAuthPIN("1234"); network.networkQueueForTesting.sync {}
        network.receiveIdentityWireForTesting(type: .authResult, payload: Data([1]))
        XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration)
        network.networkQueueForTesting.sync { XCTAssertTrue(credentials.values.isEmpty); XCTAssertTrue(pins.values.isEmpty) }
        network.stopForTesting()
    }
    func testRealReceivePathRejectsUnconfirmedOrUnrequestedAuthenticationWithoutPersistence() {
        for confirmed in [false, true] {
            let network = NetworkManager(), credentials = MemoryBacking(), pins = MemoryBacking()
            network.controlSendForAudioTesting = { _, done in done(nil) }
            _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting()
            network.configureAuthenticationForTesting(confirmed: confirmed, fingerprint: "fixture-pin",
                endpoint: .service(name: "fixture", type: "_fixture._tcp", domain: "local", interface: nil),
                credentials: credentials, pins: pins)
            network.receiveIdentityWireForTesting(type: .authResult, payload: Data([1]))
            network.receiveIdentityWireForTesting(type: .pairingSuccess, payload: Data(repeating: 1, count: 80))
            XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration)
            network.networkQueueForTesting.sync {
                XCTAssertTrue(credentials.values.isEmpty); XCTAssertTrue(pins.values.isEmpty)
            }
            network.stopForTesting()
        }
    }
    func testConfirmedPINFlowPersistsOnlyItsOwnCredentialAndOfflineForgetDeletesIt() {
        let network = NetworkManager(), credentials = MemoryBacking(), pins = MemoryBacking()
        let endpoint = NWEndpoint.service(name: "fixture", type: "_fixture._tcp", domain: "local", interface: nil)
        network.controlSendForAudioTesting = { _, done in done(nil) }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.configureAuthenticationForTesting(confirmed: true, fingerprint: "fixture-pin", endpoint: endpoint,
            credentials: credentials, pins: pins)
        network.receiveIdentityWireForTesting(type: .pairingRequired, payload: Data([0]))
        network.sendAuthPIN("1234"); network.networkQueueForTesting.sync {}
        // Negotiation prevents media/audio commit in this authentication-only test.
        network.reconnectAttemptForTesting = 3
        network.receiveIdentityWireForTesting(type: .authResult, payload: Data([1]), flags: WireProtocol.realtimeNegotiationSupportedFlag)
        XCTAssertEqual(network.reconnectAttemptForTesting, 3, "Casting authentication does not prove recovery from a cutover failure")
        let payload = Data(repeating: 1, count: 16) + network.authenticationDeviceIDForTesting +
            Data(repeating: 2, count: 16) + Data(repeating: 3, count: 32)
        network.receiveIdentityWireForTesting(type: .pairingSuccess, payload: payload)
        network.networkQueueForTesting.sync {
            XCTAssertNotNil(TrustedHostCredentialStore(backing: credentials).load(fingerprint: "fixture-pin"))
            XCTAssertEqual(TrustedHostFingerprintStore(backing: pins).load(endpoint: endpoint), "fixture-pin")
        }
        XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration)
        network.forgetTrustedHost(endpoint: endpoint); network.networkQueueForTesting.sync {}
        network.networkQueueForTesting.sync {
            XCTAssertNil(TrustedHostCredentialStore(backing: credentials).load(fingerprint: "fixture-pin"))
            XCTAssertNil(TrustedHostFingerprintStore(backing: pins).load(endpoint: endpoint))
        }
        network.stopForTesting()
    }
    #endif
    func testUnsolicitedResultsCannotCrossIdentityGate() {
        for message in [WireMessageType.authResult, .pairingSuccess, .trustedDeviceChallenge] {
            var auth = WifiAuthenticationState()
            auth.begin(confirmed: false)
            XCTAssertFalse(auth.receive(message, accepted: true))
            XCTAssertFalse(auth.mayPersistPairing)
            XCTAssertFalse(auth.sentHello())
        }
    }
    func testPINAndProofResultsRequireTheirOwnRequestsAndAreOneUse() {
        var auth = WifiAuthenticationState(); auth.begin(confirmed: true)
        XCTAssertTrue(auth.sentHello())
        XCTAssertFalse(auth.receive(.authResult, accepted: true))
        auth.begin(confirmed: true)
        XCTAssertTrue(auth.sentHello()); XCTAssertTrue(auth.receive(.pairingRequired))
        XCTAssertTrue(auth.sentPIN()); XCTAssertTrue(auth.receive(.authResult, accepted: true))
        XCTAssertTrue(auth.mayPersistPairing)
        XCTAssertTrue(auth.receive(.pairingSuccess)); XCTAssertFalse(auth.receive(.pairingSuccess))
        auth.begin(confirmed: true)
        XCTAssertTrue(auth.sentHello()); XCTAssertTrue(auth.receive(.trustedDeviceChallenge))
        XCTAssertTrue(auth.sentProof()); XCTAssertTrue(auth.receive(.authResult, accepted: true))
        XCTAssertFalse(auth.mayPersistPairing)
        XCTAssertTrue(auth.receive(.trustedAuthResult, accepted: true))
        XCTAssertTrue(auth.receive(.sessionResumeResult, accepted: true))
        XCTAssertFalse(auth.receive(.sessionResumeResult, accepted: true))
    }
    private final class MemoryBacking: TrustedHostCredentialBacking {
        var values: [String: Data] = [:]
        func load(fingerprint: String) -> Data? { values[fingerprint] }
        func save(_ data: Data, fingerprint: String) -> Bool { values[fingerprint] = data; return true }
        func delete(fingerprint: String) -> Bool { values.removeValue(forKey: fingerprint); return true }
    }
    func testEndpointPinsAndLegacyMigrationCannotTrustAnotherHost() throws {
        let memory = MemoryBacking(), store = TrustedHostFingerprintStore(backing: MemoryBacking())
        let pins = TrustedHostFingerprintStore(backing: memory)
        let a = NWEndpoint.service(name: "fixture-a", type: "_fixture._tcp", domain: "local", interface: nil)
        let b = NWEndpoint.service(name: "fixture-b", type: "_fixture._tcp", domain: "local", interface: nil)
        XCTAssertTrue(pins.save("pin-a", endpoint: a, hostID: Data(repeating: 1, count: 16)))
        XCTAssertEqual(pins.load(endpoint: a), "pin-a"); XCTAssertNil(pins.load(endpoint: b))
        XCTAssertTrue(pins.save("pin-b", endpoint: b, hostID: Data(repeating: 2, count: 16)))
        pins.delete(fingerprint: "pin-a")
        XCTAssertNil(pins.load(endpoint: a)); XCTAssertEqual(pins.load(endpoint: b), "pin-b")
        XCTAssertNil(store.load(endpoint: a))
        memory.values["selected-host"] = Data("legacy".utf8)
        XCTAssertNil(pins.migrateLegacy(endpoint: a, presented: "other", credential: nil))
        let credential = TrustedHostCredential(fingerprint: "legacy", hostID: Data(repeating: 1, count: 16),
            deviceID: Data(repeating: 2, count: 16), secret: Data(repeating: 3, count: 32), sessionID: Data(repeating: 4, count: 16))
        XCTAssertEqual(pins.migrateLegacy(endpoint: a, presented: "legacy", credential: credential), "legacy")
        XCTAssertNil(pins.load(endpoint: NWEndpoint.service(name: "fixture-c", type: "_fixture._tcp", domain: "local", interface: nil)))
    }
}

final class UsbBindCompletionOwnershipTests: XCTestCase {
    func testEveryBindIdentityComponentIsRequired() throws {
        let queue = DispatchQueue(label: "UsbBindCompletionOwnershipTests.identity")
        let session = try XCTUnwrap(SessionID(bytes: Data(repeating: 9, count: 16)))
        let other = try XCTUnwrap(SessionID(bytes: Data(repeating: 10, count: 16)))
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        var token: UsbLaneBindToken?
        let server = UsbLaneServer(networkQueue: queue, parametersProvider: { .tcp },
            onBound: { value, _, _ in token = value }, onFailure: { _ in XCTFail() })
        queue.sync {
            server.bindingResultSenderForTesting = { _, done in done(nil) }
            server.prepareBoundForTesting(connection, sessionID: session,
                connectionGeneration: 7, lane: .video, generation: 3)
        }
        queue.sync { }
        let current = try XCTUnwrap(token)
        queue.sync {
            XCTAssertTrue(server.owns(current, connection: connection))
            for invalid in [
                UsbLaneBindToken(serverEpoch: UUID(), sessionID: session, connectionGeneration: 7, lane: .video, bindGeneration: 3, connectionID: current.connectionID),
                UsbLaneBindToken(serverEpoch: current.serverEpoch, sessionID: other, connectionGeneration: 7, lane: .video, bindGeneration: 3, connectionID: current.connectionID),
                UsbLaneBindToken(serverEpoch: current.serverEpoch, sessionID: session, connectionGeneration: 6, lane: .video, bindGeneration: 3, connectionID: current.connectionID),
                UsbLaneBindToken(serverEpoch: current.serverEpoch, sessionID: session, connectionGeneration: 7, lane: .audio, bindGeneration: 3, connectionID: current.connectionID),
                UsbLaneBindToken(serverEpoch: current.serverEpoch, sessionID: session, connectionGeneration: 7, lane: .video, bindGeneration: 2, connectionID: current.connectionID)
            ] { XCTAssertFalse(server.owns(invalid, connection: connection)) }
            XCTAssertFalse(server.owns(current, connection:
                NWConnection(host: "127.0.0.1", port: 2, using: .tcp)))
        }
        server.abort()
        queue.sync { }
    }

    func testCurrentSendErrorDoesNotAdopt() throws {
        let queue = DispatchQueue(label: "UsbBindCompletionOwnershipTests.error")
        let session = try XCTUnwrap(SessionID(bytes: Data(repeating: 11, count: 16)))
        let server = UsbLaneServer(networkQueue: queue, parametersProvider: { .tcp },
            onBound: { _, _, _ in XCTFail("failed send adopted") }, onFailure: { _ in XCTFail() })
        queue.sync {
            server.bindingResultSenderForTesting = { _, done in done(.posix(.ECONNRESET)) }
            server.prepareBoundForTesting(NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
                sessionID: session, connectionGeneration: 1, lane: .video, generation: 1)
        }
        queue.sync { }
        server.abort()
        queue.sync { }
    }

    func testRetiredSendCompletionCannotAdoptOrReplaceNewLane() throws {
        let queue = DispatchQueue(label: "UsbBindCompletionOwnershipTests")
        let session = try XCTUnwrap(SessionID(bytes: Data(repeating: 7, count: 16)))
        var completions: [(NWError?) -> Void] = []
        var adopted: [NWConnection] = []
        let server = UsbLaneServer(networkQueue: queue, parametersProvider: { .tcp },
            onBound: { _, _, connection in adopted.append(connection) }, onFailure: { _ in XCTFail() })
        let old = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let replacement = NWConnection(host: "127.0.0.1", port: 2, using: .tcp)
        queue.sync {
            server.bindingResultSenderForTesting = { _, completion in completions.append(completion) }
            server.prepareBoundForTesting(old, sessionID: session, connectionGeneration: 1, lane: .video, generation: 1)
            server.prepareBoundForTesting(replacement, sessionID: session, connectionGeneration: 2, lane: .video, generation: 1)
            completions[1](nil)
        }
        queue.sync { }
        queue.sync { completions[0](nil); completions[1](nil) }
        queue.sync { }
        queue.sync {
            XCTAssertEqual(adopted.count, 1)
            XCTAssertTrue(adopted.first === replacement)
        }
        server.abort()
        queue.sync { }
    }

    func testFinalizeAndErrorCompletionNeverAdopt() throws {
        let queue = DispatchQueue(label: "UsbBindCompletionOwnershipTests.finalize")
        let session = try XCTUnwrap(SessionID(bytes: Data(repeating: 8, count: 16)))
        var completion: ((NWError?) -> Void)?
        let server = UsbLaneServer(networkQueue: queue, parametersProvider: { .tcp },
            onBound: { _, _, _ in XCTFail("retired lane adopted") }, onFailure: { _ in XCTFail() })
        queue.sync {
            server.bindingResultSenderForTesting = { _, callback in completion = callback }
            server.prepareBoundForTesting(NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
                sessionID: session, connectionGeneration: 1, lane: .audio, generation: 1)
        }
        server.finalize()
        queue.sync { }
        completion?(nil)
        queue.sync { }
        completion?(.posix(.ECONNRESET))
        queue.sync { }
    }
}

final class RendererConstantOwnershipTests: XCTestCase {
    func testTransientConstantsKeepTwoEncodedDrawsIndependent() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Out { float4 position [[position]]; float2 scale; };
            vertex Out v(uint i [[vertex_id]], constant float2& s [[buffer(0)]]) {
                float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
                return {float4(p[i],0,1),s};
            }
            fragment float4 f(Out x [[stage_in]]) { return float4(x.scale,0,1); }
            """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v")
        descriptor.fragmentFunction = library.makeFunction(name: "f")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        var targets: [MTLTexture] = []
        for expected in [SIMD2<Float>(0.25, 0.5), SIMD2<Float>(0.75, 1)] {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = .renderTarget
            let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
            targets.append(texture)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            var scale = expected
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            scale = .zero // caller storage is deliberately reused before GPU submission
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        let rendered = XCTestExpectation(description: "Both encoded draws completed")
        command.addCompletedHandler { _ in rendered.fulfill() }
        command.commit()
        guard XCTWaiter.wait(for: [rendered], timeout: 30) == .completed else {
            return XCTFail("Metal command buffer did not complete both draws")
        }
        XCTAssertEqual(command.status, .completed)
        for (texture, expected) in zip(targets, [SIMD2<Float>(0.25, 0.5), SIMD2<Float>(0.75, 1)]) {
            var pixel = SIMD4<Float>.zero
            texture.getBytes(&pixel, bytesPerRow: MemoryLayout<SIMD4<Float>>.size,
                from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(pixel.x, expected.x)
            XCTAssertEqual(pixel.y, expected.y)
        }
    }
}

final class Display120HzSourceTests: XCTestCase {
    func testCapabilitiesDecodeCanonical120HzNativeModes() throws {
        var payload = Data(count: DisplayCapabilities.encodedSize)
        payload[0] = 1
        payload[1] = 2

        func put(_ value: UInt32, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                payload.replaceSubrange(offset..<(offset + 4), with: bytes)
            }
        }
        func put16(_ value: UInt16, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                payload.replaceSubrange(offset..<(offset + 2), with: bytes)
            }
        }

        put(2388, at: 4)
        put(1668, at: 8)
        put16(120, at: 12)
        put(2388, at: 16)
        put(1668, at: 20)
        put16(60, at: 24)

        let capabilities = try XCTUnwrap(DisplayCapabilities.decode(payload))
        XCTAssertEqual(capabilities.preferred.refreshHz, 120)
        XCTAssertEqual(capabilities.refreshRates(for: DisplayResolution(width: 2388, height: 1668)), [120, 60])
    }

    func testDefaultSourceRequestIsAlways120Hz() {
        let request = DisplayPreference.defaultValue.makeRequest(
            interfaceOrientation: .landscape,
            requestId: 1)
        XCTAssertEqual(request.width, 2388)
        XCTAssertEqual(request.height, 1668)
        XCTAssertEqual(request.refreshHz, 120)
    }

    func testPresentationRateCapsToPanelWithoutChangingSource() {
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 60), 60)
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 120), 120)
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 144), 120)
        let oldPersistedPreference = DisplayPreference(
            width: 2388,
            height: 1668,
            refreshHz: 60,
            orientationMode: .automatic)
        let capabilities = DisplayCapabilities(
            modes: [
                DisplayMode(width: 2388, height: 1668, refreshHz: 120, isExperimental: false),
                DisplayMode(width: 2388, height: 1668, refreshHz: 60, isExperimental: false),
            ],
            preferred: DisplayMode(width: 2388, height: 1668, refreshHz: 120, isExperimental: false))
        XCTAssertEqual(oldPersistedPreference.reconciled(with: capabilities).refreshHz, 120)
        XCTAssertEqual(DisplayPreference.defaultValue.makeRequest(
            interfaceOrientation: .landscape,
            requestId: 2).refreshHz, 120)
    }
}

final class RealtimeAudioTimerPolicyTests: XCTestCase {
    func testAudioDisabledNeverOwnsRealtimePlayoutTimer() {
        XCTAssertFalse(RealtimeAudioTimerPolicy.shouldRun(
            mode: RealtimeTransportMode.wifiRTP,
            audioEnabled: false))
        XCTAssertFalse(RealtimeAudioTimerPolicy.shouldRun(
            mode: RealtimeTransportMode.usbSplitTLS,
            audioEnabled: false))
    }

    func testAudioEnabledRunsOnlyForRealtimeAudioTransports() {
        XCTAssertTrue(RealtimeAudioTimerPolicy.shouldRun(
            mode: RealtimeTransportMode.wifiRTP,
            audioEnabled: true))
        XCTAssertTrue(RealtimeAudioTimerPolicy.shouldRun(
            mode: RealtimeTransportMode.usbSplitTLS,
            audioEnabled: true))
        XCTAssertFalse(RealtimeAudioTimerPolicy.shouldRun(
            mode: RealtimeTransportMode.legacyTLS,
            audioEnabled: true))
    }
}

final class WifiTransportNegotiationTests: XCTestCase {
    func testKnownHostIdentityMustMatchPinnedCertificate() {
        let fingerprint = String(repeating: "AB", count: 32)

        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: fingerprint,
                pinnedFingerprint: fingerprint),
            .trusted)
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: String(repeating: "CD", count: 32),
                pinnedFingerprint: fingerprint),
            .rejected)
    }

    func testFirstPairingRequiresOutOfBandIdentityConfirmation() {
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: String(repeating: "12", count: 32),
                pinnedFingerprint: nil),
            .requiresFirstPairingConfirmation)
    }

    func testIdentityCodeIsStableAndHumanVerifiable() {
        let fingerprint = "00112233445566778899AABBCCDDEEFF" +
            String(repeating: "00", count: 16)

        XCTAssertEqual(
            WifiHostIdentityPolicy.identityCode(for: fingerprint),
            "0011-2233-4455-6677")
    }

    func testMalformedIdentityNeverPassesAsTrusted() {
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: "not-a-fingerprint",
                pinnedFingerprint: nil),
            .rejected)
        XCTAssertNil(WifiHostIdentityPolicy.identityCode(for: "1234"))
    }

    func testWifiVideoOnlyNegotiationOmitsAudio() throws {
        let capabilities = ClientCapabilities(
            version: 1,
            modes: RealtimeTransportMode.legacyTLS |
                RealtimeTransportMode.wifiRTP,
            videoCodecs: VideoCodecCapabilities.hevc,
            audioCodecs: AudioCodecCapabilities.none,
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: 49152)
        XCTAssertEqual(
            ClientCapabilities.decode(capabilities.encode()),
            capabilities)

        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let offer = TransportOffer(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            videoCodec: VideoCodecCapabilities.hevc,
            audioCodec: AudioCodecCapabilities.none,
            mtu: 1200,
            feedbackIntervalMs: 50,
            hostUDPPort: 27016,
            sessionID: sessionID,
            mediaKey: Data(repeating: 1, count: 16),
            mediaSalt: Data(repeating: 2, count: 12),
            feedbackKey: Data(repeating: 3, count: 16),
            feedbackSalt: Data(repeating: 4, count: 12),
            usbBindingSecret: Data(repeating: 5, count: 32))
        XCTAssertEqual(
            TransportOffer.decode(try XCTUnwrap(offer.encode()))?.audioCodec,
            AudioCodecCapabilities.none)

        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.none)
        XCTAssertEqual(
            TransportReady.decode(try XCTUnwrap(ready.encode())),
            ready)

        let commit = TransportCommit(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.none)
        XCTAssertEqual(
            TransportCommit.decode(try XCTUnwrap(commit.encode())),
            commit)
    }

    func testSessionIdentityDerivesExplicitMediaContract() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))

        let media = WifiMediaContract.mediaSsrc(sessionID)
        let feedback = WifiMediaContract.feedbackSsrc(sessionID)
        let request = WifiMediaContract.probeRequestSsrc(sessionID)
        let acknowledgement =
            WifiMediaContract.probeAcknowledgementSsrc(sessionID)
        XCTAssertEqual(media, 0x2d74465a)
        XCTAssertEqual(feedback, 0x6231041c)
        XCTAssertEqual(request, 0xb8ebcfca)
        XCTAssertEqual(acknowledgement, 0xfcbc8d94)
        XCTAssertEqual(Set([media, feedback, request, acknowledgement]).count, 4)
        XCTAssertNotEqual(
            request,
            acknowledgement,
            "identical sequence/ROC must still have distinct nonce inputs")
        XCTAssertEqual(
            WifiMediaContract.initialMediaSequence(sessionID),
            0x8899)
    }

    func testInvalidFirstProbeCandidateCannotLockOutValidFlow() {
        var gate = WifiProbeCandidateGate<Int>(limit: 2)

        XCTAssertTrue(gate.register(1).accepted)
        gate.reject(1)
        XCTAssertNil(gate.committed)

        XCTAssertTrue(gate.register(2).accepted)
        XCTAssertEqual(gate.authenticate(2), [])
        XCTAssertEqual(gate.committed, 2)
        XCTAssertFalse(gate.register(3).accepted)
    }

    func testFeedbackFailureRetainsEvidenceAndAdvancesSequence() {
        var ledger = WifiFeedbackSendLedger()
        ledger.recordExpiredFrame()
        ledger.recordExpiredFrame()
        ledger.markRecoveryCompleted()

        let failed = ledger.prepare(sentNanoseconds: 10)
        XCTAssertEqual(failed.sequence, 1)
        XCTAssertEqual(failed.expiredFrames, 2)
        XCTAssertTrue(failed.recoveryCompleted)
        ledger.didProtect(failed)
        ledger.complete(failed, succeeded: false)

        XCTAssertEqual(ledger.pendingExpiredFrames, 2)
        XCTAssertTrue(ledger.recoveryCompletedPending)
        XCTAssertEqual(ledger.pendingRttCount, 0)
        XCTAssertEqual(ledger.prepare(sentNanoseconds: 20).sequence, 2)
    }

    func testFeedbackSuccessClearsOnlyItsExpirySnapshot() {
        var ledger = WifiFeedbackSendLedger()
        ledger.recordExpiredFrame()
        ledger.recordExpiredFrame()
        let sent = ledger.prepare(sentNanoseconds: 10)
        ledger.didProtect(sent)
        ledger.recordExpiredFrame()

        ledger.complete(sent, succeeded: true)

        XCTAssertEqual(ledger.pendingExpiredFrames, 1)
        XCTAssertEqual(ledger.pendingRttCount, 1)
    }

    func testEarlyRttEchoDoesNotPreventSuccessfulAccounting() {
        var ledger = WifiFeedbackSendLedger()
        ledger.recordExpiredFrame()
        let sent = ledger.prepare(sentNanoseconds: 10)
        ledger.didProtect(sent)
        XCTAssertEqual(
            ledger.consumeRtt(token: sent.token, sentNanoseconds: 10),
            10)

        ledger.complete(sent, succeeded: true)

        XCTAssertEqual(ledger.pendingExpiredFrames, 0)
    }

    func testRecoveryCompletionClearsOnlyAfterSuccessfulFeedback() {
        var ledger = WifiFeedbackSendLedger()
        ledger.markRecoveryCompleted()
        let failed = ledger.prepare(sentNanoseconds: 10)
        ledger.didProtect(failed)
        ledger.complete(failed, succeeded: false)
        XCTAssertTrue(ledger.recoveryCompletedPending)

        let sent = ledger.prepare(sentNanoseconds: 20)
        ledger.didProtect(sent)
        ledger.complete(sent, succeeded: true)
        XCTAssertFalse(ledger.recoveryCompletedPending)
    }

    func testAbandonedFeedbackSendRetiresBookkeepingWithoutAcknowledgingEvidence() {
        var ledger = WifiFeedbackSendLedger()
        ledger.recordExpiredFrame()
        ledger.recordExpiredFrame()
        ledger.markRecoveryCompleted()

        let stale = ledger.prepare(sentNanoseconds: 10)
        XCTAssertEqual(stale.expiredFrames, 2)
        XCTAssertTrue(stale.recoveryCompleted)
        ledger.didProtect(stale)
        XCTAssertEqual(ledger.pendingRttCount, 1)

        ledger.abandon(stale)

        XCTAssertEqual(ledger.pendingRttCount, 0)
        XCTAssertEqual(ledger.pendingExpiredFrames, 2)
        XCTAssertTrue(ledger.recoveryCompletedPending)
    }

    func testAbandonedFeedbackSendIsIdempotentAndReplacementRereportsEvidence() {
        var ledger = WifiFeedbackSendLedger()
        ledger.recordExpiredFrame()
        ledger.recordExpiredFrame()
        ledger.markRecoveryCompleted()

        let stale = ledger.prepare(sentNanoseconds: 10)
        ledger.didProtect(stale)
        ledger.abandon(stale)
        ledger.complete(stale, succeeded: true)

        XCTAssertEqual(ledger.pendingExpiredFrames, 2)
        XCTAssertTrue(ledger.recoveryCompletedPending)
        let replacement = ledger.prepare(sentNanoseconds: 20)
        XCTAssertEqual(replacement.sequence, stale.sequence + 1)
        XCTAssertEqual(replacement.token, stale.token + 1)
        XCTAssertEqual(replacement.expiredFrames, 2)
        XCTAssertTrue(replacement.recoveryCompleted)

        ledger.didProtect(replacement)
        ledger.complete(replacement, succeeded: true)
        XCTAssertEqual(ledger.pendingExpiredFrames, 0)
        XCTAssertFalse(ledger.recoveryCompletedPending)
    }

    func testWifiNetworkErrorPolicyIsFailClosed() {
        for code: POSIXErrorCode in [
            .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH,
            .EAGAIN, .ENOBUFS, .EADDRNOTAVAIL
        ] {
            XCTAssertEqual(
                WifiNetworkErrorPolicy.disposition(for: .posix(code)),
                .transient)
        }
        for code: POSIXErrorCode in [
            .ECONNRESET, .ECONNABORTED, .ENOTCONN,
            .EPIPE, .ECONNREFUSED, .ETIMEDOUT
        ] {
            XCTAssertEqual(
                WifiNetworkErrorPolicy.disposition(for: .posix(code)),
                .terminal)
        }
        XCTAssertEqual(
            WifiNetworkErrorPolicy.disposition(for: .tls(-9806)),
            .terminal)
    }

    func testHealthyCommittedLaneRejectsReplacementCandidate() {
        var gate = WifiProbeCandidateGate<Int>(limit: 2)
        XCTAssertTrue(gate.register(1).accepted)
        XCTAssertNotNil(gate.authenticate(1))
        XCTAssertTrue(gate.committedHealthy)
        XCTAssertFalse(gate.register(2).accepted)
    }

    func testWaitingCommittedLaneRequiresAuthenticatedReplacement() {
        var gate = WifiProbeCandidateGate<Int>(limit: 2)
        XCTAssertTrue(gate.register(1).accepted)
        XCTAssertNotNil(gate.authenticate(1))
        XCTAssertTrue(gate.markCommittedWaiting(1))
        XCTAssertFalse(gate.committedHealthy)
        XCTAssertTrue(gate.register(2).accepted)
        XCTAssertEqual(gate.committed, 1)

        XCTAssertNotNil(gate.authenticate(2))
        XCTAssertEqual(gate.committed, 2)
        XCTAssertTrue(gate.committedHealthy)
        XCTAssertFalse(gate.retireCommitted(1))
        XCTAssertEqual(gate.committed, 2)
    }

    func testCommittedRecoveryClosesReplacementWindow() {
        var gate = WifiProbeCandidateGate<Int>(limit: 2)
        XCTAssertTrue(gate.register(1).accepted)
        XCTAssertNotNil(gate.authenticate(1))
        XCTAssertTrue(gate.markCommittedWaiting(1))
        XCTAssertTrue(gate.register(2).accepted)

        XCTAssertEqual(gate.committedRecovered(1), [2])
        XCTAssertTrue(gate.committedHealthy)
        XCTAssertFalse(gate.register(3).accepted)
        XCTAssertNil(gate.authenticate(2))
    }

    func testProbeAcceptanceReplacesLegacyTimerWithCommitDeadline() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        XCTAssertTrue(gate.legacyFallbackAllowed)

        let token = try XCTUnwrap(gate.acceptProbe(sessionID: sessionID))
        XCTAssertFalse(
            gate.legacyFallbackAllowed,
            "probe near 750 ms left the legacy timer eligible")
        XCTAssertTrue(gate.timeout(sessionID: sessionID, token: token))
        XCTAssertFalse(
            gate.commit(sessionID: sessionID),
            "late commit was accepted after the post-probe deadline")
        XCTAssertNotNil(gate.fallbackToken)
        XCTAssertTrue(gate.commitLegacyFallback(sessionID: sessionID))
    }

    func testNormalCommitCancelsPostProbeDeadline() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        let token = try XCTUnwrap(gate.acceptProbe(sessionID: sessionID))

        XCTAssertTrue(gate.commit(sessionID: sessionID))
        XCTAssertFalse(
            gate.timeout(sessionID: sessionID, token: token),
            "commit did not cancel its post-probe deadline")
    }

    func testAckLossLeavesTimeForHostLegacyCommit() throws {
        XCTAssertGreaterThan(
            WifiTransportTiming.clientPostProbeCommitTimeoutMs,
            WifiTransportTiming.hostProbeTimeoutMs)
        XCTAssertGreaterThan(
            WifiTransportTiming.clientPostProbeCommitTimeoutMs,
            WifiTransportTiming.hostProbeTimeoutMs +
                WifiTransportTiming.controlDeliveryMarginMs,
            "client deadline can race ACK-loss legacy delivery")
    }

    func testMissingInitialCommitRequestsExactSessionFallbackThenAborts() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let wrongSession = try XCTUnwrap(
            SessionID(hex: "10112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        let initialToken = try XCTUnwrap(
            gate.acceptProbe(sessionID: sessionID))
        XCTAssertTrue(
            gate.timeout(sessionID: sessionID, token: initialToken))
        let fallbackToken = try XCTUnwrap(gate.fallbackToken)
        XCTAssertFalse(
            gate.commitLegacyFallback(sessionID: wrongSession))
        XCTAssertFalse(
            gate.fallbackTimeout(
                sessionID: sessionID,
                token: fallbackToken &+ 1))
        XCTAssertTrue(
            gate.fallbackTimeout(
                sessionID: sessionID,
                token: fallbackToken))
        XCTAssertFalse(
            gate.commitLegacyFallback(sessionID: sessionID))

        let request = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        XCTAssertEqual(
            request.encode().flatMap(TransportReady.decode),
            request)
        XCTAssertGreaterThan(
            WifiTransportTiming.clientFallbackCommitTimeoutMs,
            WifiTransportTiming.controlDeliveryMarginMs)
    }

    func testCommittedUdpFailureIsGenerationChecked() {
        XCTAssertTrue(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 9,
            connectionGeneration: 9,
            committedGeneration: 9))
        XCTAssertFalse(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 8,
            connectionGeneration: 9,
            committedGeneration: 9))
        XCTAssertFalse(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 9,
            connectionGeneration: 9,
            committedGeneration: nil))
    }

    func testAuthenticationFailureDoesNotMutateReassemblyOrDecoder() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var decoded: [(Data, UInt32, Bool)] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1200,
            initialSequence:
                WifiMediaContract.initialMediaSequence(sessionID),
            unprotect: { packet in packet.first != 0xff },
            decoder: { data, sequence, isIDR, _ in
                decoded.append((data, sequence, isIDR))
            })

        processor.consume(Data([0xff]), arrivalTime: 1)
        XCTAssertEqual(processor.authenticationFailures, 1)
        XCTAssertEqual(processor.allocatedFrameCount, 0)
        XCTAssertTrue(decoded.isEmpty)

        processor.consume(
            makeSingleNalPacket(
                sequence:
                    WifiMediaContract.initialMediaSequence(sessionID)),
            arrivalTime: 2)
        XCTAssertEqual(processor.authenticationFailures, 1)
        XCTAssertEqual(processor.allocatedFrameCount, 0)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].0, Data([0, 0, 0, 2, 0x26, 0x01]))
        XCTAssertEqual(decoded[0].1, 7)
        XCTAssertTrue(decoded[0].2)
    }

    func testAuthenticatedMediaProcessorUsesProvidedRttForReassemblyDeadline() {
        var outcomes: [HevcReassemblyOutcome] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1_200,
            initialSequence: 10,
            unprotect: { _ in true },
            decoder: { _, _, _, _ in },
            outcomeObserver: { outcomes.append($0) },
            rttP95Provider: { 20 })
        let dependent = Data([0x02, 0x01])

        processor.consume(
            makeMediaPacket(
                sequence: 10,
                timestamp: 1,
                frameSequence: 1,
                marker: false,
                payload: dependent),
            arrivalTime: 0)
        processor.consume(
            makeMediaPacket(
                sequence: 11,
                timestamp: 2,
                frameSequence: 2,
                marker: true,
                payload: dependent),
            arrivalTime: 0.020)
        XCTAssertFalse(outcomes.contains(.expired(frameSequence: 1)))

        processor.consume(
            makeMediaPacket(
                sequence: 12,
                timestamp: 3,
                frameSequence: 3,
                marker: true,
                payload: dependent),
            arrivalTime: 0.040)
        XCTAssertTrue(outcomes.contains(.expired(frameSequence: 1)))
    }

    func testRecoveredSixFrameBurstReachesDecoderInOrder() {
        var decoded: [UInt32] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1_200,
            initialSequence: 10,
            unprotect: { _ in true },
            decoder: { _, sequence, _, _ in decoded.append(sequence) },
            rttP95Provider: { 20 })
        let payload = Data([0x02, 0x01])
        for sequence in [10, 12] {
            processor.consume(
                makeMediaPacket(
                    sequence: UInt16(sequence), timestamp: 1,
                    frameSequence: 1, marker: sequence == 12,
                    payload: payload),
                arrivalTime: 0)
        }
        for frame in 2...6 {
            processor.consume(
                makeMediaPacket(
                    sequence: UInt16(frame + 11),
                    timestamp: UInt32(frame),
                    frameSequence: UInt32(frame), marker: true,
                    payload: payload),
                arrivalTime: Double(frame) * 0.001)
        }
        processor.consume(
            makeMediaPacket(
                sequence: 11, timestamp: 1, frameSequence: 1,
                marker: false, payload: payload),
            arrivalTime: 0.010)
        XCTAssertEqual(decoded, [1, 2, 3, 4, 5, 6])
    }

    func testFreshRecoveryProcessorDeliversConfigurationAndIDR() {
        var decoded: [Data] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1_200,
            initialSequence: 1,
            unprotect: { _ in true },
            decoder: { data, _, _, _ in decoded.append(data) })
        processor.prepareForFreshIDRAnchor()
        let vps = Data([32 << 1, 1])
        let sps = Data([33 << 1, 1])
        let pps = Data([34 << 1, 1])
        let idr = Data([19 << 1, 1])
        for (sequence, payload, marker) in [
            (101, sps, false), (102, pps, false),
            (103, idr, true)
        ] {
            processor.consume(
                makeMediaPacket(
                    sequence: UInt16(sequence), timestamp: 10,
                    frameSequence: 10, marker: marker, payload: payload),
                arrivalTime: Double(sequence - 100) * 0.001)
        }
        XCTAssertTrue(decoded.isEmpty)
        processor.consume(
            makeMediaPacket(
                sequence: 100, timestamp: 10,
                frameSequence: 10, marker: false, payload: vps),
            arrivalTime: 0.004)
        XCTAssertEqual(decoded, [canonical(vps, sps, pps, idr)])
    }

    private func makeSingleNalPacket(sequence: UInt16) -> Data {
        makeMediaPacket(
            sequence: sequence,
            timestamp: 9,
            frameSequence: 7,
            marker: true,
            payload: Data([0x26, 0x01]))
    }

    private func makeMediaPacket(
        sequence: UInt16,
        timestamp: UInt32,
        frameSequence: UInt32,
        marker: Bool,
        payload: Data
    ) -> Data {
        var packet = Data(count: RtpPacketView.headerLength + payload.count)
        packet[0] = 0x90
        packet[1] = (marker ? 0x80 : 0) | 96
        storeBE16(sequence, in: &packet, at: 2)
        storeBE32(timestamp, in: &packet, at: 4)
        storeBE32(0x2d74465a, in: &packet, at: 8)
        storeBE16(0xBEDE, in: &packet, at: 12)
        storeBE16(3, in: &packet, at: 14)
        packet[16] = 0x17
        storeBE32(frameSequence, in: &packet, at: 17)
        storeBE32(8, in: &packet, at: 21)
        packet.replaceSubrange(
            RtpPacketView.headerLength..<packet.count,
            with: payload)
        return packet
    }

    private func canonical(_ nals: Data...) -> Data {
        var result = Data()
        for nal in nals {
            let count = UInt32(nal.count)
            result.append(UInt8(truncatingIfNeeded: count >> 24))
            result.append(UInt8(truncatingIfNeeded: count >> 16))
            result.append(UInt8(truncatingIfNeeded: count >> 8))
            result.append(UInt8(truncatingIfNeeded: count))
            result.append(nal)
        }
        return result
    }

    private func storeBE16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private func storeBE32(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}

final class TrustedReconnectPolicyTests: XCTestCase {
    func testFreshLaunchDoesNotAutoReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: false,
                lastKnownHost: "192.168.1.10"),
            "fresh launch without user-started connection must not schedule auto-reconnect")
    }

    func testActiveSessionReconnectsWhenForeground() {
        XCTAssertTrue(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: "192.168.1.10"),
            "user-owned active session should schedule auto-reconnect on disconnect")
    }

    func testBackgroundDoesNotScheduleReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: false,
                reconnectEnabled: true,
                lastKnownHost: "192.168.1.10"),
            "background state must not schedule auto-reconnect")
    }

    func testEmptyHostDoesNotScheduleReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: ""),
            "empty host must not schedule auto-reconnect")
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: nil),
            "nil host must not schedule auto-reconnect")
    }

    func testRecentWifiResumeIntentIsValidInsideRelaunchWindow() {
        XCTAssertTrue(
            RecentWifiResumePolicy.isValid(
                resumeUntil: 130,
                now: 120))
    }

    func testRecentWifiResumeIntentExpiresOutsideRelaunchWindow() {
        XCTAssertFalse(
            RecentWifiResumePolicy.isValid(
                resumeUntil: 120,
                now: 121))
    }

    func testMissingResumeIntentDoesNotEnableRelaunchReconnect() {
        XCTAssertFalse(
            RecentWifiResumePolicy.isValid(
                resumeUntil: nil,
                now: 120))
    }

    func testWifiLifecycleUsesBoundedBackgroundGrace() {
        XCTAssertEqual(WifiLifecyclePolicy.backgroundGrace, 5)
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: true,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
    }

    func testOldGenerationBackgroundTeardownCannotReplaceCurrentSession() {
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 8,
                hasSameConnection: true))
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: false))
    }

    func testOnlyMatchingBackgroundWifiSessionTearsDownAfterGrace() {
        XCTAssertTrue(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: true,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
    }
}

final class ClientPreferenceTests: XCTestCase {
    func testPerformanceHudPreferenceDefaultsOnAndPersists() {
        let suiteName = "ScreenCasting.ClientPreferenceTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(
            defaults.object(forKey: ClientPreferenceKeys.showPerformanceHUD)
                as? Bool ?? true)
        defaults.set(false, forKey: ClientPreferenceKeys.showPerformanceHUD)
        XCTAssertFalse(defaults.bool(forKey: ClientPreferenceKeys.showPerformanceHUD))
        defaults.set(true, forKey: ClientPreferenceKeys.showPerformanceHUD)
        XCTAssertTrue(defaults.bool(forKey: ClientPreferenceKeys.showPerformanceHUD))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testClientDebugLoggingPreferenceDefaultsOffAndPersists() throws {
        let suiteName = "ScreenCasting.ClientDebugLoggingPreferenceTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ClientDebugLoggingPreference.load(defaults: defaults))
        defaults.set(true, forKey: ClientPreferenceKeys.clientDebugLoggingEnabled)
        XCTAssertTrue(ClientDebugLoggingPreference.load(defaults: defaults))
        defaults.set(false, forKey: ClientPreferenceKeys.clientDebugLoggingEnabled)
        XCTAssertFalse(ClientDebugLoggingPreference.load(defaults: defaults))
    }

    func testNetworkManagerRestoresSessionLoggingPreference() throws {
        let suiteName = "ScreenCasting.ClientDebugLoggingSessionStartTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let disabledManager = NetworkManager(userDefaults: defaults)
        XCTAssertFalse(disabledManager.clientDebugLoggingEnabledForTesting)

        defaults.set(true, forKey: ClientPreferenceKeys.clientDebugLoggingEnabled)
        let enabledManager = NetworkManager(userDefaults: defaults)
        XCTAssertTrue(enabledManager.clientDebugLoggingEnabledForTesting)
    }
}

final class WifiReconnectTargetTests: XCTestCase {
    func testWifiReconnectHostPortTargetRoundTrips() throws {
        let target = WifiReconnectTarget.hostPort(
            host: "192.168.1.50",
            port: 27015)
        let endpoint = try XCTUnwrap(target.endpoint)
        guard case .hostPort(let host, let port) = endpoint else {
            return XCTFail("Expected hostPort endpoint")
        }
        XCTAssertEqual(String(describing: host), "192.168.1.50")
        XCTAssertEqual(port.rawValue, 27015)
    }

    func testWifiReconnectServiceTargetRoundTrips() throws {
        let target = WifiReconnectTarget.service(
            name: "ScreenCasting-PC",
            type: "_screencasting._tcp",
            domain: "local.")
        let endpoint = try XCTUnwrap(target.endpoint)
        guard case .service(let name, let type, let domain, _) = endpoint else {
            return XCTFail("Expected service endpoint")
        }
        XCTAssertEqual(name, "ScreenCasting-PC")
        XCTAssertEqual(type, "_screencasting._tcp")
        XCTAssertEqual(domain, "local.")
    }

    func testDiscoveredServiceEndpointPersistsReconnectIdentity() throws {
        let endpoint = NWEndpoint.service(
            name: "Office-PC",
            type: "_screencasting._tcp",
            domain: "local.",
            interface: nil)
        let target = try XCTUnwrap(WifiReconnectTargetPolicy.target(from: endpoint))
        XCTAssertEqual(
            target,
            .service(
                name: "Office-PC",
                type: "_screencasting._tcp",
                domain: "local."))
    }

    func testWifiReconnectTargetStorePersistsTarget() throws {
        let suite = "ScreenCasting.WifiReconnectTargetStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = WifiReconnectTarget.hostPort(host: "10.0.0.2", port: 27015)
        WifiReconnectTargetStore.save(expected, defaults: defaults)
        XCTAssertEqual(WifiReconnectTargetStore.load(defaults: defaults), expected)
    }

    func testStructuredReconnectTargetWinsOverStaleLegacyHost() {
        let discovered = WifiReconnectTarget.service(
            name: "Current-PC",
            type: "_screencasting._tcp",
            domain: "local.")
        XCTAssertEqual(
            WifiReconnectTargetSelection.preferred(
                structured: discovered,
                legacyHost: "192.168.1.99"),
            discovered)
    }

    func testLegacyReconnectHostMigratesWhenStructuredTargetMissing() {
        XCTAssertEqual(
            WifiReconnectTargetSelection.preferred(
                structured: nil,
                legacyHost: "192.168.1.10"),
            .hostPort(host: "192.168.1.10", port: 27015))
    }

    func testRecentWifiResumeIntentIsConsumedOnlyOnce() throws {
        let suite = "ScreenCasting.RecentWifiResumeStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentWifiResumeStore.mark(now: 100, defaults: defaults)
        XCTAssertTrue(RecentWifiResumeStore.consumeIfValid(now: 110, defaults: defaults))
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 111, defaults: defaults))
    }

    func testExpiredRecentWifiResumeIntentIsConsumedAndRemoved() throws {
        let suite = "ScreenCasting.RecentWifiResumeExpiredTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentWifiResumeStore.mark(now: 100, defaults: defaults)
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 131, defaults: defaults))
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 110, defaults: defaults))
    }

    func testWifiReconnectTargetStoreClearRemovesTarget() throws {
        let suite = "ScreenCasting.WifiReconnectTargetClearTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        WifiReconnectTargetStore.save(
            .hostPort(host: "10.0.0.2", port: 27015),
            defaults: defaults)
        WifiReconnectTargetStore.clear(defaults: defaults)
        XCTAssertNil(WifiReconnectTargetStore.load(defaults: defaults))
    }
}

final class ClientStreamSettingsPreferenceTests: XCTestCase {
    func testVersionedSettingsGetGoldenBytes() {
        let bytes = ClientSettingsWireCodec.get(requestID: 0x12345678)
        XCTAssertEqual(bytes, Data([1,0,0,0,0x78,0x56,0x34,0x12] + [UInt8](repeating: 0, count: 16)))
        XCTAssertEqual(bytes.count, 24)
    }

    func testHostBitrateAcceptsEveryIntegerInRangeWithoutQuantizingReadback() throws {
        for bps: UInt32 in [3_000_000,3_000_001,30_966_432,99_500_000,99_999_999,100_000_000] {
            var payload = Data(count: 24); payload[0] = 1
            payload.storeLittleEndian(bps, at: 16)
            let host = try XCTUnwrap(TrustedSettingsState.decode(payload))
            XCTAssertEqual(host.bitrateBps, bps)
            XCTAssertEqual(host.preference.bitrateMbps, Double(bps) / 1_000_000)
        }
        for bps: UInt32 in [0,2_999_999,100_000_001,UInt32.max] {
            var payload = Data(count: 24); payload[0] = 1; payload.storeLittleEndian(bps, at: 16)
            XCTAssertNil(TrustedSettingsState.decode(payload))
        }
    }

    func testRoundedHostDisplayDoesNotCreateAnAutomaticWrite() {
        let desired = ClientStreamSettingsPreference.normalized(bitrateMbps: 31, audioEnabled: false)
        let host = ClientStreamSettingsPreference(bitrateMbps: 30.966432, audioEnabled: false, adaptiveBitrateEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        model.receiveHostState(host, generation: 7)
        var gate = ClientSettingsReconciliationGate()
        for outcome: ClientSettingsApplyOutcome in [.state,.applied] {
            XCTAssertEqual(gate.decision(hostGeneration: 7, desired: desired, effective: model.effective, outcome: outcome), .inSync)
        }
        XCTAssertEqual(model.effective.bitrateMbps, 30.966432)
        XCTAssertEqual(model.desired.bitrateMbps, 31)
        XCTAssertEqual(SettingsCopy.pcUsing(adaptive: false, mbps: model.effective.bitrateMbps, audio: false),
            "The PC is using 31 Mbps, audio off")
        XCTAssertNil(gate.lastAutomaticAttemptGeneration)
    }

    func testRemoteUpdatesCannotCarryCastingAudioOrAutoButCastingKeepsBoth() {
        let desired = ClientStreamSettingsPreference.normalized(bitrateMbps: 31, audioEnabled: true, adaptiveBitrateEnabled: true)
        let remote = ClientSettingsWireCodec.update(requestID: 9, generation: 7, desired: desired, remote: true)
        let casting = ClientSettingsWireCodec.update(requestID: 9, generation: 7, desired: desired, remote: false)
        XCTAssertEqual(remote[1], 0); XCTAssertEqual(remote[3], 0)
        XCTAssertEqual(casting[1], 1); XCTAssertEqual(casting[3], 1)
        XCTAssertEqual(remote.subdata(in: 4..<24), casting.subdata(in: 4..<24))
        XCTAssertEqual(TrustedSettingsState.decode(remote)?.bitrateBps, 31_000_000)
        XCTAssertFalse(desired.forSession(remote: true).audioEnabled)
        XCTAssertFalse(desired.forSession(remote: true).adaptiveBitrateEnabled)
        XCTAssertEqual(desired.forSession(remote: false), desired)
        XCTAssertTrue(desired.audioEnabled); XCTAssertTrue(desired.adaptiveBitrateEnabled)
    }

    func testRemoteStateAppliedAndEveryRejectedOutcomeNeverAutomaticallyResend() {
        let desired = ClientStreamSettingsPreference.normalized(bitrateMbps: 20, audioEnabled: true, adaptiveBitrateEnabled: true)
        let host = ClientStreamSettingsPreference(bitrateMbps: 30.966432, audioEnabled: false, adaptiveBitrateEnabled: false)
        var gate = ClientSettingsReconciliationGate()
        for outcome: ClientSettingsApplyOutcome in [.state,.applied,.rejected(.invalidRequest),.state,
            .rejected(.staleGeneration),.state,.rejected(.runtimeApplyFailed),.state,.rejected(.invalidBitrate)] {
            XCTAssertNotEqual(gate.decision(hostGeneration: 7, desired: desired, effective: host, outcome: outcome, remote: true), .send)
        }
        XCTAssertNil(gate.lastAutomaticAttemptGeneration)
        // Remote suppression cannot contaminate the independent casting domain.
        XCTAssertEqual(gate.decision(hostGeneration: 7, desired: desired, effective: host, outcome: .state), .send)
    }

    func testRemoteSettingsControlsReportUnsupportedFeaturesAndKeepBitrateAvailable() {
        XCTAssertFalse(ClientStreamSettingsPreference.supportsAudioAndAuto(remote: true))
        XCTAssertTrue(ClientStreamSettingsPreference.supportsAudioAndAuto(remote: false))
        XCTAssertEqual(ClientStreamSettingsPreference.remoteUnsupportedReason, "PC audio is not available in remote sessions.")
    }

    func testBitrateV1CeilingAndHostState() {
        XCTAssertEqual(ClientStreamSettingsPreference.defaultBitrateMbps, 20)
        for value in [3.0, 20, 50, 75, 100] {
            XCTAssertEqual(ClientStreamSettingsPreference.normalized(bitrateMbps: value, audioEnabled: true).bitrateMbps, value)
        }
        XCTAssertEqual(ClientStreamSettingsPreference.normalized(bitrateMbps: 101, audioEnabled: true).bitrateMbps, 100)
        XCTAssertEqual(ClientStreamSettingsPreference.normalized(bitrateMbps: 2, audioEnabled: true).bitrateMbps, 3)
        func decode(_ bitrate: UInt32) -> TrustedSettingsState? {
            var data = Data(count: 24)
            data[0] = 1
            var little = bitrate.littleEndian
            withUnsafeBytes(of: &little) { data.replaceSubrange(16..<20, with: $0) }
            return TrustedSettingsState.decode(data)
        }
        XCTAssertEqual(decode(100_000_000)?.bitrateBps, 100_000_000)
        XCTAssertNil(decode(101_000_000))
        XCTAssertEqual(decode(99_500_000)?.bitrateBps, 99_500_000)
    }

    func testClientStreamSettingsDefaultTo20MbpsAndAudioOn() throws {
        let suite = "ScreenCasting.ClientStreamSettingsDefaultsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            ClientStreamSettingsStore.load(defaults: defaults),
            .normalized(bitrateMbps: 20, audioEnabled: true))
    }

    func testClientStreamSettingsPersistBitrateAndAudio() throws {
        let suite = "ScreenCasting.ClientStreamSettingsStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)

        ClientStreamSettingsStore.save(desired, defaults: defaults)

        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults), desired)
    }

    func testClientStreamSettingsClampBitrateToSupportedRange() {
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 1,
                audioEnabled: true).bitrateMbps,
            3)
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 101,
                audioEnabled: false).bitrateMbps,
            100)
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 12.6,
                audioEnabled: false).bitrateMbps,
            13)
    }

    func testHostEffectiveStateDoesNotOverwriteClientDesiredSettings() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        let host = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 50,
            audioEnabled: true)

        model.receiveHostState(host, generation: 7)

        XCTAssertEqual(model.desired, desired)
        XCTAssertEqual(model.effective, host)
        XCTAssertEqual(model.generation, 7)
        var gate = ClientSettingsReconciliationGate()
        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
    }

    func testClientReconcilesMismatchOncePerHostGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressAlreadyAttempted)
    }

    func testMatchingHostStateDoesNotSendReconcile() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: desired,
            outcome: .state), .inSync)
    }

    func testStaleGenerationRejectionRetriesOnceWithCurrentGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
    }

    func testRepeatedStaleGenerationDoesNotLoop() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .suppressAlreadyAttempted)
    }

    func testNormalMismatchThenStaleRejectionSameGenerationDoesNotSendTwice() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .suppressAlreadyAttempted)
    }

    func testStaleGenerationRetriesWhenNoAttemptForCurrentGenerationExists() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 6,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
    }

    func testRuntimeApplyFailedDoesNotAutoRetrySameGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
    }

    func testRuntimeApplyFailedDoesNotRetryImmediately() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 40)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
    }

    func testPostRuntimeReadyStateRetriesRuntimeApplyFailedExactlyOnce() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 40)
    }

    func testDuplicatePostRuntimeReadyStateDoesNotRetryTwice() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testSecondRuntimeApplyFailedSameGenerationDoesNotLoop() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testPostReadyRetryUsesLatestClientDesiredValues() {
        let initial = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let latest = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 18,
            audioEnabled: true)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var model = ClientSettingsStateModel(desired: initial)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: model.desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        model.setDesired(latest)

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: model.desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(model.desired, latest)
    }

    func testPostReadyRetryUsesCurrentHostGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var model = ClientSettingsStateModel(desired: desired)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        model.receiveHostState(effective, generation: 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)
        XCTAssertEqual(model.generation, 41)
    }

    func testRuntimeRecoveryFailureAtNewerGenerationDoesNotRearmSameGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 40)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 41)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)
    }

    func testNewerGenerationReconcilesAfterConsumedRuntimeRecoveryFailure() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)

        XCTAssertEqual(gate.decision(
            hostGeneration: 42,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertNil(gate.runtimeApplyFailedGeneration)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
        XCTAssertEqual(gate.lastAutomaticAttemptGeneration, 42)
    }

    func testSettingsDomainResetClearsRuntimeRecoveryState() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        gate.reset()

        XCTAssertNil(gate.runtimeApplyFailedGeneration)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
        XCTAssertEqual(gate.decision(
            hostGeneration: 0,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
    }

    func testExplicitUserMutationStillSendsAfterRuntimeRetrySuppressed() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state)
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))

        XCTAssertEqual(
            DesiredSettingsSendPolicy.decision(canSend: true),
            .send)
    }

    func testInvalidRequestDoesNotAutoRetrySameGeneration() {
        assertHardRejectionDoesNotRetry(.invalidRequest)
    }

    func testInvalidBitrateDoesNotAutoRetrySameGeneration() {
        assertHardRejectionDoesNotRetry(.invalidBitrate)
    }

    private func assertHardRejectionDoesNotRetry(
        _ reason: TrustedSettingsRejectReason
    ) {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(reason)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testExplicitUserChangeCanSendAfterAutomaticRejection() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(
            DesiredSettingsSendPolicy.decision(canSend: true),
            .send)
    }

    func testDisconnectedDesiredChangeReportsWaitingForHost() {
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .waitingForHost),
            "Waiting for Host")
    }

    func testConnectedSendReportsApplyingOnlyWhenRequestIsActuallySent() {
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .sent(requestID: 9)),
            "Applying…")
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .waitingForHost),
            "Waiting for Host")
    }

    func testNewerHostGenerationCanReconcileAgain() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        XCTAssertEqual(gate.decision(
            hostGeneration: 8,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
    }

    func testUsbCommittedGenerationRequestsSettingsStateOnce() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestSettings(committedGeneration: 12))
    }

    func testUsbSettingsSyncDoesNotRepeatForSameGeneration() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestSettings(committedGeneration: 12))
        XCTAssertFalse(policy.shouldRequestSettings(committedGeneration: 12))
    }

    func testNewUsbGenerationCanRequestSettingsStateAgain() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestSettings(committedGeneration: 12))
        XCTAssertTrue(policy.shouldRequestSettings(committedGeneration: 13))
    }

    func testPersistedDesiredSettingsReconcileAfterUsbSettingsState() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        model.receiveHostState(
            .normalized(bitrateMbps: 20, audioEnabled: true),
            generation: 0)
        var sync = ClientSettingsSyncPolicy()
        var gate = ClientSettingsReconciliationGate()

        XCTAssertTrue(sync.shouldRequestSettings(committedGeneration: 1))
        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
    }
}

@MainActor final class RemoteSettingsCompatibilityTests: XCTestCase {
    #if targetEnvironment(simulator)
    private func drain(_ network: NetworkManager) async {
        let queue = network.networkQueueForTesting
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    func testProductionSettingsGetIsVersionedOncePerCommittedCastingAndRemoteSession() async throws {
        for remote in [false,true] {
            let suite = "SettingsWire." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let network = NetworkManager(userDefaults: defaults)
            var writes: [Data] = []
            network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
            network.realtimeAudioPlaybackForTesting = { _ in }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: remote)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            network.requestCurrentSettingsForTesting(generation: peer.generation + 1)
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            await drain(network)
            let messages = network.networkQueueForTesting.sync { writes.filter { $0[5] == WireMessageType.settingsGet.rawValue } }
            let message = try XCTUnwrap(messages.first)
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(message.count, 40)
            let id = message.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
            XCTAssertNotEqual(id, 0)
            XCTAssertEqual(Data(message.dropFirst(16)), ClientSettingsWireCodec.get(requestID: id))
            network.stopForTesting()
            let next = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: remote)
            network.beginTransferWriterForTesting()
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            network.requestCurrentSettingsForTesting(generation: next.generation)
            await drain(network)
            let reconnectGets = network.networkQueueForTesting.sync { writes.filter { $0[5] == WireMessageType.settingsGet.rawValue } }
            XCTAssertEqual(reconnectGets.count, 2, "Reconnect gets a fresh settings domain; stale generation cannot request")
            let newest = try XCTUnwrap(reconnectGets.last)
            let nextID = newest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
            XCTAssertNotEqual(nextID, id)
            XCTAssertEqual(Data(newest.dropFirst(16)), ClientSettingsWireCodec.get(requestID: nextID))
        }
    }

    func testRemoteReadbackRoundingAndRejectedRepliesNeverSendWhileExplicitUpdateIsSafe() async throws {
        let suite = "SettingsRemote." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let desired = ClientStreamSettingsPreference.normalized(bitrateMbps: 31, audioEnabled: true, adaptiveBitrateEnabled: true)
        ClientStreamSettingsStore.save(desired, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        var writes: [Data] = []
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        network.realtimeAudioPlaybackForTesting = { _ in }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        var payload = Data(count: 24); payload[0] = 1
        payload.storeLittleEndian(UInt64(7), at: 8); payload.storeLittleEndian(UInt32(30_966_432), at: 16)
        network.receiveCaptureTargetWireForTesting(type: .settingsState, payload: payload,
            generation: peer.generation, connection: peer.connection)
        await drain(network)
        XCTAssertEqual(network.effectiveBitrateMbps, 30.966432)
        XCTAssertEqual(network.desiredBitrateMbps, 31)
        XCTAssertTrue(network.desiredAudioEnabled); XCTAssertTrue(network.desiredAdaptiveBitrateEnabled)
        XCTAssertFalse(network.effectiveAudioEnabled); XCTAssertFalse(network.isAdaptiveBitrate)
        XCTAssertTrue(network.networkQueueForTesting.sync { writes.isEmpty })
        let result = network.sendDesiredSettingsForTesting()
        guard case .sent = result else { return XCTFail("Explicit update must use the committed writer") }
        await drain(network)
        let updates = network.networkQueueForTesting.sync { writes.filter { $0[5] == WireMessageType.settingsUpdate.rawValue } }
        XCTAssertEqual(updates.count, 1)
        let update = try XCTUnwrap(updates.first).subdata(in: 16..<40)
        XCTAssertEqual(update[1], 0); XCTAssertEqual(update[3], 0)
        XCTAssertEqual(TrustedSettingsState.decode(update)?.generation, 7)
        XCTAssertEqual(TrustedSettingsState.decode(update)?.bitrateBps, 31_000_000)
        for reason: TrustedSettingsRejectReason in [.invalidRequest,.staleGeneration,.runtimeApplyFailed,.invalidBitrate] {
            payload[2] = reason.rawValue
            network.receiveCaptureTargetWireForTesting(type: .settingsRejected, payload: payload,
                generation: peer.generation, connection: peer.connection)
            await drain(network)
            XCTAssertEqual(network.settingsApplyStatus, "Rejected by Host")
            payload[2] = 0
            network.receiveCaptureTargetWireForTesting(type: .settingsState, payload: payload,
                generation: peer.generation, connection: peer.connection)
            await drain(network)
        }
        XCTAssertEqual(network.networkQueueForTesting.sync { writes.filter { $0[5] == WireMessageType.settingsUpdate.rawValue }.count }, 1)
    }

    func testCastingStillAutomaticallyReconcilesAudioAndAutoAndPreservesExactReadback() async throws {
        let suite = "SettingsCasting." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let desired = ClientStreamSettingsPreference.normalized(bitrateMbps: 12, audioEnabled: true, adaptiveBitrateEnabled: true)
        ClientStreamSettingsStore.save(desired, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        var writes: [Data] = []
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        network.realtimeAudioPlaybackForTesting = { _ in }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        var payload = Data(count: 24); payload[0] = 1
        payload.storeLittleEndian(UInt64(7), at: 8); payload.storeLittleEndian(UInt32(30_966_432), at: 16)
        network.receiveCaptureTargetWireForTesting(type: .settingsState, payload: payload,
            generation: peer.generation, connection: peer.connection)
        await drain(network)
        let updates = network.networkQueueForTesting.sync { writes.filter { $0[5] == WireMessageType.settingsUpdate.rawValue } }
        XCTAssertEqual(updates.count, 1)
        let update = try XCTUnwrap(updates.first).subdata(in: 16..<40)
        XCTAssertEqual(update[1], 1); XCTAssertEqual(update[3], 1)
        XCTAssertEqual(TrustedSettingsState.decode(update)?.bitrateBps, 12_000_000)
        XCTAssertEqual(network.effectiveBitrateMbps, 30.966432)
        XCTAssertEqual(network.desiredBitrateMbps, 12)
    }
    #endif
}

final class VideoThroughputV1Tests: XCTestCase {
    func testVideoPayloadRateUsesMonotonicDeltasAndResets() {
        var meter = VideoPayloadRateSampler()
        XCTAssertEqual(meter.sample(totalBytes: 9_000_000, at: 10), 0)
        XCTAssertEqual(meter.sample(totalBytes: 10_000_000, at: 10.5), 16)
        XCTAssertEqual(meter.sample(totalBytes: 10_000_000, at: 11), 0)
        XCTAssertEqual(meter.sample(totalBytes: 0, at: 11.5), 0)
        XCTAssertEqual(meter.sample(totalBytes: 1_000_000, at: 12), 16)
        XCTAssertEqual(meter.sample(totalBytes: 2_000_000, at: 12), 0)
        meter.reset()
        XCTAssertEqual(meter.sample(totalBytes: 100_000_000, at: 13), 0)
    }

    func testUniqueVideoPayloadCounterRejectsDuplicatesAndStaleSessions() {
        var counter = VideoPayloadCounter()
        XCTAssertFalse(counter.record(byteCount: 100, sequence: 1, generation: 1))
        counter.begin(generation: 1)
        XCTAssertTrue(counter.record(byteCount: 1_000_000, sequence: UInt32.max, generation: 1))
        XCTAssertFalse(counter.record(byteCount: 1_000_000, sequence: UInt32.max, generation: 1))
        XCTAssertTrue(counter.record(byteCount: 500_000, sequence: 0, generation: 1))
        XCTAssertFalse(counter.record(byteCount: 500_000, sequence: UInt32.max, generation: 1))
        XCTAssertFalse(counter.record(byteCount: 0, sequence: 1, generation: 1))
        XCTAssertEqual(counter.totalBytes, 1_500_000)
        counter.begin(generation: 2)
        XCTAssertFalse(counter.record(byteCount: 100, sequence: 1, generation: 1))
        XCTAssertTrue(counter.record(byteCount: 100, sequence: 1, generation: 2))
        XCTAssertEqual(counter.totalBytes, 100)
        counter.reset()
        XCTAssertFalse(counter.record(byteCount: 100, sequence: 2, generation: 2))
        XCTAssertEqual(counter.totalBytes, 0)
        XCTAssertEqual(TransportHudSnapshot(frameReceiveMs: 2, decodeMs: 3, videoRxMbps: 16).videoRxMbps, 16)
    }
    func testFallbackKeepsExistingTelemetryCadence() {
        let manager = NetworkManager()
        let session = manager.simulateCommittedWifiSessionForTesting()
        defer { manager.stopForTesting() }
        XCTAssertTrue(manager.networkQueueForTesting.sync {
            manager.fallbackCommittedWifiToLegacy(generation: session.generation)
        })
        let sampled = expectation(description: "existing feedback cadence resumes")
        manager.networkQueueForTesting.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertGreaterThan(manager.videoFeedbackCountForTesting, 0)
            sampled.fulfill()
        }
        wait(for: [sampled], timeout: 2)
    }

    func testExplicitStopCancelsWifiMediaReceiver() {
        let manager = NetworkManager()
        let session = manager.simulateCommittedWifiSessionForTesting()
        let receiver = manager.wifiMediaReceiverForTesting
        manager.networkQueueForTesting.sync {
            receiver.start(generation: session.generation) { _ in }
        }
        XCTAssertTrue(manager.networkQueueForTesting.sync { receiver.isListeningForTesting })
        manager.stopForTesting()
        XCTAssertFalse(manager.networkQueueForTesting.sync { receiver.isListeningForTesting },
            "explicit Stop must not leave the Wi-Fi media listener, feedback timer or keys alive")
    }

    func testHudSnapshotFromRetiredModeIsNotPublishedAfterModeReturns() {
        let manager = NetworkManager()
        _ = manager.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.wifiRTP)
        defer { manager.stopForTesting() }
        let stale = TransportHudSnapshot(frameReceiveMs: 41, decodeMs: 42, videoRxMbps: 43)
        // The main-thread apply is queued behind this test, so the mode can change A -> B -> A first.
        manager.publishHudSnapshotForTesting(stale)
        manager.setCommittedRealtimeModeForTesting(RealtimeTransportMode.legacyTLS)
        manager.setCommittedRealtimeModeForTesting(RealtimeTransportMode.wifiRTP)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotEqual(manager.hudTelemetry, stale, "a snapshot from a retired mode epoch was applied")
    }

    func testCommittedFallbackRearmsDecoderOnceWithoutReplacingSession() {
        let manager = NetworkManager()
        let session = manager.simulateCommittedWifiSessionForTesting()
        defer { manager.stopForTesting() }
        let decoder = manager.decoderForTesting
        let invalidates = decoder.invalidateCountForTesting
        let begins = decoder.sessionBeganCountForTesting
        XCTAssertTrue(manager.networkQueueForTesting.sync {
            manager.fallbackCommittedWifiToLegacy(generation: session.generation)
        })
        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === session.connection)
        XCTAssertEqual(after.generation, session.generation)
        XCTAssertEqual(after.authenticatedGeneration, session.generation)
        XCTAssertEqual(after.committedGeneration, session.generation)
        XCTAssertEqual(after.realtimeMode, RealtimeTransportMode.legacyTLS)
        XCTAssertEqual(decoder.invalidateCountForTesting, invalidates + 1)
        XCTAssertEqual(decoder.sessionBeganCountForTesting, begins + 1)
        XCTAssertNotEqual(decoder.currentSessionGeneration, session.generation)
        XCTAssertEqual(Array(decoder.lifecycleEventsForTesting.suffix(3)), [
            "invalidate-begin", "invalidate-end", "begin-\(decoder.currentSessionGeneration)"])
        XCTAssertFalse(manager.networkQueueForTesting.sync {
            manager.fallbackCommittedWifiToLegacy(generation: session.generation)
        })
        XCTAssertEqual(decoder.invalidateCountForTesting, invalidates + 1)
        XCTAssertEqual(decoder.sessionBeganCountForTesting, begins + 1)
    }

    func testStaleFallbackCannotRearmReplacementWifiDecoder() {
        let manager = NetworkManager()
        let old = manager.simulateCommittedWifiSessionForTesting()
        let current = manager.simulateCommittedWifiSessionForTesting()
        defer { manager.stopForTesting() }
        let decoder = manager.decoderForTesting
        let invalidates = decoder.invalidateCountForTesting
        let begins = decoder.sessionBeganCountForTesting
        XCTAssertFalse(manager.networkQueueForTesting.sync {
            manager.fallbackCommittedWifiToLegacy(generation: old.generation)
        })
        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === current.connection)
        XCTAssertEqual(after.authenticatedGeneration, current.generation)
        XCTAssertEqual(after.committedGeneration, current.generation)
        XCTAssertEqual(after.realtimeMode, RealtimeTransportMode.wifiRTP)
        XCTAssertEqual(decoder.invalidateCountForTesting, invalidates)
        XCTAssertEqual(decoder.sessionBeganCountForTesting, begins)
    }
}

final class AutoBitrateWireV1Tests: XCTestCase {
    func testAutoPreferencePersistsWithoutChangingManual75() throws {
        let suite = "ScreenCasting.AutoBitrateV1Tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ClientStreamSettingsStore.load(defaults: defaults).adaptiveBitrateEnabled)
        defaults.set(75, forKey: "ScreenCasting.client.desiredBitrateMbps.v1")
        defaults.set(true, forKey: "ScreenCasting.client.desiredAudioEnabled.v1")
        let oldManual = ClientStreamSettingsStore.load(defaults: defaults)
        XCTAssertEqual(oldManual.bitrateMbps, 75)
        XCTAssertFalse(oldManual.adaptiveBitrateEnabled)
        let auto = ClientStreamSettingsPreference.normalized(
            bitrateMbps: oldManual.bitrateMbps, audioEnabled: false, adaptiveBitrateEnabled: true)
        ClientStreamSettingsStore.save(auto, defaults: defaults)
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults), auto)
        let manual = ClientStreamSettingsPreference.normalized(
            bitrateMbps: auto.bitrateMbps, audioEnabled: auto.audioEnabled, adaptiveBitrateEnabled: false)
        ClientStreamSettingsStore.save(manual, defaults: defaults)
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults).bitrateMbps, 75)
        XCTAssertFalse(ClientStreamSettingsStore.load(defaults: defaults).adaptiveBitrateEnabled)
    }

    func testModeMismatchReconcilesEvenWhenBitrateAndAudioMatch() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 75, audioEnabled: true, adaptiveBitrateEnabled: true)
        let manual = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 75, audioEnabled: true, adaptiveBitrateEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        model.receiveHostState(manual, generation: 9)
        var gate = ClientSettingsReconciliationGate()
        XCTAssertEqual(gate.decision(hostGeneration: 9, desired: model.desired,
            effective: model.effective, outcome: .state), .send)
        model.receiveHostState(desired, generation: 10)
        XCTAssertEqual(model.desired.bitrateMbps, 75)
        XCTAssertEqual(gate.decision(hostGeneration: 10, desired: model.desired,
            effective: model.effective, outcome: .applied), .inSync)
    }

    @MainActor func testAutoSnapshotPreservesLiveTargetAndManualReportsSavedTarget() async {
        let manager = NetworkManager()
        let desired = manager.desiredBitrateMbps
        var payload = Data(count: 24)
        payload[0] = 1
        payload[1] = 1
        payload[2] = TrustedSettingsRejectReason.invalidRequest.rawValue
        payload[3] = 1
        var bitrate = UInt32(60_000_000).littleEndian
        withUnsafeBytes(of: &bitrate) { payload.replaceSubrange(16..<20, with: $0) }
        manager.receiveSettingsState(payload, outcome: .rejected(.invalidRequest))
        let seed = expectation(description: "Auto seed published")
        DispatchQueue.main.async { seed.fulfill() }
        await fulfillment(of: [seed], timeout: 2)
        XCTAssertTrue(manager.isAdaptiveBitrate)
        XCTAssertEqual(manager.effectiveBitrateMbps, 60)
        bitrate = UInt32(75_000_000).littleEndian
        withUnsafeBytes(of: &bitrate) { payload.replaceSubrange(16..<20, with: $0) }
        manager.receiveSettingsState(payload, outcome: .rejected(.invalidRequest))
        let auto = expectation(description: "Auto state published")
        DispatchQueue.main.async { auto.fulfill() }
        await fulfillment(of: [auto], timeout: 2)
        XCTAssertTrue(manager.isAdaptiveBitrate)
        XCTAssertEqual(manager.effectiveBitrateMbps, 60)
        XCTAssertEqual(manager.desiredBitrateMbps, desired)
        payload[3] = 0
        manager.receiveSettingsState(payload, outcome: .rejected(.invalidRequest))
        let manual = expectation(description: "Manual state published")
        DispatchQueue.main.async { manual.fulfill() }
        await fulfillment(of: [manual], timeout: 2)
        XCTAssertFalse(manager.isAdaptiveBitrate)
        XCTAssertEqual(manager.effectiveBitrateMbps, 75)
        XCTAssertEqual(manager.desiredBitrateMbps, desired)
    }

    func testSettingsByte3AcceptsAutoAndKeeps24ByteLayout() {
        var payload = Data(count: 24)
        payload[0] = 1
        payload[1] = 1
        payload[3] = 1
        var bitrate = UInt32(75_000_000).littleEndian
        withUnsafeBytes(of: &bitrate) { payload.replaceSubrange(16..<20, with: $0) }
        XCTAssertEqual(payload.count, 24)
        XCTAssertEqual(TrustedSettingsState.decode(payload)?.bitrateBps, 75_000_000)
        payload[3] = 0
        XCTAssertNotNil(TrustedSettingsState.decode(payload))
        for byte in UInt8(2)...UInt8(255) {
            payload[3] = byte
            XCTAssertNil(TrustedSettingsState.decode(payload))
        }
    }
}
