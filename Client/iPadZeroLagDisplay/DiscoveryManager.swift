import Foundation
import Network
import Combine
import Darwin
import dnssd
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

struct RemoteServiceRecord {
    let host: String?
    let port: UInt16
    let addresses: [Data]

    func admittedTarget(type: String, capabilities: ClientDeviceCapabilities) -> RemoteIntent.Target? {
        func admit(_ candidate: String) -> RemoteIntent.Target? {
            let intent = RemoteIntent.discovered(serviceType: type, resolved: .init(host: candidate, port: port))
            guard case .success(let address) = RemoteSessionPolicy.admit(intent, for: capabilities) else { return nil }
            return .init(host: address.host, port: port)
        }
        if let host, let target = admit(host) { return target }
        for family in [AF_INET, AF_INET6] {
            for data in addresses {
                var storage = sockaddr_storage()
                let size = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
                guard data.count >= size else { continue }
                withUnsafeMutableBytes(of: &storage) { bytes in
                    data.copyBytes(to: bytes.bindMemory(to: UInt8.self).baseAddress!, count: size)
                }
                guard storage.ss_family == sa_family_t(family), Int(storage.ss_len) == size else { continue }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(size), &name, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                    }
                }
                guard result == 0 else { continue }
                let numeric = String(cString: name)
                if family == AF_INET6 {
                    // An unscoped dial cannot identify the correct link for a link-local address.
                    guard !numeric.contains("%"), let bytes = IPv6Address(numeric)?.rawValue,
                          !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) else { continue }
                }
                if let target = admit(numeric) { return target }
            }
        }
        return nil
    }

    func displayName(instance: String) -> String {
        // DNS presentation form may escape a label byte as \DDD (decimal).
        var label = host ?? ""
        if label.hasSuffix(".") { label.removeLast() }
        if label.lowercased().hasSuffix(".local") { label.removeLast(6) }
        let raw = Array(label.utf8)
        var decoded = [UInt8]()
        var index = 0
        while index < raw.count {
            if raw[index] == 92, index + 1 < raw.count {
                index += 1
                let digits = raw[index..<min(index + 3, raw.count)]
                if digits.count == 3, digits.allSatisfy({ (48...57).contains($0) }),
                   let byte = UInt8(String(decoding: digits, as: UTF8.self)) {
                    decoded.append(byte)
                    index += 3
                    continue
                }
            }
            decoded.append(raw[index])
            index += 1
        }
        for candidate in [String(bytes: decoded, encoding: .utf8) ?? "", instance] {
            let clean = candidate.components(separatedBy: .controlCharacters).joined()
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            if !clean.isEmpty { return String(clean.prefix(63)) }
        }
        return "PC"
    }
}

// Resolve DNS-SD records without connecting to an unvalidated advertised port.
private final class RemoteServiceResolution: NSObject, NetServiceDelegate {
    private let service: NetService
    let completion: (RemoteServiceRecord?) -> Void

    init(name: String, domain: String, completion: @escaping (RemoteServiceRecord?) -> Void) {
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
        guard sender === service, let port = UInt16(exactly: sender.port) else {
            completion(nil)
            return
        }
        completion(.init(host: sender.hostName, port: port, addresses: sender.addresses ?? []))
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

    enum Status { case browsing, empty, denied, failed }
    struct RemoteRow: Identifiable {
        let displayName: String
        let target: RemoteIntent.Target
        // Admission fixes the port for every destination.
        var id: String { target.host }
        var intent: RemoteIntent { .discovered(serviceType: RemoteSessionPolicy.remoteServiceType, resolved: target) }
    }
    @Published private(set) var status: Status = .browsing
    @Published private(set) var remoteRows: [RemoteRow] = []
    var discoveredRemoteIntents: [RemoteIntent] {
        status == .browsing ? remoteRows.map(\.intent) : []
    }
    private var browserReady = false
    private let capabilities: ClientDeviceCapabilities
    typealias ServiceResolver = (String, String, @escaping (RemoteServiceRecord?) -> Void) -> () -> Void
    private let resolveService: ServiceResolver
    private var resolutions: [NWEndpoint: (id: UUID, cancel: () -> Void)] = [:]
    private var resolved: [NWEndpoint: RemoteRow] = [:]
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
                if !self.capabilities.allowsCasting {
                    self.updateRemoteState(state)
                    return
                }
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

    private func updateRemoteState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            browserReady = true
            publishRemoteResults()
        case .waiting(let error), .failed(let error):
            if case .failed = state { stopBrowsing() }
            browserReady = false
            // Apple TN3179: Bonjour reports local network policy via NWError.dns.
            if case .dns(let code) = error, Int(code) == kDNSServiceErr_PolicyDenied {
                status = .denied
            } else {
                status = .failed
            }
        case .cancelled: stopBrowsing()
        default: break
        }
    }

    private func updateRemoteResults(_ endpoints: Set<NWEndpoint>, generation: UInt64) {
        for endpoint in Array(resolutions.keys) where !endpoints.contains(endpoint) {
            resolutions.removeValue(forKey: endpoint)?.cancel()
            resolved.removeValue(forKey: endpoint)
        }
        for endpoint in endpoints where resolutions[endpoint] == nil {
            guard case .service(let name, let type, let domain, _) = endpoint,
                  !name.isEmpty, domain.lowercased() == "local.",
                  [RemoteSessionPolicy.remoteServiceType, RemoteSessionPolicy.remoteServiceType + "."].contains(type.lowercased())
            else { continue }
            let id = UUID()
            let cancel = resolveService(name, domain) { [weak self] record in
                DispatchQueue.main.async {
                    guard let self, self.browseGeneration == generation,
                          self.resolutions[endpoint]?.id == id else { return }
                    self.resolutions[endpoint]?.cancel()
                    if let record, let target = record.admittedTarget(type: type, capabilities: self.capabilities) {
                        self.resolved[endpoint] = .init(displayName: record.displayName(instance: name), target: target)
                    } else {
                        self.resolved.removeValue(forKey: endpoint)
                        self.resolutions.removeValue(forKey: endpoint)
                    }
                    self.publishRemoteResults()
                }
            }
            resolutions[endpoint] = (id, cancel)
        }
        publishRemoteResults()
    }

    private func publishRemoteResults() {
        var seen = Set<String>()
        remoteRows = resolved.values.sorted {
            ($0.displayName, $0.id) < ($1.displayName, $1.id)
        }.filter { seen.insert($0.id).inserted }
        if browserReady {
            status = resolutions.isEmpty ? .empty : .browsing
        }
    }

    /// Stops browsing for local mDNS services.
    public func stopBrowsing() {
        browseGeneration &+= 1
        resolutions.values.forEach { $0.cancel() }
        resolutions.removeAll()
        resolved.removeAll()
        browserReady = false
        status = .browsing
        if !remoteRows.isEmpty { remoteRows = [] }
        browser?.cancel()
        browser = nil
        if !discoveredHosts.isEmpty { discoveredHosts = [] }
    }

    deinit {
        resolutions.values.forEach { $0.cancel() }
        browser?.cancel()
    }
}
