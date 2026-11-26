import Foundation
import Network
import Combine
import os

/// Immutable representation of a discovered ScreenCasting host on the local network via Bonjour mDNS.
public struct DiscoveredHost: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public init(id: String = UUID().uuidString, name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.name == rhs.name && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(endpoint)
    }
}

protocol DiscoveryBrowser: Sendable {
    func start(queue: DispatchQueue, results: @escaping @Sendable ([NWEndpoint]) -> Void,
               state: @escaping @Sendable (NWBrowser.State) -> Void)
    func cancel()
}

private final class BonjourBrowser: DiscoveryBrowser {
    private let browser: NWBrowser
    init(type: String = "_screencasting._tcp") {
        browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
    }

    func start(queue: DispatchQueue, results: @escaping @Sendable ([NWEndpoint]) -> Void,
               state: @escaping @Sendable (NWBrowser.State) -> Void) {
        browser.browseResultsChangedHandler = { records, _ in results(records.map(\.endpoint)) }
        browser.stateUpdateHandler = { state($0) }
        browser.start(queue: queue)
    }

    func cancel() { browser.cancel() }
}

// Resolve DNS-SD records without connecting to an unvalidated advertised port.
private final class RemoteServiceResolution: NSObject, NetServiceDelegate {
    private let service: NetService
    let completion: (RemoteIntent.Target?) -> Void

    init(name: String, domain: String, completion: @escaping (RemoteIntent.Target?) -> Void) {
        service = NetService(domain: domain, type: RemoteSessionPolicy.remoteServiceType + ".", name: name)
        self.completion = completion
        super.init()
    }

    func start() {
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func cancel() {
        service.delegate = nil
        service.stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, let port = UInt16(exactly: sender.port) else {
            completion(nil)
            return
        }
        completion(.init(host: host, port: port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        completion(nil)
    }
}

/// Discovers ScreenCasting Windows host instances on the local LAN using Bonjour.
@MainActor
public class DiscoveryManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iPadZeroLagDisplay.client",
        category: "bonjour")

    /// Array of active, resolved ScreenCasting hosts discovered on the local network.
    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []

    @Published private(set) var discoveredRemoteIntents: [RemoteIntent] = []
    private let capabilities: ClientDeviceCapabilities
    typealias ServiceResolver = (String, String, @escaping (RemoteIntent.Target?) -> Void) -> () -> Void
    private let resolveService: ServiceResolver
    private var resolutions: [NWEndpoint: (id: UUID, cancel: () -> Void)] = [:]
    private var resolved: [NWEndpoint: RemoteIntent.Target] = [:]
    private let makeBrowser: () -> any DiscoveryBrowser
    private var browser: (any DiscoveryBrowser)?
    private var browseGeneration: UInt64 = 0
    private let browserQueue = DispatchQueue(label: "com.iPadCasting.discovery", qos: .userInitiated)

    public convenience init() { self.init(capabilities: .init(family: .pad)) }

    convenience init(makeBrowser: @escaping () -> any DiscoveryBrowser) {
        self.init(capabilities: .init(family: .pad), browserForType: { _ in makeBrowser() })
    }

    init(capabilities: ClientDeviceCapabilities,
         browserForType: @escaping (String) -> any DiscoveryBrowser = { BonjourBrowser(type: $0) },
         resolveService: @escaping ServiceResolver = { name, domain, completion in
             let resolver = RemoteServiceResolution(name: name, domain: domain, completion: completion)
             resolver.start()
             return { resolver.cancel() }
         }) {
        self.capabilities = capabilities
        let type = capabilities.allowsCasting ? "_screencasting._tcp" : RemoteSessionPolicy.remoteServiceType
        self.makeBrowser = { browserForType(type) }
        self.resolveService = resolveService
    }

    /// Starts scanning for local ScreenCasting services (`_screencasting._tcp`).
    public func startBrowsing() {
        stopBrowsing()

        guard capabilities.allowsRemoteControl else { return }
        let generation = browseGeneration
        let browser = makeBrowser()
        self.browser = browser
        browser.start(queue: browserQueue, results: { [weak self] endpoints in
            DispatchQueue.main.async {
                guard let self, self.browseGeneration == generation else { return }
                if !self.capabilities.allowsCasting {
                    self.updateRemoteResults(Set(endpoints), generation: generation)
                    return
                }
                let hosts = endpoints.map { endpoint -> DiscoveredHost in
                    if case .service(let name, _, _, _) = endpoint {
                        return DiscoveredHost(name: name, endpoint: endpoint)
                    }
                    return DiscoveredHost(name: "ScreenCasting Host", endpoint: endpoint)
                }
                self.discoveredHosts = hosts
                Self.logger.notice("[ScreenCasting][BONJOUR_RESULTS] count=\(hosts.count, privacy: .public)")
            }
        }, state: { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.browseGeneration == generation else { return }
                switch state {
                case .setup: break
                case .ready: Self.logger.notice("[ScreenCasting][BONJOUR_READY]")
                case .waiting: Self.logger.error("[ScreenCasting][BONJOUR_WAITING]")
                case .failed:
                    Self.logger.error("[ScreenCasting][BONJOUR_FAILED]")
                    self.stopBrowsing()
                case .cancelled:
                    Self.logger.notice("[ScreenCasting][BONJOUR_CANCELLED]")
                    self.stopBrowsing()
                @unknown default: Self.logger.error("[ScreenCasting][BONJOUR_UNKNOWN_STATE]")
                }
            }
        })
        Self.logger.notice("[ScreenCasting][BONJOUR_START]")
    }

