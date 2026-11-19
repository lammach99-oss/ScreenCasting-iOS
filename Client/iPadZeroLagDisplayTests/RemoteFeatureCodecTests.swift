import Foundation
import XCTest
@testable import iPadCasting

final class RemoteFeatureCodecTests: XCTestCase {
    private struct Fixture: Decodable {
        let version: Int
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let transport: String
        let id: UInt8
        let flags: UInt16
        let sequence: UInt32
        let valid: Bool
        let payloadHex: String

        func payload() throws -> Data {
            var result = Data()
            var index = payloadHex.startIndex
            while index != payloadHex.endIndex {
                let end = try XCTUnwrap(payloadHex.index(index, offsetBy: 2, limitedBy: payloadHex.endIndex), name)
                result.append(try XCTUnwrap(UInt8(payloadHex[index..<end], radix: 16), name))
                index = end
            }
            return result
        }
    }

    func testSharedContractGoldenVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "remote-ds5-ds7-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.version, 1)
        var scstValid = 0, scstRejected = 0, ipcValid = 0, ipcRejected = 0
        for vector in fixture.vectors {
            let type = try XCTUnwrap(WireMessageType(rawValue: vector.id), vector.name)
            let payload = try vector.payload()
            let file = RemoteFileProtocol.decode(type: type, payload: payload, flags: vector.flags)
            let audio = RemoteAudioProtocol.decode(type: type, payload: payload, flags: vector.flags, sequence: vector.sequence)
            let secure = RemoteSecureDesktopProtocol.decode(type: type, payload: payload, flags: vector.flags)
            if vector.transport == "ipc" {
                // The same numeric IDs have separate meanings in SCST and agent IPC.
                XCTAssertNil(file, vector.name)
                XCTAssertNil(audio, vector.name)
                XCTAssertNil(secure, vector.name)
                if vector.valid { ipcValid += 1 } else { ipcRejected += 1 }
                continue
            }
            XCTAssertEqual(vector.transport, "scst", vector.name)
            let decodedCount = [file != nil, audio != nil, secure != nil].filter { $0 }.count
            XCTAssertEqual(decodedCount, vector.valid ? 1 : 0, vector.name)
            if vector.valid {
                scstValid += 1
                if let file {
                    XCTAssertEqual(file.type, type, vector.name)
                    XCTAssertEqual(RemoteFileProtocol.encode(file), payload, vector.name)
                } else if let audio {
                    XCTAssertEqual(audio.type, type, vector.name)
                    XCTAssertEqual(RemoteAudioProtocol.encode(audio, sequence: vector.sequence), payload, vector.name)
                } else if let secure {
                    XCTAssertEqual(secure.type, type, vector.name)
                    XCTAssertEqual(RemoteSecureDesktopProtocol.encode(secure), payload, vector.name)
                }
            } else {
                scstRejected += 1
            }
        }
        XCTAssertEqual(scstValid, 31)
        XCTAssertEqual(scstRejected, 165)
        XCTAssertEqual(ipcValid, 10)
        XCTAssertEqual(ipcRejected, 49)
    }

    func testRemoteFileOfferUsesNFCAndOrdinalCaseWithoutExpandingLetters() {
        func offer(_ names: [String]) -> Data? {
            var packet = TransferPacket(kind: .offer, generation: 1, id: UUID())
            packet.files = names.map { TransferFile(name: $0, length: 1) }
            return RemoteFileProtocol.encode(.packet(grantId: UUID(), transfer: packet))
        }

        XCTAssertNil(offer(["Cafe\u{301}.txt", "CAF\u{C9}.TXT"]))
        XCTAssertNil(offer(["CON  .txt"]))
        XCTAssertNil(offer(["conout$.txt"]))
        XCTAssertNil(offer(["COM\u{B2}.txt"]))
        XCTAssertNotNil(offer(["Stra\u{DF}e.txt", "STRASSE.TXT", "join\u{200D}er.txt"]))
    }

    func testPhaseARecognizesButDoesNotRequestNewFeatures() throws {
        let new: UInt64 = 0x700
        XCTAssertEqual(RemoteFeatureNegotiation.knownFeatures & new, new)
        var negotiation = RemoteFeatureNegotiation(requestedFeatures: 0x1f | new)
        XCTAssertTrue(negotiation.begin(now: 0))
        let request = try XCTUnwrap(negotiation.pong(flags: RemoteFeatureNegotiation.supportedFlag, now: 1))
        XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, 0x1f)
        XCTAssertFalse(negotiation.result(flags: 0, payload: RemoteFeaturesMessage(features: new).encode()))
        XCTAssertEqual(negotiation.accepted, 0)
    }

    func testPhaseARejectsUnnegotiatedHeadersBeforeAllocatingBodies() {
        for type in UInt8(100)...109 {
            let frame = ConnectionControlProtocol.frame(type: type, payload: Data(count: 32))
            let parser = WireStreamParser(generation: 1)
            var failures = 0
            parser.consume(Data(frame.prefix(WireProtocol.headerSize)), generation: 1) {
                if case .failure(.invalidHeader) = $0 { failures += 1 }
            }
            XCTAssertEqual(failures, 1, "SCST \(type)")
            XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        }
    }
}
