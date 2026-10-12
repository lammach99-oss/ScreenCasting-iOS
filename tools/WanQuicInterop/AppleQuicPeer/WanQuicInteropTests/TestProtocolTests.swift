import XCTest
@testable import WanQuicInterop
final class TestProtocolTests: XCTestCase {
    func testDatagramExactLengthAndIdentity() throws {
        let r = TestProtocol.Record(opcode: 1, generation: 7, sequence: 42, body: Data([1,2,3]))
        let bytes = try TestProtocol.datagram(r, channel: 2)
        XCTAssertEqual(bytes.count, 21)
        XCTAssertEqual(try TestProtocol.decodeDatagram(bytes, generation: 7, channel: 2), r)
        XCTAssertThrowsError(try TestProtocol.decodeDatagram(bytes.dropLast(), generation: 7, channel: 2))
        XCTAssertThrowsError(try TestProtocol.decodeDatagram(bytes, generation: 8, channel: 2))
        XCTAssertThrowsError(try TestProtocol.decodeDatagram(bytes, generation: 7, channel: 1))
        var bad = bytes; bad[3] = 1
        XCTAssertThrowsError(try TestProtocol.decodeDatagram(bad, generation: 7, channel: 2))
    }
    func testControlBound() throws {
        XCTAssertThrowsError(try TestProtocol.control(.init(opcode: 1, generation: 7, sequence: 0, body: Data(count: 4081))))
    }
}