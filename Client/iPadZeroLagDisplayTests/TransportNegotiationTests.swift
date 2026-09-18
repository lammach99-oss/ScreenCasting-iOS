import XCTest
import Network
@testable import iPadCasting

final class Display120HzSourceTests: XCTestCase {
    func testCapabilitiesDecodeCanonical120HzNativeModes() throws {
        var payload = Data(count: DisplayCapabilities.encodedSize)
        payload[0] = 1
        payload[1] = 2

        func put(_ value: UInt32, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                payload.replaceSubrange(offset..<(offset + 4), with: bytes)
            }
        }
        func put16(_ value: UInt16, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                payload.replaceSubrange(offset..<(offset + 2), with: bytes)
            }
        }

        put(2388, at: 4)
        put(1668, at: 8)
        put16(120, at: 12)
        put(2388, at: 16)
        put(1668, at: 20)
        put16(60, at: 24)

        let capabilities = try XCTUnwrap(DisplayCapabilities.decode(payload))
        XCTAssertEqual(capabilities.preferred.refreshHz, 120)
        XCTAssertEqual(capabilities.refreshRates(for: DisplayResolution(width: 2388, height: 1668)), [120, 60])
    }

    func testDefaultSourceRequestIsAlways120Hz() {
        let request = DisplayPreference.defaultValue.makeRequest(
            interfaceOrientation: .landscape,
            requestId: 1)
        XCTAssertEqual(request.width, 2388)
        XCTAssertEqual(request.height, 1668)
        XCTAssertEqual(request.refreshHz, 120)
    }

    func testPresentationRateCapsToPanelWithoutChangingSource() {
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 60), 60)
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 120), 120)
        XCTAssertEqual(ClientPresentationRatePolicy.preferredFramesPerSecond(maximumFramesPerSecond: 144), 120)
        let oldPersistedPreference = DisplayPreference(
            width: 2388,
            height: 1668,
            refreshHz: 60,
            orientationMode: .automatic)
        let capabilities = DisplayCapabilities(
            modes: [
                DisplayMode(width: 2388, height: 1668, refreshHz: 120, isExperimental: false),
                DisplayMode(width: 2388, height: 1668, refreshHz: 60, isExperimental: false),
            ],
            preferred: DisplayMode(width: 2388, height: 1668, refreshHz: 120, isExperimental: false))
        XCTAssertEqual(oldPersistedPreference.reconciled(with: capabilities).refreshHz, 120)
        XCTAssertEqual(DisplayPreference.defaultValue.makeRequest(
            interfaceOrientation: .landscape,
            requestId: 2).refreshHz, 120)
    }
}

