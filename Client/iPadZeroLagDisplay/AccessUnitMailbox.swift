import Foundation

enum AccessUnitDropReason: Equatable {
    case invalid
    case replaced
    case expired
    case waitingForIDR
    case decodeFailed
    case invalidated
}

final class AccessUnitOwner {
    private let lock = NSLock()
    private var storage: NSData?
    private var releaseHandler: (() -> Void)?

    init(data: Data, onRelease: (() -> Void)? = nil) {
        // The immutable Foundation bridge owns the received allocation and
        // exposes a stable bytes pointer without forcing a second AU copy.
        storage = data as NSData
        releaseHandler = onRelease
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        guard let storage else { return Data() }
        return Data(referencing: storage)
    }

    func retainedDataBacking() -> NSData? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage?.length ?? 0
    }

    func release() {
        let handler: (() -> Void)?
        lock.lock()
        guard storage != nil else {
            lock.unlock()
            return
        }
        storage = nil
        handler = releaseHandler
        releaseHandler = nil
        lock.unlock()
        handler?()
    }

    deinit { release() }
}

struct AccessUnit {
    let owner: AccessUnitOwner
    let sequence: UInt32
    let sessionGeneration: UInt64
    let isIDR: Bool
    let receivedAt: TimeInterval
    let isLengthPrefixed: Bool

    init(
        owner: AccessUnitOwner,
        sequence: UInt32,
        sessionGeneration: UInt64,
        isIDR: Bool,
        receivedAt: TimeInterval,
        isLengthPrefixed: Bool = false
    ) {
        self.owner = owner
        self.sequence = sequence
        self.sessionGeneration = sessionGeneration
        self.isIDR = isIDR
        self.receivedAt = receivedAt
        self.isLengthPrefixed = isLengthPrefixed
    }
}

final class DecodeSubmissionLifetime {
    let owner: AccessUnitOwner
    let sequence: UInt32
    let decodeStartedAt: TimeInterval
    private let lock = NSLock()
    private var finished = false

    init(
        owner: AccessUnitOwner,
        sequence: UInt32,
        decodeStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.owner = owner
        self.sequence = sequence
        self.decodeStartedAt = decodeStartedAt
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        owner.release()
    }

    deinit { finish() }
}

/// Immutable admission identity captured by queued work and its VT callback.
struct DecodeTicket {
    let unit: AccessUnit
    let sessionGeneration: UInt64
    let chainGeneration: UInt64
    let submissionID: UInt64
}

enum DecodeCompletionDisposition: Equatable {
    case deliver
    case failed
    case stale
}

struct DecodeCompletion {
    let disposition: DecodeCompletionDisposition
    let next: DecodeTicket?
}

/// One explicit in-flight submission plus one replaceable pending access unit.
/// Every state transition and generation check occurs under this one lock.
final class AccessUnitMailbox {
    typealias Clock = () -> TimeInterval
    typealias DropHandler = (UInt32, UInt64, AccessUnitDropReason) -> Void

    private let lock = NSLock()
    private let maximumAge: TimeInterval
    private let clock: Clock
    private let onRecoveryNeeded: () -> Void
    private let onDrop: DropHandler
    private var accepting = false
    private var sessionGeneration: UInt64 = 0
    private var nextSubmissionID: UInt64 = 0
    private var nextChainGeneration: UInt64 = 0
    private var activeChainGeneration: UInt64 = 0
    private var waitingForIDRStorage = true
    private var recoveryNotified = false
    private var inFlight: DecodeTicket?
    private var pending: AccessUnit?

    init(
        maximumAge: TimeInterval = 0.00833,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        onRecoveryNeeded: @escaping () -> Void = {},
        onDrop: @escaping DropHandler = { _, _, _ in }
    ) {
        precondition(maximumAge > 0)
        self.maximumAge = maximumAge
        self.clock = clock
        self.onRecoveryNeeded = onRecoveryNeeded
        self.onDrop = onDrop
    }

