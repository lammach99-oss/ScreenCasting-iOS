import XCTest
@testable import iPadCasting

final class AudioJitterBufferTests: XCTestCase {
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
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 103)
        XCTAssertEqual(buffer.droppedPacketCount, 2)
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

    func testTargetPlusTenDropsOldestBeforeScheduling() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        [UInt16(1), 2, 3, 4].forEach { buffer.insert(packet($0)) }
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 2)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
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

    func testUsbTargetAndPlcThresholdAreExact() {
        let buffer = AudioJitterBuffer(profile: .usb)
        buffer.insert(packet(10))
        buffer.insert(packet(11))
        buffer.insert(packet(12))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 11)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
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

    func testEvictionRebasesMissingExpectedAndPlcAdvancesOneTick() {
        let buffer = AudioJitterBuffer(profile: .wifi)
        buffer.insert(packet(100))
        buffer.insert(packet(102))
        buffer.insert(packet(103))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 100)

        buffer.insert(packet(104))
        buffer.insert(packet(105))
        XCTAssertEqual(decodedSequence(buffer.dequeue()), 103)
        XCTAssertEqual(buffer.droppedPacketCount, 1)
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
