import XCTest
import Network
@testable import iPadCasting

final class UsbSplitCommitGateTests: XCTestCase {
    func testFeedbackWindowStartsEmptyAndTracksLossAndReordering() {
        var window = WifiFeedbackWindow()
        window.observe(100)
        XCTAssertEqual(window.highest, 100)
        XCTAssertEqual(window.bitmap, 0)

        window.observe(103)
        XCTAssertEqual(window.highest, 103)
        XCTAssertEqual(window.bitmap, 0b100)

        window.observe(102)
        XCTAssertEqual(window.bitmap, 0b101)
        window.observe(101)
        XCTAssertEqual(window.bitmap, 0b111)
    }

    func testFeedbackWindowWrapAndLargeJumpResetAreBounded() {
        var window = WifiFeedbackWindow()
        window.observe(UInt16.max)
        window.observe(0)
        XCTAssertEqual(window.highest, 0)
        XCTAssertEqual(window.bitmap, 1)

        window.observe(65)
        XCTAssertEqual(window.highest, 65)
        XCTAssertEqual(window.bitmap, 0)
        window.observe(64)
        XCTAssertEqual(window.bitmap, 1)
    }

    func testWifiSecurityDropsClassifyWithoutUnboundedDetail() {
        var counters = WifiSecurityDropCounters()
        counters.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_543))
        counters.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_542))
        counters.recordCryptoFailure(
            RealtimeCryptoError.invalidPacketLength)
        counters.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_542))
        counters.recordWrongEndpoint()
        XCTAssertEqual(counters.authentication, 1)
        XCTAssertEqual(counters.replay, 2)
        XCTAssertEqual(counters.wrongEndpoint, 1)
    }

    func testFeedbackV2CarriesDistinctBoundedRttFields() {
        var window = WifiFeedbackWindow()
        window.observe(7)
        let telemetry = WifiFeedbackTelemetry(
            lastDecoded: 5,
            lastPresented: 4,
            jitterMs: 2,
            rttP95Ms: 12,
            queueAgeP95Ms: 3,
            decodeP95Ms: 4)
        let packet = WifiFeedbackCodec.packet(
            sequence: 1,
            ssrc: 2,
            window: window,
            lastCompleted: 6,
            telemetry: telemetry,
            smoothedRttMs: 8,
            expiredFrames: 0,
            immediate: false,
            dependencyBreak: false,
            recoveryCompleted: false,
            rttToken: 3,
            rttSentNanoseconds: 4,
            frameIntervalMs: 1000.0 / 120,
            recoveryEpisode: 0)
        XCTAssertEqual(packet.count, 72 + WifiMediaContract.srtpTagLength)
        XCTAssertEqual(packet[18], 0)
        XCTAssertEqual(packet[19], 2)
        XCTAssertEqual(packet[42], 0)
        XCTAssertEqual(packet[43], 8)
        XCTAssertEqual(packet[44], 0)
        XCTAssertEqual(packet[45], 12)

        let bounded = WifiFeedbackCodec.packet(
            sequence: 2,
            ssrc: 2,
            window: window,
            lastCompleted: 6,
            telemetry: WifiFeedbackTelemetry(
                lastDecoded: 5,
                lastPresented: 4,
                jitterMs: 2,
                rttP95Ms: .max,
                queueAgeP95Ms: 3,
                decodeP95Ms: 4),
            smoothedRttMs: .max,
            expiredFrames: 0,
            immediate: false,
            dependencyBreak: false,
            recoveryCompleted: false,
            rttToken: 3,
            rttSentNanoseconds: 4,
            frameIntervalMs: 1000.0 / 120,
            recoveryEpisode: 0)
        XCTAssertEqual(bounded[42], 0x27)
        XCTAssertEqual(bounded[43], 0x10)
        XCTAssertEqual(bounded[44], 0x27)
        XCTAssertEqual(bounded[45], 0x10)
    }

    func testDelayedSetupWaitsForExplicitSplitCommit() throws {
        let session = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = UsbSplitCommitGate()
        gate.begin(sessionID: session)

        XCTAssertEqual(gate.provisionalSessionID, session)
        XCTAssertEqual(
            gate.resolve(
                TransportCommit(
                    version: 1,
                    mode: RealtimeTransportMode.usbSplitTLS,
                    sessionID: session,
                    audioCodec: AudioCodecCapabilities.opus),
                videoLaneBound: true,
                audioLaneBound: true),
            .split)
        XCTAssertNil(gate.provisionalSessionID)
    }

    func testTimeoutRejectsLateSplitCommit() throws {
        let session = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = UsbSplitCommitGate()
        gate.begin(sessionID: session)
        XCTAssertTrue(gate.abort(sessionID: session))
        XCTAssertEqual(
            gate.resolve(
                TransportCommit(
                    version: 1,
                    mode: RealtimeTransportMode.usbSplitTLS,
                    sessionID: session,
                    audioCodec: AudioCodecCapabilities.opus),
                videoLaneBound: true,
                audioLaneBound: true),
            .reject)
    }

    func testExplicitHostFallbackAbortsProvisionalSplit() throws {
        let session = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = UsbSplitCommitGate()
        gate.begin(sessionID: session)
        XCTAssertEqual(
            gate.resolve(
                TransportCommit(
                    version: 1,
                    mode: RealtimeTransportMode.legacyTLS,
                    sessionID: session,
                    audioCodec: AudioCodecCapabilities.pcm),
                videoLaneBound: false,
                audioLaneBound: false),
            .legacyFallback)
        XCTAssertNil(gate.provisionalSessionID)
    }

    func testVideoOnlyCommitRequiresVideoAndExplicitlyDisablesAudio() throws {
        let session = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var gate = UsbSplitCommitGate()
        gate.begin(sessionID: session)
        XCTAssertEqual(
            gate.resolve(
                TransportCommit(
                    version: 1,
                    mode: RealtimeTransportMode.usbSplitTLS,
                    sessionID: session,
                    audioCodec: AudioCodecCapabilities.none),
                videoLaneBound: true,
                audioLaneBound: false),
            .split)

        gate.begin(sessionID: session)
        XCTAssertEqual(
            gate.resolve(
                TransportCommit(
                    version: 1,
                    mode: RealtimeTransportMode.usbSplitTLS,
                    sessionID: session,
                    audioCodec: AudioCodecCapabilities.none),
                videoLaneBound: false,
                audioLaneBound: true),
            .reject)
    }
}

