import Foundation
import Network
import QuartzCore

enum WifiMediaReceiverError: Error {
    case listenerFailed
    case invalidPort
    case invalidOffer
}

enum WifiTransportTiming {
    static let hostProbeTimeoutMs = 750
    static let controlDeliveryMarginMs = 500
    static let clientPostProbeCommitTimeoutMs = 1_500
    static let clientFallbackCommitTimeoutMs = 1_500
}

enum WifiCommittedFailurePolicy {
    static func shouldTearDown(
        failureGeneration: UInt64,
        connectionGeneration: UInt64,
        committedGeneration: UInt64?
    ) -> Bool {
        failureGeneration == connectionGeneration &&
            committedGeneration == failureGeneration
    }
}

enum WifiMediaContract {
    static let srtpTagLength = 16
    static let maximumOpusPayloadLength = 1_275
    private static let domainMask: UInt32 = 0x3fff_ffff

    static func mediaSsrc(_ sessionID: SessionID) -> UInt32 {
        derive(
            sessionID, offset: 0, domain: 0x6d656469,
            domainTag: 0x0000_0000)
    }

    static func audioSsrc(_ sessionID: SessionID) -> UInt32 {
        derive(
            sessionID, offset: 0, domain: 0x61756469,
            domainTag: 0x0000_0000)
    }

    static func inputSsrc(_ sessionID: SessionID) -> UInt32 {
        var candidate = derive(
            sessionID, offset: 0, domain: 0x696e7074,
            domainTag: 0x0000_0000)
        let reserved = Set([
            mediaSsrc(sessionID),
            audioSsrc(sessionID),
            feedbackSsrc(sessionID),
            probeRequestSsrc(sessionID),
            probeAcknowledgementSsrc(sessionID)
        ])
        while reserved.contains(candidate) {
            candidate = (candidate &+ 1) & domainMask
            if candidate == 0 { candidate = 1 }
        }
        return candidate
    }

    static func feedbackSsrc(_ sessionID: SessionID) -> UInt32 {
        derive(
            sessionID, offset: 4, domain: 0x6664626b,
            domainTag: 0x4000_0000)
    }

    static func probeRequestSsrc(_ sessionID: SessionID) -> UInt32 {
        derive(
            sessionID, offset: 8, domain: 0x70726571,
            domainTag: 0x8000_0000)
    }

    static func probeAcknowledgementSsrc(_ sessionID: SessionID) -> UInt32 {
        derive(
            sessionID, offset: 12, domain: 0x7061636b,
            domainTag: 0xc000_0000)
    }

    static func initialMediaSequence(_ sessionID: SessionID) -> UInt16 {
        let bytes = sessionID.dataCopy()
        return UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    }

    static func initialInputSequence(_ sessionID: SessionID) -> UInt32 {
        let bytes = sessionID.dataCopy()
        return UInt32(bytes[12]) << 24 |
            UInt32(bytes[13]) << 16 |
            UInt32(bytes[14]) << 8 |
            UInt32(bytes[15])
    }

    private static func derive(
        _ sessionID: SessionID,
        offset: Int,
        domain: UInt32,
        domainTag: UInt32
    ) -> UInt32 {
        let bytes = sessionID.dataCopy()
        let raw = UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
        var value = (raw ^ domain) & domainMask
        if domainTag == 0 && value == 0 { value = 1 }
        return domainTag | value
    }
}

enum WifiInputRtpCodec {
    static let payloadType: UInt8 = 112
    static let headerLength = 12
    static let payloadLength = 12
    static let plaintextLength = headerLength + payloadLength
    static let protectedCapacity =
        plaintextLength + WifiMediaContract.srtpTagLength

    static func packet(
        touch: Data,
        sequence: UInt32,
        ssrc: UInt32
    ) -> Data? {
        guard touch.count == 8,
              touch[0] == 0x49,
              touch[1] == 0x54,
              touch[2] == TouchEventType.move.rawValue else {
            return nil
        }
        var packet = Data(count: protectedCapacity)
        packet[0] = 0x80
        packet[1] = payloadType
        packet[2] = UInt8(truncatingIfNeeded: sequence >> 8)
        packet[3] = UInt8(truncatingIfNeeded: sequence)
        writeBE32(sequence, to: &packet, at: 4)
        writeBE32(ssrc, to: &packet, at: 8)
        packet.replaceSubrange(12..<20, with: touch)
        writeBE32(sequence, to: &packet, at: 20)
        return packet
    }

    private static func writeBE32(
        _ value: UInt32,
        to data: inout Data,
        at offset: Int
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}

final class WifiLatestInputWriter {
    typealias PacketBuilder = (Data, UInt32) throws -> Data
    typealias Sender = (Data, @escaping (Error?) -> Void) -> Void

    private let queue: DispatchQueue
    private let packetBuilder: PacketBuilder
    private let sender: Sender
    private let onFailure: (UInt64, Error) -> Void
    private var generation: UInt64?
    private var epoch: UInt64 = 0
    private var nextSequence: UInt32 = 0
    private var pending: Data?
    private var inFlight = false

    init(
        queue: DispatchQueue,
        packetBuilder: @escaping PacketBuilder,
        sender: @escaping Sender,
        onFailure: @escaping (UInt64, Error) -> Void
    ) {
        self.queue = queue
        self.packetBuilder = packetBuilder
        self.sender = sender
        self.onFailure = onFailure
    }

    var bufferedPacketCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return (inFlight ? 1 : 0) + (pending == nil ? 0 : 1)
    }

    func begin(generation: UInt64, initialSequence: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        self.generation = generation
        nextSequence = initialSequence
    }

