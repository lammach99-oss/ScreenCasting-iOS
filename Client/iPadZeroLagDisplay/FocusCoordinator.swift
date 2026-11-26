import Combine
import UIKit


// Immutable identity captured by every surface callback. Two managers may use
// the same transport and decoder generation numbers.
struct FocusBinding: Equatable {
    let ticket: SlotTicket
    let transport: UInt64
}

// Read on Metal, VT and main queues. Each set of installed callbacks captures
// its own lifetime; a later install never revives an earlier one.
final class FocusSurfaceLifetime {
    private let lock = NSLock()
    private var retired = false
    var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !retired
    }
    func retire() {
        lock.lock(); retired = true; lock.unlock()
    }
}

@MainActor final class FocusCoordinator: ObservableObject {
    private static var current: FocusCoordinator?

    static func shared(primary: NetworkManager, pair: RemotePairStore.Pair) -> FocusCoordinator {
        if let current { return current }
        let coordinator = FocusCoordinator(primary: primary, model: SessionSwitcher(pair: pair))
        current = coordinator
        return coordinator
    }

    let model: SessionSwitcher
    let primary: NetworkManager
    let secondary: NetworkManager
    @Published private(set) var binding: FocusBinding?
    @Published private(set) var outputLease: SlotTicket?
    private let timeline = SlotTimelineExport()
    private let lifecycle = SlotLifecyclePolicy()
    private var sceneActive = true
    private var suspendedScene: String?
    private lazy var clipboardFocus = RemoteClipboardFocus { [weak self] slot, active in
        self?.manager(slot).setRemoteClipboardSceneActive(active)
    }
    private var thumbnails: [SlotOrdinal: Data] = [:]
    func thumbnail(for slot: SlotOrdinal) -> Data? {
        guard sceneActive, let bytes = thumbnails[slot], let transport = transports[slot],
              manager(slot).focusPreviewAllowed(transport) else { return nil }
        return bytes
    }

    func ownsOutput(_ ticket: SlotTicket) -> Bool {
        outputLease == ticket && manager(ticket.ordinal).acceptsFocusInput(ticket)
    }

    func performInput(_ ticket: SlotTicket, _ send: (NetworkManager) -> Void) {
        let network = manager(ticket.ordinal)
        guard ownsOutput(ticket) else { return }
        send(network)
    }
    private var transports: [SlotOrdinal: UInt64] = [:]
    private var timer: Task<Void, Never>?
    private var pairActive = false
    private var sawPresentation = false
    private var requestedRecovery = false
    private var notifications = Set<AnyCancellable>()

