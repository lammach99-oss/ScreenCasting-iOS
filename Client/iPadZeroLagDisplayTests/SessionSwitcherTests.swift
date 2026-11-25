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
