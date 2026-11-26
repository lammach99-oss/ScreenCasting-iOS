import Foundation
import Network
import UIKit

struct ClientDeviceCapabilities: Equatable {
    enum Family { case pad, phone, unknown }
    let family: Family

    var allowsCasting: Bool { family == .pad }
    var allowsUSB: Bool { family == .pad }
    var allowsSecondPC: Bool { family == .pad }
    var allowsFileTransfer: Bool { family == .pad }
    var allowsPencil: Bool { family == .pad }
    var allowsRemoteControl: Bool { family == .pad || family == .phone }

    static func resolve(_ idiom: UIUserInterfaceIdiom) -> Self {
        switch idiom {
        case .pad: return Self(family: .pad)
        case .phone: return Self(family: .phone)
        default: return Self(family: .unknown)
        }
    }
}

struct RemoteHostAddress: Equatable {
    enum Kind: Equatable { case ipv4, ipv6, dnsName }
    let host: String
    let kind: Kind

    static func parse(_ raw: String) -> RemoteHostAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let literal = unbracketIPv6(trimmed)
        if literal.contains(":"), IPv6Address(literal) != nil {
            let host = literal.contains("%") ? literal : literal.lowercased()
            return RemoteHostAddress(host: host, kind: .ipv6)
        }
        let octets = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 && octets.allSatisfy({ octet in
            guard !octet.isEmpty, octet.count <= 3,
                  octet.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(octet), (0...255).contains(value) else { return false }
            return true
        }) {
            return RemoteHostAddress(host: trimmed, kind: .ipv4)
        }

        var name = trimmed.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard (1...253).contains(name.utf8.count) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), !labels.allSatisfy({ label in label.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        return RemoteHostAddress(host: name, kind: .dnsName)
    }

    static func parseManual(_ raw: String, port: UInt16) -> RemoteHostAddress? {
        if let host = parse(raw) { return host }

        var authority = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = authority.range(of: "://") {
            let scheme = authority[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            authority = String(authority[separator.upperBound...])
            if authority.hasSuffix("/") { authority.removeLast() }
        }
        guard authority.hasPrefix("["), let close = authority.firstIndex(of: "]"),
              let host = parse(String(authority[...close])), host.kind == .ipv6 else { return nil }
        let suffix = authority[authority.index(after: close)...]
        if !suffix.isEmpty {
            let digits = suffix.dropFirst()
            guard suffix.hasPrefix(":"), !digits.isEmpty,
                  digits.utf8.allSatisfy({ (48...57).contains($0) }), UInt16(digits) == port else { return nil }
        }
        return host
    }

    static func networkHost(_ host: String) -> NWEndpoint.Host {
        let literal = unbracketIPv6(host)
        if literal.contains(":"), let address = IPv6Address(literal) { return .ipv6(address) }
        return NWEndpoint.Host(host)
    }

    private static func unbracketIPv6(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    var isTailnet: Bool {
        switch kind {
        case .ipv4:
            let octets = host.split(separator: ".")
            guard octets.count == 4, Int(octets[0]) == 100, let second = Int(octets[1]) else { return false }
            return (64...127).contains(second)
        case .ipv6:
            let tailnetPrefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
            return IPv6Address(host)?.rawValue.starts(with: tailnetPrefix) == true
        case .dnsName:
            return host.hasSuffix(".ts.net") || (!host.contains(".") && host != "localhost")
        }
    }
}

enum RemoteIntent {
    struct Target {
        let host: String
        let port: UInt16
    }

    struct ResumeContext: Equatable {
        let generation: UInt64
        let fingerprint: String
    }

    case manual(Target)
    case recent(RecentRemoteHost)
    /// Supply the advertised type and its resolution from the same browse result.
    case discovered(serviceType: String?, resolved: Target?)
    case resume(Target, remoteControl: Bool, saved: ResumeContext)
    case usb
    case pairSelection
}

enum RemoteAdmissionRejection: Error, Equatable {
    case unsupportedFamily, wrongPort, invalidAddress, castingMode, unresolvedService
    case unclassifiedService, staleResume, usbTransport, pairSelection
}

enum RemoteSessionPolicy {
    static let remoteServiceType = "_sc-remote._tcp"

    /// Every success is a Remote IP dial on NetworkManager.remoteControlPort.
    static func admit(_ intent: RemoteIntent, for capabilities: ClientDeviceCapabilities,
                      current: RemoteIntent.ResumeContext? = nil) -> Result<RemoteHostAddress, RemoteAdmissionRejection> {
        guard capabilities.allowsRemoteControl else { return .failure(.unsupportedFamily) }
        let target: RemoteIntent.Target
        switch intent {
        case .manual(let manual):
            guard manual.port == NetworkManager.remoteControlPort else { return .failure(.wrongPort) }
            guard let address = RemoteHostAddress.parseManual(manual.host, port: manual.port) else { return .failure(.invalidAddress) }
            return .success(address)
        case .recent(let recent):
            guard recent.remoteControl else { return .failure(.castingMode) }
            target = .init(host: recent.host, port: recent.port)
        case .discovered(let serviceType, let resolved):
            let type = serviceType?.lowercased()
            guard type == remoteServiceType || type == remoteServiceType + "." else { return .failure(.unclassifiedService) }
            guard let resolved else { return .failure(.unresolvedService) }
            target = resolved
        case .resume(let savedTarget, let remoteControl, let saved):
            guard remoteControl else { return .failure(.castingMode) }
            guard !saved.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  saved == current else { return .failure(.staleResume) }
            target = savedTarget
        case .usb: return .failure(.usbTransport)
        case .pairSelection: return .failure(.pairSelection)
        }
        guard target.port == NetworkManager.remoteControlPort else { return .failure(.wrongPort) }
        guard let address = RemoteHostAddress.parse(target.host) else { return .failure(.invalidAddress) }
        return .success(address)
    }

    static func isRemoteControl(endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(_, let port) = endpoint else { return false }
        return port.rawValue == NetworkManager.remoteControlPort
    }
}

struct RecentRemoteHost: Codable, Equatable, Identifiable {
    let host: String
    let remoteControl: Bool
    let lastUsed: Date
    var port: UInt16 { remoteControl ? NetworkManager.remoteControlPort : 27015 }
    var id: String { "\(host)|\(remoteControl)" }
}

enum RecentRemoteHostStore {
    static let limit = 5
    private static let key = "ScreenCasting.client.recentRemoteHosts.v1"

    static func load(defaults: UserDefaults = .standard) -> [RecentRemoteHost] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([RecentRemoteHost].self, from: data) else { return [] }
        return Array(entries.prefix(limit))
    }

    @discardableResult static func record(
        host: String,
        remoteControl: Bool,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> [RecentRemoteHost] {
        var entries = load(defaults: defaults)
        guard let address = RemoteHostAddress.parse(host) else { return entries }
        entries.removeAll { $0.host == address.host && $0.remoteControl == remoteControl }
        entries.insert(RecentRemoteHost(host: address.host, remoteControl: remoteControl, lastUsed: now), at: 0)
        entries = Array(entries.prefix(limit))
        save(entries, defaults: defaults)
        return entries
    }

    @discardableResult static func remove(
        host: String,
        remoteControl: Bool,
        defaults: UserDefaults = .standard
    ) -> [RecentRemoteHost] {
        var entries = load(defaults: defaults)
        guard let address = RemoteHostAddress.parse(host) else { return entries }
        entries.removeAll { $0.host == address.host && $0.remoteControl == remoteControl }
        save(entries, defaults: defaults)
        return entries
    }

    private static func save(_ entries: [RecentRemoteHost], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
