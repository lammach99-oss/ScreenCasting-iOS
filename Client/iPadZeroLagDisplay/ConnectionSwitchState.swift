import Foundation

/// Pure coordinator. The caller supplies monotonic time; no socket, timer or UI side effects.
public struct ConnectionSwitchState: Equatable {
    public enum Phase: Equatable {
        case checking, ready, permissionRequired, preparingUSB, switching, waitingPeer
        case waitingDisplay, waitingFrame, completed, failed, declined, unsupportedHost
    }
    public struct Pending: Equatable {
        public let request: ConnectionSelectRequest, originGeneration: UInt64
        public fileprivate(set) var started: TimeInterval
        public fileprivate(set) var sent = true
        public fileprivate(set) var accepted = false
        let protectedUSB: Bool
        fileprivate(set) var probeAnswered = false
        fileprivate(set) var rollbackRoute: ConnectionRoute?
        var rollingBack: Bool { rollbackRoute != nil }
        fileprivate var token = Data()
        fileprivate var completed: ConnectionSelectResult?
        fileprivate var completedAt: TimeInterval?
        fileprivate var replacement: UInt64?
        fileprivate var rollbackReadyAt: TimeInterval?
        fileprivate var rollbackFailure: ConnectionReason?
    }
    public private(set) var generation: UInt64 = 0
    public private(set) var enabled = false
    public private(set) var snapshot: ConnectionControlState?
    public private(set) var actualRoute: ConnectionRoute = .unknown
    public private(set) var phase: Phase = .checking
    public private(set) var pending: Pending?
    public private(set) var inputBlocked = false
    public private(set) var needsRefresh = false
    public private(set) var issue: ConnectionReason?
    public private(set) var offersReconnect = false
    private var nextTransaction: UInt64 = 0
    private var snapshotAt: TimeInterval = 0
    private var lastTime: TimeInterval?
    private var resultSnapshots: [UInt64: ConnectionControlState] = [:]
    private var displayRequest: UInt32?
    private var displayIsReady = false
    private var decoder: UInt64?
    private var root: UInt32?
    private var rootDomain: ConnectionFrameDomain = .none
    private var renderedFrame: UInt32?
    private var terminalMessage: String?
    private var restoredOwner: UInt64?
    private var lastTarget: ConnectionRoute = .unknown
    private var preparedToken = Data()
    private var protectedHandoff = false

