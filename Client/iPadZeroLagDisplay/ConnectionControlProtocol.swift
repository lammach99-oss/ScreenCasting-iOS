import Foundation
import CryptoKit

public enum ConnectionRoute: UInt8, CaseIterable {
    case unknown = 0, wifi = 1, usb = 2
    public var label: String { self == .usb ? "USB" : "Wi-Fi" }
}
public enum ConnectionAvailability: UInt8 { case unknown = 0, available = 1, unavailable = 2, detectedUnverified = 3 }
public enum ConnectionHostState: UInt8 {
    case idle = 0, ready, preflighting, awaitingPermission, switching, waitingPeer, waitingFrame, failed
}
public enum ConnectionReason: UInt16 {
    case none = 0, notRunning, notOwner, staleRevision, replay, permissionMissing, permissionDenied
    case localOperation, stoppedOnPC, noDevice, multipleDevices, wrongDevice, deviceUnverified
    case listenerClosed, tunnelUnavailable, proofFailed, peerTimeout, teardownFailed, startFailed
    case firstFrameTimeout, connectionLost, evidenceStale, notChecked, duplicateTransaction
    case identityUnavailable, deadlineExceeded

    public func text(target: ConnectionRoute) -> String {
        switch self {
        case .none: return ""
        case .notRunning: return "Start casting on the PC"
        case .notOwner, .replay: return "Connection request is no longer valid"
        case .staleRevision, .evidenceStale: return "Refresh connection status"
        case .permissionMissing: return "Allow connection changes on the PC"
        case .permissionDenied: return "Connection change denied on PC"
        case .localOperation: return "PC is busy. Try again."
        case .stoppedOnPC: return "Casting stopped on PC"
        case .noDevice: return "Connect a USB cable"
        case .multipleDevices: return "Connect only this iPad by USB"
        case .wrongDevice, .proofFailed: return "USB connection could not be verified"
        case .deviceUnverified: return "USB cable detected, not verified"
        case .listenerClosed: return target == .wifi ? "Wi-Fi listener is unavailable on PC" : "USB listener is unavailable on iPad"
        case .tunnelUnavailable: return "USB connection unavailable"
        case .peerTimeout: return "Connection check timed out"
        case .connectionLost: return "Connection lost"
        case .notChecked: return target == .wifi ? "Connection recommendation unavailable" : "USB availability not checked"
        case .identityUnavailable: return "Pair this iPad before changing connection"
        case .duplicateTransaction: return ""
        case .teardownFailed, .startFailed, .firstFrameTimeout, .deadlineExceeded:
            return "Connection check failed. Current connection kept."
        }
    }
}
public enum ConnectionHelloKind: UInt8 { case optIn = 0, resumeProof = 4 }
public enum ConnectionStatePhase: UInt8 { case snapshot = 0, prepareUSB = 1, prepareWiFi = 2 }
public enum ConnectionResultStatus: UInt8 { case accepted = 0, alreadyActive, denied, permissionRequired, unavailable, busy, failed, completed }
public enum ConnectionFrameDomain: UInt8 { case none = 0, scst, rtp }
public enum ConnectionControlError: Error { case malformed }

