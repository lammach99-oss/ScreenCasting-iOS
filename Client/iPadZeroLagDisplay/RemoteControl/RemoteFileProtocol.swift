import Foundation

enum RemoteFileProtocol {
    enum Operation: UInt8 { case requestGrant = 1, release, requestHostFiles }
    enum Direction: UInt8 { case none, toHost, toController, both }
    enum Phase: UInt8 { case pending = 1, granted, denied, released, revoked, hostFilesReady }
    enum Reason: UInt8 { case none, policy, noControl, userDeclined, unavailable, busy, timeout, scopeLost, invalidGrant }

    enum Message {
        case control(operation: Operation, requestId: UInt64, directions: Direction, grantId: UUID)
        case state(phase: Phase, requestId: UInt64, reason: Reason, directions: Direction, grantId: UUID)
        case packet(grantId: UUID, transfer: TransferPacket)
        case window(grantId: UUID, offerId: UUID, fileIndex: UInt16, consumedOffset: UInt64,
                    maxOffset: UInt64, maxChunkIndexExclusive: UInt64)

        var type: WireMessageType {
            switch self {
            case .control: return .remoteFileControl
            case .state: return .remoteFileState
            case .packet: return .remoteFilePacket
            case .window: return .remoteFileWindow
            }
        }
    }

    static let emptyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let maxFiles = 32, defaultChunkBytes = 4096, maxChunkBytes = 8192, maxPendingChunks = 2
    static let maxFileBytes: UInt64 = 1 << 30, maxBatchBytes: UInt64 = 2 << 30
    private static let controlSize = 32, stateSize = 56, windowSize = 64
    static let packetPrefix = 20
    private static let inner = packetPrefix + 25
    private static let maxOfferBytes = inner + 10 + maxFiles * (12 + TransferProtocol.maxNameBytes)

    static func isValidLength(type: WireMessageType, length: Int) -> Bool {
        switch type {
        case .remoteFileControl: return length == controlSize
        case .remoteFileState: return length == stateSize
        case .remoteFilePacket: return (inner...maxOfferBytes).contains(length)
        case .remoteFileWindow: return length == windowSize
        default: return false
        }
    }

    static func isValidPacketLength(kind: TransferKind, length: Int) -> Bool {
        switch kind {
        case .offer: return ((inner + 23)...maxOfferBytes).contains(length)
        case .response: return length == inner + 2
        case .chunk: return length > inner + 22 && length <= inner + 22 + maxChunkBytes
        case .fileEnd: return length == inner + 42
        case .fileAck: return length == inner + 3
        case .cancel, .ack: return length == inner + 1
        case .end: return length == inner
        }
    }

    static func encode(_ message: Message) -> Data? {
        var data: Data
        switch message {
        case let .control(operation, requestId, directions, grantId):
            guard validControl(operation, requestId: requestId, directions: directions, grantId: grantId) else { return nil }
            data = Data(count: controlSize)
            data[1] = operation.rawValue
            data.storeLittleEndian(requestId, at: 4)
            data[12] = directions.rawValue
            writeID(grantId, into: &data, at: 16)
        case let .state(phase, requestId, reason, directions, grantId):
            guard validState(phase, requestId: requestId, reason: reason, directions: directions, grantId: grantId) else { return nil }
            data = Data(count: stateSize)
            data[1] = phase.rawValue
            data.storeLittleEndian(requestId, at: 4)
            data[12] = reason.rawValue
            data[13] = directions.rawValue
            writeID(grantId, into: &data, at: 16)
            if isActive(phase) {
                data.storeLittleEndian(UInt32(maxChunkBytes), at: 32)
                data.storeLittleEndian(UInt16(maxFiles), at: 36)
                data.storeLittleEndian(maxFileBytes, at: 40)
                data.storeLittleEndian(maxBatchBytes, at: 48)
            }
        case let .packet(grantId, transfer):
            guard grantId != emptyID, validTransfer(transfer),
                  let body = try? TransferProtocol.encode(transfer, nameValidator: validV1Name) else { return nil }
            data = Data(count: packetPrefix)
            data[1] = transfer.kind.rawValue
            writeID(grantId, into: &data, at: 4)
            data.append(body)
        case let .window(grantId, offerId, index, consumed, maxOffset, maxChunkIndex):
            guard validWindow(grantId: grantId, offerId: offerId, index: index, consumed: consumed,
                              maxOffset: maxOffset, maxChunkIndex: maxChunkIndex) else { return nil }
            data = Data(count: windowSize)
            writeID(grantId, into: &data, at: 4)
            writeID(offerId, into: &data, at: 20)
            data.storeLittleEndian(index, at: 36)
            data.storeLittleEndian(consumed, at: 40)
            data.storeLittleEndian(maxOffset, at: 48)
            data.storeLittleEndian(maxChunkIndex, at: 56)
        }
        data[0] = 1
        return data
    }

