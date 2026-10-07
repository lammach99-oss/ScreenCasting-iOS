import Foundation

enum RealtimeAudioTransportProfile: Equatable {
    case wifi
    case usb

    // Startup/prebuffer depth only; retained capacity is the separate hard bound.
    var targetPacketCount: Int {
        switch self {
        case .wifi: return 3
        case .usb: return 2
        }
    }
}

struct AudioJitterPacket: Equatable {
    let sequence: UInt16
    let timestamp: UInt32
    let payload: Data
}

enum AudioJitterAction: Equatable {
    case decode(AudioJitterPacket)
    case plc(sequence: UInt16, timestamp: UInt32)
}

struct AudioJitterDiagnostics {
    var insertedPackets = 0
    var duplicateRejects = 0
    var staleRejects = 0
    var maximumDepth = 0
    var decodeActions = 0
    var plcActions = 0
    var nilPlayoutActions = 0
    var targetPolicyDrops = 0
    var overflowDrops = 0
    var startupWaitTicks = 0
    private var depthSamples = [Double]()
    private var depthIndex = 0
    var depthPercentiles: LatencyPercentiles { LatencyPercentiles.calculate(depthSamples) }
    mutating func observeDepth(_ depth: Int) {
        if depthSamples.count < 256 { depthSamples.append(Double(depth)) }
        else { depthSamples[depthIndex] = Double(depth); depthIndex = (depthIndex + 1) % 256 }
    }
}

/// Observation only: never participates in packet admission or playout.
struct AudioReceiveDiagnostics {
    private var highest: UInt16?
    private var history: UInt64 = 0
    private var lastArrival: TimeInterval?
    private var lastTimestamp: UInt32 = 0
    private var intervals: [Double] = []
    private var intervalIndex = 0
    private(set) var packets = 0
    private(set) var forwardGaps = 0
    private(set) var missingPacketUnits = 0
    private(set) var reorderedPackets = 0
    private(set) var repairedPacketUnits = 0
    private(set) var duplicateOrStalePackets = 0
    private(set) var jitterMs = 0.0
    var interarrivalP95Ms: Double { LatencyPercentiles.calculate(intervals).p95 }
    var interarrivalMaxMs: Double { intervals.max() ?? 0 }

    mutating func record(sequence: UInt16, timestamp: UInt32, arrivedAt: TimeInterval) {
        packets += 1
        if let lastArrival {
            let elapsedMs = max(0, arrivedAt - lastArrival) * 1000
            if intervals.count < 256 { intervals.append(elapsedMs) }
            else { intervals[intervalIndex] = elapsedMs; intervalIndex = (intervalIndex + 1) % 256 }
            let mediaMs = Double(Int32(bitPattern: timestamp &- lastTimestamp)) / 48
            jitterMs += (abs(elapsedMs - mediaMs) - jitterMs) / 16
        }
        lastArrival = arrivedAt
        lastTimestamp = timestamp
        guard let highest else { self.highest = sequence; history = 1; return }
        let forward = sequence &- highest
        if forward > 0 && forward < 0x8000 {
            if forward > 1 { forwardGaps += 1; missingPacketUnits += Int(forward) - 1 }
            history = forward >= 64 ? 1 : (history << Int(forward)) | 1
            self.highest = sequence
        } else {
            let behind = highest &- sequence
            if behind < 64 && history & (UInt64(1) << Int(behind)) == 0 {
                history |= UInt64(1) << Int(behind)
                reorderedPackets += 1
                repairedPacketUnits += 1
            } else { duplicateOrStalePackets += 1 }
        }
    }
}

/// Serial-executor state for fixed 10 ms Opus packets.
final class AudioJitterBuffer {
    static let packetDurationSamples: UInt32 = 480
    static let maximumPacketCount = 6

    private(set) var profile: RealtimeAudioTransportProfile
    private var packets: [UInt16: AudioJitterPacket] = [:]
    private var expectedSequence: UInt16?
    private var expectedTimestamp: UInt32 = 0
    private var startupAnchorSequence: UInt16?
    private var started = false
    private(set) var droppedPacketCount = 0
    private(set) var diagnostics = AudioJitterDiagnostics()

