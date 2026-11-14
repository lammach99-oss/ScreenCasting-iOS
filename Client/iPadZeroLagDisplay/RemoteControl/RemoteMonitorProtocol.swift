import Foundation

/// Controller monitor payloads. Version, reserved bytes and bounds match the C# codec.
public enum RemoteMonitorProtocol {
    public static let feature: UInt64 = 4
    static func isValidLength(type: UInt8, length: Int) -> Bool {
        switch type {
        case 68: return length == 16
        case 69: return (32...9120).contains(length)
        case 70, 71: return length == 40
        default: return false
        }
    }
    static func prefix(_ size: Int) -> Data {
        var data = Data(count: size); data[0] = 1; return data
    }
    static func validPrefix(_ data: Data, size: Int) -> Bool {
        data.count == size && data[0] == 1 && data[1..<8].allSatisfy { $0 == 0 }
    }
}

public struct RemoteMonitorCatalogueRequest: Equatable {
    public let knownRevision: UInt64
    public func encode() -> Data {
        var data = RemoteMonitorProtocol.prefix(16); data.storeLittleEndian(knownRevision, at: 8); return data
    }
    public static func decode(_ payload: Data) -> Self? {
        let data = Data(payload)
        guard RemoteMonitorProtocol.validPrefix(data, size: 16) else { return nil }
        return Self(knownRevision: data.loadLittleEndian(UInt64.self, at: 8))
    }
}

public struct RemoteMonitorEntry: Equatable {
    public let id: UInt64
    public let left: Int32, top: Int32
    public let width: UInt32, height: UInt32
    public let flags: UInt16
    public let name: String
}

public struct RemoteMonitorCatalogueCommand: Equatable {
    public let desktop: UInt8, state: UInt8
    public let epoch: UInt64, revision: UInt64, currentId: UInt64
    public let entries: [RemoteMonitorEntry]
    public func encode() -> Data? {
        guard entries.count <= 32 else { return nil }
        var data = RemoteMonitorProtocol.prefix(32); data[1] = desktop; data[2] = state
        data.storeLittleEndian(UInt16(entries.count), at: 4)
        data.storeLittleEndian(epoch, at: 8); data.storeLittleEndian(revision, at: 16)
        data.storeLittleEndian(currentId, at: 24)
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard (1...256).contains(name.count) else { return nil }
            var row = Data(count: 28); row.storeLittleEndian(entry.id, at: 0)
            row.storeLittleEndian(entry.left, at: 8); row.storeLittleEndian(entry.top, at: 12)
            row.storeLittleEndian(entry.width, at: 16); row.storeLittleEndian(entry.height, at: 20)
            row.storeLittleEndian(entry.flags, at: 24); row.storeLittleEndian(UInt16(name.count), at: 26)
            data.append(row); data.append(name)
        }
        return Self.decode(data) == nil ? nil : data
    }
    public static func decode(_ payload: Data) -> Self? {
        let data = Data(payload)
        guard (32...9120).contains(data.count), data[0] == 1,
              [UInt8(0), 1, 2, 3, 255].contains(data[1]), data[2] <= 2,
              data[3] == 0, data[6] == 0, data[7] == 0 else { return nil }
        let count = Int(data.loadLittleEndian(UInt16.self, at: 4))
        let epoch = data.loadLittleEndian(UInt64.self, at: 8)
        let revision = data.loadLittleEndian(UInt64.self, at: 16)
        let currentId = data.loadLittleEndian(UInt64.self, at: 24)
        guard count <= 32 else { return nil }
        if data[2] == 0 {
            guard count == 0, currentId == 0 else { return nil }
        } else {
            guard data[1] == 1, epoch != 0, revision != 0 else { return nil }
        }
        var entries: [RemoteMonitorEntry] = []; var ids = Set<UInt64>(); var offset = 32
        for _ in 0..<count {
            guard data.count - offset >= 28 else { return nil }
            let id = data.loadLittleEndian(UInt64.self, at: offset)
            let left = data.loadLittleEndian(Int32.self, at: offset + 8)
            let top = data.loadLittleEndian(Int32.self, at: offset + 12)
            let width = data.loadLittleEndian(UInt32.self, at: offset + 16)
            let height = data.loadLittleEndian(UInt32.self, at: offset + 20)
            let flags = data.loadLittleEndian(UInt16.self, at: offset + 24)
            let nameBytes = Int(data.loadLittleEndian(UInt16.self, at: offset + 26))
            guard id != 0, ids.insert(id).inserted, (1...32768).contains(width), (1...32768).contains(height),
                  Int64(left) + Int64(width) <= Int64(Int32.max), Int64(top) + Int64(height) <= Int64(Int32.max),
                  flags <= 1, (1...256).contains(nameBytes), data.count - offset - 28 >= nameBytes else { return nil }
            offset += 28
            guard let name = String(data: Data(data[offset..<(offset + nameBytes)]), encoding: .utf8),
                  !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            entries.append(RemoteMonitorEntry(id: id, left: left, top: top, width: width, height: height, flags: flags, name: name))
            offset += nameBytes
        }
        guard offset == data.count, currentId == 0 || ids.contains(currentId) else { return nil }
        return Self(desktop: data[1], state: data[2], epoch: epoch, revision: revision, currentId: currentId, entries: entries)
    }
}

