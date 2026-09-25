import XCTest
@testable import iPadCasting

final class HevcRtpReassemblerTests: XCTestCase {
    func testFixedHeaderAndReorderedFuReassembleCanonicalBytes() {
        let vps = nal(type: 32, count: 20, fill: 0x11)
        let sps = nal(type: 33, count: 20, fill: 0x12)
        let pps = nal(type: 34, count: 20, fill: 0x13)
        let idr = nal(type: 19, count: 2_000, fill: 0x22)
        let first = idr.subdata(in: 2..<1_171)
        let second = idr.subdata(in: 1_171..<idr.count)
        let packets = [
            packet(
                sequence: UInt16.max - 3, timestamp: 9, frame: 41,
                capture: 99, marker: false, payload: vps),
            packet(
                sequence: UInt16.max - 2, timestamp: 9, frame: 41,
                capture: 99, marker: false, payload: sps),
            packet(
                sequence: UInt16.max - 1, timestamp: 9, frame: 41,
                capture: 99, marker: false, payload: pps),
            packet(
                sequence: UInt16.max, timestamp: 9, frame: 41,
                capture: 99, marker: false,
                payload: fu(idr, bytes: first, start: true, end: false)),
            packet(
                sequence: 0, timestamp: 9, frame: 41,
                capture: 99, marker: true,
                payload: fu(idr, bytes: second, start: false, end: true))
        ]
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1_200 })
        let reassembler = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: UInt16.max - 3)
        var outcome: HevcReassemblyOutcome = .accepted
        for packet in packets.reversed() {
            outcome = reassembler.consume(
                packet,
                authentication: .authenticated,
                arrivalTime: 1,
                rttP95Ms: 4)
        }
        XCTAssertEqual(
            outcome,
            .completed(
                accessUnit: canonical(vps, sps, pps, idr),
                frameSequence: 41,
                captureTime90k: 99))
        XCTAssertEqual(reassembler.allocatedFrameCount, 0)
    }

    func testAuthenticationDuplicateMissingExpiryAndDeadlineBound() {
        let payload = nal(type: 32, count: 20, fill: 1)
        let one = packet(
            sequence: UInt16.max,
            timestamp: UInt32.max,
            frame: 1,
            capture: UInt32.max,
            marker: false,
            payload: payload)
        let reassembler = HevcRtpReassembler(mtu: 1_200)
        XCTAssertEqual(
            reassembler.consume(
                one,
                authentication: .failed,
                arrivalTime: 0,
                rttP95Ms: 4),
            .authenticationFailure)
        XCTAssertEqual(reassembler.allocatedFrameCount, 0)
        XCTAssertEqual(
            reassembler.consume(
                one,
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 4),
            .accepted)
        XCTAssertEqual(
            reassembler.consume(
                one,
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 4),
            .duplicate)

        for timestamp: UInt32 in [2, 3] {
            _ = reassembler.consume(
                packet(
                    sequence: 1,
                    timestamp: timestamp,
                    frame: timestamp,
                    capture: 0,
                    marker: false,
                    payload: payload),
                authentication: .authenticated,
                arrivalTime: Double(timestamp) / 1_000,
                rttP95Ms: 4)
        }
        XCTAssertEqual(reassembler.allocatedFrameCount, 3)
        XCTAssertFalse(reassembler.expire(at: 0.020).isEmpty)
        XCTAssertEqual(reassembler.allocatedFrameCount, 0)
    }

    func testPartialPFrameCompletesAfterOtherFramesArriveBeforeDeadline() {
        let payload = nal(type: 1, count: 20, fill: 1)
        let reassembler = HevcRtpReassembler(
            mtu: 1_200, initialExpectedSequence: 10)
        for (sequence, timestamp, arrival, marker) in [
            (10, 1, 0.0, false), (12, 1, 0.001, true),
            (13, 2, 0.008, false), (14, 3, 0.016, false),
            (15, 4, 0.024, false)
        ] {
            _ = reassembler.consume(
                packet(sequence: UInt16(sequence), timestamp: UInt32(timestamp),
                       frame: UInt32(timestamp), capture: 0,
                       marker: marker, payload: payload),
                authentication: .authenticated, arrivalTime: arrival,
                rttP95Ms: 20)
        }
        XCTAssertEqual(reassembler.allocatedFrameCount, 4)
        let outcome = reassembler.consume(
            packet(sequence: 11, timestamp: 1, frame: 1, capture: 0,
                   marker: false, payload: payload),
            authentication: .authenticated, arrivalTime: 0.030,
            rttP95Ms: 20)
        let outcomes = [outcome] + reassembler.expire(at: 0.031)
        XCTAssertTrue(outcomes.contains(.completed(
            accessUnit: canonical(payload, payload, payload),
            frameSequence: 1, captureTime90k: 0)))
        XCTAssertFalse(outcomes.contains(.sequenceAnchorLost(expectedSequence: 10)))
    }

    func testPartialFrameExpiresAtItsActualDeadline() {
        let payload = nal(type: 1, count: 20, fill: 1)
        let reassembler = HevcRtpReassembler(
            mtu: 1_200, initialExpectedSequence: 10)
        for index in 0..<4 {
            _ = reassembler.consume(
                packet(sequence: UInt16(10 + index),
                       timestamp: UInt32(index + 1),
                       frame: UInt32(index + 1), capture: 0,
                       marker: false, payload: payload),
                authentication: .authenticated,
                arrivalTime: Double(index) * 0.008,
                rttP95Ms: 20)
        }
        XCTAssertEqual(reassembler.allocatedFrameCount, 4)
        XCTAssertTrue(reassembler.expire(at: 0.034).isEmpty)
        XCTAssertEqual(reassembler.allocatedFrameCount, 4)
        XCTAssertTrue(reassembler.expire(at: 0.035).contains(
            .expired(frameSequence: 1)))
        XCTAssertEqual(reassembler.allocatedFrameCount, 3)
    }

    func testIDRSurvivesOtherFramesUntilFiftyMillisecondDeadline() {
        let idr = nal(type: 19, count: 20, fill: 1)
        let payload = nal(type: 1, count: 20, fill: 2)
        let reassembler = HevcRtpReassembler(
            mtu: 1_200, initialExpectedSequence: 10)
        _ = reassembler.consume(
            packet(sequence: 10, timestamp: 1, frame: 1, capture: 0,
                   marker: false, payload: idr),
            authentication: .authenticated, arrivalTime: 0,
            rttP95Ms: 20)
        for index in 1...5 {
            _ = reassembler.consume(
                packet(sequence: UInt16(10 + index),
                       timestamp: UInt32(index + 1),
                       frame: UInt32(index + 1), capture: 0,
                       marker: false, payload: payload),
                authentication: .authenticated,
                arrivalTime: Double(index) * 0.008,
                rttP95Ms: 20)
        }
        XCTAssertEqual(reassembler.allocatedFrameCount, 6)
        XCTAssertFalse(reassembler.expire(at: 0.049).contains(
            .expired(frameSequence: 1)))
        XCTAssertTrue(reassembler.expire(at: 0.050).contains(
            .expired(frameSequence: 1)))
    }

    func testCapacityEvictsOldestOnlyAfterDeadlineExpiry() {
        let payload = nal(type: 1, count: 20, fill: 1)
        let reassembler = HevcRtpReassembler(
            mtu: 1_200, initialExpectedSequence: 10)
        for index in 0..<8 {
            _ = reassembler.consume(
                packet(sequence: UInt16(10 + index),
                       timestamp: UInt32(index + 1),
                       frame: UInt32(index + 1), capture: 0,
                       marker: false, payload: payload),
                authentication: .authenticated,
                arrivalTime: Double(index) * 0.001,
                rttP95Ms: 20)
            XCTAssertLessThanOrEqual(reassembler.allocatedFrameCount, 6)
        }
        XCTAssertEqual(reassembler.allocatedFrameCount, 6)
        _ = reassembler.consume(
            packet(sequence: 30, timestamp: 30, frame: 30, capture: 0,
                   marker: false, payload: payload),
            authentication: .authenticated, arrivalTime: 0.036,
            rttP95Ms: 20)
        XCTAssertLessThanOrEqual(reassembler.allocatedFrameCount, 6)
    }

    func testDeadlineFormulaIsExact() {
        XCTAssertEqual(
            ReassemblyDeadline.interval(rttP95Ms: 0, isIDR: false),
            0.012)
        XCTAssertEqual(
            ReassemblyDeadline.interval(rttP95Ms: 20, isIDR: false),
            0.035)
        XCTAssertEqual(
            ReassemblyDeadline.interval(rttP95Ms: 1, isIDR: true),
            0.050)
    }

    func testMarkerFirstCompletesWhenLeadingFragmentArrives() {
        let idr = nal(type: 19, count: 40, fill: 3)
        let first = idr.subdata(in: 2..<20)
        let last = idr.subdata(in: 20..<idr.count)
        let reassembler = HevcRtpReassembler(mtu: 1_200)
        XCTAssertEqual(
            reassembler.consume(
                packet(
                    sequence: 2, timestamp: 8, frame: 8, capture: 0,
                    marker: true,
                    payload: fu(
                        idr, bytes: last, start: false, end: true)),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            reassembler.consume(
                packet(
                    sequence: 1, timestamp: 8, frame: 8, capture: 0,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 8,
                captureTime90k: 0))
        XCTAssertEqual(
            reassembler.expire(at: 0.051),
            [])
    }

    func testInitialSingleNalAndFuOnlyInOrderDoNotStall() {
        let single = nal(type: 32, count: 20, fill: 1)
        let singleReceiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 5)
        XCTAssertEqual(
            singleReceiver.consume(
                packet(
                    sequence: 5, timestamp: 1, frame: 1, capture: 0,
                    marker: true, payload: single),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(single),
                frameSequence: 1,
                captureTime90k: 0))

        let idr = nal(type: 19, count: 40, fill: 2)
        let first = idr.subdata(in: 2..<20)
        let last = idr.subdata(in: 20..<idr.count)
        let fuReceiver = HevcRtpReassembler(mtu: 1_200)
        XCTAssertEqual(
            fuReceiver.consume(
                packet(
                    sequence: 8, timestamp: 2, frame: 2, capture: 1,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            fuReceiver.consume(
                packet(
                    sequence: 9, timestamp: 2, frame: 2, capture: 1,
                    marker: true,
                    payload: fu(
                        idr, bytes: last, start: false, end: true)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 2,
                captureTime90k: 1))
    }

    func testExpectedSequenceCarriesAcrossFramesAndWraps() {
        let reassembler = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: UInt16.max)
        let vps = nal(type: 32, count: 20, fill: 1)
        XCTAssertEqual(
            reassembler.consume(
                packet(
                    sequence: UInt16.max,
                    timestamp: 1,
                    frame: 1,
                    capture: 0,
                    marker: true,
                    payload: vps),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(vps),
                frameSequence: 1,
                captureTime90k: 0))

        let idr = nal(type: 19, count: 40, fill: 2)
        let first = idr.subdata(in: 2..<20)
        let last = idr.subdata(in: 20..<idr.count)
        XCTAssertEqual(
            reassembler.consume(
                packet(
                    sequence: 1, timestamp: 2, frame: 2, capture: 1,
                    marker: true,
                    payload: fu(
                        idr, bytes: last, start: false, end: true)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            reassembler.consume(
                packet(
                    sequence: 0, timestamp: 2, frame: 2, capture: 1,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.002,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 2,
                captureTime90k: 1))
    }

    func testMismatchedFuIdentityIsMalformed() {
        for mutation in 0..<3 {
            let (reassembler, idr) = anchoredReassembler()
            let first = idr.subdata(in: 2..<20)
            let last = idr.subdata(in: 20..<idr.count)
            _ = reassembler.consume(
                packet(
                    sequence: 10, timestamp: 2, frame: 2, capture: 0,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1)
            var end = fu(
                idr, bytes: last, start: false, end: true)
            if mutation == 0 { end[2] ^= 1 }
            if mutation == 1 { end[0] ^= 1 }
            if mutation == 2 { end[1] ^= 1 }
            XCTAssertEqual(
                reassembler.consume(
                    packet(
                        sequence: 11, timestamp: 2, frame: 2, capture: 0,
                        marker: true, payload: end),
                    authentication: .authenticated,
                    arrivalTime: 0.002,
                    rttP95Ms: 1),
                .sequenceAnchorLost(expectedSequence: 10))
            XCTAssertEqual(reassembler.drainOutcome(), .malformed)
        }
    }

    func testDuplicateStartAndPrematureEndTrailingAreMalformed() {
        do {
            let (reassembler, idr) = anchoredReassembler()
            let first = idr.subdata(in: 2..<20)
            _ = reassembler.consume(
                packet(
                    sequence: 10, timestamp: 2, frame: 2, capture: 0,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1)
            XCTAssertEqual(
                reassembler.consume(
                    packet(
                        sequence: 11, timestamp: 2, frame: 2, capture: 0,
                        marker: true,
                        payload: fu(
                            idr, bytes: first, start: true, end: true)),
                    authentication: .authenticated,
                    arrivalTime: 0.002,
                    rttP95Ms: 1),
                .sequenceAnchorLost(expectedSequence: 10))
            XCTAssertEqual(reassembler.drainOutcome(), .malformed)
        }
        do {
            let (reassembler, idr) = anchoredReassembler()
            let chunk = idr.subdata(in: 2..<15)
            _ = reassembler.consume(
                packet(
                    sequence: 10, timestamp: 2, frame: 2, capture: 0,
                    marker: false,
                    payload: fu(
                        idr, bytes: chunk, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1)
            _ = reassembler.consume(
                packet(
                    sequence: 11, timestamp: 2, frame: 2, capture: 0,
                    marker: false,
                    payload: fu(
                        idr, bytes: chunk, start: false, end: true)),
                authentication: .authenticated,
                arrivalTime: 0.002,
                rttP95Ms: 1)
            XCTAssertEqual(
                reassembler.consume(
                    packet(
                        sequence: 12, timestamp: 2, frame: 2, capture: 0,
                        marker: true,
                        payload: fu(
                            idr, bytes: chunk, start: false, end: false)),
                    authentication: .authenticated,
                    arrivalTime: 0.003,
                    rttP95Ms: 1),
                .sequenceAnchorLost(expectedSequence: 10))
            XCTAssertEqual(reassembler.drainOutcome(), .malformed)
        }
    }

    func testBufferedNextFrameCompletesImmediatelyAfterAnchorAdvances() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let next = nal(type: 1, count: 20, fill: 4)
        let nextPacket = packet(
            sequence: 12, timestamp: 2, frame: 2, capture: 2,
            marker: true, payload: next)
        XCTAssertEqual(
            receiver.consume(
                nextPacket,
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .accepted)

        let idr = nal(type: 19, count: 40, fill: 2)
        let first = idr.subdata(in: 2..<20)
        let last = idr.subdata(in: 20..<idr.count)
        _ = receiver.consume(
            packet(
                sequence: 11, timestamp: 1, frame: 1, capture: 1,
                marker: true,
                payload: fu(
                    idr, bytes: last, start: false, end: true)),
            authentication: .authenticated,
            arrivalTime: 0.001,
            rttP95Ms: 1)
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 10, timestamp: 1, frame: 1, capture: 1,
                    marker: false,
                    payload: fu(
                        idr, bytes: first, start: true, end: false)),
                authentication: .authenticated,
                arrivalTime: 0.002,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 1,
                captureTime90k: 1))
        XCTAssertEqual(receiver.pendingOutcomeCount, 1)
        XCTAssertEqual(
            receiver.drainOutcome(),
            .completed(
                accessUnit: canonical(next),
                frameSequence: 2,
                captureTime90k: 2))
        XCTAssertEqual(receiver.pendingOutcomeCount, 0)
    }

    func testMalformedAnchoredFrameAdvancesToBufferedValidFrame() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let valid = nal(type: 1, count: 20, fill: 5)
        _ = receiver.consume(
            packet(
                sequence: 12, timestamp: 2, frame: 2, capture: 2,
                marker: true, payload: valid),
            authentication: .authenticated,
            arrivalTime: 0,
            rttP95Ms: 1)

        let idr = nal(type: 19, count: 40, fill: 2)
        let first = idr.subdata(in: 2..<20)
        let last = idr.subdata(in: 20..<idr.count)
        _ = receiver.consume(
            packet(
                sequence: 10, timestamp: 1, frame: 1, capture: 1,
                marker: false,
                payload: fu(
                    idr, bytes: first, start: true, end: false)),
            authentication: .authenticated,
            arrivalTime: 0.001,
            rttP95Ms: 1)
        var mismatched = fu(
            idr, bytes: last, start: false, end: true)
        mismatched[2] ^= 1
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 11, timestamp: 1, frame: 1, capture: 1,
                    marker: true, payload: mismatched),
                authentication: .authenticated,
                arrivalTime: 0.002,
                rttP95Ms: 1),
            .sequenceAnchorLost(expectedSequence: 10))
        XCTAssertEqual(receiver.drainOutcome(), .malformed)
        XCTAssertNil(receiver.drainOutcome())
        XCTAssertLessThanOrEqual(receiver.pendingOutcomeCount, 2)
    }

    func testPendingExpiryIsDeliveredBeforeDuplicateOutcome() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let vpsPacket = packet(
            sequence: 10, timestamp: 1, frame: 1, capture: 0,
            marker: false,
            payload: nal(type: 32, count: 20, fill: 1))
        let idrPacket = packet(
            sequence: 20, timestamp: 2, frame: 2, capture: 0,
            marker: false,
            payload: fu(
                nal(type: 19, count: 40, fill: 2),
                bytes: Data(repeating: 2, count: 10),
                start: true,
                end: false))
        _ = receiver.consume(
            vpsPacket,
            authentication: .authenticated,
            arrivalTime: 0,
            rttP95Ms: 0)
        _ = receiver.consume(
            idrPacket,
            authentication: .authenticated,
            arrivalTime: 0,
            rttP95Ms: 0)

        XCTAssertEqual(
            receiver.consume(
                idrPacket,
                authentication: .authenticated,
                arrivalTime: 0.020,
                rttP95Ms: 0),
            .sequenceAnchorLost(expectedSequence: 10))
        XCTAssertEqual(receiver.drainOutcome(), .expired(frameSequence: 1))
        XCTAssertLessThanOrEqual(receiver.pendingOutcomeCount, 2)
    }

    func testWholeFrameLossReanchorsOnlyOnFreshIDRBeforeSequenceWrap() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let anchor = nal(type: 32, count: 20, fill: 1)
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 10, timestamp: 1, frame: 1, capture: 1,
                    marker: true, payload: anchor),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(anchor),
                frameSequence: 1,
                captureTime90k: 1))

        // Sequence 11 is wholly lost. A later dependent frame proves the old
        // anchor cannot be satisfied, then expires far before UInt16 wrap.
        let dependent = nal(type: 1, count: 20, fill: 2)
        _ = receiver.consume(
            packet(
                sequence: 12, timestamp: 2, frame: 2, capture: 2,
                marker: true, payload: dependent),
            authentication: .authenticated,
            arrivalTime: 0.001,
            rttP95Ms: 1)
        XCTAssertEqual(
            receiver.expire(at: 0.020),
            [
                .sequenceAnchorLost(expectedSequence: 11),
                .expired(frameSequence: 2)
            ])

        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 13, timestamp: 3, frame: 3, capture: 3,
                    marker: true, payload: dependent),
                authentication: .authenticated,
                arrivalTime: 0.021,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            receiver.expire(at: 0.040),
            [.expired(frameSequence: 3)])

        let idr = nal(type: 19, count: 20, fill: 3)
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 14, timestamp: 4, frame: 4, capture: 4,
                    marker: true, payload: idr),
                authentication: .authenticated,
                arrivalTime: 0.041,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 4,
                captureTime90k: 4))
    }

    func testPartialAnchoredFrameLossRequiresFreshIDRBeforeDependentFrameCanComplete() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let dependent = nal(type: 1, count: 40, fill: 2)

        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 10, timestamp: 1, frame: 1, capture: 1,
                    marker: false,
                    payload: fu(
                        dependent,
                        bytes: dependent.subdata(in: 2..<14),
                        start: true,
                        end: false)),
                authentication: .authenticated,
                arrivalTime: 0,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 12, timestamp: 1, frame: 1, capture: 1,
                    marker: true,
                    payload: fu(
                        dependent,
                        bytes: dependent.subdata(in: 28..<dependent.count),
                        start: false,
                        end: true)),
                authentication: .authenticated,
                arrivalTime: 0.001,
                rttP95Ms: 1),
            .accepted)
        XCTAssertEqual(
            receiver.expire(at: 0.020),
            [
                .sequenceAnchorLost(expectedSequence: 10),
                .expired(frameSequence: 1)
            ])

        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 13, timestamp: 2, frame: 2, capture: 2,
                    marker: true, payload: dependent),
                authentication: .authenticated,
                arrivalTime: 0.021,
                rttP95Ms: 1),
            .accepted)

        let idr = nal(type: 19, count: 20, fill: 3)
        XCTAssertEqual(
            receiver.consume(
                packet(
                    sequence: 14, timestamp: 3, frame: 3, capture: 3,
                    marker: true, payload: idr),
                authentication: .authenticated,
                arrivalTime: 0.022,
                rttP95Ms: 1),
            .completed(
                accessUnit: canonical(idr),
                frameSequence: 3,
                captureTime90k: 3))
    }

    func testAnchorLossSurvivesTwoFrameExpiryOutcomePressure() {
        let receiver = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 10)
        let dependent = nal(type: 1, count: 20, fill: 2)

        _ = receiver.consume(
            packet(
                sequence: 11, timestamp: 2, frame: 2, capture: 2,
                marker: true, payload: dependent),
            authentication: .authenticated,
            arrivalTime: 0,
            rttP95Ms: 1)
        _ = receiver.consume(
            packet(
                sequence: 12, timestamp: 3, frame: 3, capture: 3,
                marker: true, payload: dependent),
            authentication: .authenticated,
            arrivalTime: 0.001,
            rttP95Ms: 1)

        XCTAssertEqual(
            receiver.expire(at: 0.020),
            [
                .sequenceAnchorLost(expectedSequence: 10),
                .expired(frameSequence: 2),
                .expired(frameSequence: 3)
            ])
    }

    private func anchoredReassembler()
        -> (HevcRtpReassembler, Data)
    {
        let reassembler = HevcRtpReassembler(
            mtu: 1_200,
            initialExpectedSequence: 9)
        let vps = nal(type: 32, count: 20, fill: 1)
        _ = reassembler.consume(
            packet(
                sequence: 9, timestamp: 1, frame: 1, capture: 0,
                marker: true, payload: vps),
            authentication: .authenticated,
            arrivalTime: 0,
            rttP95Ms: 1)
        return (reassembler, nal(type: 19, count: 40, fill: 2))
    }

    private func nal(
        type: UInt8,
        count: Int,
        fill: UInt8
    ) -> Data {
        var data = Data(repeating: fill, count: count)
        data[0] = type << 1
        data[1] = 1
        return data
    }

    private func fu(
        _ nal: Data,
        bytes: Data,
        start: Bool,
        end: Bool
    ) -> Data {
        var result = Data([
            (nal[0] & 0x81) | (49 << 1),
            nal[1],
            (start ? 0x80 : 0) |
                (end ? 0x40 : 0) |
                ((nal[0] >> 1) & 0x3F)
        ])
        result.append(bytes)
        return result
    }

    private func packet(
        sequence: UInt16,
        timestamp: UInt32,
        frame: UInt32,
        capture: UInt32,
        marker: Bool,
        payload: Data
    ) -> Data {
        var data = Data(repeating: 0, count: 28)
        data[0] = 0x90
        data[1] = (marker ? 0x80 : 0) | 96
        put(sequence, in: &data, at: 2)
        put(timestamp, in: &data, at: 4)
        put(UInt32(0x10203040), in: &data, at: 8)
        put(UInt16(0xBEDE), in: &data, at: 12)
        put(UInt16(3), in: &data, at: 14)
        data[16] = 0x17
        put(frame, in: &data, at: 17)
        put(capture, in: &data, at: 21)
        data.append(payload)
        return data
    }

    private func canonical(_ nals: Data...) -> Data {
        var output = Data()
        for nal in nals {
            put(UInt32(nal.count), in: &output, at: output.count)
            output.append(nal)
        }
        return output
    }

    private func put<T: FixedWidthInteger>(
        _ value: T,
        in data: inout Data,
        at offset: Int
    ) {
        let width = MemoryLayout<T>.size
        if data.count < offset + width {
            data.append(Data(repeating: 0, count: offset + width - data.count))
        }
        for index in 0..<width {
            data[offset + index] = UInt8(
                truncatingIfNeeded: value >> ((width - 1 - index) * 8))
        }
    }
}
