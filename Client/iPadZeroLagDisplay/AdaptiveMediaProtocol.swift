import Foundation
import CoreGraphics

struct AdaptiveMediaIdentity: Equatable {
    let owner: UInt64, source: UInt64, media: UInt64
    var valid: Bool { owner != 0 && source != 0 && media != 0 }
}

/// Validated wire values. Encoding is the exact canonical little-endian payload;
/// no platform struct layout, clocks or strings enter the protocol.
struct AdaptiveMediaPacket: Equatable {
    let type: UInt8
    let encoded: Data
    func u32(_ o: Int) -> UInt32 { encoded.loadLittleEndian(UInt32.self, at: o) }
    func u64(_ o: Int) -> UInt64 { encoded.loadLittleEndian(UInt64.self, at: o) }
    func u16(_ o: Int) -> UInt16 { encoded.loadLittleEndian(UInt16.self, at: o) }
    var identity: AdaptiveMediaIdentity { AdaptiveMediaIdentity(owner: u64(8), source: u64(16), media: u64(24)) }
    var effective: AdaptiveMediaEffective? {
        [96,98].contains(type) ? AdaptiveMediaEffective(packet: self) : nil
    }
}

struct AdaptiveMediaEffective: Equatable {
    let packet: AdaptiveMediaPacket
    var identity: AdaptiveMediaIdentity { packet.identity }
    var request: UInt32 { packet.u32(32) }
    var policy: UInt32 { packet.u32(36) }
    var revision: UInt32 { packet.u32(40) }
    var status: UInt8 { packet.encoded[44] }
    var mode: UInt8 { packet.encoded[45] }
    var preset: UInt8 { packet.encoded[46] }
    var reason: UInt8 { packet.encoded[47] }
    var desktopSize: CGSize { CGSize(width: Int(packet.u32(48)), height: Int(packet.u32(52))) }
    var encodedSize: CGSize { CGSize(width: Int(packet.u32(56)), height: Int(packet.u32(60))) }
    var content: CGRect { CGRect(x: Int(packet.u32(64)), y: Int(packet.u32(68)), width: Int(packet.u32(72)), height: Int(packet.u32(76))) }
    var fps: UInt16 { packet.u16(80) / 10 }
    var scale: UInt16 { packet.u16(82) }
    var bitrate: UInt32 { packet.u32(84) }
    var firstFrame: UInt64 { packet.u64(88) }
    var textureRect: SIMD4<Float> {
        SIMD4(Float(content.minX / encodedSize.width), Float(content.minY / encodedSize.height),
              Float(content.width / encodedSize.width), Float(content.height / encodedSize.height))
    }
    var summary: String {
        displaySummary(remote: false)
    }
    func displaySummary(remote: Bool) -> String {
        let reasons = ["initial","manual","network","severe backlog","decoder","recovering",
                       "text sharpness reduced","apply rejected","stale policy","stale epoch","unsupported","suspended","timeout"]
        let bitrateFormat = remote ? "%.2f" : "%.0f"
        return "\(mode == 2 ? "Auto" : mode == 1 ? "Auto bitrate" : "Manual") - \(String(format: bitrateFormat, Double(bitrate)/1_000_000)) Mbps - \(fps) FPS - \(Int(encodedSize.width))x\(Int(encodedSize.height)) - \(reasons[Int(reason)])" +
            ((scale == 5000 || remote && scale < 10000) && reason != 6 ? " - text sharpness reduced" : "")
    }
}

