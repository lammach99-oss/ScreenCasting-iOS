import Foundation

enum RemoteClipboardProtocol {
    static let preferenceKey = "ScreenCasting.client.remoteClipboardEnabled"
    static let automaticPreferenceKey = "ScreenCasting.client.automaticClipboardSending"
    static let castingCapability: UInt16 = 0x1000
    static let marker: UInt16 = 0x4800
    static let clipboardFeature: UInt64 = 0x40
    static let foregroundFeature: UInt64 = 0x1000
    static let features = clipboardFeature | foregroundFeature
    static let maxBytes = 10_000_000
    static let maxChunk = 16_384
    static let emptyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    enum Format: UInt8 { case text = 1, png }
    enum Kind: UInt8 { case disabled, pendingConsent, enabled, paused, revoked }
    enum Action: UInt8 { case request, disable, renew }
    enum Reason: UInt8 {
        case ok, denied, busy, unsupportedFormat, tooLarge, staleGrant, desktopBlocked, clipboardBusy
        case superseded, hashMismatch, invalidChunk, applyFailed, timeout, cancelled, sensitiveContent
        case hostDisallowed, viewerDisabled, controlRequired
    }

    struct State: Equatable {
        let kind: Kind
        let directions: UInt8
        let maxBytes, maxChunk: Int
        let formats: UInt8
        let nonce, token: UUID
        let epoch, requestID: UInt64
        let reason: Reason
    }

    struct Prefix: Equatable {
        let token: UUID
        let epoch: UInt64
        let update: UUID
    }

    struct Offer: Equatable {
        let prefix: Prefix
        let format: Format
        let formats: UInt8
        let length: Int
        let origin: UUID
        let counter, revision: UInt64
        let digest: Data
    }

    enum Message: Equatable {
        case hello(UInt8, Int, Int, UUID)
        case state(State)
        case control(Action, UInt8, UInt64, Bool, UUID)
        case offer(Offer)
        case response(Prefix, Bool, Reason, UInt64)
        case chunk(Prefix, UInt32, Int, Data)
        case end(Prefix, Int, Data)
        case result(Prefix, Bool, Reason, UInt64)
        case cancel(Prefix, Reason)

        var type: WireMessageType {
            switch self {
            case .hello: return .clipboardHello
            case .state: return .clipboardState
            case .control: return .clipboardControl
            case .offer: return .clipboardOffer
            case .response: return .clipboardOfferResponse
            case .chunk: return .clipboardChunk
            case .end: return .clipboardEnd
            case .result: return .clipboardResult
            case .cancel: return .clipboardCancel
            }
        }

        var prefix: Prefix? {
            switch self {
            case .offer(let offer): return offer.prefix
            case .response(let prefix, _, _, _), .chunk(let prefix, _, _, _), .end(let prefix, _, _),
                 .result(let prefix, _, _, _), .cancel(let prefix, _): return prefix
            default: return nil
            }
        }

        func encode() -> Data {
            let length: Int
            if case .chunk(_, _, _, let bytes) = self { length = 64 + bytes.count }
            else { length = RemoteClipboardProtocol.fixedLength(type) ?? 0 }
            var data = Data(count: length)
            data[0] = 2
            if let prefix {
                data.putID(prefix.token, at: 8)
                data.storeLittleEndian(prefix.epoch, at: 24)
                data.putID(prefix.update, at: 32)
            }
            switch self {
            case .hello(let formats, let bytes, let chunk, let nonce):
                data[1] = formats
                data.storeLittleEndian(UInt32(bytes), at: 4)
                data.storeLittleEndian(UInt32(chunk), at: 8)
                data.putID(nonce, at: 16)
            case .state(let state):
                data[1] = state.kind.rawValue; data[2] = state.directions; data[3] = 1
                data.storeLittleEndian(UInt32(state.maxBytes), at: 4)
                data.storeLittleEndian(UInt32(state.maxChunk), at: 8)
                data[12] = state.formats
                data.putID(state.nonce, at: 16)
                data.putID(state.token, at: 32)
                data.storeLittleEndian(state.epoch, at: 48)
                data.storeLittleEndian(state.requestID, at: 56)
                data[64] = state.reason.rawValue
            case .control(let action, let directions, let id, let active, let nonce):
                data[1] = action.rawValue; data[2] = directions; data[3] = 1
                data.storeLittleEndian(id, at: 4)
                data[12] = active ? 1 : 0
                data.putID(nonce, at: 16)
            case .offer(let offer):
                data[48] = offer.format.rawValue; data[49] = offer.formats
                data.storeLittleEndian(UInt64(offer.length), at: 56)
                data.putID(offer.origin, at: 64)
                data.storeLittleEndian(offer.counter, at: 80)
                data.storeLittleEndian(offer.revision, at: 88)
                data.replaceSubrange(96..<128, with: offer.digest)
            case .response(_, let accepted, let reason, let revision):
                data[48] = accepted ? 1 : 0; data[49] = reason.rawValue
                data.storeLittleEndian(revision, at: 56)
            case .chunk(_, let index, let offset, let bytes):
                data.storeLittleEndian(index, at: 48)
                data.storeLittleEndian(UInt32(bytes.count), at: 52)
                data.storeLittleEndian(UInt64(offset), at: 56)
                data.replaceSubrange(64..<length, with: bytes)
            case .end(_, let total, let digest):
                data.storeLittleEndian(UInt64(total), at: 48)
                data.replaceSubrange(56..<88, with: digest)
            case .result(_, let applied, let reason, let revision):
                data[48] = applied ? 0 : 1; data[49] = reason.rawValue
                data.storeLittleEndian(revision, at: 56)
            case .cancel(_, let reason): data[48] = reason.rawValue
            }
            return data
        }
    }