    static func decode(type: WireMessageType, payload: Data, flags: UInt16 = 0) -> Message? {
        guard flags == 0, isValidLength(type: type, length: payload.count) else { return nil }
        let data = Data(payload)
        guard data[0] == 1, data.loadLittleEndian(UInt16.self, at: 2) == 0 else { return nil }
        switch type {
        case .remoteFileControl:
            let requestId = data.loadLittleEndian(UInt64.self, at: 4)
            let grantId = readID(data, at: 16)
            guard let operation = Operation(rawValue: data[1]), let directions = Direction(rawValue: data[12]),
                  data[13..<16].allSatisfy({ $0 == 0 }),
                  validControl(operation, requestId: requestId, directions: directions, grantId: grantId) else { return nil }
            return .control(operation: operation, requestId: requestId, directions: directions, grantId: grantId)
        case .remoteFileState:
            let requestId = data.loadLittleEndian(UInt64.self, at: 4)
            let grantId = readID(data, at: 16)
            guard let phase = Phase(rawValue: data[1]), let reason = Reason(rawValue: data[12]),
                  let directions = Direction(rawValue: data[13]),
                  data.loadLittleEndian(UInt16.self, at: 14) == 0,
                  data.loadLittleEndian(UInt16.self, at: 38) == 0,
                  validState(phase, requestId: requestId, reason: reason, directions: directions, grantId: grantId) else { return nil }
            let active = isActive(phase)
            guard data.loadLittleEndian(UInt32.self, at: 32) == (active ? UInt32(maxChunkBytes) : 0),
                  data.loadLittleEndian(UInt16.self, at: 36) == (active ? UInt16(maxFiles) : 0),
                  data.loadLittleEndian(UInt64.self, at: 40) == (active ? maxFileBytes : 0),
                  data.loadLittleEndian(UInt64.self, at: 48) == (active ? maxBatchBytes : 0) else { return nil }
            return .state(phase: phase, requestId: requestId, reason: reason, directions: directions, grantId: grantId)
        case .remoteFilePacket:
            let grantId = readID(data, at: 4)
            guard grantId != emptyID, let kind = TransferKind(rawValue: data[1]),
                  isValidPacketLength(kind: kind, length: data.count) else { return nil }
            if kind == .offer {
                let count = Int(data.loadLittleEndian(UInt16.self, at: inner))
                guard (1...maxFiles).contains(count),
                      data.loadLittleEndian(UInt64.self, at: inner + 2) <= maxBatchBytes else { return nil }
            }
            guard let transfer = try? TransferProtocol.decode(kind, Data(data.dropFirst(packetPrefix)),
                                                               nameValidator: validV1Name),
                  validTransfer(transfer) else { return nil }
            return .packet(grantId: grantId, transfer: transfer)
        case .remoteFileWindow:
            let grantId = readID(data, at: 4), offerId = readID(data, at: 20)
            let index = data.loadLittleEndian(UInt16.self, at: 36)
            let consumed = data.loadLittleEndian(UInt64.self, at: 40)
            let maxOffset = data.loadLittleEndian(UInt64.self, at: 48)
            let maxChunkIndex = data.loadLittleEndian(UInt64.self, at: 56)
            guard data[1] == 0, data.loadLittleEndian(UInt16.self, at: 38) == 0,
                  validWindow(grantId: grantId, offerId: offerId, index: index, consumed: consumed,
                              maxOffset: maxOffset, maxChunkIndex: maxChunkIndex) else { return nil }
            return .window(grantId: grantId, offerId: offerId, fileIndex: index, consumedOffset: consumed,
                           maxOffset: maxOffset, maxChunkIndexExclusive: maxChunkIndex)
        default: return nil
        }
    }

    private static func validControl(_ operation: Operation, requestId: UInt64, directions: Direction, grantId: UUID) -> Bool {
        guard requestId != 0 else { return false }
        switch operation {
        case .requestGrant: return grantId == emptyID && directions != .none
        case .release: return grantId != emptyID && directions == .none
        case .requestHostFiles: return grantId != emptyID && directions == .toController
        }
    }

    private static func isActive(_ phase: Phase) -> Bool {
        phase == .granted || phase == .hostFilesReady
    }

    private static func validState(_ phase: Phase, requestId: UInt64, reason: Reason,
                                   directions: Direction, grantId: UUID) -> Bool {
        let active = isActive(phase)
        return (requestId == 0) == (phase == .revoked)
            && (reason != .none) == (phase == .denied || phase == .revoked)
            && (directions != .none) == active
            && (grantId != emptyID) == (active || phase == .released || phase == .revoked)
            && (phase != .hostFilesReady || directions == .toController)
    }

