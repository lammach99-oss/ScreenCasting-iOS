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

struct DiscoveryAdvertisement: Hashable {
    struct Key: Hashable {
        let endpoint: NWEndpoint
        let interfaceIndex: UInt32
    }

    let key: Key
    let interface: NWInterface?
    let changed: Bool

    init(endpoint: NWEndpoint, interface: NWInterface? = nil, interfaceIndex: UInt32 = 0, changed: Bool = false) {
        self.interface = interface
        key = Key(endpoint: endpoint, interfaceIndex: interface.map { UInt32($0.index) } ?? interfaceIndex)
        self.changed = changed
    }
}

// A selection can outlive its row. Admission also reads this on the network queue.
final class RemoteDiscoveryLink {
    let index: UInt32
    let interface: NWInterface?
    private let lock = NSLock()
    private var live = true

    init(_ advertisement: DiscoveryAdvertisement) {
        index = advertisement.key.interfaceIndex
        interface = advertisement.interface
    }

    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return live
    }

    func dialHost(_ host: String) -> NWEndpoint.Host? {
        guard let interface else {
            return index == 0 ? RemoteHostAddress.networkHost(host) : nil
        }
        if let address = IPv4Address(host) {
            return IPv4Address(address.rawValue, interface).map { .ipv4($0) }
        }
        if let address = IPv6Address(host) {
            return IPv6Address(address.rawValue, interface).map { .ipv6($0) }
        }
        return .name(host, interface)
    }

    func invalidate() {
        lock.lock()
        live = false
        lock.unlock()
    }
}

protocol DiscoveryBrowser: Sendable {
    func start(queue: DispatchQueue, results: @escaping @Sendable ([DiscoveryAdvertisement]) -> Void,
               state: @escaping @Sendable (NWBrowser.State) -> Void)
    func cancel()
}

private final class BonjourBrowser: DiscoveryBrowser {
    private let browser: NWBrowser
    private let remote: Bool
    init(type: String = "_screencasting._tcp") {
        remote = type == RemoteSessionPolicy.remoteServiceType
        let descriptor: NWBrowser.Descriptor = remote ? .bonjourWithTXTRecord(type: type, domain: "local.")
                                                     : .bonjour(type: type, domain: "local.")
        browser = NWBrowser(for: descriptor, using: .tcp)
    }

    func start(queue: DispatchQueue, results: @escaping @Sendable ([DiscoveryAdvertisement]) -> Void,
               state: @escaping @Sendable (NWBrowser.State) -> Void) {
        browser.browseResultsChangedHandler = { [remote] records, changes in
            let changed = Set(changes.compactMap { change -> NWEndpoint? in
                switch change {
                case .changed(_, let new, _), .added(let new): return new.endpoint
                default: return nil
                }
            })
            results(records.flatMap { record -> [DiscoveryAdvertisement] in
                guard remote, case .service(_, _, _, let scoped) = record.endpoint else {
                    return [.init(endpoint: record.endpoint)]
                }
                let interfaces = scoped.map { [$0] } ?? record.interfaces
                let refresh = changed.contains(record.endpoint)
                if interfaces.isEmpty { return [.init(endpoint: record.endpoint, changed: refresh)] }
                return interfaces.map { .init(endpoint: record.endpoint, interface: $0, changed: refresh) }
            })
        }
        browser.stateUpdateHandler = { state($0) }
        browser.start(queue: queue)
    }

    func cancel() { browser.cancel() }
}

struct RemoteServiceRecord {
    let host: String?
    let port: UInt16
    let addresses: [Data]

