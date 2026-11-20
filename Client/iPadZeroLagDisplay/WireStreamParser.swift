import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

enum RealtimeAudioNegotiationPolicy {
    static func advertisedCodecs(modes: UInt8) -> UInt8 {
        let realtimeModes = RealtimeTransportMode.wifiRTP |
            RealtimeTransportMode.usbSplitTLS
        return (modes & realtimeModes) == 0
            ? AudioCodecCapabilities.pcm
            : AudioCodecCapabilities.pcm | AudioCodecCapabilities.opus
    }

    static func isOfferCompatible(
        mode: UInt8,
        audioCodec: UInt8,
        advertisedModes: UInt8,
        advertisedCodecs: UInt8
    ) -> Bool {
        let exactPair =
            (mode == RealtimeTransportMode.legacyTLS &&
             audioCodec == AudioCodecCapabilities.pcm) ||
            (mode == RealtimeTransportMode.wifiRTP &&
             (audioCodec == AudioCodecCapabilities.opus ||
              audioCodec == AudioCodecCapabilities.none)) ||
            (mode == RealtimeTransportMode.usbSplitTLS &&
             audioCodec == AudioCodecCapabilities.opus)
        return exactPair &&
            (advertisedModes & mode) != 0 &&
            (advertisedCodecs & audioCodec) != 0
    }
}

enum ScstAudioPayloadKind: Equatable {
    case legacyPCM
    case opus
    case reject
}

enum ScstAudioPolicy {
    static func classify(
        mode: UInt8?,
        flags: UInt16,
        payloadLength: Int
    ) -> ScstAudioPayloadKind {
        guard payloadLength > 0 else { return .reject }
        if mode == RealtimeTransportMode.legacyTLS {
            return flags == 0 ? .legacyPCM : .reject
        }
        if mode == RealtimeTransportMode.usbSplitTLS {
            return flags == WireProtocol.audioFlagOpus &&
                payloadLength <= WireProtocol.maximumOpusPayloadLength
                ? .opus
                : .reject
        }
        return .reject
    }
}

struct WireHeader {
    let type: WireMessageType
    let flags: UInt16
    let payloadLength: Int
    let sequence: UInt32
}

struct WireMessage {
    let header: WireHeader
    let payload: Data
    let firstByteAt: TimeInterval
}

enum WireParserError: Error, Equatable {
    case invalidHeader
    case oversizedPayload(Int)
}

enum WireParserEvent {
    case message(WireMessage)
    case discardedFixedControl(WireHeader)
    case failure(WireParserError)
}

/// Incremental SCST parser with one fixed header buffer and one exactly-sized
/// payload allocation. Each receive chunk is consumed by cursor, so bytes
/// coalesced after a message remain available for the next header.
final class WireStreamParser {
    private enum State {
        case header
        case remoteFilePrefix(WireHeader)
        case payload(WireHeader)
        case draining(WireHeader, remaining: Int)
        case failed
    }

    private var generation: UInt64
    private let allowsRemoteFiles: () -> Bool
    private let allowsSecureDesktop: () -> Bool
    private let allowsSasAvailability: () -> Bool
    private let allowsRemoteAudio: () -> Bool
    private let allowsRemoteClipboard: () -> Bool
    private var state: State = .header
    private var headerBytes = Data(count: WireProtocol.headerSize)
    private var headerOffset = 0
    private var payload = Data()
    private var payloadOffset = 0
    private var messageFirstByteAt: TimeInterval = 0
    private(set) var maximumDrainChunkObserved = 0

    init(generation: UInt64, allowsRemoteFiles: @escaping () -> Bool = { false },
         allowsSecureDesktop: @escaping () -> Bool = { false },
         allowsSasAvailability: @escaping () -> Bool = { false },
         allowsRemoteAudio: @escaping () -> Bool = { false },
         allowsRemoteClipboard: @escaping () -> Bool = { false }) {
        self.generation = generation
        self.allowsRemoteFiles = allowsRemoteFiles
        self.allowsSecureDesktop = allowsSecureDesktop
        self.allowsSasAvailability = allowsSasAvailability
        self.allowsRemoteAudio = allowsRemoteAudio
        self.allowsRemoteClipboard = allowsRemoteClipboard
    }

    var allocatedPayloadBytes: Int { payload.count }