    func enqueue(_ touch: Data, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.generation == generation else { return }
        pending = touch
        pump()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        epoch &+= 1
        generation = nil
        pending = nil
        inFlight = false
    }

    private func pump() {
        guard !inFlight,
              let generation,
              let touch = pending else { return }
        pending = nil
        let sequence = nextSequence
        nextSequence &+= 1
        let packet: Data
        do {
            packet = try packetBuilder(touch, sequence)
        } catch {
            cancel()
            onFailure(generation, error)
            return
        }
        inFlight = true
        let sendEpoch = epoch
        sender(packet) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.epoch == sendEpoch,
                      self.generation == generation else { return }
                self.inFlight = false
                if let error {
                    self.cancel()
                    self.onFailure(generation, error)
                    return
                }
                self.pump()
            }
        }
    }
}

enum WifiOpusRtpCodec {
    static let payloadType: UInt8 = 111
    static let headerLength = 12

    static func parse(
        _ packet: Data,
        expectedSsrc: UInt32
    ) -> AudioJitterPacket? {
        guard packet.count > headerLength,
              packet.count <=
                headerLength + WifiMediaContract.maximumOpusPayloadLength,
              packet[0] == 0x80,
              packet[1] == payloadType,
              readBE32(packet, at: 8) == expectedSsrc else { return nil }
        let sequence = UInt16(packet[2]) << 8 | UInt16(packet[3])
        let timestamp =
            UInt32(packet[4]) << 24 |
            UInt32(packet[5]) << 16 |
            UInt32(packet[6]) << 8 |
            UInt32(packet[7])
        return AudioJitterPacket(
            sequence: sequence,
            timestamp: timestamp,
            payload: packet.subdata(in: headerLength..<packet.count))
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
    }
}

private enum WifiProbeCodec {
    static let plaintextLength = 32
    private static let payloadType: UInt8 = 126
    private static let requestMagic = Data("SCPR".utf8)
    private static let acknowledgementMagic = Data("SCPA".utf8)

    static func isRequest(
        _ packet: Data,
        sessionID: SessionID,
        ssrc: UInt32
    ) -> Bool {
        guard packet.count == plaintextLength,
              packet[0] == 0x80,
              packet[1] & 0x7f == payloadType,
              readBE32(packet, at: 8) == ssrc,
              packet.subdata(in: 12..<16) == requestMagic,
              let received = SessionID(
                bytes: packet.subdata(in: 16..<32)) else { return false }
        return received == sessionID
    }

    static func acknowledgement(
        sessionID: SessionID,
        ssrc: UInt32
    ) -> Data {
        var packet = Data(
            count: plaintextLength + WifiMediaContract.srtpTagLength)
        packet[0] = 0x80
        packet[1] = payloadType
        writeBE32(ssrc, to: &packet, at: 8)
        packet.replaceSubrange(12..<16, with: acknowledgementMagic)
        sessionID.write(to: &packet, at: 16)
        return packet
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
    }

    private static func writeBE32(
        _ value: UInt32,
        to data: inout Data,
        at offset: Int
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}

final class WifiAuthenticatedMediaProcessor {
    typealias Unprotect = (inout Data) -> Bool
    typealias Decoder = (Data, UInt32, Bool, TimeInterval) -> Void
    typealias PacketObserver = (
        UInt16, UInt32, Bool, TimeInterval
    ) -> Void
    typealias OutcomeObserver = (HevcReassemblyOutcome) -> Void
    typealias FramePacketObserver = (
        UInt32, Bool, Bool, Int, TimeInterval
    ) -> Void
    typealias TimedOutcomeObserver = (
        HevcReassemblyOutcome, TimeInterval
    ) -> Void

    private let reassembler: HevcRtpReassembler
    private let unprotect: Unprotect
    private let decoder: Decoder
    private let packetObserver: PacketObserver?
    private let outcomeObserver: OutcomeObserver?
    private let framePacketObserver: FramePacketObserver?
    private let timedOutcomeObserver: TimedOutcomeObserver?
    private(set) var authenticationFailures = 0

    init(
        mtu: Int,
        initialSequence: UInt16,
        unprotect: @escaping Unprotect,
        decoder: @escaping Decoder,
        packetObserver: PacketObserver? = nil,
        outcomeObserver: OutcomeObserver? = nil,
        framePacketObserver: FramePacketObserver? = nil,
        timedOutcomeObserver: TimedOutcomeObserver? = nil
    ) {
        reassembler = HevcRtpReassembler(
            mtu: mtu,
            initialExpectedSequence: initialSequence)
        self.unprotect = unprotect
        self.decoder = decoder
        self.packetObserver = packetObserver
        self.outcomeObserver = outcomeObserver
        self.framePacketObserver = framePacketObserver
        self.timedOutcomeObserver = timedOutcomeObserver
    }

    var allocatedFrameCount: Int {
        reassembler.allocatedFrameCount
    }

    func consume(_ protectedPacket: Data, arrivalTime: TimeInterval) {
        var packet = protectedPacket
        guard unprotect(&packet) else {
            authenticationFailures += 1
            return
        }
        if packet.count >= 8 {
            packetObserver?(
                UInt16(packet[2]) << 8 | UInt16(packet[3]),
                UInt32(packet[4]) << 24 |
                    UInt32(packet[5]) << 16 |
                    UInt32(packet[6]) << 8 |
                    UInt32(packet[7]),
                packet[1] & 0x80 != 0,
                arrivalTime)
        }
        if let view = RtpPacketView(
            data: packet,
            mtu: packet.count,
            authentication: .authenticated) {
            self.framePacketObserver?(
                view.frameSequence,
                view.marker,
                Self.isIDRPacketPayload(view.payload),
                packet.count,
                arrivalTime)
        }
        var outcome: HevcReassemblyOutcome? = reassembler.consume(
            packet,
            authentication: .authenticated,
            arrivalTime: arrivalTime,
            rttP95Ms: 4)
        while let current = outcome {
            outcomeObserver?(current)
            self.timedOutcomeObserver?(current, arrivalTime)
            if case .completed(
                let accessUnit,
                let frameSequence,
                _) = current {
                decoder(
                    accessUnit,
                    frameSequence,
                    Self.isIDR(accessUnit),
                    arrivalTime)
            }
            outcome = reassembler.drainOutcome()
        }
    }

