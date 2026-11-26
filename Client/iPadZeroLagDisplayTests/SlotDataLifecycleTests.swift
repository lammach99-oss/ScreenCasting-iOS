import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import iPadCasting

final class SlotDataLifecycleTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testDelayedClipboardWorkAndParkedCopiesAreDropped() async throws {
        var changes = 0, reads = 0, revision = 1
        var controls: [Bool] = []
        let focus = RemoteClipboardFocus { slot, enabled in
            if slot == .one { controls.append(enabled) }
        }
        let authority = RemoteClipboardAuthority()
        let board = RemoteClipboardPasteboard(authority: authority, worker: RemoteClipboardContentWorker(),
            send: { _, _, _, _ in XCTFail("Retired send") }, changed: { _, _ in changes += 1 },
            readSource: .init(changeCount: { reads += 1; return revision }, itemCount: { 1 },
                              types: { [UTType.plainText.identifier] }, providers: { [] }))
        board.bindFocus(focus, slot: .one)
        func installGrant(_ epoch: UInt64) -> RemoteClipboardAuthority.Grant {
            let token = UUID()
            let state = RemoteClipboardProtocol.State(kind: .enabled, directions: 3, maxBytes: 128,
                maxChunk: 128, formats: 3, nonce: UUID(), token: token, epoch: epoch, requestID: 1, reason: .ok)
            authority.setSceneActive(true)
            authority.update(state, deadline: ProcessInfo.processInfo.systemUptime + 30, transfer: nil)
            let grant = RemoteClipboardAuthority.Grant(token: token, epoch: epoch, directions: 3, maxBytes: 128)
            board.update(supported: true, grant: grant, reason: .ok)
            return grant
        }
        focus.promote(slot: .one, epoch: 1)
        let old = installGrant(1)
        board.setAutomatic(true)
        let late = Task { @MainActor in board.pollForTesting(grant: old) }
        focus.demote(slot: .one, epoch: 1)
        focus.promote(slot: .two, epoch: 2)
        revision += 1
        let before = reads
        await late.value
        XCTAssertEqual(reads, before)
        focus.promote(slot: .one, epoch: 3)
        _ = installGrant(3)
        board.pollForTesting()
        XCTAssertEqual(changes, 0)
        revision += 1
        board.pollForTesting()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controls, [false, true, false, true])
        focus.demote(slot: .one, epoch: 3)
    }

    @MainActor func testIncomingApplyCompletionCannotSurviveRoundTripSwap() async throws {
        let focus = RemoteClipboardFocus { _, _ in }
        let authority = RemoteClipboardAuthority()
        let board = RemoteClipboardPasteboard(authority: authority, worker: RemoteClipboardContentWorker(),
            send: { _, _, _, _ in }, changed: { _, _ in })
        board.bindFocus(focus, slot: .one)
        focus.promote(slot: .one, epoch: 1)
        let token = UUID(), now = ProcessInfo.processInfo.systemUptime
        let state = RemoteClipboardProtocol.State(kind: .enabled, directions: 2, maxBytes: 128,
            maxChunk: 128, formats: 3, nonce: UUID(), token: token, epoch: 1, requestID: 1, reason: .ok)
        let grant = RemoteClipboardAuthority.Grant(token: token, epoch: 1, directions: 2, maxBytes: 128)
        let prefix = RemoteClipboardProtocol.Prefix(token: token, epoch: 1, update: UUID())
        let content = try XCTUnwrap(RemoteClipboardContent.prepare(Data([65]), format: .text, formats: 1, fromWire: true))
        let offer = RemoteClipboardProtocol.Offer(prefix: prefix, format: .text, formats: 1, length: 1,
            origin: UUID(), counter: 1, revision: 1, digest: content.digest)
        authority.setSceneActive(true)
        authority.update(state, deadline: now + 10, transfer: RemoteClipboardTransfer(offer: offer, now: now))
        board.update(supported: true, grant: grant, reason: .ok)
        let revision = try XCTUnwrap(board.revision(grant: grant, prefix: prefix))
        var result: RemoteClipboardProtocol.Reason?
        let late = Task { @MainActor in
            board.apply(content, revision: revision, grant: grant, prefix: prefix) { reason, _ in result = reason }
        }
        focus.promote(slot: .two, epoch: 2)
        focus.promote(slot: .one, epoch: 3)
        // Even a still-valid transport grant cannot revive the previous focus revision.
        board.update(supported: true, grant: grant, reason: .ok)
        await late.value
        XCTAssertEqual(result, .staleGrant)
        focus.demote(slot: .one, epoch: 3)
    }

    @MainActor func testDemotionSendsWireDisableAndStopsRenewal() throws {
        var lease = RemoteClipboardLease()
        guard case .hello(_, _, _, let nonce) = try XCTUnwrap(lease.start()) else { return XCTFail("Hello") }
        let disabled = RemoteClipboardProtocol.State(kind: .disabled, directions: 0, maxBytes: 128,
            maxChunk: 128, formats: 3, nonce: nonce, token: RemoteClipboardProtocol.emptyID,
            epoch: 1, requestID: 0, reason: .viewerDisabled)
        lease.receive(disabled, eligible: true, now: 0)
        var messages: [RemoteClipboardProtocol.Message] = []
        let focus = RemoteClipboardFocus { _, enabled in
            if let message = lease.tick(eligible: enabled, now: 1) { messages.append(message) }
        }
        focus.promote(slot: .one, epoch: 1)
        focus.demote(slot: .one, epoch: 1)
        focus.promote(slot: .one, epoch: 1)
        XCTAssertEqual(messages, [.control(.request, 3, 1, true, nonce), .control(.disable, 0, 2, false, nonce)])
        XCTAssertNil(lease.tick(eligible: focus.isAuthorized(slot: .one, epoch: 1), now: 4))
    }

    @MainActor func testSwapCancelsOnlyActiveTransferAndSharesRetainedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = try ReceivedFileLibrary(directory: root)
        let selected = try ReceivedFileLibrary(directory: root)
        let file = root.appendingPathComponent("completed.bin"), bytes = Data([3])
        try bytes.write(to: file)
        try parked.recordPublished(file, length: 1, digest: Data(SHA256.hash(data: bytes)))
        let id = UUID()
        let manager = DataTransferManager(generation: 1, directory: root, receivedLibrary: parked) { _, done in done(true) }
        let files = RemoteFileSlotScope(slot: .one, manager: manager)
        files.promote(epoch: 1)
        manager.post(TransferPacket(kind: .offer, generation: 1, id: id, files: [TransferFile(name: "pending", length: 1)]))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while manager.activeTransferID != id && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let ticket = RemoteFileSlotScope.Action(slot: .one, epoch: 1, transferID: id)
        XCTAssertTrue(files.isAuthorized(ticket))
        XCTAssertThrowsError(try selected.confirmClear())
        files.cancelOnSwap(epoch: 1)
        XCTAssertFalse(files.isAuthorized(ticket))
        let cancelled = ProcessInfo.processInfo.systemUptime + 2
        while (try selected.snapshot()).busy && ProcessInfo.processInfo.systemUptime < cancelled {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(manager.activeTransferID)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try selected.clear(selected.confirmClear()).deletedCount, 1)
        XCTAssertEqual(try parked.snapshot().retainedCount, 0)
    }
    #endif

    func testParkAndSceneLifecycleEffects() {
        let policy = SlotLifecyclePolicy()
        XCTAssertEqual(policy.park(.two), [.releaseAuthority(.two)])
        XCTAssertEqual(policy.background(primary: .usb, secondary: .tailscale), [
            .releaseAuthority(.one), .hidePreview(.one), .releaseAuthority(.two), .hidePreview(.two),
            .suspendUSB(.one), .applyWiFiGrace(.two)])
        XCTAssertEqual(policy.foreground(hasSecondary: true), [.revalidateSessionPictureAndAuthority(.one),
                                                                .revalidateSessionPictureAndAuthority(.two)])
    }

    @MainActor func testExportBoundsPrivacyAndLegacyBytes() throws {
        let legacy = Data("private.invalid,synthetic-peer-id\r\n".utf8)
        let owner = SlotTimelineExport()
        for epoch in 0...260 { owner.record(slot: .one, route: .wifi, epoch: UInt64(epoch), event: .decoded) }
        owner.record(slot: .two, route: .tailscale, epoch: 261, event: .presented)
        XCTAssertEqual(try owner.export(hasSecondary: false) { legacy }, legacy)
        let data = try owner.export(hasSecondary: true) { XCTFail("Read legacy context"); return legacy }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 257)
        XCTAssertEqual(rows.first?["epoch"] as? Int, 5)
        XCTAssertEqual(rows.last?["slot"] as? Int, 2)
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["slot", "epoch", "route", "event", "elapsedMs"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private.invalid"))
        XCTAssertFalse(text.contains("synthetic-peer-id"))
    }
}