final class ControlChannelWriterTests: XCTestCase {
    func testSenderNeverHasMoreThanOneInFlightSend() {
        let queue = DispatchQueue(label: "control.writer.test")
        let completionQueue = DispatchQueue(label: "control.writer.completions")
        let sent = expectation(description: "all messages sent")
        sent.expectedFulfillmentCount = 64
        let spy = ConcurrentSenderSpy(queue: completionQueue)
        let writer = ControlChannelWriter(queue: queue, sender: spy.send)

        queue.sync {
            writer.begin(generation: 1)
            for value in 0..<64 {
                XCTAssertTrue(writer.enqueue(Data([UInt8(value)])) { _ in
                    sent.fulfill()
                })
            }
        }

        wait(for: [sent], timeout: 2)
        XCTAssertEqual(spy.maximumInFlight, 1)
    }

    func testReliableQueueCapsAt64WithoutDroppingCoalescedWork() {
        let queue = DispatchQueue(label: "control.writer.capacity")
        let sender = ManualSender()
        let writer = ControlChannelWriter(queue: queue, sender: sender.send)

        queue.sync {
            writer.begin(generation: 1)
            for value in 0..<64 {
                XCTAssertTrue(writer.enqueue(Data([UInt8(value)])))
            }
            XCTAssertFalse(writer.enqueue(Data([0xFF])))
            writer.enqueueTelemetry(Data([0xA1]))
            writer.enqueueTelemetry(Data([0xA2]))
            writer.enqueueMovement(Data([0xB1]))
            writer.enqueueMovement(Data([0xB2]))
        }

        for _ in 0..<66 {
            sender.completeNext()
            queue.sync { }
        }

        XCTAssertEqual(sender.sent.count, 66)
        XCTAssertEqual(Array(sender.sent.suffix(2)), [Data([0xA2]), Data([0xB2])])
    }

