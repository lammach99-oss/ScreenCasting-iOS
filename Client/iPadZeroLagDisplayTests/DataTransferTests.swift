import CryptoKit
import Network
import XCTest
import Foundation
@testable import iPadCasting

final class DataTransferTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testV310AudioIngressIsBoundedBeforeBlockedWorker() {
        for (opus, size) in [(false, 1920), (true, 1920), (false, 32768), (true, 32768)] {
            let audio = AudioManager.makeForTesting()
            let lock = NSLock()
            var packets = 0, bytes = 0
            audio.ingressRetentionForTesting = { count in
                lock.lock(); defer { lock.unlock() }
                packets += count > 0 ? 1 : -1; bytes += count
            }
            let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            audio.audioQueueForTesting.async { held.signal(); release.wait() }
            XCTAssertEqual(held.wait(timeout: .now() + 1), .success)
            for index in 0..<100 {
                let data = Data(repeating: 0, count: size)
                if opus { audio.playOpusData(data, sequence: UInt16(index), timestamp: UInt32(index * 480), generation: 70) }
                else { audio.playPCMData(data, generation: 70) }
            }
            lock.lock(); let retained = (packets, bytes); lock.unlock()
            XCTAssertLessThanOrEqual(retained.0, 64, "Pre-dispatch packet bound")
            XCTAssertLessThanOrEqual(retained.1, 256 * 1024, "Pre-dispatch byte bound")
            audio.reset() // Queued reset cannot return old retained-payload credit early.
            release.signal()
            audio.audioQueueForTesting.sync {}
            lock.lock(); let drained = (packets, bytes); lock.unlock()
            XCTAssertEqual(drained.0, 0); XCTAssertEqual(drained.1, 0)
            audio.reset(); audio.audioQueueForTesting.sync {}
        }
    }

    func testV310RetiredWifiControlCompletionCannotBlockNewOwner() {
        let network = NetworkManager()
        var callbacks: [(NWError?) -> Void] = []
        var stale = 0, current = 0
        network.controlSendForAudioTesting = { _, done in callbacks.append(done) }
        _ = network.simulateCommittedWifiSessionForTesting()
        network.enqueueControlForTesting { _ in stale += 1 }
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(callbacks.count, 1)
        network.stopForTesting()
        _ = network.simulateCommittedWifiSessionForTesting()
        network.enqueueControlForTesting { _ in current += 1 }
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(callbacks.count, 2, "Replacement must progress before old completion")
        guard callbacks.count == 2 else { network.stopForTesting(); return }
        callbacks[0](nil); network.networkQueueForTesting.sync {}
        XCTAssertEqual(stale, 0); XCTAssertEqual(current, 0)
        callbacks[1](nil); network.networkQueueForTesting.sync {}
        XCTAssertEqual(current, 1)
        network.stopForTesting()
    }
    #endif
    func testV310ReservedNamespaceRejectedWithoutRejectingOrdinaryHiddenOrPartFiles() throws {
        for name in [".scdt-receipts-v1", ".SCDT-RECEIPTS-V1", ".scdt-user.part", ".SCDT-X.PART", ".scdt-anything"] {
            XCTAssertFalse(TransferProtocol.validName(name), name)
            XCTAssertThrowsError(try TransferProtocol.encode(TransferPacket(kind: .offer, generation: 1, id: UUID(),
                files: [TransferFile(name: name, length: 0)])), name)
        }
        for name in ["normal.part", ".hidden", "report.pdf"] { XCTAssertTrue(TransferProtocol.validName(name), name) }
    }

    func testV310RestartPreservesUnprovenGlobMatchingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try ReceivedFileLibrary(directory: root)
        let legacy = root.appendingPathComponent(".scdt-historical-user.part")
        try Data([3, 7]).write(to: legacy)
        let manager = DataTransferManager(generation: 1, directory: root, receivedLibrary: library) { _, done in done(true) }
        await ux03Barrier(manager)
        XCTAssertEqual(try Data(contentsOf: legacy), Data([3, 7]), "A filename glob is not deletion authority")
        manager.retire(); await ux03Barrier(manager)
        try FileManager.default.removeItem(at: root)
    }

    func testV310PublishingNewReceiptDoesNotReadOlderPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var readBytes = 0
        var hooks = ReceivedFileLibrary.Hooks(); hooks.payloadBytesRead = { readBytes += $0 }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        let old = root.appendingPathComponent("old.bin"), oldBytes = Data(repeating: 1, count: 65537)
        try oldBytes.write(to: old)
        try library.recordPublished(old, length: UInt64(oldBytes.count), digest: Data(SHA256.hash(data: oldBytes)))
        readBytes = 0
        let fresh = root.appendingPathComponent("fresh.bin"), freshBytes = Data([8, 9, 10])
        try freshBytes.write(to: fresh)
        try library.recordPublished(fresh, length: 3, digest: Data(SHA256.hash(data: freshBytes)))
        XCTAssertEqual(readBytes, 3, "Only the new arbitrary URL must be digest verified")
        XCTAssertEqual(try library.snapshot().eligibleCount, 2)
        XCTAssertThrowsError(try library.recordPublished(fresh, length: 3, digest: Data(count: 32)))
    }

    func testV310TransferDiagnosticTotalsAreMonotonicAndExactInBothDirections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin"), empty = root.appendingPathComponent("empty.bin")
        try Data([1, 2, 3]).write(to: source); try Data().write(to: empty)
        let approval = expectation(description: "explicit approval"), completed = expectation(description: "batch completed")
        var left: DataTransferManager!, right: DataTransferManager!
        var outgoing: [String] = [], incoming: [String] = []
        left = DataTransferManager(generation: 1, directory: root.appendingPathComponent("left")) { packet, done in
            if !right.post(packet, completion: { done(true) }) { done(false) }
        }
        right = DataTransferManager(generation: 2, directory: root.appendingPathComponent("right")) { packet, done in
            if !left.post(packet, completion: { done(true) }) { done(false) }
        }
        left.diagnostic = { outgoing.append($0) }; right.diagnostic = { incoming.append($0) }
        right.changed = { if $0.phase == .awaitingDecision { approval.fulfill() } }
        left.changed = { if $0.phase == .completed { completed.fulfill() } }
        left.sendFiles([source, empty]); await fulfillment(of: [approval], timeout: 3)
        right.decide(true); await fulfillment(of: [completed], timeout: 5)
        await ux03Barrier(left); await ux03Barrier(right)
        for lines in [outgoing, incoming] {
            let counts = lines.filter { $0.contains("transfer_id=") && !$0.contains("transfer_id=none") }.compactMap { line in
                line.split(separator: " ").first { $0.hasPrefix("bytes=") }.flatMap { UInt64($0.dropFirst(6)) }
            }
            XCTAssertFalse(counts.isEmpty)
            XCTAssertTrue(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 }, "Diagnostic observed bytes decreased: \(counts)")
            XCTAssertTrue(counts.allSatisfy { $0 <= 3 }, "Diagnostic total double-counted: \(counts)")
            XCTAssertEqual(counts.last, 3)
        }
        left.retire(); right.retire(); await ux03Barrier(left); await ux03Barrier(right)
    }

    #if targetEnvironment(simulator)
    func testV310RetiredTransferObserverCannotAdvanceCurrentClearRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let network = NetworkManager(receivedFilesDirectory: root)
        _ = network.simulateCommittedWifiSessionForTesting()
        let (old, observer) = network.transferObserverForTesting()
        await ux03Barrier(old); network.networkQueueForTesting.sync {}
        _ = network.simulateCommittedWifiSessionForTesting()
        network.configureTransferAuthorizationForTesting(manager: nil, authenticated: true, committed: true)
        let (current, _) = network.transferObserverForTesting()
        await ux03Barrier(current); network.networkQueueForTesting.sync {}
        let revision = network.receivedRevisionForTesting
        var stale = DataTransferManager.Snapshot(); stale.phase = .completed; stale.published = 1
        observer(stale); network.networkQueueForTesting.sync {}
        XCTAssertEqual(network.receivedRevisionForTesting, revision)
        network.stopForTesting(); old.retire(); current.retire()
        await ux03Barrier(old); await ux03Barrier(current)
        try? FileManager.default.removeItem(at: root)
    }
    #endif

    func testC04InventoryRejectsReplacementWithoutPayloadReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var readBytes = 0
        var hooks = ReceivedFileLibrary.Hooks()
        hooks.payloadBytesRead = { readBytes += $0 }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        let file = root.appendingPathComponent("identity.bin"), bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        try library.recordPublished(file, length: 3, digest: Data(SHA256.hash(data: bytes)))
        readBytes = 0
        XCTAssertEqual(try library.snapshot().eligibleCount, 1)
        // Atomic replacement keeps equal bytes/length but changes inode ownership.
        try bytes.write(to: file, options: .atomic)
        XCTAssertEqual(try library.snapshot().eligibleCount, 0)
        XCTAssertEqual(try library.snapshot().retainedBytes, 3)
        XCTAssertEqual(readBytes, 0)
    }

    func testC04InventoryDoesNotRereadVerifiedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var readBytes = 0
        var hooks = ReceivedFileLibrary.Hooks()
        hooks.payloadBytesRead = { readBytes += $0 }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        let bytes = Data(repeating: 0x41, count: 512 * 1024 + 1)
        let store = try TransferStore(directory: root,
            metadata: TransferFile(name: "io-fixture.bin", length: UInt64(bytes.count)), id: UUID())
        var offset = 0
        var chunk: UInt64 = 0
        while offset < bytes.count {
            let end = min(offset + 16 * 1024, bytes.count)
            try store.append(chunk: chunk, offset: UInt64(offset), bytes: bytes.subdata(in: offset..<end))
            offset = end; chunk += 1
        }
        let digest = Data(SHA256.hash(data: bytes))
        let published = try store.publish(length: UInt64(bytes.count), digest: digest)
        try library.recordPublished(published, length: UInt64(bytes.count), digest: digest)
        let receiptReadBytes = readBytes
        XCTAssertEqual(try library.snapshot().eligibleCount, 1)
        XCTAssertEqual(try library.snapshot().eligibleCount, 1)
        XCTAssertEqual(readBytes - receiptReadBytes, 0,
            "Inventory must not reread payload after receipt verification")
        XCTAssertEqual(try Data(contentsOf: published), bytes)
    }


    // C2 v3.3 G3: executable tests against the fail-closed OFF/default API.
    private final class UX02Session {
        let root: URL, library: ReceivedFileLibrary, network: NetworkManager
        let generation: UInt64
        var manager: DataTransferManager!
        private let lock = NSLock()
        private var sent: [TransferPacket] = []
        init(usb: Bool = false, hooks: ReceivedFileLibrary.Hooks = .init()) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            library = try ReceivedFileLibrary(directory: root, hooks: hooks)
            network = NetworkManager(receivedFilesDirectory: root)
            generation = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS).generation
            manager = DataTransferManager(generation: generation, directory: root, receivedLibrary: library) { [weak self] p, done in
                guard let self else { done(false); return }
                self.lock.lock(); self.sent.append(p); self.lock.unlock(); done(true)
            }
            network.configureTransferAuthorizationForTesting(manager: manager, authenticated: true, committed: true, usb: usb)
        }
        var packets: [TransferPacket] { lock.lock(); defer { lock.unlock() }; return sent }
        func responses(_ id: UUID) -> [TransferPacket] { packets.filter { $0.id == id && $0.kind == .response } }
    }
    private func ux02AssertEnabled(_ f: UX02Session, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let enabled = await MainActor.run { f.network.autoAcceptIncomingFiles }
        XCTAssertEqual(enabled, expected, file: file, line: line)
    }
    private func ux02Toggle(_ f: UX02Session, _ enabled: Bool) async {
        f.network.setAutoAcceptIncomingFiles(enabled)
        f.network.networkQueueForTesting.sync { }
        await MainActor.run { }
        await ux03Barrier(f.manager)
    }
    private func ux02Finish(_ f: UX02Session) async {
        f.network.stopForTesting(); f.manager.retire(); await ux03Barrier(f.manager)
        try? FileManager.default.removeItem(at: f.root)
    }
    private func ux02Offer(_ f: UX02Session, id: UUID, name: String = "received.bin", length: UInt64 = 0) async {
        await ux03Post(TransferPacket(kind: .offer, generation: 7, id: id,
                       files: [TransferFile(name: name, length: length)]), to: f.manager)
    }
    private func ux02Complete(_ f: UX02Session, id: UUID, bytes: Data = Data(), digest: Data? = nil) async {
        guard f.responses(id).contains(where: { $0.accepted }) else { return }
        if !bytes.isEmpty {
            var p = TransferPacket(kind: .chunk, generation: 7, id: id); p.bytes = bytes
            await ux03Post(p, to: f.manager)
        }
        var end = TransferPacket(kind: .fileEnd, generation: 7, id: id)
        end.offset = UInt64(bytes.count); end.bytes = digest ?? Data(SHA256.hash(data: bytes))
        await ux03Post(end, to: f.manager)
        await ux03Post(TransferPacket(kind: .end, generation: 7, id: id), to: f.manager)
        await ux03Barrier(f.manager)
    }

    func testUX02AutoAcceptDefaultsOffAndRequiresManualConsent() async throws {
        for usb in [false, true] {
            let f = try UX02Session(usb: usb), id = UUID()
            await ux03Barrier(f.manager)
            await ux02AssertEnabled(f, false)
            await ux02Offer(f, id: id)
            XCTAssertTrue(f.responses(id).isEmpty, "No passive approval without an opt-in")
            f.manager.decide(false); await ux03Barrier(f.manager); await ux03Barrier(f.manager)
            XCTAssertEqual(f.responses(id).count, 1); XCTAssertFalse(f.responses(id).first?.accepted ?? true)
            let next = UUID(); await ux02Offer(f, id: next)
            f.manager.decide(true); await ux03Barrier(f.manager)
            XCTAssertEqual(f.responses(next).filter(\.accepted).count, 1)
            await ux02Complete(f, id: next); XCTAssertEqual(try f.library.snapshot().eligibleCount, 1)
            await ux02Finish(f)
        }
    }
    func testUX02AuthenticatedWifiAutoAcceptsTwoSequentialBatchesExactlyOnce() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        for value in [UInt8(1), 2] {
            let id = UUID(); await ux02Offer(f, id: id, name: "same.bin", length: 1)
            XCTAssertEqual(f.responses(id).filter(\.accepted).count, 1, "ON must use real admission exactly once")
            await ux02Complete(f, id: id, bytes: Data([value]))
            XCTAssertEqual(f.packets.filter { $0.id == id && $0.kind == .fileAck && $0.reason == .ok }.count, 1)
        }
        XCTAssertEqual(try f.library.snapshot().eligibleCount, 2)
        XCTAssertEqual(try f.library.snapshot().eligibleBytes, 2)
        await ux02Finish(f)
    }
    func testUX02AuthenticatedUsbAutoAcceptsOnlyAfterCommit() async throws {
        for auth in [false, true] {
            for commit in [false, true] {
                let f = try UX02Session(usb: true)
                f.network.configureTransferAuthorizationForTesting(manager: f.manager, authenticated: auth, committed: commit, usb: true)
                await ux02Toggle(f, true)
                let enabled = await MainActor.run { f.network.autoAcceptIncomingFiles }
                XCTAssertEqual(enabled, auth && commit)
                let id = UUID(); await ux02Offer(f, id: id)
                XCTAssertEqual(f.responses(id).filter(\.accepted).count, auth && commit ? 1 : 0)
                await ux02Finish(f)
            }
        }
    }
    func testUX02TurningOnWithPendingOfferDoesNotAutoAcceptOldOffer() async throws {
        let f = try UX02Session(), id = UUID(); await ux02Offer(f, id: id)
        await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        XCTAssertTrue(f.responses(id).isEmpty)
        f.manager.decide(true); f.manager.decide(true); await ux03Barrier(f.manager)
        XCTAssertEqual(f.responses(id).filter(\.accepted).count, 1)
        await ux02Complete(f, id: id); await ux02Finish(f)
    }
    func testUX02TurningOffBeforeQueuedOfferDecisionFencesAutoResponse() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        let entered = expectation(description: "offer owns IO boundary"), release = DispatchSemaphore(value: 0)
        f.manager.changed = { s in
            if s.phase == .awaitingDecision { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }
        let done = expectation(description: "offer finished"), id = UUID()
        XCTAssertTrue(f.manager.post(TransferPacket(kind: .offer, generation: 7, id: id,
                      files: [TransferFile(name: "queued.bin", length: 0)])) { done.fulfill() })
        await fulfillment(of: [entered], timeout: 3)
        f.network.setAutoAcceptIncomingFiles(false); f.network.networkQueueForTesting.sync { }
        release.signal(); await fulfillment(of: [done], timeout: 3); await ux03Barrier(f.manager)
        XCTAssertTrue(f.responses(id).isEmpty, "OFF invalidates a captured queued authorization")
        await ux02Finish(f)
    }
    func testUX02DisconnectAndReconnectResetToOff() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        f.network.stopForTesting(); f.network.networkQueueForTesting.sync { }; await MainActor.run { }
        await ux02AssertEnabled(f, false)
        _ = f.network.simulateCommittedWifiSessionForTesting(); await MainActor.run { }
        await ux02AssertEnabled(f, false)
        await ux02Finish(f)
    }
    func testUX02UsbWifiTransportHandoverResetsToOff() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        f.network.configureTransferAuthorizationForTesting(manager: f.manager, authenticated: true, committed: true, usb: true)
        await MainActor.run { }; await ux03Barrier(f.manager)
        await ux02AssertEnabled(f, false)
        let id = UUID(); await ux02Offer(f, id: id); XCTAssertTrue(f.responses(id).isEmpty)
        await ux02Toggle(f, true); await ux02AssertEnabled(f, true)
        XCTAssertTrue(f.responses(id).isEmpty, "Handover requires a fresh opt-in and old offers stay manual")
        await ux02Finish(f)
    }
    func testUX02AppRelaunchHasNoPersistedAutoAcceptFlag() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        // Reopening the presentation uses the same NetworkManager and must retain ON.
        f.network.refreshReceivedFiles(); f.network.networkQueueForTesting.sync { }; await MainActor.run { }
        await ux02AssertEnabled(f, true)
        let fresh = NetworkManager(receivedFilesDirectory: f.root)
        let freshEnabled = await MainActor.run { fresh.autoAcceptIncomingFiles }; XCTAssertFalse(freshEnabled)
        fresh.stopForTesting(); await ux02Finish(f)
    }
    func testUX02StaleCancelAndWrongPeerGenerationCannotPurgeCurrentBatch() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        let id = UUID(); await ux02Offer(f, id: id)
        XCTAssertEqual(f.responses(id).filter(\.accepted).count, 1)
        await ux03Post(TransferPacket(kind: .cancel, generation: 999, id: id), to: f.manager)
        await ux03Post(TransferPacket(kind: .cancel, generation: 7, id: UUID()), to: f.manager)
        await ux02Complete(f, id: id)
        XCTAssertEqual(try f.library.snapshot().eligibleCount, 1)
        await ux02Finish(f)
    }
    func testUX02AutoAcceptInvalidMetadataAndNoQuotaCannotBypassAdmission() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        let invalid = UUID(); await ux02Offer(f, id: invalid, name: "../escape")
        XCTAssertTrue(f.responses(invalid).isEmpty)
        for n in 0..<256 { try Data().write(to: f.root.appendingPathComponent("legacy-\(n)")) }
        let id = UUID(); await ux02Offer(f, id: id)
        XCTAssertEqual(f.responses(id).filter(\.accepted).count, 0)
        XCTAssertEqual(f.packets.filter { $0.kind == .cancel && $0.id == id }.count, 1,
                       "ON must actually attempt existing quota admission and fail closed")
        XCTAssertEqual(try f.library.snapshot().retainedCount, 256)
        await ux02Finish(f)
    }
    func testUX02AutoAcceptDigestOrReceiptErrorCannotProduceSuccessAck() async throws {
        for receiptFailure in [false, true] {
            var hooks = ReceivedFileLibrary.Hooks()
            if receiptFailure { hooks.beforeReceiptCommit = { throw CocoaError(.fileWriteOutOfSpace) } }
            let f = try UX02Session(hooks: hooks); await ux02Toggle(f, true)
            let id = UUID(); await ux02Offer(f, id: id, length: 1)
            XCTAssertEqual(f.responses(id).filter(\.accepted).count, 1)
            await ux02Complete(f, id: id, bytes: Data([1]), digest: receiptFailure ? nil : Data(repeating: 0, count: 32))
            XCTAssertEqual(f.packets.filter { $0.kind == .fileAck && $0.reason == .ok }.count, 0)
            XCTAssertEqual(try f.library.snapshot().eligibleCount, 0)
            XCTAssertEqual(try f.library.snapshot().retainedCount, receiptFailure ? 1 : 0)
            await ux02Finish(f)
        }
    }
    func testUX02OutboundIpadtoPCIgnoresInboundAutoAcceptSetting() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        let url = f.root.appendingPathComponent("outgoing.bin"); try Data([9]).write(to: url)
        f.manager.sendFiles([url]); await ux03Barrier(f.manager)
        XCTAssertEqual(f.packets.filter { $0.kind == .offer }.count, 1)
        XCTAssertEqual(f.packets.filter { $0.kind == .response }.count, 0)
        XCTAssertEqual(try f.library.snapshot().eligibleCount, 0)
        await ux02Finish(f)
    }
    func testUX02AuthenticationRevocationAndStaleEnableCannotCarryPolicy() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        await ux02AssertEnabled(f, true)
        f.network.configureTransferAuthorizationForTesting(manager: f.manager, authenticated: false, committed: true)
        await ux02Toggle(f, true)
        await ux02AssertEnabled(f, false)
        let id = UUID(); await ux02Offer(f, id: id); XCTAssertTrue(f.responses(id).isEmpty)
        await ux02Finish(f)
    }
    func testUX02ConcurrentManualDecisionAndDuplicateOfferNeverDoubleAdmit() async throws {
        let f = try UX02Session(); await ux02Toggle(f, true)
        let id = UUID(); await ux02Offer(f, id: id)
        f.manager.decide(true); f.manager.decide(false); await ux03Barrier(f.manager)
        XCTAssertEqual(f.responses(id).count, 1)
        let other = UUID(); await ux02Offer(f, id: other)
        XCTAssertEqual(f.responses(other).count, 1); XCTAssertEqual(f.responses(other).first?.reason, .busy)
        await ux02Complete(f, id: id); XCTAssertEqual(try f.library.snapshot().eligibleCount, 1)
        await ux02Finish(f)
    }

    func testUX03RetainedQuotaBoundariesWithoutLargeDiskFixtures() throws {
        let limit: UInt64 = 8 * 1024 * 1024 * 1024, reserve: Int64 = 64 * 1024 * 1024
        XCTAssertNoThrow(try DataTransferManager.validateRetainedQuota(count: 255, bytes: limit - 1,
                         incomingCount: 1, incomingBytes: 1, availableCapacity: reserve + 1))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 256, bytes: 0,
                             incomingCount: 1, incomingBytes: 0, availableCapacity: nil))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: limit,
                             incomingCount: 1, incomingBytes: 1, availableCapacity: nil))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: UInt64.max,
                             incomingCount: 1, incomingBytes: UInt64.max, availableCapacity: nil))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: 0,
                             incomingCount: 1, incomingBytes: UInt64.max, availableCapacity: nil))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: 0,
                             incomingCount: 1, incomingBytes: 1, availableCapacity: reserve))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: 0,
                             incomingCount: 1, incomingBytes: 0, availableCapacity: -1))
    }


    // C2 v3.3 G1: packet-boundary integration tests; existing runtime API only.
    private final class UX03Receiver {
        let library: ReceivedFileLibrary
        var manager: DataTransferManager!
        private let lock = NSLock()
        private var sent: [TransferPacket] = []
        private var state = DataTransferManager.Snapshot()
        var atSend: ((TransferPacket) -> Void)?
        init(root: URL, library: ReceivedFileLibrary) {
            self.library = library
            manager = DataTransferManager(generation: 11, directory: root) { [weak self] packet, done in
                guard let self else { done(false); return }
                self.lock.lock(); self.sent.append(packet); self.lock.unlock()
                self.atSend?(packet); done(true)
            }
            manager.changed = { [weak self] value in
                guard let self else { return }
                self.lock.lock(); self.state = value; self.lock.unlock()
            }
        }
        var packets: [TransferPacket] { lock.lock(); defer { lock.unlock() }; return sent }
        var snapshot: DataTransferManager.Snapshot { lock.lock(); defer { lock.unlock() }; return state }
    }
    private func ux03Post(_ packet: TransferPacket, to manager: DataTransferManager) async {
        let processed = expectation(description: "exact packet processed")
        XCTAssertTrue(manager.post(packet) { processed.fulfill() })
        await fulfillment(of: [processed], timeout: 3)
    }
    private func ux03Barrier(_ manager: DataTransferManager) async {
        // Foreign CANCEL is inert; its completion fences earlier IO work.
        await ux03Post(TransferPacket(kind: .cancel, generation: 999, id: UUID()), to: manager)
    }
    private func ux03Offer(_ files: [TransferFile], id: UUID, receiver: UX03Receiver) async {
        await ux03Post(TransferPacket(kind: .offer, generation: 7, id: id, files: files), to: receiver.manager)
        receiver.manager.decide(true); await ux03Barrier(receiver.manager)
    }
    private func ux03File(_ bytes: Data, index: UInt16, id: UUID, receiver: UX03Receiver, digest: Data? = nil) async {
        if !bytes.isEmpty {
            var chunk = TransferPacket(kind: .chunk, generation: 7, id: id)
            chunk.fileIndex = index; chunk.bytes = bytes
            await ux03Post(chunk, to: receiver.manager)
        }
        var end = TransferPacket(kind: .fileEnd, generation: 7, id: id)
        end.fileIndex = index; end.offset = UInt64(bytes.count); end.bytes = digest ?? Data(SHA256.hash(data: bytes))
        await ux03Post(end, to: receiver.manager)
    }

    func testUX03FileAckOccursOnlyAfterReceiptIsDurablyReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), name = "\u{0111}\u{1EB9}p.bin", id = UUID()
        try Data([9]).write(to: root.appendingPathComponent(name))
        let receiver = UX03Receiver(root: root, library: library)
        receiver.atSend = { packet in
            guard packet.kind == .fileAck && packet.reason == .ok else { return }
            XCTAssertEqual(packet.id, id); XCTAssertEqual(packet.generation, 7)
            do {
                XCTAssertEqual(try ReceivedFileLibrary(directory: root).snapshot().eligibleCount, Int(packet.fileIndex) + 1,
                               "FileAck requires durable receipt visibility at send time")
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(ReceivedFileLibrary.metadataName).appendingPathComponent("receipts.json").path))
            } catch { XCTFail("Receipt not readable before FileAck: \(error)") }
        }
        await ux03Offer([TransferFile(name: "empty.bin", length: 0), TransferFile(name: name, length: 2)], id: id, receiver: receiver)
        await ux03File(Data(), index: 0, id: id, receiver: receiver)
        await ux03File(Data([1, 2]), index: 1, id: id, receiver: receiver)
        await ux03Post(TransferPacket(kind: .end, generation: 7, id: id), to: receiver.manager); await ux03Barrier(receiver.manager)
        XCTAssertEqual(receiver.packets.filter { $0.kind == .fileAck && $0.reason == .ok }.map(\.fileIndex), [0, 1])
        XCTAssertEqual(receiver.snapshot.phase, .completed)
        let inventory = try library.snapshot()
        XCTAssertEqual(inventory.retainedCount, 3); XCTAssertEqual(inventory.retainedBytes, 3)
        XCTAssertEqual(inventory.eligibleCount, 2); XCTAssertEqual(inventory.eligibleBytes, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\u{0111}\u{1EB9}p (1).bin")), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data([9]))
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03ReceiptCommitFailureSendsNoSuccessfulFileAckAndKeepsLegacyCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var hooks = ReceivedFileLibrary.Hooks(); hooks.beforeReceiptCommit = { throw CocoaError(.fileWriteOutOfSpace) }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks), id = UUID()
        let receiver = UX03Receiver(root: root, library: library)
        await ux03Offer([TransferFile(name: "retained.bin", length: 2)], id: id, receiver: receiver)
        await ux03File(Data([3, 4]), index: 0, id: id, receiver: receiver)
        XCTAssertEqual(receiver.packets.filter { $0.kind == .fileAck && $0.reason == .ok }.count, 0)
        XCTAssertEqual(receiver.snapshot.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("retained.bin")), Data([3, 4]))
        let inventory = try library.snapshot()
        XCTAssertEqual(inventory.retainedCount, 1); XCTAssertEqual(inventory.retainedBytes, 2)
        XCTAssertEqual(inventory.eligibleCount, 0); XCTAssertFalse(inventory.busy)
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03QuotaIgnoresReceiptMetadataButCountsLegacyBytesAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), id = UUID()
        for index in 0..<255 { try Data([1]).write(to: root.appendingPathComponent("legacy-\(index)")) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: nested)
        let receiver = UX03Receiver(root: root, library: library)
        await ux03Offer([TransferFile(name: "last.bin", length: 1)], id: id, receiver: receiver)
        XCTAssertEqual(receiver.snapshot.phase, .receiving, "Internal metadata, directories and symlinks are not file slots")
        await ux03File(Data([2]), index: 0, id: id, receiver: receiver)
        await ux03Post(TransferPacket(kind: .end, generation: 7, id: id), to: receiver.manager); await ux03Barrier(receiver.manager)
        XCTAssertEqual(try library.snapshot().retainedCount, 256); XCTAssertEqual(try library.snapshot().retainedBytes, 256)
        XCTAssertEqual(try library.snapshot().eligibleCount, 1)
        await ux03Offer([TransferFile(name: "overflow.bin", length: 0)], id: UUID(), receiver: receiver)
        XCTAssertEqual(receiver.snapshot.phase, .failed)
        XCTAssertEqual(receiver.packets.filter { $0.kind == .response && $0.accepted }.count, 1)
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03TransferLeaseBlocksClearAndForeignOwnerCannotRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), id = UUID()
        let receiver = UX03Receiver(root: root, library: library)
        await ux03Post(TransferPacket(kind: .offer, generation: 7, id: id, files: [TransferFile(name: "x", length: 1)]), to: receiver.manager)
        XCTAssertEqual(receiver.snapshot.phase, .awaitingDecision); XCTAssertTrue(try library.snapshot().busy)
        XCTAssertThrowsError(try library.confirmClear(), "Pending consent must fence Clear")
        let foreign = UUID(); XCTAssertFalse(library.beginTransfer(owner: foreign)); library.endTransfer(owner: foreign)
        XCTAssertThrowsError(try library.confirmClear())
        receiver.manager.decide(true); await ux03Barrier(receiver.manager); XCTAssertThrowsError(try library.confirmClear())
        receiver.manager.cancel(); await ux03Barrier(receiver.manager)
        XCTAssertFalse(try library.snapshot().busy); XCTAssertEqual(try library.confirmClear().count, 0)
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03RetireDuringReceivingReleasesLeaseAfterStageClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), id = UUID()
        let receiver = UX03Receiver(root: root, library: library)
        await ux03Offer([TransferFile(name: "x", length: 2)], id: id, receiver: receiver)
        var chunk = TransferPacket(kind: .chunk, generation: 7, id: id); chunk.bytes = Data([1])
        await ux03Post(chunk, to: receiver.manager); XCTAssertTrue(try library.snapshot().busy)
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
        XCTAssertFalse(try library.snapshot().busy); XCTAssertEqual(try library.confirmClear().count, 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { $0.pathExtension == "part" })
        XCTAssertEqual(receiver.packets.filter { $0.kind == .fileAck }.count, 0)
    }

    func testUX03NewManagerCannotClearDuringPreviousManagerRetirement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), id = UUID()
        let first = UX03Receiver(root: root, library: library)
        await ux03Offer([TransferFile(name: "first", length: 1)], id: id, receiver: first)
        let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "part" }
        XCTAssertEqual(stages.count, 1)
        let second = UX03Receiver(root: root, library: library); await ux03Barrier(second.manager)
        XCTAssertTrue(stages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "New initialization cannot unlink another owner's stage")
        XCTAssertThrowsError(try library.confirmClear())
        first.manager.retire(); await ux03Barrier(first.manager)
        await ux03Post(TransferPacket(kind: .offer, generation: 8, id: UUID(), files: [TransferFile(name: "next", length: 0)]), to: second.manager)
        XCTAssertEqual(second.snapshot.phase, .awaitingDecision)
        first.manager.retire(); await ux03Barrier(first.manager)
        XCTAssertThrowsError(try library.confirmClear(), "Stale retirement cannot release the successor")
        second.manager.decide(false); await ux03Barrier(second.manager); await ux03Barrier(second.manager)
        XCTAssertFalse(try library.snapshot().busy)
        second.manager.retire(); await ux03Barrier(second.manager)
    }

    func testUX03TwoFileBatchPreservesEarlierReceiptsWhenLaterReceiptFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var commits = 0; var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeReceiptCommit = { commits += 1; if commits == 2 { throw CocoaError(.fileWriteNoPermission) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks), id = UUID()
        let receiver = UX03Receiver(root: root, library: library)
        await ux03Offer([TransferFile(name: "first", length: 1), TransferFile(name: "later", length: 2)], id: id, receiver: receiver)
        await ux03File(Data([1]), index: 0, id: id, receiver: receiver)
        await ux03File(Data([2, 3]), index: 1, id: id, receiver: receiver)
        XCTAssertEqual(receiver.packets.filter { $0.kind == .fileAck && $0.reason == .ok }.map(\.fileIndex), [0])
        XCTAssertEqual(receiver.snapshot.phase, .failed); XCTAssertEqual(receiver.snapshot.published, 1)
        let inventory = try library.snapshot()
        XCTAssertEqual(inventory.retainedCount, 2); XCTAssertEqual(inventory.retainedBytes, 3)
        XCTAssertEqual(inventory.eligibleCount, 1); XCTAssertEqual(inventory.eligibleBytes, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("later")), Data([2, 3]))
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03OutgoingTransferDoesNotCreateInboundReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("retained"), source = root.appendingPathComponent("source.bin")
        let library = try ReceivedFileLibrary(directory: directory); try Data([4]).write(to: source)
        let receiver = UX03Receiver(root: directory, library: library)
        receiver.manager.sendFiles([source]); await ux03Barrier(receiver.manager)
        XCTAssertEqual(receiver.snapshot.phase, .offering); XCTAssertTrue(try library.snapshot().busy)
        XCTAssertThrowsError(try library.confirmClear())
        let offer = try XCTUnwrap(receiver.packets.first { $0.kind == .offer })
        var rejected = TransferPacket(kind: .response, generation: offer.generation, id: offer.id); rejected.reason = .userRejected
        await ux03Post(rejected, to: receiver.manager)
        XCTAssertFalse(try library.snapshot().busy); XCTAssertEqual(try library.snapshot().eligibleCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data([4]))
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03DigestFailureAndCorruptJournalNeverProduceSuccessfulFileAck() async throws {
        for corrupt in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let library = try ReceivedFileLibrary(directory: root), id = UUID()
            if corrupt { try Data("torn{".utf8).write(to: root.appendingPathComponent(ReceivedFileLibrary.metadataName).appendingPathComponent("receipts.json")) }
            let receiver = UX03Receiver(root: root, library: library)
            await ux03Offer([TransferFile(name: "x", length: 1)], id: id, receiver: receiver)
            await ux03File(Data([1]), index: 0, id: id, receiver: receiver, digest: corrupt ? nil : Data(count: 32))
            XCTAssertEqual(receiver.packets.filter { $0.kind == .fileAck && $0.reason == .ok }.count, 0)
            XCTAssertEqual(receiver.snapshot.phase, .failed); XCTAssertEqual(try library.snapshot().eligibleCount, 0)
            XCTAssertEqual(try library.snapshot().retainedCount, corrupt ? 1 : 0); XCTAssertFalse(try library.snapshot().busy)
            receiver.manager.retire(); await ux03Barrier(receiver.manager)
        }
    }

    func testUX03ActiveExportCannotLoseItsLeaseToIncomingOffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), source = root.appendingPathComponent("legacy.bin"), id = UUID()
        try Data([1]).write(to: source)
        let token = try library.beginExport(source), receiver = UX03Receiver(root: root, library: library)
        await ux03Post(TransferPacket(kind: .offer, generation: 7, id: id, files: [TransferFile(name: "x", length: 1)]), to: receiver.manager)
        XCTAssertFalse(receiver.manager.owns(TransferPacket(kind: .cancel, generation: 7, id: id)))
        XCTAssertEqual(receiver.packets.filter { $0.kind == .response && $0.reason == .busy }.count, 1)
        XCTAssertThrowsError(try library.confirmClear())
        library.endExport(token); XCTAssertFalse(try library.snapshot().busy)
        receiver.manager.retire(); await ux03Barrier(receiver.manager)
    }

    func testUX03LegacyFilesRemainVisibleAndAreClearableAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.bin")
        let metadata = root.appendingPathComponent("unknown.json")
        try Data([1, 2, 3]).write(to: legacy)
        try Data("{}".utf8).write(to: metadata)
        let library = try ReceivedFileLibrary(directory: root)
        let inventory = try library.snapshot()
        XCTAssertEqual(inventory.retainedCount, 2)
        XCTAssertEqual(inventory.retainedBytes, 5)
        XCTAssertEqual(inventory.eligibleCount, 0)
        let confirmation = try library.confirmClear()
        XCTAssertEqual(confirmation.count, 2); XCTAssertEqual(confirmation.bytes, 5)
        let result = try library.clear(confirmation)
        XCTAssertEqual(result.deletedCount, 2); XCTAssertEqual(result.deletedBytes, 5); XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertEqual(try ReceivedFileLibrary(directory: root).snapshot().retainedCount, 0)
    }

    func testUX03ReceiptBackedClearDeletesActualCopiesAndPreservesExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = root.appendingPathComponent("retained")
        let exported = root.appendingPathComponent("exported.bin")
        let library = try ReceivedFileLibrary(directory: retained)
        let fixtures: [(String, Data)] = [("empty.bin", Data()), ("received.bin", Data(repeating: 7, count: 1024)),
                                           ("received (1).bin", Data([8]))]
        for (name, bytes) in fixtures {
            let url = retained.appendingPathComponent(name)
            try bytes.write(to: url)
            try library.recordPublished(url, length: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
        }
        try FileManager.default.copyItem(at: retained.appendingPathComponent("received.bin"), to: exported)
        let confirmation = try library.confirmClear()
        XCTAssertEqual(confirmation.count, 3)
        XCTAssertEqual(confirmation.bytes, 1025)
        let result = try library.clear(confirmation)
        XCTAssertEqual(result.deletedCount, 3)
        XCTAssertEqual(result.failedCount, 0)
        for (name, _) in fixtures { XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appendingPathComponent(name).path)) }
        XCTAssertEqual(try Data(contentsOf: exported), Data(repeating: 7, count: 1024))
        let reopened = try ReceivedFileLibrary(directory: retained).snapshot()
        XCTAssertEqual(reopened.retainedCount, 0)
        XCTAssertEqual(reopened.retainedBytes, 0)
        XCTAssertThrowsError(try library.clear(confirmation), "A consumed confirmation cannot authorize another deletion")
    }

    func testUX03ConfirmationDoesNotDeleteLaterPublishedFileOrSubstitutedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root)
        let first = root.appendingPathComponent("first.bin"), later = root.appendingPathComponent("later.bin")
        try Data([1]).write(to: first)
        try library.recordPublished(first, length: 1, digest: Data(SHA256.hash(data: Data([1]))))
        let confirmation = try library.confirmClear()
        // Atomic replacement guarantees a new file identity, even for equal content.
        try Data([1]).write(to: first, options: .atomic)
        try Data([2]).write(to: later)
        try library.recordPublished(later, length: 1, digest: Data(SHA256.hash(data: Data([2]))))
        let result = try library.clear(confirmation)
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: later), Data([2]))
        XCTAssertEqual(try library.snapshot().retainedCount, 2)
    }

    func testUX03ClearRefusesActiveTransferOrExportWithoutChangingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root)
        let file = root.appendingPathComponent("received.bin")
        try Data([9]).write(to: file)
        try library.recordPublished(file, length: 1, digest: Data(SHA256.hash(data: Data([9]))))
        let transfer = UUID()
        XCTAssertTrue(library.beginTransfer(owner: transfer))
        XCTAssertFalse(library.beginTransfer(owner: UUID()))
        XCTAssertThrowsError(try library.confirmClear())
        library.endTransfer(owner: UUID())
        XCTAssertThrowsError(try library.confirmClear(), "A foreign owner cannot release the active lease")
        library.endTransfer(owner: transfer)
        let confirmation = try library.confirmClear()
        let export = try library.beginExport(file)
        XCTAssertThrowsError(try library.clear(confirmation))
        XCTAssertEqual(try Data(contentsOf: file), Data([9]))
        library.endExport(export)
        XCTAssertEqual(try library.clear(library.confirmClear()).deletedCount, 1)
    }

    func testUX03MixedClearDeletesVerifiedAndLegacyButProtectsStageSymlinkNestedAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = root.appendingPathComponent("retained"), external = root.appendingPathComponent("external.bin")
        let library = try ReceivedFileLibrary(directory: retained)
        try Data([4]).write(to: external)
        let link = retained.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let stage = retained.appendingPathComponent(".scdt-test.part")
        try Data([5]).write(to: stage)
        let nested = retained.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([6]).write(to: nested.appendingPathComponent("file.bin"))
        let verified = retained.appendingPathComponent("verified.bin"), legacy = retained.appendingPathComponent("legacy.bin")
        try Data([1, 2]).write(to: verified); try Data([3]).write(to: legacy)
        try library.recordPublished(verified, length: 2, digest: Data(SHA256.hash(data: Data([1, 2]))))
        let exported = root.appendingPathComponent("exported.bin")
        try FileManager.default.copyItem(at: verified, to: exported)
        let digest = Data(SHA256.hash(data: Data([4])))
        XCTAssertThrowsError(try library.recordPublished(external, length: 1, digest: digest))
        XCTAssertThrowsError(try library.recordPublished(link, length: 1, digest: digest))
        XCTAssertThrowsError(try library.recordPublished(stage, length: 1, digest: Data(SHA256.hash(data: Data([5])))))
        let confirmation = try library.confirmClear()
        XCTAssertEqual(confirmation.count, 2); XCTAssertEqual(confirmation.bytes, 3)
        let result = try library.clear(confirmation)
        XCTAssertEqual(result.deletedCount, 2); XCTAssertEqual(result.deletedBytes, 3); XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(try library.snapshot().retainedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verified.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: exported), Data([1, 2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertThrowsError(try library.clear(confirmation))
        XCTAssertEqual(try Data(contentsOf: external), Data([4]))
        XCTAssertEqual(try Data(contentsOf: stage), Data([5]))
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("file.bin")), Data([6]))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: retained)
        XCTAssertThrowsError(try ReceivedFileLibrary(directory: alias))
    }

    func testUX03MismatchedDigestRemainsUnverifiedButAppOwnedFileCanClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root)
        let file = root.appendingPathComponent("unverified.bin")
        try Data([3]).write(to: file)
        XCTAssertThrowsError(try library.recordPublished(file, length: 1, digest: Data(count: 32)))
        XCTAssertEqual(try library.snapshot().eligibleCount, 0)
        XCTAssertEqual(try library.clear(library.confirmClear()).deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUX03LegacyConfirmationRejectsReplacementAndRevalidatesImmediatelyBeforeUnlink() throws {
        for replaceAtUnlink in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var hooks = ReceivedFileLibrary.Hooks()
            if replaceAtUnlink {
                hooks.beforeUnlink = { name in try Data([9]).write(to: root.appendingPathComponent(name), options: .atomic) }
            }
            let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
            let file = root.appendingPathComponent("legacy.bin"); try Data([1]).write(to: file)
            let confirmation = try library.confirmClear(); XCTAssertEqual(confirmation.count, 1)
            if !replaceAtUnlink { try Data([9]).write(to: file, options: .atomic) }
            let result = try library.clear(confirmation)
            XCTAssertEqual(result.deletedCount, 0); XCTAssertEqual(result.failedCount, 1); XCTAssertEqual(result.deletedBytes, 0)
            XCTAssertEqual(try Data(contentsOf: file), Data([9]))
            XCTAssertThrowsError(try library.clear(confirmation))
        }
    }

    func testUX03PartialUnlinkFailureReportsRealBytesAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = true
        var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeUnlink = { name in if name == "blocked.bin" && fail { throw CocoaError(.fileWriteNoPermission) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        for name in ["good.bin", "blocked.bin"] {
            let url = root.appendingPathComponent(name)
            try Data([1, 2]).write(to: url)
            try library.recordPublished(url, length: 2, digest: Data(SHA256.hash(data: Data([1, 2]))))
        }
        let result = try library.clear(library.confirmClear())
        XCTAssertEqual(result.deletedCount, 1); XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.deletedBytes, 2)
        XCTAssertEqual(try library.snapshot().retainedBytes, 2)
        fail = false
        XCTAssertEqual(try library.clear(library.confirmClear()).deletedCount, 1)
        XCTAssertEqual(try library.snapshot().retainedCount, 0)
    }

    func testUX03ReopenPreservesReceiptAndConsumesConfirmationDurably() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var confirmation: ReceivedFileLibrary.Confirmation!
        do {
            let library = try ReceivedFileLibrary(directory: root)
            let url = root.appendingPathComponent("verified.bin")
            try Data([5]).write(to: url)
            try library.recordPublished(url, length: 1, digest: Data(SHA256.hash(data: Data([5]))))
            confirmation = try library.confirmClear()
        }
        let reopened = try ReceivedFileLibrary(directory: root)
        XCTAssertEqual(try reopened.snapshot().eligibleCount, 1)
        XCTAssertEqual(try reopened.clear(confirmation).deletedCount, 1)
        XCTAssertThrowsError(try reopened.clear(confirmation))
    }

    func testUX03CorruptAndUnsupportedReceiptsNeverAdoptLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root)
        let url = root.appendingPathComponent("legacy.bin")
        try Data([1]).write(to: url)
        let metadata = root.appendingPathComponent(ReceivedFileLibrary.metadataName).appendingPathComponent("receipts.json")
        for bytes in [Data("torn{".utf8), Data("{\"version\":999}".utf8)] {
            try bytes.write(to: metadata, options: .atomic)
            XCTAssertEqual(try library.snapshot().retainedCount, 1)
            XCTAssertEqual(try library.snapshot().retainedBytes, 1)
            XCTAssertEqual(try library.snapshot().eligibleCount, 0)
            XCTAssertThrowsError(try library.confirmClear())
            XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        }
    }

    func testUX03SharedLibraryLeasesFenceWrongOwnersAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ReceivedFileLibrary(directory: root), second = try ReceivedFileLibrary(directory: root)
        let owner = UUID()
        XCTAssertTrue(first.beginTransfer(owner: owner))
        XCTAssertFalse(second.beginTransfer(owner: UUID()))
        second.endTransfer(owner: UUID())
        XCTAssertThrowsError(try second.confirmClear())
        first.endTransfer(owner: owner)
        let file = root.appendingPathComponent("legacy.bin"); try Data([1]).write(to: file)
        let export = try second.beginExport(file)
        first.endExport(UUID())
        XCTAssertThrowsError(try first.confirmClear())
        XCTAssertFalse(first.beginTransfer(owner: UUID()))
        second.endExport(export)
        XCTAssertEqual(try first.confirmClear().count, 1)
        XCTAssertEqual(try first.clear(first.confirmClear()).deletedCount, 1)
    }

    func testUX03HardlinkAndInPlaceMutationLoseEligibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root)
        let file = root.appendingPathComponent("owned.bin"), alias = root.appendingPathComponent("alias.bin")
        try Data([1]).write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)
        XCTAssertThrowsError(try library.recordPublished(file, length: 1, digest: Data(SHA256.hash(data: Data([1])))))
        try FileManager.default.removeItem(at: alias)
        try library.recordPublished(file, length: 1, digest: Data(SHA256.hash(data: Data([1]))))
        let confirmation = try library.confirmClear()
        let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: Data([2])); try handle.close()
        XCTAssertEqual(try library.clear(confirmation).failedCount, 1)
        XCTAssertEqual(try library.snapshot().eligibleCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data([2]))
    }

    func testUX03ReceiptCommitFailurePreservesPublishedBytesAsLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeReceiptCommit = { throw CocoaError(.fileWriteOutOfSpace) }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        let file = root.appendingPathComponent("retained.bin"); try Data([9]).write(to: file)
        XCTAssertThrowsError(try library.recordPublished(file, length: 1, digest: Data(SHA256.hash(data: Data([9])))))
        XCTAssertEqual(try library.snapshot().retainedCount, 1)
        XCTAssertEqual(try library.snapshot().eligibleCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data([9]))
    }

    func testF03AdmissionFailureRetainsStageAndSanitizedNativeError() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to:root)
        defer {try? FileManager.default.removeItem(at:root)}
        let offered=expectation(description:"offer"),failed=expectation(description:"native storage failure")
        let manager=DataTransferManager(generation:4,directory:root){_,done in done(true)}
        manager.changed={ value in
            if value.phase == .awaitingDecision {offered.fulfill()}
            if value.phase == .failed {
                XCTAssertFalse(value.outgoing);XCTAssertEqual(value.stage,"admission")
                XCTAssertNotNil(value.failure);XCTAssertFalse(String(describing:value.failure).contains(root.path))
                failed.fulfill()
            }
        }
        XCTAssertTrue(manager.post(TransferPacket(kind:.offer,generation:2,id:UUID(),files:[TransferFile(name:"private.pdf",length:1)])))
        await fulfillment(of:[offered],timeout:3);manager.decide(true)
        await fulfillment(of:[failed],timeout:3);manager.retire()
    }
    func testF03InvalidOffsetHasBoundedRedactedTraceAndNoPublishedFile() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let offered=expectation(description:"offer"),accepted=expectation(description:"accepted"),failed=expectation(description:"invalid offset")
        let id=UUID()
        let manager=DataTransferManager(generation:4,directory:root){_,done in done(true)}
        var lines:[String]=[]
        manager.diagnostic={lines.append($0)}
        manager.changed={ value in
            if value.phase == .awaitingDecision {offered.fulfill()}
            if value.phase == .receiving {accepted.fulfill()}
            if value.phase == .failed {
                XCTAssertEqual(value.failure?.reason,"INVALID_TRANSFER");XCTAssertEqual(value.stage,"write")
                XCTAssertTrue(value.received.isEmpty)
                XCTAssertFalse(lines.joined().contains("private.pdf"));XCTAssertFalse(lines.joined().contains(root.path))
                XCTAssertLessThan(lines.count,20);failed.fulfill()
            }
        }
        XCTAssertTrue(manager.post(TransferPacket(kind:.offer,generation:2,id:id,files:[TransferFile(name:"private.pdf",length:1)])))
        await fulfillment(of:[offered],timeout:3);manager.decide(true);await fulfillment(of:[accepted],timeout:3)
        var chunk=TransferPacket(kind:.chunk,generation:2,id:id);chunk.offset=1;chunk.bytes=Data([9])
        XCTAssertTrue(manager.post(chunk));await fulfillment(of:[failed],timeout:3);manager.retire()
    }
    func testF03SnapshotRetainsSanitizedFailureAndDirection() {
        let fields = Set(Mirror(reflecting: DataTransferManager.Snapshot()).children.compactMap(\.label))
        XCTAssertTrue(fields.contains("failure"), "Receive errors must not disappear behind Failed")
        XCTAssertTrue(fields.contains("outgoing"), "Terminal progress must retain transfer direction")
        XCTAssertTrue(fields.contains("stage"), "Retain the actual failed stage")
    }
    func testCanonicalEnvelopeAndAllTruncationPoints() throws {
        let id=UUID(uuidString:"00112233-4455-6677-8899-AABBCCDDEEFF")!
        let p=TransferPacket(kind:.end,generation:0x0807060504030201,id:id)
        let bytes=try TransferProtocol.encode(p)
        XCTAssertEqual(bytes.map{String(format:"%02X",$0)}.joined(),"01010203040506070800112233445566778899AABBCCDDEEFF")
        for cut in 0..<bytes.count {XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes.prefix(cut)))}
        XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes+Data([0])))
    }
    func testSharedGoldenWireVectors() throws {
        let vectors: [(UInt8,String)] = [
            (43, "01010203040506070800112233445566778899AABBCCDDEEFF0100030000000000000000000500612E7478740300000000000000"),
            (43, "01010203040506070800112233445566778899AABBCCDDEEFF0200030000000000000000000500612E747874030000000000000001000A00C491E1BAB9702E7478740000000000000000"),
            (44, "01010203040506070800112233445566778899AABBCCDDEEFF0100"),
            (44, "01010203040506070800112233445566778899AABBCCDDEEFF0001"),
            (45, "01010203040506070800112233445566778899AABBCCDDEEFF00000000000000000000000000000000000003000000010203"),
            (45, "01010203040506070800112233445566778899AABBCCDDEEFF000001000000000000000040000000000000020000000405"),
            (46, "01010203040506070800112233445566778899AABBCCDDEEFF00000000000000000000E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"),
            (46, "01010203040506070800112233445566778899AABBCCDDEEFF00000300000000000000039058C6F2C0CB492C533B0A4D14EF77CC0F78ABCCCED5287D84A1A2011CFB81"),
            (47, "01010203040506070800112233445566778899AABBCCDDEEFF000000"),
            (47, "01010203040506070800112233445566778899AABBCCDDEEFF00000A"),
            (48, "01010203040506070800112233445566778899AABBCCDDEEFF0E"),
            (49, "01010203040506070800112233445566778899AABBCCDDEEFF"),
            (50, "01010203040506070800112233445566778899AABBCCDDEEFF00")
        ]
        for (raw,hex) in vectors {
            var bytes=Data();var index=hex.startIndex
            while index<hex.endIndex {let next=hex.index(index,offsetBy:2);bytes.append(UInt8(hex[index..<next],radix:16)!);index=next}
            let kind=TransferKind(rawValue:raw)!,packet=try TransferProtocol.decode(kind,bytes)
            XCTAssertEqual(try TransferProtocol.encode(packet),bytes)
            XCTAssertEqual(packet.generation,0x0807060504030201)
            XCTAssertEqual(packet.id.uuidString,"00112233-4455-6677-8899-AABBCCDDEEFF")
        }
    }
    func testExistingParserEverySplitAndAdjacentInput() throws {
        let transfer=TransferPacket(kind:.chunk,generation:7,id:UUID(),bytes:Data([1,2,3]))
        let payload=try TransferProtocol.encode(transfer)
        func frame(_ type: WireMessageType,_ payload: Data) -> Data {
            var result=Data("SCST".utf8);result.append(contentsOf:[1,type.rawValue,0,0])
            var length=UInt32(payload.count).littleEndian,sequence=UInt32(1).littleEndian
            withUnsafeBytes(of:&length){result.append(contentsOf:$0)};withUnsafeBytes(of:&sequence){result.append(contentsOf:$0)};result.append(payload);return result
        }
        let encoded=frame(.transferChunk,payload)+frame(.pointerInput,Data(count:8))+frame(.ping,Data(count:16))
        for split in 0...encoded.count {
            let parser=WireStreamParser(generation:7);var types:[WireMessageType]=[]
            parser.consume(encoded.prefix(split),generation:7){if case .message(let m)=$0 {types.append(m.header.type)}}
            parser.consume(encoded.dropFirst(split),generation:7){if case .message(let m)=$0 {types.append(m.header.type)}}
            XCTAssertEqual(types,[.transferChunk,.pointerInput,.ping])
        }
    }
    func testMalformedBulkLengthNeverAllocatesPayload() {
        let parser=WireStreamParser(generation:7)
        var header=Data("SCST".utf8);header.append(contentsOf:[1,45,0,0]);var length=UInt32(TransferProtocol.maxPayloadBytes+1).littleEndian
        withUnsafeBytes(of:&length){header.append(contentsOf:$0)};header.append(Data(count:4))
        parser.consume(header,generation:7){_ in}
        XCTAssertEqual(parser.allocatedPayloadBytes,0)
    }
    func testUnsafeNamesAndBounds() throws {
        for name in ["",".","..","../x","/x","C:x","\\\\pc\\x","a/b","a\\b","NUL","CON.txt","COM1","LPT9.txt","x.","x ","a\0b",String(repeating:"a",count:256)] {XCTAssertFalse(TransferProtocol.validName(name))}
        XCTAssertTrue(TransferProtocol.validName("Ä‘áº¹p.txt"))
        XCTAssertEqual(TransferProtocol.defaultChunkBytes,16384);XCTAssertEqual(TransferProtocol.maxChunkBytes,65536)
        XCTAssertThrowsError(try TransferProtocol.validate([]))
    }
    func testPrivateStageIntegrityAndCleanup() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=try TransferStore(directory:directory,metadata:TransferFile(name:"x",length:1),id:UUID())
        try store.append(chunk:0,offset:0,bytes:Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("x").path))
        XCTAssertThrowsError(try store.publish(length:1,digest:Data(count:32)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty)
    }
    func testCancelDropsQueuedBulkButPreservesControl() async {
        let queue=DispatchQueue(label:"transfer-cancel-test"),done=expectation(description:"cancel boundary")
        var bytes:[UInt8]=[];var callbacks:[(NWError?)->Void]=[]
        let writer=ControlChannelWriter(queue:queue){data,_,callback in bytes.append(data[0]);callbacks.append(callback)}
        queue.async {
            writer.begin(generation:3);XCTAssertTrue(writer.enqueueBulk(Data([1])){_ in});XCTAssertTrue(writer.enqueueBulk(Data([2])){_ in});XCTAssertTrue(writer.enqueue(Data([9])))
            writer.cancelBulk();callbacks.removeFirst()(nil)
            queue.asyncAfter(deadline:.now()+0.02){XCTAssertEqual(bytes,[1,9]);callbacks.removeFirst()(nil);done.fulfill()}
        }
        await fulfillment(of:[done],timeout:2)
    }
    func testStoreBoundarySizesCollisionAndInvalidOffsets() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        for size in [0,1,15360,16384,16385,65536,65537,2*1024*1024] {
            let directory=root.appendingPathComponent(String(size)),bytes=Data(repeating:0x41,count:size)
            let store=try TransferStore(directory:directory,metadata:TransferFile(name:"Ä‘áº¹p.bin",length:UInt64(size)),id:UUID())
            var offset=0,chunk:UInt64=0
            while offset<size {let count=min(16384,size-offset);try store.append(chunk:chunk,offset:UInt64(offset),bytes:bytes.subdata(in:offset..<offset+count));offset+=count;chunk+=1}
            let final=try store.publish(length:UInt64(size),digest:Data(SHA256.hash(data:bytes)))
            XCTAssertEqual(try Data(contentsOf:final),bytes)
            let collision=try TransferStore(directory:directory,metadata:TransferFile(name:"Ä‘áº¹p.bin",length:0),id:UUID())
            XCTAssertNotEqual(try collision.publish(length:0,digest:Data(SHA256.hash(data:Data()))),final)
        }
        let store=try TransferStore(directory:root,metadata:TransferFile(name:"invalid",length:3),id:UUID())
        XCTAssertThrowsError(try store.append(chunk:1,offset:0,bytes:Data([1])))
        XCTAssertThrowsError(try store.append(chunk:0,offset:1,bytes:Data([1])))
        try store.append(chunk:0,offset:0,bytes:Data([1]))
        XCTAssertThrowsError(try store.append(chunk:0,offset:0,bytes:Data([1])))
        XCTAssertThrowsError(try store.publish(length:3,digest:Data(count:32)))
    }
    func testManagersSequentialBatchAndExplicitApproval() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.bin"),empty=root.appendingPathComponent("empty.bin")
        try Data(repeating:7,count:32769).write(to:source);try Data().write(to:empty)
        let completed=expectation(description:"batch ack"),approval=expectation(description:"explicit approval")
        var left:DataTransferManager!,right:DataTransferManager!
        left=DataTransferManager(generation:1,directory:root.appendingPathComponent("left")){packet,completion in
            if !right.post(packet,completion:{completion(true)}) {completion(false)}
        }
        right=DataTransferManager(generation:2,directory:root.appendingPathComponent("right")){packet,completion in
            if !left.post(packet,completion:{completion(true)}) {completion(false)}
        }
        right.changed={snapshot in if snapshot.phase == .awaitingDecision {approval.fulfill()}}
        left.changed={snapshot in if snapshot.phase == .completed {completed.fulfill()}}
        left.sendFiles([source,empty]);await fulfillment(of:[approval],timeout:3)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("right/source.bin").path))
        right.decide(true);await fulfillment(of:[completed],timeout:5)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("right/source.bin")),Data(repeating:7,count:32769))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("right/empty.bin")),Data())
        left.retire();right.retire()
    }
    func testWrongCancelIdentityCannotOwnReplacement() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let offered=expectation(description:"offer"),rejected=expectation(description:"reject")
        let manager=DataTransferManager(generation:9,directory:root){_,completion in completion(true)}
        manager.changed={snapshot in if snapshot.phase == .awaitingDecision {offered.fulfill()};if snapshot.phase == .rejected {rejected.fulfill()}}
        let id=UUID(),offer=TransferPacket(kind:.offer,generation:7,id:id,files:[TransferFile(name:"x",length:1)])
        XCTAssertTrue(manager.post(offer));await fulfillment(of:[offered],timeout:2)
        XCTAssertTrue(manager.owns(TransferPacket(kind:.cancel,generation:7,id:id)))
        XCTAssertFalse(manager.owns(TransferPacket(kind:.cancel,generation:7,id:UUID())))
        XCTAssertFalse(manager.owns(TransferPacket(kind:.cancel,generation:8,id:id)))
        manager.decide(false);await fulfillment(of:[rejected],timeout:2);manager.retire()
    }
    func testBulkYieldsToControl() async throws {
        let queue=DispatchQueue(label:"transfer-writer-test")
        let finished=expectation(description:"priority order")
        var order:[UInt8]=[];var callbacks:[(NWError?)->Void]=[]
        let writer=ControlChannelWriter(queue:queue){data,_,callback in order.append(data[0]);callbacks.append(callback)}
        queue.async {
            writer.begin(generation:1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])){_ in})
            XCTAssertTrue(writer.enqueueBulk(Data([2])){_ in})
            XCTAssertTrue(writer.enqueue(Data([9])))
            callbacks.removeFirst()(nil)
            queue.asyncAfter(deadline:.now()+0.02){
                XCTAssertEqual(order,[1,9]);callbacks.removeFirst()(nil)
                queue.asyncAfter(deadline:.now()+0.02){XCTAssertEqual(order,[1,9,2]);callbacks.removeFirst()(nil);finished.fulfill()}
            }
        }
        await fulfillment(of:[finished],timeout:2)
    }

    func testCancelBulkCompletesQueuedBulkFailureExactlyOnceWithoutAffectingControl() async {
        let q = DispatchQueue(label: "F01.explicit-callbacks")
        let done = expectation(description: "active and control drained")
        var sent: [UInt8] = [], callbacks: [(NWError?) -> Void] = []
        var a = 0, b = 0, c = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in
            sent.append(data[0]); callbacks.append(callback)
        }
        q.async {
            writer.begin(generation: 31)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { error in a += 1; XCTAssertNil(error) })
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in b += 1; XCTAssertNotNil(error) })
            XCTAssertTrue(writer.enqueue(Data([9])) { error in c += 1; XCTAssertNil(error) })
            writer.cancelBulk(); writer.cancelBulk()
            XCTAssertEqual(b, 1, "Queued B must receive exactly one terminal failure")
            XCTAssertEqual(a, 0); XCTAssertEqual(c, 0); XCTAssertEqual(sent, [1])
            callbacks.removeFirst()(nil)
            q.async {
                XCTAssertEqual(a, 1); XCTAssertEqual(b, 1); XCTAssertEqual(sent, [1, 9])
                let control = callbacks.removeFirst(); control(nil); control(nil)
                q.async {
                    XCTAssertEqual(c, 1); XCTAssertEqual(b, 1)
                    writer.cancelBulk(); writer.cancel()
                    XCTAssertEqual(b, 1); done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    func testCancelBulkPreservesActiveAndRejectsStaleGenerationCallback() async {
        let q = DispatchQueue(label: "F01.generation")
        let done = expectation(description: "replacement control")
        var callbacks: [(NWError?) -> Void] = [], sent: [UInt8] = []
        var active = 0, queued = 0, replacement = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in sent.append(data[0]); callbacks.append(callback) }
        q.async {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { _ in active += 1 })
            writer.cancelBulk(); XCTAssertEqual(active, 0)
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in queued += 1; XCTAssertNotNil(error) })
            writer.cancelBulk(); writer.cancel(); writer.begin(generation: 2)
            XCTAssertTrue(writer.enqueue(Data([9])) { _ in replacement += 1 })
            let old = callbacks.removeFirst(); old(.posix(.ECANCELED)); old(nil)
            q.async {
                XCTAssertEqual(sent, [1, 9]); XCTAssertEqual(active, 0); XCTAssertEqual(queued, 1)
                callbacks.removeFirst()(nil)
                q.async { XCTAssertEqual(replacement, 1); XCTAssertEqual(queued, 1); done.fulfill() }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    func testCancelBulkCallbackMayEnqueueReplacementWithoutLosingControl() async {
        let q = DispatchQueue(label: "F01.reentrant"), done = expectation(description: "replacement drained")
        var callbacks: [(NWError?) -> Void] = [], sent: [UInt8] = [], cancelled = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in sent.append(data[0]); callbacks.append(callback) }
        q.async {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { _ in })
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in
                cancelled += 1; XCTAssertNotNil(error)
                XCTAssertTrue(writer.enqueueBulk(Data([3])) { _ in })
            })
            XCTAssertTrue(writer.enqueue(Data([9])))
            writer.cancelBulk(); XCTAssertEqual(cancelled, 1)
            callbacks.removeFirst()(nil)
            q.async {
                XCTAssertEqual(sent, [1, 9]); callbacks.removeFirst()(nil)
                q.async {
                    XCTAssertEqual(sent, [1, 9, 3])
                    if !callbacks.isEmpty { callbacks.removeFirst()(nil) }
                    q.async { done.fulfill() }
                }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    #if targetEnvironment(simulator)
    func testUSBSharedStreamBulkWindowAllowsControlProgressWhileTransferIOBlocked() async throws {
        let network = NetworkManager()
        let session = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID(), peerGeneration: UInt64 = 7
        let offered = expectation(description: "offer admitted")
        let accepted = expectation(description: "explicitly accepted")
        let blocked = expectation(description: "first chunk holds real IO worker")
        let terminal = expectation(description: "verified transfer terminal")
        let release = DispatchSemaphore(value: 0)
        let payload = Data((0..<(6 * TransferProtocol.defaultChunkBytes)).map { UInt8(truncatingIfNeeded: $0 / TransferProtocol.defaultChunkBytes + $0 % 251) })
        var cancels = 0, fileAcks = 0, acks = 0, rejectedPosts = 0
        let pong = expectation(description: "control progresses before transfer IO releases")
        var final: DataTransferManager.Snapshot?
        let manager = DataTransferManager(generation: session.generation, directory: root) { packet, done in
            if packet.kind == .cancel { cancels += 1 }
            if packet.kind == .fileAck { fileAcks += 1 }
            if packet.kind == .ack { acks += 1 }
            done(true)
        }
        manager.changed = { snapshot in
            if snapshot.phase == .awaitingDecision { offered.fulfill() }
            if snapshot.phase == .receiving && snapshot.bytes == 0 { accepted.fulfill() }
            if snapshot.phase == .failed || snapshot.phase == .completed {
                final = snapshot; terminal.fulfill()
            }
        }
        manager.diagnostic = { line in
            if line.contains("stage=first_chunk ") { blocked.fulfill(); release.wait() }
        }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = []
        network.transferReceiveForTesting = { _, callback in reads.append(callback); XCTAssertEqual(reads.count, 1) }
        network.transferPostForTesting = { packet, completion in
            let admitted = manager.post(packet, completion: completion)
            if !admitted { rejectedPosts += 1 }
            return admitted
        }
        defer {
            release.signal(); network.stopForTesting(); manager.retire()
            try? FileManager.default.removeItem(at: root)
        }
        network.controlSendForAudioTesting = { data, completion in
            if data.count >= 16 && data[5] == WireMessageType.pong.rawValue { pong.fulfill() }
            completion(nil)
        }
        network.startTransferReceiveForTesting(manager: manager)
        network.configureTransferAuthorizationForTesting(manager: manager, authenticated: true, committed: true, usb: true)
        let offer = TransferPacket(kind: .offer, generation: peerGeneration, id: id,
                                   files: [TransferFile(name: "coalesced.bin", length: UInt64(payload.count))])
        network.networkQueueForTesting.sync {
            reads.removeFirst()(transferTestFrame(.transferOffer, try! TransferProtocol.encode(offer)), nil, false, nil)
        }
        await fulfillment(of: [offered], timeout: 3)
        manager.decide(true); await fulfillment(of: [accepted], timeout: 3)
        network.networkQueueForTesting.sync {}
        var burst = Data()
        for index in 0..<3 {
            var packet = TransferPacket(kind: .chunk, generation: peerGeneration, id: id)
            packet.chunkIndex = UInt64(index); packet.offset = UInt64(index * TransferProtocol.defaultChunkBytes)
            packet.bytes = payload.subdata(in: index * TransferProtocol.defaultChunkBytes..<(index + 1) * TransferProtocol.defaultChunkBytes)
            burst.append(transferTestFrame(.transferChunk, try TransferProtocol.encode(packet)))
        }
        burst.append(transferTestFrame(.ping, Data(count: 16)))
        XCTAssertLessThanOrEqual(burst.count, 64 * 1024)
        network.networkQueueForTesting.sync { reads.removeFirst()(burst, nil, false, nil) }
        await fulfillment(of: [blocked], timeout: 3)
        await fulfillment(of: [pong], timeout: 1)
        XCTAssertEqual(network.transferPendingForTesting, 3, "All three chunks must be admitted while the serial worker is blocked")
        XCTAssertLessThanOrEqual(network.transferPendingForTesting, DataTransferManager.maxPendingPackets)
        XCTAssertEqual(rejectedPosts, 0, "A burst within the bounded window must not fail admission")
        network.networkQueueForTesting.sync { XCTAssertEqual(reads.count, 1, "Capacity must allow one outstanding receive") }
        release.signal()
        // Completion is observable through a fresh receive; it must drain the saved suffix first.
        let rearmed = expectation(description: "coalesced suffix drained")
        network.networkQueueForTesting.async {
            network.transferReceiveForTesting = { _, callback in
                reads.append(callback); XCTAssertEqual(reads.count, 1); rearmed.fulfill()
            }
            if !reads.isEmpty { rearmed.fulfill() }
        }
        await fulfillment(of: [rearmed], timeout: 3)
        if rejectedPosts != 0 {
            await fulfillment(of: [terminal], timeout: 3)
            XCTAssertEqual(final?.phase, .completed)
            return
        }
        for index in 3..<6 {
            let drained = expectation(description: "chunk drained")
            var packet = TransferPacket(kind: .chunk, generation: peerGeneration, id: id)
            packet.chunkIndex = UInt64(index); packet.offset = UInt64(index * TransferProtocol.defaultChunkBytes)
            packet.bytes = payload.subdata(in: index * TransferProtocol.defaultChunkBytes..<(index + 1) * TransferProtocol.defaultChunkBytes)
            network.networkQueueForTesting.sync {
                network.transferReceiveForTesting = { _, callback in reads.append(callback); drained.fulfill() }
                reads.removeFirst()(transferTestFrame(.transferChunk, try! TransferProtocol.encode(packet)), nil, false, nil)
            }
            await fulfillment(of: [drained], timeout: 3)
        }
        var end = TransferPacket(kind: .fileEnd, generation: peerGeneration, id: id)
        end.offset = UInt64(payload.count); end.bytes = Data(SHA256.hash(data: payload))
        let last = transferTestFrame(.transferFileEnd, try TransferProtocol.encode(end)) +
            transferTestFrame(.transferEnd, try TransferProtocol.encode(TransferPacket(kind: .end, generation: peerGeneration, id: id)))
        network.networkQueueForTesting.sync {
            network.transferReceiveForTesting = { _, callback in reads.append(callback) }
            reads.removeFirst()(last, nil, false, nil)
        }
        await fulfillment(of: [terminal], timeout: 3)
        XCTAssertEqual(final?.phase, .completed); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(fileAcks, 1); XCTAssertEqual(acks, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("coalesced.bin")), payload)
    }

    func testBulkCancellationDoesNotRetireAuthenticatedSession() async {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        defer { network.stopForTesting() }
        var sends: [UInt8] = [], callbacks: [(NWError?) -> Void] = []
        var active = 0, queued = 0, control = 0
        let done = expectation(description: "urgent control completes")
        network.controlSendForAudioTesting = { data, completion in sends.append(data[5]); callbacks.append(completion) }
        network.beginTransferWriterForTesting()
        network.enqueueTransferWireForTesting(bulk: true) { error in active += 1; XCTAssertNil(error) }
        network.enqueueTransferWireForTesting(bulk: true) { error in queued += 1; XCTAssertNotNil(error) }
        network.enqueueTransferWireForTesting(bulk: false) { error in control += 1; XCTAssertNil(error); done.fulfill() }
        network.networkQueueForTesting.sync {}
        network.cancelTransfer(); network.networkQueueForTesting.sync {}
        XCTAssertEqual(queued, 1); XCTAssertEqual(active, 0); XCTAssertEqual(control, 0)
        XCTAssertEqual(network.wifiLifecycleSnapshotForTesting().authenticatedGeneration, session.generation)
        network.networkQueueForTesting.sync { callbacks.removeFirst()(nil) }
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(sends, [WireMessageType.transferEnd.rawValue, WireMessageType.ping.rawValue])
        network.networkQueueForTesting.sync { if !callbacks.isEmpty { callbacks.removeFirst()(nil) } }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(active, 1); XCTAssertEqual(queued, 1); XCTAssertEqual(control, 1)
        XCTAssertEqual(network.wifiSessionSnapshotForTesting().generation, session.generation)
    }

    func testRealManagerSaturationFailsTransferClosedAndRearmsOnce() async throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        let blocked = expectation(description: "first accepted offer held"), rearmed = expectation(description: "accepted work releases receive"), failed = expectation(description: "overflow fails transfer closed")
        let release = DispatchSemaphore(value: 0)
        manager.changed = { snapshot in
            if snapshot.phase == .awaitingDecision { blocked.fulfill(); release.wait() }
            if snapshot.phase == .failed { failed.fulfill() }
        }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], arms = 0
        network.transferReceiveForTesting = { _, callback in
            arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1)
            if arms == 2 { rearmed.fulfill() }
        }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        network.startTransferReceiveForTesting(manager: manager)
        var bytes = Data()
        for _ in 0..<DataTransferManager.maxPendingPackets {
            let offer = TransferPacket(kind: .offer, generation: 7, id: UUID(), files: [TransferFile(name: "x", length: 0)])
            bytes.append(transferTestFrame(.transferOffer, try TransferProtocol.encode(offer)))
        }
        network.networkQueueForTesting.sync { reads.removeFirst()(bytes, nil, false, nil) }
        await fulfillment(of: [blocked], timeout: 3)
        XCTAssertEqual(network.transferPendingForTesting, DataTransferManager.maxPendingPackets); XCTAssertTrue(reads.isEmpty); XCTAssertEqual(arms, 1)
        // The parser now pauses before overflow. Exercise a true manager refusal
        // independently, while its entire bounded worker window remains held.
        XCTAssertFalse(manager.post(TransferPacket(kind: .offer, generation: 7, id: UUID(),
            files: [TransferFile(name: "overflow", length: 0)])))
        release.signal()
        await fulfillment(of: [rearmed, failed], timeout: 3)
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(network.transferPendingForTesting, 0); XCTAssertEqual(arms, 2); XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(network.wifiLifecycleSnapshotForTesting().authenticatedGeneration, session.generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    func testT01ParserPausedMixedBurstPreservesEveryByteAtEverySplit() throws {
        let packet = TransferPacket(kind: .chunk, generation: 7, id: UUID(), bytes: Data(repeating: 3, count: 31))
        let chunk = transferTestFrame(.transferChunk, try TransferProtocol.encode(packet))
        let prefix = (0..<DataTransferManager.maxPendingPackets).reduce(into: Data()) { bytes, _ in bytes.append(chunk) }
        let mixed = prefix + transferTestFrame(.ping, Data(count: 16)) +
            transferTestFrame(.pointerInput, Data(count: 8)) + chunk + chunk + chunk
        XCTAssertLessThanOrEqual(mixed.count, WireProtocol.receiveChunkSize)
        for split in 0...mixed.count {
            let parser = WireStreamParser(generation: 7)
            var frames: [WireMessageType] = [], admitted = 0
            for fragment in [Data(mixed.prefix(split)), Data(mixed.dropFirst(split))] {
                var offset = 0
                while offset < fragment.count {
                    let count = parser.consume(Data(fragment.dropFirst(offset)), generation: 7,
                        shouldContinue: { admitted < DataTransferManager.maxPendingPackets }) { event in
                            if case .message(let message) = event {
                                frames.append(message.header.type)
                                if message.header.type == .transferChunk { admitted += 1 }
                            }
                        }
                    offset += count
                    XCTAssertLessThanOrEqual(admitted, DataTransferManager.maxPendingPackets)
                    if admitted == DataTransferManager.maxPendingPackets { admitted = 0 }
                    else { XCTAssertGreaterThan(count, 0) }
                }
            }
            XCTAssertEqual(frames, Array(repeating: .transferChunk, count: DataTransferManager.maxPendingPackets) +
                                  [.ping, .pointerInput, .transferChunk, .transferChunk, .transferChunk])
        }
    }

    private func transferTestFrame(_ type: WireMessageType, _ payload: Data) -> Data {
        var frame = Data("SCST".utf8); frame.append(contentsOf: [1, type.rawValue, 0, 0])
        var size = UInt32(payload.count).littleEndian, sequence = UInt32(1).littleEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &sequence) { frame.append(contentsOf: $0) }
        frame.append(payload); return frame
    }

    func testRejectedTransferAdmissionRearmsAuthenticatedReceiveOrRetiresExplicitly() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = []
        var arms = 0, posts = 0, pongs = 0
        network.transferReceiveForTesting = { _, callback in arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1) }
        network.transferPostForTesting = { _, _ in posts += 1; return false }
        network.controlSendForAudioTesting = { data, completion in
            if data.count >= 16 && data[5] == WireMessageType.pong.rawValue { pongs += 1 }
            completion(nil)
        }
        network.startTransferReceiveForTesting(manager: manager)
        let packet = TransferPacket(kind: .end, generation: 7, id: UUID())
        let transfer = transferTestFrame(.transferEnd, try TransferProtocol.encode(packet))
        let ping = transferTestFrame(.ping, Data(count: 16))
        // Repeated synchronous refusal must return to the outer receive boundary,
        // with one outstanding read, without recursive parser entry or extra queues.
        for _ in 0..<16 {
            network.networkQueueForTesting.sync { reads.removeFirst()(transfer + ping, nil, false, nil) }
            network.networkQueueForTesting.sync {}
            XCTAssertEqual(network.transferPendingForTesting, 0)
        }
        XCTAssertEqual(posts, 16); XCTAssertEqual(arms, 17); XCTAssertEqual(reads.count, 1); XCTAssertEqual(pongs, 16)
        // A captured old receive callback must not dispatch into a replacement owner.
        let stale = reads.removeFirst()
        _ = network.simulateCommittedWifiSessionForTesting()
        network.networkQueueForTesting.sync { stale(transfer, nil, false, nil) }
        XCTAssertEqual(posts, 16); XCTAssertEqual(arms, 17)
    }

    func testTransferAdmissionAcceptedThenRefusedPreservesOneReadAndRejectsStaleCompletion() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], finishes: [() -> Void] = []
        var posts = 0, arms = 0
        network.transferReceiveForTesting = { _, callback in arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1) }
        network.transferPostForTesting = { _, completion in
            posts += 1
            if posts == 1 { finishes.append(completion); return true }
            return false
        }
        network.startTransferReceiveForTesting(manager: manager)
        let frame = transferTestFrame(.transferEnd, try TransferProtocol.encode(TransferPacket(kind: .end, generation: 7, id: UUID())))
        network.networkQueueForTesting.sync { reads.removeFirst()(frame + frame, nil, false, nil) }
        XCTAssertEqual(posts, 2); XCTAssertEqual(arms, 2); XCTAssertEqual(reads.count, 1); XCTAssertEqual(network.transferPendingForTesting, 1)
        finishes.removeFirst()(); network.networkQueueForTesting.sync {}
        XCTAssertEqual(arms, 2); XCTAssertEqual(reads.count, 1); XCTAssertEqual(network.transferPendingForTesting, 0)
        // Hold an accepted completion, reconnect, then release it: no stale rearm.
        posts = 0
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(network.transferPendingForTesting, 1)
        XCTAssertEqual(arms, 3); XCTAssertEqual(reads.count, 1)
        let staleRead = reads.removeFirst()
        _ = network.simulateCommittedWifiSessionForTesting()
        finishes.removeFirst()(); network.networkQueueForTesting.sync {}
        network.networkQueueForTesting.sync { staleRead(frame, nil, false, nil) }
        XCTAssertEqual(arms, 3); XCTAssertTrue(reads.isEmpty)
    }

    func testTransferAdmissionWithoutManagerOrAuthenticationHasNoSideEffects() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, _ in XCTFail("No transfer side effects allowed") }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], posts = 0
        network.transferReceiveForTesting = { _, callback in reads.append(callback) }
        network.transferPostForTesting = { _, _ in posts += 1; return false }
        let frame = transferTestFrame(.transferEnd, try TransferProtocol.encode(TransferPacket(kind: .end, generation: 7, id: UUID())))
        network.startTransferReceiveForTesting(manager: nil)
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(posts, 0); XCTAssertEqual(reads.count, 1)
        reads.removeAll()
        network.startTransferReceiveForTesting(manager: manager, authenticated: false)
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(posts, 0); XCTAssertEqual(network.transferPendingForTesting, 0)
    }
    #endif

}