public struct RemoteMonitorSelectCommand: Equatable {
    public let requestId: UInt64, expectedEpoch: UInt64, catalogueRevision: UInt64, targetId: UInt64
    public func encode() -> Data? {
        var data = RemoteMonitorProtocol.prefix(40)
        data.storeLittleEndian(requestId, at: 8); data.storeLittleEndian(expectedEpoch, at: 16)
        data.storeLittleEndian(catalogueRevision, at: 24); data.storeLittleEndian(targetId, at: 32)
        return Self.decode(data) == nil ? nil : data
    }
    public static func decode(_ payload: Data) -> Self? {
        let data = Data(payload)
        guard RemoteMonitorProtocol.validPrefix(data, size: 40) else { return nil }
        let value = Self(requestId: data.loadLittleEndian(UInt64.self, at: 8), expectedEpoch: data.loadLittleEndian(UInt64.self, at: 16),
            catalogueRevision: data.loadLittleEndian(UInt64.self, at: 24), targetId: data.loadLittleEndian(UInt64.self, at: 32))
        return value.requestId == 0 || value.targetId == 0 ? nil : value
    }
}

public struct RemoteMonitorSelectResultCommand: Equatable {
    public let status: UInt8
    public let requestId: UInt64, epoch: UInt64, catalogueRevision: UInt64, currentId: UInt64
    public func encode() -> Data? {
        var data = RemoteMonitorProtocol.prefix(40); data[1] = status
        data.storeLittleEndian(requestId, at: 8); data.storeLittleEndian(epoch, at: 16)
        data.storeLittleEndian(catalogueRevision, at: 24); data.storeLittleEndian(currentId, at: 32)
        return Self.decode(data) == nil ? nil : data
    }
    public static func decode(_ payload: Data) -> Self? {
        let data = Data(payload)
        guard data.count == 40, data[0] == 1, data[1] <= 5, data[2..<8].allSatisfy({ $0 == 0 }) else { return nil }
        let value = Self(status: data[1], requestId: data.loadLittleEndian(UInt64.self, at: 8), epoch: data.loadLittleEndian(UInt64.self, at: 16),
            catalogueRevision: data.loadLittleEndian(UInt64.self, at: 24), currentId: data.loadLittleEndian(UInt64.self, at: 32))
        guard value.requestId != 0, value.status != 0 || (value.epoch != 0 && value.catalogueRevision != 0 && value.currentId != 0) else { return nil }
        return value
    }
}
