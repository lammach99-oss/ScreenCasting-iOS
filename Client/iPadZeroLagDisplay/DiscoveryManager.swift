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
    private let browser = NWBrowser(for: .bonjour(type: "_screencasting._tcp", domain: "local."),
                                    using: .tcp)

    func start(queue: DispatchQueue, results: @escaping @Sendable ([NWEndpoint]) -> Void,
               state: @escaping @Sendable (NWBrowser.State) -> Void) {
        browser.browseResultsChangedHandler = { records, _ in results(records.map(\.endpoint)) }
        browser.stateUpdateHandler = { state($0) }
        browser.start(queue: queue)
    }

    func cancel() { browser.cancel() }
}

/// Discovers ScreenCasting Windows host instances on the local LAN using Bonjour.
@MainActor
public class DiscoveryManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iPadZeroLagDisplay.client",
        category: "bonjour")

    /// Array of active, resolved ScreenCasting hosts discovered on the local network.
    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []

    private let makeBrowser: () -> any DiscoveryBrowser
    private var browser: (any DiscoveryBrowser)?
    private var browseGeneration: UInt64 = 0
    private let browserQueue = DispatchQueue(label: "com.iPadCasting.discovery", qos: .userInitiated)

    public init() { makeBrowser = { BonjourBrowser() } }
    init(makeBrowser: @escaping () -> any DiscoveryBrowser) { self.makeBrowser = makeBrowser }

    /// Starts scanning for local ScreenCasting services (`_screencasting._tcp`).
    public func startBrowsing() {
        stopBrowsing()

        let generation = browseGeneration
        let browser = makeBrowser()
        self.browser = browser
        browser.start(queue: browserQueue, results: { [weak self] endpoints in
            DispatchQueue.main.async {
                guard let self, self.browseGeneration == generation else { return }
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

    /// Stops browsing for local mDNS services.
    public func stopBrowsing() {
        browseGeneration &+= 1
        browser?.cancel()
        browser = nil
        if !discoveredHosts.isEmpty { discoveredHosts = [] }
    }

    deinit {
        browser?.cancel()
    }
}