    func admittedTarget(type: String, capabilities: ClientDeviceCapabilities, interfaceIndex: UInt32 = 0) -> RemoteIntent.Target? {
        func admit(_ candidate: String) -> RemoteIntent.Target? {
            let intent = RemoteIntent.discovered(serviceType: type, resolved: .init(host: candidate, port: port))
            guard case .success(let address) = RemoteSessionPolicy.admit(intent, for: capabilities) else { return nil }
            return .init(host: address.host, port: port)
        }
        if let host, IPv6Address(host)?.isLinkLocal != true, let target = admit(host) { return target }
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
                var numeric = String(cString: name)
                if family == AF_INET6 {
                    let literal = String(numeric.prefix { $0 != "%" })
                    guard let address = IPv6Address(literal) else { continue }
                    if address.isLinkLocal {
                        let scope = withUnsafePointer(to: &storage) {
                            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_scope_id }
                        }
                        guard scope == 0 || interfaceIndex == 0 || scope == interfaceIndex else { continue }
                        let index = scope == 0 ? interfaceIndex : scope
                        var zone = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        guard index != 0, if_indextoname(index, &zone) != nil else { continue }
                        numeric = literal + "%" + String(cString: zone)
                    }
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
private final class RemoteServiceResolution {
    // Apple mDNSShared/dns_sd.h: DNSServiceResolveReply supplies a network-order
    // port and interface index. DNSServiceGetAddrInfoReply borrows a sockaddr.
    // DNSServiceSetDispatchQueue and DNSServiceRefDeallocate share this serial queue.
    private let queue = DispatchQueue(label: "ScreenCasting.remote-resolution")
    private let name: String
    private let domain: String
    private let interfaceIndex: UInt32
    private var timeout: DispatchSourceTimer?
    private var completion: ((RemoteServiceRecord?) -> Void)?
    private var ref: DNSServiceRef?
    private var host: String?
    private var port: UInt16 = 0
    private var addresses: [Data] = []

    init(name: String, domain: String, interfaceIndex: UInt32, completion: @escaping (RemoteServiceRecord?) -> Void) {
        self.name = name
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.completion = completion
    }

    func start() {
        queue.async {
            self.scheduleTimeout(deadline: .now() + 5) { [weak self] in self?.finish() }
            var service: DNSServiceRef?
            let error = DNSServiceResolve(&service, 0, self.interfaceIndex, self.name, RemoteSessionPolicy.remoteServiceType,
                                          self.domain, { _, _, interface, error, _, target, port, _, _, context in
                guard let context else { return }
                let owner = Unmanaged<RemoteServiceResolution>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError, let target else { owner.finish(); return }
                owner.resolved(String(cString: target), port: UInt16(bigEndian: port), interface: interface)
            }, Unmanaged.passUnretained(self).toOpaque())
            self.schedule(service, error: error)
        }
    }

    private func scheduleTimeout(deadline: DispatchTime, handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler(handler: handler)
        timer.schedule(deadline: deadline)
        timeout = timer
        timer.resume()
    }

    private func schedule(_ service: DNSServiceRef?, error: DNSServiceErrorType) {
        guard error == kDNSServiceErr_NoError, let service else { finish(); return }
        ref = service
        if DNSServiceSetDispatchQueue(service, queue) != kDNSServiceErr_NoError { finish() }
    }

    private func resolved(_ target: String, port: UInt16, interface: UInt32) {
        guard port == NetworkManager.remoteControlPort else { finish(); return }
        self.host = target
        self.port = port
        if RemoteHostAddress.parse(target) != nil, IPv6Address(target)?.isLinkLocal != true { finish(); return }

        releaseRef()
        var service: DNSServiceRef?
        let families = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let error = DNSServiceGetAddrInfo(&service, 0, interface, families, target, {
            _, flags, index, error, _, address, _, context in
            guard let context else { return }
            let owner = Unmanaged<RemoteServiceResolution>.fromOpaque(context).takeUnretainedValue()
            // A negative answer for one family can precede a positive answer for the other.
            if error == kDNSServiceErr_NoSuchRecord { return }
            guard error == kDNSServiceErr_NoError, let address else { owner.finish(); return }
            owner.update(address, flags: flags, interface: index)
        }, Unmanaged.passUnretained(self).toOpaque())
        schedule(service, error: error)
    }

    private func update(_ address: UnsafePointer<sockaddr>, flags: DNSServiceFlags, interface: UInt32) {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return }
        let size = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
        guard Int(address.pointee.sa_len) == size else { return }
        var data = Data(bytes: address, count: size)
        if family == AF_INET6 {
            var socket = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
            let linkLocal = withUnsafeBytes(of: &socket.sin6_addr) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
            if linkLocal && socket.sin6_scope_id == 0 { socket.sin6_scope_id = interface }
            data = withUnsafeBytes(of: &socket) { Data($0) }
        }
        addresses.removeAll { $0 == data }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { addresses.append(data) }
        // Keep IPv6 until the deadline so a later IPv4 answer can take precedence.
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0,
           addresses.contains(where: { $0[1] == UInt8(AF_INET) }) { finish() }
    }

    private func releaseRef() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        releaseRef()
        let callback = completion
        completion = nil
        guard let callback else { return }
        let record = host.map { RemoteServiceRecord(host: $0, port: port, addresses: addresses) }
        DispatchQueue.main.async { callback(record) }
    }

