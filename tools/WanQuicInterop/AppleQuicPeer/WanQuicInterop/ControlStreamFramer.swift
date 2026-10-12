import Foundation

final class ControlStreamFramer {
    let generation: UInt64
    private var pending = [UInt8]()
    init(generation: UInt64) { self.generation = generation }
    func feed(_ data: Data) throws -> [TestProtocol.Record] {
        var records = [TestProtocol.Record]()
        for byte in data {
            pending.append(byte)
            guard pending.count >= 4 else { continue }
            let count = Int(TestProtocol.integer(pending, 0, 4))
            guard (16...4096).contains(count) else { throw TestProtocol.Failure.invalid }
            guard pending.count == count + 4 else { continue }
            let p = Array(pending.dropFirst(4))
            guard p[0] == 1, (1...3).contains(p[1]), p[2] == 0, p[3] == 0,
                  TestProtocol.integer(p, 4, 8) == generation else { throw TestProtocol.Failure.invalid }
            records.append(.init(opcode: p[1], generation: generation,
                sequence: UInt32(TestProtocol.integer(p, 12, 4)), body: Data(p.dropFirst(16))))
            pending.removeAll(keepingCapacity: true)
        }
        return records
    }
    func finish() throws { guard pending.isEmpty else { throw TestProtocol.Failure.invalid } }
}