    func testTransitionPacketsAreReliableWhileMovementIsLatestWins() {
        let queue = DispatchQueue(label: "control.writer.transitions")
        let sender = ManualSender()
        let writer = ControlChannelWriter(queue: queue, sender: sender.send)
        let down = Data([0x10])
        let up = Data([0x11])

        queue.sync {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueue(down))
            writer.enqueueMovement(Data([0x20]))
            writer.enqueueMovement(Data([0x21]))
            XCTAssertTrue(writer.enqueue(up))
        }

        sender.completeNext()
        queue.sync { }
        sender.completeNext()
        queue.sync { }
        sender.completeNext()
        queue.sync { }

        XCTAssertEqual(sender.sent, [down, Data([0x21]), up])
    }

    func testCancelBeginSuppressesStaleCompletionAndKeepsOneInFlightSend() {
        let queue = DispatchQueue(label: "control.writer.generation")
        let sender = ManualSender()
        let writer = ControlChannelWriter(queue: queue, sender: sender.send)
        var staleCompletions = 0
        var currentCompletions = 0

        queue.sync {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueue(Data([0x01])) { _ in staleCompletions += 1 })
            writer.cancel()
            writer.begin(generation: 2)
            XCTAssertTrue(writer.enqueue(Data([0x02])) { _ in currentCompletions += 1 })
        }
        XCTAssertEqual(sender.sent, [Data([0x01])])

        sender.completeNext()
        queue.sync { }
        XCTAssertEqual(staleCompletions, 0)
        XCTAssertEqual(sender.sent, [Data([0x01]), Data([0x02])])

        sender.completeNext()
        queue.sync { }
        XCTAssertEqual(currentCompletions, 1)
    }
}

final class WifiInputTransportTests: XCTestCase {
    func testDeliveryPolicyKeepsTransitionsReliable() {
        XCTAssertEqual(InputDeliveryPolicy.forEvent(.move), .unreliableLatest)
        XCTAssertEqual(InputDeliveryPolicy.forEvent(.down), .reliable)
        XCTAssertEqual(InputDeliveryPolicy.forEvent(.up), .reliable)
        XCTAssertEqual(InputDeliveryPolicy.forEvent(.force), .reliable)
    }

    func testPT112PayloadAndInputSsrcMatchManagedContract() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let ssrc = WifiMediaContract.inputSsrc(sessionID)
        let touch = Data([0x49, 0x54, 0, 127, 123, 0, 200, 1])
        let packet = try XCTUnwrap(
            WifiInputRtpCodec.packet(
                touch: touch,
                sequence: 0x0102_0304,
                ssrc: ssrc))