    fileprivate static func isIDR(_ accessUnit: Data) -> Bool {
        var offset = 0
        while offset + 6 <= accessUnit.count {
            let count = Int(UInt32(accessUnit[offset]) << 24 |
                UInt32(accessUnit[offset + 1]) << 16 |
                UInt32(accessUnit[offset + 2]) << 8 |
                UInt32(accessUnit[offset + 3]))
            guard count >= 2, offset + 4 + count <= accessUnit.count else {
                return false
            }
            let type = (accessUnit[offset + 4] >> 1) & 0x3f
            if type == 19 || type == 20 || type == 21 { return true }
            offset += 4 + count
        }
        return false
    }

    private static func isIDRPacketPayload(_ payload: Data) -> Bool {
        guard payload.count >= 2 else { return false }
        let type = (payload[0] >> 1) & 0x3f
        if type == 19 || type == 20 || type == 21 { return true }
        guard type == 49, payload.count >= 3 else { return false }
        let fragmentedType = payload[2] & 0x3f
        return fragmentedType == 19 ||
            fragmentedType == 20 ||
            fragmentedType == 21
    }
}

struct WifiFeedbackWindow {
    private(set) var highest: UInt16?
    private(set) var bitmap: UInt64 = 0

    mutating func observe(_ sequence: UInt16) {
        guard let current = highest else {
            highest = sequence
            bitmap = 0
            return
        }
        let forward = UInt16(truncatingIfNeeded: sequence &- current)
        if forward != 0 && forward < 0x8000 {
            if forward >= 65 {
                bitmap = 0
            } else {
                bitmap <<= UInt64(forward)
                bitmap |= UInt64(1) << UInt64(forward - 1)
            }
            highest = sequence
            return
        }
        let back = UInt16(truncatingIfNeeded: current &- sequence)
        if back >= 1 && back <= 64 {
            bitmap |= UInt64(1) << UInt64(back - 1)
        }
    }
}

struct WifiSecurityDropCounters: Equatable {
    private(set) var authentication: UInt64 = 0
    private(set) var replay: UInt64 = 0
    private(set) var wrongEndpoint: UInt64 = 0

    mutating func recordCryptoFailure(_ error: Error) {
        guard let crypto = error as? RealtimeCryptoError,
              case .nativeFailure(let status) = crypto else { return }
        // RealtimeAbi.h maps both libsrtp replay statuses to 0x8004A002.
        if status == -2_147_180_542 {
            replay = Self.increment(replay)
        } else if status == -2_147_180_543 {
            authentication = Self.increment(authentication)
        }
    }

    mutating func recordWrongEndpoint() {
        wrongEndpoint = Self.increment(wrongEndpoint)
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }
}

struct WifiFeedbackTelemetry {
    let lastDecoded: UInt32
    let lastPresented: UInt32
    let jitterMs: UInt16
    let rttP95Ms: UInt16
    let queueAgeP95Ms: UInt16
    let decodeP95Ms: UInt16

    static let zero = WifiFeedbackTelemetry(
        lastDecoded: 0, lastPresented: 0, jitterMs: 0,
        rttP95Ms: 0, queueAgeP95Ms: 0, decodeP95Ms: 0)
}

enum WifiFeedbackCodec {
    static let plaintextLength = 72
    static let version: UInt16 = 2
    static let maximumRttMs: UInt16 = 10_000
    private static let payloadType: UInt8 = 125

    static func packet(
        sequence: UInt16,
        ssrc: UInt32,
        window: WifiFeedbackWindow,
        lastCompleted: UInt32,
        telemetry: WifiFeedbackTelemetry,
        smoothedRttMs: UInt16,
        expiredFrames: UInt16,
        immediate: Bool,
        dependencyBreak: Bool,
        recoveryCompleted: Bool,
        rttToken: UInt32,
        rttSentNanoseconds: UInt64,
        frameIntervalMs: Double,
        recoveryEpisode: UInt32
    ) -> Data {
        var packet = Data(
            count: plaintextLength + WifiMediaContract.srtpTagLength)
        packet[0] = 0x80
        packet[1] = payloadType
        writeBE16(sequence, to: &packet, at: 2)
        writeBE32(ssrc, to: &packet, at: 8)
        packet.replaceSubrange(12..<16, with: Data("SCFB".utf8))
        writeBE16(window.highest ?? 0, to: &packet, at: 16)
        writeBE16(version, to: &packet, at: 18)
        writeBE64(window.bitmap, to: &packet, at: 20)
        writeBE32(lastCompleted, to: &packet, at: 28)
        writeBE32(telemetry.lastDecoded, to: &packet, at: 32)
        writeBE32(telemetry.lastPresented, to: &packet, at: 36)
        writeBE16(telemetry.jitterMs, to: &packet, at: 40)
        writeBE16(min(smoothedRttMs, maximumRttMs), to: &packet, at: 42)
        writeBE16(
            min(max(telemetry.rttP95Ms, smoothedRttMs), maximumRttMs),
            to: &packet,
            at: 44)
        writeBE16(telemetry.queueAgeP95Ms, to: &packet, at: 46)
        writeBE16(telemetry.decodeP95Ms, to: &packet, at: 48)
        writeBE16(expiredFrames, to: &packet, at: 50)
        var flags: UInt16 = immediate ? 1 : 0
        if dependencyBreak { flags |= 2 }
        if recoveryCompleted { flags |= 4 }
        writeBE16(flags, to: &packet, at: 52)
        writeBE32(rttToken, to: &packet, at: 54)
        writeBE64(rttSentNanoseconds, to: &packet, at: 58)
        writeBE16(
            UInt16(clamping: Int(frameIntervalMs * 100)),
            to: &packet,
            at: 66)
        writeBE32(recoveryEpisode, to: &packet, at: 68)
        return packet
    }

