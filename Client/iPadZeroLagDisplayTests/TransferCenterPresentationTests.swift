import XCTest
import Foundation
import Combine
import CryptoKit
import UIKit
@testable import iPadCasting

final class TransferCenterPresentationTests: XCTestCase {

    @MainActor private func uxWait<T>(_ publisher: Published<T>.Publisher, _ predicate: @escaping (T) -> Bool) async {
        let ready = expectation(description: "received presentation reflects completed storage work")
        var completed = false
        let subscription = publisher.sink { value in
            if !completed && predicate(value) { completed = true; ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        withExtendedLifetime(subscription) {}
    }
    private func uxRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("UX03-" + UUID().uuidString) }
    private func uxRecord(_ library: ReceivedFileLibrary, root: URL, name: String = "verified.bin", bytes: Data = Data([1, 2])) throws -> URL {
        let file = root.appendingPathComponent(name); try bytes.write(to: file)
        try library.recordPublished(file, length: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
        return file
    }

    func testUX03JournalCleanupFailureAfterUnlinkReportsWarningAndReopenSafe() throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var commits = 0; var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeReceiptCommit = { commits += 1; if commits == 4 { throw CocoaError(.fileWriteOutOfSpace) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        let file = try uxRecord(library, root: root), exported = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: exported) }
        try FileManager.default.copyItem(at: file, to: exported)
        let token = try library.confirmClear(), result = try library.clear(token)
        XCTAssertEqual(result.deletedCount, 1); XCTAssertEqual(result.deletedBytes, 2)
        XCTAssertFalse(result.journalCleanupDurable); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: exported), Data([1, 2]))
        XCTAssertEqual(try ReceivedFileLibrary(directory: root).snapshot().retainedCount, 0)
        XCTAssertThrowsError(try library.clear(token))
        XCTAssertTrue(TransferPresentation.clearResult(result, legacyCount: 0).contains("metadata"))
    }
    func testUX03ConsumedConfirmationDoesNotReplayAfterPartialCleanup() throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var commits = 0; var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeReceiptCommit = { commits += 1; if commits == 5 { throw CocoaError(.fileWriteNoPermission) } }
        hooks.beforeUnlink = { if $0 == "blocked.bin" { throw CocoaError(.fileWriteNoPermission) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        _ = try uxRecord(library, root: root); let blocked = try uxRecord(library, root: root, name: "blocked.bin")
        let token = try library.confirmClear(), result = try library.clear(token)
        XCTAssertEqual(result.deletedCount, 1); XCTAssertEqual(result.failedCount, 1); XCTAssertFalse(result.journalCleanupDurable)
        XCTAssertThrowsError(try library.clear(token)); XCTAssertEqual(try library.snapshot().retainedBytes, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
    }
    func testUX03EligibleNamesNeverAdoptLegacyAfterFilenameCollision() throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), file = try uxRecord(library, root: root)
        XCTAssertEqual(try library.snapshot().eligibleNames, ["verified.bin"])
        try Data([1, 2]).write(to: file, options: .atomic)
        XCTAssertTrue(try library.snapshot().eligibleNames.isEmpty)
        XCTAssertEqual(try library.snapshot().retainedBytes, 2)
    }
    func testUX03CorruptReceiptStillShowsRetainedQuotaButNeverGrantsDelete() throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root); _ = try uxRecord(library, root: root)
        try Data("bad{".utf8).write(to: root.appendingPathComponent(ReceivedFileLibrary.metadataName).appendingPathComponent("receipts.json"))
        let inventory = try library.snapshot()
        XCTAssertEqual(inventory.retainedCount, 1); XCTAssertEqual(inventory.retainedBytes, 2)
        XCTAssertTrue(inventory.eligibleNames.isEmpty); XCTAssertThrowsError(try library.confirmClear())
    }

    @MainActor func testUX03OfflineInventoryReopenKeepsLegacyAndReceiptBackedCopies() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root); _ = try uxRecord(library, root: root)
        try Data([7]).write(to: root.appendingPathComponent("legacy.bin"))
        let first = NetworkManager(receivedFilesDirectory: root); defer { first.stopForTesting() }
        await uxWait(first.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 2 }
        XCTAssertEqual(first.receivedFilesViewState.eligibleCount, 1); XCTAssertEqual(first.receivedFilesViewState.legacyBytes, 1)
        first.stopForTesting()
        let reopened = NetworkManager(receivedFilesDirectory: root); defer { reopened.stopForTesting() }
        await uxWait(reopened.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 2 }
        XCTAssertEqual(reopened.receivedFilesViewState.eligibleNames, ["verified.bin"])
    }
    @MainActor func testUX03ClearPromptCannotSilentlyIncludeLaterReceipt() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), first = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let prompt = try XCTUnwrap(network.receivedClearPrompt)
        let later = try uxRecord(library, root: root, name: "later.bin")
        network.confirmClearReceivedFiles(id: prompt.id)
        await uxWait(network.$receivedClearMessage) { $0?.contains("changed") == true }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: later.path))
        XCTAssertEqual(try library.snapshot().retainedCount, 2)
    }
    @MainActor func testUX03StaleClearDialogAfterReconnectDoesNotDelete() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), file = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let prompt = try XCTUnwrap(network.receivedClearPrompt)
        _ = network.simulateCommittedWifiSessionForTesting()
        network.confirmClearReceivedFiles(id: prompt.id)
        await uxWait(network.$receivedClearPrompt) { $0 == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)); XCTAssertEqual(try library.snapshot().eligibleCount, 1)
    }
    @MainActor func testUX03RapidDoubleDeleteConsumesOnlyOnePendingConfirmation() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var commits = 0; var hooks = ReceivedFileLibrary.Hooks(); hooks.beforeReceiptCommit = { commits += 1 }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks); _ = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let prompt = try XCTUnwrap(network.receivedClearPrompt)
        network.confirmClearReceivedFiles(id: prompt.id); network.confirmClearReceivedFiles(id: prompt.id)
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 0 }
        XCTAssertEqual(commits, 4); XCTAssertEqual(try library.snapshot().retainedBytes, 0)
    }
    @MainActor func testUX03PartialFailureReportsExactDeletedAndSurvivingBytes() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var hooks = ReceivedFileLibrary.Hooks(); hooks.beforeUnlink = { if $0 == "blocked.bin" { throw CocoaError(.fileWriteNoPermission) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks)
        _ = try uxRecord(library, root: root); _ = try uxRecord(library, root: root, name: "blocked.bin", bytes: Data([3, 4, 5]))
        try Data([9]).write(to: root.appendingPathComponent("legacy.bin"))
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let prompt = try XCTUnwrap(network.receivedClearPrompt); XCTAssertEqual(prompt.count, 3); XCTAssertEqual(prompt.bytes, 6)
        XCTAssertEqual(prompt.legacyCount, 1); XCTAssertEqual(prompt.legacyBytes, 1)
        network.confirmClearReceivedFiles(id: prompt.id)
        await uxWait(network.$receivedClearMessage) { $0?.contains("could not") == true }
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 1 && $0.retainedBytes == 3 }
        XCTAssertEqual(network.receivedFilesViewState.eligibleBytes, 3)
    }
    @MainActor func testUX03PostUnlinkJournalCommitFailureShowsWarning() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var commits = 0; var hooks = ReceivedFileLibrary.Hooks()
        hooks.beforeReceiptCommit = { commits += 1; if commits == 4 { throw CocoaError(.fileWriteOutOfSpace) } }
        let library = try ReceivedFileLibrary(directory: root, hooks: hooks); _ = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let id = try XCTUnwrap(network.receivedClearPrompt).id; network.confirmClearReceivedFiles(id: id)
        await uxWait(network.$receivedClearMessage) { $0?.contains("metadata") == true }
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 0 }
        XCTAssertFalse(network.receivedClearMessage?.contains("All") == true)
    }
    @MainActor func testUX03ExportLeaseHeldAcrossPickerPresentationAndDismissal() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), file = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        let acquired = expectation(description: "lease before picker"), released = expectation(description: "terminal release")
        var token: UUID?; network.requestReceivedFileExport(file) { token = $0; acquired.fulfill() }
        await fulfillment(of: [acquired], timeout: 5); let lease = try XCTUnwrap(token)
        let coordinator = TransferExporter.Coordinator { network.releaseReceivedFileExport(lease); released.fulfill() }
        XCTAssertThrowsError(try library.confirmClear()); XCTAssertTrue(try library.snapshot().busy)
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        TransferExporter.dismantleUIViewController(picker, coordinator: coordinator)
        coordinator.documentPickerWasCancelled(picker); coordinator.finishOnce()
        await fulfillment(of: [released], timeout: 5)
        await uxWait(network.$receivedFilesViewState) { $0.loaded && !$0.busy }
        XCTAssertEqual(try library.snapshot().eligibleCount, 1)
    }
    @MainActor func testUX03SaveToFilesCopyRemainsAfterAppPrivateDeletion() async throws {
        let root = uxRoot(), exported = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: exported) }
        let library = try ReceivedFileLibrary(directory: root), file = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        let acquired = expectation(description: "export owner"), ended = expectation(description: "copy completed")
        var token: UUID?; network.requestReceivedFileExport(file) { token = $0; acquired.fulfill() }
        await fulfillment(of: [acquired], timeout: 5); let lease = try XCTUnwrap(token)
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearMessage) { $0?.contains("active") == true }
        XCTAssertNil(network.receivedClearPrompt); try FileManager.default.copyItem(at: file, to: exported)
        let coordinator = TransferExporter.Coordinator { network.releaseReceivedFileExport(lease); ended.fulfill() }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        coordinator.documentPicker(picker, didPickDocumentsAt: [exported]); coordinator.finishOnce()
        await fulfillment(of: [ended], timeout: 5); await uxWait(network.$receivedFilesViewState) { $0.loaded && !$0.busy }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        network.confirmClearReceivedFiles(id: try XCTUnwrap(network.receivedClearPrompt).id)
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 0 }
        XCTAssertEqual(try Data(contentsOf: exported), Data([1, 2]))
    }
    @MainActor func testUX03LegacyOnlyCanConfirmAndClearAppPrivateCopy() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root); try Data([8]).write(to: root.appendingPathComponent("legacy.bin"))
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 1 }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let prompt = try XCTUnwrap(network.receivedClearPrompt); XCTAssertEqual(prompt.count, 1); XCTAssertEqual(prompt.bytes, 1)
        network.confirmClearReceivedFiles(id: prompt.id)
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 0 }
        XCTAssertEqual(try library.snapshot().retainedBytes, 0)
    }
    @MainActor func testUX03CancelAndStaleDismissCannotDeleteOrRevokeNextPrompt() async throws {
        let root = uxRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ReceivedFileLibrary(directory: root), file = try uxRecord(library, root: root)
        let network = NetworkManager(receivedFilesDirectory: root); defer { network.stopForTesting() }
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let first = try XCTUnwrap(network.receivedClearPrompt).id
        network.cancelClearReceivedFiles(id: first); await uxWait(network.$receivedClearPrompt) { $0 == nil }
        network.confirmClearReceivedFiles(id: first); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        network.requestClearReceivedFiles(); await uxWait(network.$receivedClearPrompt) { $0 != nil }
        let next = try XCTUnwrap(network.receivedClearPrompt).id; XCTAssertNotEqual(first, next)
        network.cancelClearReceivedFiles(id: first); network.confirmClearReceivedFiles(id: next)
        await uxWait(network.$receivedFilesViewState) { $0.loaded && $0.retainedCount == 0 }
    }

    func testUnknownFailureNeverInventsStorageCauseOrRetry() {
        var state=DataTransferManager.Snapshot();state.phase = .failed
        XCTAssertFalse(TransferPresentation.failure(state).contains("storage"))
        XCTAssertEqual(TransferPresentation.nextAction(state), "Ask the PC to send again.")
        state.outgoing=true
        XCTAssertEqual(TransferPresentation.nextAction(state), "Choose files to start a new transfer.")
    }
    func testProgressBoundedIncludingEmptyAndHugeFiles() {
        var state=DataTransferManager.Snapshot()
        XCTAssertEqual(TransferPresentation.progress(state),0)
        state.phase = .completed;XCTAssertEqual(TransferPresentation.progress(state),1)
        state.total=1;state.bytes=UInt64.max;XCTAssertEqual(TransferPresentation.progress(state),1)
        XCTAssertFalse(TransferPresentation.size(UInt64.max).isEmpty)
    }
    func testTerminalStatesAreNotCancellable() {
        for phase in [DataTransferManager.Phase.completed,.failed,.cancelled,.rejected,.retired,.idle] {
            XCTAssertFalse(TransferPresentation.active(phase))
        }
        XCTAssertTrue(TransferPresentation.active(.awaitingDecision))
    }
    func testFailureClassificationNeverExportsPrivateNSErrorText() {
        let error=NSError(domain:NSCocoaErrorDomain,code:CocoaError.fileWriteOutOfSpace.rawValue,userInfo:[NSFilePathErrorKey:"/private/user/secret.pdf"])
        let failure=DataTransferManager.FailureDetail.classify(error,stage:"admission")
        XCTAssertEqual(failure.reason,"STORAGE_FULL")
        XCTAssertFalse(String(describing:failure).contains("secret"))
        XCTAssertEqual(DataTransferManager.FailureDetail.classify(NSError(domain:"/private/secret",code:9),stage:"write").domain,"Transfer")
    }
}
