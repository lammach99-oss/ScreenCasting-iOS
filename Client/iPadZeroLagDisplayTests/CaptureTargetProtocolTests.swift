import XCTest
@testable import iPadCasting

final class CaptureTargetProtocolTests: XCTestCase {
    static func bytes(_ hex: String) -> Data {
        let characters = Array(hex.utf8)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(bytes: characters[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
        })
    }
    static let catalogueHex = "01010102307500000200000000000000030000000000000001000000000000000500000000000000" +
        "010000000000000000000600457874656e64" + "04000000000000000100050050616e656c"
    static let appliedHex = "01000100000000000100000000000000020000000000000003000000000000000100000000000000050000000000000006000000000000000100000000000000"
    static let acceptedHex = "010902ff000000000100000000000000020000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000"

    func testHelloAndRequestMatchCSharpGoldenVectors() throws {
        XCTAssertEqual(CaptureTargetProtocol.hello(), Self.bytes("01000000010000000000000000000000"))
        let request = CaptureTargetRequest(transaction: 1, owner: 2, revision: 3, targetId: 4)
        XCTAssertEqual(try request.encode(), Self.bytes("01000000000000000100000000000000020000000000000003000000000000000400000000000000"))
        XCTAssertThrowsError(try CaptureTargetRequest(transaction: 0, owner: 2, revision: 3, targetId: 4).encode())
    }
    func testCatalogueAndResultsMatchCSharpGoldenVectors() throws {
        let catalogue = try CaptureTargetCatalogue.decode(Self.bytes(Self.catalogueHex))
        XCTAssertEqual(catalogue.owner, 2); XCTAssertEqual(catalogue.revision, 3)
        XCTAssertEqual(catalogue.entries.map(\.kind), [.extend, .physical])
        XCTAssertEqual(catalogue.entries.map(\.name), ["Extend", "Panel"])
        XCTAssertEqual(catalogue.currentId, 1); XCTAssertEqual(catalogue.epoch, 5)
        let applied = try CaptureTargetResult.decode(Self.bytes(Self.appliedHex))
        XCTAssertEqual(applied.status, .applied); XCTAssertEqual(applied.kind, .extend)
        XCTAssertEqual(applied.firstFrame, 1); XCTAssertEqual(applied.source, 6)
        let accepted = try CaptureTargetResult.decode(Self.bytes(Self.acceptedHex))
        XCTAssertEqual(accepted.status, .accepted); XCTAssertNil(accepted.kind)
        XCTAssertEqual(accepted.transaction, 1); XCTAssertEqual(accepted.currentId, 0)
        var wrapped = Self.bytes(Self.appliedHex); wrapped[56] = 0
        XCTAssertEqual(try CaptureTargetResult.decode(wrapped).firstFrame, 0)
    }
    func testMalformedCataloguesAndResultsFailClosed() throws {
        let catalogue = Self.bytes(Self.catalogueHex), result = Self.bytes(Self.appliedHex)
        for size in 0..<catalogue.count {
            XCTAssertThrowsError(try CaptureTargetCatalogue.decode(Data(catalogue.prefix(size))))
        }
        for offset in [0, 1, 2, 3, 4, 48, 49, 52] {
            var bad = catalogue; bad[offset] = 254
            XCTAssertThrowsError(try CaptureTargetCatalogue.decode(bad), "offset \(offset)")
        }
        var duplicate = catalogue; duplicate.replaceSubrange(58..<66, with: catalogue[40..<48])
        XCTAssertThrowsError(try CaptureTargetCatalogue.decode(duplicate))
        var noExtend = catalogue; noExtend[48] = 1
        XCTAssertThrowsError(try CaptureTargetCatalogue.decode(noExtend))
        var trailing = catalogue; trailing.append(0)
        XCTAssertThrowsError(try CaptureTargetCatalogue.decode(trailing))
        for offset in [0, 1, 2, 3, 4, 60, 63] {
            var bad = result; bad[offset] = 254
            XCTAssertThrowsError(try CaptureTargetResult.decode(bad))
        }
        for size in 0..<64 { XCTAssertThrowsError(try CaptureTargetResult.decode(Data(result.prefix(size)))) }
    }
    func testTypedFramingRejectsWrongFlagsLengthsAndDirections() {
        XCTAssertTrue(CaptureTargetProtocol.validInbound(type: 73, flags: 0, length: 75))
        XCTAssertTrue(CaptureTargetProtocol.validInbound(type: 75, flags: 0, length: 64))
        for type in [UInt8(72), 74] {
            XCTAssertFalse(CaptureTargetProtocol.validInbound(type: type, flags: 0, length: 40))
        }
        XCTAssertFalse(CaptureTargetProtocol.validInbound(type: 73, flags: 1, length: 75))
        XCTAssertFalse(CaptureTargetProtocol.validInbound(type: 73, flags: 0, length: 34229))
        XCTAssertFalse(CaptureTargetProtocol.validInbound(type: 75, flags: 0, length: 63))
    }
    func testScopedRecoveryAndVirtualPermissionMatchHostGoldenVectors() throws {
        let applied = try CaptureTargetResult.decode(Self.bytes(Self.appliedHex))
        XCTAssertEqual(try applied.recoveryPayload(), Self.bytes("020000000000000005000000000000000600000000000000"))
        XCTAssertEqual(CaptureTargetProtocol.recoveryFlag, 0x1000)
        let accepted = try CaptureTargetResult.decode(Self.bytes(Self.acceptedHex))
        XCTAssertThrowsError(try accepted.recoveryPayload())
        let mirror = MirrorClientControl(); mirror.beginSession(7)
        _ = mirror.helloIfAdvertised(session: 7, flags: 0x7c00)
        let virtual = MirrorControlState(revision: 1, epoch: 5, source: 0, mode: .virtualDisplay,
            token: MirrorToken(low: 0, high: 0), geometry: nil, firstFrame: nil, lastSent: nil)
        _ = try mirror.receiveState(session: 7, data: MirrorControlCodec.encodeState(virtual))
        XCTAssertNil(mirror.switchPermissionRequest())
        XCTAssertNil(mirror.typedSwitchPermissionRequest(negotiated: false))
        XCTAssertEqual(mirror.typedSwitchPermissionRequest(negotiated: true),
            Self.bytes("0108000005000000000000000000000000000000000000000000000000000000"))
        XCTAssertTrue(mirror.allowsLegacyVirtualInput, "asking does not retire input or grant consent")
    }
}
