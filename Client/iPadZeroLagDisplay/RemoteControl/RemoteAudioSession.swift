import Foundation

/// Network-queue state. Playback is authorized only for the current epoch.
struct RemoteAudioSession {
    struct Request: Equatable {
        let operation: RemoteAudioProtocol.Operation
        let id: UInt64
    }

    private(set) var preferred: Bool
    private(set) var suspended = false
    private(set) var phase: RemoteAudioProtocol.Phase = .off
    private(set) var reason: RemoteAudioProtocol.Reason = .none
    private(set) var activeEpoch: UInt64 = 0
    private(set) var pending: Request?
    private var negotiated = false
    private var initialChoice = false
    private var restartAfterDisable = false
    private var nextID: UInt64 = 0
    private var deadline: TimeInterval?
    private var lastEpoch: UInt64 = 0
    private var startUs: UInt64 = 0
    private var lastSequence: UInt32 = 0
    private var lastCapture: UInt64 = 0

    init(preferred: Bool = false) {
        self.preferred = preferred
    }

    private var canListen: Bool { preferred && !suspended }

    mutating func negotiate(granted: Bool) -> Request? {
        guard granted, !negotiated else { return nil }
        negotiated = true
        initialChoice = true
        return issue(.get)
    }

    mutating func prefer(_ enabled: Bool) -> Request? {
        guard preferred != enabled else { return nil }
        let wasListening = canListen
        preferred = enabled
        return reconcile(wasListening: wasListening)
    }

    mutating func suspend(_ value: Bool) -> Request? {
        guard suspended != value else { return nil }
        let wasListening = canListen
        suspended = value
        return reconcile(wasListening: wasListening)
    }

    private mutating func reconcile(wasListening: Bool) -> Request? {
        if !canListen { activeEpoch = 0 }
        guard negotiated, !initialChoice else { return nil }
        if pending?.operation == .disable {
            restartAfterDisable = canListen
            return nil
        }
        guard wasListening != canListen else { return nil }
        return issue(canListen ? .enable : .disable)
    }

    private mutating func issue(_ operation: RemoteAudioProtocol.Operation) -> Request? {
        guard nextID < UInt64.max else { return nil }
        nextID += 1
        let request = Request(operation: operation, id: nextID)
        pending = request
        deadline = nil
        return request
    }

    mutating func admit(_ request: Request, now: TimeInterval) -> Bool {
        guard pending == request, deadline == nil, request.operation != .enable || canListen else { return false }
        deadline = now + 2
        return true
    }

    mutating func tick(now: TimeInterval) -> Request? {
        guard let deadline, now >= deadline else { return nil }
        initialChoice = false
        restartAfterDisable = false
        return issue(.get)
    }

    mutating func receive(_ phase: RemoteAudioProtocol.Phase, reason: RemoteAudioProtocol.Reason,
                          requestID: UInt64, epoch: UInt64, startUs: UInt64) -> Request? {
        guard negotiated, requestID == 0 || (requestID == pending?.id && deadline != nil) else { return nil }
        self.phase = phase
        self.reason = reason
        if phase == .streaming {
            if canListen && pending?.operation != .disable {
                if epoch != lastEpoch {
                    lastEpoch = epoch
                    activeEpoch = epoch
                    self.startUs = startUs
                    lastSequence = 0
                    lastCapture = 0
                }
            } else {
                activeEpoch = 0
                lastEpoch = epoch
            }
        } else {
            activeEpoch = 0
        }
        guard requestID != 0, phase != .pending, let request = pending else { return nil }
        pending = nil
        deadline = nil
        if initialChoice {
            initialChoice = false
            return canListen && phase != .streaming ? issue(.enable) : nil
        }
        if request.operation == .disable && restartAfterDisable {
            restartAfterDisable = false
            return canListen && phase == .off ? issue(.enable) : nil
        }
        return nil
    }

    mutating func acceptPacket(sequence: UInt32, epoch: UInt64, captureUs: UInt64) -> Bool {
        guard canListen, activeEpoch != 0, epoch == activeEpoch, sequence > lastSequence,
              captureUs >= startUs, captureUs > lastCapture else { return false }
        lastSequence = sequence
        lastCapture = captureUs
        return true
    }
}

