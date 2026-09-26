import Foundation

struct ReassemblyDeadline {
    static func interval(
        rttP95Ms: Double,
        isIDR: Bool
    ) -> TimeInterval {
        if isIDR { return 0.050 }
        return min(0.035, max(0.012, (2 * rttP95Ms + 4) / 1_000))
    }
}

enum HevcReassemblyOutcome: Equatable {
    case accepted
    case duplicate
    case expired(frameSequence: UInt32)
    case authenticationFailure
    case malformed
    case sequenceAnchorLost(expectedSequence: UInt16)
    case completed(
        accessUnit: Data,
        frameSequence: UInt32,
        captureTime90k: UInt32)
}

final class HevcRtpReassembler {
    private static let maximumBufferedFrames = 6
    private static let maximumPendingOutcomes = maximumBufferedFrames + 1

    private struct Frame {
        let timestamp: UInt32
        let frameSequence: UInt32
        let captureTime90k: UInt32
        let firstArrival: TimeInterval
        var deadline: TimeInterval
        var packets: [UInt16: RtpPacketView] = [:]
        var markerSequence: UInt16?
    }

    private var frames: [UInt32: Frame] = [:]
    private var expectedNextSequence: UInt16?
    private var maySelfAnchor: Bool
    private var requiresIDRAnchor = false
    private var requiresDecoderConfigurationAnchor = false
    private var pendingOutcomes: [HevcReassemblyOutcome] = []
    private let mtu: Int

    /// `initialExpectedSequence` is the first RTP sequence assigned by the
    /// authenticated sender. Supply it when initial packets may be reordered.
    /// Without it, only the first non-marker NAL boundary may self-anchor; a
    /// marker-first initial frame is never guessed and expires conservatively.
    init(
        mtu: Int,
        initialExpectedSequence: UInt16? = nil
    ) {
        self.mtu = mtu
        expectedNextSequence = initialExpectedSequence
        maySelfAnchor = initialExpectedSequence == nil
    }

    var allocatedFrameCount: Int { frames.count }
    var pendingOutcomeCount: Int { pendingOutcomes.count }

    func resetExpectedSequence(_ sequence: UInt16) {
        expectedNextSequence = sequence
        maySelfAnchor = false
        requiresIDRAnchor = false
        requiresDecoderConfigurationAnchor = false
        reevaluateBufferedFrames()
    }

    func prepareForFreshIDRAnchor() {
        frames.removeAll()
        pendingOutcomes.removeAll()
        expectedNextSequence = nil
        maySelfAnchor = true
        requiresIDRAnchor = true
        requiresDecoderConfigurationAnchor = true
    }

    func drainOutcome() -> HevcReassemblyOutcome? {
        guard !pendingOutcomes.isEmpty else { return nil }
        return pendingOutcomes.removeFirst()
    }

    func consume(
        _ data: Data,
        authentication: RtpAuthenticationSignal,
        arrivalTime: TimeInterval,
        rttP95Ms: Double
    ) -> HevcReassemblyOutcome {
        let priorOutcome = drainOutcome()
        guard case .authenticated = authentication else {
            enqueue(.authenticationFailure)
            return priorOutcome ?? drainOutcome()!
        }
        guard let packet = RtpPacketView(
            data: data,
            mtu: mtu,
            authentication: authentication),
              packet.payload.count >= 2 else {
            enqueue(.malformed)
            return priorOutcome ?? drainOutcome()!
        }

        expireFrames(at: arrivalTime)
        if frames[packet.timestamp] == nil &&
           frames.count >= Self.maximumBufferedFrames {
            if let oldest = frames.values.min(by: {
                $0.firstArrival < $1.firstArrival
            }) {
                drop(
                    oldest,
                    outcome: .expired(
                        frameSequence: oldest.frameSequence))
            }
        }

        if frames[packet.timestamp] == nil {
            let randomAccess = Self.isRandomAccessPayloadType(
                packet.payload)
            frames[packet.timestamp] = Frame(
                timestamp: packet.timestamp,
                frameSequence: packet.frameSequence,
                captureTime90k: packet.captureTime90k,
                firstArrival: arrivalTime,
                deadline: arrivalTime + ReassemblyDeadline.interval(
                    rttP95Ms: rttP95Ms,
                    isIDR: randomAccess))
        }
        guard var frame = frames[packet.timestamp] else {
            enqueue(.malformed)
            return priorOutcome ?? drainOutcome()!
        }
        guard frame.frameSequence == packet.frameSequence,
              frame.captureTime90k == packet.captureTime90k else {
            drop(frame, outcome: .malformed)
            reevaluateBufferedFrames()
            return priorOutcome ?? drainOutcome()!
        }
        if frame.packets[packet.sequence] != nil {
            enqueue(.duplicate)
            return priorOutcome ?? drainOutcome()!
        }
        if Self.isRandomAccessPayloadType(packet.payload) {
            frame.deadline = max(
                frame.deadline,
                frame.firstArrival + 0.050)
        }
        frame.packets[packet.sequence] = packet
        if packet.marker {
            if let existing = frame.markerSequence,
               existing != packet.sequence {
                drop(frame, outcome: .malformed)
                reevaluateBufferedFrames()
                return priorOutcome ?? drainOutcome()!
            }
            frame.markerSequence = packet.sequence
        }
        frames[packet.timestamp] = frame

        if maySelfAnchor {
            if requiresIDRAnchor,
               let anchor = Self.recoveryAnchorSequence(
                   in: frame,
                   requiresDecoderConfiguration:
                       requiresDecoderConfigurationAnchor) {
                maySelfAnchor = false
                requiresIDRAnchor = false
                requiresDecoderConfigurationAnchor = false
                expectedNextSequence = anchor
            } else if !requiresIDRAnchor,
                      !packet.marker,
                      Self.isNalBoundary(packet.payload) {
                maySelfAnchor = false
                expectedNextSequence = packet.sequence
            }
        }
        reevaluateBufferedFrames()
        return priorOutcome ?? drainOutcome() ?? .accepted
    }