final class WifiTransportNegotiationTests: XCTestCase {
    func testKnownHostIdentityMustMatchPinnedCertificate() {
        let fingerprint = String(repeating: "AB", count: 32)

        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: fingerprint,
                pinnedFingerprint: fingerprint),
            .trusted)
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: String(repeating: "CD", count: 32),
                pinnedFingerprint: fingerprint),
            .rejected)
    }

    func testFirstPairingRequiresOutOfBandIdentityConfirmation() {
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: String(repeating: "12", count: 32),
                pinnedFingerprint: nil),
            .requiresFirstPairingConfirmation)
    }

    func testIdentityCodeIsStableAndHumanVerifiable() {
        let fingerprint = "00112233445566778899AABBCCDDEEFF" +
            String(repeating: "00", count: 16)

        XCTAssertEqual(
            WifiHostIdentityPolicy.identityCode(for: fingerprint),
            "0011-2233-4455-6677")
    }

    func testMalformedIdentityNeverPassesAsTrusted() {
        XCTAssertEqual(
            WifiHostIdentityPolicy.decide(
                presentedFingerprint: "not-a-fingerprint",
                pinnedFingerprint: nil),
            .rejected)
        XCTAssertNil(WifiHostIdentityPolicy.identityCode(for: "1234"))
    }

    func testWifiVideoOnlyNegotiationOmitsAudio() throws {
        let capabilities = ClientCapabilities(
            version: 1,
            modes: RealtimeTransportMode.legacyTLS |
                RealtimeTransportMode.wifiRTP,
            videoCodecs: VideoCodecCapabilities.hevc,
            audioCodecs: AudioCodecCapabilities.none,
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: 49152)
        XCTAssertEqual(
            ClientCapabilities.decode(capabilities.encode()),
            capabilities)

        let sessionID = try XCTUnwrap(
            SessionID(hex: "00112233445566778899aabbccddeeff"))
        let offer = TransportOffer(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            videoCodec: VideoCodecCapabilities.hevc,
            audioCodec: AudioCodecCapabilities.none,
            mtu: 1200,
            feedbackIntervalMs: 50,
            hostUDPPort: 27016,
            sessionID: sessionID,
            mediaKey: Data(repeating: 1, count: 16),
            mediaSalt: Data(repeating: 2, count: 12),
            feedbackKey: Data(repeating: 3, count: 16),
            feedbackSalt: Data(repeating: 4, count: 12),
            usbBindingSecret: Data(repeating: 5, count: 32))
        XCTAssertEqual(
            TransportOffer.decode(try XCTUnwrap(offer.encode()))?.audioCodec,
            AudioCodecCapabilities.none)

        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.none)
        XCTAssertEqual(
            TransportReady.decode(try XCTUnwrap(ready.encode())),
            ready)

        let commit = TransportCommit(
            version: 1,
            mode: RealtimeTransportMode.wifiRTP,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.none)
        XCTAssertEqual(
            TransportCommit.decode(try XCTUnwrap(commit.encode())),
            commit)
    }

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

    func testAuthenticatedMediaProcessorUsesProvidedRttForReassemblyDeadline() {
        var outcomes: [HevcReassemblyOutcome] = []
        let processor = WifiAuthenticatedMediaProcessor(
            mtu: 1_200,
            initialSequence: 10,
            unprotect: { _ in true },
            decoder: { _, _, _, _ in },
            outcomeObserver: { outcomes.append($0) },
            rttP95Provider: { 20 })
        let dependent = Data([0x02, 0x01])

        processor.consume(
            makeMediaPacket(
                sequence: 10,
                timestamp: 1,
                frameSequence: 1,
                marker: false,
                payload: dependent),
            arrivalTime: 0)
        processor.consume(
            makeMediaPacket(
                sequence: 11,
                timestamp: 2,
                frameSequence: 2,
                marker: true,
                payload: dependent),
            arrivalTime: 0.020)
        XCTAssertFalse(outcomes.contains(.expired(frameSequence: 1)))

        processor.consume(
            makeMediaPacket(
                sequence: 12,
                timestamp: 3,
                frameSequence: 3,
                marker: true,
                payload: dependent),
            arrivalTime: 0.040)
        XCTAssertTrue(outcomes.contains(.expired(frameSequence: 1)))
    }

    private func makeSingleNalPacket(sequence: UInt16) -> Data {
        makeMediaPacket(
            sequence: sequence,
            timestamp: 9,
            frameSequence: 7,
            marker: true,
            payload: Data([0x26, 0x01]))
    }

    private func makeMediaPacket(
        sequence: UInt16,
        timestamp: UInt32,
        frameSequence: UInt32,
        marker: Bool,
        payload: Data
    ) -> Data {
        var packet = Data(count: RtpPacketView.headerLength + payload.count)
        packet[0] = 0x90
        packet[1] = (marker ? 0x80 : 0) | 96
        storeBE16(sequence, in: &packet, at: 2)
        storeBE32(timestamp, in: &packet, at: 4)
        storeBE32(0x2d74465a, in: &packet, at: 8)
        storeBE16(0xBEDE, in: &packet, at: 12)
        storeBE16(3, in: &packet, at: 14)
        packet[16] = 0x17
        storeBE32(frameSequence, in: &packet, at: 17)
        storeBE32(8, in: &packet, at: 21)
        packet.replaceSubrange(
            RtpPacketView.headerLength..<packet.count,
            with: payload)
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

final class TrustedReconnectPolicyTests: XCTestCase {
    func testFreshLaunchDoesNotAutoReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: false,
                lastKnownHost: "192.168.1.10"),
            "fresh launch without user-started connection must not schedule auto-reconnect")
    }

    func testActiveSessionReconnectsWhenForeground() {
        XCTAssertTrue(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: "192.168.1.10"),
            "user-owned active session should schedule auto-reconnect on disconnect")
    }

    func testBackgroundDoesNotScheduleReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: false,
                reconnectEnabled: true,
                lastKnownHost: "192.168.1.10"),
            "background state must not schedule auto-reconnect")
    }

    func testEmptyHostDoesNotScheduleReconnect() {
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: ""),
            "empty host must not schedule auto-reconnect")
        XCTAssertFalse(
            TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: true,
                reconnectEnabled: true,
                lastKnownHost: nil),
            "nil host must not schedule auto-reconnect")
    }

    func testRecentWifiResumeIntentIsValidInsideRelaunchWindow() {
        XCTAssertTrue(
            RecentWifiResumePolicy.isValid(
                resumeUntil: 130,
                now: 120))
    }

    func testRecentWifiResumeIntentExpiresOutsideRelaunchWindow() {
        XCTAssertFalse(
            RecentWifiResumePolicy.isValid(
                resumeUntil: 120,
                now: 121))
    }

    func testMissingResumeIntentDoesNotEnableRelaunchReconnect() {
        XCTAssertFalse(
            RecentWifiResumePolicy.isValid(
                resumeUntil: nil,
                now: 120))
    }

    func testWifiLifecycleUsesBoundedBackgroundGrace() {
        XCTAssertEqual(WifiLifecyclePolicy.backgroundGrace, 5)
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: true,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
    }

    func testOldGenerationBackgroundTeardownCannotReplaceCurrentSession() {
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 8,
                hasSameConnection: true))
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: false))
    }

    func testOnlyMatchingBackgroundWifiSessionTearsDownAfterGrace() {
        XCTAssertTrue(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: false,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
        XCTAssertFalse(
            WifiLifecyclePolicy.shouldTearDownAfterGrace(
                isForegroundActive: false,
                isUSB: true,
                scheduledGeneration: 7,
                currentGeneration: 7,
                hasSameConnection: true))
    }
}