    private static func writeBE16(
        _ value: UInt16, to data: inout Data, at offset: Int
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeBE32(
        _ value: UInt32, to data: inout Data, at offset: Int
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeBE64(
        _ value: UInt64, to data: inout Data, at offset: Int
    ) {
        for index in 0..<8 {
            data[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt64(56 - index * 8))
        }
    }
}

private enum WifiFeedbackEchoCodec {
    static let plaintextLength = 28
    private static let payloadType: UInt8 = 124

    static func parse(
        _ packet: Data,
        expectedSsrc: UInt32
    ) -> (token: UInt32, sentNanoseconds: UInt64)? {
        guard packet.count == plaintextLength,
              packet[0] == 0x80,
              packet[1] & 0x7f == payloadType,
              readBE32(packet, at: 8) == expectedSsrc,
              packet.subdata(in: 12..<16) == Data("SCFE".utf8)
        else { return nil }
        return (readBE32(packet, at: 16), readBE64(packet, at: 20))
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    private static func readBE64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8 | UInt64(data[offset + index])
        }
        return value
    }
}

struct WifiProbeCandidateGate<Source: Hashable> {
    private let limit: Int
    private var order: [Source] = []
    private(set) var committed: Source?

    init(limit: Int = 2) {
        precondition(limit > 0)
        self.limit = limit
    }

    mutating func register(_ source: Source) -> (accepted: Bool, evicted: Source?) {
        guard committed == nil else { return (false, nil) }
        if order.contains(source) { return (true, nil) }
        var evicted: Source?
        if order.count == limit {
            evicted = order.removeFirst()
        }
        order.append(source)
        return (true, evicted)
    }

    mutating func reject(_ source: Source) {
        order.removeAll { $0 == source }
    }

    mutating func authenticate(_ source: Source) -> [Source]? {
        guard committed == nil, order.contains(source) else { return nil }
        let abandoned = order.filter { $0 != source }
        order.removeAll()
        committed = source
        return abandoned
    }

    mutating func reset() {
        order.removeAll()
        committed = nil
    }
}

struct WifiCommitGate {
    private enum Phase {
        case idle
        case waitingForProbe(SessionID)
        case waitingForCommit(SessionID, UInt64)
        case waitingForFallbackCommit(SessionID, UInt64)
        case committed
        case aborted
    }

    private var phase: Phase = .idle
    private var nextToken: UInt64 = 0

    var legacyFallbackAllowed: Bool {
        switch phase {
        case .idle, .waitingForProbe:
            return true
        case .waitingForCommit, .waitingForFallbackCommit,
             .committed, .aborted:
            return false
        }
    }

    mutating func begin(sessionID: SessionID) {
        phase = .waitingForProbe(sessionID)
    }

    mutating func acceptProbe(sessionID: SessionID) -> UInt64? {
        guard case .waitingForProbe(let expected) = phase,
              expected == sessionID else { return nil }
        nextToken &+= 1
        phase = .waitingForCommit(sessionID, nextToken)
        return nextToken
    }

    mutating func commit(sessionID: SessionID) -> Bool {
        guard case .waitingForCommit(let expected, _) = phase,
              expected == sessionID else { return false }
        phase = .committed
        return true
    }

    mutating func timeout(sessionID: SessionID, token: UInt64) -> Bool {
        guard case .waitingForCommit(let expected, let current) = phase,
              expected == sessionID,
              current == token else { return false }
        nextToken &+= 1
        phase = .waitingForFallbackCommit(sessionID, nextToken)
        return true
    }

    var fallbackToken: UInt64? {
        guard case .waitingForFallbackCommit(_, let token) = phase
        else { return nil }
        return token
    }

    mutating func commitLegacyFallback(sessionID: SessionID) -> Bool {
        guard case .waitingForFallbackCommit(let expected, _) = phase,
              expected == sessionID else { return false }
        phase = .committed
        return true
    }

    mutating func fallbackTimeout(
        sessionID: SessionID,
        token: UInt64
    ) -> Bool {
        guard case .waitingForFallbackCommit(
            let expected,
            let current) = phase,
            expected == sessionID,
            current == token else { return false }
        phase = .aborted
        return true
    }

    mutating func abort() {
        phase = .aborted
    }

    mutating func reset() {
        phase = .idle
    }
}

final class WifiMediaReceiver {
    typealias Decoder = WifiAuthenticatedMediaProcessor.Decoder
    typealias FramePacketObserver = (
        UInt64, UInt32, Bool, Bool, Int, TimeInterval
    ) -> Void
    typealias TimedOutcomeObserver = (
        UInt64, HevcReassemblyOutcome, TimeInterval
    ) -> Void
    typealias AudioConsumer = (
        Data, UInt16, UInt32, UInt64
    ) -> Void

