import Foundation

enum TransferKind: UInt8, CaseIterable { case offer = 43, response, chunk, fileEnd, fileAck, cancel, end, ack }
enum TransferReason: UInt8 { case ok, userRejected, busy, invalidMetadata, unsupportedVersion, insufficientStorage, destinationUnavailable, sessionRetired, policyRejected, lengthMismatch, hashMismatch, writeFailed, invalidOffset, invalidChunk, cancelled }
struct TransferFile: Equatable { let name: String; let length: UInt64 }
struct TransferPacket {
    let kind: TransferKind
    let generation: UInt64
    let id: UUID
    var files: [TransferFile] = []
    var fileIndex: UInt16 = 0
    var chunkIndex: UInt64 = 0
    var offset: UInt64 = 0
    var bytes = Data()
    var accepted = false
    var reason: TransferReason = .ok
}
enum TransferProtocol {
    static let defaultChunkBytes = 16 * 1024, maxChunkBytes = 64 * 1024
    static let maxFiles = 256, maxNameBytes = 255, maxPendingBulkChunks = 2
    static let maxFileBytes: UInt64 = 1 << 40, maxTotalBytes: UInt64 = 2 << 40
    static let maxPayloadBytes = 25 + 10 + 256 * (2 + 2 + 255 + 8)
    enum Failure: Error { case invalid }
    static func validName(_ name: String) -> Bool {
        guard !name.lowercased().hasPrefix(".scdt-") else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.hasSuffix("."), !name.hasSuffix(" "), name.utf8.count <= maxNameBytes,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\:<>\"|?*".unicodeScalars.contains($0) }) else { return false }
        let stem = String(name.split(separator: ".", omittingEmptySubsequences: false)[0]).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$"].contains(stem) { return false }
        if stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && "123456789¹²³".contains(stem.last!) { return false }
        return true
    }
    static func validate(_ files: [TransferFile]) throws -> UInt64 {
        guard (1...maxFiles).contains(files.count) else { throw Failure.invalid }
        var total: UInt64 = 0
        for file in files {
            guard validName(file.name), file.length <= maxFileBytes, file.length <= maxTotalBytes - total else { throw Failure.invalid }
            total += file.length
        }
        return total
    }
    static func encode(_ packet: TransferPacket) throws -> Data {
        guard packet.generation != 0, packet.id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw Failure.invalid }
        var w = Writer(); w.put(UInt8(1)); w.put(packet.generation)
        var uuid = packet.id.uuid; withUnsafeBytes(of: &uuid) { w.data.append(contentsOf: $0) }
        switch packet.kind {
        case .offer:
            let total = try validate(packet.files); w.put(UInt16(packet.files.count)); w.put(total)
            for (index,file) in packet.files.enumerated() { let name = Data(file.name.utf8); w.put(UInt16(index)); w.put(UInt16(name.count)); w.data.append(name); w.put(file.length) }
        case .response:
            guard packet.accepted == (packet.reason == .ok) else { throw Failure.invalid }
            w.put(UInt8(packet.accepted ? 1 : 0)); w.put(packet.reason.rawValue)
        case .chunk:
            guard packet.fileIndex < maxFiles, !packet.bytes.isEmpty, packet.bytes.count <= maxChunkBytes, packet.offset <= maxFileBytes, UInt64(packet.bytes.count) <= maxFileBytes - packet.offset else { throw Failure.invalid }
            w.put(packet.fileIndex); w.put(packet.chunkIndex); w.put(packet.offset); w.put(UInt32(packet.bytes.count)); w.data.append(packet.bytes)
        case .fileEnd:
            guard packet.fileIndex < maxFiles, packet.offset <= maxFileBytes, packet.bytes.count == 32 else { throw Failure.invalid }
            w.put(packet.fileIndex); w.put(packet.offset); w.data.append(packet.bytes)
        case .fileAck:
            guard packet.fileIndex < maxFiles else { throw Failure.invalid }; w.put(packet.fileIndex); w.put(packet.reason.rawValue)
        case .cancel, .ack: w.put(packet.reason.rawValue)
        case .end: break
        }
        return w.data
    }
    static func decode(_ kind: TransferKind, _ data: Data) throws -> TransferPacket {
        guard data.count >= 25, data.count <= maxPayloadBytes else { throw Failure.invalid }
        var r = Reader(data: data)
        guard try r.u8() == 1 else { throw Failure.invalid }
        let generation = try r.u64(), uuidBytes = try r.take(16)
        let hex = uuidBytes.map { String(format: "%02x", $0) }.joined()
        let formatted = String(hex.prefix(8))+"-"+String(hex.dropFirst(8).prefix(4))+"-"+String(hex.dropFirst(12).prefix(4))+"-"+String(hex.dropFirst(16).prefix(4))+"-"+String(hex.suffix(12))
        guard generation != 0, let id = UUID(uuidString: formatted), id.uuidString != "00000000-0000-0000-0000-000000000000" else { throw Failure.invalid }
        var p = TransferPacket(kind: kind, generation: generation, id: id)
        switch kind {
        case .offer:
            let count = Int(try r.u16()), total = try r.u64()
            guard (1...maxFiles).contains(count), total <= maxTotalBytes else { throw Failure.invalid }
            for index in 0..<count {
                guard try r.u16() == index else { throw Failure.invalid }
                let length = Int(try r.u16()); guard (1...maxNameBytes).contains(length), let name = String(data: try r.take(length), encoding: .utf8) else { throw Failure.invalid }
                p.files.append(TransferFile(name: name,length: try r.u64()))
            }
            guard try validate(p.files) == total else { throw Failure.invalid }
        case .response:
            let accepted = try r.u8(); guard accepted <= 1 else { throw Failure.invalid }
            p.accepted = accepted == 1; p.reason = try r.reason()
            guard p.accepted == (p.reason == .ok) else { throw Failure.invalid }
        case .chunk:
            p.fileIndex = try r.u16(); p.chunkIndex = try r.u64(); p.offset = try r.u64(); let length = Int(try r.u32())
            guard p.fileIndex < maxFiles, (1...maxChunkBytes).contains(length), p.offset <= maxFileBytes, UInt64(length) <= maxFileBytes - p.offset else { throw Failure.invalid }
            p.bytes = try r.take(length)
        case .fileEnd:
            p.fileIndex = try r.u16(); p.offset = try r.u64(); p.bytes = try r.take(32)
            guard p.fileIndex < maxFiles, p.offset <= maxFileBytes else { throw Failure.invalid }
        case .fileAck:
            p.fileIndex = try r.u16(); p.reason = try r.reason(); guard p.fileIndex < maxFiles else { throw Failure.invalid }
        case .cancel, .ack: p.reason = try r.reason()
        case .end: break
        }
        guard r.offset == data.count else { throw Failure.invalid }
        return p
    }
    private struct Writer {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    }
    private struct Reader {
        let data: Data; var offset = 0
        mutating func take(_ count: Int) throws -> Data { guard count >= 0, count <= data.count - offset else { throw Failure.invalid }; defer { offset += count }; return data.subdata(in: offset..<offset+count) }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u16() throws -> UInt16 { let bytes = try take(2); return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        mutating func u32() throws -> UInt32 { let bytes = try take(4); return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        mutating func u64() throws -> UInt64 { let bytes = try take(8); return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian } }
        mutating func reason() throws -> TransferReason { guard let reason = TransferReason(rawValue: try u8()) else { throw Failure.invalid }; return reason }
    }
}
