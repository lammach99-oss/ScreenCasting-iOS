import Network
import SwiftUI

@MainActor final class PairSession: ObservableObject {
    static let shared = PairSession()
    @Published private(set) var focus: FocusCoordinator?
    private var authenticatedGenerations: [SlotOrdinal: UInt64] = [:]
    private var names: [SlotOrdinal: String] = [:]
    private let store: RemotePairStore
    init(store: RemotePairStore = RemotePairStore()) { self.store = store }
    private var activeScenes = Set<String>()
    var hasActiveScene: Bool { !activeScenes.isEmpty }

    func setScene(_ scene: String, active: Bool) {
        if active { activeScenes.insert(scene) } else { activeScenes.remove(scene) }
    }

    func name(_ slot: SlotOrdinal) -> String { names[slot] ?? "PC \(slot.rawValue)" }

    private func address(for peer: TrustedPeerReference?) -> RemoteHostAddress? {
        guard let peer else { return nil }
        return TrustedHostFingerprintStore().targets(for: peer.fingerprint)
            .filter { $0.port == NetworkManager.remoteControlPort }
            .compactMap { $0.host.flatMap(PairPanelModel.address) }.first
    }

    func restore(primary: NetworkManager) {
        guard primary.capabilities.allowsSecondPC else { return }
        let pair = store.load()
        guard focus == nil, pair.first != nil, pair.second != nil else { return }
        let coordinator = FocusCoordinator.shared(primary: primary, pair: pair)
        coordinator.prepareForRestore()
        focus = coordinator
        for slot in [SlotOrdinal.one, .two] {
            if let target = address(for: coordinator.model[slot].peer) { connect(slot, target) }
        }
    }

    func add(primary: NetworkManager, text: String, firstName: String) -> String? {
        guard primary.capabilities.allowsSecondPC else { return "A second PC is unavailable on this device." }
        let transport = primary.remoteKeyboardGeneration
        guard focus == nil, let target = PairPanelModel.address(text),
              primary.authenticatedRemoteIP(transport),
              let first = primary.hostFingerprint.flatMap(TrustedPeerReference.init) else {
            return "Connect PC 1 in Remote control mode first."
        }
        guard primary.videoStandby.negotiated, primary.videoStandby.generation == transport else {
            return "PC 1 must support pausing remote video."
        }
        let endpoint = WifiReconnectTarget.hostPort(host: target.host, port: NetworkManager.remoteControlPort).endpoint
        let known = endpoint.flatMap { TrustedHostFingerprintStore().load(endpoint: $0) }.flatMap(TrustedPeerReference.init)
        guard PairPanelModel.accepts(first: first, candidate: known) else { return PairPanelModel.reason(.duplicatePeer) }
        let coordinator = FocusCoordinator.shared(primary: primary, pair: .init(first: first, second: known, selected: .one))
        let firstRoute: SlotRoute = address(for: first)?.isTailnet == true ? .tailscale : .wifi
        guard let ticket = coordinator.connect(.one, route: firstRoute),
              coordinator.authenticate(ticket, transport: transport, peer: first) else {
            coordinator.endPair(scene: "")
            return "PC 1 disconnected. Reconnect and try again."
        }
        authenticatedGenerations[.one] = transport
        names[.one] = firstName.isEmpty ? "PC 1" : firstName
        focus = coordinator
        connect(.two, target)
        return nil
    }

    private func connect(_ slot: SlotOrdinal, _ target: RemoteHostAddress) {
        guard let focus, focus.connect(slot, route: target.isTailnet ? .tailscale : .wifi) != nil else { return }
        names[slot] = target.host
        focus.manager(slot).connect(to: target.host, port: NetworkManager.remoteControlPort)
        objectWillChange.send()
    }

    func retry(_ slot: SlotOrdinal) {
        guard let focus, focus.manager(.one).capabilities.allowsSecondPC, [.idle, .offline].contains(focus.model[slot].phase) else { return }
        // A watchdog-offline slot keeps its authenticated connection; resume it before dialing again.
        if focus.retryRetainedSlot(slot) { objectWillChange.send(); return }
        guard let target = address(for: focus.model[slot].peer) ?? names[slot].flatMap(PairPanelModel.address) else { return }
        let manager = focus.manager(slot)
        if manager.connectionState == .streaming, manager.authenticatedRemoteIP(manager.remoteKeyboardGeneration) {
            _ = focus.connect(slot, route: focus.model[slot].route ?? .wifi)
            update(slot)
        } else {
            connect(slot, target)
        }
    }

    func update(_ slot: SlotOrdinal) {
        guard let focus else { return }
        let manager = focus.manager(slot)
        let phase = focus.model[slot].phase
        switch manager.connectionState {
        case .streaming:
            let transport = manager.remoteKeyboardGeneration
            guard phase == .connecting || (phase == .offline && transport != authenticatedGenerations[slot]),
                  manager.authenticatedRemoteIP(transport),
                  let peer = manager.hostFingerprint.flatMap(TrustedPeerReference.init) else { return }
            guard manager.videoStandby.generation == transport, manager.videoStandby.negotiated else {
                if manager.remoteInputFeatures != 0 { focus.drop(focus.model[slot].ticket, error: .refused) }
                return
            }
            if phase == .offline { _ = focus.connect(slot, route: focus.model[slot].route ?? .wifi) }
            if focus.authenticate(focus.model[slot].ticket, transport: transport, peer: peer) {
                authenticatedGenerations[slot] = transport
                if slot == .two, let host = names[slot] { _ = RecentRemoteHostStore.record(host: host, remoteControl: true) }
                persist()
            }
        case .awaitingHostIdentity:
            guard phase == .connecting, let observed = manager.hostFingerprint.flatMap(TrustedPeerReference.init) else { return }
            if observed == focus.model[slot.alternate].peer {
                focus.drop(focus.model[slot].ticket, error: .duplicatePeer)
            } else if let expected = focus.model[slot].peer, expected != observed {
                focus.drop(focus.model[slot].ticket, error: .identityMismatch)
            }
        case .authFailed where phase != .refused:
            focus.drop(focus.model[slot].ticket, error: .refused)
        case .disconnected(let reason) where phase != .refused && phase != .idle:
            // A rejected TLS identity may be published before the socket reports its failure.
            if let expected = focus.model[slot].peer,
               let observed = manager.hostFingerprint.flatMap(TrustedPeerReference.init), observed != expected {
                focus.drop(focus.model[slot].ticket, error: .identityMismatch)
            } else if reason == NWError.posix(.ECONNREFUSED).localizedDescription {
                focus.drop(focus.model[slot].ticket, error: .refused)
            } else if phase != .offline {
                focus.drop(focus.model[slot].ticket, error: .transport)
            }
        default: break
        }
    }

    func select(scene: String) {
        guard let focus, let target = PairPanelModel.tapTarget(focus.model, scene: scene) else { return }
        focus.select(target, scene: scene)
        persist()
    }

    private func persist() {
        guard let model = focus?.model, let first = model[.one].peer, let second = model[.two].peer,
              ![.connecting, .idle, .refused].contains(model[.two].phase) else { return }
        store.save(first: first, second: second, selected: model.selected)
    }

    func remove(scene: String) {
        guard let focus, focus.model.surfaceOwner == scene else { return }
        if let second = focus.model[.two].peer { store.forget(second) }
        focus.endPair(scene: scene)
        self.focus = nil
        authenticatedGenerations.removeAll()
        names.removeAll()
        activeScenes.removeAll()
    }
}