    var retainedOwnerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return (inFlight == nil ? 0 : 1) + (pending == nil ? 0 : 1)
    }

    var waitingForIDR: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingForIDRStorage
    }

    func beginSession(generation: UInt64) {
        var releases: [(AccessUnit, AccessUnitDropReason)] = []
        lock.lock()
        collectRetainedLocked(reason: .invalidated, into: &releases)
        accepting = true
        sessionGeneration = generation
        nextSubmissionID &+= 1
        nextChainGeneration &+= 1
        activeChainGeneration = 0
        waitingForIDRStorage = true
        recoveryNotified = false
        lock.unlock()
        release(releases)
    }

    /// A returned ticket is the only item that should be scheduled. Nil means
    /// the owner is pending, rejected, or invalidated.
    func publish(_ unit: AccessUnit) -> DecodeTicket? {
        var releases: [(AccessUnit, AccessUnitDropReason)] = []
        var requestRecovery = false
        var result: DecodeTicket?

        lock.lock()
        if !accepting || unit.owner.count == 0 {
            releases.append((unit, accepting ? .invalid : .invalidated))
        } else if waitingForIDRStorage && !unit.isIDR {
            releases.append((unit, .waitingForIDR))
            requestRecovery = requestRecoveryLocked()
        } else if inFlight == nil {
            if unit.isIDR { enterRecoveryLocked() }
            result = makeTicketLocked(unit)
            inFlight = result
        } else if let replaced = pending {
            pending = nil
            releases.append((replaced, .replaced))
            if !replaced.isIDR {
                enterRecoveryLocked()
                requestRecovery = requestRecoveryLocked()
            }
            if waitingForIDRStorage && !unit.isIDR {
                releases.append((unit, .waitingForIDR))
                requestRecovery = requestRecoveryLocked() || requestRecovery
            } else {
                if unit.isIDR { enterRecoveryLocked() }
                pending = unit
            }
        } else {
            if unit.isIDR { enterRecoveryLocked() }
            pending = unit
        }
        lock.unlock()

        release(releases)
        if requestRecovery { onRecoveryNeeded() }
        return result
    }

    func isCurrent(_ ticket: DecodeTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting &&
            ticket.sessionGeneration == sessionGeneration &&
            inFlight?.submissionID == ticket.submissionID
    }

    /// Expires a queued ticket before VideoToolbox submission. Nil means the
    /// ticket is still fresh (or was already made stale by another session).
    func expireIfNeeded(_ ticket: DecodeTicket) -> DecodeCompletion? {
        var releases: [(AccessUnit, AccessUnitDropReason)] = []
        var requestRecovery = false
        lock.lock()
        guard accepting,
              ticket.sessionGeneration == sessionGeneration,
              inFlight?.submissionID == ticket.submissionID else {
            lock.unlock()
            return DecodeCompletion(disposition: .stale, next: nil)
        }
        let age = clock() - ticket.unit.receivedAt
        guard age < 0 || age > maximumAge else {
            lock.unlock()
            return nil
        }
        inFlight = nil
        releases.append((ticket.unit, .expired))
        enterRecoveryLocked()
        requestRecovery = requestRecoveryLocked()
        if let dependent = pending, !dependent.isIDR {
            pending = nil
            releases.append((dependent, .decodeFailed))
        }
        let next = drainPendingLocked(
            releases: &releases,
            requestRecovery: &requestRecovery)
        lock.unlock()
        release(releases)
        if requestRecovery { onRecoveryNeeded() }
        return DecodeCompletion(disposition: .failed, next: next)
    }

    /// Only successful decode of the current IDR exits recovery. The callback
    /// also atomically selects the next pending item.
    func complete(_ ticket: DecodeTicket, succeeded: Bool) -> DecodeCompletion {
        var releases: [(AccessUnit, AccessUnitDropReason)] = []
        var requestRecovery = false
        var disposition: DecodeCompletionDisposition = .stale

        lock.lock()
        guard accepting,
              ticket.sessionGeneration == sessionGeneration,
              inFlight?.submissionID == ticket.submissionID else {
            lock.unlock()
            return DecodeCompletion(disposition: .stale, next: nil)
        }
        inFlight = nil

        if succeeded {
            if ticket.unit.isIDR {
                activeChainGeneration = ticket.chainGeneration
                waitingForIDRStorage = false
                recoveryNotified = false
                disposition = .deliver
            } else if ticket.chainGeneration == activeChainGeneration {
                disposition = .deliver
            }
        } else {
            disposition = .failed
            releases.append((ticket.unit, .decodeFailed))
            enterRecoveryLocked()
            requestRecovery = requestRecoveryLocked()
            if let dependent = pending, !dependent.isIDR {
                pending = nil
                releases.append((dependent, .decodeFailed))
            }
        }

        let next = drainPendingLocked(
            releases: &releases,
            requestRecovery: &requestRecovery)
        lock.unlock()

        release(releases)
        if requestRecovery { onRecoveryNeeded() }
        return DecodeCompletion(disposition: disposition, next: next)
    }

    func invalidate() {
        var releases: [(AccessUnit, AccessUnitDropReason)] = []
        lock.lock()
        accepting = false
        sessionGeneration &+= 1
        collectRetainedLocked(reason: .invalidated, into: &releases)
        waitingForIDRStorage = true
        recoveryNotified = false
        lock.unlock()
        release(releases)
    }

    private func makeTicketLocked(_ unit: AccessUnit) -> DecodeTicket {
        nextSubmissionID &+= 1
        let chain: UInt64
        if unit.isIDR {
            nextChainGeneration &+= 1
            chain = nextChainGeneration
        } else {
            chain = activeChainGeneration
        }
        return DecodeTicket(
            unit: unit,
            sessionGeneration: sessionGeneration,
            chainGeneration: chain,
            submissionID: nextSubmissionID)
    }

    private func drainPendingLocked(
        releases: inout [(AccessUnit, AccessUnitDropReason)],
        requestRecovery: inout Bool
    ) -> DecodeTicket? {
        while let candidate = pending {
            pending = nil
            let age = clock() - candidate.receivedAt
            if age < 0 || age > maximumAge {
                releases.append((candidate, .expired))
                enterRecoveryLocked()
                requestRecovery = requestRecoveryLocked() || requestRecovery
                continue
            }
            if waitingForIDRStorage && !candidate.isIDR {
                releases.append((candidate, .waitingForIDR))
                requestRecovery = requestRecoveryLocked() || requestRecovery
                continue
            }
            if candidate.isIDR { enterRecoveryLocked() }
            let ticket = makeTicketLocked(candidate)
            inFlight = ticket
            return ticket
        }
        return nil
    }

    private func enterRecoveryLocked() {
        waitingForIDRStorage = true
    }

    private func requestRecoveryLocked() -> Bool {
        guard !recoveryNotified else { return false }
        recoveryNotified = true
        return true
    }

    private func collectRetainedLocked(
        reason: AccessUnitDropReason,
        into releases: inout [(AccessUnit, AccessUnitDropReason)]
    ) {
        if let ticket = inFlight {
            releases.append((ticket.unit, reason))
            inFlight = nil
        }
        if let pending {
            releases.append((pending, reason))
            self.pending = nil
        }
    }

    private func release(_ units: [(AccessUnit, AccessUnitDropReason)]) {
        for (unit, reason) in units {
            unit.owner.release()
            onDrop(unit.sequence, unit.sessionGeneration, reason)
        }
    }
}