    func expire(at now: TimeInterval) -> [HevcReassemblyOutcome] {
        expireFrames(at: now)
        reevaluateBufferedFrames()
        var result: [HevcReassemblyOutcome] = []
        while let outcome = drainOutcome() { result.append(outcome) }
        return result
    }

    private func expireFrames(at now: TimeInterval) {
        let expired = frames.values
            .filter { now >= $0.deadline }
            .sorted { $0.firstArrival < $1.firstArrival }
        for frame in expired {
            drop(
                frame,
                outcome: .expired(
                    frameSequence: frame.frameSequence))
        }
    }

    private func drop(
        _ frame: Frame,
        outcome: HevcReassemblyOutcome
    ) {
        frames.removeValue(forKey: frame.timestamp)
        guard let expected = expectedNextSequence else {
            enqueue(outcome)
            return
        }
        let ownedAnchor = frame.packets[expected] != nil
        if ownedAnchor {
            loseSequenceAnchor(expected)
        } else {
            let hasViableAnchor = frames.values.contains {
                $0.packets[expected] != nil
            }
            if !hasViableAnchor {
                loseSequenceAnchor(expected)
            }
        }
        enqueue(outcome)
    }

    private func loseSequenceAnchor(_ expected: UInt16) {
        expectedNextSequence = nil
        maySelfAnchor = true
        requiresIDRAnchor = true
        requiresDecoderConfigurationAnchor = false
        enqueue(.sequenceAnchorLost(expectedSequence: expected))
    }

    private func enqueue(_ outcome: HevcReassemblyOutcome) {
        guard outcome != .accepted else { return }
        if outcome == .duplicate,
           pendingOutcomes.count >= Self.maximumPendingOutcomes {
            return
        }
        if pendingOutcomes.count >= Self.maximumPendingOutcomes {
            if let duplicate = pendingOutcomes.firstIndex(of: .duplicate) {
                pendingOutcomes.remove(at: duplicate)
            } else if let removable = pendingOutcomes.firstIndex(where: {
                if case .sequenceAnchorLost = $0 { return false }
                return true
            }) {
                pendingOutcomes.remove(at: removable)
            } else {
                return
            }
        }
        pendingOutcomes.append(outcome)
    }

    private enum Completion {
        case incomplete
        case malformed
        case completed(Data)
    }

    private func complete(
        _ frame: Frame,
        first: UInt16
    ) -> Completion {
        guard let marker = frame.markerSequence,
              frame.packets[first] != nil else { return .incomplete }
        var ordered: [RtpPacketView] = []
        var sequence = first
        while true {
            guard let packet = frame.packets[sequence] else {
                return .incomplete
            }
            ordered.append(packet)
            if sequence == marker { break }
            sequence &+= 1
        }
        return Self.reassemble(ordered)
    }

    private func reevaluateBufferedFrames() {
        while let first = expectedNextSequence,
              let frame = frames.values.first(where: {
                  $0.packets[first] != nil
              }) {
            switch complete(frame, first: first) {
            case .incomplete:
                return
            case .malformed:
                drop(frame, outcome: .malformed)
            case .completed(let accessUnit):
                frames.removeValue(forKey: frame.timestamp)
                expectedNextSequence =
                    frame.markerSequence.map { $0 &+ 1 }
                maySelfAnchor = false
                requiresIDRAnchor = false
                enqueue(.completed(
                    accessUnit: accessUnit,
                    frameSequence: frame.frameSequence,
                    captureTime90k: frame.captureTime90k))
            }
        }
    }

