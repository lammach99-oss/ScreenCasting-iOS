import Network
import SwiftUI

extension RemoteHostAddress: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(host) }
}

enum HostPresence: Equatable {
    case checking, online, offline

    var caption: String {
        switch self {
        case .checking: return "Checking..."
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

@MainActor final class HostPresenceMonitor: ObservableObject {
    typealias Prober = (RemoteHostAddress, @escaping @MainActor (Bool) -> Void) -> () -> Void
    @Published private(set) var states: [RemoteHostAddress: HostPresence] = [:]
    private let prober: Prober
    private var hosts: [RemoteHostAddress] = []
    private var pending: [RemoteHostAddress] = []
    private var missed = Set<RemoteHostAddress>()
    private var inFlight: [RemoteHostAddress: (id: UUID, cancel: () -> Void)] = [:]
    private var refresh: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(prober: @escaping Prober = TCPPresenceProbe.start) { self.prober = prober }

    func track(_ addresses: [RemoteHostAddress], excluding excluded: Set<RemoteHostAddress> = []) {
        var unique = Set<RemoteHostAddress>()
        let next = addresses.filter { !excluded.contains($0) && unique.insert($0).inserted }
        guard hosts != next else { return }
        invalidate()
        hosts = next
        states = Dictionary(uniqueKeysWithValues: next.map { ($0, states[$0] ?? .checking) })
        missed.formIntersection(next)
        tick()
    }

    func start() {
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                self?.tick()
            }
        }
        tick()
    }

    deinit { refresh?.cancel() }

    func stop() {
        refresh?.cancel()
        refresh = nil
        invalidate()
    }

    private func invalidate() {
        generation &+= 1
        pending.removeAll()
        let old = inFlight
        inFlight.removeAll()
        for probe in old.values { probe.cancel() }
    }

    func tick() {
        guard refresh != nil, pending.isEmpty, inFlight.isEmpty else { return }
        pending = hosts
        drain()
    }

    func markSeen(_ host: RemoteHostAddress) {
        guard refresh != nil, states[host] != nil else { return }
        pending.removeAll { $0 == host }
        inFlight.removeValue(forKey: host)?.cancel()
        missed.remove(host)
        states[host] = .online
        drain()
    }

    private func drain() {
        let epoch = generation
        while refresh != nil, inFlight.count < 4, !pending.isEmpty {
            let host = pending.removeFirst()
            let id = UUID()
            inFlight[host] = (id, {})
            let cancel = prober(host) { [weak self] online in
                guard let self, self.generation == epoch, self.inFlight[host]?.id == id else { return }
                self.inFlight.removeValue(forKey: host)
                if online {
                    self.missed.remove(host)
                    self.states[host] = .online
                } else if self.states[host] != .online || !self.missed.insert(host).inserted {
                    self.states[host] = .offline
                }
                self.drain()
            }
            if inFlight[host]?.id == id { inFlight[host] = (id, cancel) }
        }
    }
}

struct PresenceButton: View {
    let title: String
    let state: HostPresence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                HostPresenceBadge(state: state)
            }.accessibilityElement(children: .combine)
        }
    }
}

struct HostPresenceBadge: View {
    let state: HostPresence

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if state == .checking { Circle().strokeBorder(lineWidth: 1) }
                else { Circle().fill() }
            }
            .frame(width: 8, height: 8)
            .foregroundStyle(state == .online ? Color.green : Color.secondary)
            .accessibilityHidden(true)
            Text(state.caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct PresenceTracking: ViewModifier {
    let monitor: HostPresenceMonitor
    let hosts: [RemoteHostAddress]
    var excluded: Set<RemoteHostAddress> = []
    var enabled = true
    var sightings: [RemoteHostAddress] = []
    @Environment(\.scenePhase) private var phase
    @State private var visible = false

    init(monitor: HostPresenceMonitor, hosts: [RemoteHostAddress], excluded: Set<RemoteHostAddress> = [],
         enabled: Bool = true, sightings: [RemoteHostAddress] = []) {
        self.monitor = monitor
        self.hosts = hosts
        self.excluded = excluded
        self.enabled = enabled
        self.sightings = sightings
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; monitor.stop() }
            .onChange(of: hosts) { _, _ in if visible { update() } }
            .onChange(of: excluded) { _, _ in if visible { update() } }
            .onChange(of: enabled) { _, _ in if visible { update() } }
            .onChange(of: phase) { _, _ in if visible { update() } }
            .onChange(of: sightings) { old, new in
                for host in new where !old.contains(host) { monitor.markSeen(host) }
            }
    }

    private func update() {
        guard enabled, phase == .active else { monitor.stop(); return }
        monitor.track(hosts, excluding: excluded)
        monitor.start()
        for host in sightings { monitor.markSeen(host) }
    }

    static func liveAddresses(_ network: NetworkManager) -> Set<RemoteHostAddress> {
        guard network.connectionState == .streaming, let fingerprint = network.hostFingerprint else { return [] }
        return Set(TrustedHostFingerprintStore().targets(for: fingerprint)
            .compactMap { $0.host.flatMap(RemoteHostAddress.parse) })
    }
}

private final class TCPPresenceProbe {
    private let queue = DispatchQueue(label: "presence.tcp")
    private let connection: NWConnection
    private var reply: (@MainActor (Bool) -> Void)?

    private init(_ host: RemoteHostAddress, _ reply: @escaping @MainActor (Bool) -> Void) {
        self.reply = reply
        let endpoint = NWEndpoint.hostPort(host: RemoteHostAddress.networkHost(host.host),
                                           port: NWEndpoint.Port(rawValue: NetworkManager.remoteControlPort)!)
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    static func start(_ host: RemoteHostAddress, _ reply: @escaping @MainActor (Bool) -> Void) -> () -> Void {
        let probe = TCPPresenceProbe(host, reply)
        probe.queue.async { probe.begin() }
        return { probe.queue.async { probe.finish(false) } }
    }

    private func begin() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: finish(true)
            case .failed, .waiting, .cancelled: finish(false)
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(false) }
        connection.start(queue: queue)
    }

    private func finish(_ online: Bool) {
        guard let reply else { return }
        self.reply = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        Task { @MainActor in reply(online) }
    }
}