    init(profile: RealtimeAudioTransportProfile) {
        self.profile = profile
    }

    var bufferedPacketCount: Int { packets.count }
    var targetDurationMs: Int { profile.targetPacketCount * 10 }
    var bufferedDurationMs: Int { packets.count * 10 }

    func reset(profile: RealtimeAudioTransportProfile? = nil) {
        if let profile {
            self.profile = profile
        }
        packets.removeAll(keepingCapacity: true)
        expectedSequence = nil
        expectedTimestamp = 0
        startupAnchorSequence = nil
        started = false
        droppedPacketCount = 0
        diagnostics = AudioJitterDiagnostics()
    }

    func insert(_ packet: AudioJitterPacket) {
        guard packets[packet.sequence] == nil else { diagnostics.duplicateRejects += 1; return }
        if let expectedSequence {
            let delta = packet.sequence &- expectedSequence
            if delta >= 0x8000 {
                guard let startupAnchorSequence else { diagnostics.staleRejects += 1; return }
                let backwardDistance =
                    startupAnchorSequence &- packet.sequence
                guard !started,
                      backwardDistance <= UInt16(Self.maximumPacketCount) else {
                    diagnostics.staleRejects += 1
                    return
                }
                self.expectedSequence = packet.sequence
                expectedTimestamp = packet.timestamp
            }
        } else {
            expectedSequence = packet.sequence
            expectedTimestamp = packet.timestamp
            startupAnchorSequence = packet.sequence
        }
        packets[packet.sequence] = packet
        diagnostics.insertedPackets += 1
        if packets.count > Self.maximumPacketCount {
            dropOldest(overflow: true)
        }
        diagnostics.maximumDepth = max(diagnostics.maximumDepth, packets.count)
    }

    func dequeue() -> AudioJitterAction? {
        diagnostics.observeDepth(packets.count)
        guard let expectedSequence else { return noPlayout() }
        if !started {
            guard packets.count >= profile.targetPacketCount else {
                diagnostics.startupWaitTicks += 1
                return noPlayout()
            }
            started = true
            startupAnchorSequence = nil
        }

        guard let currentExpected = self.expectedSequence else { return noPlayout() }
        if let packet = packets.removeValue(forKey: currentExpected) {
            advance(after: packet)
            diagnostics.decodeActions += 1
            return .decode(packet)
        }

        if !packets.isEmpty {
            let timestamp = expectedTimestamp
            self.expectedSequence = currentExpected &+ 1
            expectedTimestamp &+= Self.packetDurationSamples
            diagnostics.plcActions += 1
            return .plc(sequence: currentExpected, timestamp: timestamp)
        }
        return noPlayout()
    }

    private func noPlayout() -> AudioJitterAction? {
        diagnostics.nilPlayoutActions += 1
        return nil
    }

    private func dropOldest(overflow: Bool = false) {
        guard let expectedSequence,
              let oldest = packets.keys.min(by: {
                  ($0 &- expectedSequence) < ($1 &- expectedSequence)
              }),
              let dropped = packets.removeValue(forKey: oldest) else { return }
        droppedPacketCount += 1
        if overflow { diagnostics.overflowDrops += 1 }
        else { diagnostics.targetPolicyDrops += 1 }
        if let next = packets.values.min(by: {
            ($0.sequence &- expectedSequence) <
                ($1.sequence &- expectedSequence)
        }) {
            self.expectedSequence = next.sequence
            expectedTimestamp = next.timestamp
        } else {
            self.expectedSequence = oldest &+ 1
            expectedTimestamp = dropped.timestamp &+
                Self.packetDurationSamples
        }
    }

    private func advance(after packet: AudioJitterPacket) {
        startupAnchorSequence = nil
        expectedSequence = packet.sequence &+ 1
        expectedTimestamp = packet.timestamp &+
            Self.packetDurationSamples
    }
}