public enum ConnectionControlProtocol {
    public static let advertisementFlag: UInt16 = 0x0200
    static let protectedHandoffFlag: UInt16 = 0x0100
    static let usbProbeFlag: UInt16 = 0x0400
    static let usbProbeLength = 48
    static let usbProbeWait: TimeInterval = 3
    static let rollbackWait: TimeInterval = 120
    // Allow for host preflight, teardown, Wi-Fi startup/first frame, cleanup and USB restore.
    static let wifiOutcomeWait: TimeInterval = 110
    static let usbRollbackWait: TimeInterval = 165
    public static let preflightWait: TimeInterval = 15
    public static let listenerWait: TimeInterval = 5
    public static let outcomeWait: TimeInterval = 75
    public static let presentationWait: TimeInterval = 5
    public static let absoluteWait: TimeInterval = 80
    public static let lease: TimeInterval = 10
    static func validInbound(type: UInt8, flags: UInt16, length: Int) -> Bool {
        flags == 0 && ((type == 77 && length == 160) || (type == 79 && length == 64))
    }
    static func require(_ condition: Bool) throws { if !condition { throw ConnectionControlError.malformed } }
    static func zero(_ bytes: Data) -> Bool { bytes.allSatisfy { $0 == 0 } }
    static func read(_ bytes: [UInt8], _ offset: Int, _ count: Int = 8) -> UInt64 { MirrorControlCodec.read(bytes, offset, count) }
    static func put(_ value: UInt64, _ bytes: inout [UInt8], _ offset: Int, _ count: Int = 8) { MirrorControlCodec.put(value, &bytes, offset, count) }
    static func frame(type: UInt8, payload: Data, sequence: UInt32 = 0, flags: UInt16 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        put(0x54534353, &bytes, 0, 4); bytes[4] = 1; bytes[5] = type
        put(UInt64(flags), &bytes, 6, 2)
        put(UInt64(payload.count), &bytes, 8, 4); put(UInt64(sequence), &bytes, 12, 4)
        return Data(bytes) + payload
    }
    /// Testable strict framing seam, also useful to callers that hold a whole bounded control packet.
    static func roundTrip(_ frame: Data, clientToHost: Bool) throws -> Data {
        try require((16...176).contains(frame.count))
        let b = Array(frame), type = b[5]
        try require(read(b, 0, 4) == 0x54534353 && b[4] == 1 && read(b, 6, 2) == 0)
        let length = [76: 80, 77: 160, 78: 32, 79: 64][Int(type)]
        try require(length != nil && frame.count == 16 + (length ?? 0))
        try require(read(b, 8, 4) == UInt64(length ?? 0) && clientToHost == (type == 76 || type == 78))
        let payload = Data(frame.dropFirst(16)), encoded: Data
        switch type {
        case 76: encoded = try ConnectionHello.decode(payload).encode()
        case 77: encoded = try ConnectionControlState.decode(payload).encode()
        case 78: encoded = try ConnectionSelectRequest.decode(payload).encode()
        case 79: encoded = try ConnectionSelectResult.decode(payload).encode()
        default: throw ConnectionControlError.malformed
        }
        return self.frame(type: type, payload: encoded, sequence: UInt32(read(b, 12, 4)))
    }
}

public struct ConnectionHello: Equatable {
    public let kind: ConnectionHelloKind, target: ConnectionRoute
    public let transaction: UInt64, owner: UInt64, revision: UInt64
    public let token: Data, proof: Data
    public let capabilities: UInt32
    init(kind: ConnectionHelloKind, target: ConnectionRoute, transaction: UInt64, owner: UInt64,
         revision: UInt64, token: Data, proof: Data, capabilities: UInt32 = 1) {
        self.kind = kind; self.target = target; self.transaction = transaction; self.owner = owner
        self.revision = revision; self.token = token; self.proof = proof; self.capabilities = capabilities
    }
    public static func optIn(revision: UInt64 = 0, protectedHandoff: Bool = false) -> Self {
        Self(kind: .optIn, target: .unknown, transaction: 0, owner: 0, revision: revision,
             token: Data(repeating: 0, count: 16), proof: Data(repeating: 0, count: 32),
             capabilities: protectedHandoff ? 3 : 1)
    }
    public func encode() throws -> Data {
        var b = [UInt8](repeating: 0, count: 80); b[0] = 1; b[1] = kind.rawValue; b[2] = target.rawValue
        ConnectionControlProtocol.put(UInt64(capabilities), &b, 4, 4)
        ConnectionControlProtocol.put(transaction, &b, 8); ConnectionControlProtocol.put(owner, &b, 16)
        ConnectionControlProtocol.put(revision, &b, 24)
        try ConnectionControlProtocol.require(token.count == 16 && proof.count == 32)
        b.replaceSubrange(32..<48, with: token); b.replaceSubrange(48..<80, with: proof)
        _ = try Self.decode(Data(b)); return Data(b)
    }
    public static func decode(_ data: Data) throws -> Self {
        try ConnectionControlProtocol.require(data.count == 80)
        let b = Array(data)
        let capabilities = UInt32(ConnectionControlProtocol.read(b, 4, 4))
        guard b[0] == 1, b[3] == 0,
              let kind = ConnectionHelloKind(rawValue: b[1]), let target = ConnectionRoute(rawValue: b[2]) else { throw ConnectionControlError.malformed }
        let value = Self(kind: kind, target: target, transaction: ConnectionControlProtocol.read(b, 8),
            owner: ConnectionControlProtocol.read(b, 16), revision: ConnectionControlProtocol.read(b, 24),
            token: Data(b[32..<48]), proof: Data(b[48..<80]), capabilities: capabilities)
        if kind == .optIn {
            try ConnectionControlProtocol.require((capabilities == 1 || capabilities == 3) &&
                target == .unknown && value.transaction == 0 && value.owner == 0 &&
                ConnectionControlProtocol.zero(value.token) && ConnectionControlProtocol.zero(value.proof))
        } else {
            try ConnectionControlProtocol.require(capabilities == 1 &&
                value.owner != 0 && value.revision != 0 && !ConnectionControlProtocol.zero(value.token) &&
                !ConnectionControlProtocol.zero(value.proof) && target != .unknown && value.transaction != 0)
        }
        return value
    }
}

