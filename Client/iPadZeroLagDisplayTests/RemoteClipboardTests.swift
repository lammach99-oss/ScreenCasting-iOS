import CryptoKit
import Foundation
import XCTest
@testable import iPadCasting

final class RemoteClipboardTests: XCTestCase {
    private struct Vector: Decodable {
        let id: UInt8
        let payloadHex: String
    }

    func testHostGoldenVectorsRoundTrip() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "remote-clipboard-v2", withExtension: "json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 17)
        for vector in vectors {
            let type = try XCTUnwrap(WireMessageType(rawValue: vector.id))
            let pairs = stride(from: 0, to: vector.payloadHex.count, by: 2).map { offset in
                String(vector.payloadHex.dropFirst(offset).prefix(2))
            }
            let data = Data(try pairs.map { try XCTUnwrap(UInt8($0, radix: 16)) })
            if vector.id == 61 || vector.id == 62 {
                XCTAssertEqual(try XCTUnwrap(RemoteFeaturesMessage.decode(data)).features, 0x1043)
                continue
            }
            let message = try XCTUnwrap(RemoteClipboardProtocol.decode(type: type, payload: data), "SCST \(vector.id)")
            XCTAssertEqual(message.encode(), data)
            XCTAssertNil(RemoteClipboardProtocol.decode(type: type, payload: data.dropLast()))
            var invalid = data
            invalid[0] = 1
            XCTAssertNil(RemoteClipboardProtocol.decode(type: type, payload: invalid))
        }
    }

    func testClipboardRequiresPairedOptInAndMatchingMarker() throws {
        for (flags, optedIn, expected) in [(UInt16(0x4000), true, false), (0x4800, false, false), (0x4800, true, true)] {
            var features = RemoteFeatureNegotiation()
            XCTAssertTrue(features.begin(now: 0))
            let request = try XCTUnwrap(features.pong(flags: flags, now: 1, requestClipboard: optedIn))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, expected ? 0x1043 : 3)
        }
    }

    func testOldHostResultDoesNotActivateClipboard() throws {
        for mask in [UInt64(3), 0x43, 0x1003, 0x1043] {
            var features = RemoteFeatureNegotiation()
            XCTAssertTrue(features.begin(now: 0))
            XCTAssertNotNil(features.pong(flags: 0x4800, now: 1, requestClipboard: true))
            XCTAssertTrue(features.result(flags: 0, payload: RemoteFeaturesMessage(features: mask).encode()))
            XCTAssertEqual(features.accepted, mask == 0x1043 ? 0x1043 : 3)
        }
    }

    func testLeaseRenewsOnlyWhileEligibleAndRequestsAgainAfterExpiry() throws {
        var lease = RemoteClipboardLease()
        let hello = try XCTUnwrap(lease.start())
        guard case .hello(_, _, _, let nonce) = hello else { return XCTFail("Expected Hello") }
        XCTAssertNil(lease.tick(eligible: true, now: 0))
        let disabled = RemoteClipboardProtocol.State(kind: .disabled, directions: 0, maxBytes: 10_000_000,
            maxChunk: 16_384, formats: 3, nonce: nonce, token: RemoteClipboardProtocol.emptyID,
            epoch: 1, requestID: 0, reason: .viewerDisabled)
        lease.receive(disabled, eligible: true, now: 0)
        let request = try XCTUnwrap(lease.tick(eligible: true, now: 0))
        XCTAssertEqual(request, .control(.request, 3, 1, true, nonce))
        let grant = RemoteClipboardProtocol.State(kind: .enabled, directions: 3, maxBytes: 10_000_000,
            maxChunk: 16_384, formats: 3, nonce: nonce, token: UUID(), epoch: 2, requestID: 1, reason: .ok)
        lease.receive(grant, eligible: true, now: 0.1)
        XCTAssertEqual(lease.tick(eligible: true, now: 1), .control(.renew, 3, 2, true, nonce))
        XCTAssertEqual(lease.tick(eligible: true, now: 4), .control(.request, 3, 3, true, nonce))
        XCTAssertNil(lease.grant)
        lease.receive(grant, eligible: true, now: 4.1)
        XCTAssertNil(lease.grant)
        XCTAssertEqual(lease.tick(eligible: false, now: 4.1), .control(.disable, 0, 4, false, nonce))
        XCTAssertNil(lease.tick(eligible: false, now: 5.1))
    }

    func testParserRejectsUnnegotiatedOrOversizedClipboardBeforeAllocation() {
        for (negotiated, length, flags, accepted) in [
            (false, 65, UInt16(0), false), (true, 65, 1, false),
            (true, 64, 0, false), (true, 16_449, 0, false), (true, 65, 0, true)
        ] {
            let parser = WireStreamParser(generation: 1, allowsRemoteClipboard: { negotiated })
            var header = Data(count: WireProtocol.headerSize)
            header.storeLittleEndian(WireProtocol.magic, at: 0)
            header[4] = WireProtocol.version
            header[5] = WireMessageType.clipboardChunk.rawValue
            header.storeLittleEndian(flags, at: 6)
            header.storeLittleEndian(UInt32(length), at: 8)
            var failed = false
            parser.consume(header, generation: 1) { event in
                if case .failure = event { failed = true }
            }
            XCTAssertEqual(failed, !accepted)
            XCTAssertEqual(parser.allocatedPayloadBytes, accepted ? length : 0)
        }
    }

    func testTransferRequiresContiguousChunksAndMatchingDigest() {
        let bytes = Data("abc".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let prefix = RemoteClipboardProtocol.Prefix(token: UUID(), epoch: 1, update: UUID())
        let offer = RemoteClipboardProtocol.Offer(prefix: prefix, format: .text, formats: 1, length: bytes.count,
                                                 origin: UUID(), counter: 1, revision: 0, digest: digest)
        let transfer = RemoteClipboardTransfer(offer: offer, now: 0)
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 1))
        XCTAssertTrue(transfer.accept(revision: 4, now: 1))
        XCTAssertFalse(transfer.append(index: 0, offset: 1, data: bytes, maxChunk: 3, now: 2))
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 2, now: 2))
        XCTAssertTrue(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 2))
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 3))
        XCTAssertNil(transfer.finish(length: 3, digest: Data(count: 32), now: 3))
        XCTAssertEqual(transfer.finish(length: 3, digest: digest, now: 3), bytes)
        XCTAssertNil(transfer.finish(length: 3, digest: digest, now: 3))
    }

    func testCanonicalTextAndChunkBounds() {
        XCTAssertEqual(RemoteClipboardProtocol.canonicalText(Data("a\r\nb".utf8), fromWire: false), Data("a\nb".utf8))
        XCTAssertEqual(RemoteClipboardProtocol.canonicalText(Data(), fromWire: true), Data())
        for invalid in [Data([0xff]), Data([0]), Data([0xef, 0xbb, 0xbf]), Data([13, 10])] {
            XCTAssertNil(RemoteClipboardProtocol.canonicalText(invalid, fromWire: true))
        }
        XCTAssertFalse(RemoteClipboardProtocol.validLength(.clipboardChunk, 64))
        XCTAssertTrue(RemoteClipboardProtocol.validLength(.clipboardChunk, 64 + 16_384))
        XCTAssertFalse(RemoteClipboardProtocol.validLength(.clipboardChunk, 65 + 16_384))
    }
}