    var suggestedReceiveLength: Int {
        switch state {
        case .header:
            return WireProtocol.receiveChunkSize
        case .remoteFilePrefix:
            return RemoteFileProtocol.packetPrefix - payloadOffset
        case .payload(let header):
            return max(1, min(
                WireProtocol.receiveChunkSize,
                header.payloadLength - payloadOffset))
        case .draining(_, let remaining):
            return max(1, min(WireProtocol.drainChunkSize, remaining))
        case .failed:
            return 1
        }
    }

    func reset(generation: UInt64) {
        self.generation = generation
        state = .header
        headerOffset = 0
        payload = Data()
        payloadOffset = 0
        messageFirstByteAt = 0
        maximumDrainChunkObserved = 0
    }

    @discardableResult func consume(
        _ data: Data,
        generation: UInt64,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        shouldContinue: () -> Bool = { true },
        onEvent: (WireParserEvent) -> Void
    ) -> Int {
        guard generation == self.generation, !data.isEmpty else { return 0 }

        return data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return 0 }
            var sourceOffset = 0

            while sourceOffset < source.count {
                guard generation == self.generation, shouldContinue() else { break }
                switch state {
                case .header:
                    if headerOffset == 0 { messageFirstByteAt = receivedAt }
                    let copied = min(
                        WireProtocol.headerSize - headerOffset,
                        source.count - sourceOffset)
                    headerBytes.withUnsafeMutableBytes { destination in
                        destination.baseAddress!
                            .advanced(by: headerOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: copied)
                    }
                    headerOffset += copied
                    sourceOffset += copied
                    if headerOffset == WireProtocol.headerSize {
                        preparePayload(onEvent: onEvent)
                    }

                case .remoteFilePrefix(let header), .payload(let header):
                    let copied = min(
                        payload.count - payloadOffset,
                        source.count - sourceOffset)
                    payload.withUnsafeMutableBytes { destination in
                        destination.baseAddress!
                            .advanced(by: payloadOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: copied)
                    }
                    payloadOffset += copied
                    sourceOffset += copied
                    if case .remoteFilePrefix = state, payloadOffset == RemoteFileProtocol.packetPrefix {
                        guard payload[0] == 1, payload[2] == 0, payload[3] == 0,
                              let kind = TransferKind(rawValue: payload[1]),
                              RemoteFileProtocol.isValidPacketLength(kind: kind, length: header.payloadLength) else {
                            state = .failed; payload = Data()
                            onEvent(.failure(.invalidHeader))
                            continue
                        }
                        payload.append(Data(count: header.payloadLength - payloadOffset))
                        state = .payload(header)
                    } else if payloadOffset == header.payloadLength {
                        let completedPayload = payload
                        let firstByteAt = messageFirstByteAt
                        resetForNextHeader()
                        onEvent(.message(WireMessage(
                            header: header,
                            payload: completedPayload,
                            firstByteAt: firstByteAt)))
                    }

                case .draining(let header, let remaining):
                    let consumed = min(
                        WireProtocol.drainChunkSize,
                        remaining,
                        source.count - sourceOffset)
                    maximumDrainChunkObserved = max(maximumDrainChunkObserved, consumed)
                    sourceOffset += consumed
                    let nextRemaining = remaining - consumed
                    if nextRemaining == 0 {
                        resetForNextHeader()
                        onEvent(.discardedFixedControl(header))
                    } else {
                        state = .draining(header, remaining: nextRemaining)
                    }

                case .failed:
                    sourceOffset = source.count
                }
            }
            return sourceOffset
        }
    }

    private func preparePayload(onEvent: (WireParserEvent) -> Void) {
        let magic = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        let version = headerBytes[4]
        guard magic == WireProtocol.magic,
              version == WireProtocol.version,
              let type = WireMessageType(rawValue: headerBytes[5]) else {
            state = .failed
            payload = Data()
            onEvent(.failure(.invalidHeader))
            return
        }

        let flags = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian
        }
        let payloadLength = Int(headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        })
        let sequence = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        guard payloadLength <= WireProtocol.maxPayloadSize else {
            state = .failed
            payload = Data()
            onEvent(.failure((84...92).contains(type.rawValue) ? .invalidHeader : .oversizedPayload(payloadLength)))
            return
        }

        let header = WireHeader(
            type: type,
            flags: flags,
            payloadLength: payloadLength,
            sequence: sequence)
        if (84...92).contains(type.rawValue) {
            guard allowsRemoteClipboard(), type != .clipboardHello, type != .clipboardControl,
                  flags == 0, RemoteClipboardProtocol.validLength(type, payloadLength) else {
                state = .failed; payload = Data()
                onEvent(.failure(.invalidHeader))
                return
            }
        } else if type == .remoteSecureDesktopState || type == .remoteSasAvailability {
            let allowed = type == .remoteSecureDesktopState ? allowsSecureDesktop() : allowsSasAvailability()
            guard allowed, flags == 0,
                  RemoteSecureDesktopProtocol.isValidLength(type: type, length: payloadLength) else {
                state = .failed; payload = Data()
                onEvent(.failure(.invalidHeader))
                return
            }
        } else if (105...107).contains(type.rawValue) {
            guard allowsRemoteAudio(), flags == 0,
                  RemoteAudioProtocol.isValidLength(type: type, length: payloadLength) else {
                state = .failed; payload = Data()
                onEvent(.failure(.invalidHeader))
                return
            }
        } else if (100...109).contains(type.rawValue) {
            guard (101...103).contains(type.rawValue), allowsRemoteFiles(), flags == 0,
                  RemoteFileProtocol.isValidLength(type: type, length: payloadLength) else {
                state = .failed; payload = Data()
                onEvent(.failure(.invalidHeader))
                return
            }
            if type == .remoteFilePacket {
                payload = Data(count: RemoteFileProtocol.packetPrefix)
                payloadOffset = 0
                state = .remoteFilePrefix(header)
                return
            }
        }
        if (93...99).contains(type.rawValue),
           flags != 0 || payloadLength != AdaptiveMediaProtocol.size(type.rawValue) {
            payload = Data(); payloadOffset = 0
            if payloadLength == 0 { resetForNextHeader(); onEvent(.discardedFixedControl(header)) }
            else { state = .draining(header, remaining: payloadLength) }
            return
        }
        // This advisory extension ignores bounded malformed traffic instead of
        // turning a security-prompt notice into a session failure.
        switch type {
        case .captureAvailabilityHello, .captureAvailability:
            if type != .captureAvailability || flags != 0 || payloadLength != 8 {
                payload = Data(); payloadOffset = 0
                if payloadLength == 0 { resetForNextHeader(); onEvent(.discardedFixedControl(header)) }
                else { state = .draining(header, remaining: payloadLength) }
                return
            }
        default: break
        }
        if (76...79).contains(type.rawValue) &&
            !ConnectionControlProtocol.validInbound(type: type.rawValue, flags: flags, length: payloadLength) {
            state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
        }
        // Monitor extensions fail closed before allocating a payload buffer.
        if (68...71).contains(type.rawValue) &&
            (flags != 0 || !RemoteMonitorProtocol.isValidLength(type: type.rawValue, length: payloadLength)) {
            state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
        }
        if (72...75).contains(type.rawValue) &&
            !CaptureTargetProtocol.validInbound(type: type.rawValue, flags: flags, length: payloadLength) {
            state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
        }
        let fixedLength: Int?
        switch type {
        case .remoteFeaturesRequest, .remoteFeaturesResult, .remoteScanKey, .remoteInputReset: fixedLength = 16
        case .remoteInputContext: fixedLength = 36
        case .remotePointer: fixedLength = 24
        case .remoteCommittedText:
            guard (20...4115).contains(payloadLength) else {
                state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
            }
            fixedLength = nil
        case .ping, .pong, .videoFeedback:
            fixedLength = 16
        case .mirrorHello: fixedLength = 8
        case .mirrorState: fixedLength = MirrorControlCodec.stateBytes
        case .mirrorAction: fixedLength = 32
        case .mirrorSwitchRequest: fixedLength = 24
        case .remoteCommand, .remoteCommandResult: fixedLength = 3
        case .sessionInfoRequest: fixedLength = 1
        case .sessionInfo:
            guard (7...71).contains(payloadLength) else {
                state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
            }
            fixedLength = nil
        case .mirrorCatalogue:
            guard (20...24576).contains(payloadLength) else {
                state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
            }
            fixedLength = nil
        case .mirrorInput:
            guard (48...4147).contains(payloadLength) else {
                state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
            }
            fixedLength = nil
        case .displayCapabilities:
            fixedLength = DisplayCapabilities.encodedSize
        case .displayConfigurationRequest:
            fixedLength = 20
        case .displayReady:
            fixedLength = 24
        case .displayConfigurationFailed:
            fixedLength = 8
        case .trustedDeviceChallenge:
            fixedLength = 112
        case .trustedDeviceProof:
            fixedLength = 48
        case .pairingSuccess:
            fixedLength = 80
        case .sessionResumeResult:
            fixedLength = 17
        case .settingsGet, .settingsState, .settingsUpdate,
             .settingsApplied, .settingsRejected:
            fixedLength = 24
        case .forgetDevice:
            fixedLength = 17
        case .forgetDeviceResult:
            fixedLength = 2
        case .presentationActivity, .pipelineMode:
            fixedLength = 1
        case .keyboardInput:
            fixedLength = KeyboardInputCommand.encodedSize
        case .clientPerformanceFeedback:
            fixedLength = 24
        case .remoteDirectTouch, .iPadPointerV2:
            fixedLength = 24
        case .directTouchContact:
            fixedLength = DirectTouchContactCommand.encodedSize
        case .cursorOwnership:
            fixedLength = CursorOwnershipCommand.encodedSize
        case .pointerInput:
            fixedLength = PointerInputCommand.encodedSize
        case .clientCapabilities:
            fixedLength = ClientCapabilities.encodedSize
        case .transportOffer:
            fixedLength = TransportOffer.encodedSize
        case .transportReady:
            fixedLength = TransportReady.encodedSize
        case .transportCommit:
            fixedLength = TransportCommit.encodedSize
        case .usbLaneBind:
            fixedLength = 60
        case .usbLaneBindResult:
            fixedLength = 28
        default:
            fixedLength = nil
        }

        if let fixedLength, payloadLength != fixedLength {
            if (61...67).contains(type.rawValue) {
                state = .failed; payload = Data(); onEvent(.failure(.invalidHeader)); return
            }
            payload = Data()
            payloadOffset = 0
            if payloadLength == 0 {
                resetForNextHeader()
                onEvent(.discardedFixedControl(header))
            } else {
                state = .draining(header, remaining: payloadLength)
            }
            return
        }

        if payloadLength == 0 {
            let firstByteAt = messageFirstByteAt
            resetForNextHeader()
            onEvent(.message(WireMessage(
                header: header,
                payload: Data(),
                firstByteAt: firstByteAt)))
            return
        }

        if TransferKind(rawValue: type.rawValue) != nil && (payloadLength < 25 || payloadLength > TransferProtocol.maxPayloadBytes) {
            state = .draining(header, remaining: payloadLength)
            return
        }
        payload = Data(count: payloadLength)
        payloadOffset = 0
        state = .payload(header)
    }

    private func resetForNextHeader() {
        state = .header
        headerOffset = 0
        payload = Data()
        payloadOffset = 0
        messageFirstByteAt = 0
    }
}