    // Create once, when opting into a pair. A single-PC scene keeps its original manager.
    private init(primary: NetworkManager, model: SessionSwitcher? = nil) {
        self.primary = primary
        self.secondary = NetworkManager(role: .secondaryRemote)
        self.model = model ?? SessionSwitcher()
        for ordinal in [SlotOrdinal.one, .two] {
            let peer = manager(ordinal)
            if ordinal == .two { peer.enterFocusMode() }
            peer.focusAuthorityChanged = { [weak self] changed in self?.authorityChanged(ordinal, changed: changed) }
            peer.focusConnectionEnded = { [weak self] transport, error in
                guard let self, self.transports[ordinal] == transport else { return }
                self.drop(self.model[ordinal].ticket, error: error)
            }
        }
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.objectWillChange.send()
                        self?.thumbnails.removeAll()
                        if name == UIApplication.willResignActiveNotification {
                            self?.appLifecycleChanged(active: false)
                        }
                    }
                }.store(in: &notifications)
        }
    }

    #if targetEnvironment(simulator)
    static func forTesting(primary: NetworkManager) -> FocusCoordinator {
        FocusCoordinator(primary: primary)
    }
    #endif

    func endPair(scene: String) {
        guard model.surfaceOwner == nil || model.surfaceOwner == scene else { return }
        releaseSurface(scene)
        if pairActive {
            primary.remoteClipboardPasteboard.unbindFocus()
            primary.setRemoteClipboardSceneActive(sceneActive)
            primary.endFileSlotFocus()
        }
        secondary.stop()
        primary.focusConnectionEnded = nil
        primary.focusAuthorityChanged = nil
        secondary.focusConnectionEnded = nil
        secondary.focusAuthorityChanged = nil
        primary.leaveFocusMode()
        model.remove(.two)
        transports.removeAll()
        thumbnails.removeAll()
        pairActive = false
        if Self.current === self { Self.current = nil }
    }

    func manager(_ slot: SlotOrdinal) -> NetworkManager { slot == .one ? primary : secondary }

    func connect(_ slot: SlotOrdinal, route: SlotRoute) -> SlotTicket? {
        // A streaming observation cannot automatically retry a timed-out picture.
        if model[slot].retryRequested, let transport = transports[slot],
           manager(slot).authenticatedRemoteIP(transport) { return nil }
        return model.connect(slot, route: route)
    }

    @discardableResult func retryRetainedSlot(_ slot: SlotOrdinal) -> Bool {
        guard sceneActive, model.surfaceOwner != nil, model[slot].retryRequested,
              let transport = transports[slot], manager(slot).authenticatedRemoteIP(transport),
              let peer = model[slot].peer, let retry = model.connect(slot, route: model[slot].route ?? .wifi),
              model.authenticate(retry, peer: peer) else { return false }
        reconcile()
        return true
    }

    @discardableResult func authenticate(_ ticket: SlotTicket, transport: UInt64, peer: TrustedPeerReference) -> Bool {
        let slot = ticket.ordinal, network = manager(slot)
        guard network.authenticatedRemoteIP(transport) else { return false }
        guard model.authenticate(ticket, peer: peer) else {
            if model[slot].generation == ticket.generation, model[slot].phase == .refused { network.stop() }
            objectWillChange.send()
            return false
        }
        transports[slot] = transport
        if !pairActive, transports.count == 2 {
            primary.enterFocusMode()
            pairActive = true
            for (ordinal, transport) in transports {
                let network = manager(ordinal)
                network.remoteClipboardPasteboard.bindFocus(clipboardFocus, slot: ordinal)
                network.beginFileSlotFocus(ordinal)
                network.trackFocusTransport(transport)
                if model[ordinal].phase == .parked {
                    record(model[ordinal].ticket, .parked)
                    network.requestVideoStandby(park: true, expectedGeneration: transport)
                }
            }
        } else if pairActive || slot == .two {
            network.trackFocusTransport(transport)
            if model[slot].phase == .parked {
                record(model[slot].ticket, .parked)
                network.requestVideoStandby(park: true, expectedGeneration: transport)
            }
        }
        reconcile()
        return true
    }

    func claimSurface(_ scene: String) {
        guard sceneActive else {
            if suspendedScene == nil { suspendedScene = scene }
            return
        }
        if model.claimSurface(scene) { reconcile() }
    }
    func releaseSurface(_ scene: String) {
        if suspendedScene == scene { suspendedScene = nil }
        guard model.surfaceOwner == scene else { return }
        model.releaseSurface(scene)
        reconcile()
        thumbnails.removeAll()
    }
    func select(_ slot: SlotOrdinal, scene: String) {
        guard sceneActive, model.surfaceOwner == scene else { return }
        if model[slot].retryRequested { _ = retryRetainedSlot(slot) }
        _ = model.select(slot, scene: scene)
        reconcile()
    }
    func drop(_ ticket: SlotTicket, error: SlotFailure) {
        guard model[ticket.ordinal].ticket == ticket else { return }
        record(ticket, .drop)
        model.drop(ticket, error: error)
        if error != .transport { manager(ticket.ordinal).stop() }
        transports[ticket.ordinal] = nil
        thumbnails[ticket.ordinal] = nil
        reconcile()
    }

    private func authorityChanged(_ slot: SlotOrdinal, changed: Bool) {
        let network = manager(slot)
        if changed {
            thumbnails[slot] = nil
            if (binding.map { $0.ticket.ordinal == slot && !network.focusAuthorityMatches($0) } ?? false) || model[slot].phase == .parked {
                model.invalidateContext(model[slot].ticket)
                reconcile()
            }
        }
        if let binding, binding.ticket.ordinal == slot, network.focusContextReady(binding.transport) {
            contextReady(binding)
        }
    }

    func presented(_ evidence: FocusBinding) {
        guard binding == evidence, manager(evidence.ticket.ordinal).remoteKeyboardGeneration == evidence.transport else { return }
        guard manager(evidence.ticket.ordinal).focusAuthorityMatches(evidence) else { return }
        if !sawPresentation { record(evidence.ticket, .presented) }
        sawPresentation = true
        timer?.cancel()
        _ = model.presented(evidence.ticket)
        reconcile()
    }
    func contextReady(_ evidence: FocusBinding) {
        guard binding == evidence, manager(evidence.ticket.ordinal).remoteKeyboardGeneration == evidence.transport else { return }
        guard manager(evidence.ticket.ordinal).focusContextReady(evidence.transport) else { return }
        _ = model.contextReady(evidence.ticket)
        reconcile()
    }

    private func reconcile() {
        guard pairActive else { objectWillChange.send(); return }
        let ticket = model.inFlight ?? model.outputLease
        if binding?.ticket != ticket {
            timer?.cancel()
            let old = binding
            if let old {
                let network = manager(old.ticket.ordinal)
                let previewEligible = outputLease == old.ticket
                if let ticket, ticket.ordinal != old.ticket.ordinal { record(ticket, .tap) }
                clipboardFocus.demote(slot: old.ticket.ordinal, epoch: old.ticket.epoch)
                network.cancelFileSlotFocus(epoch: old.ticket.epoch)
                network.retireFocusInput?()
                network.setFocusOutput(nil)
                outputLease = nil
                let park = old.ticket.ordinal != ticket?.ordinal
                if park {
                    network.requestVideoStandby(park: true, expectedGeneration: old.transport)
                    if model[old.ticket.ordinal].phase == .parked { record(old.ticket, .parked) }
                    if sceneActive && previewEligible && model[old.ticket.ordinal].phase == .parked && model.surfaceOwner != nil {
                        thumbnails[old.ticket.ordinal] = network.takeFocusThumbnail(old)
                    }
                }
                network.detachFocus(old, park: park)
            }
            binding = nil
            guard let ticket, let transport = transports[ticket.ordinal] else { objectWillChange.send(); return }
            let next = FocusBinding(ticket: ticket, transport: transport)
            let network = manager(ticket.ordinal)
            guard network.remoteKeyboardGeneration == transport else { drop(ticket, error: .transport); return }
            thumbnails[ticket.ordinal] = nil
            if old?.ticket.ordinal != ticket.ordinal {
                network.requestVideoStandby(park: false, expectedGeneration: transport)
            }
            sawPresentation = false
            requestedRecovery = false
            record(ticket, .resume)
            binding = next
            network.installFocus(next) { [weak self] in self?.presented(next) }
            timer = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.watchdog(next, expired: false)
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.watchdog(next, expired: true)
                } catch {}
            }
            if network.focusContextReady(transport) { _ = model.contextReady(ticket) }
        }
        if outputLease != model.outputLease {
            outputLease = model.outputLease
            if let outputLease {
                let network = manager(outputLease.ordinal)
                network.setFocusOutput(outputLease)
                network.promoteFileSlotFocus(epoch: outputLease.epoch)
                clipboardFocus.promote(slot: outputLease.ordinal, epoch: outputLease.epoch)
            }
        }
        objectWillChange.send()
    }

    private func record(_ ticket: SlotTicket, _ event: SlotTimelineExport.Event) {
        timeline.record(slot: ticket.ordinal, route: manager(ticket.ordinal).focusRoute(model[ticket.ordinal].route),
                        epoch: ticket.epoch, event: event)
    }

    func exportDiagnostics() -> Data {
        (try? timeline.export(hasSecondary: pairActive) { primary.singleSessionDiagnostics() }) ?? Data()
    }

    func appLifecycleChanged(active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        let effects = active ? lifecycle.foreground(hasSecondary: model[.two].route != nil)
            : lifecycle.background(primary: primary.focusRoute(model[.one].route), secondary: model[.two].route)
        if !active, let scene = model.surfaceOwner {
            suspendedScene = scene
            model.releaseSurface(scene)
            reconcile()
        }
        for effect in effects {
            switch effect {
            case .releaseAuthority(let slot):
                if !pairActive { manager(slot).setRemoteClipboardSceneActive(false) }
                manager(slot).applicationWillResignActive()
            case .hidePreview(let slot):
                thumbnails[slot] = nil
            case .suspendUSB(let slot), .applyWiFiGrace(let slot):
                manager(slot).applicationDidEnterBackground()
            case .revalidateSessionPictureAndAuthority(let slot):
                let network = manager(slot)
                if !pairActive && slot == .one { network.setRemoteClipboardSceneActive(true) }
                network.applicationDidBecomeActive()
                guard let transport = transports[slot] else { continue }
                if network.authenticatedRemoteIP(transport) {
                    model.invalidateContext(model[slot].ticket)
                } else {
                    drop(model[slot].ticket, error: .transport)
                }
            }
        }
        if active, let scene = suspendedScene {
            suspendedScene = nil
            claimSurface(scene)
        }
        objectWillChange.send()
    }

    func watchdog(_ expected: FocusBinding, expired: Bool) {
        guard binding == expected, !sawPresentation else { return }
        if expired {
            record(expected.ticket, .offline)
            if manager(expected.ticket.ordinal).authenticatedRemoteIP(expected.transport) {
                model.drop(expected.ticket, error: .transport)
                reconcile()
            } else {
                drop(expected.ticket, error: .transport)
            }
        }
        else if !requestedRecovery {
            record(expected.ticket, .recovery)
            requestedRecovery = true
            manager(expected.ticket.ordinal).requestFocusRecovery(expected.transport)
        }
    }
}
