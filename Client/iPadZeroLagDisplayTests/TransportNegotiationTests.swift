import XCTest
@testable import iPadCasting

final class WifiTransportNegotiationTests: XCTestCase {
    func testSessionIdentityDerivesExplicitMediaContract() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))

        let media = WifiMediaContract.mediaSsrc(sessionID)
        let feedback = WifiMediaContract.feedbackSsrc(sessionID)
        let request = WifiMediaContract.probeRequestSsrc(sessionID)
        let acknowledgement =
            WifiMediaContract.probeAcknowledgementSsrc(sessionID)
        XCTAssertEqual(media, 0x2d74465a)
        XCTAssertEqual(feedback, 0x6231041c)
        XCTAssertEqual(request, 0xb8ebcfca)
        XCTAssertEqual(acknowledgement, 0xfcbc8d94)
        XCTAssertEqual(Set([media, feedback, request, acknowledgement]).count, 4)
        XCTAssertNotEqual(
            request,
            acknowledgement,
            "identical sequence/ROC must still have distinct nonce inputs")
        XCTAssertEqual(
            WifiMediaContract.initialMediaSequence(sessionID),
            0x8899)
    }

    func testInvalidFirstProbeCandidateCannotLockOutValidFlow() {
        var gate = WifiProbeCandidateGate<Int>(limit: 2)

        XCTAssertTrue(gate.register(1).accepted)
        gate.reject(1)
        XCTAssertNil(gate.committed)

        XCTAssertTrue(gate.register(2).accepted)
        XCTAssertEqual(gate.authenticate(2), [])
        XCTAssertEqual(gate.committed, 2)
        XCTAssertFalse(gate.register(3).accepted)
    }

    func testProbeAcceptanceReplacesLegacyTimerWithCommitDeadline() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        XCTAssertTrue(gate.legacyFallbackAllowed)

        let token = try XCTUnwrap(gate.acceptProbe(sessionID: sessionID))
        XCTAssertFalse(
            gate.legacyFallbackAllowed,
            "probe near 750 ms left the legacy timer eligible")
        XCTAssertTrue(gate.timeout(sessionID: sessionID, token: token))
        XCTAssertFalse(
            gate.commit(sessionID: sessionID),
            "late commit was accepted after the post-probe deadline")
        XCTAssertNotNil(gate.fallbackToken)
        XCTAssertTrue(gate.commitLegacyFallback(sessionID: sessionID))
    }

    func testNormalCommitCancelsPostProbeDeadline() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        let token = try XCTUnwrap(gate.acceptProbe(sessionID: sessionID))

        XCTAssertTrue(gate.commit(sessionID: sessionID))
        XCTAssertFalse(
            gate.timeout(sessionID: sessionID, token: token),
            "commit did not cancel its post-probe deadline")
    }

    func testAckLossLeavesTimeForHostLegacyCommit() throws {
        XCTAssertGreaterThan(
            WifiTransportTiming.clientPostProbeCommitTimeoutMs,
            WifiTransportTiming.hostProbeTimeoutMs)
        XCTAssertGreaterThan(
            WifiTransportTiming.clientPostProbeCommitTimeoutMs,
            WifiTransportTiming.hostProbeTimeoutMs +
                WifiTransportTiming.controlDeliveryMarginMs,
            "client deadline can race ACK-loss legacy delivery")
    }

    func testMissingInitialCommitRequestsExactSessionFallbackThenAborts() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let wrongSession = try XCTUnwrap(
            SessionID(hex: "10112233445566778899aabbccddeeff"))
        var gate = WifiCommitGate()
        gate.begin(sessionID: sessionID)
        let initialToken = try XCTUnwrap(
            gate.acceptProbe(sessionID: sessionID))
        XCTAssertTrue(
            gate.timeout(sessionID: sessionID, token: initialToken))
        let fallbackToken = try XCTUnwrap(gate.fallbackToken)
        XCTAssertFalse(
            gate.commitLegacyFallback(sessionID: wrongSession))
        XCTAssertFalse(
            gate.fallbackTimeout(
                sessionID: sessionID,
                token: fallbackToken &+ 1))
        XCTAssertTrue(
            gate.fallbackTimeout(
                sessionID: sessionID,
                token: fallbackToken))
        XCTAssertFalse(
            gate.commitLegacyFallback(sessionID: sessionID))

        let request = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        XCTAssertEqual(
            request.encode().flatMap(TransportReady.decode),
            request)
        XCTAssertGreaterThan(
            WifiTransportTiming.clientFallbackCommitTimeoutMs,
            WifiTransportTiming.controlDeliveryMarginMs)
    }

    func testCommittedUdpFailureIsGenerationChecked() {
        XCTAssertTrue(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 9,
            connectionGeneration: 9,
            committedGeneration: 9))
        XCTAssertFalse(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 8,
            connectionGeneration: 9,
            committedGeneration: 9))
        XCTAssertFalse(WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: 9,
            connectionGeneration: 9,
            committedGeneration: nil))
    }

    func testAuthenticationFailureDoesNotMutateReassemblyOrDecoder() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var decoded: [(Data, UInt32, Bool)] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1200,
            initialSequence:
                WifiMediaContract.initialMediaSequence(sessionID),
            unprotect: { packet in packet.first != 0xff },
            decoder: { data, sequence, isIDR, _ in
                decoded.append((data, sequence, isIDR))
            })

        processor.consume(Data([0xff]), arrivalTime: 1)
        XCTAssertEqual(processor.authenticationFailures, 1)
        XCTAssertEqual(processor.allocatedFrameCount, 0)
        XCTAssertTrue(decoded.isEmpty)

        processor.consume(
            makeSingleNalPacket(
                sequence:
                    WifiMediaContract.initialMediaSequence(sessionID)),
            arrivalTime: 2)
        XCTAssertEqual(processor.authenticationFailures, 1)
        XCTAssertEqual(processor.allocatedFrameCount, 0)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].0, Data([0, 0, 0, 2, 0x26, 0x01]))
        XCTAssertEqual(decoded[0].1, 7)
        XCTAssertTrue(decoded[0].2)
    }

    private func makeSingleNalPacket(sequence: UInt16) -> Data {
        var packet = Data(count: RtpPacketView.headerLength + 2)
        packet[0] = 0x90
        packet[1] = 0x80 | 96
        storeBE16(sequence, in: &packet, at: 2)
        storeBE32(9, in: &packet, at: 4)
        storeBE32(0x2d74465a, in: &packet, at: 8)
        storeBE16(0xBEDE, in: &packet, at: 12)
        storeBE16(3, in: &packet, at: 14)
        packet[16] = 0x17
        storeBE32(7, in: &packet, at: 17)
        storeBE32(8, in: &packet, at: 21)
        packet[28] = 0x26
        packet[29] = 0x01
        return packet
    }

    private func storeBE16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private func storeBE32(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
