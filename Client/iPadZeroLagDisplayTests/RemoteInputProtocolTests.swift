import XCTest
@testable import iPadCasting

final class RemoteInputProtocolTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var result = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<end], radix: 16)!); index = end
        }
        return result
    }
    func testFeatureGoldenBytesAndReservedFields() {
        let golden = bytes("01000000000000000300000000000000")
        XCTAssertEqual(RemoteFeaturesMessage(features: 3).encode(), golden)
        XCTAssertEqual(RemoteFeaturesMessage.decode(golden)?.features, 3)
        for offset in 1...7 { var bad = golden; bad[offset] = 1; XCTAssertNil(RemoteFeaturesMessage.decode(bad)) }
        XCTAssertNil(RemoteFeaturesMessage.decode(golden.dropLast()))
    }
    func testContextGoldenBytesAndPausedToken() {
        let golden = bytes("010101000102030405060708090000000000000080F8FFFFF6FFFFFF8007000038040000")
        let context = RemoteInputContextCommand(state: 1, desktop: 1, token: 0x0807060504030201,
            desktopEpoch: 9, left: -1920, top: -10, width: 1920, height: 1080)
        XCTAssertEqual(context.encode(), golden); XCTAssertEqual(RemoteInputContextCommand.decode(golden), context)
        let paused = bytes("0100FF000000000000000000090000000000000000000000000000000000000000000000")
        XCTAssertEqual(RemoteInputContextCommand.decode(paused)?.token, 0)
        var bad = golden; bad[1] = 0; XCTAssertNil(RemoteInputContextCommand.decode(bad))
    }
    func testScanGoldenBytesAndExceptionalKeys() {
        let golden = bytes("010001001C0000000102030405060708")
        let key = RemoteScanKeyCommand(action: 0, flags: 1, scan: 0x1c, token: 0x0807060504030201)
        XCTAssertEqual(key.encode(), golden); XCTAssertEqual(RemoteScanKeyCommand.decode(golden), key)
        for (offset, value) in [(0, UInt8(2)), (1, 3), (2, 4), (2, 3), (2, 2), (3, 1), (4, 0), (4, 128), (5, 1), (6, 1), (7, 1)] {
            var bad = golden; bad[offset] = value; XCTAssertNil(RemoteScanKeyCommand.decode(bad))
        }
        for action in [UInt8(0), 1, 2] {
            for (flags, scan) in [(UInt8(0), UInt16(0x1c)), (1, 0x1c), (1, 0x37), (2, 0x45), (0, 0x2a), (0, 0x36), (1, 0x5b), (1, 0x5c)] {
                XCTAssertNotNil(RemoteScanKeyCommand(action: action, flags: flags, scan: scan, token: 1).encode())
            }
        }
    }
    func testPointerGoldenBytesAndRanges() {
        let vectors: [(UInt8, UInt8, Int32, Int32, String)] = [
            (0, 0, 65535, 0, "010000000102030405060708FFFF00000000000000000000"),
            (1, 0, -7, 8, "010100000102030405060708F9FFFFFF0800000000000000"),
            (2, 5, 1, 0, "010200050102030405060708010000000000000000000000"),
            (3, 0, 120, -120, "0103000001020304050607087800000088FFFFFF00000000")]
        for (kind, button, a, b, hex) in vectors {
            let value = RemotePointerCommand(kind: kind, button: button, token: 0x0807060504030201, a: a, b: b)
            XCTAssertEqual(value.encode(), bytes(hex)); XCTAssertEqual(RemotePointerCommand.decode(bytes(hex)), value)
            var bad = bytes(hex); bad[20] = 1; XCTAssertNil(RemotePointerCommand.decode(bad))
        }
        XCTAssertNil(RemotePointerCommand(kind: 1, button: 0, token: 1, a: -32768, b: 0).encode())
        XCTAssertNil(RemotePointerCommand(kind: 2, button: 1, token: 1, a: 0, b: 1).encode())
    }
    func testResetAndCommittedTextGoldenBytes() {
        let reset = RemoteInputResetCommand(reason: 4, token: 0x0807060504030201)
        XCTAssertEqual(reset.encode(), bytes("01040000000000000102030405060708"))
        let text = RemoteCommittedTextCommand(token: 0x0807060504030201, text: "h\u{e9}")
        let golden = bytes("0100000000000000010203040506070801030068C3A9")
        XCTAssertEqual(text.encode(), golden); XCTAssertEqual(RemoteCommittedTextCommand.decode(golden), text)
        var bad = golden; bad[20] = 255; XCTAssertNil(RemoteCommittedTextCommand.decode(bad))
        XCTAssertNil(RemoteCommittedTextCommand(token: 1, text: "\n").encode())
    }
    func testNegotiationOldNewMatrixAndLatePong() {
        var oldHost = RemoteFeatureNegotiation(); XCTAssertTrue(oldHost.begin(now: 0))
        XCTAssertNil(oldHost.pong(flags: 0, now: 1)); XCTAssertNil(oldHost.pong(flags: 0x4000, now: 1.1))
        var late = RemoteFeatureNegotiation(); XCTAssertTrue(late.begin(now: 0))
        XCTAssertNil(late.pong(flags: 0x4000, now: 2)); XCTAssertEqual(late.accepted, 0)
        var current = RemoteFeatureNegotiation(); XCTAssertTrue(current.begin(now: 0))
        XCTAssertEqual(current.pong(flags: 0x4000, now: 1), bytes("01000000000000000300000000000000"))
        XCTAssertTrue(current.result(flags: 0, payload: bytes("01000000000000000300000000000000")))
        XCTAssertEqual(current.accepted, 3); XCTAssertFalse(current.result(flags: 0, payload: Data()))
        var malformed = RemoteFeatureNegotiation(); _ = malformed.begin(now: 0); _ = malformed.pong(flags: 0x4000, now: 1)
        XCTAssertFalse(malformed.result(flags: 0, payload: bytes("01000000000000000400000000000000")))
        XCTAssertEqual(malformed.accepted, 0)
    }
    func testContextRequiresFreshKeyframeAndDropsOldToken() {
        var state = RemoteFeatureNegotiation(); _ = state.begin(now: 0); _ = state.pong(flags: 0x4000, now: 1)
        XCTAssertTrue(state.result(flags: 0, payload: RemoteFeaturesMessage(features: 3).encode()))
        let ready = RemoteInputContextCommand(state: 1, desktop: 1, token: 7, desktopEpoch: 9, left: 0, top: 0, width: 1920, height: 1080)
        XCTAssertTrue(state.receiveContext(flags: 0, payload: ready.encode()!)); XCTAssertFalse(state.maySend(feature: 1, token: 7))
        state.keyframeArrived(); XCTAssertTrue(state.maySend(feature: 1, token: 7)); XCTAssertFalse(state.maySend(feature: 1, token: 6))
        state.invalidateInput(); XCTAssertFalse(state.maySend(feature: 1, token: 7))
    }
    func testEveryCodecRejectsTruncatedAndTrailingBytes() {
        let vectors: [(String, (Data) -> Bool)] = [
            ("01000000000000000300000000000000", { RemoteFeaturesMessage.decode($0) != nil }),
            ("010101000102030405060708090000000000000080F8FFFFF6FFFFFF8007000038040000", { RemoteInputContextCommand.decode($0) != nil }),
            ("010001001C0000000102030405060708", { RemoteScanKeyCommand.decode($0) != nil }),
            ("010100000102030405060708F9FFFFFF0800000000000000", { RemotePointerCommand.decode($0) != nil }),
            ("01040000000000000102030405060708", { RemoteInputResetCommand.decode($0) != nil }),
            ("0100000000000000010203040506070801030068C3A9", { RemoteCommittedTextCommand.decode($0) != nil })]
        for (hex, decode) in vectors {
            let good = bytes(hex); XCTAssertTrue(decode(good))
            for length in 0..<good.count { XCTAssertFalse(decode(Data(good.prefix(length)))) }
            var long = good; long.append(0); XCTAssertFalse(decode(long))
        }
    }
    func testEnhancedParserRejectsMalformedLengthsBeforeAllocation() {
        for (type, badSize) in [(61, 17), (62, 15), (63, 37), (64, 17), (65, 23), (66, 17), (67, 19)] {
            var header = Data(count: 16); header.storeLittleEndian(WireProtocol.magic, at: 0)
            header[4] = 1; header[5] = UInt8(type); header.storeLittleEndian(UInt32(badSize), at: 8)
            let parser = WireStreamParser(generation: 1); var failed = false
            parser.consume(header, generation: 1) { event in
                if case .failure = event { failed = true }
            }
            XCTAssertTrue(failed); XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        }
    }
}
