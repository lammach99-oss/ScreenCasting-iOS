import Foundation

struct RemotePairStore {
    struct Pair: Equatable {
        let first: TrustedPeerReference?
        let second: TrustedPeerReference?
        let selected: SlotOrdinal
        static let empty = Pair(first: nil, second: nil, selected: .one)
    }

    private struct Record: Codable {
        let version: Int
        let first: String?
        let second: String?
        let selected: SlotOrdinal
    }

    static let key = "ScreenCasting.remote.pair.v1"
    private let defaults: UserDefaults
    private let isTrusted: (TrustedPeerReference) -> Bool
    private let legacyReference: () -> TrustedPeerReference?

    init(defaults: UserDefaults = .standard,
         directory: TrustedHostFingerprintStore = TrustedHostFingerprintStore()) {
        self.init(defaults: defaults, isTrusted: { peer in
            directory.targets(for: peer.fingerprint).contains { target in
                guard let endpoint = target.endpoint else { return false }
                return RemoteSessionPolicy.isRemoteControl(endpoint: endpoint)
            }
        }, legacyReference: {
            guard let target = WifiReconnectTargetStore.load(defaults: defaults),
                  let endpoint = target.endpoint, RemoteSessionPolicy.isRemoteControl(endpoint: endpoint),
                  let key = directory.load(endpoint: endpoint) else { return nil }
            return TrustedPeerReference(key)
        })
    }

    init(defaults: UserDefaults, isTrusted: @escaping (TrustedPeerReference) -> Bool,
         legacyReference: @escaping () -> TrustedPeerReference?) {
        self.defaults = defaults
        self.isTrusted = isTrusted
        self.legacyReference = legacyReference
    }

    private func normalized(_ first: TrustedPeerReference?, _ second: TrustedPeerReference?,
                            _ selected: SlotOrdinal) -> Pair {
        let selection: SlotOrdinal
        if first == nil && second != nil { selection = .two }
        else if second == nil { selection = .one }
        else { selection = selected }
        return Pair(first: first, second: second, selected: selection)
    }

    private func read() -> Pair {
        guard defaults.object(forKey: Self.key) != nil else {
            guard let peer = legacyReference(), isTrusted(peer) else { return .empty }
            let pair = normalized(peer, nil, .one)
            write(pair)
            return pair
        }
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1 else { return .empty }
        let first = record.first.flatMap(TrustedPeerReference.init)
        let second = record.second.flatMap(TrustedPeerReference.init)
        guard (record.first == nil || first != nil), (record.second == nil || second != nil),
              first == nil || first != second else { return .empty }
        return normalized(first, second, record.selected)
    }

    func load() -> Pair {
        let pair = read()
        return normalized(pair.first.flatMap { isTrusted($0) ? $0 : nil },
                          pair.second.flatMap { isTrusted($0) ? $0 : nil }, pair.selected)
    }

    @discardableResult func save(first: TrustedPeerReference?, second: TrustedPeerReference?,
                                 selected: SlotOrdinal) -> Bool {
        guard first == nil || first != second, [first, second].compactMap({ $0 }).allSatisfy(isTrusted)
        else { return false }
        return write(normalized(first, second, selected))
    }

    func forget(_ peer: TrustedPeerReference) {
        let pair = read()
        write(normalized(pair.first == peer ? nil : pair.first,
                         pair.second == peer ? nil : pair.second, pair.selected))
    }

    @discardableResult private func write(_ pair: Pair) -> Bool {
        let record = Record(version: 1, first: pair.first?.fingerprint, second: pair.second?.fingerprint,
                            selected: pair.selected)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
