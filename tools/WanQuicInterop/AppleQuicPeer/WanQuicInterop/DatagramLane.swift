import Foundation
import Network

enum DatagramLane {
    static func sizes(capacity: Int) -> [Int] {
        var bodies = [1, 64, 256, 512, 1000]
        if capacity >= 19 { bodies += [capacity - 19, capacity - 18, capacity - 17] }
        return bodies.filter { (0...65517).contains($0) }
    }
    static func probe(owner: QuicConnectionOwner, send: (Data, UInt32) -> Void) throws {
        guard let lane = owner.datagrams,
              let metadata = lane.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
            throw TestProtocol.Failure.invalid
        }
        let capacity = min(metadata.usableDatagramFrameSize, lane.maximumDatagramSize)
        guard capacity >= 19 else { throw TestProtocol.Failure.invalid }
        EventLog.write("apple_capacity", generation: owner.generation, owner: owner.id, value: capacity)
        for (i, size) in sizes(capacity: capacity).enumerated() {
            let sequence = UInt32(i)
            let record = TestProtocol.Record(opcode: 1, generation: owner.generation,
                sequence: sequence, body: Data(repeating: 0x5a, count: size))
            let data = try TestProtocol.datagram(record, channel: 2)
            EventLog.write("apple_capacity_probe", generation: owner.generation,
                owner: owner.id, sequence: sequence, value: data.count)
            send(data, sequence) // a single cap+1 rejection probe, never a flood
        }
    }
}