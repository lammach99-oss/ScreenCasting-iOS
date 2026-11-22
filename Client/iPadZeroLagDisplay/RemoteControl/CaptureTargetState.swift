import Foundation

/// Network-owner value state. Session UUID fences callbacks even when a route keeps the same wire generation.
public struct CaptureTargetState: Equatable {
    public struct Pending: Equatable {
        public let request: CaptureTargetRequest
        public let entry: CaptureTargetEntry
        let previousCatalogue: CaptureTargetCatalogue
        fileprivate(set) var acceptance: CaptureTargetResult? = nil
        public var accepted: Bool { acceptance != nil }
    }
    public private(set) var session = UUID()
    public private(set) var generation: UInt64 = 0
    public private(set) var enabled = false
    public private(set) var catalogue: CaptureTargetCatalogue?
    public private(set) var pending: Pending?
    public private(set) var applied: CaptureTargetResult?
    public private(set) var issue: CaptureTargetStatus?
    public private(set) var unknownOutcome = false
    public private(set) var inputBlocked = false
    public private(set) var needsCatalogueRefresh = false
    public private(set) var listUnavailable = false
    private var retainedPresentation: CaptureTargetResult?
    public private(set) var awaitingReattachIDR = false
    private var owner: UInt64?
    private var nextTransaction: UInt64 = 0
    private var latestRevision: UInt64 = 0
    private var selectionSuppressed = false
    private var revisions: [UInt64: CaptureTargetCatalogue] = [:]
    private var lastReadyCatalogue: CaptureTargetCatalogue?

