import Foundation
import Network
import Combine

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

/// Discovers ScreenCasting Windows host instances on the local LAN using Apple's native `NWBrowser` (mDNS / Bonjour).
public class DiscoveryManager: ObservableObject {
    /// Array of active, resolved ScreenCasting hosts discovered on the local network.
    @Published public var discoveredHosts: [DiscoveredHost] = []

    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.iPadCasting.discovery", qos: .userInitiated)

    public init() {}

    /// Starts scanning for local ScreenCasting services (`_screencasting._tcp`).
    public func startBrowsing() {
        stopBrowsing()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_screencasting._tcp", domain: "local.")
        let parameters = NWParameters.tcp

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }

            let hosts = results.compactMap { result -> DiscoveredHost? in
                switch result.endpoint {
                case .service(let name, _, _, _):
                    return DiscoveredHost(name: name, endpoint: result.endpoint)
                default:
                    return DiscoveredHost(name: "ScreenCasting Host", endpoint: result.endpoint)
                }
            }

            DispatchQueue.main.async {
                self.discoveredHosts = hosts
            }
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("[DiscoveryManager] NWBrowser failed with error: \(error)")
            default:
                break
            }
        }

        browser.start(queue: browserQueue)
        self.browser = browser
    }

    /// Stops browsing for local mDNS services.
    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    deinit {
        stopBrowsing()
    }
}
