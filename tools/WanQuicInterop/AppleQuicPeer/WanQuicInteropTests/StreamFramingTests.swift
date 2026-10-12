import XCTest
@testable import WanQuicInterop
final class StreamFramingTests: XCTestCase {
    func testEverySplitAndCoalescing() throws {
        let r = TestProtocol.Record(opcode: 1, generation: 7, sequence: 0, body: Data([1,2,3]))
        let bytes = try TestProtocol.control(r)
        for i in 0...bytes.count {
            let f = ControlStreamFramer(generation: 7)
            let a = try f.feed(bytes.prefix(i)); let b = try f.feed(bytes.dropFirst(i))
            XCTAssertEqual(a + b, [r]); try f.finish()
        }
        let f = ControlStreamFramer(generation: 7)
        XCTAssertEqual(try f.feed(bytes + bytes), [r,r]); try f.finish()
    }
    func testRejectsTruncatedOversizedWrongVersionStale() throws {
        let bytes = try TestProtocol.control(.init(opcode: 1, generation: 7, sequence: 0, body: Data()))
        let f = ControlStreamFramer(generation: 7); _ = try f.feed(bytes.dropLast())
        XCTAssertThrowsError(try f.finish())
        XCTAssertThrowsError(try ControlStreamFramer(generation: 8).feed(bytes))
        var bad = bytes; bad[0] = 1
        XCTAssertThrowsError(try ControlStreamFramer(generation: 7).feed(bad))
        bad = bytes; bad[4] = 2
        XCTAssertThrowsError(try ControlStreamFramer(generation: 7).feed(bad))
    }
}