    private static func reassemble(
        _ packets: [RtpPacketView]
    ) -> Completion {
        var output = Data()
        var index = 0
        while index < packets.count {
            let payload = packets[index].payload
            let type = (payload[0] >> 1) & 0x3F
            if type != 49 {
                appendLengthPrefixed(payload, to: &output)
                index += 1
                continue
            }
            guard payload.count >= 4,
                  payload[2] & 0x80 != 0,
                  payload[2] & 0x40 == 0 else {
                return .malformed
            }
            let fuType = payload[2] & 0x3F
            let fuLayerHigh = payload[0] & 0x81
            let fuLayerTemporal = payload[1]
            var nal = Data([
                fuLayerHigh | (fuType << 1),
                payload[1]
            ])
            var ended = false
            var firstFragment = true
            while index < packets.count {
                let fragment = packets[index].payload
                guard fragment.count >= 4,
                      (fragment[0] >> 1) & 0x3F == 49,
                      fragment[0] & 0x81 == fuLayerHigh,
                      fragment[1] == fuLayerTemporal,
                      fragment[2] & 0x3F == fuType else {
                    return .malformed
                }
                if !firstFragment && fragment[2] & 0x80 != 0 {
                    return .malformed
                }
                nal.append(contentsOf: fragment.dropFirst(3))
                ended = fragment[2] & 0x40 != 0
                index += 1
                firstFragment = false
                if ended {
                    if index < packets.count {
                        let trailing = packets[index].payload
                        if trailing.count >= 3,
                           (trailing[0] >> 1) & 0x3F == 49,
                           trailing[2] & 0x80 == 0 {
                            return .malformed
                        }
                    }
                    break
                }
            }
            guard ended else { return .malformed }
            appendLengthPrefixed(nal, to: &output)
        }
        return .completed(output)
    }

    private static func appendLengthPrefixed(
        _ nal: Data,
        to output: inout Data
    ) {
        let count = UInt32(nal.count)
        output.append(UInt8(truncatingIfNeeded: count >> 24))
        output.append(UInt8(truncatingIfNeeded: count >> 16))
        output.append(UInt8(truncatingIfNeeded: count >> 8))
        output.append(UInt8(truncatingIfNeeded: count))
        output.append(nal)
    }

    private static func nalType(_ payload: Data) -> UInt8? {
        guard payload.count >= 2 else { return nil }
        let type = (payload[0] >> 1) & 0x3F
        if type == 49 {
            guard payload.count >= 3 else { return nil }
            return payload[2] & 0x3F
        }
        return type
    }

    private static func isIDR(_ payload: Data) -> Bool {
        guard let nalType = nalType(payload) else { return false }
        return nalType == 19 || nalType == 20 || nalType == 21
    }

    private static func isRandomAccessPayloadType(_ payload: Data) -> Bool {
        guard let type = nalType(payload) else { return false }
        return type == 32 || type == 33 || type == 34 ||
            type == 19 || type == 20 || type == 21
    }

    private static func recoveryAnchorSequence(
        in frame: Frame,
        requiresDecoderConfiguration: Bool
    ) -> UInt16? {
        let idrBoundaries = frame.packets.values.filter {
            isIDR($0.payload) && isNalBoundary($0.payload)
        }
        for idr in idrBoundaries {
            if requiresDecoderConfiguration {
                let vpsBoundaries = frame.packets.values.filter {
                    nalType($0.payload) == 32 &&
                        isNalBoundary($0.payload) &&
                        UInt16(truncatingIfNeeded:
                            idr.sequence &- $0.sequence) < 0x8000
                }.sorted {
                    UInt16(truncatingIfNeeded:
                        idr.sequence &- $0.sequence) >
                    UInt16(truncatingIfNeeded:
                        idr.sequence &- $1.sequence)
                }
                for vps in vpsBoundaries where hasDecoderConfigurationPrefix(
                    in: frame,
                    from: vps.sequence,
                    through: idr.sequence) {
                    return vps.sequence
                }
                continue
            }
            let prefix = frame.packets.values.filter {
                UInt16(truncatingIfNeeded: idr.sequence &- $0.sequence) < 0x8000
            }
            guard let first = prefix.max(by: {
                UInt16(truncatingIfNeeded: idr.sequence &- $0.sequence) <
                    UInt16(truncatingIfNeeded: idr.sequence &- $1.sequence)
            }), isNalBoundary(first.payload) else { continue }
            var sequence = first.sequence
            for _ in 0..<prefix.count {
                guard frame.packets[sequence] != nil else { break }
                if sequence == idr.sequence { return first.sequence }
                sequence &+= 1
            }
        }
        return nil
    }

    private static func hasDecoderConfigurationPrefix(
        in frame: Frame,
        from start: UInt16,
        through idr: UInt16
    ) -> Bool {
        let distance = Int(UInt16(truncatingIfNeeded: idr &- start))
        guard distance < frame.packets.count else { return false }
        var sawVPS = false
        var sawSPS = false
        var sawPPS = false
        var sequence = start
        for _ in 0...distance {
            guard let packet = frame.packets[sequence] else { return false }
            if isNalBoundary(packet.payload), let type = nalType(packet.payload) {
                switch type {
                case 32 where !sawSPS && !sawPPS:
                    sawVPS = true
                case 33 where sawVPS && !sawPPS:
                    sawSPS = true
                case 34 where sawVPS && sawSPS:
                    sawPPS = true
                default:
                    break
                }
            }
            sequence &+= 1
        }
        return sawVPS && sawSPS && sawPPS
    }

    private static func isNalBoundary(_ payload: Data) -> Bool {
        let type = (payload[0] >> 1) & 0x3F
        return type != 49 ||
            (payload.count >= 3 && payload[2] & 0x80 != 0)
    }

}
