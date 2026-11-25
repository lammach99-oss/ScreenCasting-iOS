// One instance shared by all scenes. Each synchronous transition completes before
// the caller dispatches transport, surface or output work for its resulting tickets.
@MainActor final class SessionSwitcher {
    enum SwapEffect: Equatable {
        case parkAndCancelTransfer(SlotTicket)
    }

    static let shared = SessionSwitcher(pair: RemotePairStore().load())
    private var first = SessionSlot(ordinal: .one)
    private var second = SessionSlot(ordinal: .two)
    private(set) var selected: SlotOrdinal
    private(set) var focusEpoch: UInt64 = 0
    private(set) var surfaceOwner: String?
    private(set) var outputLease: SlotTicket?
    private(set) var inFlight: SlotTicket?
    private var desired: SlotOrdinal?
    private var hasPresentation = false
    private var hasContext = false

    init(pair: RemotePairStore.Pair = .empty) {
        selected = pair.selected
        first.peer = pair.first
        second.peer = pair.second
    }

    private(set) subscript(_ ordinal: SlotOrdinal) -> SessionSlot {
        get { ordinal == .one ? first : second }
        set {
            if ordinal == .one { first = newValue } else { second = newValue }
        }
    }

    var offeredAlternate: SlotOrdinal? {
        let phase = self[selected].phase
        guard phase == .offline || phase == .refused, self[selected.alternate].phase == .parked else { return nil }
        return selected.alternate
    }

    func connect(_ ordinal: SlotOrdinal, route: SlotRoute) -> SlotTicket? {
        switch self[ordinal].phase {
        case .idle, .offline, .refused: break
        default: return nil
        }
        self[ordinal].generation += 1
        self[ordinal].phase = .connecting
        self[ordinal].route = route
        self[ordinal].lastError = nil
        self[ordinal].retryRequested = false
        return self[ordinal].ticket
    }

    @discardableResult func authenticate(_ ticket: SlotTicket, peer: TrustedPeerReference) -> Bool {
        let ordinal = ticket.ordinal
        guard self[ordinal].ticket == ticket, self[ordinal].phase == .connecting else { return false }
        if self[ordinal.alternate].peer == peer {
            drop(ticket, error: .duplicatePeer)
            return false
        }
        if let expected = self[ordinal].peer, expected != peer {
            drop(ticket, error: .identityMismatch)
            return false
        }
        self[ordinal].peer = peer
        self[ordinal].phase = ordinal == selected ? .authenticated : .parked
        if ordinal == selected { resumeIfPossible() }
        return true
    }

    func drop(_ ticket: SlotTicket, error: SlotFailure) {
        let ordinal = ticket.ordinal
        guard self[ordinal].ticket == ticket else { return }
        if ordinal == selected { fence() }
        self[ordinal].epoch += 1
        self[ordinal].phase = error == .transport ? .offline : .refused
        self[ordinal].preview = .placeholder
        self[ordinal].retryRequested = error == .transport
        self[ordinal].lastError = error
    }

    func remove(_ ordinal: SlotOrdinal) {
        if ordinal == selected { fence() }
        let generation = self[ordinal].generation + 1
        self[ordinal] = SessionSlot(ordinal: ordinal, generation: generation)
    }

    @discardableResult func claimSurface(_ scene: String) -> Bool {
        if let owner = surfaceOwner { return owner == scene }
        surfaceOwner = scene
        resumeIfPossible()
        return true
    }

    func releaseSurface(_ scene: String) {
        guard scene == surfaceOwner else { return }
        fence()
        parkSelected()
        first.preview = .placeholder
        second.preview = .placeholder
        surfaceOwner = nil
    }

    @discardableResult func select(_ ordinal: SlotOrdinal, scene: String) -> SwapEffect? {
        guard scene == surfaceOwner else { return nil }
        if inFlight != nil {
            desired = ordinal
            return nil
        }
        guard ordinal != selected, self[ordinal].phase == .parked else { return nil }
        let outgoing = self[selected]
        fence()
        parkSelected()
        selected = ordinal
        resumeIfPossible()
        return outgoing.phase == .active ? .parkAndCancelTransfer(outgoing.ticket) : nil
    }

    private func parkSelected() {
        switch self[selected].phase {
        case .active, .resuming, .authenticated:
            self[selected].epoch += 1
            self[selected].phase = .parked
        default: break
        }
    }

    private func resumeIfPossible() {
        guard surfaceOwner != nil, self[selected].phase == .authenticated || self[selected].phase == .parked else { return }
        focusEpoch = max(focusEpoch, self[selected].epoch) + 1
        self[selected].epoch = focusEpoch
        self[selected].phase = .resuming
        inFlight = self[selected].ticket
    }

    private func fence() {
        focusEpoch += 1
        outputLease = nil
        inFlight = nil
        desired = nil
        hasPresentation = false
        hasContext = false
    }

    // Call only for actual presentation and validated input context from the
    // binding that captured this ticket. Invalidate on source/permission change.
    @discardableResult func presented(_ ticket: SlotTicket) -> SwapEffect? {
        guard ticket == inFlight else { return nil }
        hasPresentation = true
        return finishIfReady(ticket)
    }

    @discardableResult func contextReady(_ ticket: SlotTicket) -> SwapEffect? {
        guard ticket == inFlight else { return nil }
        hasContext = true
        return finishIfReady(ticket)
    }

    private func finishIfReady(_ ticket: SlotTicket) -> SwapEffect? {
        guard hasPresentation, hasContext, let scene = surfaceOwner else { return nil }
        inFlight = nil
        self[selected].phase = .active
        if let next = desired, next != selected, self[next].phase == .parked {
            return select(next, scene: scene)
        }
        desired = nil
        outputLease = ticket
        return nil
    }

    func recordAuthorizedThumbnail(_ ticket: SlotTicket, revision: UInt64) {
        guard ticket == outputLease else { return }
        self[ticket.ordinal].preview = .thumbnail(revision: revision)
    }

    func invalidateContext(_ ticket: SlotTicket) {
        let ordinal = ticket.ordinal
        guard self[ordinal].ticket == ticket else { return }
        self[ordinal].preview = .placeholder
        switch self[ordinal].phase {
        case .active, .resuming:
            fence()
            self[ordinal].phase = .authenticated
            resumeIfPossible()
        case .parked, .authenticated: self[ordinal].epoch += 1
        default: break
        }
    }
}
