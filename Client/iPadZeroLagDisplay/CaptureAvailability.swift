import Foundation

// A monotonic progress domain shared by every capture-dependent deadline.
// Keep its offset across generations: a retained route handoff must not see time go backwards.
struct CaptureReadinessClock {
    private var pausedAt: TimeInterval?
    private var excluded: TimeInterval = 0
    func now(at wall: TimeInterval) -> TimeInterval { (pausedAt ?? wall) - excluded }
    mutating func setSuspended(_ suspended: Bool, at wall: TimeInterval) {
        if suspended {
            if pausedAt == nil { pausedAt = wall }
        } else if let start = pausedAt {
            excluded += max(0, wall - start); pausedAt = nil
        }
    }
}

// DisplayCapabilities only; independent of Ping/Pong feature flags.
enum CaptureAvailabilityProtocol {
    static let advertisementFlag: UInt16 = 0x0040
    static let hello = Data([1, 0, 0, 0])

    static func isNewInputPacket(_ data: Data) -> Bool {
        if data.count == TouchWireProtocol.packetSize {
            return !MirrorClientControl.isRelease(kind: .pencil, payload: data)
        }
        guard data.count >= WireProtocol.headerSize else { return false }
        let payload = Data(data.dropFirst(WireProtocol.headerSize))
        if data[5] == WireMessageType.mirrorInput.rawValue {
            guard let envelope = try? MirrorControlCodec.decodeInput(payload) else { return true }
            return !MirrorClientControl.isRelease(kind: envelope.kind, payload: envelope.payload)
        }
        guard let kind = MirrorInputKind(rawValue: data[5]) else { return false }
        return !MirrorClientControl.isRelease(kind: kind, payload: payload)
    }
}

struct CaptureAvailabilityCommand: Equatable {
    let state: UInt8
    let reason: UInt8
    let sequence: UInt32

    func encode() -> Data {
        Data([state, reason, 0, 0, UInt8(truncatingIfNeeded: sequence),
              UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence >> 16),
              UInt8(truncatingIfNeeded: sequence >> 24)])
    }

    static func decode(_ payload: Data) -> Self? {
        guard payload.count == 8, payload[2] == 0, payload[3] == 0,
              payload[0] == 0 && payload[1] == 0 || payload[0] == 1 && (payload[1] == 1 || payload[1] == 2) else { return nil }
        let sequence = UInt32(payload[4]) | UInt32(payload[5]) << 8 | UInt32(payload[6]) << 16 | UInt32(payload[7]) << 24
        return Self(state: payload[0], reason: payload[1], sequence: sequence)
    }
}

// Pure, serialized by NetworkManager. Availability never changes a decoder or source identity.
struct CaptureAvailabilityState {
    enum Reception: Equatable {
        case ignored(String)
        case suspended(retireInput: Bool)
        case updated
    }
    private(set) var generation: UInt64 = 0
    private(set) var helloSent = false
    private(set) var lastSequence: UInt32?
    private(set) var wireSuspended = false
    private(set) var notice: String?
    private struct FrameKey: Hashable { let sequence: UInt32; let decoder: UInt64 }
    private struct Frame { let receivedAfterResume: Bool; var decoded = false; var presented = false }
    private var frames: [FrameKey: Frame] = [:]
    private var receivedAfterResume: [UInt32: Bool] = [:]
    private var receiptOrder: [UInt32] = []
    private var frameOrder: [FrameKey] = []
    private var lastAdmitted: UInt32?
    private var suspensionFloor: UInt32?
    private var freshRoot = false
    var inputBlocked: Bool { notice != nil }
    var negotiated: Bool { helloSent }

    mutating func begin(generation: UInt64) {
        self = Self(); self.generation = generation
    }

    mutating func hello(flags: UInt16, authenticated: Bool, generation: UInt64) -> Data? {
        guard generation != 0, generation == self.generation, authenticated, !helloSent,
              flags & CaptureAvailabilityProtocol.advertisementFlag != 0 else { return nil }
        helloSent = true
        return CaptureAvailabilityProtocol.hello
    }

