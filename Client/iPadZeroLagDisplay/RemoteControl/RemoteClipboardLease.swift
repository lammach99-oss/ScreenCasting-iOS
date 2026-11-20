import Foundation

/// Connection-scoped and owned by the network queue.
struct RemoteClipboardLease {
    typealias Wire = RemoteClipboardProtocol

    private(set) var nonce: UUID?
    private(set) var grant: Wire.State?
    private(set) var reason: Wire.Reason = .ok
    private var helloAcknowledged = false
    private var epoch: UInt64 = 0
    private var nextID: UInt64 = 0
    private var pendingID: UInt64?
    private var deadline: TimeInterval = 0
    private var nextRenew: TimeInterval = 0
    private var requested = false
    private var retry = true
    private var retryAt: TimeInterval = 0

    var validUntil: TimeInterval { deadline }

    mutating func start() -> Wire.Message? {
        guard nonce == nil else { return nil }
        let nonce = UUID()
        self.nonce = nonce
        return .hello(3, Wire.maxBytes, Wire.maxChunk, nonce)
    }

    mutating func tick(eligible: Bool, now: TimeInterval) -> Wire.Message? {
        guard let nonce, helloAcknowledged else { return nil }
        if !eligible {
            retry = true
            reason = .ok
            grant = nil
            retryAt = 0
            guard requested else { return nil }
            requested = false
            nextID += 1
            pendingID = nextID
            return .control(.disable, 0, nextID, false, nonce)
        }
        if requested, now >= deadline {
            grant = nil
            pendingID = nil
            requested = false
        }
        if !requested, retry, now >= retryAt {
            requested = true
            nextID += 1
            pendingID = nextID
            deadline = now + 3
            nextRenew = now + 1
            return .control(.request, 3, nextID, true, nonce)
        }
        if let grant, now >= nextRenew {
            nextRenew = now + 1
            nextID += 1
            return .control(.renew, grant.directions, nextID, true, nonce)
        }
        return nil
    }

    /// Renew has no success State. Advance the local cutoff only once the writer admits it.
    mutating func admitRenew(_ id: UInt64, now: TimeInterval) -> Bool {
        guard id == nextID, grant != nil, now < deadline else { return false }
        deadline = now + 3
        return true
    }

    func mayWrite(_ action: Wire.Action, id: UInt64, now: TimeInterval) -> Bool {
        if action == .disable { return id == pendingID && !requested }
        return id == nextID && requested && now < deadline &&
            (action == .renew ? grant != nil : pendingID == id)
    }

    mutating func receive(_ state: Wire.State, eligible: Bool, now: TimeInterval) {
        guard state.nonce == nonce else { return }
        if !helloAcknowledged {
            guard state.requestID == 0, state.kind == .disabled, state.epoch > 0 else { return }
            helloAcknowledged = true
            epoch = state.epoch
            return
        }
        if state.requestID == 0 {
            guard state.epoch > epoch else { return }
        } else {
            guard state.requestID == pendingID, state.epoch >= epoch else { return }
        }
        if state.kind == .enabled {
            guard eligible, requested, now < deadline, state.epoch > epoch,
                  state.requestID != 0 else { return }
            grant = state
        } else {
            grant = nil
            reason = state.reason
            requested = false
            retry = state.reason == .timeout || state.reason == .desktopBlocked ||
                state.reason == .controlRequired || (state.requestID == 0 && state.reason == .viewerDisabled)
            if retry, state.reason != .timeout { retryAt = now + 1 }
        }
        epoch = state.epoch
        if state.kind != .pendingConsent { pendingID = nil }
        if state.kind == .enabled { reason = .ok }
    }
}