public struct ConnectionControlState: Equatable {
    public let hostState: ConnectionHostState, current: ConnectionRoute, recommended: ConnectionRoute
    public let wifi: ConnectionAvailability, usb: ConnectionAvailability
    public let allowed: Bool, phase: ConnectionStatePhase
    public let revision: UInt64, owner: UInt64, transaction: UInt64
    public let wifiReason: ConnectionReason, usbReason: ConnectionReason, stateReason: ConnectionReason
    public let token: Data, challenge: Data, secret: Data, reserved: Data
    public func encode() throws -> Data {
        var b = [UInt8](repeating: 0, count: 160)
        b[0] = 1; b[1] = hostState.rawValue; b[2] = current.rawValue; b[3] = recommended.rawValue
        b[4] = wifi.rawValue; b[5] = usb.rawValue; b[6] = allowed ? 1 : 0; b[7] = phase.rawValue
        for (offset, value) in [(8, revision), (16, owner), (24, transaction)] { ConnectionControlProtocol.put(value, &b, offset) }
        ConnectionControlProtocol.put(10000, &b, 32, 4)
        for (offset, value) in [(36, wifiReason), (38, usbReason), (40, stateReason)] { ConnectionControlProtocol.put(UInt64(value.rawValue), &b, offset, 2) }
        try ConnectionControlProtocol.require(token.count == 16 && challenge.count == 32 && secret.count == 32 && reserved.count == 32)
        b.replaceSubrange(48..<64, with: token); b.replaceSubrange(64..<96, with: challenge)
        b.replaceSubrange(96..<128, with: secret); b.replaceSubrange(128..<160, with: reserved)
        _ = try Self.decode(Data(b)); return Data(b)
    }
    public static func decode(_ data: Data) throws -> Self {
        try ConnectionControlProtocol.require(data.count == 160)
        let b = Array(data)
        guard b.count == 160, b[0] == 1, let state = ConnectionHostState(rawValue: b[1]),
              let current = ConnectionRoute(rawValue: b[2]), let recommended = ConnectionRoute(rawValue: b[3]),
              let wifi = ConnectionAvailability(rawValue: b[4]), let usb = ConnectionAvailability(rawValue: b[5]), b[6] <= 1,
              let phase = ConnectionStatePhase(rawValue: b[7]), ConnectionControlProtocol.read(b, 32, 4) == 10000,
              b[42..<48].allSatisfy({ $0 == 0 }),
              let wr = ConnectionReason(rawValue: UInt16(ConnectionControlProtocol.read(b, 36, 2))),
              let ur = ConnectionReason(rawValue: UInt16(ConnectionControlProtocol.read(b, 38, 2))),
              let sr = ConnectionReason(rawValue: UInt16(ConnectionControlProtocol.read(b, 40, 2))) else { throw ConnectionControlError.malformed }
        func available(_ value: ConnectionAvailability, _ reason: ConnectionReason, usb: Bool) -> Bool {
            switch value {
            case .unknown: return reason == .evidenceStale || reason == .notChecked
            case .available: return reason == .none
            case .unavailable: return reason != .none && reason != .notChecked && reason != .evidenceStale && reason != .duplicateTransaction
            case .detectedUnverified: return usb && reason == .deviceUnverified
            }
        }
        let value = Self(hostState: state, current: current, recommended: recommended, wifi: wifi, usb: usb,
            allowed: b[6] == 1, phase: phase, revision: ConnectionControlProtocol.read(b, 8), owner: ConnectionControlProtocol.read(b, 16),
            transaction: ConnectionControlProtocol.read(b, 24), wifiReason: wr, usbReason: ur, stateReason: sr,
            token: Data(b[48..<64]), challenge: Data(b[64..<96]), secret: Data(b[96..<128]), reserved: Data(b[128..<160]))
        try ConnectionControlProtocol.require(value.owner != 0 && value.revision != 0 && available(wifi, wr, usb: false) && available(usb, ur, usb: true))
        switch phase {
        case .snapshot:
            try ConnectionControlProtocol.require(value.transaction == 0 && ConnectionControlProtocol.zero(Data(b[48..<160])))
        case .prepareUSB, .prepareWiFi:
            try ConnectionControlProtocol.require(!ConnectionControlProtocol.zero(value.token) &&
                !ConnectionControlProtocol.zero(value.challenge) && !ConnectionControlProtocol.zero(value.secret) && ConnectionControlProtocol.zero(value.reserved) &&
                current == (phase == .prepareUSB ? .wifi : .usb) && value.transaction != 0)
        }
        return value
    }
}

