import Foundation

public struct RemoteFeaturesMessage: Equatable {
    public let features: UInt64
    public init(features: UInt64) { self.features = features }
    public func encode() -> Data { var d = Data(count: 16); d[0] = 1; d.storeLittleEndian(features, at: 8); return d }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 16, d[0] == 1, d[1..<8].allSatisfy({ $0 == 0 }) else { return nil }
        return Self(features: d.loadLittleEndian(UInt64.self, at: 8))
    }
}

public struct RemoteInputContextCommand: Equatable {
    public let state: UInt8, desktop: UInt8
    public let token: UInt64, desktopEpoch: UInt64
    public let left: Int32, top: Int32
    public let width: UInt32, height: UInt32
    public init(state: UInt8, desktop: UInt8, token: UInt64, desktopEpoch: UInt64, left: Int32, top: Int32, width: UInt32, height: UInt32) {
        self.state = state; self.desktop = desktop; self.token = token; self.desktopEpoch = desktopEpoch
        self.left = left; self.top = top; self.width = width; self.height = height
    }
    public func encode() -> Data? {
        var d = Data(count: 36); d[0] = 1; d[1] = state; d[2] = desktop
        d.storeLittleEndian(token, at: 4); d.storeLittleEndian(desktopEpoch, at: 12)
        d.storeLittleEndian(left, at: 20); d.storeLittleEndian(top, at: 24)
        d.storeLittleEndian(width, at: 28); d.storeLittleEndian(height, at: 32)
        return Self.decode(d) == nil ? nil : d
    }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 36, d[0] == 1, d[1] <= 1, [0, 1, 2, 3, 255].contains(d[2]), d[3] == 0 else { return nil }
        let result = Self(state: d[1], desktop: d[2], token: d.loadLittleEndian(UInt64.self, at: 4),
            desktopEpoch: d.loadLittleEndian(UInt64.self, at: 12), left: d.loadLittleEndian(Int32.self, at: 20),
            top: d.loadLittleEndian(Int32.self, at: 24), width: d.loadLittleEndian(UInt32.self, at: 28), height: d.loadLittleEndian(UInt32.self, at: 32))
        guard result.state == 0 ? result.token == 0 : result.token != 0 && result.desktop != 0 && result.desktop != 255 && result.width > 0 && result.height > 0 else { return nil }
        return result
    }
}

public struct RemoteScanKeyCommand: Equatable {
    public let action: UInt8, flags: UInt8
    public let scan: UInt16, token: UInt64
    public init(action: UInt8, flags: UInt8, scan: UInt16, token: UInt64) { self.action = action; self.flags = flags; self.scan = scan; self.token = token }
    public func encode() -> Data? {
        var d = Data(count: 16); d[0] = 1; d[1] = action; d[2] = flags
        d.storeLittleEndian(scan, at: 4); d.storeLittleEndian(token, at: 8)
        return Self.decode(d) == nil ? nil : d
    }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 16, d[0] == 1, d[1] <= 2, d[2] <= 2, d[3] == 0, d[6] == 0, d[7] == 0 else { return nil }
        let scan = d.loadLittleEndian(UInt16.self, at: 4), token = d.loadLittleEndian(UInt64.self, at: 8)
        guard (1...127).contains(scan), (d[2] != 2 || scan == 0x45), token != 0 else { return nil }
        return Self(action: d[1], flags: d[2], scan: scan, token: token)
    }
}

public struct RemotePointerCommand: Equatable {
    public let kind: UInt8, button: UInt8
    public let token: UInt64
    public let a: Int32, b: Int32
    public init(kind: UInt8, button: UInt8, token: UInt64, a: Int32, b: Int32) { self.kind = kind; self.button = button; self.token = token; self.a = a; self.b = b }
    public func encode() -> Data? {
        var d = Data(count: 24); d[0] = 1; d[1] = kind; d[3] = button; d.storeLittleEndian(token, at: 4)
        d.storeLittleEndian(a, at: 12); d.storeLittleEndian(b, at: 16)
        return Self.decode(d) == nil ? nil : d
    }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 24, d[0] == 1, d[2] == 0, d[20..<24].allSatisfy({ $0 == 0 }) else { return nil }
        let token = d.loadLittleEndian(UInt64.self, at: 4), a = d.loadLittleEndian(Int32.self, at: 12), b = d.loadLittleEndian(Int32.self, at: 16)
        guard token != 0 else { return nil }
        switch d[1] {
        case 0: guard d[3] == 0, (0...65535).contains(a), (0...65535).contains(b) else { return nil }
        case 1, 3: guard d[3] == 0, (-32767...32767).contains(a), (-32767...32767).contains(b) else { return nil }
        case 2: guard (1...5).contains(d[3]), (0...1).contains(a), b == 0 else { return nil }
        default: return nil
        }
        return Self(kind: d[1], button: d[3], token: token, a: a, b: b)
    }
}