    private let networkQueue: DispatchQueue
    private let decoder: Decoder
    private let audioConsumer: AudioConsumer
    private let onProbeAuthenticated: (UInt64, SessionID) -> Void
    private let onCommittedFailure: (UInt64, Error) -> Void
    private let securityDropObserver: ((WifiSecurityDropCounters) -> Void)?
    private let telemetryProvider: () -> WifiFeedbackTelemetry
    private let framePacketObserver: FramePacketObserver?
    private let timedOutcomeObserver: TimedOutcomeObserver?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var provisionalConnections: [ObjectIdentifier: NWConnection] = [:]
    private var candidateGate = WifiProbeCandidateGate<ObjectIdentifier>()
    private var listenerGeneration: UInt64?
    private var activeGeneration: UInt64?
    private var sessionID: SessionID?
    private var probeRequestSrtp: SrtpSession?
    private var probeAcknowledgementSrtp: SrtpSession?
    private var feedbackSrtp: SrtpSession?
    private var mediaSrtp: SrtpSession?
    private var audioSrtp: SrtpSession?
    private var inputSrtp: SrtpSession?
    private var mediaProcessor: WifiAuthenticatedMediaProcessor?
    private var endpointCommitted = false
    private var expectedHostPort: UInt16?
    private var startCompletionDelivered = false
    private var feedbackTimer: DispatchSourceTimer?
    private var feedbackWindow = WifiFeedbackWindow()
    private var feedbackSequence: UInt16 = 1
    private var lastCompletedFrame: UInt32 = 0
    private var hasCompletedFrame = false
    private var expiredFrames: UInt16 = 0
    private var lastTransit90k: Double?
    private var jitter90k: Double = 0
    private var lastFrameTimestamp: UInt32?
    private var frameIntervalMs: Double = 1000.0 / 120.0
    private var dependencyBreakActive = false
    private var recoveryCompletedPending = false
    private var recoveryEpisode: UInt32 = 0
    private var recoveryFloorFrame: UInt32 = 0
    private var recoveryFloorSet = false
    private var pendingRecoveryIdr: (
        sequence: UInt32,
        episode: UInt32
    )?
    private var nextRttToken: UInt32 = 1
    private var pendingRtt: [UInt32: UInt64] = [:]
    private var rttSamplesMs: [UInt16] = []
    private var smoothedRttMs: Double?
    private(set) var securityDropCounters = WifiSecurityDropCounters()
    private lazy var inputWriter = WifiLatestInputWriter(
        queue: networkQueue,
        packetBuilder: { [weak self] touch, sequence in
            guard let self,
                  let inputSrtp = self.inputSrtp,
                  let sessionID = self.sessionID,
                  var packet = WifiInputRtpCodec.packet(
                    touch: touch,
                    sequence: sequence,
                    ssrc: WifiMediaContract.inputSsrc(sessionID)) else {
                throw WifiMediaReceiverError.invalidOffer
            }
            let length = try inputSrtp.protectRtp(
                &packet,
                plaintextLength: WifiInputRtpCodec.plaintextLength)
            return Data(packet.prefix(length))
        },
        sender: { [weak self] packet, completion in
            guard let connection = self?.connection else {
                completion(WifiMediaReceiverError.invalidOffer)
                return
            }
            connection.send(
                content: packet,
                completion: .contentProcessed { error in
                    completion(error)
                })
        },
        onFailure: { [weak self] generation, error in
            self?.onCommittedFailure(generation, error)
        })

    init(
        networkQueue: DispatchQueue,
        decoder: @escaping Decoder,
        audioConsumer: @escaping AudioConsumer,
        onProbeAuthenticated: @escaping (UInt64, SessionID) -> Void,
        onCommittedFailure: @escaping (UInt64, Error) -> Void,
        framePacketObserver: FramePacketObserver? = nil,
        timedOutcomeObserver: TimedOutcomeObserver? = nil,
        securityDropObserver: ((WifiSecurityDropCounters) -> Void)? = nil,
        telemetryProvider: @escaping () -> WifiFeedbackTelemetry = {
            .zero
        }
    ) {
        self.networkQueue = networkQueue
        self.decoder = decoder
        self.audioConsumer = audioConsumer
        self.onProbeAuthenticated = onProbeAuthenticated
        self.onCommittedFailure = onCommittedFailure
        self.securityDropObserver = securityDropObserver
        self.framePacketObserver = framePacketObserver
        self.timedOutcomeObserver = timedOutcomeObserver
        self.telemetryProvider = telemetryProvider
    }