    func cancel() {
        queue.async {
            self.timeout?.cancel()
            self.timeout = nil
            self.releaseRef()
            self.completion = nil
        }
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
        var id: String { "\(target.host)@\(target.discoveryLink?.index ?? 0)" }
        var intent: RemoteIntent { .discovered(serviceType: RemoteSessionPolicy.remoteServiceType, resolved: target) }
    }
    @Published private(set) var status: Status = .browsing
    @Published private(set) var remoteRows: [RemoteRow] = []
    var discoveredRemoteIntents: [RemoteIntent] {
        status == .browsing ? remoteRows.map(\.intent) : []
    }
    private var browserReady = false
    private let capabilities: ClientDeviceCapabilities
    typealias ServiceResolver = (String, String, UInt32, @escaping (RemoteServiceRecord?) -> Void) -> () -> Void
    private let resolveService: ServiceResolver
    private var resolutions: [DiscoveryAdvertisement.Key: (id: UUID, cancel: () -> Void)] = [:]
    private var resolved: [DiscoveryAdvertisement.Key: RemoteRow] = [:]
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
         resolveService: @escaping ServiceResolver = { name, domain, index, completion in
             let resolver = RemoteServiceResolution(name: name, domain: domain, interfaceIndex: index, completion: completion)
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
                let hosts = endpoints.map { advertisement -> DiscoveredHost in
                    let endpoint = advertisement.key.endpoint
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

    private func updateRemoteResults(_ endpoints: Set<DiscoveryAdvertisement>, generation: UInt64,
                                     attempt: Int = 1) {
        // Only a browser snapshot can withdraw or replace an advertisement.
        if attempt == 1 {
            let present = Set(endpoints.map(\.key))
            let changed = Set(endpoints.filter(\.changed).map(\.key))
            for endpoint in Array(resolutions.keys) where !present.contains(endpoint) || changed.contains(endpoint) {
                resolved.removeValue(forKey: endpoint)?.target.discoveryLink?.invalidate()
                resolutions.removeValue(forKey: endpoint)?.cancel()
            }
        }
        for advertisement in endpoints where resolutions[advertisement.key] == nil {
            guard case .service(let name, let type, let domain, _) = advertisement.key.endpoint,
                  !name.isEmpty, domain.lowercased() == "local.",
                  [RemoteSessionPolicy.remoteServiceType, RemoteSessionPolicy.remoteServiceType + "."].contains(type.lowercased())
            else { continue }
            let key = advertisement.key
            let id = UUID()
            let cancel = resolveService(name, domain, key.interfaceIndex) { [weak self] record in
                DispatchQueue.main.async {
                    guard let self, self.browseGeneration == generation, self.resolutions[key]?.id == id else { return }
                    self.resolutions[key]?.cancel()
                    let completed = UUID()
                    self.resolutions[key] = (completed, {})
                    if let record, var target = record.admittedTarget(type: type, capabilities: self.capabilities,
                                                                      interfaceIndex: key.interfaceIndex) {
                        target.discoveryLink = RemoteDiscoveryLink(advertisement)
                        self.resolved[key] = .init(displayName: record.displayName(instance: name), target: target)
                    } else if attempt < 3 {
                        let timer = DispatchSource.makeTimerSource(queue: .main)
                        timer.schedule(deadline: .now() + .seconds(1 << (attempt - 1)))
                        timer.setEventHandler { [weak self] in
                            guard let self, self.resolutions[key]?.id == completed else { return }
                            self.resolutions.removeValue(forKey: key)?.cancel()
                            self.updateRemoteResults([advertisement], generation: generation, attempt: attempt + 1)
                        }
                        self.resolutions[key] = (completed, { timer.cancel() })
                        timer.resume()
                    }
                    self.publishRemoteResults()
                }
            }
            resolutions[key] = (id, cancel)
        }
        publishRemoteResults()
    }

    private func publishRemoteResults() {
        var seen = Set<String>()
        remoteRows = resolved.values.sorted {
            ($0.displayName, $0.id) < ($1.displayName, $1.id)
        }.filter { seen.insert($0.id).inserted }
        if browserReady {
            status = remoteRows.isEmpty ? .empty : .browsing
        }
    }

    /// Stops browsing for local mDNS services.
    public func stopBrowsing() {
        browseGeneration &+= 1
        resolutions.values.forEach { $0.cancel() }
        resolutions.removeAll()
        resolved.values.forEach { $0.target.discoveryLink?.invalidate() }
        resolved.removeAll()
        browserReady = false
        status = .browsing
        if !remoteRows.isEmpty { remoteRows = [] }
        browser?.cancel()
        browser = nil
        if !discoveredHosts.isEmpty { discoveredHosts = [] }
    }

    deinit {
        resolved.values.forEach { $0.target.discoveryLink?.invalidate() }
        resolutions.values.forEach { $0.cancel() }
        browser?.cancel()
    }
}