    public init() {}
    public mutating func begin(generation: UInt64) {
        self = Self(); self.generation = generation
    }
    /// A route changes the frame sequence domain but not the authenticated owner's consumed transactions.
    public mutating func retireRoute(preserveAppliedSource: Bool = false) {
        let generation = self.generation, enabled = self.enabled, nextTransaction = self.nextTransaction, owner = self.owner
        let latestRevision = self.latestRevision
        let previous = preserveAppliedSource ? applied : nil
        let catalogue = self.catalogue
        let lastReadyCatalogue = self.lastReadyCatalogue
        self = Self(); self.generation = generation; self.enabled = enabled
        self.nextTransaction = nextTransaction; self.owner = owner; inputBlocked = enabled
        self.latestRevision = latestRevision
        self.lastReadyCatalogue = lastReadyCatalogue
        unknownOutcome = enabled; needsCatalogueRefresh = enabled
        if let previous {
            self.catalogue = catalogue
            applied = CaptureTargetResult(status: previous.status, state: previous.state, kind: previous.kind,
                transaction: previous.transaction, owner: previous.owner, revision: previous.revision,
                currentId: previous.currentId, epoch: previous.epoch, source: previous.source, firstFrame: 0)
            awaitingReattachIDR = true; unknownOutcome = false
        }
    }
    public mutating func advertise(flags: UInt16, generation: UInt64) -> Data? {
        guard generation != 0, generation == self.generation, !enabled,
              flags & CaptureTargetProtocol.advertisementFlag != 0 else { return nil }
        enabled = true
        return CaptureTargetProtocol.hello()
    }
    public func refresh(session: UUID) -> Data? {
        guard session == self.session, enabled else { return nil }
        return CaptureTargetProtocol.hello(knownRevision: needsCatalogueRefresh ? 0 : catalogue?.revision ?? 0)
    }
    @discardableResult public mutating func receiveCatalogue(_ value: CaptureTargetCatalogue, session: UUID,
                                                               preservingSuspendedPresentation: Bool = false) -> Bool {
        guard session == self.session, enabled, owner == nil || owner == value.owner,
              value.revision > latestRevision else { return false }
        latestRevision = value.revision
        if preservingSuspendedPresentation, pending == nil, let applied,
           value.epoch == applied.epoch, value.state != 1,
           value.currentId == 0 || value.currentId == applied.currentId,
           value.entries.contains(where: { $0.id == applied.currentId && $0.kind == applied.kind }) {
            // A temporary unavailable snapshot has no replacement authority. Keep the
            // confirmed UI/picture, but consume its revision to reject stale refreshes.
            return false
        }
        owner = value.owner; catalogue = value; revisions[value.revision] = value; needsCatalogueRefresh = false
        if value.state == 1 { lastReadyCatalogue = value }
        // Terminal publication precedes the result. Keep recent revisions to resolve it without regressing the UI.
        if pending == nil { revisions = [value.revision: value] }
        if pending == nil { selectionSuppressed = false }
        listUnavailable = false
        if let retained = retainedPresentation, pending == nil {
            if value.currentId != retained.currentId || !value.entries.contains(where: { $0.id == retained.currentId && $0.kind == retained.kind }) {
                retainedPresentation = nil
            } else if value.state == 1, value.epoch >= retained.epoch {
                applied = CaptureTargetResult(status: retained.status, state: 1, kind: retained.kind,
                    transaction: retained.transaction, owner: retained.owner, revision: value.revision,
                    currentId: retained.currentId, epoch: value.epoch, source: retained.source,
                    firstFrame: value.epoch == retained.epoch ? retained.firstFrame : 0)
                retainedPresentation = nil; awaitingReattachIDR = true
                unknownOutcome = false; inputBlocked = true
                issue = retained.status == .applied ? nil : retained.status
            }
        }
        return true
    }
    public mutating func select(_ id: UInt64, catalogue expected: CaptureTargetCatalogue, session: UUID) -> CaptureTargetRequest? {
        guard session == self.session, canSelect, !needsCatalogueRefresh,
              let catalogue, catalogue == expected, catalogue.state == 1, catalogue.allowed,
              let entry = catalogue.entries.first(where: { $0.id == id }), nextTransaction != UInt64.max else { return nil }
        retainedPresentation = nil; awaitingReattachIDR = false
        nextTransaction += 1
        let request = CaptureTargetRequest(transaction: nextTransaction, owner: catalogue.owner,
                                          revision: catalogue.revision, targetId: id)
        pending = Pending(request: request, entry: entry, previousCatalogue: catalogue)
        applied = nil; issue = nil; unknownOutcome = false
        inputBlocked = true
        return request
    }
    @discardableResult public mutating func receiveResult(_ value: CaptureTargetResult, session: UUID) -> Bool {
        guard session == self.session, enabled, let pending,
              value.transaction == pending.request.transaction, value.owner == pending.request.owner,
              value.revision >= pending.request.revision else { return false }
        if value.status == .accepted {
            guard value.revision == pending.request.revision else { return false }
            if !pending.accepted { self.pending?.acceptance = value }
            selectionSuppressed = true
            return true
        }
        self.pending = nil
        issue = value.status == .applied ? nil : value.status
        needsCatalogueRefresh = value.status == .stale || value.status == .busy || value.status == .notAvailable || value.status == .timedOut
        guard let matching = revisions[value.revision], matching.owner == value.owner,
              matching.state == value.state, matching.currentId == value.currentId,
              matching.entries.first(where: { $0.id == value.currentId })?.kind == value.kind else {
            issue = .failed; needsCatalogueRefresh = true; return true
        }
        selectionSuppressed = false
        if value.status == .applied {
            guard matching.state == 1, matching.epoch == value.epoch, value.kind == pending.entry.kind else {
                issue = .failed; needsCatalogueRefresh = true; return true
            }
            applied = value
        } else if let acceptance = pending.acceptance,
                  value.kind != nil, value.currentId != 0,
                  acceptance.epoch != 0, acceptance.source != 0,
                  value.epoch != 0, value.epoch != acceptance.epoch, value.source != 0,
                  value.revision > pending.request.revision, matching.state == 1, matching.epoch == value.epoch {
            // Keep the failure in issue and record the attested restored publication
            // as the local Applied anchor for decoding and scoped recovery.
            applied = CaptureTargetResult(status: .applied, state: value.state, kind: value.kind,
                transaction: value.transaction, owner: value.owner, revision: value.revision,
                currentId: value.currentId, epoch: value.epoch, source: value.source, firstFrame: value.firstFrame)
            needsCatalogueRefresh = false
        }
        revisions = catalogue.map { [$0.revision: $0] } ?? [:]
        return true
    }
    @discardableResult public mutating func expire(transaction: UInt64, session: UUID) -> Bool {
        guard session == self.session, pending?.request.transaction == transaction else { return false }
        pending = nil; applied = nil; unknownOutcome = true; inputBlocked = true; needsCatalogueRefresh = true
        return true
    }
    /// A terminal rejection can confirm that the source that presented the rollback is still current.
    mutating func restoreRollbackPresentation(_ result: CaptureTargetResult, previous: CaptureTargetCatalogue,
                                              firstFrame: UInt32) -> Bool {
        guard pending == nil, applied == nil, issue == result.status, result.state == 1,
              let kind = result.kind, result.owner == previous.owner, result.currentId == previous.currentId,
              result.epoch == previous.epoch, result.source != 0,
              let catalogue, catalogue.revision == result.revision, catalogue.epoch == result.epoch,
              catalogue.state == 1, catalogue.currentId == result.currentId,
              previous.entries.contains(where: { $0.id == result.currentId && $0.kind == kind }) else { return false }
        applied = CaptureTargetResult(status: .applied, state: result.state, kind: kind, transaction: result.transaction,
            owner: result.owner, revision: result.revision, currentId: result.currentId, epoch: result.epoch,
            source: result.source, firstFrame: firstFrame)
        inputBlocked = true
        return true
    }

    mutating func releasePresentedSourceForDisplayChange() -> Bool {
        guard pending == nil, applied != nil, !inputBlocked else { return false }
        applied = nil
        return true
    }