        XCTAssertEqual(packet.count, WifiInputRtpCodec.protectedCapacity)
        XCTAssertEqual(packet[0], 0x80)
        XCTAssertEqual(packet[1], 112)
        XCTAssertEqual(packet[2], 0x03)
        XCTAssertEqual(packet[3], 0x04)
        XCTAssertEqual(
            packet.subdata(in: 4..<8),
            Data([1, 2, 3, 4]))
        XCTAssertEqual(packet.subdata(in: 12..<20), touch)
        XCTAssertEqual(
            packet.subdata(in: 20..<24),
            Data([1, 2, 3, 4]))
        XCTAssertNotEqual(ssrc, WifiMediaContract.mediaSsrc(sessionID))
        XCTAssertNotEqual(ssrc, WifiMediaContract.audioSsrc(sessionID))
        XCTAssertNotEqual(ssrc, WifiMediaContract.feedbackSsrc(sessionID))
        XCTAssertNotEqual(
            ssrc,
            WifiMediaContract.probeRequestSsrc(sessionID))
        XCTAssertNotEqual(
            ssrc,
            WifiMediaContract.probeAcknowledgementSsrc(sessionID))
    }

    func testLatestWriterIsBoundedGenerationSafeAndSequencesOnlySends() {
        let queue = DispatchQueue(label: "wifi.input.latest")
        let sender = ManualInputSender()
        let writer = WifiLatestInputWriter(
            queue: queue,
            packetBuilder: { touch, sequence in
                var packet = touch
                packet.append(UInt8(truncatingIfNeeded: sequence))
                return packet
            },
            sender: sender.send,
            onFailure: { _, _ in XCTFail("unexpected send failure") })

        queue.sync {
            writer.begin(generation: 7, initialSequence: UInt32.max)
            writer.enqueue(Data([1]), generation: 7)
            writer.enqueue(Data([2]), generation: 7)
            writer.enqueue(Data([3]), generation: 7)
            XCTAssertEqual(writer.bufferedPacketCount, 2)
        }
        XCTAssertEqual(sender.sent, [Data([1, 0xff])])

        sender.completeNext()
        queue.sync { }
        XCTAssertEqual(
            sender.sent,
            [Data([1, 0xff]), Data([3, 0])])

        queue.sync {
            writer.enqueue(Data([4]), generation: 6)
            writer.cancel()
            writer.begin(generation: 8, initialSequence: 10)
            writer.enqueue(Data([5]), generation: 8)
        }
        sender.completeNext()
        queue.sync { }
        XCTAssertEqual(sender.sent.last, Data([5, 10]))
    }
}

private final class ManualInputSender {
    private let lock = NSLock()
    private var completions: [(Error?) -> Void] = []
    private(set) var sent: [Data] = []

    lazy var send: WifiLatestInputWriter.Sender = { [weak self] data, completion in
        guard let self else { return }
        self.lock.lock()
        self.sent.append(data)
        self.completions.append(completion)
        self.lock.unlock()
    }

    func completeNext(_ error: Error? = nil) {
        lock.lock()
        let completion = completions.removeFirst()
        lock.unlock()
        completion(error)
    }
}

private final class ConcurrentSenderSpy {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    lazy var send: ControlChannelWriter.Sender = { [weak self] _, completion in
        guard let self else { return }
        self.lock.lock()
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        self.lock.unlock()
        self.queue.async {
            self.lock.lock()
            self.inFlight -= 1
            self.lock.unlock()
            completion(nil)
        }
    }
}

private final class ManualSender {
    private let lock = NSLock()
    private var completions: [(NWError?) -> Void] = []
    private(set) var sent: [Data] = []

    lazy var send: ControlChannelWriter.Sender = { [weak self] data, completion in
        guard let self else { return }
        self.lock.lock()
        self.sent.append(data)
        self.completions.append(completion)
        self.lock.unlock()
    }

    func completeNext(_ error: NWError? = nil) {
        lock.lock()
        let completion = completions.removeFirst()
        lock.unlock()
        completion(error)
    }
}

final class WireProtocolTests: XCTestCase {
    func testUSBLaneBindingMatchesManagedHMACFixture() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let wrongSession = try XCTUnwrap(
            SessionID(hex: "ffeeddccbbaa99887766554433221100"))
        let secret = Data((0..<32).map(UInt8.init))
        let mac = Data([
            0x02, 0xcd, 0x20, 0xb0, 0x69, 0xb9, 0xf2, 0x66,
            0x0c, 0x9a, 0x14, 0xbe, 0x8b, 0x78, 0x8a, 0x13,
            0x80, 0xc8, 0xb2, 0x5c, 0xdb, 0xdb, 0x72, 0xe3,
            0xec, 0x42, 0x53, 0x13, 0x58, 0x40, 0xc6, 0x0f
        ])
        var payload = Data(count: UsbLaneBinding.encodedSize)
        sessionID.write(to: &payload, at: 0)
        payload[16] = UsbLaneKind.video.rawValue
        payload[17] = UsbLaneBinding.version
        payload.storeLittleEndian(UInt64(7), at: 20)
        payload.replaceSubrange(28..<60, with: mac)

