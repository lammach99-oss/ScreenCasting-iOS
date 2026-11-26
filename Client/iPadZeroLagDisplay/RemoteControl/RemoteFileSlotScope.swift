import Foundation

/// Construct per connection. Capture Action when publishing a prompt or starting work.
@MainActor
final class RemoteFileSlotScope {
    struct Action: Equatable {
        let slot: SlotOrdinal
        let epoch: UInt64
        let transferID: UUID
    }

    let slot: SlotOrdinal
    private let manager: DataTransferManager
    private var epoch: UInt64?
    private var focused = false

    init(slot: SlotOrdinal, manager: DataTransferManager) {
        self.slot = slot
        self.manager = manager
        manager.setSlotFileFocus(slot: slot, epoch: nil)
    }

    func promote(epoch: UInt64) {
        if let previous = self.epoch, previous >= epoch { return }
        self.epoch = epoch
        focused = true
        manager.setSlotFileFocus(slot: slot, epoch: epoch)
    }

    func isAuthorized(_ action: Action) -> Bool {
        focused && action.slot == slot && action.epoch == epoch && manager.activeTransferID == action.transferID
    }

    func cancelOnSwap(epoch: UInt64) {
        guard focused, self.epoch == epoch else { return }
        focused = false
        manager.setSlotFileFocus(slot: slot, epoch: nil)
        manager.cancel()
    }
}