public struct ConnectionSelectRequest: Equatable {
    public let target: ConnectionRoute, transaction: UInt64, owner: UInt64, revision: UInt64
    public func encode() throws -> Data {
        try ConnectionControlProtocol.require(target != .unknown && transaction != 0 && owner != 0 && revision != 0)
        var b = [UInt8](repeating: 0, count: 32); b[0] = 1; b[1] = target.rawValue
        ConnectionControlProtocol.put(transaction, &b, 8); ConnectionControlProtocol.put(owner, &b, 16); ConnectionControlProtocol.put(revision, &b, 24)
        return Data(b)
    }
    public static func decode(_ data: Data) throws -> Self {
        try ConnectionControlProtocol.require(data.count == 32)
        let b = Array(data)
        guard b.count == 32, b[0] == 1, let target = ConnectionRoute(rawValue: b[1]), b[2..<8].allSatisfy({ $0 == 0 }) else { throw ConnectionControlError.malformed }
        let value = Self(target: target, transaction: ConnectionControlProtocol.read(b, 8), owner: ConnectionControlProtocol.read(b, 16), revision: ConnectionControlProtocol.read(b, 24))
        _ = try value.encode(); return value
    }
}

public struct ConnectionSelectResult: Equatable {
    public let status: ConnectionResultStatus, target: ConnectionRoute, current: ConnectionRoute, reason: ConnectionReason, hostState: ConnectionHostState
    public let transaction: UInt64, originOwner: UInt64, revision: UInt64, routeOwner: UInt64
    public let token: Data, firstFrame: UInt32, frameDomain: ConnectionFrameDomain
    public func encode() throws -> Data {
        var b = [UInt8](repeating: 0, count: 64); b[0] = 1; b[1] = status.rawValue; b[2] = target.rawValue; b[3] = current.rawValue
        ConnectionControlProtocol.put(UInt64(reason.rawValue), &b, 4, 2); b[6] = hostState.rawValue
        for (offset, value) in [(8, transaction), (16, originOwner), (24, revision), (32, routeOwner)] { ConnectionControlProtocol.put(value, &b, offset) }
        try ConnectionControlProtocol.require(token.count == 16); b.replaceSubrange(40..<56, with: token)
        ConnectionControlProtocol.put(UInt64(firstFrame), &b, 56, 4); b[60] = frameDomain.rawValue
        _ = try Self.decode(Data(b)); return Data(b)
    }
    public static func decode(_ data: Data) throws -> Self {
        try ConnectionControlProtocol.require(data.count == 64)
        let b = Array(data)
        guard b.count == 64, b[0] == 1, b[7] == 0, b[61..<64].allSatisfy({ $0 == 0 }),
              let status = ConnectionResultStatus(rawValue: b[1]), let target = ConnectionRoute(rawValue: b[2]), target != .unknown,
              let current = ConnectionRoute(rawValue: b[3]), let reason = ConnectionReason(rawValue: UInt16(ConnectionControlProtocol.read(b, 4, 2))),
              let state = ConnectionHostState(rawValue: b[6]), let domain = ConnectionFrameDomain(rawValue: b[60]) else { throw ConnectionControlError.malformed }
        let value = Self(status: status, target: target, current: current, reason: reason, hostState: state,
            transaction: ConnectionControlProtocol.read(b, 8), originOwner: ConnectionControlProtocol.read(b, 16),
            revision: ConnectionControlProtocol.read(b, 24), routeOwner: ConnectionControlProtocol.read(b, 32),
            token: Data(b[40..<56]), firstFrame: UInt32(ConnectionControlProtocol.read(b, 56, 4)), frameDomain: domain)
        try ConnectionControlProtocol.require(value.transaction != 0 && value.originOwner != 0 && value.revision != 0 &&
            ((current == .unknown) == (value.routeOwner == 0)))
        switch status {
        case .accepted, .alreadyActive, .completed, .permissionRequired:
            try ConnectionControlProtocol.require(reason == .none)
        case .busy:
            // LocalOperation covers both lifecycle ownership and a switch already pending.
            try ConnectionControlProtocol.require([ConnectionReason.localOperation, .duplicateTransaction].contains(reason))
        case .denied:
            try ConnectionControlProtocol.require([ConnectionReason.permissionDenied, .notOwner].contains(reason))
        case .unavailable:
            try ConnectionControlProtocol.require([ConnectionReason.tunnelUnavailable, .noDevice, .multipleDevices,
                .listenerClosed, .identityUnavailable, .stoppedOnPC, .staleRevision].contains(reason))
        case .failed:
            try ConnectionControlProtocol.require([ConnectionReason.peerTimeout, .deadlineExceeded, .wrongDevice,
                .proofFailed, .teardownFailed, .startFailed, .firstFrameTimeout, .stoppedOnPC, .connectionLost].contains(reason))
        }
        if status == .alreadyActive { try ConnectionControlProtocol.require(current == target && state == .ready) }
        if status == .completed {
            try ConnectionControlProtocol.require(current == target && state == .ready && value.routeOwner != value.originOwner && domain != .none && !ConnectionControlProtocol.zero(value.token))
        } else {
            try ConnectionControlProtocol.require(value.firstFrame == 0 && domain == .none)
            if status == .accepted {
                try ConnectionControlProtocol.require(state == .switching && current != .unknown && current != target && value.routeOwner == value.originOwner && !ConnectionControlProtocol.zero(value.token))
            } else if status != .failed {
                try ConnectionControlProtocol.require(ConnectionControlProtocol.zero(value.token))
            }
        }
        return value
    }
}

