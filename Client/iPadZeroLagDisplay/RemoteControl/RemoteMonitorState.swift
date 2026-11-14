import Foundation

/// Value state owned by networkQueue. A fresh session also retires callbacks from earlier negotiations.
public struct RemoteMonitorState: Equatable {
    public enum Issue: Equatable { case stale, unavailable, denied, failed, busy }
    public struct Pending: Equatable {
        public let request: RemoteMonitorSelectCommand
        public fileprivate(set) var applied: RemoteMonitorSelectResultCommand?
    }
    public private(set) var session = UUID()
    public private(set) var enabled = false
    public private(set) var catalogue: RemoteMonitorCatalogueCommand?
    public private(set) var context: RemoteInputContextCommand?
    public private(set) var pending: Pending?
    public private(set) var issue: Issue?
    public private(set) var needsCatalogueRefresh = false
    private var nextRequestId: UInt64 = 0
    private var latestRevision: UInt64 = 0
    private var latestEpoch: UInt64 = 0
    private var lastConfirmedCurrentId: UInt64 = 0
    public init() {}

    public mutating func begin(session: UUID, acceptedFeatures: UInt64) {
        self = Self(); self.session = session; enabled = acceptedFeatures & 7 == 7
    }
    public func catalogueRequest(session: UUID) -> RemoteMonitorCatalogueRequest? {
        guard session == self.session, enabled else { return nil }
        return RemoteMonitorCatalogueRequest(knownRevision: needsCatalogueRefresh ? 0 : catalogue?.revision ?? 0)
    }
    @discardableResult public mutating func receiveCatalogue(_ value: RemoteMonitorCatalogueCommand, session: UUID) -> Bool {
        guard session == self.session, enabled,
              value.revision == 0 || value.revision >= latestRevision,
              value.epoch == 0 || value.epoch >= latestEpoch else { return false }
        latestRevision = max(latestRevision, value.revision); latestEpoch = max(latestEpoch, value.epoch)
        catalogue = value; needsCatalogueRefresh = false
        if value.state == 0 { pending = nil; issue = .unavailable }
        else if issue == .unavailable { issue = nil }
        rememberCurrent()
        settleApplied()
        return true
    }
    public mutating func receiveContext(_ value: RemoteInputContextCommand?, session: UUID) {
        guard session == self.session, enabled else { return }
        context = value; rememberCurrent(); settleApplied()
    }
    public var isSourceRecovery: Bool {
        catalogue?.state == 1 && catalogue?.currentId == 0 && catalogue?.entries.isEmpty == false
    }
    public func selectionReady(inputReady: Bool, controlEnabled: Bool) -> Bool {
        guard enabled, controlEnabled, let catalogue, catalogue.state == 1, issue != .unavailable else { return false }
        if isSourceRecovery { return true }
        guard inputReady, let context, context.state == 1, context.token != 0 else { return false }
        return context.desktop == catalogue.desktop && context.desktopEpoch == catalogue.epoch
    }
    public func mayWriteSelection(_ request: RemoteMonitorSelectCommand, session: UUID,
                                  inputReady: Bool, controlEnabled: Bool) -> Bool {
        session == self.session && pending?.request == request && pending?.applied == nil && !needsCatalogueRefresh &&
            selectionReady(inputReady: inputReady, controlEnabled: controlEnabled)
    }
    public mutating func select(targetId: UInt64, catalogue expected: RemoteMonitorCatalogueCommand, session: UUID,
                                inputReady: Bool = false, controlEnabled: Bool = false) -> RemoteMonitorSelectCommand? {
        guard session == self.session, selectionReady(inputReady: inputReady, controlEnabled: controlEnabled),
              pending == nil, !needsCatalogueRefresh,
              let catalogue, catalogue.state == 1 else { return nil }
        guard catalogue == expected else { issue = .stale; needsCatalogueRefresh = true; return nil }
        guard targetId != catalogue.currentId, catalogue.entries.contains(where: { $0.id == targetId }),
              nextRequestId != UInt64.max else { return nil }
        nextRequestId += 1
        let request = RemoteMonitorSelectCommand(requestId: nextRequestId, expectedEpoch: catalogue.epoch,
            catalogueRevision: catalogue.revision, targetId: targetId)
        pending = Pending(request: request, applied: nil); issue = nil
        return request
    }
    @discardableResult public mutating func receiveResult(_ value: RemoteMonitorSelectResultCommand, session: UUID) -> Bool {
        guard session == self.session, enabled, let pending, pending.request.requestId == value.requestId else { return false }
        switch value.status {
        case 0:
            guard value.currentId == pending.request.targetId, value.epoch >= pending.request.expectedEpoch,
                  value.catalogueRevision >= pending.request.catalogueRevision else {
                selectionFailed(requestId: value.requestId, session: session); return true
            }
            self.pending?.applied = value; settleApplied()
        case 1: self.pending = nil; issue = .stale; needsCatalogueRefresh = true
        case 2: self.pending = nil; issue = .unavailable; needsCatalogueRefresh = true
        case 3: self.pending = nil; issue = .denied
        case 4: self.pending = nil; issue = .failed
        case 5: self.pending = nil; issue = .busy; needsCatalogueRefresh = true
        default: return false
        }
        return true
    }
    public mutating func selectionFailed(requestId: UInt64, session: UUID) {
        guard session == self.session, pending?.request.requestId == requestId else { return }
        pending = nil; issue = .failed; needsCatalogueRefresh = true
    }
    /// Presentation only. Input authority stays entirely in RemoteFeatureNegotiation.
    public var confirmedCurrentId: UInt64 {
        guard let catalogue, catalogue.state != 0, let context, context.state == 1,
              context.desktop == catalogue.desktop, context.desktopEpoch == catalogue.epoch,
              let current = catalogue.entries.first(where: { $0.id == catalogue.currentId }),
              current.left == context.left, current.top == context.top,
              current.width == context.width, current.height == context.height else { return 0 }
        return current.id
    }
    /// Keep the last confirmed tile visible during a pause, without promoting an unconfirmed selection.
    public var displayCurrentId: UInt64 {
        let current = confirmedCurrentId
        if current != 0 { return current }
        return catalogue?.entries.contains(where: { $0.id == lastConfirmedCurrentId }) == true ? lastConfirmedCurrentId : 0
    }
    private mutating func rememberCurrent() {
        if catalogue?.state == 0 || catalogue?.currentId == 0 { lastConfirmedCurrentId = 0 }
        else if confirmedCurrentId != 0 { lastConfirmedCurrentId = confirmedCurrentId }
    }
    public func selectionStatus(inputReady: Bool, controlEnabled: Bool) -> String? {
        if let statusMessage { return statusMessage }
        if !controlEnabled { return "Turn Control on to choose a screen." }
        if isSourceRecovery { return pending == nil ? "Choose a screen to restore the picture." : "Switching screens..." }
        if !selectionReady(inputReady: inputReady, controlEnabled: controlEnabled) { return "Waiting for the remote picture." }
        return nil
    }
    private mutating func settleApplied() {
        guard let applied = pending?.applied, let catalogue, catalogue.state == 1,
              catalogue.epoch == applied.epoch, catalogue.revision >= applied.catalogueRevision,
              confirmedCurrentId == applied.currentId else { return }
        pending = nil; issue = nil
    }
    public var statusMessage: String? {
        if catalogue?.state == 0 || issue == .unavailable {
            return "Screens are unavailable on this desktop. Return to the Windows desktop to choose a screen."
        }
        if catalogue?.state == 2 { return "Switching screens..." }
        switch issue {
        case .stale: return needsCatalogueRefresh ? "The screen list changed. Refreshing screens..." : "The screen list changed. Choose a screen again."
        case .denied: return "This screen is no longer available. Choose another screen."
        case .failed: return "Couldn't switch screens. Try again."
        case .busy: return "The PC is switching screens. Wait, then try again."
        case .unavailable: return nil
        case nil: return nil
        }
    }
}
