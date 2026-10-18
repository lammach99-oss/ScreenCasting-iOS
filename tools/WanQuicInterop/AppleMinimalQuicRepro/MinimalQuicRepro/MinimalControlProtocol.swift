import Foundation

// Copied wire constants only from tools/WanQuicInterop/PROTOCOL.md, not runtime code.
enum MinimalControlProtocol {
    static let alpn = "sc-wan-interop-v1"
    enum Invalid: Error { case record }
    static func be(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func integer(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func request(generation: UInt64) -> Data {
        be(17, count: 4) + Data([1, 1, 0, 0]) + be(generation, count: 8)
            + be(0, count: 4) + Data([0x5a])
    }
    struct ReplyDecoder {
        let generation: UInt64
        private(set) var buffer = Data()
        private(set) var received = false
        mutating func feed(_ data: Data) throws -> Bool {
            guard !received || data.isEmpty, buffer.count + data.count <= 4100 else { throw Invalid.record }
            buffer.append(data)
            guard buffer.count >= 4 else { return false }
            let bytes = [UInt8](buffer)
            let length = Int(integer(bytes, 0, 4))
            guard length == 17 else { throw Invalid.record }
            guard buffer.count >= length + 4 else { return false }
            guard buffer.count == 21, bytes[4...7].elementsEqual([1, 2, 0, 0]),
                  integer(bytes, 8, 8) == generation, integer(bytes, 16, 4) == 0,
                  bytes[20] == 0x5a else { throw Invalid.record }
            received = true
            buffer.removeAll(keepingCapacity: false)
            return true
        }
        func finish() throws {
            guard received && buffer.isEmpty else { throw Invalid.record }
        }
    }
}

struct MinimalIdentity: Equatable {
    let runID = UUID()
    let groupID = UUID()
    let controlID = UUID()
    let generation: UInt64
}

struct MinimalRunGate {
    let identity: MinimalIdentity
    private(set) var live = true
    private(set) var controlRequested = false
    func accepts(_ candidate: MinimalIdentity) -> Bool { live && candidate == identity }
    mutating func requestControl() -> Bool {
        guard live && !controlRequested else { return false }
        controlRequested = true
        return true
    }
    mutating func retire() { live = false }
}