final class ClientPreferenceTests: XCTestCase {
    func testPerformanceHudPreferenceDefaultsOnAndPersists() {
        let suiteName = "ScreenCasting.ClientPreferenceTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(
            defaults.object(forKey: ClientPreferenceKeys.showPerformanceHUD)
                as? Bool ?? true)
        defaults.set(false, forKey: ClientPreferenceKeys.showPerformanceHUD)
        XCTAssertFalse(defaults.bool(forKey: ClientPreferenceKeys.showPerformanceHUD))
        defaults.set(true, forKey: ClientPreferenceKeys.showPerformanceHUD)
        XCTAssertTrue(defaults.bool(forKey: ClientPreferenceKeys.showPerformanceHUD))
        defaults.removePersistentDomain(forName: suiteName)
    }
}

final class WifiReconnectTargetTests: XCTestCase {
    func testWifiReconnectHostPortTargetRoundTrips() throws {
        let target = WifiReconnectTarget.hostPort(
            host: "192.168.1.50",
            port: 27015)
        let endpoint = try XCTUnwrap(target.endpoint)
        guard case .hostPort(let host, let port) = endpoint else {
            return XCTFail("Expected hostPort endpoint")
        }
        XCTAssertEqual(String(describing: host), "192.168.1.50")
        XCTAssertEqual(port.rawValue, 27015)
    }

    func testWifiReconnectServiceTargetRoundTrips() throws {
        let target = WifiReconnectTarget.service(
            name: "ScreenCasting-PC",
            type: "_screencasting._tcp",
            domain: "local.")
        let endpoint = try XCTUnwrap(target.endpoint)
        guard case .service(let name, let type, let domain, _) = endpoint else {
            return XCTFail("Expected service endpoint")
        }
        XCTAssertEqual(name, "ScreenCasting-PC")
        XCTAssertEqual(type, "_screencasting._tcp")
        XCTAssertEqual(domain, "local.")
    }

    func testDiscoveredServiceEndpointPersistsReconnectIdentity() throws {
        let endpoint = NWEndpoint.service(
            name: "Office-PC",
            type: "_screencasting._tcp",
            domain: "local.",
            interface: nil)
        let target = try XCTUnwrap(WifiReconnectTargetPolicy.target(from: endpoint))
        XCTAssertEqual(
            target,
            .service(
                name: "Office-PC",
                type: "_screencasting._tcp",
                domain: "local."))
    }

    func testWifiReconnectTargetStorePersistsTarget() throws {
        let suite = "ScreenCasting.WifiReconnectTargetStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = WifiReconnectTarget.hostPort(host: "10.0.0.2", port: 27015)
        WifiReconnectTargetStore.save(expected, defaults: defaults)
        XCTAssertEqual(WifiReconnectTargetStore.load(defaults: defaults), expected)
    }

    func testStructuredReconnectTargetWinsOverStaleLegacyHost() {
        let discovered = WifiReconnectTarget.service(
            name: "Current-PC",
            type: "_screencasting._tcp",
            domain: "local.")
        XCTAssertEqual(
            WifiReconnectTargetSelection.preferred(
                structured: discovered,
                legacyHost: "192.168.1.99"),
            discovered)
    }