/// TLS preserves arrival order. Keep three fresh packets, conceal short gaps,
/// then wait for a fresh prebuffer instead of playing an unbounded gap.
struct RemoteAudioJitter {
    struct Packet {
        let sequence: UInt32
        let captureUs: UInt64
        let opus: Data
    }

    struct Frame: Equatable {
        let captureUs: UInt64
        let opus: Data?
    }

    private static let capacity = 3
    private static let packetUs: UInt64 = 10_000
    private var packets: [Packet] = []
    private var nextSequence: UInt32?
    private var nextCaptureUs: UInt64 = 0
    private var concealment = 0
    var count: Int { packets.count }

    mutating func insert(_ packet: Packet) {
        if let nextSequence, packet.sequence < nextSequence { return }
        if packets.count == Self.capacity {
            packets.removeFirst()
            nextSequence = nil
        }
        packets.append(packet)
    }

    mutating func dequeue() -> Frame? {
        if nextSequence == nil {
            guard packets.count == Self.capacity, let anchor = packets.first else { return nil }
            nextSequence = anchor.sequence
            nextCaptureUs = anchor.captureUs
        }
        guard let sequence = nextSequence else { return nil }
        if let packet = packets.first, packet.sequence == sequence {
            packets.removeFirst()
            advance(sequence: sequence, captureUs: packet.captureUs)
            concealment = 2
            return Frame(captureUs: packet.captureUs, opus: packet.opus)
        }
        guard concealment > 0 else {
            nextSequence = nil
            return dequeue()
        }
        let captureUs = nextCaptureUs
        advance(sequence: sequence, captureUs: captureUs)
        concealment -= 1
        return Frame(captureUs: captureUs, opus: nil)
    }

    private mutating func advance(sequence: UInt32, captureUs: UInt64) {
        nextSequence = sequence == UInt32.max ? nil : sequence + 1
        nextCaptureUs = captureUs > UInt64.max - Self.packetUs ? UInt64.max : captureUs + Self.packetUs
    }
}

struct RemoteAudioClock {
    let captureUs: UInt64
    let playoutAt: TimeInterval

    func videoDeadline(captureUs videoUs: UInt64, receivedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        let relativeUs = videoUs >= captureUs ? Double(videoUs - captureUs) : -Double(captureUs - videoUs)
        return max(now, min(playoutAt + relativeUs / 1_000_000, receivedAt + 0.050))
    }
}

/// Receives fragments already validated by RemoteAudioProtocol.
struct RemoteTimedVideoAssembler {
    struct AccessUnit: Equatable {
        let flags: UInt8
        let frame: UInt32
        let captureUs: UInt64
        let bytes: Data
        let firstByteAt: TimeInterval
    }

    enum Result: Equatable {
        case partial, complete(AccessUnit), recover
    }

    private struct Partial {
        let flags: UInt8
        let frame: UInt32
        let total: UInt32
        let captureUs: UInt64
        let firstByteAt: TimeInterval
        var bytes: Data
    }

    private var pending: Partial?
    var hasPartial: Bool { pending != nil }

    mutating func reset() { pending = nil }

    mutating func push(flags: UInt8, frame: UInt32, total: UInt32, offset: UInt32,
                       captureUs: UInt64, fragment: Data, receivedAt: TimeInterval) -> Result {
        if offset == 0 {
            var bytes = Data()
            bytes.reserveCapacity(Int(total))
            pending = Partial(flags: flags, frame: frame, total: total, captureUs: captureUs,
                              firstByteAt: receivedAt, bytes: bytes)
        }
        guard pending?.flags == flags, pending?.frame == frame, pending?.total == total,
              pending?.captureUs == captureUs, pending?.bytes.count == Int(offset) else {
            reset()
            return .recover
        }
        pending?.bytes.append(fragment)
        guard Int(offset) + fragment.count == Int(total), let complete = pending else { return .partial }
        reset()
        return .complete(AccessUnit(flags: flags, frame: frame, captureUs: captureUs,
                                   bytes: complete.bytes, firstByteAt: complete.firstByteAt))
    }
}
