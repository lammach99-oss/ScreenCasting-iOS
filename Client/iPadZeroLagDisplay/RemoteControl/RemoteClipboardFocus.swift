import Foundation

// Provider and content-worker callbacks run outside the main actor.
final class RemoteClipboardReadPermit {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return valid
    }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }
}

/// One per interactive pair. Lease effects run on the same actor as pasteboard access.
@MainActor
final class RemoteClipboardFocus {
    private let setLeaseActive: (SlotOrdinal, Bool) -> Void
    private var boards: [SlotOrdinal: () -> Void] = [:]
    private(set) var epoch: UInt64?
    private(set) var readPermit: RemoteClipboardReadPermit?
    private var selected: SlotOrdinal?

    init(setLeaseActive: @escaping (SlotOrdinal, Bool) -> Void) {
        self.setLeaseActive = setLeaseActive
    }

    func bind(_ board: RemoteClipboardPasteboard, slot: SlotOrdinal) {
        boards[slot] = { [weak board] in board?.resetFocus() }
        setLeaseActive(slot, selected == slot)
    }

    func promote(slot: SlotOrdinal, epoch: UInt64) {
        if let previous = self.epoch, previous >= epoch { return }
        if let selected, let previous = self.epoch { demote(slot: selected, epoch: previous) }
        self.epoch = epoch
        readPermit = RemoteClipboardReadPermit()
        selected = slot
        boards[slot]?()
        setLeaseActive(slot, true)
    }

    func demote(slot: SlotOrdinal, epoch: UInt64) {
        guard isAuthorized(slot: slot, epoch: epoch) else { return }
        readPermit?.revoke()
        readPermit = nil
        selected = nil
        boards[slot]?()
        setLeaseActive(slot, false)
    }

    func isAuthorized(slot: SlotOrdinal, epoch: UInt64) -> Bool {
        selected == slot && self.epoch == epoch
    }
}