enum AdaptiveMediaProtocol {
    static let probeFlag: UInt16 = 0x0200
    static let probeBackoffFlag: UInt16 = 0x0040
    static func size(_ type: UInt8) -> Int {
        switch type { case 93: return 32; case 94,95,99: return 64; case 96,98: return 112; case 97: return 160; default: return 0 }
    }
    static func decode(type: UInt8, data: Data, flags: UInt16 = 0) -> AdaptiveMediaPacket? {
        guard flags == 0, size(type) != 0, data.count == size(type), data[0] == 1,
              data[1..<8].allSatisfy({ $0 == 0 }) else { return nil }
        let p = AdaptiveMediaPacket(type: type, encoded: data)
        func z(_ o: Int, _ n: Int) -> Bool { data[o..<(o+n)].allSatisfy { $0 == 0 } }
        func bits(_ v: UInt32, _ mask: UInt32) -> Bool { v != 0 && v & ~mask == 0 }
        func bounds(_ a: UInt32, _ b: UInt32, _ lo: UInt32, _ hi: UInt32) -> Bool { a >= lo && a <= b && b <= hi }
        func dimensions(_ w: UInt32, _ h: UInt32) -> Bool { (1...32768).contains(w) && (1...32768).contains(h) }
        func fps(_ v: UInt16) -> Bool { [300,600,1200].contains(v) }
        func scale(_ v: UInt16) -> Bool { [5000,7500,10000].contains(v) }
        func align(_ v: UInt16) -> Bool { v > 0 && v <= 256 && v & (v-1) == 0 }
        if type == 93 {
            guard z(12,4), bits(p.u32(8),7), p.u64(16) != 0, p.u64(24) != 0 else { return nil }; return p
        }
        if type == 94 {
            guard z(52,12), p.u64(8) != 0, p.u64(16) != 0, bits(p.u32(24),7), data[51] <= 1,
                  bounds(p.u32(28),p.u32(32),300_000,100_000_000), dimensions(p.u32(36),p.u32(40)),
                  align(p.u16(44)), align(p.u16(46)), bits(UInt32(data[48]),7), bits(UInt32(data[49]),7), data[50] == 1,
                  data[51] == 0 ? p.u32(28) >= 3_000_000 : data[48] & 4 == 0 else { return nil }; return p
        }
        guard p.identity.valid else { return nil }
        switch type {
        case 95:
            let lo: UInt32 = data[42] == 0 || data[40] == 0 ? 3_000_000 : 300_000
            let hi: UInt32 = data[42] == 0 || data[40] == 0 ? 100_000_000 : 20_000_000
            guard p.u32(32) != 0, p.u32(36) != 0, data[40] <= 2, data[41] <= 1, data[42] <= 1,
                  z(43,1), z(62,2), bounds(p.u32(44),p.u32(44),3_000_000,100_000_000),
                  bounds(p.u32(48),p.u32(52),lo,hi), fps(p.u16(56)), fps(p.u16(58)),
                  p.u16(56) <= p.u16(58), scale(p.u16(60)),
                  !(data[42] == 1 || data[41] == 0) || p.u16(58) <= 600 else { return nil }
        case 96,98:
            let w = p.u32(56), h = p.u32(60), x = p.u32(64), y = p.u32(68)
            guard z(100,12), p.u32(36) != 0, p.u32(40) != 0, data[44] <= 4, data[45] <= 2,
                  data[46] <= 1, data[47] <= 12, dimensions(p.u32(48),p.u32(52)), dimensions(w,h),
                  x <= w, y <= h, p.u32(72) > 0, p.u32(76) > 0, p.u32(72) <= w-x, p.u32(76) <= h-y,
                  fps(p.u16(80)), scale(p.u16(82)), bounds(p.u32(84),p.u32(84),300_000,100_000_000),
                  p.u32(96) & ~UInt32(1) == 0, (p.u16(82) == 5000) == (p.u32(96) & 1 != 0),
                  type != 98 || (p.u32(32) != 0 && p.u64(88) != 0) else { return nil }
        case 97:
            guard z(145,15), (1...10_000_000).contains(p.u32(40)), p.u32(44) & ~UInt32(63) == 0,
                  data[144] & ~UInt8(15) == 0 else { return nil }
        case 99:
            guard z(46,2), z(56,8), p.u32(32) != 0, p.u32(36) != 0, p.u32(40) != 0,
                  data[44] <= 2, data[45] <= 12, p.u64(48) != 0 else { return nil }
        default: return nil
        }
        return p
    }
    static func empty(_ type: UInt8) -> Data { var d = Data(count: size(type)); d[0] = 1; return d }
    static func putIdentity(_ i: AdaptiveMediaIdentity, _ d: inout Data) {
        d.storeLittleEndian(i.owner,at:8); d.storeLittleEndian(i.source,at:16); d.storeLittleEndian(i.media,at:24)
    }
    static func hello(owner: UInt64, nonce: UInt64) -> AdaptiveMediaPacket {
        var d = empty(93); d.storeLittleEndian(UInt32(7),at:8); d.storeLittleEndian(nonce,at:16); d.storeLittleEndian(owner,at:24)
        return AdaptiveMediaPacket(type:93,encoded:d)
    }
    static func ack(_ v: AdaptiveMediaEffective, status: UInt8, reason: UInt8 = 0) -> AdaptiveMediaPacket {
        var d = empty(99); putIdentity(v.identity,&d); d.storeLittleEndian(v.request,at:32)
        d.storeLittleEndian(v.policy,at:36); d.storeLittleEndian(v.revision,at:40); d[44]=status; d[45]=reason
        d.storeLittleEndian(v.firstFrame,at:48); return AdaptiveMediaPacket(type:99,encoded:d)
    }
    static func matchesAcknowledgement(_ ack: AdaptiveMediaPacket, _ v: AdaptiveMediaEffective) -> Bool {
        ack.type == 99 && ack.identity == v.identity && ack.u32(32) == v.request && ack.u32(36) == v.policy &&
            ack.u32(40) == v.revision && ack.u64(48) == v.firstFrame && v.request != 0 && v.firstFrame != 0
    }
}

