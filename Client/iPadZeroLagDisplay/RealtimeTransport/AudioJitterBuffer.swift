import Foundation

enum RealtimeAudioTransportProfile {
    case wifi
    case usb

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
    }

    func insert(_ packet: AudioJitterPacket) {
        guard packets[packet.sequence] == nil else { return }
        if let expectedSequence {
            let delta = packet.sequence &- expectedSequence
            if delta >= 0x8000 {
                guard let startupAnchorSequence else { return }
                let backwardDistance =
                    startupAnchorSequence &- packet.sequence
                guard !started,
                      backwardDistance <= UInt16(Self.maximumPacketCount) else {
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
        if packets.count > Self.maximumPacketCount {
            dropOldest()
        }
    }

    func dequeue() -> AudioJitterAction? {
        guard let expectedSequence else { return nil }
        if !started {
            guard packets.count >= profile.targetPacketCount else { return nil }
            started = true
            startupAnchorSequence = nil
        }

        if packets.count >= profile.targetPacketCount + 1 {
            dropOldest()
        }

        guard let currentExpected = self.expectedSequence else { return nil }
        if let packet = packets.removeValue(forKey: currentExpected) {
            advance(after: packet)
            return .decode(packet)
        }

        if !packets.isEmpty &&
            packets.count <= max(0, profile.targetPacketCount - 1) {
            let timestamp = expectedTimestamp
            self.expectedSequence = currentExpected &+ 1
            expectedTimestamp &+= Self.packetDurationSamples
            return .plc(sequence: currentExpected, timestamp: timestamp)
        }
        return nil
    }

    private func dropOldest() {
        guard let expectedSequence,
              let oldest = packets.keys.min(by: {
                  ($0 &- expectedSequence) < ($1 &- expectedSequence)
              }),
              let dropped = packets.removeValue(forKey: oldest) else { return }
        droppedPacketCount += 1
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