    private static func validWindow(grantId: UUID, offerId: UUID, index: UInt16, consumed: UInt64,
                                    maxOffset: UInt64, maxChunkIndex: UInt64) -> Bool {
        grantId != emptyID && offerId != emptyID && Int(index) < maxFiles
            && consumed <= maxOffset && maxOffset <= maxFileBytes
            && maxOffset - consumed <= UInt64(maxPendingChunks * maxChunkBytes)
            && maxChunkIndex <= maxFileBytes && (maxChunkIndex != 0 || maxOffset == 0)
    }

    static func validTransfer(_ transfer: TransferPacket) -> Bool {
        switch transfer.kind {
        case .offer:
            guard (1...maxFiles).contains(transfer.files.count) else { return false }
            var names = Set<[UInt32]>()
            var total: UInt64 = 0
            for file in transfer.files {
                guard file.length <= maxFileBytes, validV1Name(file.name) else { return false }
                let normalized = file.name.precomposedStringWithCanonicalMapping
                var stem = Array(normalized.unicodeScalars.prefix { $0.value != 0x2e })
                while stem.last?.value == 0x20 { stem.removeLast() }
                var nameStem = ""
                for scalar in stem { nameStem.unicodeScalars.append(scalar) }
                let stemKey = ordinalNameKey(nameStem)
                guard nameStem.isEmpty || (validV1Name(nameStem)
                    && !["CONIN$", "CONOUT$"].contains(where: { ordinalNameKey($0) == stemKey })),
                      names.insert(ordinalNameKey(normalized)).inserted else { return false }
                total += file.length
            }
            return total <= maxBatchBytes
        case .chunk:
            return (1...maxChunkBytes).contains(transfer.bytes.count) && transfer.chunkIndex < maxFileBytes
                && transfer.offset <= maxFileBytes && UInt64(transfer.bytes.count) <= maxFileBytes - transfer.offset
                && Int(transfer.fileIndex) < maxFiles
        case .fileEnd:
            return transfer.offset <= maxFileBytes && Int(transfer.fileIndex) < maxFiles
        case .fileAck:
            return Int(transfer.fileIndex) < maxFiles
        default:
            return true
        }
    }

    // DS5 uses the C# V1 name rules and adds normalized, ordinal name checks.
    private static func validV1Name(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard !scalars.allSatisfy({ $0.properties.isWhitespace }),
              scalars.last?.value != 0x2e, scalars.last?.value != 0x20,
              name.utf8.count <= TransferProtocol.maxNameBytes,
              !scalars.contains(where: { $0.properties.generalCategory == .control || "/\\:<>\"|?*".unicodeScalars.contains($0) }),
              !ordinalNameKey(name).starts(with: ".SCDT-".unicodeScalars.map(\.value)) else { return false }
        let stem = scalars.prefix { $0.value != 0x2e }.map { simpleUppercase($0) }
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$"].contains(where: { $0.unicodeScalars.map(\.value) == stem }) {
            return false
        }
        return stem.count != 4 || !(stem.starts(with: [67, 79, 77]) || stem.starts(with: [76, 80, 84]))
            || !"123456789\u{B9}\u{B2}\u{B3}".unicodeScalars.map(\.value).contains(stem[3])
    }

    private static func ordinalNameKey(_ name: String) -> [UInt32] {
        name.unicodeScalars.map { scalar in
            let upper = simpleUppercase(scalar)
            return scalar.value > 0x7f && upper <= 0x7f ? scalar.value : upper
        }
    }

    private static func simpleUppercase(_ scalar: Unicode.Scalar) -> UInt32 {
        // Ordinal comparison has no multi-character expansions. The Greek
        // letters with ypogegrammeni have a single-scalar titlecase mapping.
        if scalar.value == 0x0131 { return scalar.value }
        let upper = scalar.properties.uppercaseMapping.unicodeScalars
        if upper.count == 1, let mapped = upper.first { return mapped.value }
        let title = scalar.properties.titlecaseMapping.unicodeScalars
        if title.count == 1, let mapped = title.first { return mapped.value }
        return scalar.value
    }

    private static func readID(_ data: Data, at offset: Int) -> UUID {
        UUID(uuid: (data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
                    data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
                    data[offset + 8], data[offset + 9], data[offset + 10], data[offset + 11],
                    data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]))
    }

    private static func writeID(_ id: UUID, into data: inout Data, at offset: Int) {
        var bytes = id.uuid
        withUnsafeBytes(of: &bytes) { data.replaceSubrange(offset..<(offset + 16), with: $0) }
    }
}