enum AdaptiveCastingRoute: UInt32 {
    case wifiRTP = 0, wifiTLS = 1, usbTLS = 2

    var usesOrderedVideo: Bool { self != .wifiRTP }
}

struct AdaptiveMediaProbe {
    enum Phase { case idle, waiting, enabled, legacy, backoff }
    private(set) var phase: Phase = .idle
    private var ping = Data()
    private(set) var began: TimeInterval = 0
    private var castingRoute: AdaptiveCastingRoute?
    mutating func begin(_ payload: Data, now: TimeInterval, castingRoute: AdaptiveCastingRoute? = nil) -> Bool {
        guard phase == .idle, payload.count == 16 else { return false }
        self.castingRoute = castingRoute
        phase = .waiting; ping = payload; began = now; return true
    }
    func matchesRequest(_ payload: Data, sequence: UInt32) -> Bool {
        phase == .waiting && payload == ping && sequence == (castingRoute?.rawValue ?? 0)
    }
    mutating func tick(now: TimeInterval) { if phase == .waiting && now-began >= 2 { phase = .legacy; ping = Data() } }
    mutating func accept(_ payload: Data, flags: UInt16, sequence: UInt32 = 0, now: TimeInterval) -> Bool {
        tick(now: now)
        guard phase == .waiting, ping == payload else { return false }
        let marker = flags & (AdaptiveMediaProtocol.probeFlag | AdaptiveMediaProtocol.probeBackoffFlag)
        if marker != 0, let castingRoute, castingRoute.usesOrderedVideo, sequence != castingRoute.rawValue { return false }
        switch marker {
        case AdaptiveMediaProtocol.probeBackoffFlag: phase = .backoff
        case AdaptiveMediaProtocol.probeFlag: phase = .enabled
        case 0: phase = .legacy
        default: return false // The two DS2 markers are mutually exclusive.
        }
        ping = Data()
        return phase == .enabled
    }
    mutating func retire() { phase = .legacy; ping = Data() }
}