    public init() {}
    public mutating func begin(generation: UInt64) {
        self = Self(); self.generation = generation
    }
    public mutating func advertise(flags: UInt16, authenticated: Bool, generation: UInt64) -> Data? {
        guard generation == self.generation, generation != 0, authenticated, !enabled else { return nil }
        guard flags & ConnectionControlProtocol.advertisementFlag != 0 else { phase = .unsupportedHost; return nil }
        protectedHandoff = flags & ConnectionControlProtocol.protectedHandoffFlag != 0
        enabled = true; phase = pending == nil ? .checking : .waitingDisplay
        return refresh()
    }
    public func refresh() -> Data? {
        enabled ? try? ConnectionHello.optIn(revision: snapshot?.revision ?? 0, protectedHandoff: protectedHandoff).encode() : nil
    }
    @discardableResult public mutating func receive(_ value: ConnectionControlState, generation: UInt64, now: TimeInterval) -> Bool {
        tick(now: now)
        guard enabled, generation == self.generation, value.phase == .snapshot,
              snapshot == nil || snapshot?.owner == value.owner,
              value.revision >= (snapshot?.revision ?? 0) else { return false }
        // Equal revisions refresh a heartbeat, but may not change its contents.
        guard snapshot?.revision != value.revision || snapshot == value else { return false }
        if let pending, let route = pending.rollbackRoute {
            guard pending.replacement == generation, value.current == route,
                  value.owner != pending.request.owner else { return false }
        }
        snapshot = value; snapshotAt = now; needsRefresh = false
        if value.hostState != .failed || value.current != actualRoute || value.stateReason == .stoppedOnPC {
            restoredOwner = nil
        }
        resultSnapshots[value.revision] = value
        if resultSnapshots.count > 32, let oldest = resultSnapshots.keys.min() { resultSnapshots.removeValue(forKey: oldest) }
        if pending == nil && phase != .failed {
            actualRoute = value.current
            if value.stateReason == .permissionDenied {
                phase = .declined; issue = .permissionDenied
                if terminalMessage == nil { terminalMessage = ConnectionReason.permissionDenied.text(target: lastTarget) }
            }
            else if phase == .permissionRequired && !value.allowed { }
            else { phase = .ready; issue = nil }
        }
        return true
    }
    public mutating func select(_ target: ConnectionRoute, askPC: Bool = false, now: TimeInterval) -> ConnectionSelectRequest? {
        tick(now: now)
        guard enabled, pending == nil, !offersReconnect, let snapshot, !needsRefresh,
              target != .unknown, routeSelectionReady, now >= snapshotAt,
              now - snapshotAt < ConnectionControlProtocol.lease, nextTransaction != UInt64.max else { return nil }
        if target != snapshot.current {
            guard askPC || snapshot.allowed else { return nil }
            if !askPC {
                let availability = target == .usb ? snapshot.usb : snapshot.wifi
                guard availability == .available || target == .usb && availability == .detectedUnverified else { return nil }
            }
        }
        nextTransaction += 1
        let request = ConnectionSelectRequest(target: target, transaction: nextTransaction, owner: snapshot.owner, revision: snapshot.revision)
        pending = Pending(request: request, originGeneration: generation, started: now,
            protectedUSB: protectedHandoff && snapshot.current == .wifi && target == .usb)
        lastTarget = target
        inputBlocked = true; phase = .checking; issue = nil; terminalMessage = nil
        resetPresentation(); return request
    }
    mutating func deferRequestSend() {
        guard pending?.accepted == false else { return }
        pending?.sent = false
        if pending?.request.target == .usb { phase = .preparingUSB }
    }
    mutating func markRequestSent(transaction: UInt64, now: TimeInterval) -> Bool {
        tick(now: now)
        guard let pending, !pending.sent, pending.request.transaction == transaction,
              !needsRefresh, snapshot?.revision == pending.request.revision else { return false }
        self.pending?.started = now; self.pending?.sent = true; phase = .checking
        return true
    }
    @discardableResult mutating func preparing(_ value: ConnectionControlState, generation: UInt64, now: TimeInterval) -> Bool {
        tick(now: now)
        guard enabled, generation == self.generation, let pending, !pending.accepted,
              pending.sent, !pending.rollingBack,
              value.owner == pending.request.owner, value.revision == pending.request.revision,
              value.transaction == pending.request.transaction,
              value.phase == (pending.request.target == .usb ? .prepareUSB : .prepareWiFi),
              preparedToken.isEmpty || preparedToken == value.token else { return false }
        preparedToken = value.token
        phase = value.phase == .prepareUSB ? .preparingUSB : .checking; return true
    }
    mutating func markUSBProbeAnswered(generation: UInt64, now: TimeInterval) -> Bool {
        tick(now: now)
        guard let pending, pending.protectedUSB, pending.sent, !pending.accepted,
              !pending.probeAnswered, !pending.rollingBack, pending.originGeneration == generation,
              self.generation == generation, !preparedToken.isEmpty else { return false }
        self.pending?.probeAnswered = true
        return true
    }
    @discardableResult public mutating func receive(_ value: ConnectionSelectResult, generation: UInt64, now: TimeInterval) -> Bool {
        tick(now: now)
        guard enabled, generation == self.generation, var operation = pending,
              operation.sent,
              value.transaction == operation.request.transaction, value.originOwner == operation.request.owner,
              value.target == operation.request.target, value.reason != .duplicateTransaction,
              let authority = resultSnapshots[value.revision], authority.owner == value.routeOwner || value.routeOwner == 0,
              snapshot?.revision == value.revision, authority.current == value.current,
              authority.hostState == value.hostState || value.status == .accepted &&
                (authority.hostState == .ready || authority.hostState == .preflighting) else { return false }
        if let route = operation.rollbackRoute {
            guard value.status == .failed, operation.replacement == generation, value.current == route,
                  value.token == operation.token, value.routeOwner != operation.request.owner else { return false }
            if value.reason == .stoppedOnPC { cancel(reason: value.reason) }
            else {
                issue = value.reason
                pending?.rollbackFailure = value.reason
                completeRollbackIfPresented(now: now)
            }
            return true
        }
        if operation.accepted {
            guard value.token == operation.token, value.status == .completed || value.status == .failed else { return false }
        } else if generation != operation.originGeneration { return false }
        switch value.status {
        case .accepted:
            guard !preparedToken.isEmpty, value.token == preparedToken,
                  !operation.protectedUSB || operation.probeAnswered else { return false }
            operation.accepted = true; operation.token = value.token; pending = operation
            phase = .switching; inputBlocked = true
        case .completed:
            guard operation.accepted, operation.replacement == generation, value.routeOwner != operation.request.owner,
                  value.current == operation.request.target, operation.completed == nil else { return false }
            operation.completed = value; operation.completedAt = now; pending = operation
            phase = displayIsReady ? .waitingFrame : .waitingDisplay
            completeIfPresented(now: now)
        case .alreadyActive:
            guard !operation.accepted, value.current == operation.request.target else { return false }
            pending = nil; inputBlocked = false; phase = .ready
            terminalMessage = "Already using " + value.current.label
        case .permissionRequired:
            guard !operation.accepted else { return false }
            pending = nil; inputBlocked = false; phase = .permissionRequired; issue = .permissionMissing
        case .denied, .unavailable, .busy:
            guard !operation.accepted else { return false }
            pending = nil; inputBlocked = false; phase = .declined; issue = value.reason
            terminalMessage = value.reason.text(target: operation.request.target)
            needsRefresh = value.reason == .staleRevision
        case .failed:
            if operation.protectedUSB && !operation.accepted {
                guard operation.probeAnswered, !preparedToken.isEmpty, value.token == preparedToken else { return false }
            }
            if !beginRollback(reason: value.reason, now: now) { cancel(reason: value.reason) }
        }
        return true
    }
    @discardableResult public mutating func bindReplacement(generation: UInt64, route: ConnectionRoute, authenticated: Bool, now: TimeInterval) -> Bool {
        tick(now: now)
        guard var operation = pending, operation.accepted, !operation.rollingBack, operation.replacement == nil, authenticated,
              generation != 0, generation != operation.originGeneration, route == operation.request.target else { return false }
        operation.replacement = generation; pending = operation; self.generation = generation
        enabled = false; snapshot = nil; resultSnapshots.removeAll(); nextTransaction = 0
        phase = .waitingDisplay; actualRoute = route; resetPresentation(); return true
    }
    mutating func beginRollback(reason: ConnectionReason, now: TimeInterval) -> Bool {
        guard var operation = pending,
              !operation.rollingBack, reason != .stoppedOnPC,
              now >= operation.started else { return false }
        let route: ConnectionRoute
        let budget: TimeInterval
        if operation.protectedUSB && operation.probeAnswered {
            route = .wifi
            budget = operation.accepted ? ConnectionControlProtocol.rollbackWait : ConnectionControlProtocol.preflightWait
        } else if operation.accepted && operation.request.target == .wifi && reason != .teardownFailed {
            route = .usb
            budget = ConnectionControlProtocol.usbRollbackWait
        } else { return false }
        let token = operation.accepted ? operation.token : preparedToken
        guard !token.isEmpty, now < operation.started + budget else { return false }
        operation.rollbackRoute = route; operation.token = token
        operation.completed = nil; operation.completedAt = nil
        pending = operation
        issue = reason; resetRollbackAttempt()
        return true
    }
    mutating func resetRollbackAttempt() {
        guard pending?.rollingBack == true else { return }
        pending?.replacement = nil; pending?.rollbackReadyAt = nil; pending?.rollbackFailure = nil
        enabled = false; snapshot = nil; resultSnapshots.removeAll(); nextTransaction = 0
        phase = .waitingPeer; actualRoute = .unknown; resetPresentation()
    }
    mutating func bindRollback(generation: UInt64, route: ConnectionRoute, authenticated: Bool, now: TimeInterval) -> Bool {
        tick(now: now)
        guard let pending, pending.rollbackRoute == route, pending.replacement == nil, authenticated,
              generation != 0, generation != pending.originGeneration else { return false }
        self.pending?.replacement = generation; self.generation = generation
        phase = .waitingDisplay
        return true
    }
    var hasRollbackSnapshot: Bool {
        guard let pending, let route = pending.rollbackRoute, pending.replacement == generation,
              !needsRefresh, let snapshot else { return false }
        return snapshot.current == route && snapshot.hostState != .idle && snapshot.stateReason != .stoppedOnPC
    }
    mutating func noteRollbackReady(now: TimeInterval) {
        guard hasRollbackSnapshot else { return }
        if pending?.rollbackReadyAt == nil { pending?.rollbackReadyAt = now }
        phase = .waitingFrame
    }
    mutating func invalidateRollbackDisplay() {
        guard pending?.rollingBack == true else { return }
        resetPresentation()
    }
    mutating func waitingForPeer() { if pending?.accepted == true { phase = .waitingPeer; actualRoute = .unknown } }
    public mutating func expectDisplay(request: UInt32, decoder: UInt64, generation: UInt64) {
        guard pending?.replacement == generation, generation == self.generation else { return }
        displayRequest = request; self.decoder = decoder; displayIsReady = false
        root = nil; renderedFrame = nil; rootDomain = .none
    }
    public mutating func displayReady(request: UInt32, generation: UInt64, now: TimeInterval? = nil) {
        let time = now ?? lastTime ?? snapshotAt
        tick(now: time)
        guard generation == self.generation, pending?.replacement == generation, displayRequest == request else { return }
        if pending?.rollingBack == true {
            guard hasRollbackSnapshot else { return }
            noteRollbackReady(now: time)
        }
        displayIsReady = true; if pending?.completed != nil { phase = .waitingFrame }
        completeIfPresented(now: time)
    }
    public mutating func observeIDR(sequence: UInt32, domain: ConnectionFrameDomain, decoder: UInt64, generation: UInt64) {
        guard pending?.replacement == generation, self.generation == generation, self.decoder == decoder, domain != .none else { return }
        root = sequence; rootDomain = domain; renderedFrame = nil
    }
    mutating func invalidateDecodeRoot(generation: UInt64) {
        guard generation == self.generation, pending != nil else { return }
        root = nil; renderedFrame = nil; inputBlocked = true
    }
    public mutating func rendered(sequence: UInt32, domain: ConnectionFrameDomain, decoder: UInt64, generation: UInt64, now: TimeInterval) {
        tick(now: now)
        guard pending?.replacement == generation, self.generation == generation, self.decoder == decoder,
              let root, domain == rootDomain, MirrorControlCodec.sequenceAtOrAfter(sequence, root) else { return }
        renderedFrame = sequence; completeIfPresented(now: now)
    }
    private mutating func completeIfPresented(now: TimeInterval) {
        if pending?.rollingBack == true { completeRollbackIfPresented(now: now); return }
        guard let operation = pending, let completed = operation.completed, displayIsReady,
              completed.frameDomain == rootDomain, let root, let renderedFrame,
              MirrorControlCodec.sequenceAtOrAfter(renderedFrame, completed.firstFrame),
              MirrorControlCodec.sequenceAtOrAfter(renderedFrame, root), !deadlineExpired(now: now) else { return }
        actualRoute = completed.current; pending = nil; phase = .completed; inputBlocked = false
        issue = nil; terminalMessage = nil; offersReconnect = false
    }
    private mutating func completeRollbackIfPresented(now: TimeInterval) {
        guard let pending, let route = pending.rollbackRoute, let readyAt = pending.rollbackReadyAt,
              hasRollbackSnapshot, displayIsReady, root != nil, renderedFrame != nil,
              pending.rollbackFailure != nil ||
                route == .wifi && now >= readyAt + ConnectionControlProtocol.presentationWait else { return }
        issue = pending.rollbackFailure ?? issue
        restoredOwner = snapshot?.hostState == .failed ? snapshot?.owner : nil
        self.pending = nil; actualRoute = route; phase = .declined; inputBlocked = false
        terminalMessage = "\(pending.request.target.label) switch failed. Reconnected over \(route.label)."
    }

