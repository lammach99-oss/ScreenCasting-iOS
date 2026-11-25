import Network
import XCTest
@testable import iPadCasting

final class SessionSwitcherTests: XCTestCase {
    private let a = TrustedPeerReference(String(repeating: "A", count: 64))!
    private let b = TrustedPeerReference(String(repeating: "B", count: 64))!

    @MainActor private func connected() throws -> SessionSwitcher {
        let model = SessionSwitcher()
        for (slot, peer) in [(SlotOrdinal.one, a), (.two, b)] {
            let attempt = try XCTUnwrap(model.connect(slot, route: .wifi))
            XCTAssertTrue(model.authenticate(attempt, peer: peer))
        }
        XCTAssertTrue(model.claimSurface("first"))
        return model
    }

    @MainActor func testCoalescedSelectionAndStalePresentation() throws {
        let model = try connected()
        let first = try XCTUnwrap(model.inFlight)
        model.contextReady(first)
        XCTAssertNil(model.outputLease)
        model.presented(first)
        XCTAssertEqual(model.outputLease, first)
        XCTAssertEqual(model.select(.two, scene: "first"), .parkAndCancelTransfer(first))
        let second = try XCTUnwrap(model.inFlight)
        XCTAssertNil(model.outputLease)
        model.select(.one, scene: "first")
        model.select(.two, scene: "first")
        model.select(.one, scene: "first")
        XCTAssertEqual(model.inFlight, second)
        model.presented(second)
        XCTAssertEqual(model.contextReady(second), .parkAndCancelTransfer(second))
        let third = try XCTUnwrap(model.inFlight)
        XCTAssertEqual(third.ordinal, .one)
        model.presented(first)
        model.contextReady(first)
        XCTAssertNil(model.outputLease)
        model.contextReady(third)
        model.presented(third)
        XCTAssertEqual(model.outputLease, third)
    }

    @MainActor func testSurfaceAndContextRevocation() throws {
        let model = try connected()
        let old = try XCTUnwrap(model.inFlight)
        XCTAssertFalse(model.claimSurface("second"))
        model.select(.two, scene: "second")
        model.releaseSurface("second")
        XCTAssertEqual(model.inFlight, old)
        model.releaseSurface("first")
        XCTAssertTrue(model.claimSurface("second"))
        let fresh = try XCTUnwrap(model.inFlight)
        XCTAssertNotEqual(old, fresh)
        model.invalidateContext(fresh)
        model.presented(fresh)
        model.contextReady(fresh)
        XCTAssertNil(model.outputLease)
        XCTAssertNotEqual(model.inFlight, fresh)
    }

    @MainActor func testDuplicateAndFailureMatrix() throws {
        let model = try connected()
        let parked = model[.two].ticket
        let active = try XCTUnwrap(model.inFlight)
        model.presented(active)
        model.contextReady(active)
        model.drop(parked, error: .transport)
        XCTAssertTrue(model[.two].retryRequested)
        XCTAssertEqual(model[.two].preview, .placeholder)
        XCTAssertEqual(model.outputLease, active)
        let retry = try XCTUnwrap(model.connect(.two, route: .tailscale))
        XCTAssertFalse(model.authenticate(retry, peer: a))
        XCTAssertEqual(model[.two].phase, .refused)
        XCTAssertFalse(model[.two].retryRequested)
        let next = try XCTUnwrap(model.connect(.two, route: .wifi))
        XCTAssertTrue(model.authenticate(next, peer: b))
        model.drop(parked, error: .busy)
        model.drop(active, error: .transport)
        XCTAssertNil(model.outputLease)
        XCTAssertEqual(model.selected, .one)
        XCTAssertEqual(model.offeredAlternate, .two)
        model.drop(model[.two].ticket, error: .transport)
        XCTAssertNil(model.offeredAlternate)
        XCTAssertTrue(model[.one].retryRequested && model[.two].retryRequested)
        for error in [SlotFailure.busy, .refused, .forgotten, .identityMismatch] {
            let attempt = try XCTUnwrap(model.connect(.one, route: .wifi))
            model.drop(attempt, error: error)
            XCTAssertEqual(model[.one].phase, .refused)
            XCTAssertFalse(model[.one].retryRequested)
        }
    }