        let binding = try XCTUnwrap(UsbLaneBinding.decode(payload))
        XCTAssertTrue(
            binding.validate(
                expectedSessionID: sessionID,
                secret: secret))
        XCTAssertFalse(
            binding.validate(
                expectedSessionID: wrongSession,
                secret: secret))
        payload[18] = 1
        XCTAssertNil(UsbLaneBinding.decode(payload))
    }

    func testClientCapabilitiesMatchManagedFixture() {
        let capabilities = ClientCapabilities(
            version: 1,
            modes: RealtimeTransportMode.legacyTLS |
                RealtimeTransportMode.wifiRTP |
                RealtimeTransportMode.usbSplitTLS,
            videoCodecs: VideoCodecCapabilities.hevc,
            audioCodecs: AudioCodecCapabilities.pcm |
                AudioCodecCapabilities.opus,
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: 49152)

        let encoded = capabilities.encode()

        XCTAssertEqual(
            encoded,
            Data([1, 7, 1, 3, 0xB0, 0x04, 50, 0, 0, 0xC0, 0, 0]))
        XCTAssertEqual(ClientCapabilities.decode(encoded), capabilities)
    }

    func testClientCapabilitiesRejectEveryTruncatedLength() {
        let encoded = ClientCapabilities(
            version: 1,
            modes: RealtimeTransportMode.legacyTLS,
            videoCodecs: VideoCodecCapabilities.hevc,
            audioCodecs: AudioCodecCapabilities.pcm,
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: 0).encode()

        for length in 0..<encoded.count {
            XCTAssertNil(
                ClientCapabilities.decode(Data(encoded.prefix(length))),
                "accepted truncation \(length)")
        }
    }

    func testClientCapabilitiesRejectInvalidRangesAndReservedBytes() {
        let valid = ClientCapabilities(
            version: 1,
            modes: RealtimeTransportMode.legacyTLS,
            videoCodecs: VideoCodecCapabilities.hevc,
            audioCodecs: AudioCodecCapabilities.pcm,
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: 0).encode()

        for mtu in [UInt16(575), UInt16(1201)] {
            var invalid = valid
            invalid.storeLittleEndian(mtu, at: 4)
            XCTAssertNil(ClientCapabilities.decode(invalid))
        }
        for feedback in [UInt16(24), UInt16(201)] {
            var invalid = valid
            invalid.storeLittleEndian(feedback, at: 6)
            XCTAssertNil(ClientCapabilities.decode(invalid))
        }
        var reserved = valid
        reserved[10] = 1
        XCTAssertNil(ClientCapabilities.decode(reserved))
        var unexpectedPort = valid
        unexpectedPort.storeLittleEndian(UInt16(49152), at: 8)
        XCTAssertNil(ClientCapabilities.decode(unexpectedPort))
        var missingLegacyFallback = valid
        missingLegacyFallback[1] = RealtimeTransportMode.wifiRTP
        missingLegacyFallback.storeLittleEndian(UInt16(49152), at: 8)
        XCTAssertNil(ClientCapabilities.decode(missingLegacyFallback))
    }

    func testOfferReadyAndCommitFixedCodecsRoundTrip() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        var offer = TransportOffer(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            videoCodec: VideoCodecCapabilities.hevc,
            audioCodec: AudioCodecCapabilities.opus,
            mtu: 1200,
            feedbackIntervalMs: 50,
            hostUDPPort: 27016,
            sessionID: sessionID,
            mediaKey: Data((0..<16).map(UInt8.init)),
            mediaSalt: Data((16..<28).map(UInt8.init)),
            feedbackKey: Data((28..<44).map(UInt8.init)),
            feedbackSalt: Data((44..<56).map(UInt8.init)),
            usbBindingSecret: Data((56..<88).map(UInt8.init)))
        let offerBytes = offer.encode()
        XCTAssertEqual(offerBytes?.count, 116)
        XCTAssertEqual(offerBytes.flatMap(TransportOffer.decode), offer)

        offer.zeroSecrets()
        XCTAssertTrue(offer.secretsAreZero)

        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.opus)
        XCTAssertEqual(ready.encode().flatMap(TransportReady.decode), ready)
        XCTAssertEqual(ready.encode()?.count, 20)

        let commit = TransportCommit(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.opus)
        XCTAssertEqual(commit.encode().flatMap(TransportCommit.decode), commit)
        XCTAssertEqual(commit.encode()?.count, 20)
    }

    func testFixedNegotiationCodecsRejectTruncationAndReservedBytes() throws {
        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let offer = TransportOffer(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            videoCodec: VideoCodecCapabilities.hevc,
            audioCodec: AudioCodecCapabilities.pcm,
            mtu: 1200,
            feedbackIntervalMs: 50,
            hostUDPPort: 0,
            sessionID: sessionID,
            mediaKey: Data(repeating: 1, count: 16),
            mediaSalt: Data(repeating: 2, count: 12),
            feedbackKey: Data(repeating: 3, count: 16),
            feedbackSalt: Data(repeating: 4, count: 12),
            usbBindingSecret: Data(repeating: 5, count: 32))
        let offerBytes = try XCTUnwrap(offer.encode())
        for length in 0..<offerBytes.count {
            XCTAssertNil(
                TransportOffer.decode(Data(offerBytes.prefix(length))),
                "accepted offer truncation \(length)")
        }
        var reservedOffer = offerBytes
        reservedOffer[10] = 1
        XCTAssertNil(TransportOffer.decode(reservedOffer))

        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        let readyBytes = try XCTUnwrap(ready.encode())
        for length in 0..<readyBytes.count {
            XCTAssertNil(
                TransportReady.decode(Data(readyBytes.prefix(length))),
                "accepted ready truncation \(length)")
        }
        var invalidReady = readyBytes
        invalidReady[3] = AudioCodecCapabilities.opus
        XCTAssertNil(TransportReady.decode(invalidReady))

        let commit = TransportCommit(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        let commitBytes = try XCTUnwrap(commit.encode())
        for length in 0..<commitBytes.count {
            XCTAssertNil(
                TransportCommit.decode(Data(commitBytes.prefix(length))),
                "accepted commit truncation \(length)")
        }
        var invalidCommit = commitBytes
        invalidCommit[2] = AudioCodecCapabilities.opus
        XCTAssertNil(TransportCommit.decode(invalidCommit))
    }

    func testNegotiationMessageValuesAndAuthFlagAreStable() {
        XCTAssertEqual(WireMessageType.clientCapabilities.rawValue, 9)
        XCTAssertEqual(WireMessageType.transportOffer.rawValue, 10)
        XCTAssertEqual(WireMessageType.transportReady.rawValue, 11)
        XCTAssertEqual(WireMessageType.transportCommit.rawValue, 12)
        XCTAssertEqual(WireMessageType.usbLaneBind.rawValue, 13)
        XCTAssertEqual(WireMessageType.usbLaneBindResult.rawValue, 14)
        XCTAssertEqual(WireProtocol.realtimeNegotiationSupportedFlag, 0x8000)
    }

    func testUSBIdentityResourceDecodesWhitespaceWrappedData() {
        let decoded = USBIdentityResource.decode("AQID\nBA==")
        XCTAssertEqual(decoded, Data([1, 2, 3, 4]))
    }

    func testUSBIdentityResourceRejectsMalformedPayload() {
        XCTAssertNil(USBIdentityResource.decode("A"))
    }

    func testEveryHeaderSplitPointPreservesMessage() {
        let expected = makeMessage(type: .video, flags: 1, payload: Data([1, 2, 3]), sequence: 42)

        for split in 1..<WireProtocol.headerSize {
            let parser = WireStreamParser(generation: 7)
            var messages: [WireMessage] = []
            parser.consume(expected.prefix(split), generation: 7) { event in
                if case .message(let message) = event { messages.append(message) }
            }
            parser.consume(expected.dropFirst(split), generation: 7) { event in
                if case .message(let message) = event { messages.append(message) }
            }

            XCTAssertEqual(messages.count, 1, "split \(split)")
            XCTAssertEqual(messages.first?.header.sequence, 42)
            XCTAssertEqual(messages.first?.header.flags, 1)
            XCTAssertEqual(messages.first?.payload, Data([1, 2, 3]))
        }
    }

    func testOneByteFragmentsPreserveBothMessages() {
        let first = makeMessage(type: .video, flags: 0, payload: Data([9, 8]), sequence: 1)
        let second = makeMessage(type: .audio, flags: 0, payload: Data([7]), sequence: 2)
        let parser = WireStreamParser(generation: 3)
        var sequences: [UInt32] = []

        for byte in first + second {
            parser.consume(Data([byte]), generation: 3) { event in
                if case .message(let message) = event {
                    sequences.append(message.header.sequence)
                }
            }
        }

        XCTAssertEqual(sequences, [1, 2])
    }

    func testTwoCoalescedMessagesInOneConsume() {
        let first = makeMessage(type: .video, flags: 1, payload: Data([9, 8]), sequence: 1)
        let second = makeMessage(type: .audio, flags: 0, payload: Data([7]), sequence: 2)
        let parser = WireStreamParser(generation: 3)
        var sequences: [UInt32] = []

        parser.consume(first + second, generation: 3) { event in
            if case .message(let message) = event {
                sequences.append(message.header.sequence)
            }
        }

        XCTAssertEqual(sequences, [1, 2])
    }

    func testVideoFirstByteTimingExcludesPriorControlAndSurvivesFragments() {
        let control = makeMessage(type: .ping, flags: 0,
                                  payload: Data(repeating: 0, count: 16), sequence: 1)
        let video = makeMessage(type: .video, flags: 1,
                                payload: Data([9, 8, 7]), sequence: 2)
        let parser = WireStreamParser(generation: 1)
        var received: WireMessage?

        parser.consume(control, generation: 1, receivedAt: 10) { _ in }
        parser.consume(video.prefix(5), generation: 1, receivedAt: 20) { _ in }
        parser.consume(video.dropFirst(5), generation: 1, receivedAt: 40) { event in
            if case .message(let message) = event { received = message }
        }

        XCTAssertEqual(received?.header.sequence, 2)
        XCTAssertEqual(received?.firstByteAt, 20,
                       "video timing must start at its own first header byte")
    }

    func testStaleGenerationIsIgnoredAndResetDropsPartialHeader() {
        let message = makeMessage(type: .video, flags: 0, payload: Data([5]), sequence: 11)
        let parser = WireStreamParser(generation: 1)
        var sequences: [UInt32] = []

        parser.consume(message.prefix(9), generation: 1) { _ in
            XCTFail("partial header emitted an event")
        }
        parser.reset(generation: 2)
        parser.consume(message.dropFirst(9), generation: 1) { _ in
            XCTFail("stale generation emitted an event")
        }
        parser.consume(message, generation: 2) { event in
            if case .message(let parsed) = event {
                sequences.append(parsed.header.sequence)
            }
        }

        XCTAssertEqual(sequences, [11])
    }

    func testOversizedPayloadIsRejectedBeforeAllocation() {
        let parser = WireStreamParser(generation: 1)
        let header = makeHeader(
            type: .video,
            flags: 0,
            payloadLength: WireProtocol.maxPayloadSize + 1,
            sequence: 5)
        var errors: [WireParserError] = []

        parser.consume(header, generation: 1) { event in
            if case .failure(let error) = event { errors.append(error) }
        }

        XCTAssertEqual(errors, [.oversizedPayload(WireProtocol.maxPayloadSize + 1)])
        XCTAssertEqual(parser.allocatedPayloadBytes, 0)
    }

    func testMalformedFixedControlDrainsBoundedChunksAndContinuesSession() {
        let parser = WireStreamParser(generation: 4)
        let malformedLength = 4_097
        let malformed = makeHeader(
            type: .ping,
            flags: 0,
            payloadLength: malformedLength,
            sequence: 8) + Data(repeating: 0xAA, count: malformedLength)
        let following = makeMessage(
            type: .video,
            flags: 1,
            payload: Data([0, 0, 0, 1, 0x26]),
            sequence: 9)
        var discarded: [UInt32] = []
        var received: [UInt32] = []

        parser.consume(malformed.prefix(WireProtocol.headerSize), generation: 4) { event in
            XCTFail("malformed control emitted before its payload was drained: \(event)")
        }
        XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        XCTAssertLessThanOrEqual(parser.suggestedReceiveLength, WireProtocol.drainChunkSize)

        parser.consume(
            malformed.dropFirst(WireProtocol.headerSize) + following,
            generation: 4
        ) { event in
            switch event {
            case .discardedFixedControl(let header):
                discarded.append(header.sequence)
            case .message(let message):
                received.append(message.header.sequence)
            case .failure(let error):
                XCTFail("unexpected parser failure: \(error)")
            }
        }

        XCTAssertEqual(discarded, [8])
        XCTAssertEqual(received, [9])
        XCTAssertEqual(parser.allocatedPayloadBytes, 0)
        XCTAssertLessThanOrEqual(
            parser.maximumDrainChunkObserved,
            WireProtocol.drainChunkSize)
    }

    func testConcurrentStopReceiveResetRequestsStayOnParserQueue() {
        let networkQueue = DispatchQueue(label: "wire.parser.test.network")
        let callers = DispatchQueue(
            label: "wire.parser.test.callers",
            attributes: .concurrent)
        let domain = WireParserQueueDomain(generation: 1, queue: networkQueue)
        let partial = makeMessage(
            type: .video,
            flags: 1,
            payload: Data([1, 2, 3]),
            sequence: 1).prefix(8)
        let group = DispatchGroup()
        var received: [UInt32] = []

        for index in 0..<256 {
            group.enter()
            callers.async {
                networkQueue.async {
                    if index.isMultiple(of: 2) {
                        domain.reset(generation: UInt64(index + 2))
                    } else {
                        domain.consume(Data(partial), generation: 1) { _ in }
                    }
                }
                group.leave()
            }
        }
        group.wait()

        networkQueue.sync {
            received.removeAll()
            domain.reset(generation: 10_000)
            domain.consume(
                makeMessage(
                    type: .video,
                    flags: 1,
                    payload: Data([9]),
                    sequence: 77),
                generation: 10_000
            ) { event in
                if case .message(let message) = event {
                    received.append(message.header.sequence)
                }
            }
        }

        XCTAssertEqual(received, [77])
    }

    private func makeMessage(
        type: WireMessageType,
        flags: UInt16,
        payload: Data,
        sequence: UInt32
    ) -> Data {
        makeHeader(
            type: type,
            flags: flags,
            payloadLength: payload.count,
            sequence: sequence) + payload
    }

    private func makeHeader(
        type: WireMessageType,
        flags: UInt16,
        payloadLength: Int,
        sequence: UInt32
    ) -> Data {
        var data = Data(count: WireProtocol.headerSize)
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: WireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: WireProtocol.version, toByteOffset: 4, as: UInt8.self)
            bytes.storeBytes(of: type.rawValue, toByteOffset: 5, as: UInt8.self)
            bytes.storeBytes(of: flags.littleEndian, toByteOffset: 6, as: UInt16.self)
            bytes.storeBytes(
                of: UInt32(payloadLength).littleEndian,
                toByteOffset: 8,
                as: UInt32.self)
            bytes.storeBytes(of: sequence.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        return data
    }
}
