import Combine
import CryptoKit
import Foundation
import XCTest
@testable import iPadCasting

final class RemoteFeatureCodecTests: XCTestCase {
    func testPhoneFeatureRequestKeepsClipboardAndMonitor() throws {
        for family in [ClientDeviceCapabilities.Family.phone, .pad] {
            let capabilities = ClientDeviceCapabilities(family: family)
            var features = RemoteFeatureNegotiation(requestedFeatures: capabilities.remoteInputFeatureMask)
            XCTAssertTrue(features.begin(now: 0))
            let bytes = try XCTUnwrap(features.pong(flags: RemoteClipboardProtocol.marker, now: 1,
                requestRemoteFiles: capabilities.allowsFileTransfer, requestClipboard: true))
            let expected: UInt64 = family == .phone ? 0x17 : 0x11f
            XCTAssertEqual(RemoteFeaturesMessage.decode(bytes)?.features, expected | RemoteClipboardProtocol.features)
        }
    }

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

    func testRemoteSasAvailabilityGoldenPayloads() throws {
        // Tests/Ipc/RemoteContracts/remote-sas-availability-golden.json
        let vectors: [([UInt8], UInt16, Bool?)] = [
            ([1, 0], 0, false), ([1, 1], 0, true), ([1], 0, nil),
            ([1, 1, 0], 0, nil), ([2, 1], 0, nil), ([1, 2], 0, nil), ([1, 1], 1, nil)
        ]
        let type = try XCTUnwrap(WireMessageType(rawValue: 110))
        for (bytes, flags, available) in vectors {
            let payload = Data(bytes)
            let decoded = RemoteSecureDesktopProtocol.decode(type: type, payload: payload, flags: flags)
            XCTAssertEqual(decoded, available.map { .sasAvailability(available: $0) }, "\(bytes), flags \(flags)")
            if let decoded {
                XCTAssertEqual(decoded.type, type)
                XCTAssertEqual(RemoteSecureDesktopProtocol.encode(decoded), payload)
            }
        }
    }

    func testRemoteSasAvailabilityParserRequiresNegotiationAndValidHeader() {
        let cases: [(Bool, Int, UInt8, Bool)] = [
            (false, 2, 0, false), (true, 2, 0, true), (true, 2, 1, false),
            (true, 1, 0, false), (true, 3, 0, false)
        ]
        for (negotiated, size, flags, allowed) in cases {
            var frame = ConnectionControlProtocol.frame(type: 110, payload: Data([1, 1, 0].prefix(size)))
            frame[6] = flags
            let parser = WireStreamParser(generation: 1, allowsSecureDesktop: { true },
                                          allowsSasAvailability: { negotiated })
            var messages = 0, failures = 0
            parser.consume(Data(frame.prefix(WireProtocol.headerSize)), generation: 1) {
                if case .failure(.invalidHeader) = $0 { failures += 1 }
            }
            if allowed {
                parser.consume(Data(frame.dropFirst(WireProtocol.headerSize)), generation: 1) {
                    if case .message = $0 { messages += 1 }
                }
            } else {
                XCTAssertEqual(parser.allocatedPayloadBytes, 0)
            }
            XCTAssertEqual(messages, allowed ? 1 : 0)
            XCTAssertEqual(failures, allowed ? 0 : 1)
        }
    }