    /// Called only for the owned decoder after Applied, never for reception/decode/write acknowledgements.
    @discardableResult public mutating func observeRendered(sequence: UInt32, session: UUID) -> Bool {
        guard session == self.session, inputBlocked, !awaitingReattachIDR, let applied,
              MirrorControlCodec.sequenceAtOrAfter(sequence, applied.firstFrame) else { return false }
        inputBlocked = false
        return true
    }
    public var confirmedCurrentId: UInt64 {
        guard !selectionSuppressed else { return 0 }
        return catalogue?.currentId ?? 0
    }
    // A non-ready publication can omit screens. Only the live catalogue authorizes a request.
    var pickerCatalogue: CaptureTargetCatalogue? { catalogue?.state == 1 ? catalogue : lastReadyCatalogue ?? catalogue }
    public var canSelect: Bool { enabled && !isSwitching }
    // Failed transactions can still owe a restored frame before input reopens.
    public var isSwitching: Bool { pending != nil || issue == nil && applied != nil && inputBlocked }
    public mutating func markListUnavailable(session: UUID) {
        guard session == self.session, catalogue == nil else { return }
        listUnavailable = true
    }
    /// Supersession preserves monotonic transactions, but no old Applied or callback can reopen input.
    public mutating func abandonPresentation(session: UUID, allowSameSourceReattach: Bool = false) {
        guard session == self.session, enabled else { return }
        if allowSameSourceReattach, pending == nil, let applied { retainedPresentation = applied }
        else { retainedPresentation = nil }
        awaitingReattachIDR = false
        pending = nil; applied = nil; unknownOutcome = true; inputBlocked = true; needsCatalogueRefresh = true
    }
    /// Reattachment has no new source request: a fresh IDR establishes its presentation floor.
    @discardableResult mutating func anchorReattachedSource(sequence: UInt32, isIDR: Bool) -> Bool {
        guard awaitingReattachIDR, let old = applied, isIDR,
              MirrorControlCodec.sequenceAtOrAfter(sequence, old.firstFrame) else { return false }
        applied = CaptureTargetResult(status: old.status, state: old.state, kind: old.kind,
            transaction: old.transaction, owner: old.owner, revision: old.revision, currentId: old.currentId,
            epoch: old.epoch, source: old.source, firstFrame: sequence)
        awaitingReattachIDR = false
        return true
    }
    public mutating func requireFreshPresentation(session: UUID) {
        guard session == self.session, applied != nil else { return }
        inputBlocked = true
    }
    var requiresRestart: Bool { catalogue?.state == 0 || catalogue?.state == 3 }

    public var statusMessage: String? {
        let nextStep=requiresRestart ? " Stop and restart the session." : " Choose a source again."
        if pending != nil { return "Switching display source..." }
        if unknownOutcome { return "Switch outcome unknown." + nextStep }
        if requiresRestart && issue == nil {
            return "Sources are unavailable. Stop and restart the session."
        }
        if listUnavailable { return "The source list is unavailable. Refresh sources to try again." }
        switch issue {
        case .stale:
            if requiresRestart { return "The source list changed." + nextStep }
            return needsCatalogueRefresh ? "The source list changed. Refreshing sources..." : "The source list changed. Choose a source again."
        case .notAvailable: return "This source is unavailable." + nextStep
        case .denied: return "Source switching is not allowed on the PC." + (requiresRestart ? nextStep : "")
        case .failed: return "Couldn't switch sources." + nextStep
        case .busy: return "The PC is busy switching sources. Wait, then choose again."
        case .administratorRequired: return "Extend iPad: administrator required on the PC." + (requiresRestart ? nextStep : "")
        case .timedOut: return "The PC timed out." + nextStep
        case .cancelled: return "Source switching was cancelled." + nextStep
        case .applied, .accepted, nil:
            return applied != nil && inputBlocked ? "Waiting for the new source picture..." : nil
        }
    }
}

/// Bounded encoded candidate chain. It cannot reach the decoder until Applied supplies its anchor.
/// Dropping an oversized chain leaves input blocked while the network owner asks for a new keyframe.
struct CaptureTargetVideoBuffer {
    struct Frame {
        let data: Data, sequence: UInt32, isIDR: Bool, lengthPrefixed: Bool, receivedAt: TimeInterval
    }
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumFrames = 120
    private(set) var frames: [Frame] = []
    private(set) var byteCount = 0
    func hasRoot(firstFrame: UInt32) -> Bool {
        guard let root = frames.first, root.isIDR else { return false }
        return MirrorControlCodec.sequenceAtOrAfter(root.sequence, firstFrame)
    }
    mutating func reset() { frames.removeAll(keepingCapacity: false); byteCount = 0 }
    @discardableResult
    mutating func append(_ frame: Frame, continuesDecodeChain: Bool = false) -> Bool {
        if frame.isIDR { reset() }
        guard frame.isIDR || !frames.isEmpty || continuesDecodeChain else { return false }
        guard frames.count < Self.maximumFrames, frame.data.count <= Self.maximumBytes - byteCount else {
            reset(); return false
        }
        frames.append(frame); byteCount += frame.data.count
        return true
    }
    mutating func popFirst() -> Frame? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        byteCount -= frame.data.count
        return frame
    }
    mutating func take(firstFrame: UInt32) -> [Frame] {
        defer { reset() }
        guard let root = frames.first, root.isIDR,
              MirrorControlCodec.sequenceAtOrAfter(root.sequence, firstFrame) else { return [] }
        return frames
    }
}