    func testLegacyReconnectHostMigratesWhenStructuredTargetMissing() {
        XCTAssertEqual(
            WifiReconnectTargetSelection.preferred(
                structured: nil,
                legacyHost: "192.168.1.10"),
            .hostPort(host: "192.168.1.10", port: 27015))
    }

    func testRecentWifiResumeIntentIsConsumedOnlyOnce() throws {
        let suite = "ScreenCasting.RecentWifiResumeStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentWifiResumeStore.mark(now: 100, defaults: defaults)
        XCTAssertTrue(RecentWifiResumeStore.consumeIfValid(now: 110, defaults: defaults))
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 111, defaults: defaults))
    }

    func testExpiredRecentWifiResumeIntentIsConsumedAndRemoved() throws {
        let suite = "ScreenCasting.RecentWifiResumeExpiredTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentWifiResumeStore.mark(now: 100, defaults: defaults)
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 131, defaults: defaults))
        XCTAssertFalse(RecentWifiResumeStore.consumeIfValid(now: 110, defaults: defaults))
    }

    func testWifiReconnectTargetStoreClearRemovesTarget() throws {
        let suite = "ScreenCasting.WifiReconnectTargetClearTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        WifiReconnectTargetStore.save(
            .hostPort(host: "10.0.0.2", port: 27015),
            defaults: defaults)
        WifiReconnectTargetStore.clear(defaults: defaults)
        XCTAssertNil(WifiReconnectTargetStore.load(defaults: defaults))
    }
}