    func start(
        generation: UInt64,
        completion: @escaping (Result<UInt16, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        cancel()
        do {
            let listener = try NWListener(using: .udp, on: .any)
            self.listener = listener
            listenerGeneration = generation
            startCompletionDelivered = false
            listener.newConnectionHandler = { [weak self] connection in
                self?.networkQueue.async {
                    self?.accept(connection, generation: generation)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                self.networkQueue.async {
                    guard self.listenerGeneration == generation else { return }
                    switch state {
                    case .ready:
                        guard !self.startCompletionDelivered else { return }
                        self.startCompletionDelivered = true
                        guard let port = listener?.port?.rawValue,
                              port != 0 else {
                            completion(.failure(
                                WifiMediaReceiverError.invalidPort))
                            return
                        }
                        completion(.success(port))
                    case .failed:
                        guard !self.startCompletionDelivered else { return }
                        self.startCompletionDelivered = true
                        completion(.failure(
                            WifiMediaReceiverError.listenerFailed))
                        self.cancel()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: networkQueue)
        } catch {
            completion(.failure(error))
        }
    }

    func configure(offer: TransportOffer, generation: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard listenerGeneration == generation,
              offer.mode == RealtimeTransportMode.wifiRTP,
              offer.hostUDPPort != 0 else { return false }
        do {
            let request = try SrtpSession(
                key: offer.feedbackKey,
                salt: offer.feedbackSalt,
                ssrc: WifiMediaContract.probeRequestSsrc(offer.sessionID))
            let acknowledgement = try SrtpSession(
                key: offer.feedbackKey,
                salt: offer.feedbackSalt,
                ssrc: WifiMediaContract.probeAcknowledgementSsrc(
                    offer.sessionID))
            let media = try SrtpSession(
                key: offer.mediaKey,
                salt: offer.mediaSalt,
                ssrc: WifiMediaContract.mediaSsrc(offer.sessionID))
            let audio = try SrtpSession(
                key: offer.mediaKey,
                salt: offer.mediaSalt,
                ssrc: WifiMediaContract.audioSsrc(offer.sessionID))
            let input = try SrtpSession(
                key: offer.mediaKey,
                salt: offer.mediaSalt,
                ssrc: WifiMediaContract.inputSsrc(offer.sessionID))
            let feedback = try SrtpSession(
                key: offer.feedbackKey,
                salt: offer.feedbackSalt,
                ssrc: WifiMediaContract.feedbackSsrc(offer.sessionID))
            sessionID = offer.sessionID
            expectedHostPort = offer.hostUDPPort
            probeRequestSrtp = request
            probeAcknowledgementSrtp = acknowledgement
            feedbackSrtp = feedback
            mediaSrtp = media
            audioSrtp = audio
            inputSrtp = input
            endpointCommitted = false
            mediaProcessor = WifiAuthenticatedMediaProcessor(
                mtu: Int(offer.mtu),
                initialSequence:
                    WifiMediaContract.initialMediaSequence(offer.sessionID),
                unprotect: { [weak self] packet in
                    guard let self, let media = self.mediaSrtp else {
                        return false
                    }
                    do {
                        let length = try media.unprotectRtp(
                            &packet,
                            protectedLength: packet.count)
                        packet.removeSubrange(length..<packet.count)
                        return true
                    } catch {
                        self.securityDropCounters.recordCryptoFailure(error)
                        return false
                    }
                },
                decoder: decoder,
                packetObserver: {
                    [weak self] sequence, timestamp, _, arrival in
                    guard let self else { return }
                    self.feedbackWindow.observe(sequence)
                    let transit = arrival * 90_000 - Double(timestamp)
                    if let previous = self.lastTransit90k {
                        self.jitter90k +=
                            (abs(transit - previous) - self.jitter90k) / 16
                    }
                    self.lastTransit90k = transit
                    if self.lastFrameTimestamp != timestamp {
                        if let previous = self.lastFrameTimestamp {
                            let delta = UInt32(
                                truncatingIfNeeded: timestamp &- previous)
                            if delta > 0 && delta < 90_000 {
                                self.frameIntervalMs =
                                    Double(delta) / 90.0
                            }
                        }
                        self.lastFrameTimestamp = timestamp
                    }
                },
                outcomeObserver: { [weak self] outcome in
                    guard let self else { return }
                    switch outcome {
                    case .completed(let accessUnit, let frameSequence, _):
                        if !self.hasCompletedFrame ||
                            Self.isNewer(frameSequence, self.lastCompletedFrame) {
                            self.lastCompletedFrame = frameSequence
                            self.hasCompletedFrame = true
                        }
                        if self.dependencyBreakActive &&
                            WifiAuthenticatedMediaProcessor.isIDR(accessUnit) &&
                            (!self.recoveryFloorSet ||
                             Self.isNewer(
                                 frameSequence,
                                 self.recoveryFloorFrame)) {
                            self.pendingRecoveryIdr = (
                                frameSequence,
                                self.recoveryEpisode)
                        }
                    case .expired:
                        self.expiredFrames &+= 1
                        self.sendFeedback(immediate: true)
                    default:
                        break
                    }
                },
                framePacketObserver: {
                    sequence, marker, isIDR, bytes, arrivalTime in
                    self.framePacketObserver?(
                        generation,
                        sequence,
                        marker,
                        isIDR,
                        bytes,
                        arrivalTime)
                },
                timedOutcomeObserver: { outcome, observedAt in
                    self.timedOutcomeObserver?(
                        generation,
                        outcome,
                        observedAt)
                })
            return true
        } catch {
            clearOffer()
            return false
        }
    }

    func activate(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard listenerGeneration == generation, endpointCommitted else { return }
        activeGeneration = generation
        if let sessionID {
            inputWriter.begin(
                generation: generation,
                initialSequence:
                    WifiMediaContract.initialInputSequence(sessionID))
        }
        startFeedbackTimer()
    }

    func enqueueInput(_ touch: Data, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeGeneration == generation else { return }
        inputWriter.enqueue(touch, generation: generation)
    }

    func requestImmediateRecoveryFeedback(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeGeneration == generation else { return }
        guard !dependencyBreakActive else {
            if pendingRecoveryIdr != nil {
                beginRecoveryEpisode()
                return
            }
            sendFeedback(immediate: true)
            return
        }
        beginRecoveryEpisode()
    }

    func decoderDidComplete(
        sequence: UInt32,
        generation: UInt64,
        succeeded: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeGeneration == generation,
              dependencyBreakActive,
              let candidate = pendingRecoveryIdr,
              candidate.sequence == sequence,
              candidate.episode == recoveryEpisode else { return }
        pendingRecoveryIdr = nil
        guard succeeded else {
            beginRecoveryEpisode()
            return
        }
        dependencyBreakActive = false
        recoveryCompletedPending = true
        sendFeedback(immediate: true)
    }

    private func beginRecoveryEpisode() {
        recoveryCompletedPending = false
        recoveryEpisode &+= 1
        if recoveryEpisode == 0 { recoveryEpisode = 1 }
        recoveryFloorFrame = lastCompletedFrame
        recoveryFloorSet = hasCompletedFrame
        pendingRecoveryIdr = nil
        dependencyBreakActive = true
        sendFeedback(immediate: true)
    }

    func clearOffer() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        inputWriter.cancel()
        connection?.cancel()
        connection = nil
        activeGeneration = nil
        sessionID = nil
        probeRequestSrtp = nil
        probeAcknowledgementSrtp = nil
        feedbackSrtp = nil
        mediaSrtp = nil
        audioSrtp = nil
        inputSrtp = nil
        mediaProcessor = nil
        feedbackTimer?.cancel()
        feedbackTimer = nil
        feedbackWindow = WifiFeedbackWindow()
        feedbackSequence = 1
        lastCompletedFrame = 0
        hasCompletedFrame = false
        expiredFrames = 0
        lastTransit90k = nil
        jitter90k = 0
        lastFrameTimestamp = nil
        frameIntervalMs = 1000.0 / 120.0
        dependencyBreakActive = false
        recoveryCompletedPending = false
        recoveryEpisode = 0
        recoveryFloorFrame = 0
        recoveryFloorSet = false
        pendingRecoveryIdr = nil
        nextRttToken = 1
        pendingRtt.removeAll(keepingCapacity: false)
        rttSamplesMs.removeAll(keepingCapacity: false)
        smoothedRttMs = nil
        securityDropCounters = WifiSecurityDropCounters()
        endpointCommitted = false
        expectedHostPort = nil
        provisionalConnections.values.forEach { $0.cancel() }
        provisionalConnections.removeAll()
        candidateGate.reset()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        listener?.cancel()
        listener = nil
        listenerGeneration = nil
        clearOffer()
    }

    private func accept(_ candidate: NWConnection, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard listenerGeneration == generation,
              let expectedHostPort,
              case .hostPort(_, let port) = candidate.endpoint,
              port.rawValue == expectedHostPort else {
            securityDropCounters.recordWrongEndpoint()
            candidate.cancel()
            return
        }
        let source = ObjectIdentifier(candidate)
        let registration = candidateGate.register(source)
        guard registration.accepted else {
            candidate.cancel()
            return
        }
        if let evicted = registration.evicted {
            provisionalConnections.removeValue(forKey: evicted)?.cancel()
        }
        provisionalConnections[source] = candidate
        candidate.stateUpdateHandler = { _ in }
        candidate.start(queue: networkQueue)
        receive(on: candidate, generation: generation)
    }

    private func receive(on connection: NWConnection, generation: UInt64) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            self.networkQueue.async {
                guard self.listenerGeneration == generation,
                      self.connection === connection ||
                        self.provisionalConnections[
                            ObjectIdentifier(connection)] === connection
                else { return }
                if let data {
                    self.consume(data, on: connection, generation: generation)
                }
                let source = ObjectIdentifier(connection)
                let stillOwned =
                    self.connection === connection ||
                    self.provisionalConnections[source] === connection
                if error == nil && stillOwned {
                    self.receive(on: connection, generation: generation)
                } else {
                    let committedFailure =
                        error != nil &&
                        self.connection === connection &&
                        self.activeGeneration == generation
                    connection.cancel()
                    self.provisionalConnections.removeValue(
                        forKey: source)
                    self.candidateGate.reject(source)
                    if self.connection === connection {
                        self.connection = nil
                    }
                    if committedFailure, let error {
                        self.onCommittedFailure(generation, error)
                    }
                }
            }
        }
    }

    private func consume(
        _ datagram: Data,
        on connection: NWConnection,
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if !endpointCommitted {
            var packet = datagram
            let source = ObjectIdentifier(connection)
            guard provisionalConnections[source] === connection,
                  let probeRequestSrtp,
                  let probeAcknowledgementSrtp,
                  let sessionID else { return }
            do {
                let length = try probeRequestSrtp.unprotectRtp(
                    &packet,
                    protectedLength: packet.count)
                packet.removeSubrange(length..<packet.count)
                let requestSsrc =
                    WifiMediaContract.probeRequestSsrc(sessionID)
                guard WifiProbeCodec.isRequest(
                    packet,
                    sessionID: sessionID,
                    ssrc: requestSsrc) else {
                    rejectProvisional(connection)
                    return
                }
                let acknowledgementSsrc =
                    WifiMediaContract.probeAcknowledgementSsrc(sessionID)
                var acknowledgement = WifiProbeCodec.acknowledgement(
                    sessionID: sessionID,
                    ssrc: acknowledgementSsrc)
                let protectedLength = try probeAcknowledgementSrtp.protectRtp(
                    &acknowledgement,
                    plaintextLength: WifiProbeCodec.plaintextLength)
                guard let abandoned = candidateGate.authenticate(source) else {
                    rejectProvisional(connection)
                    return
                }
                for other in abandoned {
                    provisionalConnections.removeValue(forKey: other)?.cancel()
                }
                provisionalConnections.removeValue(forKey: source)
                self.connection = connection
                endpointCommitted = true
                onProbeAuthenticated(generation, sessionID)
                connection.send(
                    content: Data(acknowledgement.prefix(protectedLength)),
                    completion: .contentProcessed { _ in })
            } catch {
                securityDropCounters.recordCryptoFailure(error)
                rejectProvisional(connection)
                return
            }
            return
        }
        guard activeGeneration == generation else { return }
        if datagram.count >= 12,
           let sessionID,
           readBE32(datagram, at: 8) ==
                WifiMediaContract.probeRequestSsrc(sessionID) {
            consumeFeedbackEcho(datagram)
            return
        }
        if datagram.count >= 12,
           let sessionID,
           readBE32(datagram, at: 8) ==
                WifiMediaContract.audioSsrc(sessionID) {
            consumeAudio(datagram, generation: generation, sessionID: sessionID)
            return
        }
        mediaProcessor?.consume(datagram, arrivalTime: CACurrentMediaTime())
    }

    private func consumeAudio(
        _ datagram: Data,
        generation: UInt64,
        sessionID: SessionID
    ) {
        guard let audioSrtp else { return }
        var packet = datagram
        do {
            let length = try audioSrtp.unprotectRtp(
                &packet,
                protectedLength: packet.count)
            packet.removeSubrange(length..<packet.count)
            guard let opus = WifiOpusRtpCodec.parse(
                packet,
                expectedSsrc: WifiMediaContract.audioSsrc(sessionID))
            else { return }
            audioConsumer(
                opus.payload,
                opus.sequence,
                opus.timestamp,
                generation)
        } catch {
            securityDropCounters.recordCryptoFailure(error)
            return
        }
    }

    private func startFeedbackTimer() {
        feedbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + .milliseconds(50),
                       repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.sendFeedback(immediate: false)
        }
        timer.resume()
        feedbackTimer = timer
    }