/// Ephemeral in-memory context. Never log, stringify or persist this value.
struct ConnectionProofContext {
    enum Role: String { case ping = "SCCT1-P", pong = "SCCT1-Q", resume = "SCCT1-W" }
    let target: ConnectionRoute, transaction: UInt64, owner: UInt64, revision: UInt64
    private(set) var token: Data, challenge: Data
    private var secret: Data
    init(target: ConnectionRoute, transaction: UInt64, owner: UInt64, revision: UInt64, token: Data, challenge: Data, secret: Data) {
        self.target = target; self.transaction = transaction; self.owner = owner; self.revision = revision
        self.token = token; self.challenge = challenge; self.secret = secret
    }
    var context: Data {
        var b = [UInt8](repeating: 0, count: 26); b[0] = 1; b[1] = target.rawValue
        ConnectionControlProtocol.put(transaction, &b, 2); ConnectionControlProtocol.put(owner, &b, 10); ConnectionControlProtocol.put(revision, &b, 18)
        return Data(b) + token + challenge
    }
    func resumeHello() -> ConnectionHello {
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data(Role.resume.rawValue.utf8) + context,
            using: SymmetricKey(data: secret)))
        return ConnectionHello(kind: .resumeProof, target: target, transaction: transaction, owner: owner,
            revision: revision, token: token, proof: proof)
    }
    func usbProbeReply(to frame: Data) -> Data? {
        guard target == .usb, frame.count == ConnectionControlProtocol.usbProbeLength else { return nil }
        let b = Array(frame)
        let flag = ConnectionControlProtocol.usbProbeFlag
        guard ConnectionControlProtocol.read(b, 0, 4) == 0x54534353, b[4] == 1,
              b[5] == WireMessageType.ping.rawValue, ConnectionControlProtocol.read(b, 6, 2) == UInt64(flag),
              ConnectionControlProtocol.read(b, 8, 4) == 32, ConnectionControlProtocol.read(b, 12, 4) == 0 else { return nil }
        let key = SymmetricKey(data: secret)
        let authority = context
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(b[16..<48]),
            authenticating: Data(Role.ping.rawValue.utf8) + authority, using: key) else { return nil }
        let pong = Data(HMAC<SHA256>.authenticationCode(for: Data(Role.pong.rawValue.utf8) + authority, using: key))
        return ConnectionControlProtocol.frame(type: WireMessageType.pong.rawValue, payload: pong, flags: flag)
    }
    mutating func erase() {
        secret.resetBytes(in: 0..<secret.count); secret.removeAll(keepingCapacity: false)
        challenge.resetBytes(in: 0..<challenge.count); challenge.removeAll(keepingCapacity: false)
        token.resetBytes(in: 0..<token.count); token.removeAll(keepingCapacity: false)
    }
}