    var routeSelectionReady: Bool {
        guard let snapshot else { return false }
        if snapshot.hostState == .ready { return true }
        // A restored owner can keep publishing the last failed operation.
        return snapshot.hostState == .failed && snapshot.owner == restoredOwner &&
            snapshot.current == actualRoute && snapshot.stateReason != .stoppedOnPC
    }

    var operationOutcome: String? {
        guard pending == nil else { return nil }
        return terminalMessage ?? (phase == .declined ? message : nil)
    }
    func shouldTryRollbackAfterTimeout(now: TimeInterval) -> Bool {
        guard let pending, pending.accepted, !pending.rollingBack,
              pending.completed == nil else { return false }
        if pending.request.target == .wifi { return now >= pending.started + ConnectionControlProtocol.wifiOutcomeWait }
        return pending.protectedUSB && now >= pending.started + ConnectionControlProtocol.outcomeWait
    }
    private func deadlineExpired(now: TimeInterval) -> Bool {
        guard let operation = pending, operation.sent else { return false }
        if operation.rollingBack {
            if operation.rollbackRoute == .usb {
                return now >= operation.started + ConnectionControlProtocol.usbRollbackWait
            }
            if let readyAt = operation.rollbackReadyAt { return now >= readyAt + ConnectionControlProtocol.presentationWait }
            return now >= operation.started + ConnectionControlProtocol.rollbackWait
        }
        if !operation.accepted { return now >= operation.started + ConnectionControlProtocol.preflightWait }
        if let completedAt = operation.completedAt { return now >= min(completedAt + 5, operation.started + 80) }
        let budget = operation.request.target == .wifi ? ConnectionControlProtocol.wifiOutcomeWait : ConnectionControlProtocol.outcomeWait
        return now >= operation.started + budget
    }
    public mutating func tick(now: TimeInterval) {
        let backwards = lastTime.map { now < $0 } ?? false; lastTime = now
        if backwards { needsRefresh = true; if pending != nil { cancel(reason: .evidenceStale) }; return }
        if snapshot != nil && now - snapshotAt >= ConnectionControlProtocol.lease { needsRefresh = true }
        if pending?.rollingBack == true { completeRollbackIfPresented(now: now) }
        guard let operation = pending, deadlineExpired(now: now) else { return }
        let text = operation.completedAt == nil ? "Connection change timed out" : "No picture on the new connection"
        cancel(reason: .deadlineExceeded); terminalMessage = text
    }
    public mutating func cancel(reason: ConnectionReason) {
        pending = nil; actualRoute = .unknown; phase = .failed; inputBlocked = true; issue = reason; offersReconnect = true
        terminalMessage = reason == .connectionLost || reason == .stoppedOnPC ? reason.text(target: .unknown) : "Connection change failed"
        resetPresentation()
    }
    mutating func preflightFailed(reason: ConnectionReason) {
        guard let pending, !pending.accepted else { cancel(reason: reason); return }
        // Once 78 is sent there is no cancellation handshake. Keep correlation
        // and the input fence until a host terminal result or the 15-second cap.
        guard !pending.sent else { return }
        terminalMessage = reason.text(target: pending.request.target)
        self.pending = nil; phase = .declined; inputBlocked = false; issue = reason
        resetPresentation()
    }
    private mutating func resetPresentation() { displayRequest = nil; decoder = nil; displayIsReady = false; root = nil; rootDomain = .none; renderedFrame = nil; preparedToken = Data() }
    public var recommendationText: String {
        guard let snapshot else { return "USB availability not checked" }
        guard !needsRefresh else { return "Connection recommendation unavailable" }
        if snapshot.usb == .detectedUnverified { return "USB cable detected, not verified" }
        switch snapshot.recommended {
        case .usb: return "USB recommended"
        case .wifi: return "Wi-Fi/Tailscale recommended"
        case .unknown: return "Connection recommendation unavailable"
        }
    }
    public func disabledReason(for route: ConnectionRoute, hasWifiEndpoint: Bool) -> String? {
        if !enabled { return "Connection recommendation unavailable" }
        if pending != nil { return message }
        if offersReconnect { return message }
        if needsRefresh { return "Refresh connection status" }
        guard let snapshot else { return "USB availability not checked" }
        if route == snapshot.current { return nil }
        if route == .wifi && !hasWifiEndpoint { return "Wi-Fi listener is unavailable on PC" }
        if !snapshot.allowed { return (issue ?? .permissionMissing).text(target: route) }
        let reason = route == .usb ? snapshot.usbReason : snapshot.wifiReason
        let availability = route == .usb ? snapshot.usb : snapshot.wifi
        return availability == .available || route == .usb && availability == .detectedUnverified ? nil : reason.text(target: route)
    }
    public var message: String {
        if let terminalMessage { return terminalMessage }
        switch phase {
        case .checking: return snapshot == nil ? "USB availability not checked" : "Checking connection..."
        case .preparingUSB: return "Preparing USB..."
        case .permissionRequired: return "Allow connection changes on the PC"
        case .switching: return pending?.request.target == .usb ? "Switching to USB..." : "Switching to Wi-Fi..."
        case .waitingPeer:
            if let route = pending?.rollbackRoute { return "Reconnecting over " + route.label + "..." }
            return pending?.request.target == .usb ? "Connecting over USB..." : "Connecting over Wi-Fi..."
        case .waitingDisplay: return "Preparing display..."
        case .waitingFrame: return "Waiting for picture..."
        case .failed: return "Connection change failed"
        case .declined: return issue?.text(target: lastTarget) ?? "Connection check failed. Current connection kept."
        case .unsupportedHost: return "Connection recommendation unavailable"
        case .ready, .completed:
            return actualRoute == .unknown ? recommendationText : "Connected over " + actualRoute.label
        }
    }
}