    func testPairMigrationForgetCorruptionAndRelaunch() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func store() -> RemotePairStore {
            RemotePairStore(defaults: defaults, isTrusted: { $0 == self.a || $0 == self.b },
                            legacyReference: { self.a })
        }
        let migrated = store().load()
        XCTAssertEqual(migrated.first, a)
        XCTAssertNil(migrated.second)
        XCTAssertFalse(store().save(first: a, second: a, selected: .two))
        XCTAssertTrue(store().save(first: a, second: b, selected: .two))
        XCTAssertEqual(store().load().selected, .two)
        store().forget(a)
        XCTAssertNil(store().load().first)
        XCTAssertEqual(store().load().second, b)
        store().forget(b)
        XCTAssertEqual(store().load(), .empty)
        defaults.set(Data([0xff]), forKey: RemotePairStore.key)
        XCTAssertEqual(store().load(), .empty)
    }

    @MainActor func testExplicitFailoverAndChangedIdentityOnReconnect() throws {
        let model = try connected()
        let old = try XCTUnwrap(model.inFlight)
        model.presented(old)
        model.contextReady(old)
        model.drop(old, error: .transport)
        XCTAssertEqual(model.selected, .one)
        XCTAssertNil(model.inFlight)
        model.select(.two, scene: "first")
        let alternate = try XCTUnwrap(model.inFlight)
        XCTAssertEqual(alternate.ordinal, .two)
        model.contextReady(alternate)
        XCTAssertNil(model.outputLease)
        model.presented(alternate)
        let retry = try XCTUnwrap(model.connect(.one, route: .wifi))
        let changed = try XCTUnwrap(TrustedPeerReference(String(repeating: "C", count: 64)))
        XCTAssertFalse(model.authenticate(retry, peer: changed))
        XCTAssertEqual(model[.one].peer, a)
        XCTAssertEqual(model[.one].lastError, .identityMismatch)
        XCTAssertFalse(model[.one].retryRequested)
        XCTAssertEqual(model.outputLease, alternate)
    }

    private final class MemoryDirectoryBacking: TrustedHostCredentialBacking {
        var values: [String: Data] = [:]
        func load(fingerprint: String) -> Data? { values[fingerprint] }
        func save(_ data: Data, fingerprint: String) -> Bool {
            values[fingerprint] = data
            return true
        }
        func delete(fingerprint: String) -> Bool {
            values.removeValue(forKey: fingerprint)
            return true
        }
    }

    func testLegacyMigrationRequiresRemotePortAndExistingDirectoryPin() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TrustedHostFingerprintStore(backing: MemoryDirectoryBacking())
        let store = RemotePairStore(defaults: defaults, directory: directory)
        let remote = WifiReconnectTarget.hostPort(host: suite, port: 27020)
        let casting = WifiReconnectTarget.hostPort(host: suite, port: 27015)
        WifiReconnectTargetStore.save(remote, defaults: defaults)
        XCTAssertEqual(store.load(), .empty)
        for target in [remote, casting] {
            let endpoint = try XCTUnwrap(target.endpoint)
            XCTAssertTrue(directory.save(a.fingerprint, endpoint: endpoint, hostID: Data(count: 16)))
        }
        WifiReconnectTargetStore.save(casting, defaults: defaults)
        XCTAssertEqual(store.load(), .empty)
        WifiReconnectTargetStore.save(remote, defaults: defaults)
        XCTAssertEqual(store.load().first, a)
        XCTAssertNil(store.load().second)
        store.forget(a)
        XCTAssertEqual(store.load(), .empty)
    }

    @MainActor func testThumbnailInvalidationAndStaleGeneration() throws {
        let model = try connected()
        let ticket = try XCTUnwrap(model.inFlight)
        model.contextReady(ticket)
        model.presented(ticket)
        model.recordAuthorizedThumbnail(ticket, revision: 1)
        model.select(.two, scene: "first")
        XCTAssertEqual(model[.one].preview, .thumbnail(revision: 1))
        model.invalidateContext(model[.one].ticket)
        model.recordAuthorizedThumbnail(ticket, revision: 1)
        XCTAssertEqual(model[.one].preview, .placeholder)
        let parked = model[.one].ticket
        model.drop(parked, error: .transport)
        let retry = try XCTUnwrap(model.connect(.one, route: .wifi))
        model.drop(parked, error: .refused)
        XCTAssertTrue(model.authenticate(retry, peer: a))
        XCTAssertEqual(model[.one].phase, .parked)
    }
}
#if targetEnvironment(simulator)
final class SlotTransportTests: XCTestCase {
    private final class Peer {
        let manager: NetworkManager
        private let suite = "SlotTransportTests." + UUID().uuidString
        let defaults: UserDefaults
        private var packets: [Data] = []
        private var reader: ((Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?

        init(_ role: RemoteSlotRole) {
            defaults = UserDefaults(suiteName: suite)!
            RecentWifiResumeStore.mark(defaults: defaults)
            manager = NetworkManager(userDefaults: defaults, role: role)
            manager.transferReceiveForTesting = { [weak self] _, read in
                XCTAssertNil(self?.reader)
                self?.reader = read
            }
            manager.controlSendForAudioTesting = { [weak self] bytes, completion in
                self?.packets.append(bytes)
                completion(nil)
            }
        }

        func send(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) throws {
            let frame = ConnectionControlProtocol.frame(type: type.rawValue, payload: payload, flags: flags)
            try manager.networkQueueForTesting.sync {
                let read = try XCTUnwrap(reader)
                reader = nil
                read(frame, nil, false, nil)
            }
        }

        func payloads(_ type: WireMessageType) -> [Data] {
            manager.networkQueueForTesting.sync {} // Flush the enqueued request before its writer hop.
            return manager.networkQueueForTesting.sync {
                packets.filter { $0.count >= 16 && $0[5] == type.rawValue }.map { Data($0.dropFirst(16)) }
            }
        }

        func finish() {
            manager.stopForTesting()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testIndependentFeatureExchangesAndPingReaders() throws {
        let a = Peer(.primary), b = Peer(.secondaryRemote)
        defer { a.finish(); b.finish() }
        b.manager.startListening()
        b.manager.networkQueueForTesting.sync {}
        XCTAssertNil(b.manager.preparedUSBListenerPortForTesting)
        XCTAssertTrue(RecentWifiResumeStore.consumeIfValid(defaults: b.defaults))
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(defaults: a.defaults))
        let first = a.manager.beginSlotProbeForTesting(), second = b.manager.beginSlotProbeForTesting()
        for peer in [a, b] {
            let ping = try XCTUnwrap(peer.payloads(.ping).last)
            try peer.send(.pong, ping, flags: RemoteFeatureNegotiation.supportedFlag)
            let request = try XCTUnwrap(peer.payloads(.remoteFeaturesRequest).last.flatMap(RemoteFeaturesMessage.decode))
            XCTAssertNotEqual(request.features & RemoteFeatureNegotiation.remoteVideoStandby, 0)
            try peer.send(.remoteFeaturesResult, RemoteFeaturesMessage(features: peer === a ? 3 : 3 | RemoteFeatureNegotiation.remoteVideoStandby).encode())
            peer.manager.requestVideoStandby(park: true)
        }
        XCTAssertTrue(a.payloads(.remoteVideoStandby).isEmpty)
        let park = try XCTUnwrap(b.payloads(.remoteVideoStandby).last)
        XCTAssertEqual(RemoteVideoStandbyMessage.decode(park, flags: 0, request: true)?.operation, .park)
        func reply(_ operation: RemoteVideoStandbyMessage.Operation, serial: UInt64) throws {
            let bytes = try XCTUnwrap(RemoteVideoStandbyMessage(operation: operation, serial: serial).encode())
            try b.send(.remoteVideoStandby, bytes)
        }
        func video(_ kinds: [UInt8]) throws {
            let bytes = Data(kinds.flatMap { [UInt8(0), 0, 0, 2, $0 << 1, 1] })
            try b.send(.video, bytes, flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed)
        }
        let parked = try XCTUnwrap(RemoteVideoStandbyMessage.decode(park, flags: 0, request: true))
        try reply(.parked, serial: parked.serial)
        try reply(.parked, serial: parked.serial)
        try video([32, 33, 34, 19])
        XCTAssertEqual(b.manager.slotStandbyPhaseForTesting, .parked)
        b.manager.requestVideoStandby(park: false, expectedGeneration: second.generation)
        let request = try XCTUnwrap(b.payloads(.remoteVideoStandby).last)
        let resume = try XCTUnwrap(RemoteVideoStandbyMessage.decode(request, flags: 0, request: true))
        try reply(.parked, serial: parked.serial)
        try video([32, 33, 34, 19])
        XCTAssertEqual(b.manager.slotStandbyPhaseForTesting, .resuming)
        try reply(.resuming, serial: resume.serial)
        try video([19])
        XCTAssertEqual(b.manager.slotStandbyPhaseForTesting, .resuming)
        try video([32, 33, 34, 19])
        try reply(.resuming, serial: resume.serial)
        XCTAssertEqual(b.manager.slotStandbyPhaseForTesting, .idle)
        let oldLifetime = a.manager.remoteKeyboardGeneration
        try a.send(.remoteVideoStandby, try XCTUnwrap(RemoteVideoStandbyMessage(operation: .parked, serial: 1).encode()))
        XCTAssertNotEqual(a.manager.remoteKeyboardGeneration, oldLifetime, "Unnegotiated standby must close this peer")
        a.manager.stopForTesting()
        let echo = Data(repeating: 9, count: 16)
        let ping = ConnectionControlProtocol.frame(type: WireMessageType.ping.rawValue, payload: echo, flags: 0)
        b.manager.receiveClipboardWireForTesting(ping, generation: second.generation, connection: first.connection)
        XCTAssertFalse(b.payloads(.pong).contains(echo))
        try b.send(.ping, echo)
        XCTAssertEqual(b.payloads(.pong).last, echo)
        try b.send(.remoteVideoStandby, Data(repeating: 0, count: 11))
        XCTAssertNotEqual(b.manager.remoteKeyboardGeneration, second.generation, "Malformed reply must close the negotiated peer")
    }

    @MainActor func testStreamRebindingDiscardsOldManagerEvents() {
        let a = Peer(.primary), b = Peer(.secondaryRemote)
        defer { a.finish(); b.finish() }
        let first = a.manager.beginSlotProbeForTesting()
        let second = b.manager.beginSlotProbeForTesting()
        let stream = StreamManager(networkManager: a.manager)
        stream.observe(a.manager, slot: .one, generation: first.generation)
        a.manager.stopForTesting()
        stream.observe(b.manager, slot: .two, generation: second.generation)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in stream.isConnected }, object: nil)
        wait(for: [selected], timeout: 2)
    }

