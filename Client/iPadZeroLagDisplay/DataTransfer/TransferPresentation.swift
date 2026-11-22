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
    static func rejection(_ state: DataTransferManager.Snapshot) -> String? {
        guard state.phase == .rejected, state.outgoing, let reason = state.rejectionReason else { return nil }
        switch reason {
        case .ok: return nil
        case .userRejected: return "The transfer was declined on the PC."
        case .busy: return "The PC is busy with another transfer. Try again when it finishes."
        case .invalidMetadata: return "The PC rejected the file names or sizes. Review the files and try again."
        case .unsupportedVersion: return "The PC does not support this transfer version. Update the PC app and try again."
        case .insufficientStorage: return "The PC is out of space for this transfer. Free space on the PC and try again."
        case .destinationUnavailable: return "The PC could not open the destination. Check the receive folder on the PC."
        case .sessionRetired: return "The PC transfer session ended. Reconnect and try again."
        case .policyRejected: return "The PC's file-transfer policy blocked this upload. Check the PC's transfer settings."
        case .lengthMismatch, .hashMismatch, .invalidOffset, .invalidChunk:
            return "The PC rejected the file data. Choose the files again and retry."
        case .writeFailed: return "The PC could not write the files. Check the receive folder on the PC."
        case .cancelled: return "The PC cancelled the transfer."
        }
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
        return deleted + " Copies saved to Files stay untouched."
    }
}