    mutating func receive(_ payload: Data, flags: UInt16, generation: UInt64) -> Reception {
        guard generation != 0, generation == self.generation else { return .ignored("generation") }
        guard helloSent else { return .ignored("unnegotiated") }
        guard flags == 0, let command = CaptureAvailabilityCommand.decode(payload) else { return .ignored("malformed") }
        guard lastSequence == nil || command.sequence > lastSequence! else { return .ignored("stale") }
        lastSequence = command.sequence
        if command.state == 1 {
            let retire = !inputBlocked
            if !wireSuspended || retire {
                frames.removeAll(); frameOrder.removeAll(); freshRoot = false
                receivedAfterResume.removeAll(); receiptOrder.removeAll()
                suspensionFloor = lastAdmitted
            }
            wireSuspended = true
            notice = command.reason == 1 ? "Windows security prompt on PC" : "PC screen temporarily unavailable"
            return .suspended(retireInput: retire)
        }
        wireSuspended = false
        // Only decoded-and-presented continuation evidence may clear the notice.
        return .updated
    }

    // A route may reset wire frame sequences without ending the authenticated session.
    mutating func resetMediaDomain() {
        frames.removeAll(); frameOrder.removeAll(); freshRoot = false
        receivedAfterResume.removeAll(); receiptOrder.removeAll()
        lastAdmitted = nil; suspensionFloor = nil
    }

    // Called at transport receipt, before source/route buffers can delay admission.
    mutating func noteFrameReceived(sequence: UInt32) {
        guard inputBlocked, receivedAfterResume[sequence] == nil else { return }
        if receiptOrder.count == 256 { receivedAfterResume.removeValue(forKey: receiptOrder.removeFirst()) }
        receivedAfterResume[sequence] = !wireSuspended; receiptOrder.append(sequence)
    }

    func mayPresent(sequence: UInt32, decoder: UInt64) -> Bool {
        guard !wireSuspended else { return false }
        return !inputBlocked || frames[FrameKey(sequence: sequence, decoder: decoder)]?.receivedAfterResume == true
    }

    mutating func admitFrame(sequence: UInt32, decoder: UInt64, isIDR: Bool, generation: UInt64) -> Bool {
        guard generation != 0, generation == self.generation else { return false }
        guard inputBlocked else { lastAdmitted = sequence; return true }
        if let floor = suspensionFloor,
           sequence == floor || !MirrorControlCodec.sequenceAtOrAfter(sequence, floor) { return false }
        guard freshRoot || isIDR else { return false }
        freshRoot = true; lastAdmitted = sequence
        let key = FrameKey(sequence: sequence, decoder: decoder)
        guard frames[key] == nil else { return false }
        if frameOrder.count == 64 { frames.removeValue(forKey: frameOrder.removeFirst()) }
        frames[key] = Frame(receivedAfterResume: receivedAfterResume[sequence] ?? false)
        frameOrder.append(key)
        return true
    }

    @discardableResult mutating func observeFrame(sequence: UInt32, decoder: UInt64, decoded: Bool,
                                                   presented: Bool, generation: UInt64) -> Bool {
        guard generation == self.generation, inputBlocked else { return false }
        let key = FrameKey(sequence: sequence, decoder: decoder)
        guard var frame = frames[key] else { return false }
        frame.decoded = frame.decoded || decoded; frame.presented = frame.presented || presented
        frames[key] = frame
        guard !wireSuspended, frame.receivedAfterResume, frame.decoded && frame.presented else { return false }
        notice = nil; wireSuspended = false
        frames.removeAll(); frameOrder.removeAll()
        return true
    }
}

// Lives with the notice view, so repeated status publications never repeat VoiceOver.
struct CaptureAvailabilityAnnouncement {
    private var announced = false
    mutating func update(_ notice: String?) -> String? {
        guard let notice else { announced = false; return nil }
        guard !announced else { return nil }
        announced = true
        return notice
    }
}

enum CapturePresentationPolicy {
    static func confirmed(time: TimeInterval) -> Bool { time.isFinite && time > 0 }

    // Simulator has no drawable presentation feedback. Successful completion of
    // a current command buffer containing present is its best available proxy.
    static func simulatorCompleted(succeeded: Bool, current: Bool) -> Bool {
        succeeded && current
    }
}