    func testSecondaryRejectsDiscoveredAndCastingTargets() {
        let peer = Peer(.secondaryRemote)
        defer { peer.finish() }
        let generation = peer.manager.remoteKeyboardGeneration
        let casting = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 27015)
        let remote = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: NetworkManager.remoteControlPort)!)
        peer.manager.connect(to: casting)
        peer.manager.updateDiscoveredWifiEndpoints([remote])
        peer.manager.connectDiscoveredHostIfNeeded(remote)
        peer.manager.reconnectLastPC()
        peer.manager.networkQueueForTesting.sync {}
        XCTAssertEqual(peer.manager.remoteKeyboardGeneration, generation)
        XCTAssertFalse(peer.manager.hasReconnectTarget)
        XCTAssertTrue(RecentWifiResumeStore.consumeIfValid(defaults: peer.defaults))
    }

    func testResumeRequiresOrderedParameterSetsAndRealIDR() {
        func picture(_ kinds: [UInt8]) -> Bool {
            let data = Data(kinds.flatMap { [UInt8(0), 0, 0, 2, $0 << 1, 1] })
            return RemoteStandbyClient.isResumePicture(data, isIDR: true, lengthPrefixed: true)
        }
        XCTAssertFalse(picture([19, 32, 33, 34]))
        XCTAssertFalse(picture([32, 34, 19]))
        XCTAssertFalse(picture([32, 33, 34, 1]))
        XCTAssertTrue(picture([32, 33, 34, 20]))
    }

    func testStandbyReplyFenceAndFreshPicture() throws {
        var state = RemoteStandbyClient()
        let park = try XCTUnwrap(state.request(park: true))
        XCTAssertFalse(state.admitVideo(parameterSetIDR: true))
        state.receive(.init(operation: .parked, serial: park.serial))
        XCTAssertEqual(state.phase, .parked)
        let resume = try XCTUnwrap(state.request(park: false))
        XCTAssertGreaterThan(resume.serial, park.serial)
        XCTAssertFalse(state.admitVideo(parameterSetIDR: true))
        state.receive(.init(operation: .parked, serial: park.serial))
        state.receive(.init(operation: .parked, serial: resume.serial))
        XCTAssertFalse(state.admitVideo(parameterSetIDR: true))
        state.receive(.init(operation: .resuming, serial: resume.serial))
        XCTAssertFalse(state.admitVideo(parameterSetIDR: false))
        XCTAssertEqual(state.phase, .resuming)
        XCTAssertTrue(state.admitVideo(parameterSetIDR: true))
        state.receive(.init(operation: .resuming, serial: resume.serial))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.admitVideo(parameterSetIDR: false))
    }
}
#endif