/// Enforces the single executor used by production receive/reset operations.
/// Tests use the same seam to race caller threads while parser mutation remains
/// serialized on the supplied network queue.
final class WireParserQueueDomain {
    private let queue: DispatchQueue
    private let parser: WireStreamParser

    init(generation: UInt64, queue: DispatchQueue, allowsRemoteFiles: @escaping () -> Bool = { false },
         allowsSecureDesktop: @escaping () -> Bool = { false },
         allowsSasAvailability: @escaping () -> Bool = { false },
         allowsRemoteAudio: @escaping () -> Bool = { false },
         allowsRemoteClipboard: @escaping () -> Bool = { false }) {
        self.queue = queue
        parser = WireStreamParser(generation: generation, allowsRemoteFiles: allowsRemoteFiles,
                                  allowsSecureDesktop: allowsSecureDesktop, allowsSasAvailability: allowsSasAvailability,
                                  allowsRemoteAudio: allowsRemoteAudio, allowsRemoteClipboard: allowsRemoteClipboard)
    }

    var suggestedReceiveLength: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.suggestedReceiveLength
    }

    var allocatedPayloadBytes: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.allocatedPayloadBytes
    }

    var maximumDrainChunkObserved: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.maximumDrainChunkObserved
    }

    func reset(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        parser.reset(generation: generation)
    }

    @discardableResult func consume(
        _ data: Data,
        generation: UInt64,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        shouldContinue: () -> Bool = { true },
        onEvent: (WireParserEvent) -> Void
    ) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.consume(data, generation: generation, receivedAt: receivedAt,
                              shouldContinue: shouldContinue, onEvent: onEvent)
    }
}
