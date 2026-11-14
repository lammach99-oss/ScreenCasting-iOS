import XCTest
@testable import iPadCasting

final class ConnectionControlProtocolTests: XCTestCase {
    static func bytes(_ hex: String) -> Data {
        let chars = Array(hex.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0 + 1]), radix: 16)!
        })
    }
    static let hello = bytes("53435354014c00005000000000000000" +
        "0100000001000000" + String(repeating: "00", count: 72))
    static let snapshot = bytes("53435354014d0000a000000000000000" +
        "0101010101030100020000000000000001000000000000000000000000000000" +
        "1027000000000c000000000000000000" + String(repeating: "00", count: 112))
    static let request = bytes("53435354014e00002000000000000000" +
        "0102000000000000030000000000000001000000000000000200000000000000")
    static let accepted = bytes("53435354014f00004000000000000000" +
        "0100020100000400030000000000000001000000000000000300000000000000" +
        "0100000000000000000102030405060708090a0b0c0d0e0f0000000000000000")
    static let resumeUSB = bytes("53435354014c00005000000000000000" +
        "0104020001000000030000000000000001000000000000000200000000000000" +
        "000102030405060708090a0b0c0d0e0f2cfd519f56e258566e43cf13a31a7e22d" +
        "10d92588479bbac31ab767432c9f7ca")
    static let resumeWiFi = bytes("53435354014c00005000000000000000" +
        "0104010001000000030000000000000001000000000000000200000000000000" +
        "000102030405060708090a0b0c0d0e0f0fe08b0f2e4b4c3677b2d07812ea8c7d" +
        "bdcf282b9c5854513f8bb9a7f7e09526")
    func testSixFullMessageGoldenVectorsRoundTrip() throws {
        for (frame, direction) in [(Self.hello, true), (Self.snapshot, false),
                                    (Self.request, true), (Self.accepted, false),
                                    (Self.resumeUSB, true), (Self.resumeWiFi, true)] {
            XCTAssertEqual(try ConnectionControlProtocol.roundTrip(frame, clientToHost: direction), frame)
            XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(frame, clientToHost: !direction))
            XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(frame + Data([0]), clientToHost: direction))
            XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(Data(frame.dropLast()), clientToHost: direction))
            for offset in [4, 6, 7, 16] {
                var bad = frame; bad[offset] = 255
                XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(bad, clientToHost: direction))
            }
        }
    }
    func testReservedBytesAndUnknownEnumsReject() throws {
        for (frame, offsets, outbound) in [(Self.hello, [19], true),
            (Self.snapshot, Array(58..<64), false), (Self.request, Array(18..<24), true),
            (Self.accepted, [23, 77, 78, 79], false)] {
            for offset in offsets {
                var bad = frame; bad[offset] = 1
                XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(bad, clientToHost: outbound))
            }
        }
        for (frame, offsets, outbound) in [(Self.hello, [17,18,20], true),
            (Self.snapshot, [17,18,19,20,21,22,23,52,54,56], false),
            (Self.request, [17], true), (Self.accepted, [17,18,19,20,22,76], false)] {
            for offset in offsets {
                var bad = frame; bad[offset] = 255
                XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(bad, clientToHost: outbound))
            }
        }
    }
    func testSymmetricResumeGoldenVectors() throws {
        for (route, expected) in [(ConnectionRoute.usb, "2cfd519f56e258566e43cf13a31a7e22d10d92588479bbac31ab767432c9f7ca"),
                                  (.wifi, "0fe08b0f2e4b4c3677b2d07812ea8c7dbdcf282b9c5854513f8bb9a7f7e09526")] {
            let context = ConnectionProofContext(target: route, transaction: 3, owner: 1, revision: 2,
                token: Data(0..<16), challenge: Data(32..<64), secret: Data(64..<96))
            let hello = context.resumeHello()
            XCTAssertEqual(hello.kind, .resumeProof); XCTAssertEqual(hello.target, route)
            XCTAssertEqual(hello.proof, Self.bytes(expected))
            XCTAssertEqual(try ConnectionHello.decode(hello.encode()), hello)
            XCTAssertEqual(ConnectionControlProtocol.frame(type: 76, payload: try hello.encode()),
                route == .usb ? Self.resumeUSB : Self.resumeWiFi)
        }
    }
    func testRemovedCandidateKindsPhaseAndFormerHostProofReject() throws {
        for kind in [UInt8(1), 2, 3] {
            var frame = Self.resumeUSB; frame[17] = kind
            XCTAssertThrowsError(try ConnectionControlProtocol.roundTrip(frame, clientToHost: true))
        }
        var preparation = try ConnectionSwitchStateTests.prepare().encode()
        preparation[7] = 3
        XCTAssertThrowsError(try ConnectionControlState.decode(preparation))
        preparation[7] = 1; preparation[128] = 1
        XCTAssertThrowsError(try ConnectionControlState.decode(preparation))
    }
    func testTerminalContextDisposesTokenChallengeAndKey() {
        var context = ConnectionProofContext(target: .usb, transaction: 3, owner: 1, revision: 2,
            token: Data(0..<16), challenge: Data(32..<64), secret: Data(64..<96))
        context.erase()
        XCTAssertTrue(context.token.isEmpty); XCTAssertTrue(context.challenge.isEmpty)
    }
    static let usbCredential = TrustedHostCredential(fingerprint: "synthetic", hostID: Data(32..<48),
        deviceID: Data(16..<32), secret: Data(112..<144), sessionID: Data(144..<160))
    static let usbChallenge = Data(0..<112)
    func testUsbIdentitySuccessExactExistingCredentialBytes() throws {
        var state = USBSessionIdentityProof()
        XCTAssertEqual(state.offer(flags: 0x0100, credential: Self.usbCredential, now: 0), 0x0080)
        let hello = try XCTUnwrap(state.clientHello(name: "iPad", now: 0))
        XCTAssertEqual(hello, Data([1]) + Data(16..<32) + Data(144..<160) + Data([4]) + Data("iPad".utf8))
        let proof = try XCTUnwrap(state.answer(Self.usbChallenge, flags: 0, now: 1))
        XCTAssertEqual(proof, Self.bytes("000102030405060708090a0b0c0d0e0fcc47d96d2e54d4ae4e418f0460e9b3b53556db88d5de9ae0201f3469b368f878"))
        XCTAssertTrue(state.result(Data([1]) + Data("USB identity verified.".utf8), flags: 0,
            currentCredential: Self.usbCredential, now: 2))
        XCTAssertTrue(state.identified); XCTAssertFalse(state.pending)
    }
    func testUsbIdentityNoCredentialAndOldHostStaySilent() {
        for (flags, credential) in [(UInt16(0x0100), Optional<TrustedHostCredential>.none), (0, Self.usbCredential)] {
            var state = USBSessionIdentityProof()
            XCTAssertEqual(state.offer(flags: flags, credential: credential, now: 0), 0)
            XCTAssertNil(state.clientHello(name: "iPad", now: 0))
            XCTAssertNil(state.answer(Self.usbChallenge, flags: 0, now: 1))
            XCTAssertFalse(state.identified)
        }
    }
    func testUsbWrongHostChallengeNeverProducesProofOrIdentity() {
        for offset in [16, 32] {
            var state = USBSessionIdentityProof()
            _ = state.offer(flags: 0x0100, credential: Self.usbCredential, now: 0)
            _ = state.clientHello(name: "iPad", now: 0)
            var wrong = Self.usbChallenge; wrong[offset] ^= 1
            XCTAssertNil(state.answer(wrong, flags: 0, now: 1))
            XCTAssertFalse(state.result(Data([1]), flags: 0, currentCredential: Self.usbCredential, now: 2))
            XCTAssertFalse(state.identified); XCTAssertFalse(state.pending)
        }
    }
    func testUsbIdentityDeadlineReplayMalformedAndCredentialReplacement() {
        for time in [TimeInterval(5), -1] {
            var state = USBSessionIdentityProof()
            _ = state.offer(flags: 0x0100, credential: Self.usbCredential, now: 0)
            _ = state.clientHello(name: "iPad", now: 0)
            XCTAssertNil(state.answer(Self.usbChallenge, flags: 0, now: time))
            XCTAssertFalse(state.identified)
        }
        var state = USBSessionIdentityProof()
        _ = state.offer(flags: 0x0100, credential: Self.usbCredential, now: 0)
        _ = state.clientHello(name: "iPad", now: 0)
        XCTAssertNotNil(state.answer(Self.usbChallenge, flags: 0, now: 1))
        XCTAssertNil(state.answer(Self.usbChallenge, flags: 0, now: 1))
        XCTAssertFalse(state.result(Data([1]), flags: 0, currentCredential: nil, now: 2))
        XCTAssertFalse(state.identified)
        for credential in [Optional<TrustedHostCredential>.none,
                           TrustedHostCredential(fingerprint: "replaced", hostID: Data(32..<48),
                             deviceID: Data(16..<32), secret: Data(112..<144), sessionID: Data(144..<160))] {
            var replaced = USBSessionIdentityProof()
            _ = replaced.offer(flags: 0x0100, credential: Self.usbCredential, now: 0)
            _ = replaced.clientHello(name: "iPad", now: 1)
            XCTAssertNotNil(replaced.answer(Self.usbChallenge, flags: 0, now: 2))
            XCTAssertFalse(replaced.result(Data([1]), flags: 0, currentCredential: credential, now: 3))
            XCTAssertFalse(replaced.identified)
        }
    }
    func testUsbIdentityWriteDelayCannotExtendFiveSecondBudget() {
        var state = USBSessionIdentityProof()
        _ = state.offer(flags: 0x0100, credential: Self.usbCredential, now: 10)
        XCTAssertNotNil(state.clientHello(name: "iPad", now: 13))
        XCTAssertEqual(state.remainingBudget(now: 13), 2)
        XCTAssertEqual(state.remainingBudget(now: 15), 0)
        XCTAssertFalse(state.pending)
    }
    func testParserRejectsWrongDirectionBeforeAllocation() {
        for type in [UInt8(76), 78] {
            var header = Self.hello.prefix(16); header[5] = type
            let parser = WireStreamParser(generation: 1); var failures = 0
            parser.consume(Data(header), generation: 1) { if case .failure = $0 { failures += 1 } }
            XCTAssertEqual(failures, 1); XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        }
    }
    func testSemanticStatusReasonCombinationsReject() throws {
        var bytes = Array(Self.accepted.dropFirst(16))
        bytes[1] = 3; bytes[4] = 9; bytes[6] = 3
        bytes.replaceSubrange(40..<56, with: repeatElement(UInt8(0), count: 16))
        XCTAssertThrowsError(try ConnectionSelectResult.decode(Data(bytes)), "PermissionRequired must carry PermissionMissing")
        bytes[1] = 5; bytes[4] = 5
        XCTAssertThrowsError(try ConnectionSelectResult.decode(Data(bytes)), "Busy must carry LocalOperation")
        bytes[1] = 2; bytes[4] = 9
        XCTAssertThrowsError(try ConnectionSelectResult.decode(Data(bytes)), "NoDevice is Unavailable, not Denied")
        bytes[1] = 1; bytes[4] = 0; bytes[6] = 1
        XCTAssertThrowsError(try ConnectionSelectResult.decode(Data(bytes)), "fresh AlreadyActive echoes its active target")
    }
}
