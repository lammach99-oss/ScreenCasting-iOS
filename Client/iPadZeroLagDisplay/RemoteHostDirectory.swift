import Foundation
import Network

struct RemoteHostAddress: Equatable {
    enum Kind: Equatable { case ipv4, dnsName }
    let host: String
    let kind: Kind

    static func parse(_ raw: String) -> RemoteHostAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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

    var isTailnet: Bool {
        switch kind {
        case .ipv4:
            let octets = host.split(separator: ".")
            guard octets.count == 4, Int(octets[0]) == 100, let second = Int(octets[1]) else { return false }
            return (64...127).contains(second)
        case .dnsName:
            return host.hasSuffix(".ts.net") || (!host.contains(".") && host != "localhost")
        }
    }
}

enum RemoteSessionPolicy {
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
