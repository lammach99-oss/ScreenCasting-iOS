import Foundation

enum RemoteAudioProtocol {
    enum Operation: UInt8 { case get, enable, disable }
    enum Phase: UInt8 { case off, pending, streaming, paused, denied }
    enum Reason: UInt8 { case none, policy, desktop, session, endpoint, budget, runtime, revoked }

    enum Message {
        case set(operation: Operation, requestId: UInt64)
        case state(phase: Phase, reason: Reason, requestId: UInt64, audioEpoch: UInt64, startUs: UInt64)
        case packet(audioSequence: UInt32, audioEpoch: UInt64, captureUs: UInt64, opus: Data)
        case timedVideo(videoFlags: UInt8, frameSequence: UInt32, totalBytes: UInt32, offset: UInt32,
                        captureUs: UInt64, fragment: Data)

        var type: WireMessageType {
            switch self {
            case .set: return .remoteAudioSet
            case .state: return .remoteAudioState
            case .packet: return .remoteAudioPacket
            case .timedVideo: return .remoteTimedVideo
            }
        }
    }

    static let maxOpusBytes = 120
    static let maxFragmentBytes = 16 * 1024
    static let maxAccessUnitBytes: UInt32 = 8 * 1024 * 1024
    private static let setSize = 16, stateSize = 32, mediaPrefix = 24
    private static let opusCodec: UInt8 = 1

    static func isValidLength(type: WireMessageType, length: Int) -> Bool {
        switch type {
        case .remoteAudioSet: return length == setSize
        case .remoteAudioState: return length == stateSize
        case .remoteAudioPacket: return length > mediaPrefix && length <= mediaPrefix + maxOpusBytes
        case .remoteTimedVideo: return length > mediaPrefix && length <= mediaPrefix + maxFragmentBytes
        default: return false
        }
    }

    static func encode(_ message: Message, sequence: UInt32 = 0) -> Data? {
        var data: Data
        switch message {
        case let .set(operation, requestId):
            guard requestId != 0 else { return nil }
            data = Data(count: setSize)
            data[1] = operation.rawValue
            data.storeLittleEndian(requestId, at: 8)
        case let .state(phase, reason, requestId, epoch, startUs):
            guard validState(phase: phase, reason: reason, epoch: epoch, startUs: startUs) else { return nil }
            data = Data(count: stateSize)
            data[1] = phase.rawValue
            data[2] = reason.rawValue
            data[3] = phase == .streaming ? opusCodec : 0
            data.storeLittleEndian(requestId, at: 8)
            data.storeLittleEndian(epoch, at: 16)
            data.storeLittleEndian(startUs, at: 24)
        case let .packet(audioSequence, epoch, captureUs, opus):
            guard validPacket(sequence: audioSequence, epoch: epoch, captureUs: captureUs, count: opus.count) else { return nil }
            data = Data(count: mediaPrefix)
            data.storeLittleEndian(audioSequence, at: 4)
            data.storeLittleEndian(epoch, at: 8)
            data.storeLittleEndian(captureUs, at: 16)
            data.append(opus)
        case let .timedVideo(flags, frame, total, offset, captureUs, fragment):
            guard validVideo(flags: flags, frame: frame, total: total, offset: offset, captureUs: captureUs,
                             count: fragment.count, sequence: sequence) else { return nil }
            data = Data(count: mediaPrefix)
            data[1] = flags
            data.storeLittleEndian(frame, at: 4)
            data.storeLittleEndian(total, at: 8)
            data.storeLittleEndian(offset, at: 12)
            data.storeLittleEndian(captureUs, at: 16)
            data.append(fragment)
        }
        data[0] = 1
        return data
    }

    static func decode(type: WireMessageType, payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) -> Message? {
        guard flags == 0, isValidLength(type: type, length: payload.count) else { return nil }
        let data = Data(payload)
        guard data[0] == 1 else { return nil }
        switch type {
        case .remoteAudioSet:
            let id = data.loadLittleEndian(UInt64.self, at: 8)
            guard let operation = Operation(rawValue: data[1]), id != 0,
                  data[2..<8].allSatisfy({ $0 == 0 }) else { return nil }
            return .set(operation: operation, requestId: id)
        case .remoteAudioState:
            let epoch = data.loadLittleEndian(UInt64.self, at: 16)
            let startUs = data.loadLittleEndian(UInt64.self, at: 24)
            guard let phase = Phase(rawValue: data[1]), let reason = Reason(rawValue: data[2]),
                  data[3] == (phase == .streaming ? opusCodec : 0),
                  data.loadLittleEndian(UInt32.self, at: 4) == 0,
                  validState(phase: phase, reason: reason, epoch: epoch, startUs: startUs) else { return nil }
            return .state(phase: phase, reason: reason, requestId: data.loadLittleEndian(UInt64.self, at: 8),
                          audioEpoch: epoch, startUs: startUs)
        case .remoteAudioPacket:
            let audioSequence = data.loadLittleEndian(UInt32.self, at: 4)
            let epoch = data.loadLittleEndian(UInt64.self, at: 8)
            let captureUs = data.loadLittleEndian(UInt64.self, at: 16)
            guard data[1..<4].allSatisfy({ $0 == 0 }),
                  validPacket(sequence: audioSequence, epoch: epoch, captureUs: captureUs,
                              count: data.count - mediaPrefix) else { return nil }
            return .packet(audioSequence: audioSequence, audioEpoch: epoch, captureUs: captureUs,
                           opus: Data(data.dropFirst(mediaPrefix)))
        case .remoteTimedVideo:
            let frame = data.loadLittleEndian(UInt32.self, at: 4)
            let total = data.loadLittleEndian(UInt32.self, at: 8)
            let offset = data.loadLittleEndian(UInt32.self, at: 12)
            let captureUs = data.loadLittleEndian(UInt64.self, at: 16)
            guard data.loadLittleEndian(UInt16.self, at: 2) == 0,
                  validVideo(flags: data[1], frame: frame, total: total, offset: offset,
                             captureUs: captureUs, count: data.count - mediaPrefix, sequence: sequence) else { return nil }
            return .timedVideo(videoFlags: data[1], frameSequence: frame, totalBytes: total, offset: offset,
                               captureUs: captureUs, fragment: Data(data.dropFirst(mediaPrefix)))
        default: return nil
        }
    }

    private static func validState(phase: Phase, reason: Reason, epoch: UInt64, startUs: UInt64) -> Bool {
        guard (reason != .none) == (phase == .paused || phase == .denied) else { return false }
        return phase == .streaming ? epoch != 0 && startUs != 0 : epoch == 0 && startUs == 0
    }

    private static func validPacket(sequence: UInt32, epoch: UInt64, captureUs: UInt64, count: Int) -> Bool {
        sequence != 0 && epoch != 0 && captureUs != 0 && (1...maxOpusBytes).contains(count)
    }

    private static func validVideo(flags: UInt8, frame: UInt32, total: UInt32, offset: UInt32,
                                   captureUs: UInt64, count: Int, sequence: UInt32) -> Bool {
        let lengthPrefixed = WireProtocol.videoFlagLengthPrefixed
        let idr = WireProtocol.videoFlagIDR
        return (UInt16(flags) == lengthPrefixed || UInt16(flags) == (lengthPrefixed | idr))
            && frame != 0 && sequence != 0 && ((sequence == frame) == (offset == 0))
            && captureUs != 0 && (1...maxAccessUnitBytes).contains(total) && offset < total
            && (1...maxFragmentBytes).contains(count) && UInt32(count) <= total - offset
    }
}
