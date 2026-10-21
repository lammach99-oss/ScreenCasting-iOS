import Foundation

enum TransferPresentation {
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    static func progress(_ state: DataTransferManager.Snapshot) -> Double {
        guard state.total > 0 else { return state.phase == .completed ? 1 : 0 }
        return min(1, Double(state.bytes) / Double(state.total))
    }
    static func failure(_ state: DataTransferManager.Snapshot) -> String {
        switch state.failure?.reason {
        case "STORAGE_FULL": return "Not enough storage. Save retained files to Files and free app or device storage."
        case "STAGING_CREATE": return "The receiving file could not be created. Check available device storage."
        case "WRITE_FAILED": return "The file could not be written. Check device storage."
        case "VERIFY_OR_PUBLISH_FAILED": return "The file could not be verified or saved. No unverified file is available to export."
        case "INVALID_TRANSFER": return "The transfer did not match the expected file data."
        case "SEND_FAILED": return "The file could not be sent. Check the PC connection."
        default: return "The transfer could not finish. Check diagnostics."
        }
    }
    static func nextAction(_ state: DataTransferManager.Snapshot) -> String {
        state.outgoing ? "Choose files to start a new transfer." : "Ask the PC to send again."
    }
    static func active(_ phase: DataTransferManager.Phase) -> Bool {
        [.offering,.awaitingDecision,.sending,.receiving,.verifying,.awaitingAck].contains(phase)
    }
    static func clearResult(_ result: ReceivedFileLibrary.ClearResult, legacyCount: Int) -> String {
        let deleted = "Deleted \(result.deletedCount) files (\(size(result.deletedBytes)))."
        if !result.journalCleanupDurable {
            return deleted + " File deletion counts reflect disk operations, but metadata maintenance is incomplete. Refresh required."
        }
        if result.failedCount > 0 { return deleted + " \(result.failedCount) files could not be removed. Review files and retry." }
        return deleted + " \(legacyCount) older/unclassified files remain in ScreenCasting. Copies saved to Files stay untouched."
    }
}