    private func updateRemoteResults(_ endpoints: Set<NWEndpoint>, generation: UInt64) {
        for endpoint in Array(resolutions.keys) where !endpoints.contains(endpoint) {
            resolutions.removeValue(forKey: endpoint)?.cancel()
            resolved.removeValue(forKey: endpoint)
        }
        publishRemoteResults()
        for endpoint in endpoints where resolutions[endpoint] == nil {
            guard case .service(let name, let type, let domain, _) = endpoint,
                  !name.isEmpty, domain.lowercased() == "local.",
                  [RemoteSessionPolicy.remoteServiceType, RemoteSessionPolicy.remoteServiceType + "."].contains(type.lowercased())
            else { continue }
            let id = UUID()
            let cancel = resolveService(name, domain) { [weak self] target in
                DispatchQueue.main.async {
                    guard let self, self.browseGeneration == generation,
                          self.resolutions[endpoint]?.id == id else { return }
                    self.resolutions[endpoint]?.cancel()
                    let intent = RemoteIntent.discovered(serviceType: type, resolved: target)
                    if let target, case .success(let address) = RemoteSessionPolicy.admit(intent, for: self.capabilities) {
                        self.resolved[endpoint] = .init(host: address.host, port: target.port)
                    } else {
                        self.resolved.removeValue(forKey: endpoint)
                        self.resolutions.removeValue(forKey: endpoint)
                    }
                    self.publishRemoteResults()
                }
            }
            resolutions[endpoint] = (id, cancel)
        }
    }

    private func publishRemoteResults() {
        var seen = Set<String>()
        discoveredRemoteIntents = resolved.values.sorted { $0.host < $1.host }.compactMap {
            guard seen.insert($0.host).inserted else { return nil }
            return .discovered(serviceType: RemoteSessionPolicy.remoteServiceType, resolved: $0)
        }
    }

    /// Stops browsing for local mDNS services.
    public func stopBrowsing() {
        browseGeneration &+= 1
        resolutions.values.forEach { $0.cancel() }
        resolutions.removeAll()
        resolved.removeAll()
        if !discoveredRemoteIntents.isEmpty { discoveredRemoteIntents = [] }
        browser?.cancel()
        browser = nil
        if !discoveredHosts.isEmpty { discoveredHosts = [] }
    }

    deinit {
        resolutions.values.forEach { $0.cancel() }
        browser?.cancel()
    }
}