    func testRemoteAudioRequestsFeatureOnlyWithOptInAndAcceptsViewOnlyGrant() throws {
        for preferred in [false, true] {
            var negotiation = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
            XCTAssertTrue(negotiation.begin(now: 0))
            let request = try XCTUnwrap(negotiation.pong(flags: 0x4000, now: 1, requestRemoteAudio: preferred))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, preferred ? 0x21f : 0x1f)
            XCTAssertEqual(negotiation.result(flags: 0, payload: RemoteFeaturesMessage(features: 0x200).encode()), preferred)
        }
        var legacy = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
        XCTAssertTrue(legacy.begin(now: 0))
        XCTAssertNil(legacy.pong(flags: 0, now: 1, requestRemoteAudio: true))
    }

    func testRemoteAudioParserAdmitsOnlyNegotiatedServerDirections() {
        let cases: [(UInt8, Int, UInt8, Bool)] = [
            (104, 16, 0, false), (105, 32, 0, true), (106, 25, 0, true), (107, 25, 0, true),
            (105, 32, 1, false), (106, 25, 1, false), (107, 25, 1, false),
            (105, 31, 0, false), (106, 145, 0, false), (107, 16_409, 0, false)
        ]
        for (type, size, flags, allowed) in cases {
            var bytes = ConnectionControlProtocol.frame(type: type, payload: Data(count: size), sequence: 1)
            bytes[6] = flags
            let parser = WireStreamParser(generation: 1, allowsRemoteAudio: { true })
            var messages = 0
            var failures = 0
            parser.consume(bytes, generation: 1) {
                if case .message = $0 { messages += 1 }
                if case .failure(.invalidHeader) = $0 { failures += 1 }
            }
            XCTAssertEqual(messages, allowed ? 1 : 0)
            XCTAssertEqual(failures, allowed ? 0 : 1)
        }
    }

    func testRemoteAudioPreferenceDefaultsOffAndIsScopedToPairedHost() throws {
        let suiteName = "remote-audio-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostA = Data(repeating: 1, count: 16)
        let hostB = Data(repeating: 2, count: 16)
        XCTAssertFalse(ClientStreamSettingsStore.loadRemoteAudio(hostID: hostA, defaults: defaults))
        ClientStreamSettingsStore.saveRemoteAudio(true, hostID: hostA, defaults: defaults)
        XCTAssertTrue(ClientStreamSettingsStore.loadRemoteAudio(hostID: hostA, defaults: defaults))
        XCTAssertFalse(ClientStreamSettingsStore.loadRemoteAudio(hostID: hostB, defaults: defaults))
        ClientStreamSettingsStore.saveRemoteAudio(false, hostID: hostA, defaults: defaults)
        XCTAssertFalse(ClientStreamSettingsStore.loadRemoteAudio(hostID: hostA, defaults: defaults))
    }

    func testRemoteAudioDisableWinsAndRevocationFencesPackets() throws {
        var session = RemoteAudioSession(preferred: true)
        let get = try XCTUnwrap(session.negotiate(granted: true))
        XCTAssertEqual(get.operation, .get)
        XCTAssertTrue(session.admit(get, now: 0))
        let enable = try XCTUnwrap(session.receive(.off, reason: .none, requestID: get.id, epoch: 0, startUs: 0))
        XCTAssertEqual(enable.operation, .enable)
        XCTAssertTrue(session.admit(enable, now: 0))
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: enable.id, epoch: 5, startUs: 100))
        XCTAssertTrue(session.acceptPacket(sequence: 1, epoch: 5, captureUs: 100))
        XCTAssertFalse(session.acceptPacket(sequence: 1, epoch: 5, captureUs: 101))
        let disable = try XCTUnwrap(session.prefer(false))
        XCTAssertEqual(disable.operation, .disable)
        XCTAssertNil(session.prefer(true))
        XCTAssertTrue(session.admit(disable, now: 1))
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: 0, epoch: 5, startUs: 100))
        XCTAssertFalse(session.acceptPacket(sequence: 2, epoch: 5, captureUs: 101))
        let restart = try XCTUnwrap(session.receive(.off, reason: .none, requestID: disable.id, epoch: 0, startUs: 0))
        XCTAssertEqual(restart.operation, .enable)
        XCTAssertTrue(session.admit(restart, now: 2))
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: restart.id, epoch: 6, startUs: 200))
        XCTAssertFalse(session.acceptPacket(sequence: 1, epoch: 6, captureUs: 199))
        XCTAssertNil(session.receive(.paused, reason: .revoked, requestID: 0, epoch: 0, startUs: 0))
        XCTAssertEqual(session.reason, .revoked)
        XCTAssertFalse(session.acceptPacket(sequence: 1, epoch: 6, captureUs: 200))
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: 0, epoch: 6, startUs: 200))
        XCTAssertEqual(session.activeEpoch, 0)
        XCTAssertNil(session.receive(.denied, reason: .endpoint, requestID: 0, epoch: 0, startUs: 0))
        XCTAssertEqual(session.reason, .endpoint)
    }

    func testRemoteAudioTimeoutUsesFreshGetAndBackgroundFencesPlayback() throws {
        var session = RemoteAudioSession(preferred: true)
        let get = try XCTUnwrap(session.negotiate(granted: true))
        XCTAssertTrue(session.admit(get, now: 1))
        XCTAssertNil(session.tick(now: 2))
        let retry = try XCTUnwrap(session.tick(now: 3))
        XCTAssertEqual(retry.operation, .get)
        XCTAssertGreaterThan(retry.id, get.id)
        XCTAssertTrue(session.admit(retry, now: 3))
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: get.id, epoch: 1, startUs: 1))
        XCTAssertEqual(session.activeEpoch, 0)
        XCTAssertNil(session.receive(.streaming, reason: .none, requestID: retry.id, epoch: 1, startUs: 1))
        XCTAssertEqual(session.activeEpoch, 1)
        XCTAssertEqual(session.suspend(true)?.operation, .disable)
        XCTAssertEqual(session.activeEpoch, 0)
    }

    func testRemoteAudioJitterBoundsDepthAndConcealsAtMostTwoMissingPackets() {
        var jitter = RemoteAudioJitter()
        for sequence in UInt32(65_535)...65_538 {
            jitter.insert(.init(sequence: sequence, captureUs: UInt64(sequence) * 10_000, opus: Data([1])))
        }
        XCTAssertEqual(jitter.count, 3)
        for sequence in UInt32(65_536)...65_538 {
            XCTAssertEqual(jitter.dequeue()?.captureUs, UInt64(sequence) * 10_000)
        }
        XCTAssertEqual(jitter.dequeue(), .init(captureUs: 655_390_000, opus: nil))
        XCTAssertEqual(jitter.dequeue(), .init(captureUs: 655_400_000, opus: nil))
        XCTAssertNil(jitter.dequeue())
    }

    func testRemoteTimedVideoOnlyReleasesCompleteAUAndResetsAcrossBarriers() {
        var assembler = RemoteTimedVideoAssembler()
        func append(_ offset: UInt32, bytes: [UInt8], frame: UInt32 = 70) -> RemoteTimedVideoAssembler.Result {
            assembler.push(flags: 3, frame: frame, total: 4, offset: offset, captureUs: 110, fragment: Data(bytes), receivedAt: 2)
        }
        XCTAssertEqual(append(0, bytes: [1, 2]), .partial)
        XCTAssertEqual(append(2, bytes: [3, 4]), .complete(.init(flags: 3, frame: 70, captureUs: 110,
                                                               bytes: Data([1, 2, 3, 4]), firstByteAt: 2)))
        XCTAssertEqual(append(0, bytes: [1]), .partial)
        XCTAssertEqual(append(2, bytes: [3, 4]), .recover)
        XCTAssertEqual(append(0, bytes: [1, 2]), .partial)
        XCTAssertEqual(append(2, bytes: [3, 4], frame: 71), .recover)
        XCTAssertEqual(append(0, bytes: [1, 2]), .partial)
        assembler.reset()
        XCTAssertEqual(append(2, bytes: [3, 4]), .recover)
    }

    func testRemoteAudioVideoDeadlineUsesAnchorAndCapsDelay() {
        let anchor = RemoteAudioClock(captureUs: 100_000, playoutAt: 10)
        XCTAssertEqual(anchor.videoDeadline(captureUs: 130_000, receivedAt: 10, now: 10), 10.03, accuracy: 0.000001)
        XCTAssertEqual(anchor.videoDeadline(captureUs: 200_000, receivedAt: 10, now: 10), 10.05, accuracy: 0.000001)
        XCTAssertEqual(anchor.videoDeadline(captureUs: 80_000, receivedAt: 10, now: 10), 10, accuracy: 0.000001)
    }

    func testRemoteFilesRequestRequiresMarkedTimelyPongAndMatchingResult() throws {
        var oldHost = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
        XCTAssertTrue(oldHost.begin(now: 0))
        XCTAssertNil(oldHost.pong(flags: 0, now: 1, requestRemoteFiles: true))
        let initialProbe = Data(repeating: 1, count: 16)
        let retryProbe = Data(repeating: 2, count: 16)
        for reply in [initialProbe, retryProbe] {
            var late = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
            XCTAssertTrue(late.begin(now: 0))
            late.recordProbe(initialProbe, clipboard: false)
            XCTAssertTrue(late.expire(now: 2))
            late.recordProbe(retryProbe, clipboard: true)
            XCTAssertNil(late.consumeProbeReply(Data(repeating: 3, count: 16)))
            XCTAssertEqual(late.consumeProbeReply(reply), reply == retryProbe)
            XCTAssertNil(late.consumeProbeReply(initialProbe))
            XCTAssertNil(late.consumeProbeReply(retryProbe))
            let lateRequest = try XCTUnwrap(late.pong(flags: 0x4000, now: 2.5, requestRemoteFiles: true))
            XCTAssertEqual(RemoteFeaturesMessage.decode(lateRequest)?.features, 0x11f)
            XCTAssertTrue(late.result(flags: 0, payload: RemoteFeaturesMessage(features: 0x11f).encode()))
            XCTAssertEqual(late.accepted, 0x11f)
        }
        for mask in [UInt64(0x1f), 0x11f] {
            var peer = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
            XCTAssertTrue(peer.begin(now: 0))
            let request = try XCTUnwrap(peer.pong(flags: 0x4000, now: 1, requestRemoteFiles: true))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, 0x11f)
            XCTAssertEqual(peer.accepted, 0)
            XCTAssertTrue(peer.result(flags: 0, payload: RemoteFeaturesMessage(features: mask).encode()))
            XCTAssertEqual(peer.accepted & 0x100, mask & 0x100)
        }
    }

    func testRemoteFileGoldenGrantRequiresConsentAndRetiredGrantCannotAdmit() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "remote-ds5-ds7-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let vector = try XCTUnwrap(fixture.vectors.first { $0.name == "file-granted" })
        let reply = try XCTUnwrap(RemoteFileProtocol.decode(type: .remoteFileState, payload: vector.payload(), flags: vector.flags))
        guard case let .state(_, id, _, _, grant) = reply else { return XCTFail("Expected grant") }
        var session = RemoteFileAccess()
        XCTAssertTrue(session.receive(reply, allowed: true).isEmpty)
        for prior in 1..<id {
            _ = try XCTUnwrap(session.start(.download))
            session.didStartRequest(prior)
            _ = session.receive(.state(phase: .denied, requestId: prior, reason: .userDeclined,
                                       directions: .none, grantId: RemoteFileProtocol.emptyID), allowed: true)
        }
        let request = try XCTUnwrap(session.start(.download))
        XCTAssertEqual(RemoteFileProtocol.encode(request)?.count, 32)
        XCTAssertTrue(session.receive(reply, allowed: true).isEmpty)
        session.didStartRequest(id)
        XCTAssertEqual(session.receive(reply, allowed: true).count, 1)
        XCTAssertEqual(session.grant, grant)
        XCTAssertFalse(session.takeIncomingOffer(grant: grant, offer: UUID()))
        let revoked = RemoteFileProtocol.Message.state(phase: .revoked, requestId: 0, reason: .scopeLost,
                                                        directions: .none, grantId: grant)
        _ = session.receive(revoked, allowed: true)
        XCTAssertNil(session.grant)
        XCTAssertTrue(session.receive(reply, allowed: true).isEmpty)
    }

    func testRemoteFileGrantArrivingAfterBackgroundIsReleasedWithoutStarting() throws {
        var session = RemoteFileAccess()
        _ = try XCTUnwrap(session.start(.download))
        session.didStartRequest(1)
        XCTAssertNil(session.revoke())
        let id = UUID()
        let reply = RemoteFileProtocol.Message.state(phase: .granted, requestId: 1, reason: .none,
                                                      directions: .both, grantId: id)
        let actions = session.receive(reply, allowed: false)
        XCTAssertNil(session.grant)
        XCTAssertEqual(actions.count, 1)
        guard case let .send(.control(operation, request, _, grant))? = actions.first else {
            return XCTFail("Expected Release")
        }
        XCTAssertEqual(operation, .release)
        XCTAssertEqual(request, 2)
        XCTAssertEqual(grant, id)
    }

    private func goldenFile(_ name: String) throws -> RemoteFileProtocol.Message {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "remote-ds5-ds7-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let vector = try XCTUnwrap(fixture.vectors.first { $0.name == name && $0.valid })
        let type = try XCTUnwrap(WireMessageType(rawValue: vector.id))
        return try XCTUnwrap(RemoteFileProtocol.decode(type: type, payload: vector.payload(), flags: vector.flags))
    }

    func testRemoteFileParserBoundsPrefixBeforeAllocation() throws {
        let payload = try XCTUnwrap(RemoteFileProtocol.encode(goldenFile("file-chunk")))
        let frame = ConnectionControlProtocol.frame(type: 102, payload: payload)
        let parser = WireStreamParser(generation: 1, allowsRemoteFiles: { true })
        parser.consume(Data(frame.prefix(WireProtocol.headerSize)), generation: 1) { _ in XCTFail("Premature event") }
        XCTAssertEqual(parser.allocatedPayloadBytes, 20)
        var received = 0
        parser.consume(Data(frame.dropFirst(WireProtocol.headerSize)), generation: 1) {
            if case .message(let message) = $0 { XCTAssertEqual(message.payload, payload); received += 1 }
        }
        XCTAssertEqual(received, 1)
        var bad = frame
        bad[WireProtocol.headerSize + 1] = TransferKind.end.rawValue
        parser.consume(Data(bad.prefix(WireProtocol.headerSize + 20)), generation: 1) {
            if case .failure(.invalidHeader) = $0 { received += 1 }
        }
        XCTAssertEqual(received, 2)
        XCTAssertEqual(parser.allocatedPayloadBytes, 0)
    }

    func testRemoteFilesDownloadNeedsCorrelatedPickerAndIgnoresReplayedOffer() throws {
        let grantMessage = try goldenFile("file-granted")
        let ready = try goldenFile("file-host-files-ready")
        let offer = try goldenFile("file-offer")
        guard case let .packet(grant, packet) = offer else { return XCTFail("Expected offer") }
        var access = RemoteFileAccess()
        for id in 1...2 {
            _ = try XCTUnwrap(access.start(.download, now: 0))
            access.didStartRequest(UInt64(id))
            _ = access.receive(.state(phase: .denied, requestId: UInt64(id), reason: .policy,
                                      directions: .none, grantId: RemoteFileProtocol.emptyID), allowed: true)
        }
        XCTAssertNotNil(access.start(.download, now: 1))
        XCTAssertTrue(access.expire(now: 61))
        access.didStartRequest(3)
        _ = access.receive(grantMessage, allowed: true, now: 2)
        access.didStartRequest(4)
        _ = access.receive(ready, allowed: true)
        let early = UUID()
        XCTAssertFalse(access.takeIncomingOffer(grant: grant, offer: early))
        _ = access.receive(.state(phase: .denied, requestId: 4, reason: .userDeclined,
                                  directions: .none, grantId: RemoteFileProtocol.emptyID), allowed: true)
        XCTAssertEqual(RemoteFileProtocol.encode(try XCTUnwrap(access.start(.download))),
                       RemoteFileProtocol.encode(try goldenFile("file-request-host-files")))
        access.didStartRequest(5)
        _ = access.receive(ready, allowed: true)
        XCTAssertFalse(access.takeIncomingOffer(grant: grant, offer: early))
        XCTAssertTrue(access.takeIncomingOffer(grant: grant, offer: packet.id))
        XCTAssertFalse(access.takeIncomingOffer(grant: grant, offer: packet.id))
    }

    func testRemoteFileCreditRequiresBothBoundsAndExactConsumption() throws {
        guard case let .packet(_, chunk) = try goldenFile("file-chunk") else { return XCTFail("Expected chunk") }
        let window = DataTransferManager.FileWindow(offer: chunk.id, file: 0, consumed: 0, limit: 1, chunks: 1)
        var credit = DataTransferManager.DownloadCredit(generation: chunk.generation, window: window, offset: 0, chunk: 0)
        var future = chunk
        future.bytes.append(0)
        XCTAssertFalse(credit.admit(future))
        XCTAssertTrue(credit.admit(chunk))
        XCTAssertFalse(credit.admit(chunk))
        XCTAssertEqual(credit.offset, 1)
        XCTAssertEqual(credit.chunk, 1)
    }

    func testRemoteFilePacingSuspendsForQualityAndStaleVideo() {
        var pacing = RemoteFileMediaPacing()
        pacing.feedback(now: 0, presented: 0, queueAge: 0, drops: 0)
        pacing.received(bytes: 1_000_000)
        pacing.feedback(now: 1, presented: 10, queueAge: 0, drops: 0)
        XCTAssertEqual(pacing.rate(now: 1, unsettled: false), 100_000)
        XCTAssertEqual(pacing.rate(now: 1, unsettled: true), 0)
        XCTAssertEqual(pacing.rate(now: 4, unsettled: false), 0)
    }

    #if targetEnvironment(simulator)
    @MainActor func testRemoteFileRealWriterKeepsGrantDuringUIPauseAndReleasesOnBackground() async throws {
        let network = NetworkManager()
        let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        defer { network.stopForTesting() }
        var writes: [Data] = []
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 0x103, requestRemoteFiles: true)
        let context = RemoteInputContextCommand(state: 1, desktop: 1, token: 12, desktopEpoch: 1,
            left: 0, top: 0, width: 100, height: 100)
        network.receiveRemoteMonitorContextForTesting(context, keyframe: true)
        let published = expectation(description: "Authenticated remote connection published")
        let observation = network.$isRemoteControlSession.first(where: { $0 }).sink { _ in published.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [published], timeout: 15) == .completed else {
            return XCTFail("Remote role missing after authentication")
        }

        let scope = network.transferActionScope
        network.requestRemoteFiles(scope: scope)
        for _ in 0..<3 { network.networkQueueForTesting.sync {} }
        func controls() -> [RemoteFileProtocol.Message] {
            network.networkQueueForTesting.sync {
                writes.filter { $0[5] == 100 }.compactMap {
                    RemoteFileProtocol.decode(type: .remoteFileControl, payload: Data($0.dropFirst(16)), flags: 0)
                }
            }
        }
        guard case let .control(.requestGrant, request, .both, _)? = controls().first else {
            return XCTFail("Expected RequestGrant on the authenticated writer")
        }
        let grant = UUID()
        let reply = RemoteFileProtocol.Message.state(phase: .granted, requestId: request, reason: .none,
                                                     directions: .both, grantId: grant)
        network.receiveMirrorWireForTesting(type: .remoteFileState, payload: try XCTUnwrap(RemoteFileProtocol.encode(reply)),
                                            generation: owner.generation, connection: owner.connection)
        for _ in 0..<3 { network.networkQueueForTesting.sync {} }
        let input = RemoteSessionInputState()
        input.bind(network)
        func inputConfiguration(_ active: Bool) -> RemoteSessionInputConfiguration {
            .init(remote: true, connected: true, active: active, generation: owner.generation,
                features: 0x103, context: context, ready: true, revision: 1)
        }
        input.configure(inputConfiguration(true))
        input.configure(inputConfiguration(false))
        for _ in 0..<3 { network.networkQueueForTesting.sync {} }
        XCTAssertFalse(input.pointerEnabled)
        XCTAssertEqual(controls().count, 2)
        let sentFocusReset = network.networkQueueForTesting.sync {
            writes.contains { $0[5] == WireMessageType.remoteInputReset.rawValue &&
                RemoteInputResetCommand.decode(Data($0.dropFirst(16)))?.reason == 0 }
        }
        XCTAssertTrue(sentFocusReset)
        network.backgroundRemoteFilesForTesting()
        for _ in 0..<3 { network.networkQueueForTesting.sync {} }
        guard case let .control(.release, _, _, released)? = controls().last else {
            return XCTFail("Background must release the grant")
        }
        XCTAssertEqual(released, grant)
        XCTAssertNotEqual(network.transferActionScope, scope)
        network.requestRemoteFiles(scope: scope)
        for _ in 0..<3 { network.networkQueueForTesting.sync {} }
        XCTAssertEqual(controls().count, 3)
    }

    func testRemoteFileFakeHostUploadWaitsForCreditAndResendStartsAtZero() throws {
        guard case let .packet(grant, fixtureResponse) = try goldenFile("file-response") else {
            return XCTFail("Expected fixture response")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.bin")
        try Data(repeating: 0x55, count: 4097).write(to: source)
        var sent: [TransferPacket] = []
        let manager = DataTransferManager(generation: 4, directory: root.appendingPathComponent("received"),
                                          remoteWindowSender: { _, done in XCTFail("Upload must not grant credit"); done(false) }) { packet, done in
            let data = RemoteFileProtocol.encode(.packet(grantId: grant, transfer: packet))
            if let data, case let .packet(_, decoded)? = RemoteFileProtocol.decode(type: .remoteFilePacket, payload: data, flags: 0) {
                sent.append(decoded)
                done(true)
            } else { XCTFail("Invalid wire packet"); done(false) }
        }
        defer { manager.retire(); manager.drainRemoteIOForTesting() }
        manager.sendFiles([source])
        manager.drainRemoteIOForTesting()
        let first = try XCTUnwrap(sent.first)
        var accepted = TransferPacket(kind: fixtureResponse.kind, generation: first.generation, id: first.id)
        accepted.accepted = fixtureResponse.accepted
        XCTAssertTrue(try postFakeFileMessage(.packet(grantId: grant, transfer: accepted), to: manager))
        manager.drainRemoteIOForTesting()
        XCTAssertEqual(sent.map(\.kind), [.offer])
        func credit(_ offer: UUID, consumed: UInt64, limit: UInt64, chunks: UInt64) throws {
            XCTAssertTrue(try postFakeFileMessage(.window(grantId: grant, offerId: offer, fileIndex: 0,
                consumedOffset: consumed, maxOffset: limit, maxChunkIndexExclusive: chunks), to: manager))
        }
        try credit(first.id, consumed: 0, limit: 4096, chunks: 1)
        for _ in 0..<4 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(sent.map(\.kind), [.offer, .chunk])
        XCTAssertEqual(sent.last?.bytes.count, 4096)
        try credit(first.id, consumed: 4096, limit: 4097, chunks: 2)
        for _ in 0..<4 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(sent.map(\.kind), [.offer, .chunk, .chunk, .fileEnd])
        XCTAssertEqual(sent.filter { $0.kind == .chunk }.map(\.offset), [0, 4096])
        manager.cancel()
        manager.drainRemoteIOForTesting()
        manager.retryRemoteFiles()
        manager.drainRemoteIOForTesting()
        let second = try XCTUnwrap(sent.last)
        XCTAssertEqual(second.kind, .offer)
        XCTAssertNotEqual(second.id, first.id)
        accepted = TransferPacket(kind: .response, generation: second.generation, id: second.id, accepted: true)
        XCTAssertTrue(try postFakeFileMessage(.packet(grantId: grant, transfer: accepted), to: manager))
        try credit(second.id, consumed: 0, limit: 1, chunks: 1)
        manager.drainRemoteIOForTesting()
        XCTAssertEqual(sent.last?.kind, .chunk)
        XCTAssertEqual(sent.last?.offset, 0)
    }

    private func fakeFileWire(_ message: RemoteFileProtocol.Message) throws -> RemoteFileProtocol.Message {
        let bytes = try XCTUnwrap(RemoteFileProtocol.encode(message))
        return try XCTUnwrap(RemoteFileProtocol.decode(type: message.type, payload: bytes, flags: 0))
    }

    private func postFakeFileMessage(_ message: RemoteFileProtocol.Message, to manager: DataTransferManager) throws -> Bool {
        switch try fakeFileWire(message) {
        case let .packet(_, packet):
            return manager.post(packet)
        case let .window(_, offer, file, consumed, limit, chunks):
            return manager.postRemoteFileWindow(.init(offer: offer, file: file, consumed: consumed, limit: limit, chunks: chunks)) {}
        default:
            XCTFail("Expected DS5 transfer data")
            return false
        }
    }

    func testRemoteFileFakeHostUploadFillsTwoSlotsBeforeAcknowledgment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.bin"), grant = UUID()
        let payload = Data(repeating: 1, count: 8192) + Data(repeating: 2, count: 8192) + Data([3])
        try payload.write(to: source)
        var sent: [TransferPacket] = []
        var windows: [DataTransferManager.FileWindow] = []
        var completed: DataTransferManager.Snapshot?
        var manager: DataTransferManager!
        manager = DataTransferManager(generation: 4, directory: root.appendingPathComponent("received"),
            remoteWindowSender: { window, done in
                windows.append(window)
                done(manager.authorizeRemoteWindow(window, beginWrite: true))
            }) { packet, done in
            if case let .packet(_, decoded)? = try? self.fakeFileWire(.packet(grantId: grant, transfer: packet)) {
                sent.append(decoded)
                done(true)
            } else { XCTFail("Invalid wire packet"); done(false) }
        }
        defer { manager.retire(); manager.drainRemoteIOForTesting(); manager = nil }
        manager.drainRemoteIOForTesting()
        manager.changed = { if $0.phase == .completed { completed = $0 } }
        manager.sendFiles([source])
        manager.drainRemoteIOForTesting()
        let offer = try XCTUnwrap(sent.first)
        func reply(_ kind: TransferKind) throws {
            let packet = TransferPacket(kind: kind, generation: offer.generation, id: offer.id, accepted: kind == .response)
            XCTAssertTrue(try postFakeFileMessage(.packet(grantId: grant, transfer: packet), to: manager))
        }
        func credit(consumed: UInt64, limit: UInt64, chunks: UInt64) throws {
            XCTAssertTrue(try postFakeFileMessage(.window(grantId: grant, offerId: offer.id, fileIndex: 0,
                consumedOffset: consumed, maxOffset: limit, maxChunkIndexExclusive: chunks), to: manager))
            for _ in 0..<4 { manager.drainRemoteIOForTesting() }
        }
        try reply(.response)
        try credit(consumed: 0, limit: 16384, chunks: 2)
        XCTAssertEqual(sent.map(\.kind), [.offer, .chunk, .chunk])
        XCTAssertEqual(sent.dropFirst().map(\.offset), [0, 8192])
        XCTAssertEqual(sent.dropFirst().map { $0.bytes.count }, [8192, 8192])
        try credit(consumed: 8192, limit: 16385, chunks: 3)
        XCTAssertEqual(sent.map(\.kind), [.offer, .chunk, .chunk, .chunk, .fileEnd])
        XCTAssertEqual(sent.filter { $0.kind == .chunk }.reduce(into: Data()) { $0.append($1.bytes) }, payload)
        XCTAssertEqual(sent.last?.bytes, Data(SHA256.hash(data: payload)))
        try reply(.fileAck)
        try reply(.ack)
        manager.drainRemoteIOForTesting()
        XCTAssertEqual(sent.last?.kind, .end)
        XCTAssertEqual(completed?.bytes, UInt64(payload.count))

        var download = TransferPacket(kind: .offer, generation: offer.generation, id: UUID())
        download.files = [.init(name: "download.bin", length: 32768)]
        XCTAssertTrue(try postFakeFileMessage(.packet(grantId: grant, transfer: download), to: manager))
        manager.drainRemoteIOForTesting()
        manager.decide(true, consent: try XCTUnwrap(manager.consentForTesting()))
        for _ in 0..<3 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(windows.first, .init(offer: download.id, file: 0, consumed: 0, limit: 16384, chunks: 2))
    }

    func testRemoteFileFakeHostDownloadExpandsAndKeepsAlreadyAdmittedChunk() throws {
        try checkFakeFileDownload(chunkBytes: 8192)
    }

    func testRemoteFileFakeHostLegacyDownloadKeepsOneSlot() throws {
        try checkFakeFileDownload(chunkBytes: 4096)
    }

    private func checkFakeFileDownload(chunkBytes: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = UUID(), id = UUID(), generation: UInt64 = 7
        let payload = Data(repeating: 0xa5, count: 32768)
        let wide = chunkBytes == 8192
        let chunks = (0..<(payload.count / chunkBytes)).map { index in
            let start = index * chunkBytes
            return TransferPacket(kind: .chunk, generation: generation, id: id, chunkIndex: UInt64(index),
                                  offset: UInt64(start), bytes: payload.subdata(in: start..<(start + chunkBytes)))
        }
        var windows: [DataTransferManager.FileWindow] = []
        var sent: [TransferPacket] = []
        var completed: DataTransferManager.Snapshot?
        var manager: DataTransferManager!
        func deliver(_ packet: TransferPacket) throws -> Bool {
            try postFakeFileMessage(.packet(grantId: grant, transfer: packet), to: manager)
        }
        manager = DataTransferManager(generation: generation, directory: root, remoteWindowSender: { window, done in
            do {
                let message = RemoteFileProtocol.Message.window(grantId: grant, offerId: window.offer, fileIndex: window.file,
                    consumedOffset: window.consumed, maxOffset: window.limit, maxChunkIndexExclusive: window.chunks)
                guard case let .window(_, offer, file, consumed, limit, slots) = try self.fakeFileWire(message) else {
                    XCTFail("Expected DS5 credit"); done(false); return
                }
                // Deliver chunk 2 under the preceding window before the replacement starts writing.
                let burst = wide && consumed == 16384 && slots == 4
                if burst { XCTAssertTrue(try deliver(chunks[2])) }
                XCTAssertTrue(manager.authorizeRemoteWindow(window, beginWrite: true))
                windows.append(.init(offer: offer, file: file, consumed: consumed, limit: limit, chunks: slots))
                if burst { XCTAssertTrue(try deliver(chunks[3])) }
                done(true)
            } catch { XCTFail("Invalid wire window"); done(false) }
        }) { packet, done in
            if case let .packet(_, decoded)? = try? self.fakeFileWire(.packet(grantId: grant, transfer: packet)) {
                sent.append(decoded)
                done(true)
            } else { XCTFail("Invalid wire packet"); done(false) }
        }
        defer { manager.retire(); manager.drainRemoteIOForTesting(); manager = nil }
        manager.drainRemoteIOForTesting()
        manager.changed = { if $0.phase == .completed { completed = $0 } }
        func drain() { for _ in 0..<4 { manager.drainRemoteIOForTesting() } }
        var offer = TransferPacket(kind: .offer, generation: generation, id: id)
        offer.files = [.init(name: "sample.bin", length: UInt64(payload.count))]
        XCTAssertTrue(try deliver(offer))
        drain()
        manager.decide(true, consent: try XCTUnwrap(manager.consentForTesting()))
        drain()
        XCTAssertEqual(windows, [.init(offer: id, file: 0, consumed: 0, limit: 8192, chunks: 1)])
        XCTAssertTrue(try deliver(chunks[0]))
        drain()
        if wide {
            let widened = DataTransferManager.FileWindow(offer: id, file: 0, consumed: 8192, limit: 24576, chunks: 3)
            XCTAssertEqual(windows.last, widened)
            guard windows.last == widened else { return }
            XCTAssertTrue(try deliver(chunks[1]))
            drain()
        } else {
            for chunk in chunks.dropFirst() {
                XCTAssertEqual(windows.last?.chunks, chunk.chunkIndex + 1)
                XCTAssertTrue(try deliver(chunk))
                drain()
            }
        }
        let end = TransferPacket(kind: .fileEnd, generation: generation, id: id, offset: UInt64(payload.count),
                                 bytes: Data(SHA256.hash(data: payload)))
        XCTAssertTrue(try deliver(end))
        drain()
        XCTAssertEqual(sent.last?.kind, .fileAck)
        XCTAssertTrue(try deliver(.init(kind: .end, generation: generation, id: id)))
        drain()
        XCTAssertEqual(sent.last?.kind, .ack)
        XCTAssertEqual(completed?.bytes, UInt64(payload.count))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(completed?.received.first)), payload)
    }

    func testRemoteFileFakeHostDownloadsOnlyAfterCurrentConsentAndCleansRevokedStage() throws {
        guard case let .packet(grant, template) = try goldenFile("file-offer"),
              case let .packet(_, chunk) = try goldenFile("file-chunk") else { return XCTFail("Expected fixture packets") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func stages(for id: UUID) throws -> [URL] {
            let files = FileManager.default
            return try files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".scdt-\(id.uuidString)-") && $0.pathExtension == "part" }
        }
        var manager: DataTransferManager!
        var events: [String] = []
        var published: [URL] = []
        manager = DataTransferManager(generation: 7, directory: root, remoteWindowSender: { window, done in
            let message = RemoteFileProtocol.Message.window(grantId: grant, offerId: window.offer, fileIndex: window.file,
                consumedOffset: window.consumed, maxOffset: window.limit, maxChunkIndexExclusive: window.chunks)
            XCTAssertNotNil(RemoteFileProtocol.encode(message))
            if window.consumed == 1 {
                let activeStages = try? stages(for: window.offer)
                XCTAssertEqual(activeStages?.count, 1)
                let stage = activeStages?.first
                XCTAssertEqual(stage.flatMap { try? Data(contentsOf: $0) }, chunk.bytes)
            }
            XCTAssertTrue(manager.authorizeRemoteWindow(window, beginWrite: true))
            events.append("credit-\(window.consumed)")
            done(true)
        }) { packet, done in
            XCTAssertNotNil(RemoteFileProtocol.encode(.packet(grantId: grant, transfer: packet)))
            events.append("\(packet.kind)")
            done(true)
        }
        manager.changed = { if $0.phase == .completed { published = $0.received } }
        defer { manager.retire(); manager.drainRemoteIOForTesting(); manager = nil }
        var offer = template
        offer.files = [.init(name: "sample.bin", length: 2)]
        XCTAssertTrue(manager.post(offer))
        manager.drainRemoteIOForTesting()
        let consent = try XCTUnwrap(manager.consentForTesting())
        manager.decide(true, consent: .init(sessionID: consent.sessionID, transferID: UUID()))
        manager.drainRemoteIOForTesting()
        XCTAssertTrue(events.isEmpty)
        manager.decide(true, consent: consent)
        for _ in 0..<3 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(events, ["response", "credit-0"])
        XCTAssertTrue(manager.post(chunk))
        manager.drainRemoteIOForTesting()
        XCTAssertEqual(events, ["response", "credit-0", "credit-1"])
        var secondChunk = chunk
        secondChunk.chunkIndex = 1
        secondChunk.offset = 1
        XCTAssertTrue(manager.post(secondChunk))
        manager.drainRemoteIOForTesting()
        var last = TransferPacket(kind: .fileEnd, generation: offer.generation, id: offer.id)
        last.offset = 2
        last.bytes = Data(SHA256.hash(data: chunk.bytes + secondChunk.bytes))
        XCTAssertTrue(manager.post(last))
        manager.drainRemoteIOForTesting()
        XCTAssertEqual(events.last, "fileAck")
        XCTAssertTrue(manager.post(.init(kind: .end, generation: offer.generation, id: offer.id)))
        for _ in 0..<3 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(events.last, "ack")
        let saved = try XCTUnwrap(published.first)
        XCTAssertEqual(try Data(contentsOf: saved), chunk.bytes + secondChunk.bytes)

        var interrupted = TransferPacket(kind: .offer, generation: offer.generation, id: UUID())
        interrupted.files = [.init(name: "interrupted.bin", length: 2)]
        XCTAssertTrue(manager.post(interrupted))
        manager.drainRemoteIOForTesting()
        manager.decide(true, consent: try XCTUnwrap(manager.consentForTesting()))
        for _ in 0..<3 { manager.drainRemoteIOForTesting() }
        XCTAssertEqual(try stages(for: interrupted.id).count, 1)
        manager.retire()
        manager.drainRemoteIOForTesting()
        XCTAssertTrue(try stages(for: interrupted.id).isEmpty)
        XCTAssertFalse(manager.post(chunk))
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(urls.contains(saved))
        XCTAssertFalse(urls.contains { $0.pathExtension == "part" || $0.lastPathComponent == "interrupted.bin" })
    }

    func testRemoteFileQuotaUsesSharedRetainedLimits() {
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 256, bytes: 0,
            incomingCount: 1, incomingBytes: 1, availableCapacity: nil))
        XCTAssertThrowsError(try DataTransferManager.validateRetainedQuota(count: 0, bytes: 8 << 30,
            incomingCount: 1, incomingBytes: 1, availableCapacity: nil))
        XCTAssertNoThrow(try DataTransferManager.validateRetainedQuota(count: 255, bytes: (8 << 30) - 1,
            incomingCount: 1, incomingBytes: 1, availableCapacity: nil))
    }
    #endif
}