/// One instance per authenticated route. Host values never mutate input
/// authority; pending geometry cannot be published as applied quality.
struct AdaptiveMediaSession {
    let owner: UInt64, nonce: UInt64
    let remote: Bool
    let castingRoute: AdaptiveCastingRoute?
    init(owner: UInt64, nonce: UInt64, remote: Bool = false, castingRoute: AdaptiveCastingRoute = .wifiRTP) {
        self.owner = owner; self.nonce = nonce; self.remote = remote
        self.castingRoute = remote ? nil : castingRoute
    }
    var usesOrderedVideo: Bool { remote || castingRoute?.usesOrderedVideo == true }
    private(set) var capabilities: AdaptiveMediaPacket?
    private(set) var current: AdaptiveMediaEffective?
    private(set) var pending: AdaptiveMediaEffective?
    private(set) var applied: AdaptiveMediaEffective?
    private(set) var firstDecoded = false, firstPresented = false
    private(set) var frameFloor: UInt64 = 0
    private var appliedFloor: UInt64 = 0
    private var frameAnchor: UInt64?
    private var lastConfiguration: AdaptiveMediaIdentity?
    private var nextRequest: UInt32 = 1
    private var requested: Data?
    private var policyPending: UInt32?
    private var awaitingRollback = false
    private var awaitingRemoteBaselineIDR = false
    private var remotePreparing = false
    var mediaRecoveryActive: Bool { awaitingRollback || pending != nil || awaitingRemoteBaselineIDR || remotePreparing }
    var supportsAuto: Bool {
        guard let caps = capabilities, caps.u32(24) & 7 == 7 else { return false }
        if castingRoute?.usesOrderedVideo == true { return applied != nil }
        return !remote || (applied != nil && caps.u32(28) <= 20_000_000 && caps.encoded[49] & 4 != 0)
    }
    mutating func acceptCapabilities(_ p: AdaptiveMediaPacket) -> Bool {
        guard capabilities == nil, p.type == 94, p.u64(8) == nonce, p.u64(16) == owner,
              p.encoded[51] == (remote ? 1 : 0) else { return false }
        capabilities = p; return true
    }
    mutating func receiveState(_ value: AdaptiveMediaEffective) -> Bool {
        guard capabilities != nil, value.identity.owner == owner else { return false }
        if remote { return receiveRemoteState(value) }
        if castingRoute?.usesOrderedVideo == true, current == nil {
            guard value.status == 0, value.mode == 0, value.request == 0, fitsCapabilities(value) else { return false }
        }
        if let old = current {
            if value.identity.source == old.identity.source && value.identity.media != old.identity.media && pending == nil { return false }
            guard value.identity.source >= old.identity.source,
                  value.identity.source != old.identity.source || value.identity.media >= old.identity.media,
                  value.policy >= old.policy,
                  value.identity.source != old.identity.source || value.revision >= old.revision else { return false }
        }
        if let pending, value.identity.source > pending.identity.source { retirePendingConfiguration() }
        let hadPending = pending != nil
        if let pending {
            guard value.identity == pending.identity, firstPresented,
                  value.revision >= pending.revision else { return false }
            if castingRoute?.usesOrderedVideo == true {
                guard value.status == 0, sameGeometry(value, pending) else { return false }
            }
            frameFloor = pending.firstFrame; self.pending = nil
        } else if let old = current, value.identity == old.identity,
                  (value.desktopSize != old.desktopSize || value.encodedSize != old.encodedSize || value.fps != old.fps || value.content != old.content) {
            return false
        }
        if let old=current, value.identity.source != old.identity.source { requested = nil; policyPending = nil; awaitingRollback = false }
        if value.request == policyPending, value.status == 0 || value.status == 1 { policyPending = nil }
        if current?.identity != value.identity && !hadPending {
            frameFloor = value.firstFrame; frameAnchor = value.firstFrame == 0 ? nil : value.firstFrame
        }
        current = value
        if value.status == 0 { applied = value; appliedFloor = frameFloor }
        return true
    }
    private func fitsCapabilities(_ value: AdaptiveMediaEffective) -> Bool {
        guard let caps = capabilities, value.identity.owner == owner,
              value.bitrate >= caps.u32(28), value.bitrate <= caps.u32(32),
              value.encodedSize.width <= CGFloat(caps.u32(36)), value.encodedSize.height <= CGFloat(caps.u32(40)),
              value.packet.u32(56) % UInt32(caps.u16(44)) == 0,
              value.packet.u32(60) % UInt32(caps.u16(46)) == 0,
              caps.encoded[48] & (value.fps == 30 ? 1 : value.fps == 60 ? 2 : 4) != 0,
              caps.encoded[49] & (value.scale == 5000 ? 1 : value.scale == 7500 ? 2 : 4) != 0 else { return false }
        return !remote || value.preset == 0
    }
    private func sameGeometry(_ a: AdaptiveMediaEffective, _ b: AdaptiveMediaEffective) -> Bool {
        a.desktopSize == b.desktopSize && a.encodedSize == b.encodedSize &&
            a.content == b.content && a.fps == b.fps && a.scale == b.scale
    }
    private func allowsRemoteMode(_ value: AdaptiveMediaEffective, after prior: AdaptiveMediaEffective) -> Bool {
        value.mode == 0 || (value.mode == 2 && (prior.mode == 2 ||
            (value.request == policyPending && value.policy > prior.policy)))
    }
    private mutating func receiveRemoteState(_ value: AdaptiveMediaEffective) -> Bool {
        guard fitsCapabilities(value) else { return false }
        if let prior = current {
            guard value.identity.source == prior.identity.source, value.desktopSize == prior.desktopSize,
                  value.policy >= prior.policy, value.revision >= prior.revision,
                  allowsRemoteMode(value, after: prior) else { return false }
            if value.status == 2 {
                if value.identity == prior.identity, value.request != 0, pending == nil,
                   value.policy == prior.policy, value.revision == prior.revision,
                   value.mode == prior.mode, value.bitrate == prior.bitrate, sameGeometry(value, prior) {
                    remotePreparing = true
                }
                return false
            }
            guard value.status == 0 || value.status == 1 else { return false }
            if value.identity != prior.identity {
                guard let pending, firstPresented, value.identity == pending.identity,
                      value.request == 0 || value.request == pending.request,
                      value.policy == pending.policy, value.revision == pending.revision,
                      value.firstFrame == pending.firstFrame, value.mode == pending.mode,
                      value.bitrate == pending.bitrate, sameGeometry(value, pending) else { return false }
            } else {
                guard sameGeometry(value, prior),
                      value.status == 1 ? pending == nil : value.revision > prior.revision && pending == nil else { return false }
                if awaitingRollback {
                    frameFloor = appliedFloor
                    frameAnchor = appliedFloor == 0 ? nil : appliedFloor
                    awaitingRemoteBaselineIDR = true
                }
            }
        } else {
            guard value.status == 0, value.mode == 0, value.request == 0, value.identity.media == 1,
                  value.firstFrame == 0, value.scale == 10000 else { return false }
            awaitingRemoteBaselineIDR = true
        }
        remotePreparing = false; awaitingRollback = false
        pending = nil
        if value.request == policyPending || value.mode == 0 && value.policy > (current?.policy ?? 0) {
            policyPending = nil
        }
        current = value
        applied = value
        appliedFloor = frameFloor
        return true
    }
    mutating func configure(_ value: AdaptiveMediaEffective, restoringSource: Bool = false,
                            controlSequence: UInt32 = 0) -> Bool {
        if usesOrderedVideo {
            guard value.status == 2, controlSequence < UInt32.max,
                  value.firstFrame == UInt64(controlSequence + 1) else { return false }
        }
        if castingRoute?.usesOrderedVideo == true {
            guard let current, value.identity.source == current.identity.source,
                  value.desktopSize == current.desktopSize else { return false }
        }
        if remote {
            guard let current, value.identity.source == current.identity.source,
                  value.desktopSize == current.desktopSize, value.revision > current.revision,
                  allowsRemoteMode(value, after: current) else { return false }
        }
        if restoringSource {
            // A rollback prepares a fresh media epoch for the last applied source and geometry.
            // A new adaptation must not take over while the source request is in flight.
            guard value.status == 2, value.reason == 7, let applied,
                  value.identity.source == applied.identity.source, value.identity.media > applied.identity.media,
                  value.revision > applied.revision, value.desktopSize == applied.desktopSize,
                  value.encodedSize == applied.encodedSize, value.content == applied.content,
                  value.fps == applied.fps, value.scale == applied.scale else { return false }
        }
        guard fitsCapabilities(value) else { return false }
        if let lastConfiguration, value.identity.source == lastConfiguration.source,
           value.identity.media <= lastConfiguration.media { return false }
        if let old = pending ?? current {
            guard value.identity.source >= old.identity.source,
                  value.identity.source != old.identity.source || value.identity.media > old.identity.media,
                  value.policy >= (remote ? current?.policy ?? 0 : old.policy),
                  value.identity.source != old.identity.source || value.revision >= old.revision else { return false }
        }
        lastConfiguration = value.identity; awaitingRollback = false
        pending = value; frameFloor = value.firstFrame; frameAnchor = value.firstFrame; firstDecoded = false; firstPresented = false
        return true
    }
    enum OrderedVideoAdmission { case regular, cutover(AdaptiveMediaEffective), discard, missingFirstFrame }
    var orderedVideoNeedsParameterSets: Bool { awaitingRemoteBaselineIDR || pending != nil && !firstDecoded }
    func admitCastingTLS(sequence: UInt32, isIDR: Bool, hasParameterSets: Bool) -> OrderedVideoAdmission {
        if awaitingRollback { return .discard }
        guard let pending else { return .regular }
        if firstDecoded { return .discard }
        guard UInt64(sequence) == pending.firstFrame, isIDR, hasParameterSets else { return .missingFirstFrame }
        return .cutover(pending)
    }
    mutating func admitRemote(sequence: UInt32, isIDR: Bool, hasParameterSets: Bool) -> OrderedVideoAdmission {
        if awaitingRollback { return .discard }
        if let pending, !firstDecoded {
            guard let frame = frameIdentity(sequence), frame >= frameFloor else { return .discard }
            guard frame == pending.firstFrame, isIDR, hasParameterSets else { return .missingFirstFrame }
            awaitingRemoteBaselineIDR = false
            return .cutover(pending)
        }
        if awaitingRemoteBaselineIDR {
            guard isIDR, hasParameterSets else { return .discard }
            awaitingRemoteBaselineIDR = false
        }
        return .regular
    }
    mutating func retirePendingConfiguration() {
        awaitingRollback = false
        pending = nil; firstDecoded = false; firstPresented = false; frameFloor = appliedFloor; policyPending = nil
    }
    static func frameID(_ sequence: UInt32, near anchor: UInt64) -> UInt64? {
        let delta = Int64(Int32(bitPattern: sequence &- UInt32(truncatingIfNeeded: anchor)))
        if delta < 0 { let distance = UInt64(-delta); return anchor >= distance ? anchor-distance : nil }
        let (id, overflow) = anchor.addingReportingOverflow(UInt64(delta)); return overflow ? nil : id
    }
    func frameIdentity(_ sequence: UInt32) -> UInt64? {
        guard !awaitingRollback else { return nil }
        if castingRoute?.usesOrderedVideo == true { return UInt64(sequence) }
        guard let frameAnchor else { return UInt64(sequence) }
        return Self.frameID(sequence,near:frameAnchor)
    }
    mutating func admit(sequence: UInt32, isIDR: Bool) -> Bool {
        guard pending != nil || current != nil else { return true }
        guard let frame = frameIdentity(sequence), frame >= frameFloor else { return false }
        if pending != nil && !firstDecoded {
            guard frame == frameFloor, isIDR else { return false }; firstDecoded = true
        }
        frameAnchor = max(frameAnchor ?? frame,frame)
        return true
    }
    mutating func presented(sequence: UInt32) -> AdaptiveMediaPacket? {
        guard let p = pending, firstDecoded, !firstPresented else { return nil }
        let frame = castingRoute?.usesOrderedVideo == true ? UInt64(sequence) : Self.frameID(sequence, near: p.firstFrame)
        guard frame == p.firstFrame else { return nil }
        firstPresented = true; return AdaptiveMediaProtocol.ack(p,status:1)
    }
    mutating func failed(reason: UInt8) -> AdaptiveMediaPacket? {
        guard let p = pending else { return nil }
        awaitingRollback = true
        pending = nil; firstDecoded = false; firstPresented = false
        return AdaptiveMediaProtocol.ack(p,status:2,reason:reason)
    }
    mutating func makePolicy(auto: Bool, manualBps: UInt32, game: Bool) -> AdaptiveMediaPacket? {
        guard let caps = capabilities, let value = current, pending == nil, policyPending == nil, !awaitingRollback,
              !auto || supportsAuto, nextRequest != 0 else { return nil }
        let fpsMask = caps.encoded[48]
        let maxFps: UInt16 = !remote && game && fpsMask & 4 != 0 ? 1200 : fpsMask & 2 != 0 ? 600 : 300
        let minFps: UInt16 = fpsMask & 1 != 0 ? 300 : fpsMask & 2 != 0 ? 600 : 1200
        let minScale: UInt16 = caps.encoded[49] & 1 != 0 ? 5000 : caps.encoded[49] & 2 != 0 ? 7500 : 10000
        var d = AdaptiveMediaProtocol.empty(95); AdaptiveMediaProtocol.putIdentity(value.identity,&d)
        d.storeLittleEndian(value.policy,at:36); d[40] = auto ? 2 : 0; d[41] = !remote && game ? 1 : 0
        d[42] = remote ? 1 : 0
        let remoteAuto = remote && auto
        d.storeLittleEndian(manualBps,at:44); d.storeLittleEndian(max(remoteAuto ? 300_000 : 3_000_000,caps.u32(28)),at:48)
        d.storeLittleEndian(min(remoteAuto ? 20_000_000 : 100_000_000,caps.u32(32)),at:52)
        d.storeLittleEndian(minFps,at:56); d.storeLittleEndian(maxFps,at:58); d.storeLittleEndian(minScale,at:60)
        // Compare user intent independently of request/revision. Repeated State
        // publications cannot enqueue the same toggle or manual restore twice.
        let signature = Data(d[40..<64])
        guard signature != requested else { return nil }
        d.storeLittleEndian(nextRequest,at:32)
        guard let packet = AdaptiveMediaProtocol.decode(type:95,data:d) else { return nil }
        nextRequest = nextRequest == .max ? 0 : nextRequest+1
        requested = signature; policyPending = packet.u32(32); return packet
    }
    mutating func permitRemoteAutoRequestAgain() { requested = nil }
}