    private static func fixedLength(_ type: WireMessageType) -> Int? {
        switch type {
        case .clipboardHello, .clipboardControl: return 32
        case .clipboardState: return 72
        case .clipboardOffer: return 128
        case .clipboardOfferResponse, .clipboardResult: return 64
        case .clipboardEnd: return 88
        case .clipboardCancel: return 56
        default: return nil
        }
    }

    static func validLength(_ type: WireMessageType, _ length: Int) -> Bool {
        if type == .clipboardChunk { return (65...(64 + maxChunk)).contains(length) }
        return fixedLength(type) == length
    }

    static func decode(type: WireMessageType, payload: Data, flags: UInt16 = 0) -> Message? {
        guard flags == 0, validLength(type, payload.count) else { return nil }
        let data = Data(payload)
        guard data[0] == 2 else { return nil }
        func zero(_ range: Range<Int>) -> Bool { data[range].allSatisfy { $0 == 0 } }
        func u64(_ offset: Int) -> UInt64 { data.loadLittleEndian(UInt64.self, at: offset) }
        func u32(_ offset: Int) -> UInt32 { data.loadLittleEndian(UInt32.self, at: offset) }
        func limits(_ bytes: Int, _ chunk: Int) -> Bool {
            (1...maxBytes).contains(bytes) && (1...maxChunk).contains(chunk)
        }
        switch type {
        case .clipboardHello:
            let bytes = Int(u32(4)), chunk = Int(u32(8)), nonce = data.id(at: 16)
            guard (1...3).contains(data[1]), zero(2..<4), limits(bytes, chunk), zero(12..<16), nonce != emptyID else { return nil }
            return .hello(data[1], bytes, chunk, nonce)
        case .clipboardState:
            let bytes = Int(u32(4)), chunk = Int(u32(8)), nonce = data.id(at: 16), token = data.id(at: 32)
            let epoch = u64(48)
            guard let kind = Kind(rawValue: data[1]), data[2] <= 3, data[3] == 1, limits(bytes, chunk),
                  (1...3).contains(data[12]), zero(13..<16), nonce != emptyID,
                  let reason = Reason(rawValue: data[64]), zero(65..<72) else { return nil }
            if kind == .enabled {
                guard data[2] != 0, token != emptyID, epoch != 0, reason == .ok else { return nil }
            } else {
                guard token == emptyID,
                      (kind != .disabled && kind != .revoked) || data[2] == 0 else { return nil }
            }
            return .state(State(kind: kind, directions: data[2], maxBytes: bytes, maxChunk: chunk,
                                formats: data[12], nonce: nonce, token: token, epoch: epoch, requestID: u64(56), reason: reason))
        case .clipboardControl:
            let nonce = data.id(at: 16)
            guard let action = Action(rawValue: data[1]), data[2] <= 3, action == .disable || data[2] != 0,
                  data[3] == 1, u64(4) != 0, data[12] <= 1, zero(13..<16), nonce != emptyID else { return nil }
            return .control(action, data[2], u64(4), data[12] == 1, nonce)
        default: break
        }
        let prefix = Prefix(token: data.id(at: 8), epoch: u64(24), update: data.id(at: 32))
        guard zero(1..<8), prefix.token != emptyID, prefix.epoch != 0, prefix.update != emptyID else { return nil }
        switch type {
        case .clipboardOffer:
            let formats = data[49], length = u64(56), origin = data.id(at: 64), counter = u64(80)
            guard let format = Format(rawValue: data[48]), (1...3).contains(formats),
                  format == (formats & 2 != 0 ? .png : .text), zero(50..<56), length <= UInt64(maxBytes),
                  format == .text || length > 0, origin != emptyID, counter != 0 else { return nil }
            return .offer(Offer(prefix: prefix, format: format, formats: formats, length: Int(length),
                                origin: origin, counter: counter, revision: u64(88), digest: data.subdata(in: 96..<128)))
        case .clipboardOfferResponse, .clipboardResult:
            let success = data[48] == (type == .clipboardResult ? 0 : 1)
            guard data[48] <= 1, let reason = Reason(rawValue: data[49]), success == (reason == .ok), zero(50..<56) else { return nil }
            return type == .clipboardResult ? .result(prefix, success, reason, u64(56)) : .response(prefix, success, reason, u64(56))
        case .clipboardChunk:
            let index = u32(48), count = u32(52), offset = u64(56)
            guard count == data.count - 64, index <= maxBytes,
                  offset <= UInt64(maxBytes), UInt64(count) <= UInt64(maxBytes) - offset else { return nil }
            return .chunk(prefix, index, Int(offset), data.subdata(in: 64..<data.count))
        case .clipboardEnd:
            let total = u64(48)
            guard total <= UInt64(maxBytes) else { return nil }
            return .end(prefix, Int(total), data.subdata(in: 56..<88))
        case .clipboardCancel:
            guard let reason = Reason(rawValue: data[48]), reason != .ok, zero(49..<56) else { return nil }
            return .cancel(prefix, reason)
        default: return nil
        }
    }

    static func canonicalText(_ bytes: Data, fromWire: Bool) -> Data? {
        guard bytes.count <= (fromWire ? maxBytes : 2 * maxBytes),
              !bytes.starts(with: [0xef, 0xbb, 0xbf]), !bytes.contains(0),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        let canonical = fromWire ? bytes : Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
        return canonical.count <= maxBytes && !canonical.contains(13) ? canonical : nil
    }
}

private extension Data {
    mutating func putID(_ id: UUID, at offset: Int) {
        var bytes = id.uuid
        Swift.withUnsafeBytes(of: &bytes) { replaceSubrange(offset..<(offset + 16), with: $0) }
    }

    func id(at offset: Int) -> UUID {
        let bytes = Array(self[offset..<(offset + 16)])
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
