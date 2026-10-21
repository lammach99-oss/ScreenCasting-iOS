import Foundation

// Fail-closed API scaffold for executable native RED. Not connected to runtime.
final class ReceivedFileLibrary {
    struct Inventory {
        let retainedCount: Int
        let retainedBytes: UInt64
        let eligibleCount: Int
    }
    struct Confirmation {
        let count: Int
        let bytes: UInt64
    }
    struct ClearResult {
        let deletedCount: Int
        let failedCount: Int
    }
    init(directory: URL) throws {}
    func snapshot() throws -> Inventory { Inventory(retainedCount: 0, retainedBytes: 0, eligibleCount: 0) }
    func confirmClear() throws -> Confirmation { throw CocoaError(.featureUnsupported) }
    func clear(_ confirmation: Confirmation) throws -> ClearResult { throw CocoaError(.featureUnsupported) }
    func recordPublished(_ url: URL, length: UInt64, digest: Data) throws { throw CocoaError(.featureUnsupported) }
    func beginTransfer(owner: UUID) -> Bool { false }
    func endTransfer(owner: UUID) {}
    func beginExport(_ url: URL) throws -> UUID { throw CocoaError(.featureUnsupported) }
    func endExport(_ token: UUID) {}
}
