import XCTest
@testable import iPadCasting

final class ConnectionSwitchStateTests: XCTestCase {
    static func snapshot(revision: UInt64 = 2, owner: UInt64 = 1, route: ConnectionRoute = .wifi,
                         allowed: Bool = true, hostState: ConnectionHostState = .ready) throws -> ConnectionControlState {
        var b = Array(ConnectionControlProtocolTests.snapshot.dropFirst(16))
        b[2] = route.rawValue; b[4] = 1; b[5] = 1; b[38] = 0; b[6] = allowed ? 1 : 0
        b[1] = hostState.rawValue
        MirrorControlCodec.put(revision, &b, 8, 8); MirrorControlCodec.put(owner, &b, 16, 8)
        return try ConnectionControlState.decode(Data(b))
    }
    static func result(_ status: ConnectionResultStatus, transaction: UInt64 = 1,
                       reason: ConnectionReason = .none) throws -> ConnectionSelectResult {
        var b = Array(ConnectionControlProtocolTests.accepted.dropFirst(16))
        b[1] = status.rawValue; b[4] = UInt8(reason.rawValue)
        if status == .alreadyActive && reason == .none { b[2] = 1 }
        MirrorControlCodec.put(transaction, &b, 8, 8)
        if status == .completed { b[3] = 2; b[6] = 1; b[32] = 2; b[60] = 1 }
        else if status != .accepted { b.replaceSubrange(40..<56, with: repeatElement(UInt8(0), count: 16)); b[6] = status == .permissionRequired ? 3 : 1 }
        return try ConnectionSelectResult.decode(Data(b))
    }
    static func prepare(target: ConnectionRoute = .usb) throws -> ConnectionControlState {
        var bytes = Array(try snapshot(route: target == .usb ? .wifi : .usb).encode())
        bytes[7] = target == .usb ? ConnectionStatePhase.prepareUSB.rawValue : ConnectionStatePhase.prepareWiFi.rawValue
        bytes[24] = 1
        bytes.replaceSubrange(48..<64, with: UInt8(0)..<UInt8(16))
        bytes.replaceSubrange(64..<96, with: UInt8(32)..<UInt8(64))
        bytes.replaceSubrange(96..<128, with: UInt8(64)..<UInt8(96))
        return try ConnectionControlState.decode(Data(bytes))
    }
    static func wifiResult(failure: ConnectionReason? = nil) throws -> ConnectionSelectResult {
        var bytes = Array(ConnectionControlProtocolTests.accepted.dropFirst(16))
        bytes[2] = ConnectionRoute.wifi.rawValue
        bytes[3] = ConnectionRoute.usb.rawValue
        bytes[8] = 1
        if let failure {
            bytes[1] = ConnectionResultStatus.failed.rawValue
            bytes[4] = UInt8(failure.rawValue)
            bytes[6] = ConnectionHostState.failed.rawValue
            bytes[24] = 4; bytes[32] = 3
        }
        return try ConnectionSelectResult.decode(Data(bytes))
    }
    func ready(allowed: Bool = true) throws -> ConnectionSwitchState {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        XCTAssertNotNil(state.advertise(flags: 0x0200, authenticated: true, generation: 1))
        XCTAssertTrue(state.receive(try Self.snapshot(allowed: allowed), generation: 1, now: 0))
        return state
    }
    private func preparedProtectedSwitch() throws -> ConnectionSwitchState {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        _ = state.advertise(flags: 0x0300, authenticated: true, generation: 1)
        XCTAssertTrue(state.receive(try Self.snapshot(), generation: 1, now: 0))
        XCTAssertNotNil(state.select(.usb, now: 0))
        XCTAssertTrue(state.preparing(try Self.prepare(), generation: 1, now: 1))
        return state
    }
    func testProtectedCutoverRequiresProbeAndReplacementRender() throws {
        var state = try preparedProtectedSwitch()
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 2))
        XCTAssertFalse(state.receive(try Self.result(.accepted), generation: 1, now: 2))
        XCTAssertEqual(state.actualRoute, .wifi)
        XCTAssertTrue(state.markUSBProbeAnswered(generation: 1, now: 2))
        XCTAssertFalse(state.markUSBProbeAnswered(generation: 1, now: 2))
        XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: 2))
        XCTAssertTrue(state.bindReplacement(generation: 2, route: .usb, authenticated: true, now: 3))
        _ = state.advertise(flags: 0x0200, authenticated: true, generation: 2)
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, owner: 2, route: .usb), generation: 2, now: 3))
        XCTAssertTrue(state.receive(try Self.result(.completed), generation: 2, now: 4))
        XCTAssertNil(SessionConnectionPresentation(state: state, streamingRoute: .usb,
            hasWifiEndpoint: true).activeRoute)
        var lostBeforeRender = state
        XCTAssertTrue(lostBeforeRender.beginRollback(reason: .connectionLost, now: 4))
        XCTAssertTrue(lostBeforeRender.inputBlocked)
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2, now: 4)
        state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 2)
        state.rendered(sequence: 0, domain: .scst, decoder: 10, generation: 1, now: 4)
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 4)
        XCTAssertEqual(state.phase, .completed); XCTAssertFalse(state.inputBlocked)
        XCTAssertEqual(SessionConnectionPresentation(state: state, streamingRoute: .usb,
            hasWifiEndpoint: true).activeRoute, .usb)
    }
    func testProtectedPreflightRejectionKeepsOriginalWifi() throws {
        var state = try preparedProtectedSwitch()
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3), generation: 1, now: 2))
        XCTAssertTrue(state.receive(try Self.result(.unavailable, reason: .tunnelUnavailable), generation: 1, now: 2))
        XCTAssertFalse(state.inputBlocked); XCTAssertNil(state.pending)
        XCTAssertEqual(state.generation, 1); XCTAssertEqual(state.actualRoute, .wifi)
        XCTAssertFalse(state.beginRollback(reason: .connectionLost, now: 2))
    }
    func testRollbackRequiresFreshWifiAndExactFailedAuthority() throws {
        var state = try preparedProtectedSwitch()
        XCTAssertTrue(state.markUSBProbeAnswered(generation: 1, now: 2))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 2))
        XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: 2))
        XCTAssertTrue(state.beginRollback(reason: .connectionLost, now: 3))
        XCTAssertFalse(state.bindRollback(generation: 2, route: .wifi, authenticated: false, now: 4))
        XCTAssertTrue(state.bindRollback(generation: 2, route: .wifi, authenticated: true, now: 4))
        let hello = try XCTUnwrap(state.advertise(flags: 0x0300, authenticated: true, generation: 2))
        XCTAssertEqual(try ConnectionHello.decode(hello).kind, .optIn)
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, owner: 2, hostState: .failed), generation: 2, now: 4))
        var bytes = Array(ConnectionControlProtocolTests.accepted.dropFirst(16))
        bytes[1] = ConnectionResultStatus.failed.rawValue; bytes[4] = 20; bytes[6] = ConnectionHostState.failed.rawValue
        bytes[8] = 1; bytes[32] = 2
        let failed = try ConnectionSelectResult.decode(Data(bytes))
        bytes[40] ^= 1
        XCTAssertFalse(state.receive(try ConnectionSelectResult.decode(Data(bytes)), generation: 2, now: 4))
        bytes[40] ^= 1; bytes[8] = 2
        XCTAssertFalse(state.receive(try ConnectionSelectResult.decode(Data(bytes)), generation: 2, now: 4))
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2, now: 4)
        state.observeIDR(sequence: 12, domain: .rtp, decoder: 11, generation: 2)
        state.rendered(sequence: 12, domain: .rtp, decoder: 11, generation: 1, now: 4)
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 12, domain: .rtp, decoder: 11, generation: 2, now: 4)
        XCTAssertTrue(state.inputBlocked)
        XCTAssertFalse(state.receive(failed, generation: 1, now: 4))
        XCTAssertTrue(state.receive(failed, generation: 2, now: 4))
        XCTAssertEqual(state.actualRoute, .wifi); XCTAssertFalse(state.inputBlocked)
        XCTAssertEqual(state.issue, .connectionLost); XCTAssertNil(state.pending)
        let panel = SessionConnectionPresentation(state: state, streamingRoute: .wifi, hasWifiEndpoint: true)
        XCTAssertEqual(panel.outcome, "USB switch failed. Reconnected over Wi-Fi.")
        XCTAssertEqual(panel.action, .change(.usb, faster: false))
        XCTAssertNotNil(state.select(.usb, now: 4), "A rendered rollback restores route admission")
    }
    func testUSBRestoreRequiresOriginalFailureAndFreshOwnedRender() throws {
        var state = ConnectionSwitchState()
        state.begin(generation: 1)
        XCTAssertNotNil(state.advertise(flags: 0x0300, authenticated: true, generation: 1))
        XCTAssertTrue(state.receive(try Self.snapshot(route: .usb), generation: 1, now: 0))
        XCTAssertNotNil(state.select(.wifi, now: 0))
        XCTAssertTrue(state.preparing(try Self.prepare(target: .wifi), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, route: .usb, hostState: .switching),
                                    generation: 1, now: 2))
        XCTAssertTrue(state.receive(try Self.wifiResult(), generation: 1, now: 2))
        XCTAssertTrue(state.bindReplacement(generation: 2, route: .wifi, authenticated: true, now: 3))
        XCTAssertTrue(state.beginRollback(reason: .connectionLost, now: 90))
        XCTAssertEqual(state.message, "Reconnecting over USB...")
        XCTAssertFalse(state.bindRollback(generation: 3, route: .usb, authenticated: false, now: 91))
        XCTAssertFalse(state.bindRollback(generation: 3, route: .wifi, authenticated: true, now: 91))
        XCTAssertTrue(state.bindRollback(generation: 3, route: .usb, authenticated: true, now: 91))
        XCTAssertNotNil(state.advertise(flags: 0x0300, authenticated: true, generation: 3))
        XCTAssertFalse(state.receive(try Self.snapshot(revision: 4, owner: 1, route: .usb), generation: 3, now: 92))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 4, owner: 3, route: .usb, hostState: .failed),
                                    generation: 3, now: 92))
        let failed = try Self.wifiResult(failure: .firstFrameTimeout)
        var bytes = Array(try failed.encode())
        bytes[40] ^= 1
        XCTAssertFalse(state.receive(try ConnectionSelectResult.decode(Data(bytes)), generation: 3, now: 92))
        XCTAssertFalse(state.receive(failed, generation: 2, now: 92))
        state.expectDisplay(request: 7, decoder: 11, generation: 3)
        state.displayReady(request: 7, generation: 3, now: 92)
        state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 3)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 92)
        XCTAssertTrue(state.inputBlocked)
        var withoutResult = state
        withoutResult.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 3, now: 92)
        withoutResult.tick(now: 98)
        XCTAssertTrue(withoutResult.inputBlocked)
        XCTAssertNotNil(withoutResult.pending)
        withoutResult.tick(now: 165)
        XCTAssertTrue(withoutResult.offersReconnect)
        XCTAssertTrue(state.receive(failed, generation: 3, now: 92))
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 3, now: 92)
        XCTAssertFalse(state.inputBlocked)
        XCTAssertEqual(state.issue, .firstFrameTimeout)
        let panel = SessionConnectionPresentation(state: state, streamingRoute: .usb, hasWifiEndpoint: true)
        XCTAssertEqual(panel.activeRoute, .usb)
        XCTAssertEqual(panel.outcome, "Wi-Fi switch failed. Reconnected over USB.")
    }
    func testLostAcceptedCanRecoverWithinRollbackDeadline() throws {
        var state = try preparedProtectedSwitch()
        XCTAssertFalse(state.beginRollback(reason: .connectionLost, now: 2))
        XCTAssertTrue(state.markUSBProbeAnswered(generation: 1, now: 2))
        XCTAssertFalse(state.beginRollback(reason: .stoppedOnPC, now: 3))
        XCTAssertTrue(state.beginRollback(reason: .connectionLost, now: 3))
        XCTAssertTrue(state.bindRollback(generation: 2, route: .wifi, authenticated: true, now: 119))
        _ = state.advertise(flags: 0x0300, authenticated: true, generation: 2)
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, owner: 2), generation: 2, now: 119))
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2, now: 119)
        state.observeIDR(sequence: 12, domain: .scst, decoder: 11, generation: 2)
        var noPicture = state
        state.rendered(sequence: 12, domain: .scst, decoder: 11, generation: 2, now: 123)
        XCTAssertTrue(state.inputBlocked)
        state.tick(now: 124)
        XCTAssertEqual(state.actualRoute, .wifi); XCTAssertFalse(state.inputBlocked)
        noPicture.tick(now: 124)
        XCTAssertTrue(noPicture.inputBlocked); XCTAssertTrue(noPicture.offersReconnect)
    }
    func testWifiRollbackRejectsLateAuthenticationAndOldHosts() throws {
        var protected = try preparedProtectedSwitch()
        XCTAssertTrue(protected.markUSBProbeAnswered(generation: 1, now: 2))
        XCTAssertTrue(protected.beginRollback(reason: .connectionLost, now: 3))
        XCTAssertFalse(protected.bindRollback(generation: 2, route: .wifi, authenticated: true, now: 120))
        XCTAssertTrue(protected.inputBlocked); XCTAssertTrue(protected.offersReconnect)

        var legacy = try ready()
        XCTAssertNotNil(legacy.select(.usb, now: 0))
        XCTAssertTrue(legacy.preparing(try Self.prepare(), generation: 1, now: 1))
        XCTAssertTrue(legacy.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 2))
        XCTAssertTrue(legacy.receive(try Self.result(.accepted), generation: 1, now: 2))
        XCTAssertFalse(legacy.beginRollback(reason: .connectionLost, now: 3))
    }
    func testAcceptedFromTenPointOneThroughFourteenPointNineSecondsContinuesToOwnedRender() throws {
        for arrival in [10.1, 12, 14.9] {
            var state = try ready(); _ = state.select(.usb, now: 0)
            XCTAssertTrue(state.preparing(try Self.prepare(), generation: 1, now: 1))
            state.tick(now: 10)
            XCTAssertNotNil(state.pending); XCTAssertTrue(state.inputBlocked)
            XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: arrival))
            XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: arrival))
            XCTAssertTrue(state.bindReplacement(generation: 2, route: .usb, authenticated: true, now: arrival + 1))
            _ = state.advertise(flags: 0x0200, authenticated: true, generation: 2)
            _ = state.receive(try Self.snapshot(revision: 3, owner: 2, route: .usb), generation: 2, now: arrival + 1)
            XCTAssertTrue(state.receive(try Self.result(.completed), generation: 2, now: arrival + 2))
            state.expectDisplay(request: 7, decoder: 11, generation: 2)
            state.displayReady(request: 7, generation: 2, now: arrival + 2)
            state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 2)
            state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: arrival + 2)
            XCTAssertEqual(state.phase, .completed); XCTAssertFalse(state.inputBlocked)
        }
    }
    func testPreflightAtFifteenSecondsIsUnknownAndLateResultsCannotRestoreInput() throws {
        var state = try ready(); _ = state.select(.usb, now: 0)
        _ = state.preparing(try Self.prepare(), generation: 1, now: 1)
        state.preflightFailed(reason: .listenerClosed)
        XCTAssertNotNil(state.pending); XCTAssertTrue(state.inputBlocked)
        state.tick(now: 14.9)
        XCTAssertNotNil(state.pending); XCTAssertFalse(state.offersReconnect)
        state.tick(now: 15)
        XCTAssertNil(state.pending); XCTAssertEqual(state.actualRoute, .unknown)
        XCTAssertEqual(state.phase, .failed); XCTAssertTrue(state.inputBlocked)
        XCTAssertTrue(state.offersReconnect); XCTAssertEqual(state.message, "Connection change timed out")
        XCTAssertNotNil(ConnectScreenStatus.connectionChange(state))
        _ = state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 15)
        XCTAssertFalse(state.receive(try Self.result(.accepted), generation: 1, now: 15))
        XCTAssertFalse(state.receive(try Self.result(.completed), generation: 1, now: 16))
        state.tick(now: 20); XCTAssertTrue(state.inputBlocked)
        state.begin(generation: 2); XCTAssertFalse(state.inputBlocked)
    }
    func testPreflightBudgetStartsAtSendAndWaitingPeerCopyUsesTarget() throws {
        var state = try ready(); _ = state.select(.usb, now: 0); state.deferRequestSend()
        XCTAssertTrue(state.markRequestSent(transaction: 1, now: 4))
        state.tick(now: 18.9); XCTAssertNotNil(state.pending)
        state.tick(now: 19); XCTAssertTrue(state.offersReconnect); XCTAssertTrue(state.inputBlocked)
        for target in [ConnectionRoute.usb, .wifi] {
            state = try ready()
            if target == .wifi { _ = state.receive(try Self.snapshot(revision: 3, route: .usb), generation: 1, now: 0) }
            _ = state.select(target, now: 0)
            var prepare = Array(try Self.prepare().encode())
            if target == .wifi { prepare[2] = 2; prepare[7] = 2; prepare[8] = 3 }
            _ = state.preparing(try ConnectionControlState.decode(Data(prepare)), generation: 1, now: 1)
            _ = state.receive(try Self.snapshot(revision: 4, route: target == .usb ? .wifi : .usb, hostState: .switching), generation: 1, now: 1)
            var accepted = Array(try Self.result(.accepted).encode()); accepted[24] = 4
            if target == .wifi { accepted[2] = 1; accepted[3] = 2 }
            XCTAssertTrue(state.receive(try ConnectionSelectResult.decode(Data(accepted)), generation: 1, now: 1))
            state.waitingForPeer()
            XCTAssertEqual(state.message, target == .usb ? "Connecting over USB..." : "Connecting over Wi-Fi...")
        }
    }
    func testOldHostSilenceAndReplacementNegotiationReset() {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        XCTAssertNil(state.advertise(flags: 0, authenticated: true, generation: 1))
        XCTAssertNil(state.advertise(flags: 0x0200, authenticated: false, generation: 1))
        XCTAssertNil(state.select(.usb, now: 0))
        XCTAssertNotNil(state.advertise(flags: 0x0200, authenticated: true, generation: 1))
        state.begin(generation: 2)
        XCTAssertFalse(state.enabled); XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.recommendationText, "USB availability not checked")
    }
    func testLeaseEqualityBackwardsTimeAndStaleRevision() throws {
        var state = try ready()
        XCTAssertFalse(state.receive(try Self.snapshot(revision: 1), generation: 1, now: 1))
        XCTAssertNil(state.select(.usb, now: 10)); XCTAssertTrue(state.needsRefresh)
        state = try ready(); XCTAssertNil(state.select(.usb, now: -1))
        XCTAssertNil(state.select(.usb, now: 0), "backwards time invalidates authority until refresh")
    }
    func testPermissionAskAndApprovalRequireExplicitHigherTransaction() throws {
        var state = try ready(allowed: false)
        XCTAssertNil(state.select(.usb, now: 1))
        let first = try XCTUnwrap(state.select(.usb, askPC: true, now: 1))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, allowed: false, hostState: .awaitingPermission), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try Self.result(.permissionRequired), generation: 1, now: 1))
        XCTAssertEqual(state.message, "Allow connection changes on the PC"); XCTAssertNil(state.pending)
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 4), generation: 1, now: 2))
        XCTAssertNil(state.pending)
        XCTAssertGreaterThan(try XCTUnwrap(state.select(.usb, now: 2)).transaction, first.transaction)
    }
    func testSameRouteNoopAndUnrelatedDuplicateCannotSettlePending() throws {
        var state = try ready(); XCTAssertNotNil(state.select(.wifi, now: 1))
        XCTAssertEqual(state.actualRoute, .wifi)
        var bytes = Array(try Self.result(.alreadyActive).encode()); bytes[2] = 1
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try ConnectionSelectResult.decode(Data(bytes)), generation: 1, now: 1))
        XCTAssertEqual(state.message, "Already using Wi-Fi")
        state = try ready(); XCTAssertNotNil(state.select(.usb, now: 1))
        XCTAssertFalse(state.receive(try Self.result(.busy, reason: .duplicateTransaction), generation: 1, now: 2))
        XCTAssertFalse(state.receive(try Self.result(.denied, transaction: 99, reason: .notOwner), generation: 1, now: 2))
        XCTAssertNotNil(state.pending)
    }
    func accepted() throws -> ConnectionSwitchState {
        var state = try ready(); XCTAssertNotNil(state.select(.usb, now: 0))
        XCTAssertTrue(state.preparing(try Self.prepare(), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: 1))
        XCTAssertTrue(state.bindReplacement(generation: 2, route: .usb, authenticated: true, now: 2))
        XCTAssertNotNil(state.advertise(flags: 0x0200, authenticated: true, generation: 2))
        XCTAssertTrue(state.receive(try Self.snapshot(revision: 3, owner: 2, route: .usb), generation: 2, now: 2))
        return state
    }
    func testCompletedDisplayAndOwnedIDRRenderEitherOrderAndWrappedZero() throws {
        for completedFirst in [true, false] {
            var state = try accepted()
            state.expectDisplay(request: 7, decoder: 11, generation: 2)
            if completedFirst { XCTAssertTrue(state.receive(try Self.result(.completed), generation: 2, now: 3)) }
            state.displayReady(request: 6, generation: 2); XCTAssertTrue(state.inputBlocked)
            state.displayReady(request: 7, generation: 2)
            state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 2)
            state.rendered(sequence: 0, domain: .rtp, decoder: 11, generation: 2, now: 3)
            state.rendered(sequence: 0, domain: .scst, decoder: 10, generation: 2, now: 3)
            XCTAssertTrue(state.inputBlocked)
            state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 3)
            if !completedFirst { XCTAssertTrue(state.inputBlocked); XCTAssertTrue(state.receive(try Self.result(.completed), generation: 2, now: 3)) }
            XCTAssertFalse(state.inputBlocked); XCTAssertEqual(state.message, "Connected over USB")
            XCTAssertNil(state.pending)
        }
    }
    func testOutcomePresentationAndAbsoluteDeadlineNeverRevive() throws {
        var state = try ready(); _ = state.select(.usb, now: 0)
        state.tick(now: 75); XCTAssertEqual(state.message, "Connection change timed out")
        XCTAssertFalse(state.receive(try Self.result(.accepted), generation: 1, now: 75))
        state = try accepted(); XCTAssertTrue(state.receive(try Self.result(.completed), generation: 2, now: 74))
        state.tick(now: 79); XCTAssertEqual(state.message, "No picture on the new connection")
        XCTAssertTrue(state.inputBlocked); XCTAssertTrue(state.offersReconnect)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 79)
        XCTAssertTrue(state.inputBlocked)
    }
    func testUnexpectedDisconnectBackgroundAndStopCancel() throws {
        for reason in [ConnectionReason.connectionLost, .stoppedOnPC] {
            var state = try accepted(); state.cancel(reason: reason)
            XCTAssertNil(state.pending); XCTAssertTrue(state.inputBlocked)
            XCTAssertFalse(state.receive(try Self.result(.completed), generation: 2, now: 3))
        }
    }

    func testStoppedOnPCRetiresTheAuthenticatedHandoffAndClearsPanelProgress() throws {
        var state = try accepted()
        let streaming = SessionConnectionPresentation(state: state, streamingRoute: .usb, hasWifiEndpoint: true)
        XCTAssertEqual(streaming.action, .waiting(state.message, showsProgress: true))
        XCTAssertNil(streaming.activeRoute)
        let authority = try Self.snapshot(revision: 4, owner: 2, route: .usb, hostState: .failed)
        XCTAssertTrue(state.receive(authority, generation: 2, now: 3))
        let stopped = ConnectionSelectResult(status: .failed, target: .usb, current: .usb, reason: .stoppedOnPC,
            hostState: .failed, transaction: 1, originOwner: 1, revision: 4, routeOwner: 2, token: Data(0..<16),
            firstFrame: 0, frameDomain: .none)
        XCTAssertFalse(state.receive(stopped, generation: 1, now: 3))
        XCTAssertTrue(state.receive(stopped, generation: 2, now: 3))
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.issue, .stoppedOnPC)
        let panel = SessionConnectionPresentation(state: state, streamingRoute: nil, hasWifiEndpoint: true)
        XCTAssertNil(panel.activeRoute)
        XCTAssertEqual(panel.action, .reconnect)
        XCTAssertEqual(panel.outcome, "Casting stopped on PC")
    }
    func testBufferOverflowLosesIDRAndDependentDeltas() {
        var buffer = CaptureTargetVideoBuffer()
        for sequence in 0...120 {
            buffer.append(.init(data: Data([1]), sequence: UInt32(sequence), isIDR: sequence == 0, lengthPrefixed: true, receivedAt: 0))
        }
        XCTAssertTrue(buffer.frames.isEmpty)
        buffer.append(.init(data: Data([1]), sequence: 121, isIDR: false, lengthPrefixed: true, receivedAt: 0))
        XCTAssertTrue(buffer.frames.isEmpty)
    }
    func testAcceptedNeedsPreparationAndReplacementMustMatchRouteAndLifetime() throws {
        var state = try ready(); _ = state.select(.usb, now: 0)
        _ = state.receive(try Self.snapshot(revision: 3, hostState: .switching), generation: 1, now: 1)
        XCTAssertFalse(state.receive(try Self.result(.accepted), generation: 1, now: 1))
        XCTAssertTrue(state.preparing(try Self.prepare(), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: 1))
        XCTAssertFalse(state.bindReplacement(generation: 1, route: .usb, authenticated: true, now: 2))
        XCTAssertFalse(state.bindReplacement(generation: 2, route: .wifi, authenticated: true, now: 2))
        XCTAssertFalse(state.bindReplacement(generation: 2, route: .usb, authenticated: false, now: 2))
        XCTAssertTrue(state.inputBlocked)
    }
    func testLostIDRAndOldDecoderCannotCompletePresentation() throws {
        var state = try accepted()
        _ = state.receive(try Self.result(.completed), generation: 2, now: 3)
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2)
        state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 2)
        state.invalidateDecodeRoot(generation: 2)
        state.rendered(sequence: 1, domain: .scst, decoder: 11, generation: 2, now: 3)
        XCTAssertTrue(state.inputBlocked)
        state.expectDisplay(request: 7, decoder: 12, generation: 2)
        state.displayReady(request: 7, generation: 2)
        state.observeIDR(sequence: 1, domain: .scst, decoder: 12, generation: 2)
        state.rendered(sequence: 1, domain: .scst, decoder: 11, generation: 2, now: 3)
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 1, domain: .scst, decoder: 12, generation: 2, now: 3)
        XCTAssertFalse(state.inputBlocked)
    }
    func testWrappedSequenceMustBeAtOrAfterFirstFrame() throws {
        var state = try accepted()
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2)
        state.observeIDR(sequence: UInt32.max, domain: .scst, decoder: 11, generation: 2)
        _ = state.receive(try Self.result(.completed), generation: 2, now: 3)
        state.rendered(sequence: UInt32.max, domain: .scst, decoder: 11, generation: 2, now: 3)
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 3)
        XCTAssertFalse(state.inputBlocked)
    }
    func testAllCompletedDisplayAndRenderPermutations() throws {
        for events in [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]] {
            var state = try accepted()
            state.expectDisplay(request: 7, decoder: 11, generation: 2)
            for event in events {
                switch event {
                case 0: _ = state.receive(try Self.result(.completed), generation: 2, now: 3)
                case 1: state.displayReady(request: 7, generation: 2, now: 3)
                default:
                    state.observeIDR(sequence: 0, domain: .scst, decoder: 11, generation: 2)
                    state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 3)
                }
            }
            XCTAssertFalse(state.inputBlocked, "event order: \(events)")
        }
    }
    func testUsbToWifiReplacementNegotiatesAgainAndUsesRtpFrameDomain() throws {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        _ = state.advertise(flags: 0x0200, authenticated: true, generation: 1)
        _ = state.receive(try Self.snapshot(route: .usb), generation: 1, now: 0)
        XCTAssertNotNil(state.select(.wifi, now: 0))
        var prepare = Array(try Self.prepare().encode()); prepare[2] = 2; prepare[7] = 2
        XCTAssertTrue(state.preparing(try ConnectionControlState.decode(Data(prepare)), generation: 1, now: 1))
        _ = state.receive(try Self.snapshot(revision: 3, route: .usb, hostState: .switching), generation: 1, now: 1)
        var accepted = Array(try Self.result(.accepted).encode()); accepted[2] = 1; accepted[3] = 2
        XCTAssertTrue(state.receive(try ConnectionSelectResult.decode(Data(accepted)), generation: 1, now: 1))
        XCTAssertFalse(state.bindReplacement(generation: 2, route: .wifi, authenticated: false, now: 2))
        XCTAssertTrue(state.bindReplacement(generation: 2, route: .wifi, authenticated: true, now: 2))
        XCTAssertFalse(state.enabled); XCTAssertNil(state.snapshot)
        XCTAssertNil(state.advertise(flags: 0, authenticated: true, generation: 2))
        XCTAssertNotNil(state.advertise(flags: 0x0200, authenticated: true, generation: 2))
        _ = state.receive(try Self.snapshot(revision: 3, owner: 2), generation: 2, now: 2)
        var completed = Array(try Self.result(.completed).encode()); completed[2] = 1; completed[3] = 1; completed[60] = 2
        XCTAssertTrue(state.receive(try ConnectionSelectResult.decode(Data(completed)), generation: 2, now: 3))
        state.expectDisplay(request: 7, decoder: 11, generation: 2)
        state.displayReady(request: 7, generation: 2, now: 3)
        state.observeIDR(sequence: 0, domain: .rtp, decoder: 11, generation: 2)
        state.rendered(sequence: 0, domain: .scst, decoder: 11, generation: 2, now: 3)
        XCTAssertTrue(state.inputBlocked)
        state.rendered(sequence: 0, domain: .rtp, decoder: 11, generation: 2, now: 3)
        XCTAssertEqual(state.message, "Connected over Wi-Fi"); XCTAssertFalse(state.inputBlocked)
    }
    func testAcceptedCanAdvanceLatestReadySnapshotAfterResumePreparation() throws {
        var state = try ready(); _ = state.select(.usb, now: 0)
        _ = state.preparing(try Self.prepare(), generation: 1, now: 1)
        _ = state.receive(try Self.snapshot(revision: 3), generation: 1, now: 1)
        XCTAssertTrue(state.receive(try Self.result(.accepted), generation: 1, now: 1))
    }
    func testListenerPreparationDoesNotSpendSentRequestBudgetOrSendStaleRevision() throws {
        var state = try ready(); let request = try XCTUnwrap(state.select(.usb, now: 0))
        state.deferRequestSend(); state.tick(now: 4)
        XCTAssertFalse(try XCTUnwrap(state.pending).sent)
        XCTAssertTrue(state.markRequestSent(transaction: request.transaction, now: 4))
        XCTAssertEqual(state.pending?.started, 4)
        state = try ready(); _ = state.select(.usb, now: 0); state.deferRequestSend()
        _ = state.receive(try Self.snapshot(revision: 3), generation: 1, now: 1)
        XCTAssertFalse(state.markRequestSent(transaction: 1, now: 1))
    }
    func testUiAvailabilityAndErrorStrings() throws {
        let cases: [(ConnectionReason, String)] = [(.notRunning, "Start casting on the PC"),
            (.permissionMissing, "Allow connection changes on the PC"), (.permissionDenied, "Connection change denied on PC"),
            (.localOperation, "PC is busy. Try again."), (.noDevice, "Connect a USB cable"),
            (.multipleDevices, "Connect only this iPad by USB"), (.deviceUnverified, "USB cable detected, not verified"),
            (.wrongDevice, "USB connection could not be verified"), (.proofFailed, "USB connection could not be verified"),
            (.listenerClosed, "USB listener is unavailable on iPad"), (.tunnelUnavailable, "USB connection unavailable"),
            (.identityUnavailable, "Pair this iPad before changing connection"), (.staleRevision, "Refresh connection status"),
            (.replay, "Connection request is no longer valid"), (.stoppedOnPC, "Casting stopped on PC"),
            (.peerTimeout, "Connection check timed out"), (.connectionLost, "Connection lost")]
        for (reason, text) in cases { XCTAssertEqual(reason.text(target: .usb), text) }
        XCTAssertEqual(ConnectionReason.listenerClosed.text(target: .wifi), "Wi-Fi listener is unavailable on PC")
        let state = try ready()
        XCTAssertEqual(state.disabledReason(for: .wifi, hasWifiEndpoint: false), nil, "current route remains a no-op")
        var usb = state
        _ = usb.receive(try Self.snapshot(revision: 3, route: .usb), generation: 1, now: 1)
        XCTAssertEqual(usb.disabledReason(for: .wifi, hasWifiEndpoint: false), "Wi-Fi listener is unavailable on PC")
    }
    func testDetectedUsbMayBeRequestedWithoutTreatingItAsRecommended() throws {
        var state = ConnectionSwitchState(); state.begin(generation: 1)
        _ = state.advertise(flags: 0x0200, authenticated: true, generation: 1)
        _ = state.receive(try ConnectionControlState.decode(Data(ConnectionControlProtocolTests.snapshot.dropFirst(16))), generation: 1, now: 0)
        XCTAssertEqual(state.recommendationText, "USB cable detected, not verified")
        XCTAssertNil(state.disabledReason(for: .usb, hasWifiEndpoint: true))
        XCTAssertNotNil(state.select(.usb, now: 0))
    }
}