/// One raw-USB credential attempt. This proves the iPad to the host; it is not mutual host authentication.
/// No credential, PIN, identity or wire payload is logged or persisted by this value.
struct USBSessionIdentityProof {
    static let offerFlag: UInt16 = 0x0100
    static let optInFlag: UInt16 = 0x0080
    enum Phase { case initial, offered, waitingChallenge, waitingResult, identified, unidentified }
    private(set) var phase: Phase = .initial
    private(set) var optedIn = false
    private var credential: TrustedHostCredential?
    private var tlsLeafHash: Data?
    private var started: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    var identified: Bool { phase == .identified }
    var pending: Bool { phase == .offered || phase == .waitingChallenge || phase == .waitingResult }
    mutating func offer(flags: UInt16, credential: TrustedHostCredential?, now: TimeInterval,
                        tlsLeafHash: Data? = nil) -> UInt16 {
        guard phase == .initial else { return 0 }
        guard flags & Self.offerFlag != 0, let credential, credential.deviceID.count == 16,
              credential.hostID.count == 16, credential.secret.count == 32, credential.sessionID.count == 16,
              tlsLeafHash != nil || (credential.usbControlTLSSeen != true && flags & USBControlTLSUpgrade.flag == 0) else {
            phase = .unidentified; return 0
        }
        self.credential = credential; self.tlsLeafHash = tlsLeafHash
        started = now; lastTime = now; phase = .offered; optedIn = true
        return Self.optInFlag
    }
    mutating func tick(now: TimeInterval) {
        guard pending else { return }
        if now < lastTime || now - started >= 5 { abandon() }
        lastTime = now
    }
    mutating func remainingBudget(now: TimeInterval) -> TimeInterval {
        tick(now: now)
        return pending ? max(0, started + 5 - now) : 0
    }
    mutating func clientHello(name: String, now: TimeInterval) -> Data? {
        tick(now: now)
        guard phase == .offered, let credential else { return nil }
        guard let hello = WireProtocol.clientHello(deviceID: credential.deviceID, sessionID: credential.sessionID, name: name) else {
            abandon(); return nil
        }
        phase = .waitingChallenge
        return hello
    }
    mutating func answer(_ challenge: Data, flags: UInt16, now: TimeInterval) -> Data? {
        tick(now: now)
        guard phase == .waitingChallenge, flags == 0, challenge.count == 112, let credential,
              Data(challenge[16..<32]) == credential.deviceID, Data(challenge[32..<48]) == credential.hostID else {
            if pending { abandon() }; return nil
        }
        let context = Data(challenge[48..<112]) + Data(challenge[0..<48]) + Data([1])
        var key = SymmetricKey(data: credential.secret)
        if let tlsLeafHash {
            let binding = Data("SCUSB-TLS1".utf8) + tlsLeafHash
            key = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: binding, using: key))
        }
        let proof = Data(HMAC<SHA256>.authenticationCode(for: context, using: key))
        phase = .waitingResult
        return Data(challenge[0..<16]) + proof
    }
    mutating func result(_ payload: Data, flags: UInt16, currentCredential: TrustedHostCredential?, now: TimeInterval) -> Bool {
        tick(now: now)
        guard phase == .waitingResult, flags == 0, payload.count >= 1, payload[0] == 1,
              String(data: payload.dropFirst(), encoding: .utf8) != nil, let credential,
              tlsLeafHash != nil || currentCredential?.usbControlTLSSeen != true,
              currentCredential == credential else { if pending { abandon() }; return false }
        phase = .identified; self.credential = nil; tlsLeafHash = nil
        return true
    }
    mutating func abandon() { credential = nil; tlsLeafHash = nil; phase = .unidentified }
}