public struct RemoteInputResetCommand: Equatable {
    public let reason: UInt8, token: UInt64
    public init(reason: UInt8, token: UInt64) { self.reason = reason; self.token = token }
    public func encode() -> Data? {
        var d = Data(count: 16); d[0] = 1; d[1] = reason; d.storeLittleEndian(token, at: 8)
        return Self.decode(d) == nil ? nil : d
    }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 16, d[0] == 1, d[1] <= 4, d[2..<8].allSatisfy({ $0 == 0 }) else { return nil }
        let token = d.loadLittleEndian(UInt64.self, at: 8)
        return token == 0 ? nil : Self(reason: d[1], token: token)
    }
}

public struct RemoteCommittedTextCommand: Equatable {
    public let token: UInt64
    public let text: String
    public init(token: UInt64, text: String) { self.token = token; self.text = text }
    public func encode() -> Data? {
        guard token != 0, let textBytes = TextCommitCommand(text: text).encode() else { return nil }
        var d = Data(count: 16); d[0] = 1; d.storeLittleEndian(token, at: 8); d.append(textBytes); return d
    }
    public static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard (20...4115).contains(d.count), d[0] == 1, d[1..<8].allSatisfy({ $0 == 0 }),
              let text = TextCommitCommand.decode(Data(d.dropFirst(16))) else { return nil }
        let token = d.loadLittleEndian(UInt64.self, at: 8)
        return token == 0 ? nil : Self(token: token, text: text.text)
    }
}

/// Connection-scoped, networkQueue owned. No unknown ID is sent until marked Pong.
struct RemoteFeatureNegotiation {
    static let supportedFlag: UInt16 = 0x4000
    static let knownFeatures: UInt64 = 3
    private enum Phase { case initial, pong, result, legacy, complete }
    private var phase: Phase = .initial
    private var deadline: TimeInterval = 0
    private(set) var accepted: UInt64 = 0
    private(set) var context: RemoteInputContextCommand?
    private var freshKeyframe = false
    private(set) var revision: UInt64 = 0

    mutating func begin(now: TimeInterval) -> Bool {
        guard phase == .initial else { return false }; deadline = now + 2; phase = .pong; return true
    }
    mutating func expire(now: TimeInterval) {
        if phase == .pong && now >= deadline { phase = .legacy }
    }
    mutating func pong(flags: UInt16, now: TimeInterval) -> Data? {
        guard phase == .pong else { return nil }
        guard now < deadline, flags & Self.supportedFlag != 0 else { phase = .legacy; return nil }
        phase = .result; return RemoteFeaturesMessage(features: Self.knownFeatures).encode()
    }
    mutating func result(flags: UInt16, payload: Data) -> Bool {
        guard phase == .result else { return false }; phase = .legacy
        guard flags == 0, let message = RemoteFeaturesMessage.decode(payload), message.features & ~Self.knownFeatures == 0 else { return false }
        accepted = message.features; phase = .complete; return true
    }
    mutating func receiveContext(flags: UInt16, payload: Data) -> Bool {
        guard phase == .complete, accepted != 0, flags == 0, let value = RemoteInputContextCommand.decode(payload) else { return false }
        invalidateInput(); context = value; return true
    }
    mutating func invalidateInput() { revision &+= 1; context = nil; freshKeyframe = false }
    mutating func keyframeArrived() { if context?.state == 1 { freshKeyframe = true } }
    var inputReady: Bool { context?.state == 1 && freshKeyframe }
    func maySend(feature: UInt64, token: UInt64) -> Bool {
        accepted & feature == feature && context?.state == 1 && context?.token == token && token != 0 && freshKeyframe
    }
}
