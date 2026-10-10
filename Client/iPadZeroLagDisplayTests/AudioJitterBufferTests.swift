import XCTest
@testable import iPadCasting

final class AudioJitterBufferTests: XCTestCase {
    func testAudioDiagnosticsSeparateTargetDropsOverflowAndConcealment() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        XCTAssertNil(buffer.dequeue())
        XCTAssertEqual(buffer.diagnostics.nilPlayoutActions, 1)
        [UInt16(1), 2, 3, 4].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
        XCTAssertEqual(buffer.diagnostics.overflowDrops, 0)
        XCTAssertEqual(buffer.diagnostics.decodeActions, 1)
        XCTAssertEqual(buffer.diagnostics.insertedPackets, 4)
        XCTAssertEqual(buffer.diagnostics.depthPercentiles.p95, 4)
        buffer.reset(profile: .usb)
        for sequence in UInt16(1)...7 { buffer.insert(packet(sequence)) }
        XCTAssertEqual(buffer.diagnostics.overflowDrops, 1)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
        XCTAssertEqual(buffer.diagnostics.maximumDepth, 6)
        XCTAssertEqual(buffer.profile, .usb)
        buffer.reset(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        _ = buffer.dequeue(); _ = buffer.dequeue(); _ = buffer.dequeue()
        buffer.insert(packet(5))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 4 * 480))
        XCTAssertEqual(buffer.diagnostics.plcActions, 1)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
    }

    func testAudioReceiveDiagnosticsClassifyRepairedGapAndWrap() {
        var rx = AudioReceiveDiagnostics()
        rx.record(sequence: 1, timestamp: 480, arrivedAt: 1)
        rx.record(sequence: 3, timestamp: 1440, arrivedAt: 1.02)
        rx.record(sequence: 2, timestamp: 960, arrivedAt: 1.025)
        XCTAssertEqual(rx.packets, 3)
        XCTAssertEqual(rx.forwardGaps, 1)
        XCTAssertEqual(rx.missingPacketUnits, 1)
        XCTAssertEqual(rx.reorderedPackets, 1)
        XCTAssertEqual(rx.repairedPacketUnits, 1)
        XCTAssertEqual(rx.duplicateOrStalePackets, 0)
        rx.record(sequence: 2, timestamp: 960, arrivedAt: 1.03)
        XCTAssertEqual(rx.duplicateOrStalePackets, 1)
        rx = AudioReceiveDiagnostics()
        for (index, sequence) in [UInt16.max, 0, 1].enumerated() {
            rx.record(sequence: sequence, timestamp: UInt32(index * 480), arrivedAt: 2 + Double(index) * 0.01)
        }
        XCTAssertEqual(rx.forwardGaps, 0)
        XCTAssertEqual(rx.reorderedPackets, 0)
        XCTAssertEqual(rx.jitterMs, 0, accuracy: 0.00001)
        XCTAssertEqual(rx.interarrivalP95Ms, 10, accuracy: 0.00001)
        XCTAssertEqual(rx.interarrivalMaxMs, 10, accuracy: 0.00001)
    }

    func testAudioPlayoutDiagnosticEventsAreIndependentAndMonotonic() {
        var counters = AudioPlayoutDiagnostics()
        counters.record(.tick); counters.record(.nilTick)
        counters.record(.decode); counters.record(.plc)
        counters.record(.decodeFailure); counters.record(.pcmRejected)
        counters.record(.pcmScheduled, frames: 480)
        counters.record(.playerStart); counters.record(.playerStart)
        XCTAssertEqual(counters.ticks, 1)
        XCTAssertEqual(counters.nilTicks, 1)
        XCTAssertEqual(counters.decodeActions, 1)
        XCTAssertEqual(counters.plcActions, 1)
        XCTAssertEqual(counters.decodeFailures, 1)
        XCTAssertEqual(counters.pcmQueueRejects, 1)
        XCTAssertEqual(counters.pcmBuffersScheduled, 1)
        XCTAssertEqual(counters.pcmFramesScheduled, 480)
        XCTAssertEqual(counters.playerStarts, 2)
        XCTAssertEqual(counters.playerRestarts, 1)
    }

    func testAudioDiagnosticsRejectDuplicatesAndStaleWithoutChangingPolicy() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(10)); buffer.insert(packet(10)); buffer.insert(packet(11))
        XCTAssertEqual(buffer.diagnostics.duplicateRejects, 1)
        _ = buffer.dequeue()
        buffer.insert(packet(9))
        XCTAssertEqual(buffer.diagnostics.staleRejects, 1)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
        XCTAssertEqual(buffer.targetDurationMs, 20)
    }
    func testReorderedPacketsPlayInSequence() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(102))
        buffer.insert(packet(101))
        buffer.insert(packet(103))

        XCTAssertEqual(decodedSequence(buffer.dequeue()), 101)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 102)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 103)
    }

    func testStartupReorderWindowCannotWalkBackwardCumulatively() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(102))
        buffer.insert(packet(96))
        buffer.insert(packet(90))
        buffer.insert(packet(103))

        XCTAssertEqual(buffer.bufferedPacketCount, 3)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 96)
    }

    func testStartupReorderWindowIsWrapSafeWithoutAliasing() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(2))
        buffer.insert(packet(UInt16.max - 3))
        buffer.insert(packet(UInt16.max - 9))

        XCTAssertEqual(buffer.bufferedPacketCount, 2)
        buffer.insert(packet(3))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), UInt16.max - 3)
    }

    func testStartupAnchorClearsAtPlayoutAndSessionReset() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(10), 11, 12].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 10)
        buffer.insert(packet(9))
        XCTAssertEqual(buffer.bufferedPacketCount, 2)

        buffer.reset()
        buffer.insert(packet(9))
        XCTAssertEqual(buffer.bufferedPacketCount, 1)
    }

    func testFullStartupBufferIncludesBackwardPacketInEviction() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(102), 103, 104, 105, 106, 107].forEach {
            buffer.insert(packet($0))
        }
        buffer.insert(packet(96))

        XCTAssertEqual(buffer.bufferedPacketCount, 6)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 102)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
    }

    func testSevenPacketsDropOldestAndRemainCappedAtSixtyMs() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        for sequence in UInt16(1)...UInt16(7) {
            buffer.insert(packet(sequence))
        }
        XCTAssertEqual(buffer.bufferedPacketCount, 6)
        XCTAssertEqual(buffer.bufferedDurationMs, 60)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
    }

    func testMissingPacketInvokesExactlyOneTenMsPlc() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 2)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 3)

        buffer.insert(packet(5))
        XCTAssertEqual(
            buffer.dequeue(),
            .plc(sequence: 4, timestamp: 4 * 480))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 5)
    }

    func testWifiTargetPlusOneRetainsOldestValidPacket() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3, 4].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
        XCTAssertEqual(buffer.droppedPacketCount, 0)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
    }

    func testWifiDepthFourToSixRetainsValidInOrderPackets() {
        for depth in 4...6 {
            let buffer = AudioJitterBuffer(profile: .wifi)
            for sequence in UInt16(1)...UInt16(depth) { buffer.insert(packet(sequence)) }
            for sequence in UInt16(1)...UInt16(depth) {
                XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence, "depth=\(depth)")
            }
            XCTAssertEqual(buffer.diagnostics.decodeActions, depth)
            XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
            XCTAssertEqual(buffer.diagnostics.overflowDrops, 0)
            XCTAssertEqual(buffer.diagnostics.plcActions, 0)
        }
    }

    func testWifiHardOverflowRemainsBoundedAtSixPackets() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        for sequence in UInt16(1)...UInt16(7) {
            buffer.insert(packet(sequence))
            XCTAssertLessThanOrEqual(buffer.bufferedPacketCount, 6)
        }
        XCTAssertEqual(buffer.bufferedDurationMs, 60)
        XCTAssertEqual(buffer.diagnostics.maximumDepth, 6)
        XCTAssertEqual(buffer.diagnostics.overflowDrops, 1)
        for sequence in UInt16(2)...UInt16(7) {
            XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence)
        }
        XCTAssertEqual(buffer.diagnostics.overflowDrops, 1)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
    }

    func testMissingExpectedPacketUsesOnePlcThenContinuesInOrder() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for sequence in UInt16(1)...UInt16(3) { XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence) }
        [UInt16(5), 6, 7].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 4 * 480))
        for sequence in UInt16(5)...UInt16(7) { XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence) }
        XCTAssertEqual(buffer.diagnostics.plcActions, 1)
        XCTAssertEqual(buffer.diagnostics.nilPlayoutActions, 0)
        XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
    }

    func testStartedWifiPlayoutDoesNotReturnNilForRecoverableSequenceGap() {
        for depth in 1...6 {
            let buffer = AudioJitterBuffer(profile: .wifi)
            [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
            for sequence in UInt16(1)...UInt16(3) { XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence) }
            for sequence in UInt16(5)...UInt16(4 + depth) { buffer.insert(packet(sequence)) }
            XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 4 * 480), "depth=\(depth)")
            XCTAssertEqual(decodedSequence(buffer.dequeue()), 5)
            XCTAssertEqual(buffer.diagnostics.nilPlayoutActions, 0)
            XCTAssertEqual(buffer.diagnostics.plcActions, 1)
            XCTAssertEqual(buffer.diagnostics.targetPolicyDrops, 0)
        }
    }

    func testWifiMissingPacketPlcWrapsSequenceAndTimestampByOnePacket() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(UInt16.max - 3, timestamp: UInt32.max - 1919))
        buffer.insert(packet(UInt16.max - 2, timestamp: UInt32.max - 1439))
        buffer.insert(packet(UInt16.max - 1, timestamp: UInt32.max - 959))
        for sequence in (UInt16.max - 3)...(UInt16.max - 1) {
            XCTAssertEqual(decodedSequence(buffer.dequeue()), sequence)
        }
        buffer.insert(packet(0, timestamp: 0))
        buffer.insert(packet(1, timestamp: 480))
        buffer.insert(packet(2, timestamp: 960))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: UInt16.max, timestamp: UInt32.max - 479))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 0)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 2)
        XCTAssertEqual(buffer.diagnostics.plcActions, 1)
        XCTAssertEqual(buffer.diagnostics.nilPlayoutActions, 0)
    }

    func testWifiStartupStillWaitsForThreePackets() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(1)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(2)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(3)); XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
        XCTAssertEqual(buffer.targetDurationMs, 30)
        XCTAssertEqual(buffer.diagnostics.startupWaitTicks, 2)
    }

    func testEmptyOrResetBufferDoesNotGenerateEndlessPlc() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for _ in 0..<3 { _ = buffer.dequeue() }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 1920))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 5, timestamp: 2400))
        for _ in 0..<100 { XCTAssertNil(buffer.dequeue()) }
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        buffer.reset()
        XCTAssertNil(buffer.dequeue())
        XCTAssertEqual(buffer.bufferedPacketCount, 0)
        XCTAssertEqual(buffer.diagnostics.plcActions, 0)
    }

    func testFirstReceivePacketMarksOnlyItsObservedSequence() {
        for first in [UInt16(100), UInt16(0)] {
            var rx = AudioReceiveDiagnostics()
            rx.record(sequence: first, timestamp: 480, arrivedAt: 1)
            rx.record(sequence: first &- 1, timestamp: 0, arrivedAt: 1.01)
            XCTAssertEqual(rx.reorderedPackets, 1)
            XCTAssertEqual(rx.repairedPacketUnits, 1)
            XCTAssertEqual(rx.duplicateOrStalePackets, 0)
            rx.record(sequence: first &- 1, timestamp: 0, arrivedAt: 1.02)
            XCTAssertEqual(rx.duplicateOrStalePackets, 1)
            XCTAssertEqual(rx.repairedPacketUnits, 1)
        }
    }

    func testWifiAndUsbTargetsAreExactAndResetIsSessionBound() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        XCTAssertEqual(buffer.targetDurationMs, 30)
        buffer.insert(packet(9))
        buffer.reset(profile: .usb)
        XCTAssertEqual(buffer.targetDurationMs, 20)
        XCTAssertEqual(buffer.bufferedPacketCount, 0)
        buffer.insert(packet(9))
        XCTAssertEqual(buffer.bufferedPacketCount, 1)
    }

    func testSequenceAndTimestampWrapStayOrdered() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(UInt16.max, timestamp: UInt32.max - 479))
        buffer.insert(packet(0, timestamp: 0))
        buffer.insert(packet(1, timestamp: 480))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), UInt16.max)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 0)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 1)
    }

    func testUsbStartupTargetAndMissingPacketDurationAreExact() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(10))
        buffer.insert(packet(11))
        buffer.insert(packet(12))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 10)
        XCTAssertEqual(buffer.droppedPacketCount, 0)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 11)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 12)
        buffer.insert(packet(14))
        XCTAssertEqual(
            buffer.dequeue(),
            .plc(sequence: 13, timestamp: 13 * 480))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 14)
    }

    func testDuplicateAndStalePacketsCannotGrowTheBuffer() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(20))
        buffer.insert(packet(20))
        buffer.insert(packet(13))
        XCTAssertEqual(buffer.bufferedPacketCount, 1)
    }

    func testFuturePacketsDoNotRebaseMissingExpectedAndPlcAdvancesOneTick() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(100))
        buffer.insert(packet(102))
        buffer.insert(packet(103))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 100)

        buffer.insert(packet(104))
        buffer.insert(packet(105))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 101, timestamp: 101 * 480))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 102)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 103)
        XCTAssertEqual(buffer.droppedPacketCount, 0)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 104)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 105)

        buffer.insert(packet(107))
        XCTAssertEqual(
            buffer.dequeue(),
            .plc(sequence: 106, timestamp: 106 * 480))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 107)
    }

    func testAudioNegotiationAndScstIngressPoliciesAreExact() {
        let both = AudioCodecCapabilities.pcm |
            AudioCodecCapabilities.opus
        XCTAssertEqual(
            RealtimeAudioNegotiationPolicy.advertisedCodecs(
                modes: RealtimeTransportMode.legacyTLS),
            AudioCodecCapabilities.pcm)
        XCTAssertEqual(
            RealtimeAudioNegotiationPolicy.advertisedCodecs(
                modes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.wifiRTP),
            both)
        XCTAssertTrue(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.legacyTLS,
                audioCodec: AudioCodecCapabilities.pcm,
                advertisedModes: RealtimeTransportMode.legacyTLS,
                advertisedCodecs: AudioCodecCapabilities.pcm))
        XCTAssertTrue(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.wifiRTP,
                audioCodec: AudioCodecCapabilities.opus,
                advertisedModes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.wifiRTP,
                advertisedCodecs: both))
        XCTAssertTrue(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.usbSplitTLS,
                audioCodec: AudioCodecCapabilities.opus,
                advertisedModes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.usbSplitTLS,
                advertisedCodecs: both))
        XCTAssertFalse(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.legacyTLS,
                audioCodec: AudioCodecCapabilities.opus,
                advertisedModes: RealtimeTransportMode.legacyTLS,
                advertisedCodecs: both))
        XCTAssertFalse(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.wifiRTP,
                audioCodec: AudioCodecCapabilities.pcm,
                advertisedModes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.wifiRTP,
                advertisedCodecs: both))
        XCTAssertFalse(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.usbSplitTLS,
                audioCodec: AudioCodecCapabilities.pcm,
                advertisedModes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.usbSplitTLS,
                advertisedCodecs: both))
        XCTAssertFalse(
            RealtimeAudioNegotiationPolicy.isOfferCompatible(
                mode: RealtimeTransportMode.wifiRTP,
                audioCodec: AudioCodecCapabilities.opus,
                advertisedModes: RealtimeTransportMode.legacyTLS,
                advertisedCodecs: AudioCodecCapabilities.pcm))
        XCTAssertEqual(
            ScstAudioPolicy.classify(
                mode: RealtimeTransportMode.legacyTLS,
                flags: 0,
                payloadLength: 1_920),
            .legacyPCM)
        XCTAssertEqual(
            ScstAudioPolicy.classify(
                mode: RealtimeTransportMode.usbSplitTLS,
                flags: WireProtocol.audioFlagOpus,
                payloadLength: 1_275),
            .opus)
        XCTAssertEqual(
            ScstAudioPolicy.classify(
                mode: RealtimeTransportMode.usbSplitTLS,
                flags: 0,
                payloadLength: 1_920),
            .reject)
        XCTAssertEqual(
            ScstAudioPolicy.classify(
                mode: RealtimeTransportMode.usbSplitTLS,
                flags: WireProtocol.audioFlagOpus,
                payloadLength: 1_276),
            .reject)
        XCTAssertEqual(
            ScstAudioPolicy.classify(
                mode: RealtimeTransportMode.legacyTLS,
                flags: 2,
                payloadLength: 4),
            .reject)
    }

    func testWifiOpusRtpAndAudioNonceDomainAreExact() {
        let session = SessionID(
            bytes: Data([
                0x00, 0x11, 0x22, 0x33,
                0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xaa, 0xbb,
                0xcc, 0xdd, 0xee, 0xff
            ]))!
        let audioSsrc = WifiMediaContract.audioSsrc(session)
        XCTAssertEqual(audioSsrc, 0x2164_465a)
        XCTAssertNotEqual(audioSsrc, WifiMediaContract.mediaSsrc(session))

        var rtp = Data(count: 15)
        rtp[0] = 0x80
        rtp[1] = WifiOpusRtpCodec.payloadType
        rtp[2] = 0xff
        rtp[3] = 0xff
        rtp[4] = 0xff
        rtp[5] = 0xff
        rtp[6] = 0xfe
        rtp[7] = 0x20
        writeBE32(audioSsrc, to: &rtp, at: 8)
        rtp.replaceSubrange(12..<15, with: [1, 2, 3])
        let parsed = WifiOpusRtpCodec.parse(
            rtp,
            expectedSsrc: audioSsrc)
        XCTAssertEqual(parsed?.sequence, UInt16.max)
        XCTAssertEqual(parsed?.timestamp, UInt32.max - 479)
        XCTAssertEqual(parsed?.payload, Data([1, 2, 3]))

        rtp[1] = 96
        XCTAssertNil(WifiOpusRtpCodec.parse(
            rtp,
            expectedSsrc: audioSsrc))
    }

    // Finite post-start concealment and fresh same-session rebuffer ownership.
    func testPostStartEmptyBufferHasExactlyTwoConcealmentTicksThenRebuffers() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for expected in UInt16(1)...3 { XCTAssertEqual(decodedSequence(buffer.dequeue()), expected) }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 1920))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 5, timestamp: 2400))
        for _ in 0..<100 { XCTAssertNil(buffer.dequeue()) }
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        XCTAssertEqual(buffer.diagnostics.boundedPlcActions, 2)
        XCTAssertEqual(buffer.diagnostics.shortStarvationEntries, 1)
        XCTAssertEqual(buffer.diagnostics.rebufferEntries, 1)
        XCTAssertEqual(buffer.diagnostics.rebufferWaitTicks, 100)
    }

    func testRebufferWaitsForFreshTargetAndSkipsUnknownGapWithoutPlcStorm() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for _ in 0..<6 { _ = buffer.dequeue() }
        buffer.insert(packet(100)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(101)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(102)); XCTAssertEqual(decodedSequence(buffer.dequeue()), 100)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 101)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 102)
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        XCTAssertEqual(buffer.diagnostics.rebufferResumes, 1)
        XCTAssertEqual(buffer.diagnostics.freshReanchorSkipUnits, 94)
    }

    func testRebufferRejectsAlreadyConcealedLatePackets() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(1)); buffer.insert(packet(2))
        for _ in 0..<5 { _ = buffer.dequeue() }
        buffer.insert(packet(3)); buffer.insert(packet(4))
        XCTAssertEqual(buffer.bufferedPacketCount, 0)
        XCTAssertEqual(buffer.diagnostics.staleRejects, 2)
        buffer.insert(packet(10)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(11)); XCTAssertEqual(decodedSequence(buffer.dequeue()), 10)
        XCTAssertEqual(buffer.targetDurationMs, 20)
    }

    func testExpectedPacketReturningDuringShortStarvationResumesImmediately() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for _ in 0..<3 { _ = buffer.dequeue() }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 1920))
        buffer.insert(packet(5))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 5)
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 6, timestamp: 2880))
    }

    func testConcealmentAndRebufferAreWrapSafe() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(65534, timestamp: UInt32.max - 959))
        buffer.insert(packet(65535, timestamp: UInt32.max - 479))
        _ = buffer.dequeue(); _ = buffer.dequeue()
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 0, timestamp: 0))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 1, timestamp: 480))
        XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(4, timestamp: 1920)); XCTAssertNil(buffer.dequeue())
        buffer.insert(packet(5, timestamp: 2400)); XCTAssertEqual(decodedSequence(buffer.dequeue()), 4)
    }

    func testDuplicateOrStalePacketsCannotRenewTheStarvationBudget() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(1)); buffer.insert(packet(2)); _ = buffer.dequeue(); _ = buffer.dequeue()
        for _ in 0..<100 { buffer.insert(packet(2)); _ = buffer.dequeue() }
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        XCTAssertEqual(buffer.bufferedPacketCount, 0)
        buffer.reset()
        for _ in 0..<100 { XCTAssertNil(buffer.dequeue()) }
        XCTAssertEqual(buffer.diagnostics.plcActions, 0)
        XCTAssertEqual(buffer.diagnostics.boundedPlcActions, 0)
        XCTAssertEqual(buffer.diagnostics.rebufferEntries, 0)
        XCTAssertEqual(buffer.diagnostics.rebufferResumes, 0)
        XCTAssertEqual(buffer.diagnostics.freshReanchorSkipUnits, 0)
    }

    func testFarFutureBufferedGapUsesAtMostTwoConsecutivePlcThenFreshAnchor() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
        for _ in 0..<3 { _ = buffer.dequeue() }
        [UInt16(100), 101, 102].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 4, timestamp: 1920))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 5, timestamp: 2400))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 100)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 101)
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 102)
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        XCTAssertEqual(buffer.diagnostics.boundedPlcActions, 2)
        XCTAssertEqual(buffer.diagnostics.rebufferResumes, 1)
        XCTAssertEqual(buffer.diagnostics.freshReanchorSkipUnits, 94)
    }

    func testOneAndExactlyTwoMissingPacketsDecodeAlreadyBufferedExpectedWithoutRebuffer() {
        for gap in 1...2 {
            let buffer = AudioJitterBuffer(profile: .wifi)
            [UInt16(1), 2, 3].forEach { buffer.insert(packet($0)) }
            for _ in 0..<3 { _ = buffer.dequeue() }
            buffer.insert(packet(UInt16(4 + gap)))
            for n in 0..<gap { XCTAssertEqual(buffer.dequeue(), .plc(sequence: UInt16(4 + n), timestamp: UInt32(4 + n) * 480)) }
            XCTAssertEqual(decodedSequence(buffer.dequeue()), UInt16(4 + gap))
            XCTAssertEqual(buffer.diagnostics.rebufferEntries, 0)
            XCTAssertEqual(buffer.diagnostics.boundedPlcActions, gap)
        }
    }

    func testFarFutureGapBudgetReanchorAndDuplicateRejectionAcrossSequenceWrap() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(65533), 65534, 65535].forEach { buffer.insert(packet($0)) }
        for _ in 0..<3 { _ = buffer.dequeue() }
        [UInt16(100), 101, 102].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 0, timestamp: UInt32(65535) * 480 + 480))
        buffer.insert(packet(0)); buffer.insert(packet(100))
        XCTAssertEqual(buffer.dequeue(), .plc(sequence: 1, timestamp: UInt32(65535) * 480 + 960))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 100)
        XCTAssertEqual(buffer.diagnostics.plcActions, 2)
        XCTAssertEqual(buffer.diagnostics.boundedPlcActions, 2)
        XCTAssertEqual(buffer.diagnostics.freshReanchorSkipUnits, 98)
        XCTAssertEqual(buffer.diagnostics.staleRejects, 1)
        XCTAssertEqual(buffer.diagnostics.duplicateRejects, 1)
        _ = buffer.dequeue(); _ = buffer.dequeue() // Remaining valid 101/102.
        _ = buffer.dequeue(); _ = buffer.dequeue() // Two misses enter rebuffering.
        XCTAssertEqual(buffer.diagnostics.rebufferEntries, 2)
        buffer.reset(profile: .usb)
        XCTAssertEqual(buffer.diagnostics.plcActions, 0)
        for _ in 0..<10 { XCTAssertNil(buffer.dequeue()) }
        XCTAssertEqual(buffer.targetDurationMs, 20)
        XCTAssertEqual(AudioJitterBuffer.maximumPacketCount, 6)
    }

    private func packet(
        _ sequence: UInt16,
        timestamp: UInt32? = nil
    ) -> AudioJitterPacket {
        AudioJitterPacket(
            sequence: sequence,
            timestamp: timestamp ?? UInt32(sequence) &* 480,
            payload: Data([UInt8(truncatingIfNeeded: sequence)]))
    }

    private func decodedSequence(_ action: AudioJitterAction?) -> UInt16? {
        guard case .decode(let packet) = action else { return nil }
        return packet.sequence
    }

    private func writeBE32(
        _ value: UInt32,
        to data: inout Data,
        at offset: Int
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
