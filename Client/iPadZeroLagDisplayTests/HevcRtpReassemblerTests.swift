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

    func testAuthenticationDuplicateMissingExpiryAndTwoFrameBound() {
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
        XCTAssertEqual(reassembler.allocatedFrameCount, 2)
        XCTAssertFalse(reassembler.expire(at: 0.020).isEmpty)
        XCTAssertEqual(reassembler.allocatedFrameCount, 0)
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

    func testMarkerFirstMissingLeadingNalExpiresWithoutSuffix() {
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
            .accepted)
        XCTAssertEqual(
            reassembler.expire(at: 0.051),
            [.expired(frameSequence: 8)])
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
                .malformed)
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
                .malformed)
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
                .malformed)
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
            .malformed)
        XCTAssertEqual(
            receiver.drainOutcome(),
            .completed(
                accessUnit: canonical(valid),
                frameSequence: 2,
                captureTime90k: 2))
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
            .expired(frameSequence: 1))
        XCTAssertEqual(receiver.drainOutcome(), .duplicate)
        XCTAssertLessThanOrEqual(receiver.pendingOutcomeCount, 2)
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
