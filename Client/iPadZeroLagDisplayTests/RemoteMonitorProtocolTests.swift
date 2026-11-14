import XCTest
@testable import iPadCasting

final class RemoteMonitorProtocolTests: XCTestCase {
    static let catalogueHex = "0101010001000000090000000000000003000000000000000100000000000000010000000000000080F8FFFFF6FFFFFF80070000380400000100010041"
    static let requestHex = "01000000000000000700000000000000090000000000000003000000000000000100000000000000"
    static let resultHex = "010000000000000007000000000000000A0000000000000004000000000000000100000000000000"
    static func bytes(_ hex: String) -> Data {
        var data = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<end], radix: 16)!); index = end
        }
        return data
    }
    func testSharedCSharpGoldenVectorsAndWireIDs() throws {
        let catalogue = try XCTUnwrap(RemoteMonitorCatalogueCommand.decode(Self.bytes(Self.catalogueHex)))
        XCTAssertEqual(catalogue.entries, [RemoteMonitorEntry(id: 1, left: -1920, top: -10,
            width: 1920, height: 1080, flags: 1, name: "A")])
        XCTAssertEqual(catalogue.encode(), Self.bytes(Self.catalogueHex))
        let request = RemoteMonitorSelectCommand(requestId: 7, expectedEpoch: 9, catalogueRevision: 3, targetId: 1)
        XCTAssertEqual(request.encode(), Self.bytes(Self.requestHex))
        XCTAssertEqual(RemoteMonitorSelectCommand.decode(Self.bytes(Self.requestHex)), request)
        let result = RemoteMonitorSelectResultCommand(status: 0, requestId: 7, epoch: 10, catalogueRevision: 4, currentId: 1)
        XCTAssertEqual(result.encode(), Self.bytes(Self.resultHex))
        XCTAssertEqual(RemoteMonitorSelectResultCommand.decode(Self.bytes(Self.resultHex)), result)
        XCTAssertEqual(RemoteMonitorCatalogueRequest(knownRevision: 3).encode(), Self.bytes("01000000000000000300000000000000"))
        XCTAssertEqual(WireMessageType.remoteMonitorCatalogueRequest.rawValue, 68)
        XCTAssertEqual(WireMessageType.remoteMonitorCatalogue.rawValue, 69)
        XCTAssertEqual(WireMessageType.remoteMonitorSelectRequest.rawValue, 70)
        XCTAssertEqual(WireMessageType.remoteMonitorSelectResult.rawValue, 71)
    }
    func testAllTruncationsTrailingBytesVersionAndReservedBytes() {
        let vectors: [(Data, (Data) -> Bool, [Int])] = [
            (Self.bytes("01000000000000000300000000000000"), { RemoteMonitorCatalogueRequest.decode($0) != nil }, Array(1...7)),
            (Self.bytes(Self.catalogueHex), { RemoteMonitorCatalogueCommand.decode($0) != nil }, [3, 6, 7]),
            (Self.bytes(Self.requestHex), { RemoteMonitorSelectCommand.decode($0) != nil }, Array(1...7)),
            (Self.bytes(Self.resultHex), { RemoteMonitorSelectResultCommand.decode($0) != nil }, Array(2...7))]
        for (good, decode, reserved) in vectors {
            XCTAssertTrue(decode(good))
            for length in 0..<good.count { XCTAssertFalse(decode(Data(good.prefix(length))), "length \(length)") }
            var trailing = good; trailing.append(0); XCTAssertFalse(decode(trailing))
            for offset in [0] + reserved { var bad = good; bad[offset] = 2; XCTAssertFalse(decode(bad), "offset \(offset)") }
        }
    }
    func testCatalogueRejectsInvalidIdentityGeometryNamesAndState() {
        let good = Self.bytes(Self.catalogueHex)
        let mutations: [(Int, UInt8)] = [(1,4),(2,3),(4,33),(32,0),(24,2),
            (56,2),(57,1),(58,0),(59,2),(60,0),(60,10),(60,31),(60,127),(60,128),(60,192),(60,255)]
        for (offset, value) in mutations {
            var bad = good; bad[offset] = value; XCTAssertNil(RemoteMonitorCatalogueCommand.decode(bad), "offset \(offset)")
        }
        for offset in [48, 52] {
            for value in [UInt32(0), 32769, UInt32.max] {
                var bad = good; bad.storeLittleEndian(value, at: offset); XCTAssertNil(RemoteMonitorCatalogueCommand.decode(bad))
            }
        }
        for offset in [40, 44] {
            var bad = good; bad.storeLittleEndian(Int32.max, at: offset); XCTAssertNil(RemoteMonitorCatalogueCommand.decode(bad))
        }
        for offset in [8, 16] {
            var bad = good; bad.storeLittleEndian(UInt64(0), at: offset); XCTAssertNil(RemoteMonitorCatalogueCommand.decode(bad))
        }
        var duplicate = good; duplicate[4] = 2; duplicate.append(good.dropFirst(32))
        XCTAssertNil(RemoteMonitorCatalogueCommand.decode(duplicate))
        var unavailable = good; unavailable[2] = 0; XCTAssertNil(RemoteMonitorCatalogueCommand.decode(unavailable))
        for desktop in [UInt8(0), 2, 3, 255] {
            var bad = good; bad[1] = desktop; XCTAssertNil(RemoteMonitorCatalogueCommand.decode(bad))
        }
    }
    func testCatalogueMaximumUTF8AndUnavailableBounds() {
        let entries = (1...32).map { RemoteMonitorEntry(id: UInt64($0), left: Int32.min, top: -32768,
            width: 32768, height: 32768, flags: 0, name: String(repeating: "x", count: 256)) }
        let maximum = RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 9, revision: 3, currentId: 0, entries: entries)
        XCTAssertEqual(maximum.encode()?.count, 9120)
        XCTAssertEqual(maximum.encode().flatMap(RemoteMonitorCatalogueCommand.decode), maximum)
        for name in ["A", "\u{e9}", String(repeating: "x", count: 256), "A\u{200c}B"] {
            let value = RemoteMonitorCatalogueCommand(desktop: 1, state: 2, epoch: 9, revision: 3, currentId: 1,
                entries: [RemoteMonitorEntry(id: 1, left: 0, top: 0, width: 1, height: 1, flags: 0, name: name)])
            XCTAssertEqual(value.encode().flatMap(RemoteMonitorCatalogueCommand.decode), value)
        }
        for name in ["", String(repeating: "x", count: 257), "\u{85}", "\n"] {
            let value = RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 9, revision: 3, currentId: 1,
                entries: [RemoteMonitorEntry(id: 1, left: 0, top: 0, width: 1, height: 1, flags: 0, name: name)])
            XCTAssertNil(value.encode())
        }
        XCTAssertNil(RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 1, revision: 1, currentId: 0, entries: entries + [entries[0]]).encode())
        for desktop in [UInt8(0), 1, 2, 3, 255] {
            let value = RemoteMonitorCatalogueCommand(desktop: desktop, state: 0, epoch: 0, revision: 0, currentId: 0, entries: [])
            XCTAssertEqual(value.encode().flatMap(RemoteMonitorCatalogueCommand.decode), value)
        }
    }
    func testSelectIdentityAndResultStatusBounds() {
        for offset in [8, 32] {
            var bad = Self.bytes(Self.requestHex); bad.storeLittleEndian(UInt64(0), at: offset)
            XCTAssertNil(RemoteMonitorSelectCommand.decode(bad))
        }
        for offset in [8, 16, 24, 32] {
            var bad = Self.bytes(Self.resultHex); bad.storeLittleEndian(UInt64(0), at: offset)
            XCTAssertNil(RemoteMonitorSelectResultCommand.decode(bad))
        }
        for status in [UInt8(0), 1, 2, 3, 4, 5, 6, 255] {
            var value = Self.bytes(Self.resultHex); value[1] = status
            XCTAssertEqual(RemoteMonitorSelectResultCommand.decode(value) != nil, status <= 5)
        }
    }
    func testMonitorParserRejectsLengthsAndFlagsBeforeAllocation() {
        for (type, minimum, maximum) in [(68,16,16),(69,32,9120),(70,40,40),(71,40,40)] {
            for length in [0, minimum - 1, maximum + 1] {
                var header = Data(count: 16); header.storeLittleEndian(WireProtocol.magic, at: 0)
                header[4] = 1; header[5] = UInt8(type); header.storeLittleEndian(UInt32(length), at: 8)
                let parser = WireStreamParser(generation: 1); var failed = false
                parser.consume(header, generation: 1) { if case .failure = $0 { failed = true } }
                XCTAssertTrue(failed); XCTAssertEqual(parser.allocatedPayloadBytes, 0)
            }
            var header = Data(count: 16); header.storeLittleEndian(WireProtocol.magic, at: 0)
            header[4] = 1; header[5] = UInt8(type); header.storeLittleEndian(UInt16(1), at: 6)
            header.storeLittleEndian(UInt32(minimum), at: 8)
            let parser = WireStreamParser(generation: 1); var failed = false
            parser.consume(header, generation: 1) { if case .failure = $0 { failed = true } }
            XCTAssertTrue(failed); XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        }
    }
}