/// Counts unique stage progress within a one-second window. Unknown stages keep
/// their validity bit clear; local presentation age is receive-to-fresh-present.
struct AdaptiveMediaWindow {
    static let feedbackPollInterval: TimeInterval = 0.05
    // Leave headroom above the host's 200 ms observation floor for routine
    // reports. A loss or queue spike can close the current window earlier.
    private static let routineFeedbackWindowUs: UInt32 = 250_000
    private static let minimumFeedbackWindowUs: UInt32 = 200_000
    private static let decoderQueueSpikeUs: UInt32 = 20_000

    // Bound reordering and duplicate detection across window boundaries. An
    // older callback outside this sequence range is stale.
    private struct RecentFrames {
        private static let capacity: UInt64 = 512
        private var slots: [UInt64: UInt64] = [:]
        private(set) var last: UInt64 = 0

        func contains(_ frame: UInt64) -> Bool { slots[frame % Self.capacity] == frame }

        mutating func insert(_ frame: UInt64) -> Bool {
            guard last <= frame || last - frame < Self.capacity else { return false }
            let slot = frame % Self.capacity
            guard slots[slot] != frame else { return false }
            slots[slot] = frame
            last = max(last, frame)
            return true
        }
    }

    private var started: TimeInterval
    private var window: UInt64 = 0
    private var bytes: UInt64 = 0, receivedCount: UInt64 = 0, decodedCount: UInt64 = 0, presentedCount: UInt64 = 0
    private var receivedFrames = RecentFrames(), decodedFrames = RecentFrames(), presentedFrames = RecentFrames()
    private var receiveTimes: [UInt64: TimeInterval] = [:]
    private var decodeTimes: [UInt32] = []
    private var presentationAgeUs: UInt32?
    private var receiveUs: UInt32 = 0, queueUs: UInt32 = 0
    private var receiveTimingComplete = true
    private var validity: UInt32 = 0
    private var drops: [UInt32] = [0,0,0,0]
    private var rtt: (UInt32,TimeInterval)?
    var hasPressureSpike: Bool { drops[0] > 0 || queueUs >= Self.decoderQueueSpikeUs }