final class ClientStreamSettingsPreferenceTests: XCTestCase {
    func testClientStreamSettingsDefaultTo20MbpsAndAudioOn() throws {
        let suite = "ScreenCasting.ClientStreamSettingsDefaultsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            ClientStreamSettingsStore.load(defaults: defaults),
            .normalized(bitrateMbps: 20, audioEnabled: true))
    }

    func testClientStreamSettingsPersistBitrateAndAudio() throws {
        let suite = "ScreenCasting.ClientStreamSettingsStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)

        ClientStreamSettingsStore.save(desired, defaults: defaults)

        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults), desired)
    }

    func testClientStreamSettingsClampBitrateToSupportedRange() {
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 1,
                audioEnabled: true).bitrateMbps,
            3)
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 80,
                audioEnabled: false).bitrateMbps,
            50)
        XCTAssertEqual(
            ClientStreamSettingsPreference.normalized(
                bitrateMbps: 12.6,
                audioEnabled: false).bitrateMbps,
            13)
    }

    func testHostEffectiveStateDoesNotOverwriteClientDesiredSettings() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        let host = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 50,
            audioEnabled: true)

        model.receiveHostState(host, generation: 7)

        XCTAssertEqual(model.desired, desired)
        XCTAssertEqual(model.effective, host)
        XCTAssertEqual(model.generation, 7)
        var gate = ClientSettingsReconciliationGate()
        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
    }

    func testClientReconcilesMismatchOncePerHostGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressAlreadyAttempted)
    }

    func testMatchingHostStateDoesNotSendReconcile() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: desired,
            outcome: .state), .inSync)
    }

    func testStaleGenerationRejectionRetriesOnceWithCurrentGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
    }

    func testRepeatedStaleGenerationDoesNotLoop() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .suppressAlreadyAttempted)
    }

    func testNormalMismatchThenStaleRejectionSameGenerationDoesNotSendTwice() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .suppressAlreadyAttempted)
    }

    func testStaleGenerationRetriesWhenNoAttemptForCurrentGenerationExists() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 6,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.staleGeneration)), .send)
    }

    func testRuntimeApplyFailedDoesNotAutoRetrySameGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
    }

    func testRuntimeApplyFailedDoesNotRetryImmediately() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 40)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
    }

    func testPostRuntimeReadyStateRetriesRuntimeApplyFailedExactlyOnce() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 40)
    }

    func testDuplicatePostRuntimeReadyStateDoesNotRetryTwice() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testSecondRuntimeApplyFailedSameGenerationDoesNotLoop() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testPostReadyRetryUsesLatestClientDesiredValues() {
        let initial = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let latest = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 18,
            audioEnabled: true)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var model = ClientSettingsStateModel(desired: initial)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: model.desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        model.setDesired(latest)

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: model.desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(model.desired, latest)
    }

    func testPostReadyRetryUsesCurrentHostGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var model = ClientSettingsStateModel(desired: desired)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        model.receiveHostState(effective, generation: 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)
        XCTAssertEqual(model.generation, 41)
    }

    func testRuntimeRecoveryFailureAtNewerGenerationDoesNotRearmSameGeneration() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 40)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeApplyFailedGeneration, 41)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)

        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
        XCTAssertEqual(gate.runtimeReadyRetryGeneration, 41)
    }

    func testNewerGenerationReconcilesAfterConsumedRuntimeRecoveryFailure() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 41,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)

        XCTAssertEqual(gate.decision(
            hostGeneration: 42,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
        XCTAssertNil(gate.runtimeApplyFailedGeneration)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
        XCTAssertEqual(gate.lastAutomaticAttemptGeneration, 42)
    }

    func testSettingsDomainResetClearsRuntimeRecoveryState() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        gate.reset()

        XCTAssertNil(gate.runtimeApplyFailedGeneration)
        XCTAssertNil(gate.runtimeReadyRetryGeneration)
        XCTAssertEqual(gate.decision(
            hostGeneration: 0,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
    }

    func testExplicitUserMutationStillSendsAfterRuntimeRetrySuppressed() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 24,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .state)
        _ = gate.decision(
            hostGeneration: 40,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))

        XCTAssertEqual(
            DesiredSettingsSendPolicy.decision(canSend: true),
            .send)
    }

    func testInvalidRequestDoesNotAutoRetrySameGeneration() {
        assertHardRejectionDoesNotRetry(.invalidRequest)
    }

    func testInvalidBitrateDoesNotAutoRetrySameGeneration() {
        assertHardRejectionDoesNotRetry(.invalidBitrate)
    }

    private func assertHardRejectionDoesNotRetry(
        _ reason: TrustedSettingsRejectReason
    ) {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(reason)), .suppressHardRejection)
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .state), .suppressHardRejection)
    }

    func testExplicitUserChangeCanSendAfterAutomaticRejection() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()
        XCTAssertEqual(gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed)), .suppressHardRejection)
        XCTAssertEqual(
            DesiredSettingsSendPolicy.decision(canSend: true),
            .send)
    }

    func testDisconnectedDesiredChangeReportsWaitingForHost() {
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .waitingForHost),
            "Waiting for Host")
    }

    func testConnectedSendReportsApplyingOnlyWhenRequestIsActuallySent() {
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .sent(requestID: 9)),
            "Applying…")
        XCTAssertEqual(
            DesiredSettingsSendPolicy.status(for: .waitingForHost),
            "Waiting for Host")
    }

    func testNewerHostGenerationCanReconcileAgain() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 20,
            audioEnabled: true)
        var gate = ClientSettingsReconciliationGate()

        _ = gate.decision(
            hostGeneration: 7,
            desired: desired,
            effective: effective,
            outcome: .rejected(.runtimeApplyFailed))
        XCTAssertEqual(gate.decision(
            hostGeneration: 8,
            desired: desired,
            effective: effective,
            outcome: .state), .send)
    }

    func testUsbCommittedGenerationRequestsSettingsStateOnce() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestUsbSettings(committedGeneration: 12))
    }

    func testUsbSettingsSyncDoesNotRepeatForSameGeneration() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestUsbSettings(committedGeneration: 12))
        XCTAssertFalse(policy.shouldRequestUsbSettings(committedGeneration: 12))
    }

    func testNewUsbGenerationCanRequestSettingsStateAgain() {
        var policy = ClientSettingsSyncPolicy()
        XCTAssertTrue(policy.shouldRequestUsbSettings(committedGeneration: 12))
        XCTAssertTrue(policy.shouldRequestUsbSettings(committedGeneration: 13))
    }

    func testPersistedDesiredSettingsReconcileAfterUsbSettingsState() {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: 12,
            audioEnabled: false)
        var model = ClientSettingsStateModel(desired: desired)
        model.receiveHostState(
            .normalized(bitrateMbps: 20, audioEnabled: true),
            generation: 0)
        var sync = ClientSettingsSyncPolicy()
        var gate = ClientSettingsReconciliationGate()

        XCTAssertTrue(sync.shouldRequestUsbSettings(committedGeneration: 1))
        XCTAssertEqual(gate.decision(
            hostGeneration: model.generation,
            desired: model.desired,
            effective: model.effective,
            outcome: .state), .send)
    }
}