    private func sendFeedback(immediate: Bool) {
        guard activeGeneration != nil,
              let connection,
              let feedbackSrtp,
              let sessionID else { return }
        let ssrc = WifiMediaContract.feedbackSsrc(sessionID)
        securityDropObserver?(securityDropCounters)
        let sourceTelemetry = telemetryProvider()
        let jitterMs = UInt16(clamping: Int(jitter90k / 90))
        let measuredRtt = rttP95Ms()
        let measuredSmoothedRtt = UInt16(clamping: Int(
            (smoothedRttMs ?? 0).rounded()))
        let telemetry = WifiFeedbackTelemetry(
            lastDecoded: sourceTelemetry.lastDecoded,
            lastPresented: sourceTelemetry.lastPresented,
            jitterMs: max(sourceTelemetry.jitterMs, jitterMs),
            rttP95Ms: max(sourceTelemetry.rttP95Ms, measuredRtt),
            queueAgeP95Ms: sourceTelemetry.queueAgeP95Ms,
            decodeP95Ms: sourceTelemetry.decodeP95Ms)
        let token = nextRttToken
        nextRttToken &+= 1
        let sentNanoseconds = UInt64(
            ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        if pendingRtt.count >= 64,
           let oldest = pendingRtt.min(by: { $0.value < $1.value })?.key {
            pendingRtt.removeValue(forKey: oldest)
        }
        pendingRtt[token] = sentNanoseconds
        var packet = WifiFeedbackCodec.packet(
            sequence: feedbackSequence,
            ssrc: ssrc,
            window: feedbackWindow,
            lastCompleted: lastCompletedFrame,
            telemetry: telemetry,
            smoothedRttMs: measuredSmoothedRtt,
            expiredFrames: expiredFrames,
            immediate: immediate,
            dependencyBreak: dependencyBreakActive,
            recoveryCompleted: recoveryCompletedPending,
            rttToken: token,
            rttSentNanoseconds: sentNanoseconds,
            frameIntervalMs: frameIntervalMs,
            recoveryEpisode: recoveryEpisode)
        do {
            let length = try feedbackSrtp.protectRtp(
                &packet,
                plaintextLength: WifiFeedbackCodec.plaintextLength)
            feedbackSequence &+= 1
            expiredFrames = 0
            connection.send(
                content: Data(packet.prefix(length)),
                completion: .contentProcessed { _ in })
        } catch {
            pendingRtt.removeValue(forKey: token)
            if let generation = activeGeneration {
                onCommittedFailure(generation, error)
            }
        }
    }

    private func consumeFeedbackEcho(_ datagram: Data) {
        guard let probeRequestSrtp, let sessionID else { return }
        var packet = datagram
        do {
            let length = try probeRequestSrtp.unprotectRtp(
                &packet,
                protectedLength: packet.count)
            packet.removeSubrange(length..<packet.count)
            let expectedSsrc =
                WifiMediaContract.probeRequestSsrc(sessionID)
            guard let echo = WifiFeedbackEchoCodec.parse(
                    packet,
                    expectedSsrc: expectedSsrc),
                  let sent = pendingRtt.removeValue(forKey: echo.token),
                  sent == echo.sentNanoseconds else { return }
            let now = UInt64(
                ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            guard now >= sent else { return }
            let milliseconds = UInt16(clamping: Int(
                (now - sent + 500_000) / 1_000_000))
            rttSamplesMs.append(milliseconds)
            smoothedRttMs = smoothedRttMs.map {
                $0 * 0.875 + Double(milliseconds) * 0.125
            } ?? Double(milliseconds)
            if rttSamplesMs.count > 64 {
                rttSamplesMs.removeFirst(rttSamplesMs.count - 64)
            }
        } catch {
            securityDropCounters.recordCryptoFailure(error)
            return
        }
    }

    private func rttP95Ms() -> UInt16 {
        guard !rttSamplesMs.isEmpty else { return 0 }
        let sorted = rttSamplesMs.sorted()
        let index = min(
            sorted.count - 1,
            Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    private static func isNewer(_ candidate: UInt32, _ reference: UInt32)
        -> Bool {
        let delta = candidate &- reference
        return delta != 0 && delta < 0x8000_0000
    }

    private func rejectProvisional(_ candidate: NWConnection) {
        let source = ObjectIdentifier(candidate)
        candidateGate.reject(source)
        provisionalConnections.removeValue(forKey: source)
        candidate.cancel()
    }
}
