import Foundation

enum TestProtocol {
    static let alpn = "sc-wan-interop-v1"
    struct Record: Equatable {
        let opcode: UInt8
        let generation: UInt64
        let sequence: UInt32
        let body: Data
    }
    enum Failure: Error { case invalid }
    static func be(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func integer(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func control(_ r: Record) throws -> Data {
        guard r.body.count <= 4080, (1...3).contains(r.opcode) else { throw Failure.invalid }
        return be(UInt64(r.body.count + 16), 4) + Data([1, r.opcode, 0, 0])
            + be(r.generation, 8) + be(UInt64(r.sequence), 4) + r.body
    }
    static func datagram(_ r: Record, channel: UInt8) throws -> Data {
        guard (1...2).contains(channel), r.body.count <= 65517 else { throw Failure.invalid }
        return Data([1, channel, 0, 0]) + be(r.generation, 8)
            + be(UInt64(r.sequence), 4) + be(UInt64(r.body.count), 2) + r.body
    }
    static func decodeDatagram(_ data: Data, generation: UInt64, channel: UInt8) throws -> Record {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 1, b[1] == channel, b[2] == 0, b[3] == 0,
              integer(b, 4, 8) == generation, integer(b, 16, 2) == b.count - 18 else { throw Failure.invalid }
        return Record(opcode: 1, generation: generation, sequence: UInt32(integer(b, 12, 4)), body: Data(b.dropFirst(18)))
    }
}