    init(started: TimeInterval) { self.started = started }
    static func us(_ seconds: TimeInterval) -> UInt32 { UInt32(max(0,min(Double(UInt32.max),(seconds*1_000_000).rounded()))) }
    func hasReceived(frame: UInt64) -> Bool { receivedFrames.contains(frame) }
    mutating func received(frame: UInt64, bytes: Int, now: TimeInterval, receiveUs: UInt32?) {
        guard receivedFrames.insert(frame) else { return }
        receivedCount &+= 1; self.bytes &+= UInt64(max(0,bytes))
        if receiveTimes.count >= 512 { receiveTimes.removeValue(forKey: receiveTimes.keys.min() ?? frame) }
        receiveTimes[frame] = now
        if let receiveUs {
            let (total, overflow) = self.receiveUs.addingReportingOverflow(receiveUs)
            self.receiveUs = total
            receiveTimingComplete = receiveTimingComplete && !overflow
        } else {
            receiveTimingComplete = false
        }
    }
    mutating func decoded(frame: UInt64, queueUs: UInt32?, decodeUs: UInt32?) {
        guard decodedFrames.insert(frame) else { return }
        decodedCount &+= 1
        if let queueUs { self.queueUs = max(self.queueUs,queueUs); validity |= 16 }
        if let decodeUs { decodeTimes.append(decodeUs); if decodeTimes.count > 512 { decodeTimes.removeFirst() }; validity |= 2 }
    }
    mutating func presented(frame: UInt64, now: TimeInterval) {
        guard presentedFrames.insert(frame) else { return }
        presentedCount &+= 1
        presentationAgeUs = receiveTimes.removeValue(forKey: frame).map { Self.us(now - $0) }
    }
    mutating func drop(_ cause: Int) { guard drops.indices.contains(cause) else { return }; if drops[cause] != .max { drops[cause] += 1 }; validity |= 32 }
    mutating func recordRtt(us: UInt32, now: TimeInterval) { rtt = (us,now) }
    mutating func restart(started: TimeInterval) {
        let nextWindow = window
        let latestRtt = rtt
        self = Self(started: started)
        window = nextWindow
        rtt = latestRtt
    }
    private mutating func resetMeasurements(started: TimeInterval) {
        self.started = started
        bytes = 0; receivedCount = 0; decodedCount = 0; presentedCount = 0
        decodeTimes.removeAll(keepingCapacity: true)
        presentationAgeUs = nil
        drops = [0,0,0,0]; validity = 0; receiveUs = 0; queueUs = 0
        receiveTimingComplete = true
    }
    mutating func sample(identity: AdaptiveMediaIdentity, now: TimeInterval, activity: UInt8) -> AdaptiveMediaPacket? {
        guard identity.valid else { return nil }
        let durationUs = Self.us(now - started)
        // The controllers use windows of at most one second. Discard an
        // overdue window instead of assigning its counters a shorter duration.
        guard durationUs <= 1_000_000 else {
            resetMeasurements(started: now)
            receiveTimes.removeAll(keepingCapacity: true)
            return nil
        }
        let minimumUs = hasPressureSpike ? Self.minimumFeedbackWindowUs : Self.routineFeedbackWindowUs
        guard durationUs >= minimumUs else { return nil }
        func p95(_ values: [UInt32]) -> UInt32 { let s=values.sorted(); return s.isEmpty ? 0 : s[max(0,Int(ceil(Double(s.count)*0.95))-1)] }
        var d=AdaptiveMediaProtocol.empty(97); AdaptiveMediaProtocol.putIdentity(identity,&d)
        d.storeLittleEndian(window,at:32); d.storeLittleEndian(durationUs,at:40)
        let validReceive = receiveTimingComplete && receiveUs > 0
        var valid = validity
        if validReceive { valid |= 1 }
        if presentationAgeUs != nil { valid |= 4 }
        if let rtt { valid |= 8; d.storeLittleEndian(rtt.0,at:112); d.storeLittleEndian(Self.us(now-rtt.1),at:116) }
        d.storeLittleEndian(valid,at:44); d.storeLittleEndian(bytes,at:48); d.storeLittleEndian(receivedCount,at:56)
        d.storeLittleEndian(decodedCount,at:64); d.storeLittleEndian(presentedCount,at:72)
        for i in 0..<4 { d.storeLittleEndian(drops[i],at:80+i*4) }
        d.storeLittleEndian(validReceive ? receiveUs : 0,at:96); d.storeLittleEndian(queueUs,at:100)
        d.storeLittleEndian(p95(decodeTimes),at:104); d.storeLittleEndian(presentationAgeUs ?? 0,at:108)
        d.storeLittleEndian(receivedFrames.last,at:120); d.storeLittleEndian(decodedFrames.last,at:128)
        d.storeLittleEndian(presentedFrames.last,at:136); d[144]=activity
        guard let packet = AdaptiveMediaProtocol.decode(type: 97, data: d) else { return nil }
        window &+= 1
        resetMeasurements(started: now)
        return packet
    }
}
