import Foundation

struct RemotePhysicalKey: Hashable {
    let scan: UInt16
    let flags: UInt8

    init(scan: UInt16, flags: UInt8 = 0) {
        self.scan = scan
        self.flags = flags
    }

    var isModifier: Bool {
        if flags == 0 { return [0x1d, 0x2a, 0x36, 0x38].contains(scan) }
        return flags == 1 && [0x1d, 0x38, 0x5b, 0x5c].contains(scan)
    }

    var isValid: Bool {
        (1...127).contains(scan) && flags <= 2 && (flags != 2 || scan == 0x45)
    }
}

/// One ready context only. RI-F must discard this value on token/revision changes,
/// gate sends on negotiated readiness, and capture the originating generation.
struct RemoteKeyboardState {
    enum Modifier: String, CaseIterable {
        case shift = "Shift", control = "Ctrl", alt = "Alt", win = "Win"

        var key: RemotePhysicalKey {
            switch self {
            case .shift: return RemotePhysicalKey(scan: 0x2a)
            case .control: return RemotePhysicalKey(scan: 0x1d)
            case .alt: return RemotePhysicalKey(scan: 0x38)
            case .win: return RemotePhysicalKey(scan: 0x5b, flags: 1)
            }
        }
    }

    enum ModifierState: String {
        case off = "Off", oneShot = "One-shot", locked = "Locked"
    }

    let token: UInt64
    private(set) var heldKeys: Set<RemotePhysicalKey> = []
    private var hardware: [Int: RemotePhysicalKey] = [:]
    private var bar: Set<RemotePhysicalKey> = []
    private var sticky: [Modifier: ModifierState] = [:]
    private var lastTap: [Modifier: TimeInterval] = [:]
    private var consumed: [Modifier: Set<RemotePhysicalKey>] = [:]

    init(token: UInt64) { self.token = token }

    func modifierState(_ modifier: Modifier) -> ModifierState { sticky[modifier] ?? .off }
    func isHardwareHeld(usage: Int) -> Bool { hardware[usage] != nil }

    /// An untimed accessibility action reaches the same locked state as double tap.
    mutating func lockModifier(_ modifier: Modifier) -> [RemoteScanKeyCommand] {
        guard token != 0 else { return [] }
        sticky[modifier] = .locked
        lastTap.removeValue(forKey: modifier)
        return reconcile()
    }

    mutating func hardwareDown(usage: Int) -> [RemoteScanKeyCommand] {
        guard token != 0, hardware[usage] == nil,
              let key = RemoteHardwareKeyboard.key(forUsage: usage) else { return [] }
        consumeOneShots(for: key)
        hardware[usage] = key
        return reconcile()
    }

    mutating func hardwareRepeat(usage: Int) -> [RemoteScanKeyCommand] {
        guard let key = hardware[usage], !key.isModifier else { return [] }
        return [command(key, action: 2)]
    }

    mutating func hardwareUp(usage: Int) -> [RemoteScanKeyCommand] {
        guard hardware.removeValue(forKey: usage) != nil else { return [] }
        return reconcile()
    }

    mutating func barKeyDown(_ key: RemotePhysicalKey) -> [RemoteScanKeyCommand] {
        guard token != 0, key.isValid, !key.isModifier, !bar.contains(key) else { return [] }
        consumeOneShots(for: key)
        bar.insert(key)
        return reconcile()
    }

    mutating func barKeyUp(_ key: RemotePhysicalKey) -> [RemoteScanKeyCommand] {
        guard bar.remove(key) != nil else { return [] }
        return reconcile()
    }

    mutating func tapKey(_ key: RemotePhysicalKey) -> [RemoteScanKeyCommand] {
        guard token != 0, key.isValid, !key.isModifier else { return [] }
        if heldKeys.contains(key) { return [command(key, action: 2)] }
        let down = barKeyDown(key)
        return down + barKeyUp(key)
    }

    /// Call once per activation with monotonic time; two activations within 300 ms lock.
    mutating func tapModifier(_ modifier: Modifier, at time: TimeInterval) -> [RemoteScanKeyCommand] {
        guard token != 0, time.isFinite else { return [] }
        switch modifierState(modifier) {
        case .off:
            sticky[modifier] = .oneShot
            lastTap[modifier] = time
        case .oneShot:
            let previous = lastTap[modifier] ?? -.infinity
            sticky[modifier] = time >= previous && time <= previous + 0.3 ? .locked : .off
            lastTap.removeValue(forKey: modifier)
        case .locked:
            sticky[modifier] = .off
            lastTap.removeValue(forKey: modifier)
        }
        return reconcile()
    }

    /// Returns best-effort ups in deterministic order, ordinary keys before modifiers.
    /// If the context is retired, discard these commands instead of rebinding their token.
    mutating func reset() -> [RemoteScanKeyCommand] {
        let releases = heldKeys.sorted(by: Self.releaseOrder).map { command($0, action: 1) }
        hardware.removeAll()
        bar.removeAll()
        sticky.removeAll()
        lastTap.removeAll()
        consumed.removeAll()
        heldKeys.removeAll()
        return releases
    }

    private mutating func consumeOneShots(for key: RemotePhysicalKey) {
        guard !key.isModifier, !heldKeys.contains(key) else { return }
        for modifier in Modifier.allCases where modifierState(modifier) == .oneShot {
            consumed[modifier, default: []].insert(key)
            sticky[modifier] = .off
            lastTap.removeValue(forKey: modifier)
        }
    }

    private mutating func reconcile() -> [RemoteScanKeyCommand] {
        var desired = Set(hardware.values).union(bar)
        for modifier in Modifier.allCases {
            let targets = (consumed[modifier] ?? []).intersection(desired)
            consumed[modifier] = targets
            if modifierState(modifier) != .off || !targets.isEmpty { desired.insert(modifier.key) }
        }
        let releases = heldKeys.subtracting(desired).sorted(by: Self.releaseOrder)
        let downs = desired.subtracting(heldKeys).sorted {
            if $0.isModifier != $1.isModifier { return $0.isModifier }
            return Self.keyOrder($0, $1)
        }
        heldKeys = desired
        return releases.map { command($0, action: 1) } + downs.map { command($0, action: 0) }
    }

    private func command(_ key: RemotePhysicalKey, action: UInt8) -> RemoteScanKeyCommand {
        RemoteScanKeyCommand(action: action, flags: key.flags, scan: key.scan, token: token)
    }

    private static func releaseOrder(_ a: RemotePhysicalKey, _ b: RemotePhysicalKey) -> Bool {
        if a.isModifier != b.isModifier { return !a.isModifier }
        return keyOrder(a, b)
    }

    private static func keyOrder(_ a: RemotePhysicalKey, _ b: RemotePhysicalKey) -> Bool {
        a.flags == b.flags ? a.scan < b.scan : a.flags < b.flags
    }
}
