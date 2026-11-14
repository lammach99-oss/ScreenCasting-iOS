import Foundation

/// Casting extension only. Legacy monitor messages 55/56 and remote messages 68-71 are independent.
public enum CaptureTargetProtocol {
    public static let advertisementFlag: UInt16 = 0x0400
    public static let terminalWait: TimeInterval = 65
    public static let recoveryFlag: UInt16 = 0x1000
    public static let presentationWait: TimeInterval = 5
    static func validInbound(type: UInt8, flags: UInt16, length: Int) -> Bool {
        guard flags == 0 else { return false }
        switch type {
        case 73: return (40...34228).contains(length)
        case 75: return length == 64
        default: return false
        }
    }
    public static func hello(knownRevision: UInt64 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16); bytes[0] = 1; bytes[4] = 1
        MirrorControlCodec.put(knownRevision, &bytes, 8, 8)
        return Data(bytes)
    }
}

public enum CaptureTargetKind: UInt8 { case extend = 0, physical = 1 }
public enum CaptureTargetStatus: UInt8 {
    case applied = 0, stale = 1, notAvailable = 2, denied = 3, failed = 4
    case busy = 5, administratorRequired = 6, timedOut = 7, cancelled = 8
    case accepted = 9
}
public struct CaptureTargetEntry: Equatable, Identifiable {
    public let id: UInt64
    public let kind: CaptureTargetKind
    public let name: String
}
public struct CaptureTargetCatalogue: Equatable {
    public let state: UInt8, allowed: Bool
    public let owner: UInt64, revision: UInt64, currentId: UInt64, epoch: UInt64
    public let entries: [CaptureTargetEntry]

    public static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard (40...34228).contains(bytes.count), bytes[0] == 1, bytes[1] <= 3,
              bytes[2] <= 1, bytes[3] <= 33, MirrorControlCodec.read(bytes, 4, 4) == 30000,
              MirrorControlCodec.read(bytes, 8, 8) != 0, MirrorControlCodec.read(bytes, 16, 8) != 0
        else { throw MirrorControlError.malformed }
        var offset = 40, entries: [CaptureTargetEntry] = [], ids = Set<UInt64>()
        for _ in 0..<Int(bytes[3]) {
            guard bytes.count - offset >= 12 else { throw MirrorControlError.malformed }
            let id = MirrorControlCodec.read(bytes, offset, 8)
            let length = Int(MirrorControlCodec.read(bytes, offset + 10, 2))
            guard id != 0, ids.insert(id).inserted, let kind = CaptureTargetKind(rawValue: bytes[offset + 8]),
                  bytes[offset + 9] == 0, (1...1024).contains(length), bytes.count - offset - 12 >= length
            else { throw MirrorControlError.malformed }
            offset += 12
            guard let name = String(bytes: bytes[offset..<offset + length], encoding: .utf8),
                  !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw MirrorControlError.malformed }
            entries.append(CaptureTargetEntry(id: id, kind: kind, name: name)); offset += length
        }
        let current = MirrorControlCodec.read(bytes, 24, 8)
        guard offset == bytes.count, entries.filter({ $0.kind == .extend }).count == 1,
              current == 0 || ids.contains(current),
              !(bytes[1] == 0 || bytes[1] == 3) || current == 0,
              bytes[1] != 1 || current != 0 else { throw MirrorControlError.malformed }
        return Self(state: bytes[1], allowed: bytes[2] == 1, owner: MirrorControlCodec.read(bytes, 8, 8),
                    revision: MirrorControlCodec.read(bytes, 16, 8), currentId: current,
                    epoch: MirrorControlCodec.read(bytes, 32, 8), entries: entries)
    }
}
public struct CaptureTargetRequest: Equatable {
    public let transaction: UInt64, owner: UInt64, revision: UInt64, targetId: UInt64
    public func encode() throws -> Data {
        guard transaction != 0, owner != 0, revision != 0, targetId != 0 else { throw MirrorControlError.malformed }
        var bytes = [UInt8](repeating: 0, count: 40); bytes[0] = 1
        for (offset, value) in [(8, transaction), (16, owner), (24, revision), (32, targetId)] {
            MirrorControlCodec.put(value, &bytes, offset, 8)
        }
        return Data(bytes)
    }
}
public struct CaptureTargetResult: Equatable {
    public let status: CaptureTargetStatus
    public let state: UInt8
    public let kind: CaptureTargetKind?
    public let transaction: UInt64, owner: UInt64, revision: UInt64, currentId: UInt64, epoch: UInt64, source: UInt64
    public let firstFrame: UInt32

    public func recoveryPayload() throws -> Data {
        guard status == .applied, owner != 0, epoch != 0, source != 0 else { throw MirrorControlError.denied }
        var bytes = [UInt8](repeating: 0, count: 24)
        MirrorControlCodec.put(owner, &bytes, 0, 8)
        MirrorControlCodec.put(epoch, &bytes, 8, 8)
        MirrorControlCodec.put(source, &bytes, 16, 8)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard bytes.count == 64, bytes[0] == 1, let status = CaptureTargetStatus(rawValue: bytes[1]),
              bytes[2] <= 3, bytes[3] == 255 || CaptureTargetKind(rawValue: bytes[3]) != nil,
              bytes[4..<8].allSatisfy({ $0 == 0 }), bytes[60..<64].allSatisfy({ $0 == 0 })
        else { throw MirrorControlError.malformed }
        let value = Self(status: status, state: bytes[2], kind: CaptureTargetKind(rawValue: bytes[3]),
                         transaction: MirrorControlCodec.read(bytes, 8, 8), owner: MirrorControlCodec.read(bytes, 16, 8),
                         revision: MirrorControlCodec.read(bytes, 24, 8), currentId: MirrorControlCodec.read(bytes, 32, 8),
                         epoch: MirrorControlCodec.read(bytes, 40, 8), source: MirrorControlCodec.read(bytes, 48, 8),
                         firstFrame: UInt32(MirrorControlCodec.read(bytes, 56, 4)))
        guard value.transaction != 0, value.owner != 0, value.revision != 0,
              (value.currentId == 0) == (value.kind == nil),
              !(value.state == 0 || value.state == 3) || value.currentId == 0,
              status != .applied || value.state == 1 && value.currentId != 0 && value.epoch != 0 && value.source != 0,
              status != .accepted || value.state == 2 && value.currentId == 0
        else { throw MirrorControlError.malformed }
        return value
    }
}
