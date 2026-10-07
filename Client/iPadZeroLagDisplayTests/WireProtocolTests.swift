import XCTest
import Network
import UIKit
import AVFoundation
@testable import iPadCasting

final class ExternalPointerInputTests: XCTestCase {
    private let point = CGPoint(x: 0.25, y: 0.75)

    func testAbsoluteHoverAndLetterboxRejection() {
        var state = ExternalPointerInputState()
        XCTAssertTrue(state.configure(active: true, generation: 7).isEmpty)
        let move = state.hover(point: point, generation: 7)
        XCTAssertEqual(move?.action, .move)
        XCTAssertEqual(move?.x, 16_384)
        XCTAssertEqual(move?.y, 49_151)
        XCTAssertNil(state.hover(point: nil, generation: 7))
        XCTAssertNil(state.hover(point: point, generation: 6))
    }

    func testPrimaryOwnershipDuplicateAndOutsideTerminalRelease() {
        var state = ExternalPointerInputState()
        _ = state.configure(active: true, generation: 7)
        XCTAssertEqual(state.begin(id: 1, point: point, primary: true, secondary: false, generation: 7)?.action, .leftDown)
        XCTAssertNil(state.begin(id: 1, point: point, primary: true, secondary: false, generation: 7))
        XCTAssertNil(state.end(id: 2, point: nil, generation: 7))
        XCTAssertEqual(state.end(id: 1, point: nil, generation: 7)?.action, .leftUp)
        XCTAssertNil(state.end(id: 1, point: nil, generation: 7))
    }

    func testSecondaryClickNeverOwnsPrimaryButton() {
        var state = ExternalPointerInputState()
        _ = state.configure(active: true, generation: 7)
        XCTAssertEqual(state.begin(id: 2, point: point, primary: false, secondary: true, generation: 7)?.action, .rightClick)
        XCTAssertNil(state.end(id: 2, point: point, generation: 7))
        XCTAssertTrue(state.retire().isEmpty)
    }

    func testGenerationReplacementReleasesOnceAndFencesOldOwner() {
        var state = ExternalPointerInputState()
        _ = state.configure(active: true, generation: 7)
        _ = state.begin(id: 1, point: point, primary: true, secondary: false, generation: 7)
        XCTAssertEqual(state.configure(active: true, generation: 8).map(\.action), [.leftUp])
        XCTAssertNil(state.end(id: 1, point: point, generation: 7))
        XCTAssertTrue(state.retire().isEmpty)
    }

    func testIndependentScrollRemaindersAndNoSyntheticCenter() {
        var state = ExternalPointerInputState()
        _ = state.configure(active: true, generation: 7)
        XCTAssertTrue(state.scroll(delta: CGPoint(x: 24, y: 24), generation: 7).isEmpty)
        _ = state.hover(point: point, generation: 7)
        XCTAssertTrue(state.scroll(delta: CGPoint(x: 12, y: 12), generation: 7).isEmpty)
        let wheels = state.scroll(delta: CGPoint(x: 12, y: 12), generation: 7)
        XCTAssertEqual(Set(wheels.map { $0.action.rawValue }), Set([PointerInputAction.verticalWheel.rawValue, PointerInputAction.horizontalWheel.rawValue]))
        XCTAssertTrue(wheels.allSatisfy { abs(Int($0.value)) == 120 && $0.x == 16_384 && $0.y == 49_151 })
        XCTAssertTrue(state.scroll(delta: CGPoint(x: 24, y: 24), generation: 6).isEmpty)
    }

    @MainActor func testRecognizersCannotConsumeDirectFingerInput() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let hover = (view.gestureRecognizers ?? []).compactMap { $0 as? UIHoverGestureRecognizer }
        let scroll = (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }.filter { $0.allowedScrollTypesMask == .continuous }
        XCTAssertEqual(hover.count, 1)
        XCTAssertEqual(scroll.count, 1)
        XCTAssertFalse(hover.first?.cancelsTouchesInView ?? true)
        XCTAssertFalse(scroll.first?.cancelsTouchesInView ?? true)
        XCTAssertEqual(scroll.first?.allowedTouchTypes, [])
        view.configureDirectTouch(active: true, generation: 7)
        view.configureExternalPointer(active: true, generation: 7)
        var contacts: [DirectTouchContactCommand] = []
        view.onDirectTouchContact = { contacts.append($0) }
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 200, y: 150), 255), .directTouch(.up, 1, CGPoint(x: 200, y: 150), 255)])
        XCTAssertEqual(contacts.map(\.phase), [.down, .up])
    }

    func testAppExplicitlySupportsIndirectInputEvents() {
        XCTAssertEqual(Bundle(for: PencilUIKitView.self).object(forInfoDictionaryKey: "UIApplicationSupportsIndirectInputEvents") as? Bool, true)
    }

    func testOutsideHoverPreventsScrollButKeepsFailSafeRelease() {
        var state = ExternalPointerInputState()
        _ = state.configure(active: true, generation: 7)
        _ = state.begin(id: 1, point: point, primary: true, secondary: false, generation: 7)
        XCTAssertEqual(state.move(id: 1, point: point, generation: 7)?.action, .move)
        XCTAssertNil(state.hover(point: nil, generation: 7))
        XCTAssertTrue(state.scroll(delta: CGPoint(x: 24, y: 24), generation: 7).isEmpty)
        XCTAssertEqual(state.retire().map(\.action), [.leftUp])
        XCTAssertNil(state.hover(point: point, generation: 7))
    }

    @MainActor func testViewportAndGenerationRetirementFenceOldButtonOwner() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let view = PencilUIKitView(frame: window.bounds)
        window.addSubview(view)
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.configureExternalPointer(active: true, generation: 7)
        var commands: [PointerInputCommand] = []
        view.onPointerInput = { commands.append($0) }
        view.handleExternalPointer(id: 1, phase: 1, point: CGPoint(x: 200, y: 150), primary: true, generation: 7)
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        view.handleExternalPointer(id: 1, phase: 4, point: .zero, generation: 7)
        XCTAssertEqual(commands.map(\.action), [.leftDown, .leftUp])
        view.handleExternalPointer(id: 2, phase: 1, point: CGPoint(x: 200, y: 150), primary: true, generation: 7)
        view.configureExternalPointer(active: true, generation: 8)
        view.handleExternalPointer(id: 2, phase: 4, point: .zero, generation: 7)
        view.removeFromSuperview()
        XCTAssertEqual(commands.map(\.action), [.leftDown, .leftUp, .leftDown, .leftUp])
    }

    @MainActor func testAggregateRetirementReleasesExternalAndDirectOwnersOnce() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let container = ConnectedPresentationContainer(frame: window.bounds)
        window.addSubview(container)
        let view = container.touchView
        view.frame = window.bounds
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.configureDirectTouch(active: true, generation: 7)
        view.configureExternalPointer(active: true, generation: 7)
        var buttons: [PointerInputCommand] = []
        var contacts: [DirectTouchContactCommand] = []
        view.onPointerInput = { buttons.append($0) }
        view.onDirectTouchContact = { contacts.append($0) }
        view.handleExternalPointer(id: 1, phase: 1, point: CGPoint(x: 200, y: 150), primary: true, generation: 7)
        view.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 200, y: 150), 255)])
        container.retireRemotePointerInputs()
        container.retireRemotePointerInputs()
        XCTAssertEqual(buttons.map(\.action), [.leftDown, .leftUp])
        XCTAssertEqual(contacts.map(\.phase), [.down, .cancel])
    }
}

final class UsbSplitCommitGateTests: XCTestCase {
    func testFeedbackWindowUnknownHistoryIsNotLoss() {
        var window = WifiFeedbackWindow()
        XCTAssertNil(window.highest)
        XCTAssertEqual(window.bitmap, UInt64.max)
        window.observe(100)
        XCTAssertEqual(window.highest, 100)
        XCTAssertEqual(window.bitmap, UInt64.max)

        window.observe(101)
        window.observe(103)
        XCTAssertEqual(window.highest, 103)
        XCTAssertEqual(window.bitmap, UInt64.max & ~UInt64(1))
        XCTAssertEqual((~window.bitmap).nonzeroBitCount, 1)

        window.observe(102)
        XCTAssertEqual(window.bitmap, UInt64.max)
    }

    func testFeedbackWindowWrapAndLargeJumpResetAreBounded() {
        var window = WifiFeedbackWindow()
        window.observe(UInt16.max)
        window.observe(0)
        XCTAssertEqual(window.highest, 0)
        XCTAssertEqual(window.bitmap, UInt64.max)

        window.observe(65)
        XCTAssertEqual(window.highest, 65)
        XCTAssertEqual(window.bitmap, 0)
        window.observe(64)
        XCTAssertEqual(window.bitmap, 1)
    }

    func testUnknownHistorySerializesAsAllReceivedBits() {
        let packet = WifiFeedbackCodec.packet(
            sequence: 1,
            ssrc: 2,
            window: WifiFeedbackWindow(),
            lastCompleted: 0,
            telemetry: WifiFeedbackTelemetry(
                lastDecoded: 0, lastPresented: 0, jitterMs: 0,
                rttP95Ms: 0, queueAgeP95Ms: 0, decodeP95Ms: 0),
            smoothedRttMs: 0,
            expiredFrames: 0,
            immediate: false,
            dependencyBreak: false,
            recoveryCompleted: false,
            rttToken: 0,
            rttSentNanoseconds: 0,
            frameIntervalMs: 1000.0 / 120,
            recoveryEpisode: 0)
        XCTAssertEqual(Array(packet[20..<28]),
                       Array(repeating: UInt8.max, count: 8))
    }

    func testFeedbackWindowReportsOnlyNewForwardGap() {
        var window = WifiFeedbackWindow()
        XCTAssertFalse(window.observe(100))
        XCTAssertFalse(window.observe(101))
        XCTAssertTrue(window.observe(103))
        XCTAssertEqual(window.bitmap, UInt64.max & ~UInt64(1))
        XCTAssertFalse(window.observe(104))
        XCTAssertFalse(window.observe(102))
        XCTAssertEqual(window.bitmap, UInt64.max)
        XCTAssertFalse(window.observe(102))
    }

    func testFeedbackWindowWrapAdjacencyDoesNotReportGap() {
        var window = WifiFeedbackWindow()
        XCTAssertFalse(window.observe(UInt16.max))
        XCTAssertFalse(window.observe(0))
        XCTAssertEqual(window.bitmap, UInt64.max)
    }

    func testFeedbackWindowLargeJumpReportsOneBoundedGap() {
        var window = WifiFeedbackWindow()
        XCTAssertFalse(window.observe(100))
        XCTAssertTrue(window.observe(165))
        XCTAssertEqual(window.bitmap, 0)
        XCTAssertFalse(window.observe(166))
        XCTAssertFalse(window.observe(164))
        XCTAssertEqual(window.bitmap, 0b11)
    }

    func testAuthenticatedForwardGapRequestsImmediateFeedbackBeforeExpiry() {
        let queue = DispatchQueue(label: "test.wifi.feedback.gap")
        let receiver = WifiMediaReceiver(
            networkQueue: queue,
            decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in },
            onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in })
        queue.sync {
            receiver.simulateActivePacketSequenceForTesting(100, generation: 7)
            receiver.simulateActivePacketSequenceForTesting(101, generation: 7)
            XCTAssertEqual(receiver.immediateGapFeedbackCountForTesting, 0)
            receiver.simulateActivePacketSequenceForTesting(103, generation: 7)
            XCTAssertEqual(receiver.immediateGapFeedbackCountForTesting, 1)
            receiver.simulateActivePacketSequenceForTesting(104, generation: 7)
            receiver.simulateActivePacketSequenceForTesting(102, generation: 7)
            XCTAssertEqual(receiver.immediateGapFeedbackCountForTesting, 1)
        }
    }

    func testForwardGapStillRequestsImmediateFeedbackDuringRecovery() {
        let queue = DispatchQueue(label: "test.wifi.feedback.recovery.gap")
        let receiver = WifiMediaReceiver(
            networkQueue: queue,
            decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in },
            onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in })
        queue.sync {
            receiver.simulateActivePacketSequenceForTesting(100, generation: 7)
            receiver.requestImmediateRecoveryFeedback(generation: 7)
            let episode = receiver.recoveryEpisodeForTesting
            receiver.simulateActivePacketSequenceForTesting(103, generation: 7)
            XCTAssertEqual(receiver.immediateGapFeedbackCountForTesting, 1)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode)
        }
    }

    func testStalledRecoveryRetriesOnceAtBoundedTimerTick() {
        let queue = DispatchQueue(label: "test.wifi.feedback.recovery.timer")
        let receiver = WifiMediaReceiver(
            networkQueue: queue,
            decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in },
            onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in })
        queue.sync {
            receiver.simulateActivePacketSequenceForTesting(100, generation: 7)
            receiver.beginRecoveryEpisodeForTesting(at: 10)
            let episode = receiver.recoveryEpisodeForTesting
            receiver.feedbackTimerTickForTesting(at: 10.050)
            receiver.feedbackTimerTickForTesting(at: 10.099)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode)
            receiver.feedbackTimerTickForTesting(at: 10.125)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode + 1)
            receiver.simulatePendingRecoveryCandidateForTesting(sequence: 5)
            receiver.feedbackTimerTickForTesting(at: 10.300)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode + 1)
            receiver.decoderDidComplete(sequence: 5, generation: 7,
                                        succeeded: true)
            XCTAssertNil(receiver.recoveryEpisodeStartedAtForTesting)
            receiver.feedbackTimerTickForTesting(at: 10.500)
            XCTAssertEqual(receiver.recoveryEpisodeForTesting, episode + 1)
        }
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

final class OptionalUsbAudioBindingTests: XCTestCase {
    func testAudioBindingReceiveFailureCancelsCandidateWithoutGlobalFailure() {
        assertReceiveFailure(lane: .audio, expectedGlobalFailures: 0)
    }

    func testMandatoryVideoBindingReceiveFailureRemainsFatal() {
        assertReceiveFailure(lane: .video, expectedGlobalFailures: 1)
    }

    private func assertReceiveFailure(lane: UsbLaneKind, expectedGlobalFailures: Int) {
        let queue = DispatchQueue(label: "OptionalUsbAudioBindingTests.\(lane)")
        let received = expectation(description: "binding receive callback completed")
        let cancelled = expectation(description: "candidate cancelled")
        var globalFailures = 0
        var bound = 0
        let server = UsbLaneServer(
            networkQueue: queue,
            parametersProvider: { .tcp },
            onBound: { _, _, _ in bound += 1 },
            onFailure: { _ in globalFailures += 1 })
        let candidate = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        candidate.stateUpdateHandler = { state in
            if case .cancelled = state { cancelled.fulfill() }
        }
        server.bindingReceiverForTesting = { connection, completion in
            connection.start(queue: queue)
            completion(nil, nil, false, .posix(.ECONNRESET))
            received.fulfill()
        }
        server.receiveBindingForTesting(candidate, lane: lane)
        wait(for: [received, cancelled], timeout: 5)
        queue.sync {
            XCTAssertEqual(globalFailures, expectedGlobalFailures)
            XCTAssertEqual(bound, 0)
        }
    }
}

final class CommittedAudioAvailabilityTests: XCTestCase {
    func testSettingsCannotStartPlaybackForVideoOnlyUsbCommit() throws {
        try withManager { manager, actions in
            manager.commitAudioTransportForTesting(
                mode: RealtimeTransportMode.usbSplitTLS, audioAvailable: false)
            sendSettings(manager, enabled: false, generation: 1)
            sendSettings(manager, enabled: true, generation: 2)
            XCTAssertFalse(actions().contains(true))
            XCTAssertEqual(manager.usbSessionSnapshot().committedGeneration,
                           manager.usbSessionSnapshot().generation)
        }
    }

    func testPersistedDesiredOffPreventsAudioCapableCommitStartingPlayback() throws {
        try withManager(desiredAudio: false) { manager, actions in
            manager.commitAudioTransportForTesting(
                mode: RealtimeTransportMode.usbSplitTLS, audioAvailable: true)
            XCTAssertFalse(actions().contains(true))
        }
    }

    func testAudioCapableUsbSettingsOffOnAndStaleReconcile() throws {
        try withManager { manager, actions in
            let mode = RealtimeTransportMode.usbSplitTLS
            manager.commitAudioTransportForTesting(mode: mode, audioAvailable: true)
            sendSettings(manager, enabled: false, generation: 1)
            sendSettings(manager, enabled: true, generation: 2)
            XCTAssertEqual(actions(), [true, false, true])
            manager.reconcileAudioForTesting(
                generation: manager.usbSessionSnapshot().generation &+ 1,
                mode: mode, audioEnabled: true)
            XCTAssertEqual(actions(), [true, false, true])
        }
    }

    func testWifiOpusAndLegacyTimerBehaviorRemainDistinct() throws {
        try withManager { manager, actions in
            manager.commitAudioTransportForTesting(
                mode: RealtimeTransportMode.wifiRTP, audioAvailable: true)
            XCTAssertEqual(actions(), [true])
        }
        try withManager { manager, actions in
            manager.commitAudioTransportForTesting(
                mode: RealtimeTransportMode.legacyTLS, audioAvailable: true)
            XCTAssertEqual(actions(), [])
        }
    }

    func testVideoOnlyAvailabilityDoesNotLeakIntoNextCapableGeneration() throws {
        try withManager { manager, actions in
            let mode = RealtimeTransportMode.usbSplitTLS
            manager.commitAudioTransportForTesting(mode: mode, audioAvailable: false)
            let previous = manager.usbSessionSnapshot().generation
            manager.stopForTesting()
            manager.commitAudioTransportForTesting(mode: mode, audioAvailable: true)
            XCTAssertGreaterThan(manager.usbSessionSnapshot().generation, previous)
            XCTAssertEqual(actions(), [false, true])
            sendSettings(manager, enabled: true, generation: 1)
            sendSettings(manager, enabled: true, generation: 2)
            XCTAssertEqual(actions(), [false, true])
        }
    }

    private func withManager(
        desiredAudio: Bool = true,
        _ body: (NetworkManager, () -> [Bool]) throws -> Void
    ) throws {
        let suite = "CommittedAudioAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ClientStreamSettingsStore.save(
            .normalized(bitrateMbps: 20, audioEnabled: desiredAudio), defaults: defaults)
        let manager = NetworkManager(userDefaults: defaults)
        XCTAssertEqual(manager.desiredAudioEnabled, desiredAudio)
        var actions: [Bool] = []
        manager.realtimeAudioPlaybackForTesting = { actions.append($0) }
        manager.controlSendForAudioTesting = { _, completion in completion(nil) }
        defer { manager.stopForTesting() }
        try body(manager, { manager.networkQueueForTesting.sync { actions } })
    }

    private func sendSettings(_ manager: NetworkManager, enabled: Bool, generation: UInt64) {
        var payload = Data(count: 24)
        payload[0] = 1
        payload[1] = enabled ? 1 : 0
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: generation.littleEndian, toByteOffset: 8, as: UInt64.self)
            bytes.storeBytes(of: UInt32(20_000_000).littleEndian, toByteOffset: 16, as: UInt32.self)
        }
        manager.networkQueueForTesting.sync {
            manager.receiveSettingsState(payload, outcome: .state)
        }
    }
}

final class AudioInterruptionOwnershipTests: XCTestCase {
    private final class LivenessFixture {
        let audio = AudioManager.makeForTesting()
        var now: TimeInterval = 10
        var running = false
        var starts = 0
        var completions: [() -> Void] = []
        init() {
            audio.manualPlayoutForTesting = true
            audio.engineRunningForTesting = { [weak self] in self?.running == true }
            audio.engineStartForTesting = { [weak self] in self?.starts += 1; self?.running = true }
            audio.clockForTesting = { [weak self] in self?.now ?? 0 }
            audio.pcmScheduleForTesting = { [weak self] _, completion in self?.completions.append(completion) }
            audio.beginRealtimeSession(generation: 40, profile: .wifi)
            audio.audioQueueForTesting.sync { }
        }
        deinit { audio.reset(); audio.audioQueueForTesting.sync { } }
        func fill() {
            for _ in 0..<20 { audio.playPCMData(Data(repeating: 0, count: 480 * 4), generation: 40) }
            audio.playPCMData(Data(repeating: 0, count: 480 * 4), generation: 40)
            audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.queued, 9600)
        }
        func resume(_ generation: UInt64 = 40) {
            audio.resumeCurrentRealtimeSession(generation: generation, profile: .wifi)
            audio.audioQueueForTesting.sync { }
        }
        func tick(_ time: TimeInterval) { now = time; audio.playoutTickForTesting() }
    }

    func testEngineStartUsesActualEngineRunningStateNotOnlyCachedFlag() {
        let f = LivenessFixture()
        f.audio.cachedEngineStartedForTesting = true
        f.running = false
        f.audio.startEngineForTesting()
        XCTAssertEqual(f.starts, 1)
        f.audio.startEngineForTesting()
        XCTAssertEqual(f.starts, 1)
    }

    func testEngineConfigurationChangeFencesOldPlaybackEpoch() {
        let f = LivenessFixture(); f.fill()
        let before = f.audio.playbackStateForTesting
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: f.audio.engineForTesting)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, before.epoch + 1)
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 0)
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, 40)
    }

    func testEngineConfigurationChangeRecoveryIsQueuedNotSynchronous() async {
        let f = LivenessFixture()
        let entered = expectation(description: "audio queue blocked")
        let release = DispatchSemaphore(value: 0)
        f.audio.audioQueueForTesting.async { entered.fulfill(); release.wait() }
        await fulfillment(of: [entered], timeout: 1)
        let posted = expectation(description: "notification returns without waiting for audio queue")
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: f.audio.engineForTesting)
            posted.fulfill()
        }
        await fulfillment(of: [posted], timeout: 1)
        release.signal()
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, 2)
    }

    func testRouteChangeRecoveryKeepsCurrentGenerationOnly() {
        let f = LivenessFixture()
        f.audio.beginRealtimeSession(generation: 41, profile: .wifi)
        f.audio.audioQueueForTesting.sync { }
        let before = f.audio.playbackStateForTesting
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, before.epoch + 1)
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, 41)
        f.audio.reset(); f.audio.audioQueueForTesting.sync { }
        let retired = f.audio.playbackStateForTesting
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, retired.epoch)
        XCTAssertNil(f.audio.playbackStateForTesting.generation)
    }

    func testManualWifiResumeCoalescesImmediateEngineConfigurationRecovery() {
        let f = LivenessFixture(); f.resume()
        let before = f.audio.playbackStateForTesting
        f.now += 0.01
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: f.audio.engineForTesting)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 1)
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, before.epoch)
    }

    func testManualWifiResumeCoalescesImmediateRouteChangeRecovery() {
        let f = LivenessFixture(); f.resume()
        f.now += 0.01
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 1)
    }

    func testRealLaterRouteChangeStillRecoversAfterCooldown() {
        let f = LivenessFixture(); f.resume()
        f.now += 1.01
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 2)
    }

    func testCoalescedNotificationDoesNotIncrementEpochTwice() {
        let f = LivenessFixture(); f.resume()
        let epoch = f.audio.playbackStateForTesting.epoch
        for name in [AVAudioSession.routeChangeNotification, .AVAudioEngineConfigurationChange] {
            NotificationCenter.default.post(name: name,
                object: name == .AVAudioEngineConfigurationChange ? f.audio.engineForTesting : nil)
            f.audio.audioQueueForTesting.sync { }
        }
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, epoch)
    }

    func testCoalescedNotificationDoesNotDiscardFreshQueuedFrames() {
        let f = LivenessFixture(); f.resume()
        f.audio.playPCMData(Data(repeating: 0, count: 480 * 4), generation: 40)
        f.audio.audioQueueForTesting.sync { }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 480)
    }

    func testCoalescedRecoveryPreservesCurrentGenerationOwnership() {
        let f = LivenessFixture(); f.resume()
        let before = f.audio.playbackStateForTesting
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, before.generation)
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, before.epoch)
        // A real replacement must not inherit the preceding generation's cooldown.
        f.audio.beginRealtimeSession(generation: 41, profile: .wifi)
        f.audio.audioQueueForTesting.sync { }
        let replacement = f.audio.playbackStateForTesting
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, 41)
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, replacement.epoch + 1)
    }

    func testPcmRejectionReportsActualEngineStateNotCachedStartedFlag() {
        let audio = AudioManager.makeForTesting()
        audio.manualPlayoutForTesting = true
        audio.engineStartForTesting = { }
        audio.engineRunningForTesting = { false }
        defer { audio.reset(); audio.audioQueueForTesting.sync { } }
        audio.beginLegacySession(generation: 130)
        audio.audioQueueForTesting.sync { }
        audio.cachedEngineStartedForTesting = true
        audio.playPCMData(Data(repeating: 0, count: 9_601 * 4), generation: 130)
        var records: [String] = []
        audio.publishDiagnostics(generation: 130, profile: "usb", opus: false, receiveRejects: "", sink: { records.append($0) })
        audio.audioQueueForTesting.sync { }
        XCTAssertTrue(records.first?.contains("pcm_reject_engine_running=0") == true)
    }

    func testPreservedWifiResumeClearsQueuedFramesAndStaleJitter() {
        let f = LivenessFixture(); f.fill()
        f.audio.playOpusData(Data([1]), sequence: 1, timestamp: 480, generation: 40)
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.interruptionStateForTesting.packets, 1)
        f.resume()
        XCTAssertEqual(f.audio.interruptionStateForTesting.queuedFrames, 0)
        XCTAssertEqual(f.audio.interruptionStateForTesting.packets, 0)
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, 40)
    }

    func testPreservedWifiResumeDoesNotReplayOldPCM() {
        let f = LivenessFixture(); f.fill()
        let scheduled = f.completions.count
        f.resume()
        XCTAssertEqual(f.completions.count, scheduled)
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 0)
    }

    func testPreservedWifiResumeRejectsWrongGeneration() {
        let f = LivenessFixture(); f.fill()
        let before = f.audio.playbackStateForTesting
        f.resume(39)
        XCTAssertEqual(f.audio.playbackStateForTesting.epoch, before.epoch)
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, before.queued)
    }

    func testSaturatedQueueWithoutPlaybackCompletionsTriggersOneRecovery() {
        let f = LivenessFixture(); f.fill()
        f.tick(10.249)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 0)
        f.tick(10.251)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 1)
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 0)
        XCTAssertEqual(f.audio.playbackStateForTesting.generation, 40)
    }

    func testHealthyPlaybackCompletionsNeverTriggerStallRecovery() {
        let f = LivenessFixture(); f.fill()
        f.now = 10.2
        f.completions[0]()
        f.audio.audioQueueForTesting.sync { }
        f.tick(10.4)
        XCTAssertEqual(f.audio.playbackStateForTesting.completions, 1)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 0)
    }

    func testStallRecoveryCooldownPreventsRestartLoop() {
        let f = LivenessFixture(); f.fill()
        f.tick(10.3)
        f.now = 10.4; f.fill()
        f.tick(10.8)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 1)
        f.tick(11.31)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 2)
    }

    func testOldEpochCompletionCannotMutateNewQueuedFrames() {
        let f = LivenessFixture(); f.fill()
        let oldCompletion = f.completions[0]
        f.resume()
        f.audio.playPCMData(Data(repeating: 0, count: 480 * 4), generation: 40)
        f.audio.audioQueueForTesting.sync { }
        oldCompletion()
        f.audio.audioQueueForTesting.sync { }
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 480)
        XCTAssertEqual(f.audio.playbackStateForTesting.completions, 0)
    }

    func testResetCancelsPendingRecoveryOwnership() {
        let f = LivenessFixture(); f.fill()
        f.audio.reset()
        f.resume()
        f.tick(11)
        XCTAssertNil(f.audio.playbackStateForTesting.generation)
        XCTAssertEqual(f.audio.playbackStateForTesting.queued, 0)
        XCTAssertEqual(f.audio.playbackStateForTesting.recoveries, 0)
    }

    func testLegacyPcmRejectionRetainsBoundedContextAtExistingDiagnosticCadence() {
        let audio = AudioManager.makeForTesting()
        audio.engineStartForTesting = { }
        defer { audio.reset(); audio.audioQueueForTesting.sync { } }
        audio.beginLegacySession(generation: 130)
        audio.playPCMData(Data(repeating: 0, count: 9_601 * 4), generation: 130)
        audio.audioQueueForTesting.sync { }
        var records: [String] = []
        audio.publishDiagnostics(generation: 130, profile: "usb", opus: false, receiveRejects: "", sink: { records.append($0) })
        audio.audioQueueForTesting.sync { }
        XCTAssertEqual(records.count, 1)
        let record = records.first ?? ""
        XCTAssertTrue(record.contains("pcm_reject=1"))
        for field in ["pcm_reject_generation=130", "pcm_reject_epoch=1", "pcm_reject_incoming_frames=9601", "pcm_reject_queued_before=0", "pcm_reject_cap=9600", "pcm_reject_player_playing=", "pcm_reject_engine_running="] {
            XCTAssertTrue(record.contains(field), "Missing rejection context: \(field)")
        }
        XCTAssertEqual(audio.interruptionStateForTesting.queuedFrames, 0)
    }

    func testLegacyPcmReplacementClearsOldRejectionContextAndRejectsStalePacket() {
        let audio = AudioManager.makeForTesting()
        audio.engineStartForTesting = { }
        defer { audio.reset(); audio.audioQueueForTesting.sync { } }
        audio.beginLegacySession(generation: 130)
        audio.playPCMData(Data(repeating: 0, count: 9_601 * 4), generation: 130)
        audio.beginLegacySession(generation: 131)
        audio.playPCMData(Data(repeating: 0, count: 9_601 * 4), generation: 130)
        var records: [String] = []
        audio.publishDiagnostics(generation: 131, profile: "usb", opus: false, receiveRejects: "", sink: { records.append($0) })
        audio.audioQueueForTesting.sync { }
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].contains("pcm_reject=0"))
        XCTAssertTrue(records[0].contains("pcm_reject_context=none"))
        XCTAssertFalse(records[0].contains("pcm_reject_generation=130"))
    }

    func testIdleInterruptionEndCannotStartPlayback() {
        withAudio { audio, resumes in
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 0)
        }
    }

    func testSameGenerationResumesExactlyOnce() {
        withAudio { audio, resumes in
            audio.beginRealtimeSession(generation: 40, profile: .usb)
            audio.interruptForTesting(began: true)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 1)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 1)
        }
    }

    func testDisableDuringInterruptionCannotResumePlayback() {
        withAudio { audio, resumes in
            audio.beginRealtimeSession(generation: 40, profile: .wifi)
            audio.interruptForTesting(began: true)
            audio.reset()
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 0)
        }
    }

    func testReplacementGenerationCannotBeResumedByOldInterruption() {
        withAudio { audio, resumes in
            audio.beginRealtimeSession(generation: 40, profile: .usb)
            audio.interruptForTesting(began: true)
            audio.beginRealtimeSession(generation: 41, profile: .usb)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 0)
        }
    }

    func testSameGenerationReplacementEpochCannotBeResumedByOldInterruption() {
        withAudio { audio, resumes in
            audio.beginRealtimeSession(generation: 40, profile: .wifi)
            audio.interruptForTesting(began: true)
            audio.beginRealtimeSession(generation: 40, profile: .wifi)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 0)
        }
    }

    func testMissingShouldResumeDoesNotStartPlayback() {
        withAudio { audio, resumes in
            audio.beginRealtimeSession(generation: 40, profile: .usb)
            audio.interruptForTesting(began: true)
            audio.interruptForTesting(began: false, shouldResume: false)
            XCTAssertEqual(resumes(), 0)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 0)
        }
    }

    func testInterruptionStopsTimerAndDoesNotAccumulatePausedPackets() {
        withAudio { audio, _ in
            audio.beginRealtimeSession(generation: 40, profile: .usb)
            audio.interruptForTesting(began: true)
            audio.playOpusData(Data([0x01]), sequence: 1, timestamp: 480, generation: 40)
            let paused = audio.interruptionStateForTesting
            XCTAssertFalse(paused.timerActive)
            XCTAssertEqual(paused.packets, 0)
            XCTAssertEqual(paused.queuedFrames, 0)
        }
    }

    func testLegacyPlaybackOwnsResumeAndResetRevokesIt() {
        withAudio { audio, resumes in
            audio.beginLegacySession(generation: 40)
            audio.interruptForTesting(began: true)
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 1)
            XCTAssertFalse(audio.interruptionStateForTesting.timerActive)
            audio.interruptForTesting(began: true)
            audio.reset()
            audio.interruptForTesting(began: false)
            XCTAssertEqual(resumes(), 1)
        }
    }

    func testLegacyReplacementRejectsOldInterruptionAndStalePcm() {
        withAudio { audio, resumes in
            audio.beginLegacySession(generation: 40)
            audio.interruptForTesting(began: true)
            audio.beginLegacySession(generation: 41)
            audio.interruptForTesting(began: false)
            audio.playPCMData(Data(repeating: 0, count: 1920), generation: 40)
            XCTAssertEqual(resumes(), 0)
            XCTAssertEqual(audio.interruptionStateForTesting.queuedFrames, 0)
        }
    }

    private func withAudio(_ body: (AudioManager, () -> Int) -> Void) {
        let audio = AudioManager.makeForTesting()
        var resumes = 0
        audio.interruptionResumeForTesting = { resumes += 1 }
        defer {
            audio.reset()
            audio.audioQueueForTesting.sync { }
        }
        body(audio, { audio.audioQueueForTesting.sync { resumes } })
    }
}

final class DirectTouchGestureStateMachineTests: XCTestCase {
    private func pointerActions(
        _ outputs: [DirectTouchGestureOutput]
    ) -> [PointerInputAction] {
        outputs.compactMap {
            if case .pointer(let action, _, _) = $0 { return action }
            return nil
        }
    }

    private func touchPhases(_ outputs: [DirectTouchGestureOutput]) -> [DirectTouchPhase] {
        outputs.compactMap { if case .directTouch(let phase, _, _, _) = $0 { return phase }; return nil }
    }

    private func touchPoint(_ outputs: [DirectTouchGestureOutput]) -> CGPoint? {
        outputs.compactMap { if case .directTouch(_, _, let point, _) = $0 { return point }; return nil }.last
    }

    func testSingleAndDoubleTapProduceClicksWithoutSettings() {
        var machine = DirectTouchGestureStateMachine()
        XCTAssertTrue(machine.begin(id: 1, point: .zero, timestamp: 0).isEmpty)
        XCTAssertEqual(
            touchPhases(machine.end(id: 1, point: CGPoint(x: 2, y: 2), timestamp: 0.1)),
            [.down, .up])
        XCTAssertTrue(machine.begin(id: 2, point: .zero, timestamp: 0.15).isEmpty)
        let second = machine.end(id: 2, point: .zero, timestamp: 0.25)
        XCTAssertEqual(touchPhases(second), [.down, .up])
        XCTAssertFalse(second.contains(.openSettings))
    }

    func testVerticalScrollBelow72PointsEmitsNoWheel() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 0, y: 71), timestamp: 0.01).isEmpty)
    }

    func testVerticalScrollCrossing72PointsEmitsOne120Notch() {
        for direction: CGFloat in [-1, 1] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            let point = CGPoint(x: 0, y: direction * 72)
            XCTAssertEqual(machine.move(id: 1, point: point, timestamp: 0.01), [.pointer(.verticalWheel, point, direction > 0 ? 120 : -120)])
        }
    }

    func testVerticalScrollAccumulatesResidualDistance() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 0, y: 30), timestamp: 0.01).isEmpty)
        XCTAssertEqual(machine.move(id: 1, point: CGPoint(x: 0, y: 80), timestamp: 0.02), [.pointer(.verticalWheel, CGPoint(x: 0, y: 80), 120)])
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 0, y: 143), timestamp: 0.03).isEmpty)
        XCTAssertEqual(machine.move(id: 1, point: CGPoint(x: 0, y: 144), timestamp: 0.04), [.pointer(.verticalWheel, CGPoint(x: 0, y: 144), 120)])
    }

    func testHorizontalScrollBelow72PointsEmitsNoWheel() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 71, y: 0), timestamp: 0.01).isEmpty)
    }

    func testHorizontalScrollCrossing72PointsEmitsOne120Notch() {
        for direction: CGFloat in [-1, 1] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            let point = CGPoint(x: direction * 72, y: 0)
            XCTAssertEqual(machine.move(id: 1, point: point, timestamp: 0.01), [.pointer(.horizontalWheel, point, direction > 0 ? -120 : 120)])
        }
    }

    func testLargeMoveDoesNotEmitUnboundedCatchUpBurst() {
        for horizontal in [false, true] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            let point = horizontal ? CGPoint(x: 1000, y: 0) : CGPoint(x: 0, y: 1000)
            let expected: DirectTouchGestureOutput = .pointer(horizontal ? .horizontalWheel : .verticalWheel, point, horizontal ? -120 : 120)
            XCTAssertEqual(machine.move(id: 1, point: point, timestamp: 0.01), [expected])
            XCTAssertEqual(machine.move(id: 1, point: point, timestamp: 0.02), [expected])
        }
    }

    func testScrollAccumulatorResetsAtGestureEnd() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.move(id: 1, point: CGPoint(x: 0, y: 70), timestamp: 0.01)
        machine.end(id: 1, point: CGPoint(x: 0, y: 70), timestamp: 0.02)
        machine.begin(id: 2, point: .zero, timestamp: 0.03)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 0, y: 13), timestamp: 0.04).isEmpty)
        machine.retire()
        machine.begin(id: 3, point: .zero, timestamp: 0.05)
        XCTAssertTrue(machine.move(id: 3, point: CGPoint(x: 0, y: 71), timestamp: 0.06).isEmpty)
    }

    func testScrollAxisClassifierWithJitterRemainsSymmetric() {
        for horizontal in [false, true] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            let point = horizontal ? CGPoint(x: 30, y: 18) : CGPoint(x: 18, y: 30)
            machine.move(id: 1, point: point, timestamp: 0.01)
            XCTAssertEqual(machine.scrollClassification?.horizontal, horizontal)
        }
    }

    func testOneFingerScrollAccumulatesWhileTinyMotionRemainsTap() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: CGPoint(x: 10, y: 10), timestamp: 0)
        let classified = machine.move(id: 1, point: CGPoint(x: 10, y: 23), timestamp: 0.05)
        XCTAssertTrue(classified.isEmpty)
        XCTAssertEqual(machine.scrollClassification?.horizontal, false)
        let moved = machine.move(id: 1, point: CGPoint(x: 10, y: 30), timestamp: 0.1)
        XCTAssertTrue(moved.isEmpty)
        XCTAssertTrue(machine.end(id: 1, point: CGPoint(x: 10, y: 30), timestamp: 0.15).isEmpty)
        machine.begin(id: 2, point: .zero, timestamp: 1)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 4, y: 4), timestamp: 1.05).isEmpty)
        XCTAssertEqual(touchPhases(machine.end(id: 2, point: CGPoint(x: 4, y: 4), timestamp: 1.1)), [.down, .up])
    }

    func testLargeScrollMoveEmitsOneAggregatedSignedWheelCommand() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(pointerActions(machine.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.01)), [.verticalWheel])
        for (time, y, units) in [(0.02, CGFloat(378), Int16(120)), (0.03, CGFloat(42), Int16(-120))] {
            let output = machine.move(id: 1, point: CGPoint(x: 0, y: y), timestamp: time)
            XCTAssertEqual(output, [.pointer(.verticalWheel, CGPoint(x: 0, y: y), units)])
            XCTAssertTrue(touchPhases(output).isEmpty)
        }
    }

    func testQuantizedVerticalWheelPreservesDirectionAndFractionalDistance() {
        for (distance, units): (CGFloat, Int16) in [(7, 0), (21, 0), (72, 120), (-72, -120)] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            machine.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.01)
            let point = CGPoint(x: 0, y: 72 + distance)
            XCTAssertEqual(machine.move(id: 1, point: point, timestamp: 0.02), units == 0 ? [] : [.pointer(.verticalWheel, point, units)])
        }
        var fractional = DirectTouchGestureStateMachine()
        fractional.begin(id: 1, point: .zero, timestamp: 0)
        fractional.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.01)
        var total = 0
        for offset in 1...72 {
            let point = CGPoint(x: 0, y: 72 + CGFloat(offset))
            let output = fractional.move(id: 1, point: point, timestamp: 0.01 + Double(offset) * 0.01)
            XCTAssertTrue(touchPhases(output).isEmpty)
            total += output.reduce(0) { sum, event in
                if case .pointer(.verticalWheel, _, let value) = event { return sum + Int(value) }; return sum
            }
        }
        XCTAssertEqual(total, 120)
    }

    func testHorizontalScrollIsQuantizedInvertedAndAxisLocked() {
        var right = DirectTouchGestureStateMachine()
        right.begin(id: 1, point: CGPoint(x: 100, y: 100), timestamp: 0)
        XCTAssertEqual(right.move(id: 1, point: CGPoint(x: 172, y: 100), timestamp: 0.01),
            [.pointer(.horizontalWheel, CGPoint(x: 172, y: 100), -120)])
        for (time, point, units) in [(0.02, CGPoint(x: 179, y: 100), Int16(0)), (0.03, CGPoint(x: 244, y: 100), Int16(-120)), (0.04, CGPoint(x: 244, y: 200), Int16(0))] {
            let output = right.move(id: 1, point: point, timestamp: time)
            XCTAssertEqual(output, units == 0 ? [] : [.pointer(.horizontalWheel, point, units)])
            XCTAssertTrue(touchPhases(output).isEmpty)
        }
        var left = DirectTouchGestureStateMachine()
        left.begin(id: 1, point: CGPoint(x: 100, y: 100), timestamp: 0)
        XCTAssertEqual(left.move(id: 1, point: CGPoint(x: 28, y: 100), timestamp: 0.01),
            [.pointer(.horizontalWheel, CGPoint(x: 28, y: 100), 120)])
        XCTAssertEqual(left.move(id: 1, point: CGPoint(x: -44, y: 100), timestamp: 0.02),
            [.pointer(.horizontalWheel, CGPoint(x: -44, y: 100), 120)])
        var vertical = DirectTouchGestureStateMachine()
        vertical.begin(id: 1, point: .zero, timestamp: 0)
        vertical.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.01)
        XCTAssertTrue(vertical.move(id: 1, point: CGPoint(x: 100, y: 79), timestamp: 0.02).isEmpty)
        XCTAssertEqual(vertical.scrollClassification?.horizontal, false)
    }

    func testHorizontalScrollWithMinorVerticalJitterLocksHorizontal() {
        for direction: CGFloat in [-1, 1] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: CGPoint(x: 100, y: 100), timestamp: 0)
            for (index, delta) in [CGPoint(x: 30, y: 18), CGPoint(x: 45, y: 25), CGPoint(x: 60, y: 32)].enumerated() {
                let point = CGPoint(x: 100 + direction * delta.x, y: 100 + delta.y)
                let outputs = machine.move(id: 1, point: point, timestamp: Double(index + 1) * 0.05)
                XCTAssertTrue(outputs.isEmpty)
                XCTAssertEqual(machine.scrollClassification?.horizontal, true)
                XCTAssertTrue(touchPhases(outputs).isEmpty)
                if case .pointer(_, _, let units) = outputs.first {
                    XCTAssertEqual(units > 0, direction < 0)
                }
            }
        }
    }

    func testVerticalScrollWithMinorHorizontalJitterLocksVertical() {
        for direction: CGFloat in [-1, 1] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: CGPoint(x: 100, y: 100), timestamp: 0)
            for (index, delta) in [CGPoint(x: 18, y: 30), CGPoint(x: 25, y: 45), CGPoint(x: 32, y: 60)].enumerated() {
                let outputs = machine.move(id: 1,
                    point: CGPoint(x: 100 + delta.x, y: 100 + direction * delta.y),
                    timestamp: Double(index + 1) * 0.05)
                XCTAssertTrue(outputs.isEmpty)
                XCTAssertEqual(machine.scrollClassification?.horizontal, false)
                XCTAssertTrue(touchPhases(outputs).isEmpty)
                if case .pointer(_, _, let units) = outputs.first {
                    XCTAssertEqual(units > 0, direction > 0)
                }
            }
        }
    }

    func testAmbiguousDiagonalWaitsForDominantAxis() {
        for horizontal in [false, true] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 15, y: 15), timestamp: 0.05).isEmpty)
            XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 20, y: 19), timestamp: 0.1).isEmpty)
            let point = horizontal ? CGPoint(x: 35, y: 20) : CGPoint(x: 20, y: 35)
            let output = machine.move(id: 1, point: point, timestamp: 0.15)
            XCTAssertTrue(output.isEmpty)
            XCTAssertEqual(machine.scrollClassification?.horizontal, horizontal)
            XCTAssertTrue(touchPhases(output).isEmpty)
        }
    }

    func testAxisLockNeverFlipsAfterHorizontalClassification() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: CGPoint(x: 100, y: 100), timestamp: 0)
        for (index, point) in [CGPoint(x: 114, y: 104), CGPoint(x: 130, y: 108), CGPoint(x: 145, y: 111), CGPoint(x: 152, y: 200)].enumerated() {
            let output = machine.move(id: 1, point: point, timestamp: Double(index + 1) * 0.05)
            XCTAssertTrue(output.isEmpty)
            XCTAssertEqual(machine.scrollClassification?.horizontal, true)
            XCTAssertTrue(touchPhases(output).isEmpty)
        }
    }

    func testHorizontalWheelPreservesFractionalDistanceAndBoundsOnePacket() {
        var fractional = DirectTouchGestureStateMachine()
        fractional.begin(id: 1, point: .zero, timestamp: 0)
        fractional.move(id: 1, point: CGPoint(x: 72, y: 0), timestamp: 0.01)
        var total = 0
        for offset in 1...72 {
            let point = CGPoint(x: 72 + CGFloat(offset), y: 0)
            let output = fractional.move(id: 1, point: point, timestamp: 0.01 + Double(offset) * 0.01)
            XCTAssertTrue(touchPhases(output).isEmpty)
            total += output.reduce(0) { sum, event in
                if case .pointer(.horizontalWheel, _, let value) = event { return sum + Int(value) }; return sum
            }
        }
        XCTAssertEqual(total, -120)
        var bounded = DirectTouchGestureStateMachine()
        bounded.begin(id: 1, point: .zero, timestamp: 0)
        bounded.move(id: 1, point: CGPoint(x: 72, y: 0), timestamp: 0.01)
        XCTAssertEqual(bounded.move(id: 1, point: CGPoint(x: 378, y: 0), timestamp: 0.02),
            [.pointer(.horizontalWheel, CGPoint(x: 378, y: 0), -120)])
    }

    private func zoomValues(_ outputs: [DirectTouchGestureOutput]) -> [Int16] {
        outputs.compactMap { if case .pointer(.zoomWheel, _, let value) = $0 { return value }; return nil }
    }

    func testPinchOutEmitsExactlyOneFixedZoomStep() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        XCTAssertEqual(zoomValues(machine.move(id: 2, point: CGPoint(x: 115, y: 0), timestamp: 0.02)), [120])
    }

    func testPinchInEmitsExactlyOneFixedZoomStep() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        XCTAssertEqual(zoomValues(machine.move(id: 2, point: CGPoint(x: 85, y: 0), timestamp: 0.02)), [-120])
    }

    func testLargePinchStillEmitsOnlyOneZoomStep() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        XCTAssertEqual(zoomValues(machine.move(id: 2, point: CGPoint(x: 400, y: 0), timestamp: 0.02)), [120])
    }

    func testContinuedMovementAfterPinchLatchEmitsNothing() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        machine.move(id: 2, point: CGPoint(x: 115, y: 0), timestamp: 0.02)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 300, y: 0), timestamp: 0.03).isEmpty)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 40, y: 0), timestamp: 0.04).isEmpty)
    }

    func testPinchLatchResetsOnlyAfterGestureCompletion() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        machine.move(id: 2, point: CGPoint(x: 115, y: 0), timestamp: 0.02)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 115, y: 0), timestamp: 0.03).isEmpty)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 50, y: 0), timestamp: 0.04).isEmpty)
        XCTAssertTrue(machine.end(id: 1, point: CGPoint(x: 50, y: 0), timestamp: 0.05).isEmpty)
        machine.begin(id: 3, point: .zero, timestamp: 1)
        machine.begin(id: 4, point: CGPoint(x: 100, y: 0), timestamp: 1.01)
        XCTAssertEqual(zoomValues(machine.move(id: 4, point: CGPoint(x: 85, y: 0), timestamp: 1.02)), [-120])
    }

    func testTwoFingerTapBelowPinchThresholdStillEmitsContextAction() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 105, y: 0), timestamp: 0.02).isEmpty)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 105, y: 0), timestamp: 0.03).isEmpty)
        XCTAssertEqual(pointerActions(machine.end(id: 1, point: .zero, timestamp: 0.04)), [.rightClick])
    }

    func testTwoFingerRightClickUsesCentroidOnlyAfterBothLift() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: CGPoint(x: 40, y: 50), timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 100), timestamp: 0.05)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 100, y: 100), timestamp: 0.1).isEmpty)
        let output = machine.end(id: 1, point: CGPoint(x: 40, y: 50), timestamp: 0.2)
        XCTAssertEqual(pointerActions(output), [.rightClick])
        guard case .pointer(_, let point, _) = output.first else {
            return XCTFail("right click missing")
        }
        XCTAssertEqual(point, CGPoint(x: 70, y: 75))
    }

    func testDragDoesNotActivateBefore500ms() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(touchPhases(machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 0.499)).isEmpty)
    }

    func testDragActivatesAt500msBoundary() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(touchPhases(machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 0.5)), [.down, .update])
    }

    func testDragAfter500msEmitsSingleDownBeforeUpdates() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(touchPhases(machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 0.501)), [.down, .update])
        XCTAssertEqual(touchPhases(machine.move(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.52)), [.update])
        XCTAssertEqual(touchPhases(machine.end(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.53)), [.up])
    }

    func testTapBelow500msStillRemainsTap() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(touchPhases(machine.end(id: 1, point: .zero, timestamp: 0.2)), [.down, .up])
    }

    func testMovementBeforeHoldThresholdStillUsesScrollClassification() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        let outputs = machine.move(id: 1, point: CGPoint(x: 0, y: 80), timestamp: 0.499)
        XCTAssertEqual(pointerActions(outputs), [.verticalWheel])
        XCTAssertTrue(touchPhases(outputs).isEmpty)
        XCTAssertTrue(touchPhases(machine.move(id: 1, point: CGPoint(x: 0, y: 90), timestamp: 0.6)).isEmpty)
    }

    func testLongHoldDragOwnsOneContactAndReleasesOnlyPrimary() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(touchPhases(machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 1.1)), [.down, .update])
        machine.begin(id: 2, point: CGPoint(x: 50, y: 50), timestamp: 1.12)
        XCTAssertTrue(machine.move(id: 2, point: CGPoint(x: 90, y: 90), timestamp: 1.14).isEmpty)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 90, y: 90), timestamp: 1.15).isEmpty)
        XCTAssertEqual(touchPhases(machine.move(id: 1, point: CGPoint(x: 12, y: 0), timestamp: 1.16)), [.update])
        XCTAssertEqual(touchPhases(machine.end(id: 1, point: CGPoint(x: 12, y: 0), timestamp: 1.18)), [.up])
    }

    func testSecondFingerDoesNotReclassifyActiveScroll() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(
            pointerActions(machine.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.02)),
            [.verticalWheel])
        machine.begin(id: 2, point: CGPoint(x: 40, y: 40), timestamp: 0.03)
        XCTAssertTrue(machine.move(
            id: 2, point: CGPoint(x: 80, y: 80), timestamp: 0.04).isEmpty)
        XCTAssertEqual(
            pointerActions(machine.move(id: 1, point: CGPoint(x: 0, y: 144), timestamp: 0.05)),
            [.verticalWheel])

        var horizontal = DirectTouchGestureStateMachine()
        horizontal.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(
            pointerActions(horizontal.move(
                id: 1, point: CGPoint(x: 72, y: 0), timestamp: 0.02)),
            [.horizontalWheel])
        horizontal.begin(id: 2, point: CGPoint(x: 40, y: 40), timestamp: 0.03)
        XCTAssertTrue(horizontal.move(
            id: 2, point: CGPoint(x: 80, y: 80), timestamp: 0.04).isEmpty)
        XCTAssertEqual(
            pointerActions(horizontal.move(
                id: 1, point: CGPoint(x: 144, y: 0), timestamp: 0.05)),
            [.horizontalWheel])
    }

    func testThreeFingerTapOpensSettingsOnlyAndFailuresDoNothing() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 5, y: 0), timestamp: 0.03)
        machine.begin(id: 3, point: CGPoint(x: 10, y: 0), timestamp: 0.06)
        XCTAssertTrue(machine.end(id: 1, point: .zero, timestamp: 0.12).isEmpty)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 5, y: 0), timestamp: 0.14).isEmpty)
        XCTAssertEqual(
            machine.end(id: 3, point: CGPoint(x: 10, y: 0), timestamp: 0.16),
            [.openSettings])

        var moved = DirectTouchGestureStateMachine()
        moved.begin(id: 1, point: .zero, timestamp: 0)
        moved.begin(id: 2, point: .zero, timestamp: 0.02)
        moved.begin(id: 3, point: .zero, timestamp: 0.04)
        moved.move(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.05)
        XCTAssertTrue(moved.end(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.1).isEmpty)
    }

    func testTapAndRightClickUseMaximumExcursion() {
        var tap = DirectTouchGestureStateMachine()
        tap.begin(id: 1, point: .zero, timestamp: 0)
        tap.move(id: 1, point: CGPoint(x: 11, y: 11), timestamp: 0.05)
        tap.move(id: 1, point: .zero, timestamp: 0.1)
        XCTAssertTrue(tap.end(id: 1, point: .zero, timestamp: 0.15).isEmpty)

        var rightClick = DirectTouchGestureStateMachine()
        rightClick.begin(id: 1, point: .zero, timestamp: 0)
        rightClick.begin(id: 2, point: CGPoint(x: 40, y: 40), timestamp: 0.02)
        rightClick.move(id: 1, point: CGPoint(x: 13, y: 0), timestamp: 0.04)
        rightClick.move(id: 1, point: .zero, timestamp: 0.06)
        XCTAssertFalse(pointerActions(rightClick.end(
            id: 2, point: CGPoint(x: 40, y: 40), timestamp: 0.08)).contains(.rightClick))
    }

    func testThreeFingerFailureAndReplacementAreSuppressed() {
        var duration = DirectTouchGestureStateMachine()
        for id in UInt64(1)...3 {
            duration.begin(id: id, point: .zero, timestamp: Double(id) * 0.01)
        }
        duration.end(id: 1, point: .zero, timestamp: 0.1)
        duration.end(id: 2, point: .zero, timestamp: 0.2)
        XCTAssertTrue(duration.end(id: 3, point: .zero, timestamp: 0.32).isEmpty)

        var cancelled = DirectTouchGestureStateMachine()
        for id in UInt64(1)...3 {
            cancelled.begin(id: id, point: .zero, timestamp: Double(id) * 0.01)
        }
        cancelled.end(id: 1, point: .zero, timestamp: 0.1, cancelled: true)
        cancelled.end(id: 2, point: .zero, timestamp: 0.12)
        XCTAssertTrue(cancelled.end(id: 3, point: .zero, timestamp: 0.14).isEmpty)

        var replacement = DirectTouchGestureStateMachine()
        for id in UInt64(1)...3 {
            replacement.begin(id: id, point: .zero, timestamp: Double(id) * 0.01)
        }
        replacement.end(id: 1, point: .zero, timestamp: 0.1)
        replacement.begin(id: 4, point: .zero, timestamp: 0.11)
        replacement.end(id: 2, point: .zero, timestamp: 0.12)
        replacement.end(id: 3, point: .zero, timestamp: 0.13)
        XCTAssertTrue(replacement.end(id: 4, point: .zero, timestamp: 0.14).isEmpty)
    }

    func testContactBegunDuringPalmGuardRemainsIgnoredForLifetime() {
        var machine = DirectTouchGestureStateMachine()
        machine.pencilBegan(timestamp: 0)
        machine.pencilEnded(timestamp: 0.01)
        machine.begin(id: 1, point: .zero, timestamp: 0.1)
        machine.move(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.2)
        XCTAssertTrue(machine.end(id: 1, point: .zero, timestamp: 0.3).isEmpty)
        machine.begin(id: 2, point: .zero, timestamp: 0.31)
        XCTAssertEqual(touchPhases(machine.end(
            id: 2, point: .zero, timestamp: 0.4)), [.down, .up])
    }

    func testFourthFingerSuppressesUntilAllLift() {
        var machine = DirectTouchGestureStateMachine()
        for id in UInt64(1)...4 {
            XCTAssertTrue(machine.begin(id: id, point: .zero, timestamp: Double(id) * 0.01).isEmpty)
        }
        for id in UInt64(1)...4 {
            XCTAssertTrue(machine.end(id: id, point: .zero, timestamp: 0.1 + Double(id) * 0.01).isEmpty)
        }
        machine.begin(id: 5, point: .zero, timestamp: 1)
        XCTAssertEqual(touchPhases(machine.end(id: 5, point: .zero, timestamp: 1.1)), [.down, .up])
    }

    func testPencilPreemptsPendingAndActiveDragThenGuardsPalms() {
        var pending = DirectTouchGestureStateMachine()
        pending.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(pending.pencilBegan(timestamp: 0.02).isEmpty)
        XCTAssertTrue(pending.end(id: 1, point: .zero, timestamp: 0.03).isEmpty)

        var drag = DirectTouchGestureStateMachine()
        drag.begin(id: 1, point: .zero, timestamp: 0)
        drag.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 1.1)
        XCTAssertEqual(touchPhases(drag.pencilBegan(timestamp: 1.13)), [.cancel])
        XCTAssertTrue(drag.begin(id: 3, point: .zero, timestamp: 1.14).isEmpty)
        drag.pencilEnded(timestamp: 1.15)
        XCTAssertTrue(drag.end(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 1.35).isEmpty)
        XCTAssertTrue(drag.end(id: 3, point: .zero, timestamp: 1.4).isEmpty)
        drag.begin(id: 4, point: .zero, timestamp: 1.41)
        XCTAssertEqual(touchPhases(drag.end(id: 4, point: .zero, timestamp: 1.5)), [.down, .up])
    }

    func testCancellationNeverLeavesLogicalDragActive() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 1.1)
        XCTAssertEqual(
            touchPhases(machine.end(
                id: 1,
                point: CGPoint(x: 7, y: 0),
                timestamp: 1.13,
                cancelled: true)),
            [.cancel])
        XCTAssertTrue(machine.retire().isEmpty)
    }
}

final class PointerInputFailSafeReleaseTests: XCTestCase {
    func testLeftUpUsesLastValidCoordinateOutsideViewportThenClearsIt() {
        var state = PointerInputCoordinateState()
        let valid = CGPoint(x: 0.25, y: 0.75)
        XCTAssertEqual(state.resolve(action: .leftDown, mappedPoint: valid), valid)
        XCTAssertEqual(state.resolve(action: .leftUp, mappedPoint: nil), valid)
        XCTAssertNil(state.lastValidPoint)
        XCTAssertEqual(state.resolve(action: .leftUp, mappedPoint: nil), .zero)
    }

    func testUnmappedPositionBearingActionsRemainRejected() {
        var state = PointerInputCoordinateState()
        for action: PointerInputAction in [
            .move, .leftDown, .leftClick, .rightClick, .verticalWheel, .horizontalWheel
        ] {
            XCTAssertNil(state.resolve(action: action, mappedPoint: nil))
        }
    }

    func testDisplaySuppressionAllowsOnlyLeftUp() {
        XCTAssertTrue(PointerInputDeliveryPolicy.maySend(
            action: .leftUp, inputSuppressed: true))
        for action: PointerInputAction in [
            .move, .leftClick, .leftDown, .rightClick, .verticalWheel, .horizontalWheel
        ] {
            XCTAssertFalse(PointerInputDeliveryPolicy.maySend(
                action: action, inputSuppressed: true))
        }
    }
}

final class LifetimeIdentityMapTests: XCTestCase {
    func testIdentityIsStableDistinctAndRetiredAtEnd() {
        var identities = LifetimeIdentityMap<String>()
        let first = identities.begin("first")
        XCTAssertEqual(identities.begin("first"), first)
        let second = identities.begin("second")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(identities.existing("first"), first)
        XCTAssertEqual(identities.end("first"), first)
        XCTAssertNil(identities.existing("first"))
        XCTAssertNotEqual(identities.begin("first"), first)
    }

    func testMissingMidContactIdentityIsNotInvented() {
        let identities = LifetimeIdentityMap<Int>()
        XCTAssertNil(identities.existing(7))
    }
}

final class USBListenerLifetimeTests: XCTestCase {
    private var manager: NetworkManager!
    private var peers: [NWConnection] = []

    override func setUp() {
        super.setUp()
        manager = NetworkManager()
        manager.startListening(port: 0)
    }

    override func tearDown() {
        manager.stopForTesting()
        peers.forEach { $0.cancel() }
        peers.removeAll()
        manager = nil
        super.tearDown()
    }

    func testListenerSurvivesFailureAndImmediatelyAcceptsAnotherSession() throws {
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        let firstPeer = try connect()
        let old = manager.usbSessionSnapshot()
        XCTAssertTrue(old.connection === firstPeer)
        try deliver(.failed(.posix(.ECONNRESET)), to: firstPeer)

        let lost = manager.usbSessionSnapshot()
        XCTAssertTrue(lost.listener === listener)
        XCTAssertTrue(lost.listenerIntent)
        XCTAssertNil(lost.connection)
        XCTAssertNil(lost.authenticatedGeneration)
        XCTAssertNil(lost.committedGeneration)
        XCTAssertGreaterThan(lost.generation, old.generation)

        let secondPeer = try connect()
        let active = manager.usbSessionSnapshot()
        XCTAssertTrue(active.listener === listener)
        XCTAssertTrue(active.connection === secondPeer)
    }

    func testBlockedOldDecoderCannotBlockListenerAcceptance() throws {
        let firstPeer = try connect()
        let old = try XCTUnwrap(manager.usbSessionSnapshot().connection)
        XCTAssertTrue(old === firstPeer)
        let decoderBlocked = expectation(description: "old decoder blocked")
        let releaseDecoder = DispatchSemaphore(value: 0)
        let decoderQueue = manager.decoderForTesting.sessionQueueForTesting
        decoderQueue.async {
            decoderBlocked.fulfill()
            releaseDecoder.wait()
        }
        wait(for: [decoderBlocked], timeout: 5)
        defer {
            releaseDecoder.signal()
            decoderQueue.sync { }
        }

        let sessionRetired = expectation(description: "listener queue remains available")
        DispatchQueue.global().async {
            self.manager.simulateSessionAuthenticatedAndCommitted()
            try? self.deliver(.failed(.posix(.ECONNRESET)), to: old)
            sessionRetired.fulfill()
        }

        guard XCTWaiter.wait(for: [sessionRetired], timeout: 5) == .completed else {
            XCTFail("Session retirement blocked the listener behind VideoToolbox")
            return
        }

        let listener = manager.usbSessionSnapshot().listener
        let secondPeer = try connect()
        XCTAssertTrue(manager.usbSessionSnapshot().listener === listener)
        XCTAssertTrue(manager.usbSessionSnapshot().connection === secondPeer)
    }

    func testLandscapeDisconnectPortraitReconnectSendsCurrentDisplay() throws {
        try reconnect(from: .landscape, to: .portrait, loss: .failed(.posix(.ECONNRESET)))
    }

    func testPortraitDisconnectLandscapeReconnectSendsCurrentDisplay() throws {
        try reconnect(from: .portrait, to: .landscape, loss: .cancelled)
    }

    func testRepeatedFailedCandidatesKeepTheListener() throws {
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        for state in [NWConnection.State.failed(.posix(.ECONNRESET)), .cancelled] {
            let candidate = try connect()
            try deliver(state, to: candidate)
            let snap = manager.usbSessionSnapshot()
            XCTAssertTrue(snap.listener === listener)
            XCTAssertNil(snap.connection)
        }
        let successful = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        let snap = manager.usbSessionSnapshot()
        XCTAssertTrue(snap.listener === listener)
        XCTAssertTrue(snap.connection === successful)
        XCTAssertNotNil(snap.committedGeneration)
    }

    func testLateOldStateCallbacksCannotClearReplacement() throws {
        let firstPeer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        let oldCallback = try XCTUnwrap(firstPeer.stateUpdateHandler)
        try deliver(.failed(.posix(.ECONNRESET)), to: firstPeer)

        let secondPeer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        manager.updateInterfaceOrientation(.portrait)
        let current = manager.usbSessionSnapshot()
        XCTAssertTrue(current.connection === secondPeer)

        // Late callbacks from old connection arrive on network queue
        manager.networkQueueForTesting.sync {
            oldCallback(.failed(.posix(.ECONNRESET)))
            oldCallback(.cancelled)
        }

        let after = manager.usbSessionSnapshot()
        XCTAssertTrue(after.listener === current.listener)
        XCTAssertTrue(after.connection === current.connection)
        XCTAssertEqual(after.committedGeneration, current.committedGeneration)
        XCTAssertEqual(after.orientation, .portrait)
    }

    func testDeadSessionAllowsReplacementImmediately() throws {
        let firstPeer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        let oldGen = manager.usbSessionSnapshot().generation

        // Simulate transport loss
        try deliver(.failed(.posix(.ECONNRESET)), to: firstPeer)
        let lostSnap = manager.usbSessionSnapshot()
        XCTAssertTrue(lostSnap.listener === listener)
        XCTAssertNil(lostSnap.connection)

        // Replacement candidate arrives immediately
        let replacement = try connect()
        let repSnap = manager.usbSessionSnapshot()
        XCTAssertTrue(repSnap.listener === listener)
        XCTAssertTrue(repSnap.connection === replacement)
        XCTAssertGreaterThan(repSnap.generation, oldGen)
    }

    func testControlCenterAppInactivityDoesNotTearDownUsbSession() throws {
        let peer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted(
            mode: RealtimeTransportMode.usbSplitTLS)
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        let snapBefore = manager.usbSessionSnapshot()
        let decoderInvalidations = manager.decoderForTesting.invalidateCountForTesting
        let feedbacks = manager.usbForegroundRecoveryFeedbackCountForTesting

        manager.applicationWillResignActive()
        manager.applicationDidBecomeActive()
        let snapDuring = manager.usbSessionSnapshot()
        XCTAssertTrue(snapDuring.listener === listener)
        XCTAssertTrue(snapDuring.connection === peer)
        XCTAssertEqual(snapDuring.generation, snapBefore.generation)
        XCTAssertEqual(snapDuring.committedGeneration, snapBefore.committedGeneration)
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            decoderInvalidations)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks)
    }

    func testUsbBackgroundForegroundRearmsDecoderOnceForSameGeneration() throws {
        let peer = try connect()
        guard case .ready = peer.state else {
            return XCTFail("Foreground recovery requires a healthy accepted socket")
        }
        manager.simulateSessionAuthenticatedAndCommitted(
            mode: RealtimeTransportMode.usbSplitTLS)
        let before = manager.usbSessionSnapshot()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let sessions = manager.decoderForTesting.sessionBeganCountForTesting
        let feedbacks = manager.usbForegroundRecoveryFeedbackCountForTesting
        manager.decoderForTesting.resetLifecycleEventsForTesting()

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()

        let after = manager.usbSessionSnapshot()
        XCTAssertTrue(after.connection === peer)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.committedGeneration, before.committedGeneration)
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            invalidations + 1)
        XCTAssertEqual(
            manager.decoderForTesting.sessionBeganCountForTesting,
            sessions + 1)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks + 1)
        XCTAssertEqual(
            manager.decoderForTesting.lifecycleEventsForTesting,
            ["invalidate-begin", "invalidate-end", "begin-\(before.generation)"])

        manager.applicationDidBecomeActive()
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            invalidations + 1)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks + 1)
    }

    func testConnectionFailureCleanupIsNotForegroundRecovery() throws {
        let peer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted(mode: RealtimeTransportMode.usbSplitTLS)
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let recoveries = manager.usbForegroundRecoveryFeedbackCountForTesting
        try deliver(.failed(.posix(.ECONNRESET)), to: peer)
        manager.decoderForTesting.sessionQueueForTesting.sync { }
        XCTAssertNil(manager.usbSessionSnapshot().connection)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations + 1)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, recoveries)
    }

    func testStaleUsbBackgroundTokenCannotRearmReplacementGeneration() throws {
        let first = try connect()
        manager.simulateSessionAuthenticatedAndCommitted(
            mode: RealtimeTransportMode.usbSplitTLS)
        manager.applicationDidEnterBackground()
        try deliver(.failed(.posix(.ECONNRESET)), to: first)
        let replacement = try connect()
        manager.simulateSessionAuthenticatedAndCommitted(
            mode: RealtimeTransportMode.usbSplitTLS)
        let before = manager.usbSessionSnapshot()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let feedbacks = manager.usbForegroundRecoveryFeedbackCountForTesting

        manager.applicationDidBecomeActive()

        let after = manager.usbSessionSnapshot()
        XCTAssertTrue(after.connection === replacement)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            invalidations)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks)
    }

    func testUsbBackgroundStopRevokesDecoderRearm() throws {
        let peer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted(
            mode: RealtimeTransportMode.usbSplitTLS)
        manager.applicationDidEnterBackground()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let feedbacks = manager.usbForegroundRecoveryFeedbackCountForTesting

        manager.stopForTesting()
        manager.applicationDidBecomeActive()

        XCTAssertNil(manager.usbSessionSnapshot().connection)
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            invalidations + 1)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks)
        _ = peer
    }

    func testUsbListenerOnlyBackgroundDoesNotRearmDecoder() throws {
        let snapshot = manager.usbSessionSnapshot()
        let listener = try XCTUnwrap(snapshot.listener)
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let feedbacks = manager.usbForegroundRecoveryFeedbackCountForTesting

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()

        let current = manager.usbSessionSnapshot()
        XCTAssertTrue(current.listener === listener)
        XCTAssertNil(current.connection)
        XCTAssertEqual(
            manager.decoderForTesting.invalidateCountForTesting,
            invalidations)
        XCTAssertEqual(manager.usbForegroundRecoveryFeedbackCountForTesting, feedbacks)
    }

    func testHealthyCommittedSessionRejectsLateCandidate() throws {
        let firstPeer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        manager.updateInterfaceOrientation(.landscape)
        let listener = manager.usbSessionSnapshot().listener
        let committed = manager.usbSessionSnapshot()

        let latePeer = try connect()
        let snap = manager.usbSessionSnapshot()
        XCTAssertTrue(snap.connection === firstPeer)
        XCTAssertTrue(snap.listener === listener)
        XCTAssertEqual(snap.generation, committed.generation)
        XCTAssertEqual(snap.committedGeneration, committed.committedGeneration)
        XCTAssertNil(latePeer.stateUpdateHandler)

        try deliver(.failed(.posix(.ECONNRESET)), to: firstPeer)
        let replacement = try connect()
        XCTAssertTrue(manager.usbSessionSnapshot().connection === replacement)
        XCTAssertGreaterThan(manager.usbSessionSnapshot().generation, committed.generation)
    }

    func testExplicitStopRejectsLateAcceptUntilExplicitStart() throws {
        let peer = try connect()
        let snapshot = manager.usbSessionSnapshot()
        let listener = try XCTUnwrap(snapshot.listener)
        let lateAccept = try XCTUnwrap(listener.newConnectionHandler)

        manager.stopForTesting()
        let latePeer = NWConnection(host: "127.0.0.1", port: 42042, using: .tcp)
        manager.networkQueueForTesting.sync { lateAccept(latePeer) }

        let stopped = manager.usbSessionSnapshot()
        XCTAssertFalse(stopped.listenerIntent)
        XCTAssertNil(stopped.listener)
        XCTAssertNil(stopped.connection)
        XCTAssertNil(stopped.committedGeneration)

        manager.startListening(port: 0)
        let restarted = manager.usbSessionSnapshot()
        XCTAssertTrue(restarted.listenerIntent)
        XCTAssertNotNil(restarted.listener)
        let replacementPeer = try connect()
        XCTAssertTrue(manager.usbSessionSnapshot().connection === replacementPeer)
    }

    func testOrientationAndRepeatedStartDoNotRestartIdleListener() throws {
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        for orientation in [ClientDisplayOrientation.landscape, .portrait, .landscape, .portrait] {
            manager.updateInterfaceOrientation(orientation)
            let snapshot = manager.usbSessionSnapshot()
            XCTAssertTrue(snapshot.listener === listener)
            XCTAssertTrue(snapshot.listenerIntent)
            XCTAssertEqual(snapshot.orientation, orientation)
        }
        manager.startListening(port: 0)
        XCTAssertTrue(manager.usbSessionSnapshot().listener === listener)
    }

    func testReadyUsbSocketRemainsProvisionalUntilHostPing() throws {
        let peer = try connect()
        try deliver(.ready, to: peer)
        let snapshot = manager.usbSessionSnapshot()
        XCTAssertNil(snapshot.authenticatedGeneration)
        XCTAssertNil(snapshot.committedGeneration)
        XCTAssertNotEqual(manager.connectionState, .streaming)
    }

    private func reconnect(
        from initial: ClientDisplayOrientation,
        to desired: ClientDisplayOrientation,
        loss: NWConnection.State
    ) throws {
        let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
        manager.updateInterfaceOrientation(initial)
        let peer = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        try deliver(loss, to: peer)

        manager.updateInterfaceOrientation(desired)
        XCTAssertNil(manager.usbSessionSnapshot().pendingDisplay)
        XCTAssertEqual(manager.usbSessionSnapshot().orientation, desired)

        let replacement = try connect()
        manager.simulateSessionAuthenticatedAndCommitted()
        XCTAssertTrue(manager.usbSessionSnapshot().listener === listener)
        XCTAssertTrue(manager.usbSessionSnapshot().connection === replacement)
        XCTAssertEqual(manager.usbSessionSnapshot().orientation, desired)
    }

    private func connect() throws -> NWConnection {
        let snapshot = manager.usbSessionSnapshot()
        let listener = try XCTUnwrap(snapshot.listener)
        let acceptHandler = try XCTUnwrap(listener.newConnectionHandler)
        let listenerReady = expectation(description: "ephemeral USB listener ready")
        manager.networkQueueForTesting.sync {
            if case .ready = listener.state {
                listenerReady.fulfill()
            } else {
                let stateHandler = listener.stateUpdateHandler
                listener.stateUpdateHandler = { state in
                    stateHandler?(state)
                    if case .ready = state {
                        listener.stateUpdateHandler = stateHandler
                        listenerReady.fulfill()
                    }
                }
            }
        }
        wait(for: [listenerReady], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let acceptedReady = expectation(description: "USB candidate ready or rejected")
        var acceptedPeer: NWConnection?
        manager.networkQueueForTesting.sync {
            listener.newConnectionHandler = { connection in
                acceptHandler(connection)
                acceptedPeer = connection
                guard self.manager.usbSessionSnapshot().connection === connection else {
                    acceptedReady.fulfill()
                    return
                }
                let stateHandler = connection.stateUpdateHandler
                connection.stateUpdateHandler = { state in
                    stateHandler?(state)
                    if case .ready = state {
                        connection.stateUpdateHandler = stateHandler
                        acceptedReady.fulfill()
                    }
                }
            }
        }
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        peers.append(client)
        client.start(queue: manager.networkQueueForTesting)
        wait(for: [acceptedReady], timeout: 5)
        let accepted = try manager.networkQueueForTesting.sync {
            listener.newConnectionHandler = acceptHandler
            return try XCTUnwrap(acceptedPeer)
        }
        return accepted
    }

    private func deliver(_ state: NWConnection.State, to connection: NWConnection) throws {
        let callback = try XCTUnwrap(connection.stateUpdateHandler)
        if DispatchQueue.getSpecific(key: manager.networkQueueKeyForTesting) != nil {
            callback(state)
        } else {
            manager.networkQueueForTesting.sync {
                callback(state)
            }
        }
    }
}

final class WifiForegroundDecoderRecoveryTests: XCTestCase {
    private var manager: NetworkManager!

    override func setUp() {
        super.setUp()
        manager = NetworkManager()
    }

    override func tearDown() {
        manager.stopForTesting()
        manager = nil
        super.tearDown()
    }

    func testControlCenterRearmsPreservedWifiRtpDecoderOnce() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting
        manager.decoderForTesting.resetLifecycleEventsForTesting()

        manager.applicationWillResignActive()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        if case .cancelled = session.connection.state {
            XCTFail("Wi-Fi control connection was cancelled on foreground")
        }
        XCTAssertEqual(manager.decoderForTesting.currentSessionGeneration,
                       session.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins + 1)
        manager.decoderForTesting.sessionQueueForTesting.sync { }
        let events = manager.decoderForTesting.lifecycleEventsForTesting
        XCTAssertEqual(events.first, "invalidate-begin")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.filter { $0.hasPrefix("begin-") }, ["begin-\(session.generation)"])
        XCTAssertEqual(events.filter { $0 == "invalidate-end" }, ["invalidate-end"])
        XCTAssertEqual(manager.decoderForTesting.invalidateWaitModesForTesting.last, false)
    }

    func testDuplicateActiveDoesNotRearmWifiDecoderAgain() {
        _ = manager.simulateCommittedWifiSessionForTesting()
        manager.applicationWillResignActive()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting

        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins)
    }

    func testShortBackgroundRearmsSamePreservedWifiGeneration() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        if case .cancelled = session.connection.state {
            XCTFail("Wi-Fi control connection was cancelled inside background grace")
        }
        XCTAssertEqual(manager.decoderForTesting.currentSessionGeneration,
                       session.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins + 1)
    }

    func testRapidSecondPreservedResumeCoalescesUntilRecoveryCompletes() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.networkQueueForTesting.sync {
            manager.wifiMediaReceiverForTesting
                .simulateActivePacketSequenceForTesting(
                    100, generation: session.generation)
        }

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting
        let reanchors = manager.networkQueueForTesting.sync {
            manager.wifiMediaReceiverForTesting.lifecycleReanchorCountForTesting
        }

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins)
        manager.networkQueueForTesting.sync {
            XCTAssertTrue(manager.wifiMediaReceiverForTesting
                .isPreservedSessionRecoveryPending(generation: session.generation))
            XCTAssertEqual(manager.wifiMediaReceiverForTesting
                .lifecycleReanchorCountForTesting, reanchors)
        }
    }

    func testSuccessfulRecoveryAllowsLaterPreservedResume() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.networkQueueForTesting.sync {
            manager.wifiMediaReceiverForTesting
                .simulateActivePacketSequenceForTesting(
                    100, generation: session.generation)
        }
        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting

        manager.networkQueueForTesting.sync {
            let receiver = manager.wifiMediaReceiverForTesting
            receiver.simulatePendingRecoveryCandidateForTesting(sequence: 77)
            receiver.decoderDidComplete(
                sequence: 77, generation: session.generation, succeeded: true)
            XCTAssertFalse(receiver.isPreservedSessionRecoveryPending(
                generation: session.generation))
        }

        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins + 1)
    }

    func testPreservedForegroundReanchorsOnlyCurrentMediaGeneration() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.networkQueueForTesting.sync {
            manager.wifiMediaReceiverForTesting
                .simulateActivePacketSequenceForTesting(
                    100, generation: session.generation)
            manager.wifiMediaReceiverForTesting
                .simulateActivePacketSequenceForTesting(
                    102, generation: session.generation)
        }
        let before = manager.wifiLifecycleSnapshotForTesting()
        manager.applicationDidEnterBackground()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === session.connection)
        XCTAssertEqual(after.generation, session.generation)
        XCTAssertEqual(after.authenticatedGeneration, session.generation)
        XCTAssertEqual(after.committedGeneration, session.generation)
        XCTAssertEqual(after.initialReceiveStarts, before.initialReceiveStarts)
        XCTAssertEqual(after.writerBegins, before.writerBegins)
        XCTAssertEqual(after.clientHelloCount, before.clientHelloCount)
        manager.networkQueueForTesting.sync {
            let receiver = manager.wifiMediaReceiverForTesting
            XCTAssertEqual(receiver.lifecycleReanchorCountForTesting, 1)
            XCTAssertNil(receiver.feedbackWindowForTesting.highest)
            XCTAssertTrue(receiver.dependencyBreakActiveForTesting)
            receiver.reanchorForPreservedSessionRecovery(
                generation: session.generation - 1)
            XCTAssertEqual(receiver.lifecycleReanchorCountForTesting, 1)
        }
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync {
            XCTAssertEqual(manager.wifiMediaReceiverForTesting
                .lifecycleReanchorCountForTesting, 1)
        }
    }

    func testGenericDecoderRecoveryDoesNotReanchorRtpHistory() {
        let queue = DispatchQueue(label: "test.wifi.generic.recovery")
        let receiver = WifiMediaReceiver(
            networkQueue: queue,
            decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in },
            onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in })
        queue.sync {
            receiver.simulateActivePacketSequenceForTesting(
                100, generation: 7)
            receiver.requestImmediateRecoveryFeedback(generation: 7)
            XCTAssertEqual(receiver.lifecycleReanchorCountForTesting, 0)
            XCTAssertEqual(receiver.feedbackWindowForTesting.highest, 100)
            XCTAssertTrue(receiver.dependencyBreakActiveForTesting)
        }
    }

    func testReplacementWifiGenerationCannotRearmStaleSession() {
        let retired = manager.simulateCommittedWifiSessionForTesting()
        manager.applicationWillResignActive()
        let current = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting
        manager.decoderForTesting.resetLifecycleEventsForTesting()

        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        XCTAssertGreaterThan(current.generation, retired.generation)
        XCTAssertEqual(manager.decoderForTesting.currentSessionGeneration,
                       current.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting,
                       begins + 1)
        manager.decoderForTesting.sessionQueueForTesting.sync { }
        let events = manager.decoderForTesting.lifecycleEventsForTesting
        XCTAssertEqual(events.first, "invalidate-begin")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.filter { $0.hasPrefix("begin-") }, ["begin-\(current.generation)"])
        XCTAssertEqual(events.filter { $0 == "invalidate-end" }, ["invalidate-end"])
        XCTAssertEqual(manager.decoderForTesting.invalidateWaitModesForTesting.last, false)
    }

    func testLegacyWifiSessionDoesNotForceRtpDecoderRearm() {
        _ = manager.simulateCommittedWifiSessionForTesting(
            mode: RealtimeTransportMode.legacyTLS)
        let invalidations = manager.decoderForTesting.invalidateCountForTesting

        manager.applicationWillResignActive()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations)
    }
}

final class WifiTerminalDecoderRetirementTests: XCTestCase {
    private var manager: NetworkManager!

    override func setUp() {
        super.setUp()
        manager = NetworkManager()
    }

    override func tearDown() {
        manager.stopForTesting()
        manager = nil
        super.tearDown()
    }

    private func deliver(_ state: NWConnection.State, to connection: NWConnection) {
        let callback = connection.stateUpdateHandler
        XCTAssertNotNil(callback)
        manager.networkQueueForTesting.sync { callback?(state) }
    }

    func testFailedWifiConnectionRetiresDecoderBeforeReconnect() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting

        deliver(.failed(.posix(.ECONNRESET)), to: session.connection)

        let retired = manager.wifiSessionSnapshotForTesting()
        XCTAssertNil(retired.connection)
        XCTAssertNil(retired.committedGeneration)
        XCTAssertGreaterThan(retired.generation, session.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
    }

    func testCancelledWifiConnectionRetiresDecoderExactlyOnce() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting

        deliver(.cancelled, to: session.connection)
        deliver(.cancelled, to: session.connection)

        let retired = manager.wifiSessionSnapshotForTesting()
        XCTAssertNil(retired.connection)
        XCTAssertNil(retired.committedGeneration)
        XCTAssertGreaterThan(retired.generation, session.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations + 1)
    }

    func testReplacementWifiDecoderBeginsAfterTerminalInvalidation() {
        let retired = manager.simulateCommittedWifiSessionForTesting()
        manager.decoderForTesting.resetLifecycleEventsForTesting()

        deliver(.failed(.posix(.ECONNRESET)), to: retired.connection)
        let replacement = manager.simulateCommittedWifiSessionForTesting()

        XCTAssertGreaterThan(replacement.generation, retired.generation)
        XCTAssertEqual(manager.decoderForTesting.currentSessionGeneration,
                       replacement.generation)
        XCTAssertEqual(manager.decoderForTesting.lifecycleEventsForTesting,
                       ["invalidate-begin", "invalidate-end",
                        "begin-\(replacement.generation)"])
    }

    func testExplicitStopIgnoresLateCancelledCallback() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.stopForTesting()
        let stopped = manager.wifiSessionSnapshotForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting

        deliver(.cancelled, to: session.connection)

        let afterCallback = manager.wifiSessionSnapshotForTesting()
        XCTAssertEqual(afterCallback.generation, stopped.generation)
        XCTAssertNil(afterCallback.connection)
        XCTAssertNil(afterCallback.committedGeneration)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting,
                       invalidations)
    }
}

final class WifiShortBackgroundSameSessionTests: XCTestCase {
    private var manager: NetworkManager!

    override func setUp() {
        super.setUp()
        manager = NetworkManager()
    }

    override func tearDown() {
        manager.stopForTesting()
        manager = nil
        super.tearDown()
    }

    private func deliver(_ state: NWConnection.State, to connection: NWConnection) {
        let callback = connection.stateUpdateHandler
        XCTAssertNotNil(callback)
        manager.networkQueueForTesting.sync { callback?(state) }
    }

    private func backgroundWaiting() -> (connection: NWConnection, generation: UInt64) {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.applicationDidEnterBackground()
        manager.networkQueueForTesting.sync { }
        deliver(.waiting(.posix(.ENETDOWN)), to: session.connection)
        return session
    }

    private func inactiveSession() -> (connection: NWConnection, generation: UInt64) {
        let session = manager.simulateCommittedWifiSessionForTesting()
        manager.applicationWillResignActive()
        manager.networkQueueForTesting.sync { }
        return session
    }

    func testInactiveWaitingPreservesCommittedSessionBeforeBackground() {
        let session = inactiveSession()
        deliver(.waiting(.posix(.ENETDOWN)), to: session.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertEqual(snap.realtimeMode, RealtimeTransportMode.wifiRTP)
        XCTAssertEqual(snap.waitingGeneration, session.generation)
        XCTAssertEqual(snap.inactiveTransitionGeneration, session.generation)
        XCTAssertFalse(snap.graceActive)
    }

    func testInactiveSendErrorPreservesCommittedSessionBeforeBackground() {
        let session = inactiveSession()
        manager.simulateWifiControlSendErrorForTesting(
            generation: session.generation, connection: session.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertEqual(snap.inactiveTransitionGeneration, session.generation)
        XCTAssertFalse(snap.graceActive)
    }

    func testInactiveReceiveErrorPreservesCommittedSessionBeforeBackground() {
        let session = inactiveSession()
        manager.simulateWifiControlReceiveErrorForTesting(
            generation: session.generation, connection: session.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertNil(snap.receiveActiveGeneration)
        XCTAssertEqual(snap.inactiveTransitionGeneration, session.generation)
        XCTAssertFalse(snap.graceActive)
    }

    func testInactiveWaitingHandsOwnershipToExistingBackgroundGrace() {
        let session = inactiveSession()
        deliver(.waiting(.posix(.ENETDOWN)), to: session.connection)
        manager.applicationDidEnterBackground()
        manager.networkQueueForTesting.sync { }
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertEqual(snap.waitingGeneration, session.generation)
        XCTAssertNil(snap.inactiveTransitionGeneration)
        XCTAssertTrue(snap.graceActive)
    }

    func testInactiveReceiveErrorHandsOwnershipToExistingBackgroundGrace() {
        let session = inactiveSession()
        manager.simulateWifiControlReceiveErrorForTesting(
            generation: session.generation, connection: session.connection)
        manager.applicationDidEnterBackground()
        manager.networkQueueForTesting.sync { }
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertNil(snap.inactiveTransitionGeneration)
        XCTAssertTrue(snap.graceActive)
        XCTAssertNil(snap.receiveActiveGeneration)
    }

    func testInactiveWaitingThenActiveWithoutBackgroundUsesTerminalFallback() {
        let session = inactiveSession()
        deliver(.waiting(.posix(.ENETDOWN)), to: session.connection)
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertNil(snap.inactiveTransitionGeneration)
        XCTAssertFalse(snap.graceActive)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testInactiveReadyThenActiveResumesSameGeneration() {
        let session = inactiveSession()
        let before = manager.wifiLifecycleSnapshotForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === session.connection)
        XCTAssertEqual(after.generation, session.generation)
        XCTAssertEqual(after.committedGeneration, session.generation)
        XCTAssertNil(after.inactiveTransitionGeneration)
        XCTAssertEqual(after.writerBegins, before.writerBegins)
        XCTAssertEqual(after.clientHelloCount, before.clientHelloCount)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations + 1)
    }

    func testInactiveMarkerCannotPreserveStaleGeneration() {
        let old = inactiveSession()
        let replacement = manager.simulateCommittedWifiSessionForTesting()
        deliver(.waiting(.posix(.ENETDOWN)), to: old.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === replacement.connection)
        XCTAssertEqual(snap.committedGeneration, replacement.generation)
        XCTAssertNil(snap.inactiveTransitionGeneration)
    }

    func testUsbStartClearsInactiveWifiTransitionOwnership() {
        _ = inactiveSession()
        manager.startListening(port: 0)
        manager.networkQueueForTesting.sync { }
        manager.applicationWillResignActive()
        manager.networkQueueForTesting.sync { }
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.inactiveTransitionGeneration)
        XCTAssertFalse(snap.graceActive)
        XCTAssertTrue(manager.usbSessionSnapshot().listenerIntent)
    }

    func testBackgroundWaitingPreservesCommittedSession() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        manager.applicationDidEnterBackground()
        manager.networkQueueForTesting.sync { }

        deliver(.waiting(.posix(.ENETDOWN)), to: session.connection)

        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.generation, session.generation)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertEqual(snap.realtimeMode, RealtimeTransportMode.wifiRTP)
        XCTAssertEqual(snap.waitingGeneration, session.generation)
        XCTAssertTrue(snap.graceActive)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations)
    }

    func testForegroundWhileWaitingKeepsOriginalGraceAndDefersResume() {
        let session = backgroundWaiting()
        let before = manager.wifiLifecycleSnapshotForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting

        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === session.connection)
        XCTAssertEqual(after.generation, session.generation)
        XCTAssertEqual(after.waitingGeneration, session.generation)
        XCTAssertTrue(after.graceActive)
        XCTAssertEqual(after.pingAttempts, before.pingAttempts)
        XCTAssertEqual(after.clientHelloCount, before.clientHelloCount)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations)
    }

    func testPreservedWifiResumeDoesNotBlockNetworkQueueAndKeepsCleanupFIFO() async {
        let session = backgroundWaiting()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let decoder = manager.decoderForTesting
        let entered = expectation(description: "decoder barrier entered")
        let released = DispatchSemaphore(value: 0)
        decoder.sessionQueueForTesting.async {
            entered.fulfill()
            released.wait()
        }
        await fulfillment(of: [entered], timeout: 1)
        let progressed = expectation(description: "network resume progresses while decoder is blocked")
        let callback = session.connection.stateUpdateHandler
        manager.networkQueueForTesting.async {
            callback?(.ready)
            progressed.fulfill()
        }
        await fulfillment(of: [progressed], timeout: 1)
        released.signal()
        manager.networkQueueForTesting.sync { }
        XCTAssertEqual(decoder.invalidateWaitModesForTesting.last, false)
        let cleanup = expectation(description: "old decoder cleanup precedes subsequent decoder work")
        decoder.sessionQueueForTesting.async {
            XCTAssertEqual(decoder.lifecycleEventsForTesting.last, "invalidate-end")
            cleanup.fulfill()
        }
        await fulfillment(of: [cleanup], timeout: 1)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.authenticatedGeneration, session.generation)
        XCTAssertEqual(snap.committedGeneration, session.generation)
    }

    func testRetiredWifiReadyCannotQueueDecoderCleanupForReplacement() {
        let old = backgroundWaiting()
        let callback = old.connection.stateUpdateHandler
        let current = manager.simulateCommittedWifiSessionForTesting()
        manager.networkQueueForTesting.sync { }
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        manager.networkQueueForTesting.sync { callback?(.ready) }
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === current.connection)
        XCTAssertEqual(snap.committedGeneration, current.generation)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations)
    }

    func testSameReadyResumesWithoutReplayingInitialHandshake() {
        let session = backgroundWaiting()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        let before = manager.wifiLifecycleSnapshotForTesting()
        let invalidations = manager.decoderForTesting.invalidateCountForTesting
        let begins = manager.decoderForTesting.sessionBeganCountForTesting

        deliver(.ready, to: session.connection)

        let after = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(after.connection === session.connection)
        XCTAssertEqual(after.generation, session.generation)
        XCTAssertEqual(after.authenticatedGeneration, session.generation)
        XCTAssertEqual(after.committedGeneration, session.generation)
        XCTAssertEqual(after.realtimeMode, RealtimeTransportMode.wifiRTP)
        XCTAssertNil(after.waitingGeneration)
        XCTAssertFalse(after.graceActive)
        XCTAssertEqual(after.initialReceiveStarts, before.initialReceiveStarts)
        XCTAssertEqual(after.writerBegins, before.writerBegins)
        XCTAssertEqual(after.clientHelloCount, before.clientHelloCount)
        XCTAssertEqual(after.pingAttempts, before.pingAttempts + 1)
        XCTAssertEqual(manager.decoderForTesting.invalidateCountForTesting, invalidations + 1)
        XCTAssertEqual(manager.decoderForTesting.sessionBeganCountForTesting, begins + 1)
    }

    func testTransientReceiveErrorResumesWithoutResettingCommit() {
        let session = backgroundWaiting()
        manager.simulateWifiControlReceiveErrorForTesting(
            generation: session.generation, connection: session.connection)
        let stopped = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(stopped.receiveActiveGeneration)
        XCTAssertEqual(stopped.authenticatedGeneration, session.generation)
        XCTAssertEqual(stopped.committedGeneration, session.generation)

        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }
        deliver(.ready, to: session.connection)

        let resumed = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertEqual(resumed.receiveActiveGeneration, session.generation)
        XCTAssertEqual(resumed.authenticatedGeneration, session.generation)
        XCTAssertEqual(resumed.committedGeneration, session.generation)
        XCTAssertEqual(resumed.realtimeMode, RealtimeTransportMode.wifiRTP)
        XCTAssertEqual(resumed.initialReceiveStarts, stopped.initialReceiveStarts)
    }

    func testTransientSendErrorDuringGracePreservesSession() {
        let session = backgroundWaiting()
        manager.simulateWifiControlSendErrorForTesting(
            generation: session.generation, connection: session.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === session.connection)
        XCTAssertEqual(snap.committedGeneration, session.generation)
        XCTAssertTrue(snap.graceActive)
    }

    func testTerminalSendErrorDuringInactiveRetiresSession() {
        let session = inactiveSession()
        manager.simulateWifiControlSendErrorForTesting(
            .posix(.ECONNRESET), generation: session.generation,
            connection: session.connection)

        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertNil(snap.committedGeneration)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testTerminalReceiveErrorDuringGraceRetiresSession() {
        let session = backgroundWaiting()
        manager.simulateWifiControlReceiveErrorForTesting(
            .posix(.EPIPE), generation: session.generation,
            connection: session.connection)

        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertNil(snap.committedGeneration)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testTerminalWaitingErrorDuringInactiveRetiresSession() {
        let session = inactiveSession()
        deliver(.waiting(.posix(.ECONNRESET)), to: session.connection)

        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertNil(snap.committedGeneration)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testWaitingOwnerIncludesExactConnectionIdentity() {
        let session = manager.simulateCommittedWifiSessionForTesting()
        let staleConnection = NWConnection(
            host: "127.0.0.1", port: 27015, using: .tcp)
        manager.setWifiWaitingOwnerForTesting(
            generation: session.generation, connection: staleConnection)

        XCTAssertTrue(manager.isWifiConnectionReadyForTesting(
            connection: session.connection, generation: session.generation))
    }

    func testActualReadyStateWinsStaleWaitingBookkeeping() {
        XCTAssertTrue(WifiConnectionReadinessPolicy.isReady(
            actualReady: true, waitingOwned: true))
        XCTAssertFalse(WifiConnectionReadinessPolicy.isReady(
            actualReady: false, waitingOwned: true,
            simulatedReady: true))
    }

    func testOriginalGraceExpiresEvenAfterForegroundWhileWaiting() {
        let session = backgroundWaiting()
        manager.applicationDidBecomeActive()
        manager.networkQueueForTesting.sync { }

        manager.expireWifiBackgroundGraceForTesting()

        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertNil(snap.committedGeneration)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testBackgroundGraceStillRetiresLongBackgroundSession() {
        let session = backgroundWaiting()
        manager.expireWifiBackgroundGraceForTesting()
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertNil(snap.connection)
        XCTAssertGreaterThan(snap.generation, session.generation)
    }

    func testTerminalFailureAndCancellationStillRetire() {
        let terminalStates: [NWConnection.State] = [
            .failed(.posix(.ECONNRESET)), .cancelled
        ]
        for state in terminalStates {
            let session = backgroundWaiting()
            deliver(state, to: session.connection)
            let snap = manager.wifiLifecycleSnapshotForTesting()
            XCTAssertNil(snap.connection)
            XCTAssertGreaterThan(snap.generation, session.generation)
        }
    }

    func testStaleWaitingCallbackCannotMutateReplacement() {
        let old = backgroundWaiting()
        let replacement = manager.simulateCommittedWifiSessionForTesting()
        deliver(.waiting(.posix(.ENETDOWN)), to: old.connection)
        let snap = manager.wifiLifecycleSnapshotForTesting()
        XCTAssertTrue(snap.connection === replacement.connection)
        XCTAssertEqual(snap.generation, replacement.generation)
        XCTAssertNotEqual(snap.waitingGeneration, old.generation)
    }

    func testUsbIsExcludedFromWifiGracePolicy() {
        XCTAssertFalse(WifiLifecyclePolicy.shouldTearDownAfterGrace(
            isForegroundActive: false, isUSB: true,
            scheduledGeneration: 7, currentGeneration: 7,
            hasSameConnection: true, isWaiting: true))
    }
}

final class ControlChannelWriterTests: XCTestCase {
    func testNetworkManagerReportsMissingControlConnectionAsNotConnected() {
        let manager = NetworkManager()
        let completed = expectation(description: "control completion")
        manager.enqueueControlForTesting { error in
            guard case .posix(.ENOTCONN)? = error else {
                XCTFail("Unsent control packet must report ENOTCONN, got \(String(describing: error))")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testRetiredSocketDoesNotBlockReplacementOrDeliverLateCompletion() {
        let queue = DispatchQueue(label: "control.writer.retired-socket")
        let sender = ManualSender()
        let writer = ControlChannelWriter(queue: queue, sender: sender.send)
        var staleCompletions = 0
        var currentCompletions = 0
        queue.sync {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueue(Data([1])) { _ in staleCompletions += 1 })
            writer.abandonConnection()
            writer.begin(generation: 2)
            XCTAssertTrue(writer.enqueue(Data([2])) { _ in currentCompletions += 1 })
            XCTAssertTrue(writer.enqueue(Data([3])) { _ in currentCompletions += 1 })
            XCTAssertEqual(sender.sent, [Data([1]), Data([2])],
                "A retired socket must not delay the new connection's first send")
        }
        sender.completeNext(.posix(.ECONNRESET))
        queue.sync {
            XCTAssertEqual(staleCompletions, 0)
            XCTAssertEqual(currentCompletions, 0)
            XCTAssertEqual(sender.sent, [Data([1]), Data([2])],
                "A stale completion must not drain the current socket")
        }
        sender.completeNext()
        queue.sync { XCTAssertEqual(sender.sent, [Data([1]), Data([2]), Data([3])]) }
        sender.completeNext()
        queue.sync { XCTAssertEqual(currentCompletions, 2) }
    }

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

    lazy var send: ControlChannelWriter.Sender = { [weak self] _, _, completion in
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

    lazy var send: ControlChannelWriter.Sender = { [weak self] data, _, completion in
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
            version: 2,
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
            Data([2, 7, 1, 3, 0xB0, 0x04, 50, 0, 0, 0xC0, 0, 0]))
        XCTAssertEqual(ClientCapabilities.decode(encoded), capabilities)
    }

    func testClientCapabilitiesVersionOneRemainsDecodable() {
        let legacy = Data([1, 1, 1, 1, 0xB0, 0x04, 50, 0, 0, 0, 0, 0])

        XCTAssertEqual(ClientCapabilities.decode(legacy)?.version, 1)
        XCTAssertEqual(legacy.count, ClientCapabilities.encodedSize)
    }

    func testClientCapabilitiesRejectUnknownFutureVersion() {
        let future = Data([3, 1, 1, 1, 0xB0, 0x04, 50, 0, 0, 0, 0, 0])

        XCTAssertNil(ClientCapabilities.decode(future))
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
        XCTAssertEqual(WireMessageType.presentationActivity.rawValue, 35)
        XCTAssertEqual(WireMessageType.pipelineMode.rawValue, 36)
        XCTAssertEqual(WireMessageType.pointerInput.rawValue, 37)
        XCTAssertEqual(PipelineMode.office.rawValue, 0)
        XCTAssertEqual(PipelineMode.game.rawValue, 1)
        XCTAssertEqual(WireProtocol.realtimeNegotiationSupportedFlag, 0x8000)
    }

    func testPipelineModePayloadIsOneByteAndRejectsUnknownValues() {
        XCTAssertEqual(PipelineMode.office.encode(), Data([0]))
        XCTAssertEqual(PipelineMode.game.encode(), Data([1]))
        XCTAssertEqual(PipelineMode.decode(Data([0])), .office)
        XCTAssertEqual(PipelineMode.decode(Data([1])), .game)
        XCTAssertNil(PipelineMode.decode(Data()))
        XCTAssertNil(PipelineMode.decode(Data([0, 0])))
        XCTAssertNil(PipelineMode.decode(Data([2])))
    }

    func testPointerInputPayloadRoundTripsAllActionsAndRejectsInvalidValues() throws {
        XCTAssertEqual(PointerInputAction.verticalWheel.rawValue, 5)
        XCTAssertEqual(PointerInputAction.horizontalWheel.rawValue, 6)
        for action in PointerInputAction.allCases {
            let value: Int16
            switch action {
            case .verticalWheel: value = 20
            case .horizontalWheel: value = -60
            default: value = 0
            }
            let command = PointerInputCommand(
                action: action,
                x: 1_234,
                y: 54_321,
                value: value)
            let payload = command.encode()
            XCTAssertEqual(payload.count, 8)
            XCTAssertEqual(PointerInputCommand.decode(payload), command)
        }

        var unknownVersion = PointerInputCommand(
            action: .move,
            x: 1,
            y: 2).encode()
        unknownVersion[0] = 2
        XCTAssertNil(PointerInputCommand.decode(unknownVersion))

        var unknownAction = PointerInputCommand(
            action: .move,
            x: 1,
            y: 2).encode()
        unknownAction[1] = 0xFF
        XCTAssertNil(PointerInputCommand.decode(unknownAction))
        XCTAssertNil(PointerInputCommand.decode(Data(repeating: 0, count: 7)))
    }

    func testSemanticZoomKeepsPointerV1EightByteLayoutAndRejectsFutureAction() throws {
        let payload = Data([1, 7, 0x34, 0x12, 0xCD, 0xAB, 0x88, 0xFF])
        let decoded = try XCTUnwrap(PointerInputCommand.decode(payload))
        XCTAssertEqual(decoded.action.rawValue, 7)
        XCTAssertEqual(decoded.x, 0x1234)
        XCTAssertEqual(decoded.y, 0xABCD)
        XCTAssertEqual(decoded.value, -120)
        XCTAssertEqual(decoded.encode(), payload)
        XCTAssertEqual(decoded.encode().count, 8)
        XCTAssertNil(PointerInputCommand.decode(Data([1, 8, 0, 0, 0, 0, 0, 0])))
    }

    func testMalformedPointerInputLengthIsDrainedAndSessionContinues() {
        let parser = WireStreamParser(generation: 4)
        let malformed = makeMessage(
            type: .pointerInput,
            flags: 0,
            payload: Data(repeating: 0, count: 7),
            sequence: 8)
        let following = makeMessage(
            type: .video,
            flags: 1,
            payload: Data([0, 0, 0, 1, 0x26]),
            sequence: 9)
        var discarded: [UInt32] = []
        var received: [UInt32] = []

        parser.consume(malformed + following, generation: 4) { event in
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
    }

    func testMalformedPipelineModeLengthIsDrainedAndSessionContinues() {
        let parser = WireStreamParser(generation: 4)
        let malformed = makeMessage(
            type: .pipelineMode,
            flags: 0,
            payload: Data([0, 0]),
            sequence: 8)
        let following = makeMessage(
            type: .video,
            flags: 1,
            payload: Data([0, 0, 0, 1, 0x26]),
            sequence: 9)
        var discarded: [UInt32] = []
        var received: [UInt32] = []

        parser.consume(malformed + following, generation: 4) { event in
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
    }

    func testUSBIdentityResourceDecodesWhitespaceWrappedPKCS12() {
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

final class KeyboardWireV1Tests: XCTestCase {
    func testFixedABIAndRoundTrips() {
        XCTAssertEqual(WireMessageType.keyboardInput.rawValue, 38)
        XCTAssertEqual(WireMessageType.pointerInput.rawValue, 37)
        XCTAssertEqual(PointerInputCommand.encodedSize, 8)
        for command in [KeyboardInputCommand(action: .keyDown, virtualKey: 0x41),
                        KeyboardInputCommand(action: .keyUp, virtualKey: 0xA2),
                        KeyboardInputCommand(action: .keyDown, virtualKey: 0x1234)] {
            XCTAssertEqual(Array(command.encode()), [1, command.action.rawValue, UInt8(truncatingIfNeeded: command.virtualKey), UInt8(command.virtualKey >> 8)])
            XCTAssertEqual(KeyboardInputCommand.decode(command.encode()), command)
        }
    }

    func testMalformedPayloadsReject() {
        for bytes in [[2, 0, 65, 0], [1, 2, 65, 0], [1, 0, 0, 0], [1, 0, 65], [1, 0, 65, 0, 0]] as [[UInt8]] {
            XCTAssertNil(KeyboardInputCommand.decode(Data(bytes)))
        }
    }
}

final class RemoteKeyboardV1Tests: XCTestCase {
    @MainActor func testOverlappingPhysicalCommandKeysOwnCtrlUntilLastRelease() {
        let view = PencilUIKitView(frame: .zero)
        var commands: [KeyboardInputCommand] = []
        view.onKeyboardInput = { commands.append($0) }
        view.keyboardCaptureEnabled = true
        view.handleHardwareKey(.keyboardLeftGUI, action: .keyDown)
        view.handleHardwareKey(.keyboardRightGUI, action: .keyDown)
        view.handleHardwareKey(.keyboardLeftGUI, action: .keyDown)
        view.handleHardwareKey(.keyboardLeftGUI, action: .keyUp)
        view.handleHardwareKey(.keyboardLeftGUI, action: .keyUp)
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyDown, .keyDown])
        view.handleHardwareKey(.keyboardRightGUI, action: .keyUp)
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyDown, .keyDown, .keyUp])
        XCTAssertEqual(commands.map(\.virtualKey), [0xA2, 0xA2, 0xA2, 0xA2])
        view.keyboardCaptureEnabled = false
        XCTAssertEqual(commands.count, 4)
    }

    @MainActor func testCaptureDisableReleasesOneUpPerSharedVirtualKey() {
        let view = PencilUIKitView(frame: .zero)
        var commands: [KeyboardInputCommand] = []
        view.onKeyboardInput = { commands.append($0) }
        view.keyboardCaptureEnabled = true
        for usage: UIKeyboardHIDUsage in [.keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftControl, .keyboardRightControl] {
            view.handleHardwareKey(usage, action: .keyDown)
            view.handleHardwareKey(usage, action: .keyDown)
        }
        view.keyboardCaptureEnabled = false
        XCTAssertEqual(commands.filter { $0.action == .keyUp }.map(\.virtualKey), [0xA2, 0xA3])
    }

    func testPhysicalHIDMapping() {
        let pairs: [(Int, UInt16)] = [
            (0x04, 0x41), (0x1D, 0x5A), (0x1E, 0x31), (0x26, 0x39), (0x27, 0x30),
            (0x28, 0x0D), (0x29, 0x1B), (0x2A, 0x08), (0x2B, 0x09), (0x2C, 0x20),
            (0x2D, 0xBD), (0x2E, 0xBB), (0x2F, 0xDB), (0x30, 0xDD), (0x31, 0xDC),
            (0x33, 0xBA), (0x34, 0xDE), (0x35, 0xC0), (0x36, 0xBC), (0x37, 0xBE), (0x38, 0xBF),
            (0x39, 0x14), (0x49, 0x2D), (0x4A, 0x24), (0x4B, 0x21), (0x4C, 0x2E),
            (0x4D, 0x23), (0x4E, 0x22), (0x4F, 0x27), (0x50, 0x25), (0x51, 0x28), (0x52, 0x26),
            (0xE0, 0xA3), (0xE4, 0xA3), (0xE3, 0xA2), (0xE7, 0xA2),
            (0xE1, 0xA0), (0xE5, 0xA1), (0xE2, 0xA4), (0xE6, 0xA5)
        ]
        for (hid, vk) in pairs {
            XCTAssertEqual(RemoteKeyboardKeyMapper.virtualKey(for: UIKeyboardHIDUsage(rawValue: hid)!), vk)
        }
        for hid in 0x04...0x1D {
            XCTAssertEqual(RemoteKeyboardKeyMapper.virtualKey(for: UIKeyboardHIDUsage(rawValue: hid)!), UInt16(0x41 + hid - 0x04))
        }
        for hid in 0x3A...0x45 {
            XCTAssertEqual(RemoteKeyboardKeyMapper.virtualKey(for: UIKeyboardHIDUsage(rawValue: hid)!), UInt16(0x70 + hid - 0x3A))
        }
        XCTAssertNil(RemoteKeyboardKeyMapper.virtualKey(for: UIKeyboardHIDUsage(rawValue: 0x32)!))
        XCTAssertNil(RemoteKeyboardKeyMapper.virtualKey(for: UIKeyboardHIDUsage(rawValue: 0x59)!))
    }

    func testDeliveryAllowsOnlyKeyUpDuringSuppression() {
        XCTAssertTrue(KeyboardInputDeliveryPolicy.maySend(action: .keyDown, inputSuppressed: false))
        XCTAssertTrue(KeyboardInputDeliveryPolicy.maySend(action: .keyUp, inputSuppressed: false))
        XCTAssertFalse(KeyboardInputDeliveryPolicy.maySend(action: .keyDown, inputSuppressed: true))
        XCTAssertTrue(KeyboardInputDeliveryPolicy.maySend(action: .keyUp, inputSuppressed: true))
    }

    @MainActor func testDisableReleasesBeforeResigning() {
        let view = KeyboardResponderOrderView(frame: .zero)
        var commands: [KeyboardInputCommand] = []
        view.onKeyboardInput = {
            XCTAssertTrue(view.keyboardCaptureEnabled || $0.action == .keyUp)
            commands.append($0)
        }
        view.keyboardCaptureEnabled = true
        XCTAssertTrue(view.handleHardwareKey(.keyboardLeftGUI, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardA, action: .keyDown))
        var releaseOrdering: [String] = []
        view.onKeyboardInput = { command in
            commands.append(command)
            releaseOrdering.append("up")
        }
        view.onResign = { releaseOrdering.append("resign") }
        view.keyboardCaptureEnabled = false
        XCTAssertEqual(releaseOrdering, ["up", "up", "resign"])
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyDown, .keyDown, .keyUp, .keyUp])
        XCTAssertEqual(commands.suffix(2).map(\.virtualKey), [0x41, 0xA2])
        XCTAssertFalse(view.handleHardwareKey(.keyboardA, action: .keyDown))
        view.keyboardCaptureEnabled = false
        XCTAssertEqual(commands.count, 5)
    }

    @MainActor func testKeyUpAndCancellationStateIsIdempotent() {
        let view = PencilUIKitView(frame: .zero)
        var commands: [KeyboardInputCommand] = []
        view.onKeyboardInput = { commands.append($0) }
        view.keyboardCaptureEnabled = true
        XCTAssertFalse(view.handleHardwareKey(UIKeyboardHIDUsage(rawValue: 0x59)!, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardLeftGUI, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardLeftControl, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardLeftGUI, action: .keyUp))
        XCTAssertTrue(view.handleHardwareKey(.keyboardLeftGUI, action: .keyUp))
        view.keyboardCaptureEnabled = false
        XCTAssertEqual(commands.map(\.virtualKey), [0xA2, 0xA3, 0xA2, 0xA3])
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyDown, .keyUp, .keyUp])
    }
}

@MainActor private final class KeyboardResponderOrderView: PencilUIKitView {
    var onResign: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        onResign?()
        return super.resignFirstResponder()
    }
}

final class KeyboardV2Tests: XCTestCase {
    func testTextCommitWireAndStrictUnicode() {
        XCTAssertEqual(WireMessageType.textCommit.rawValue, 40)
        for text in ["hello", "Tiếng Việt", "a\u{0301}", "😀", "👨‍👩‍👧‍👦", " "] {
            let command = TextCommitCommand(text: text)
            XCTAssertEqual(TextCommitCommand.decode(command.encode()!)?.text.utf8.map { $0 }, Array(text.utf8))
        }
        for bytes in [[UInt8](), [1,0,0], [2,1,0,65], [1,2,0,65], [1,1,0,65,66], [1,2,0,0xC0,0xAF], [1,3,0,0xED,0xA0,0x80]] {
            XCTAssertNil(TextCommitCommand.decode(Data(bytes)))
        }
        for text in ["", "\0", "\t", "\n", "\r", "\u{85}", String(repeating: "a", count: 4097)] {
            XCTAssertNil(TextCommitCommand(text: text).encode())
        }
    }
    func testChunkingPreservesGraphemes() {
        let original = String(repeating: "a\u{0301}👨‍👩‍👧‍👦", count: 1000)
        let chunks = TextCommitCommand.chunks(original)
        XCTAssertEqual(Array(chunks.map(\.text).joined().utf8), Array(original.utf8))
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty && $0.text.utf8.count <= 4096 })
        XCTAssertFalse(TextCommitDeliveryPolicy.maySend(inputSuppressed: true))
        XCTAssertTrue(TextCommitCommand.chunks("a" + String(repeating:"\u{0301}",count:4096)).isEmpty)
    }
    func testAuthorityPriority() {
        for active in [false,true] { for hardware in [false,true] { for requested in [false,true] {
            XCTAssertEqual(RemoteKeyboardMode.resolve(active:active,hardware:hardware,requested:requested), !active ? .none : requested ? .softwareOpen : hardware ? .hardware : .softwareAvailable)
        } } }
    }
    func testSpecialKeyOrdering() {
        XCTAssertEqual(SoftwareKeyboardRouter.route("abc\r\nđ\t"), [.text("abc"), .key(0x0D), .text("đ"), .key(0x09)])
        XCTAssertTrue(SoftwareKeyboardRouter.route("a\0b").isEmpty)
    }
    @MainActor func testMarkedDiscardAndCommittedExactlyOnce() {
        let view = RemoteSoftwareKeyboardTextView()
        var delivered: [SoftwareKeyboardEmission] = []
        view.onEmission = { delivered.append($0) }
        view.deliveryEnabled = true
        view.setMarkedText("Tiếng", selectedRange:NSRange(location:5,length:0))
        view.consumeCommittedBuffer()
        XCTAssertTrue(delivered.isEmpty)
        view.deactivateAndDiscardComposition()
        view.consumeCommittedBuffer()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(view.text, "")
        XCTAssertFalse(view.deliveryEnabled)
        view.deliveryEnabled = true
        view.text = "đ😀"
        view.consumeCommittedBuffer()
        view.consumeCommittedBuffer()
        XCTAssertEqual(delivered, [.text("đ😀")])
        view.deleteBackward()
        XCTAssertEqual(delivered.last, .key(0x08))
    }
    @MainActor func testNativeVietnameseTailReplacementDoesNotAppendOldBase() {
        let view = RemoteSoftwareKeyboardTextView()
        var emitted: [SoftwareKeyboardEmission] = []
        view.onEmission = { emitted.append($0) }
        view.deliveryEnabled = true
        view.text = "d"
        view.consumeCommittedBuffer()
        view.text = "đ"
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted, [.text("d"), .key(0x08), .text("đ")])
        XCTAssertEqual(view.text, "đ")
    }
    @MainActor func testNativeCommittedEditTraceMatchesPhysicalVietnamesePhrase() {
        let view = RemoteSoftwareKeyboardTextView()
        var remote = ""
        view.onEmission = {
            switch $0 {
            case .text(let text): remote.append(text)
            case .key(0x08): if !remote.isEmpty { remote.removeLast() }
            default: XCTFail("Unexpected control key in phrase")
            }
        }
        view.deliveryEnabled = true
        for text in ["d", "đ", "đe", "đep", "đẹp", "đẹp ", "đẹp v", "đẹp va",
                     "đẹp vai", "đẹp vãi", "đẹp vãi ", "đẹp vãi c", "đẹp vãi ca",
                     "đẹp vãi cả", "đẹp vãi cả ", "đẹp vãi cả n", "đẹp vãi cả nh",
                     "đẹp vãi cả nho", "đẹp vãi cả nhô", "đẹp vãi cả nhôn", "đẹp vãi cả nhồn"] {
            view.text = text
            view.consumeCommittedBuffer()
            view.consumeCommittedBuffer()
            XCTAssertEqual(Array(remote.utf8), Array(text.utf8))
        }
        XCTAssertEqual(remote, "đẹp vãi cả nhồn")
    }
    @MainActor func testNativeCommittedShadowPreservesExactUnicodeAndGraphemes() {
        let view = RemoteSoftwareKeyboardTextView()
        var emitted: [SoftwareKeyboardEmission] = []
        view.deliveryEnabled = true
        view.onEmission = { emitted.append($0) }
        for text in ["a", "ab", "abc"] { view.text = text; view.consumeCommittedBuffer() }
        XCTAssertEqual(emitted, [.text("a"), .text("b"), .text("c")])
        view.deactivateAndDiscardComposition()
        view.deliveryEnabled = true
        emitted.removeAll()
        view.text = "é👨‍👩‍👧‍👦"
        view.consumeCommittedBuffer()
        view.text = "e\u{0301}👩🏽‍💻"
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted.count, 4)
        XCTAssertEqual(emitted[1], .key(0x08))
        XCTAssertEqual(emitted[2], .key(0x08))
        if case .text(let replacement) = emitted[3] {
            XCTAssertEqual(Array(replacement.utf8), Array("e\u{0301}👩🏽‍💻".utf8))
        } else { XCTFail("Missing exact NFD replacement") }
    }
    @MainActor func testNativeShadowBackspaceAndControlKeysKeepOrdering() {
        let view = RemoteSoftwareKeyboardTextView()
        var emitted: [SoftwareKeyboardEmission] = []
        view.deliveryEnabled = true
        view.onEmission = { emitted.append($0) }
        view.insertText("a")
        view.deleteBackward()
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted, [.text("a"), .key(0x08)])
        view.deleteBackward()
        XCTAssertEqual(emitted, [.text("a"), .key(0x08), .key(0x08)])
        emitted.removeAll()
        view.insertText("abc\r\nđ\t")
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted, [.text("abc"), .key(0x0D), .text("đ"), .key(0x09)])
    }
    @MainActor func testNativeShadowIsBoundedAndDeactivationDoesNotDeleteRemoteText() {
        let view = RemoteSoftwareKeyboardTextView()
        var emitted: [SoftwareKeyboardEmission] = []
        view.deliveryEnabled = true
        view.onEmission = { emitted.append($0) }
        let longText = String(repeating: "a", count: 1000)
        view.text = longText
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted, [.text(longText)])
        XCTAssertLessThanOrEqual(view.text.count, 128)
        let tail = view.text ?? ""
        view.text = tail + "b"
        view.consumeCommittedBuffer()
        XCTAssertEqual(emitted.last, .text("b"))
        let before = emitted
        view.deactivateAndDiscardComposition()
        XCTAssertEqual(emitted, before)
        XCTAssertEqual(view.text, "")
    }
    @MainActor func testResponderHandoff() {
        let container = ConnectedPresentationContainer(frame:CGRect(x:0,y:0,width:500,height:500))
        var keys: [KeyboardInputCommand] = []
        container.touchView.onKeyboardInput = { keys.append($0) }
        container.applyRemoteKeyboardMode(.hardware)
        _ = container.touchView.handleHardwareKey(.keyboardLeftGUI, action:.keyDown)
        container.applyRemoteKeyboardMode(.softwareOpen)
        XCTAssertFalse(container.touchView.keyboardCaptureEnabled)
        XCTAssertEqual(keys.last?.action, .keyUp)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        container.softwareTextView.setMarkedText("pending", selectedRange: NSRange(location:7,length:0))
        container.applyRemoteKeyboardMode(.hardware)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
        XCTAssertEqual(container.softwareTextView.text, "")
        container.applyRemoteKeyboardMode(.softwareAvailable)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
        XCTAssertFalse(container.touchView.keyboardCaptureEnabled)
        for mode in [RemoteKeyboardMode.none, .hardware, .softwareAvailable, .softwareOpen] {
            container.applyRemoteKeyboardMode(mode)
            XCTAssertEqual(container.keyboardButton.isHidden, mode == .none)
            XCTAssertFalse(container.touchView.keyboardCaptureEnabled && container.softwareTextView.deliveryEnabled)
        }
        container.retireRemoteKeyboard()
        XCTAssertEqual(container.keyboardMode, .none)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
    }
    @MainActor func testFloatingControlOwnsOnlyItsLocalHitTarget() {
        let container = ConnectedPresentationContainer(frame:CGRect(x:0,y:0,width:1000,height:800))
        container.applyRemoteKeyboardMode(.softwareAvailable)
        container.layoutIfNeeded()
        let button = container.keyboardButton
        let point = CGPoint(x:button.frame.midX,y:button.frame.midY)
        XCTAssertTrue(container.hitTest(point,with:nil) === button)
        XCTAssertTrue(container.hitTest(CGPoint(x:300,y:300),with:nil) === container.touchView)
    }
    @MainActor func testKeyboardFadeRemainsOneTapAndCancellationRestoresOpacity() async throws {
        let container = ConnectedPresentationContainer(frame:CGRect(x:0,y:0,width:1000,height:800))
        container.applyRemoteKeyboardMode(.softwareAvailable)
        XCTAssertEqual(container.keyboardButton.alpha, 1)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        XCTAssertEqual(container.keyboardButton.alpha, 0.30, accuracy:0.001)
        container.applyRemoteKeyboardMode(.none)
        container.applyRemoteKeyboardMode(.softwareAvailable)
        XCTAssertEqual(container.keyboardButton.alpha, 1)
        XCTAssertTrue(container.keyboardButton.isUserInteractionEnabled)
        container.retireRemoteKeyboard()
    }
    @MainActor func testGenerationAndLifecycleDoNotReplaySoftwareIntent() {
        let container = ConnectedPresentationContainer(frame:CGRect(x:0,y:0,width:1000,height:800))
        container.configureRemoteKeyboard(active:true,generation:1)
        container.applyRemoteKeyboardMode(.softwareOpen)
        container.softwareTextView.setMarkedText("pending",selectedRange:NSRange(location:7,length:0))
        container.hardwarePresenceChanged(true)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        XCTAssertEqual(container.softwareTextView.text, "pending")
        container.hardwarePresenceChanged(false)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        container.applyRemoteKeyboardMode(.softwareOpen)
        container.configureRemoteKeyboard(active:true,generation:2)
        XCTAssertNotEqual(container.keyboardMode, .softwareOpen)
        container.configureRemoteKeyboard(active:false,generation:2)
        XCTAssertEqual(container.keyboardMode, .none)
        container.configureRemoteKeyboard(active:true,generation:2)
        XCTAssertNotEqual(container.keyboardMode, .softwareOpen)
    }
    func testFloatingPlacementAndFade() {
        let bounds = CGRect(x:0,y:0,width:1000,height:800)
        let insets = UIEdgeInsets(top:20,left:0,bottom:20,right:20)
        let normal = FloatingKeyboardPlacement.frame(bounds:bounds,safeArea:insets,keyboard:nil)
        XCTAssertEqual(normal.size, CGSize(width:48,height:48))
        let raised = FloatingKeyboardPlacement.frame(bounds:bounds,safeArea:insets,keyboard:CGRect(x:500,y:500,width:500,height:300))
        XCTAssertLessThanOrEqual(raised.maxY, 500)
        XCTAssertEqual(normal.minX, raised.minX)
        XCTAssertEqual(FloatingKeyboardPlacement.dimOpacity, 0.30)
        XCTAssertEqual(FloatingKeyboardPlacement.fadeSeconds, 3)
    }
}

final class PostKeyboardV2CorrectiveTests: XCTestCase {
    @MainActor func testAppendOnlyKeyboardDisablesReplacementTraits() {
        let view = RemoteSoftwareKeyboardTextView()
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.smartDashesType, .no)
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no)
    }

    @MainActor func testAppendOnlyMarkedUnicodeStillCommitsExactlyOnce() {
        let view = RemoteSoftwareKeyboardTextView()
        let original = "Tiếng Việt a\u{0301}😀👨‍👩‍👧‍👦"
        var emissions: [SoftwareKeyboardEmission] = []
        view.onEmission = { emissions.append($0) }
        view.deliveryEnabled = true
        view.setMarkedText(original, selectedRange: NSRange(location:0, length:0))
        view.consumeCommittedBuffer()
        XCTAssertTrue(emissions.isEmpty)
        view.unmarkText()
        view.consumeCommittedBuffer()
        XCTAssertEqual(emissions.count, 1)
        guard case .text(let committed) = emissions.first else { return XCTFail("missing commit") }
        XCTAssertEqual(Array(committed.utf8), Array(original.utf8))
        view.deleteBackward()
        XCTAssertEqual(emissions.last, .key(0x08))
    }
}

final class PointerV2WireRegistrationTests: XCTestCase {
    func testDirectTouchExactLittleEndianAndMalformedPayloads() {
        for phase: DirectTouchPhase in [.down, .update, .up, .cancel] {
            let command = DirectTouchContactCommand(phase: phase, pressure: 255,
                contactID: 0x0807060504030201, x: 0x1234, y: 0xABCD)
            let bytes: [UInt8] = [1, phase.rawValue, 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0x34, 0x12, 0xCD, 0xAB]
            XCTAssertEqual(Array(command.encode()), bytes)
            XCTAssertEqual(DirectTouchContactCommand.decode(Data(bytes)), command)
            for (offset, value): (Int, UInt8) in [(0, 2), (1, 4), (3, 1)] {
                var bad = bytes; bad[offset] = value
                XCTAssertNil(DirectTouchContactCommand.decode(Data(bad)))
            }
            var zero = bytes; zero.replaceSubrange(4..<12, with: repeatElement(UInt8(0), count: 8))
            XCTAssertNil(DirectTouchContactCommand.decode(Data(zero)))
            XCTAssertNil(DirectTouchContactCommand.decode(Data(bytes.dropLast())))
            XCTAssertNil(DirectTouchContactCommand.decode(Data(bytes + [0])))
        }
    }

    func testOwnershipExactABIAndStrictValidation() {
        for state: CursorOwnershipState in [.clientActive, .hostActive] {
            let command = CursorOwnershipCommand(state: state)
            XCTAssertEqual(Array(command.encode()), [1, state.rawValue])
            XCTAssertEqual(CursorOwnershipCommand.decode(command.encode()), command)
        }
        for bytes: [UInt8] in [[2, 0], [1, 2], [1], [1, 0, 0]] {
            XCTAssertNil(CursorOwnershipCommand.decode(Data(bytes)))
        }
    }

    func testAdditiveIDsPreserveFrozenInputABI() {
        XCTAssertNotNil(WireMessageType(rawValue: 41), "DirectTouchContact must register audited free raw41")
        XCTAssertNotNil(WireMessageType(rawValue: 42), "CursorOwnership must register audited free raw42")
        XCTAssertEqual(WireMessageType.pipelineMode.rawValue, 36)
        XCTAssertEqual(WireMessageType.pointerInput.rawValue, 37)
        XCTAssertEqual(PointerInputCommand.encodedSize, 8)
        XCTAssertEqual(WireMessageType.keyboardInput.rawValue, 38)
        XCTAssertEqual(WireMessageType.clientPerformanceFeedback.rawValue, 39)
        XCTAssertEqual(WireMessageType.textCommit.rawValue, 40)
    }

    func testMalformedFixedV2PacketDrainsAndNextMessageParses() {
        for (raw, expectedSize): (UInt8, Int) in [(41, 16), (42, 2)] {
            for malformedSize in [0, expectedSize - 1, expectedSize + 1] {
                let parser = WireStreamParser(generation: 4)
                var discarded = 0
                var acceptedPing = 0
                var failures = 0
                var input = packet(raw: raw, payload: Data(repeating: 0, count: malformedSize))
                input.append(packet(raw: WireMessageType.ping.rawValue, payload: Data(repeating: 0, count: 16)))
                for byte in input {
                    parser.consume(Data([byte]), generation: 4) { event in
                        switch event {
                        case .discardedFixedControl(let header):
                            if header.type.rawValue == raw { discarded += 1 }
                        case .message(let message):
                            if message.header.type == .ping { acceptedPing += 1 }
                        case .failure: failures += 1
                        default: break
                        }
                    }
                }
                XCTAssertEqual(discarded, 1, "raw\(raw) malformed length \(malformedSize)")
                XCTAssertEqual(acceptedPing, 1)
                XCTAssertEqual(failures, 0)
            }
        }
    }

    private func packet(raw: UInt8, payload: Data) -> Data {
        var data = Data(count: WireProtocol.headerSize)
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: WireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: WireProtocol.version, toByteOffset: 4, as: UInt8.self)
            bytes.storeBytes(of: raw, toByteOffset: 5, as: UInt8.self)
            bytes.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        data.append(payload)
        return data
    }
}

final class TouchGestureV2ContractTests: XCTestCase {
    func testOneMoveCallbackParallelTranslationHasNoIntermediatePinch() {
        for reversed in [false, true] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
            let movements: [(id: UInt64, point: CGPoint, timestamp: TimeInterval)] = [
                (1, CGPoint(x: 20, y: 0), 0.1), (2, CGPoint(x: 120, y: 0), 0.1)]
            let output = machine.moveBatch(reversed ? Array(movements.reversed()) : movements)
            XCTAssertTrue(output.isEmpty, "One UIKit callback must evaluate the final pair span, not an intermediate span")
            XCTAssertTrue(machine.end(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.15).isEmpty)
            XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 120, y: 0), timestamp: 0.16).isEmpty)
        }
    }

    func testSecondaryLiftDoesNotRetireCommittedOneFingerDrag() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertEqual(phases(machine.move(id: 1, point: CGPoint(x: 7, y: 0), timestamp: 1.1)), [.down, .update])
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 1.12)
        XCTAssertTrue(machine.end(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 1.14).isEmpty)
        XCTAssertEqual(phases(machine.move(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 1.16)), [.update])
        XCTAssertEqual(phases(machine.end(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 1.18)), [.up])
    }

    func testTwoFingerTapRequiresBothContactsAndUsesCentroidAfterBothLift() {
        for firstLift: UInt64 in [1, 2] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: CGPoint(x: 20, y: 40), timestamp: 0)
            machine.begin(id: 2, point: CGPoint(x: 100, y: 40), timestamp: 0.03)
            let firstPoint = firstLift == 1 ? CGPoint(x: 20, y: 40) : CGPoint(x: 100, y: 40)
            XCTAssertTrue(machine.end(id: firstLift, point: firstPoint, timestamp: 0.1).isEmpty)
            let lastPoint = firstLift == 1 ? CGPoint(x: 100, y: 40) : CGPoint(x: 20, y: 40)
            XCTAssertEqual(machine.end(id: firstLift == 1 ? 2 : 1, point: lastPoint, timestamp: 0.12),
                [.pointer(.rightClick, CGPoint(x: 60, y: 40), 0)])
        }
    }

    func testEitherFingerExcursionPermanentlyDisqualifiesRightClick() {
        for moved: UInt64 in [1, 2] {
            var machine = DirectTouchGestureStateMachine()
            let start = moved == 1 ? CGPoint.zero : CGPoint(x: 100, y: 0)
            machine.begin(id: 1, point: .zero, timestamp: 0)
            machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
            machine.move(id: moved, point: CGPoint(x: start.x, y: 14), timestamp: 0.05)
            machine.move(id: moved, point: start, timestamp: 0.06)
            let output = machine.end(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.1) +
                machine.end(id: 1, point: .zero, timestamp: 0.12)
            XCTAssertFalse(output.contains { if case .pointer(.rightClick, _, _) = $0 { return true }; return false })
            XCTAssertTrue(phases(output).isEmpty)
        }
    }

    func testPinchApartAndTogetherProduceSignedZoomWithoutContactOrSettings() {
        for (x, sign) in [(CGFloat(120), 1), (CGFloat(80), -1)] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 1, point: .zero, timestamp: 0)
            machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
            let output = machine.move(id: 2, point: CGPoint(x: x, y: 0), timestamp: 0.05)
            XCTAssertTrue(phases(output).isEmpty)
            XCTAssertGreaterThan(wheel(output, action: .zoomWheel) * sign, 0)
            machine.begin(id: 3, point: CGPoint(x: 50, y: 0), timestamp: 0.06)
            var terminal = machine.end(id: 1, point: .zero, timestamp: 0.1)
            terminal += machine.end(id: 2, point: CGPoint(x: x, y: 0), timestamp: 0.11)
            terminal += machine.end(id: 3, point: CGPoint(x: 50, y: 0), timestamp: 0.12)
            XCTAssertFalse(terminal.contains(.openSettings))
            XCTAssertFalse(terminal.contains { if case .pointer(.rightClick, _, _) = $0 { return true }; return false })
        }
    }

    private func phases(_ outputs: [DirectTouchGestureOutput]) -> [DirectTouchPhase] {
        outputs.compactMap { if case .directTouch(let phase, _, _, _) = $0 { return phase }; return nil }
    }

    private func wheel(_ outputs: [DirectTouchGestureOutput], action: PointerInputAction) -> Int {
        outputs.reduce(0) { total, output in
            if case .pointer(let candidate, _, let value) = output, candidate == action { return total + Int(value) }
            return total
        }
    }

    func testEarlyVerticalMovementIsWheelOnlyWithNaturalCalibration() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        let output = machine.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.2)
        XCTAssertTrue(phases(output).isEmpty)
        XCTAssertEqual(wheel(output, action: .verticalWheel), 120)
        XCTAssertTrue(machine.end(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 0.3).isEmpty)
    }

    func testEarlyHorizontalMovementIsWheelOnlyAndAxisStaysLocked() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        let first = machine.move(id: 1, point: CGPoint(x: 72, y: 0), timestamp: 0.2)
        XCTAssertTrue(phases(first).isEmpty)
        XCTAssertEqual(wheel(first, action: .horizontalWheel), -120)
        let next = machine.move(id: 1, point: CGPoint(x: 144, y: 100), timestamp: 1.5)
        XCTAssertTrue(phases(next).isEmpty)
        XCTAssertEqual(wheel(next, action: .horizontalWheel), -120)
        XCTAssertEqual(wheel(next, action: .verticalWheel), 0)
    }

    func testMovementBeforeHoldCannotBecomeDragWhenThresholdCrossesLater() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 0, y: 9), timestamp: 0.499).isEmpty)
        let output = machine.move(id: 1, point: CGPoint(x: 0, y: 72), timestamp: 1.05)
        XCTAssertTrue(phases(output).isEmpty)
        XCTAssertEqual(wheel(output, action: .verticalWheel), 120)
    }

    func testStationaryHoldThenMoveCommitsOneContactAndRetiresOnce() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: CGPoint(x: 10, y: 20), timestamp: 0)
        XCTAssertTrue(machine.move(id: 1, point: CGPoint(x: 10, y: 20), timestamp: 1).isEmpty)
        let output = machine.move(id: 1, point: CGPoint(x: 17, y: 20), timestamp: 1.1)
        XCTAssertEqual(phases(output), [.down, .update])
        XCTAssertEqual(wheel(output, action: .horizontalWheel), 0)
        XCTAssertEqual(phases(machine.retire()), [.cancel])
        XCTAssertTrue(machine.retire().isEmpty)
        XCTAssertTrue(machine.end(id: 1, point: .zero, timestamp: 1.2).isEmpty)
    }

    func testLongHoldWithoutDragStillTapsOriginalAnchor() {
        var machine = DirectTouchGestureStateMachine()
        let anchor = CGPoint(x: 10, y: 20)
        machine.begin(id: 1, point: anchor, timestamp: 0)
        let output = machine.end(id: 1, point: CGPoint(x: 12, y: 21), timestamp: 1.5)
        XCTAssertEqual(phases(output), [.down, .up])
        for event in output {
            if case .directTouch(_, _, let point, _) = event { XCTAssertEqual(point, anchor) }
        }
    }

    func testTwoFingerMovementNeverCommitsOldModifierDragOrRightClick() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.begin(id: 2, point: CGPoint(x: 100, y: 0), timestamp: 0.01)
        var output = machine.move(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.1)
        output += machine.move(id: 2, point: CGPoint(x: 120, y: 0), timestamp: 0.11)
        output += machine.end(id: 2, point: CGPoint(x: 120, y: 0), timestamp: 0.15)
        output += machine.end(id: 1, point: CGPoint(x: 20, y: 0), timestamp: 0.16)
        XCTAssertTrue(phases(output).isEmpty)
        XCTAssertFalse(output.contains { if case .pointer(.rightClick, _, _) = $0 { return true }; return false })
    }
}

final class PointerV2GestureMigrationTests: XCTestCase {
    func testContinuousFileSelectionDragEmitsOnlyRaw41Contacts() {
        var machine = DirectTouchGestureStateMachine()
        var outputs = machine.begin(id: 500, point: CGPoint(x: 100, y: 100), timestamp: 0)
        outputs += machine.move(id: 500, point: CGPoint(x: 100, y: 100), timestamp: 1)
        for index in 1...40 {
            outputs += machine.move(id: 500, point: CGPoint(x: 100 + index * 5, y: 100 + index * 3), timestamp: 1.1 + Double(index) * 0.02)
        }
        outputs += machine.end(id: 500, point: CGPoint(x: 300, y: 220), timestamp: 2)
        XCTAssertTrue(mouseActions(outputs).isEmpty)
        let phases = outputs.compactMap { output -> DirectTouchPhase? in
            if case .directTouch(let phase, _, _, _) = output { return phase }
            return nil
        }
        XCTAssertEqual(phases.first, .down)
        XCTAssertEqual(phases.last, .up)
        XCTAssertGreaterThan(phases.filter { $0 == .update }.count, 20)
    }
    private func mouseActions(_ outputs: [DirectTouchGestureOutput]) -> [PointerInputAction] {
        outputs.compactMap { if case .pointer(let action, _, _) = $0 { return action }; return nil }
    }
    func testQualifiedTapIsContactPairWithNoMousePacket() {
        var machine = DirectTouchGestureStateMachine()
        XCTAssertTrue(machine.begin(id: 17, point: .zero, timestamp: 0).isEmpty)
        let output = machine.end(id: 17, point: .zero, timestamp: 0.1)
        XCTAssertEqual(output.count, 2, "Qualified tap must produce Down/Up")
        XCTAssertTrue(mouseActions(output).isEmpty, "Finger tap must not emit raw37 mouse activation")
    }
    func testEarlyScrollUsesOnlyWheelAndLongHoldDragRetainsContactTerminal() {
        for horizontal in [false, true] {
            var machine = DirectTouchGestureStateMachine()
            machine.begin(id: 18, point: .zero, timestamp: 0)
            let point = horizontal ? CGPoint(x: 72, y: 0) : CGPoint(x: 0, y: 72)
            let start = machine.move(id: 18, point: point, timestamp: 0.02)
            XCTAssertEqual(start.count, 1, "Scroll sends one bounded semantic wheel, not raw41")
            XCTAssertEqual(mouseActions(start), [horizontal ? .horizontalWheel : .verticalWheel])
            let secondPoint = horizontal ? CGPoint(x: 144, y: 55) : CGPoint(x: 55, y: 144)
            let move = machine.move(id: 18, point: secondPoint, timestamp: 0.04)
            XCTAssertEqual(move.count, 1)
            XCTAssertEqual(mouseActions(move), [horizontal ? .horizontalWheel : .verticalWheel])
            let end = machine.end(id: 18, point: CGPoint(x: 55, y: 55), timestamp: 0.08)
            XCTAssertTrue(end.isEmpty, "Semantic wheel has no retained contact or terminal Up")
            XCTAssertTrue(mouseActions(end).isEmpty)
            XCTAssertTrue(machine.end(id: 18, point: .zero, timestamp: 0.09).isEmpty)
        }
        var drag = DirectTouchGestureStateMachine()
        drag.begin(id: 19, point: .zero, timestamp: 0)
        let start = drag.move(id: 19, point: CGPoint(x: 7, y: 0), timestamp: 1.1)
        XCTAssertEqual(start.count, 2)
        XCTAssertTrue(mouseActions(start).isEmpty)
        let cancelled = drag.end(id: 19, point: CGPoint(x: 7, y: 0), timestamp: 1.13, cancelled: true)
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertTrue(mouseActions(cancelled).isEmpty)
        XCTAssertTrue(drag.retire().isEmpty)
    }
    func testPencilPreemptsContactWithoutMouseRelease() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 21, point: .zero, timestamp: 0)
        machine.move(id: 21, point: CGPoint(x: 7, y: 0), timestamp: 1.1)
        let output = machine.pencilBegan(timestamp: 1.13)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(mouseActions(output).isEmpty, "Pencil preemption must Cancel native contact")
        XCTAssertTrue(machine.end(id: 21, point: .zero, timestamp: 1.14).isEmpty)
    }
}

final class PointerV2CursorOverlayTests: XCTestCase {
    @MainActor func testLocalCursorIsAbsentAndKeyboardRetainsLocalHitTarget() {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertFalse(container.subviews.contains { $0.accessibilityIdentifier == "client-local-cursor" })
        XCTAssertLessThan(container.subviews.firstIndex(of: container.metalView)!, container.subviews.firstIndex(of: container.touchView)!)
        XCTAssertLessThan(container.subviews.firstIndex(of: container.touchView)!, container.subviews.firstIndex(of: container.keyboardButton)!)
    }
}

final class PointerV2LifecycleTests: XCTestCase {
    @MainActor func testCaptureDisableAndViewportReplacementCancelExactlyOnce() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.configureDirectTouch(active: true, generation: 1)
        var packets: [DirectTouchContactCommand] = []
        view.onDirectTouchContact = { packets.append($0) }
        view.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 100, y: 100), 255)])
        view.configureDirectTouch(active: false, generation: 1)
        view.configureDirectTouch(active: false, generation: 1)
        XCTAssertEqual(packets.map(\.phase), [.down, .cancel])
        view.configureDirectTouch(active: true, generation: 1)
        view.emitDirectOutputs([.directTouch(.down, 2, CGPoint(x: 100, y: 100), 255)])
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0.2, y: 0, width: 0.6, height: 1))
        view.emitDirectOutputs([.directTouch(.up, 2, CGPoint(x: 100, y: 100), 255)])
        XCTAssertEqual(packets.map(\.phase), [.down, .cancel, .down, .cancel])
    }
    func testSuppressionAllowsOnlyTerminalAndNoContactRevival() {
        for phase: DirectTouchPhase in [.down, .update, .up, .cancel] {
            XCTAssertEqual(DirectTouchDeliveryPolicy.maySend(phase: phase, inputSuppressed: true),
                phase == .up || phase == .cancel)
        }
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.move(id: 1, point: CGPoint(x: 0, y: 13), timestamp: 1.1)
        XCTAssertEqual(machine.retire().count, 1)
        XCTAssertTrue(machine.retire().isEmpty)
        XCTAssertTrue(machine.end(id: 1, point: .zero, timestamp: 1.13).isEmpty)
    }
}

final class PointerV2FinalBoundaryTests: XCTestCase {
    @MainActor private func softwareResponderFailureFixture() -> ConnectedPresentationContainer {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 309)
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyUp))
        container.softwareResponderAcquisitionForTesting = { false }
        return container
    }

    @MainActor func testSoftwareResponderFailureRestoresHardwareCaptureEligibility() {
        let container = softwareResponderFailureFixture()
        var commands: [KeyboardInputCommand] = []
        container.touchView.onKeyboardInput = { commands.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.keyboardCaptureEnabled)
        container.hardwarePresenceChanged(true)
        XCTAssertFalse(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyUp))
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyUp])
        XCTAssertEqual(commands.map(\.virtualKey), [0x41, 0x41])
        container.retireRemoteKeyboard()
    }

    @MainActor func testSoftwareResponderFailurePreservesSoftwareRequest() {
        let container = softwareResponderFailureFixture()
        var lines: [String] = []
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        XCTAssertTrue(lines.last?.contains("software_requested=1") == true)
        XCTAssertTrue(lines.last?.contains("responder_result=failure") == true)
        XCTAssertTrue(lines.last?.contains("reason=native_show_request_failed") == true)
        XCTAssertEqual(attempts, 1)
        container.retireRemoteKeyboard()
    }

    @MainActor func testSoftwareResponderFailureDoesNotDiscardMarkedComposition() {
        let container = softwareResponderFailureFixture()
        container.softwareTextView.deliveryEnabled = true
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        container.retireRemoteKeyboard()
    }

    @MainActor func testSoftwareResponderFailureDoesNotHideSoftwareKeyboardButton() {
        let container = softwareResponderFailureFixture()
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(container.keyboardButton.isHidden)
        container.retireRemoteKeyboard()
    }

    @MainActor func testSoftwareResponderFailureDoesNotClaimNativeVisibility() {
        let container = softwareResponderFailureFixture()
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(container.softwareTextView.isFirstResponder)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        XCTAssertTrue(lines.last?.contains("responder_result=failure") == true)
        container.retireRemoteKeyboard()
    }

    @MainActor func testSoftwareResponderSuccessKeepsSoftwareResponderOwnership() {
        let container = softwareResponderFailureFixture()
        container.softwareResponderAcquisitionForTesting = { true }
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.keyboardCaptureEnabled)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(lines.last?.contains("responder_result=success") == true)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        container.retireRemoteKeyboard()
    }

    @MainActor private func sceneBackedKeyboardGapFixture() throws -> (UIWindow, ConnectedPresentationContainer) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        let container = ConnectedPresentationContainer(frame: window.bounds)
        controller.view.addSubview(container)
        window.isHidden = false
        XCTAssertTrue(container.window === window)
        container.configureRemoteKeyboard(active: true, generation: 308)
        container.applyRemoteKeyboardMode(.softwareOpen)
        return (window, container)
    }

    @MainActor private func sceneBackedInitialKeyboardFixture() throws -> (UIWindow, ConnectedPresentationContainer) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        let container = ConnectedPresentationContainer(frame: window.bounds)
        controller.view.addSubview(container)
        window.isHidden = false
        XCTAssertTrue(container.window === window)
        container.configureRemoteKeyboard(active: true, generation: 308)
        return (window, container)
    }

    @MainActor func testVisibleKeyboardMovingOutsideClearsNativeVisibility() throws {
        let (window, container) = try sceneBackedKeyboardGapFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        for (y, visible): (CGFloat, Bool) in [(container.bounds.height - 200, true), (container.bounds.height + 100, false)] {
            let frame = window.convert(container.convert(CGRect(x: 0, y: y, width: container.bounds.width, height: 200), to: window), to: window.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
            XCTAssertTrue(lines.last?.contains("native_keyboard_visible=\(visible ? 1 : 0)") == true, lines.last ?? "No diagnostic")
            XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=0") == true)
            XCTAssertFalse(lines.last?.contains("keyboard_frame=none") == true)
        }
    }

    @MainActor func testOutsideKeyboardFrameCanReturnInsideAndBecomeVisibleAgain() throws {
        let (window, container) = try sceneBackedKeyboardGapFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        for inside in [true, false, true] {
            let y = inside ? container.bounds.height - 200 : container.bounds.height + 100
            let frame = window.convert(container.convert(CGRect(x: 0, y: y, width: container.bounds.width, height: 200), to: window), to: window.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
            XCTAssertTrue(lines.last?.contains("native_keyboard_visible=\(inside ? 1 : 0)") == true, lines.last ?? "No diagnostic")
            XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=0") == true)
        }
    }

    @MainActor func testPostHideSoftwareResponderLossPreservesSoftwareRequestAndReconcilesCapture() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var responderAcquired = true
        var acquisitionAttempts = 0
        container.softwareResponderAcquisitionForTesting = {
            acquisitionAttempts += 1
            return responderAcquired
        }
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(acquisitionAttempts, 1)
        XCTAssertTrue(container.touchView.softwareResponderOwnsInput)

        responderAcquired = false
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertFalse(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.passiveKeyboardCaptureEnabled)
        XCTAssertTrue(diagnostics.contains { $0.contains("reason=software_post_hide_recovery") || $0.contains("reason=software_post_hide_recovery_failed") })
    }

    @MainActor func testPencilBTPresenceAfterResponderLossDoesNotBecomeHardwareAuthority() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var responderAcquired = true
        container.softwareResponderAcquisitionForTesting = { responderAcquired }
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))

        responderAcquired = false
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        NotificationCenter.default.post(name: Notification.Name.GCKeyboardDidConnect, object: nil)
        container.touchView.onPencilInput?(PencilPacket(xRatio: 0.5, yRatio: 0.5, pressure: 1.0, tiltX: 0, tiltY: 0, pointerFlags: 1))

        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertFalse(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.passiveKeyboardCaptureEnabled)
    }

    @MainActor private func controlledRecycleFixture(acquired: Bool) throws -> (losses: Int, passiveDuring: Bool, ownsAfter: Bool, passiveAfter: Bool, marked: Bool, emissions: Int, reconciliations: Int) {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        container.softwareResponderAcquisitionForTesting = { container.softwareTextView.becomeFirstResponder() }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(container.softwareTextView.isFirstResponder)
        XCTAssertTrue(container.touchView.softwareResponderOwnsInput)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        var losses = 0, emissions = 0
        var passiveDuring = false
        var lines: [String] = []
        let originalLoss = container.softwareTextView.onPreservedSystemResponderLoss
        container.softwareTextView.onPreservedSystemResponderLoss = { losses += 1; originalLoss?() }
        container.softwareTextView.onEmission = { _ in emissions += 1 }
        container.touchView.diagnosticSink = { lines.append($0) }
        container.softwareResponderAcquisitionForTesting = {
            // Model a UIKit end-edit callback delivered inside the controlled acquire boundary.
            container.softwareTextView.textViewDidEndEditing(container.softwareTextView)
            passiveDuring = container.touchView.passiveKeyboardCaptureEnabled
            return acquired && container.softwareTextView.becomeFirstResponder()
        }
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        return (losses, passiveDuring, container.touchView.softwareResponderOwnsInput,
                container.touchView.passiveKeyboardCaptureEnabled,
                container.softwareTextView.markedTextRange != nil, emissions,
                lines.filter { $0.contains("reason=software_post_hide_recovery") }.count)
    }

    @MainActor func testControlledSoftwareRecycleDoesNotActivatePassiveCaptureMidRecycle() throws {
        let result = try controlledRecycleFixture(acquired: true)
        XCTAssertFalse(result.passiveDuring)
        XCTAssertEqual(result.losses, 0)
    }

    @MainActor func testControlledSoftwareRecycleReconcilesOwnershipExactlyOnceAfterAcquire() throws {
        let result = try controlledRecycleFixture(acquired: true)
        XCTAssertEqual(result.losses, 0)
        XCTAssertEqual(result.reconciliations, 1)
    }

    @MainActor func testFailedControlledRecycleEnablesPassiveCaptureAfterAcquireFailure() throws {
        let result = try controlledRecycleFixture(acquired: false)
        XCTAssertFalse(result.passiveDuring)
        XCTAssertFalse(result.ownsAfter)
        XCTAssertTrue(result.passiveAfter)
        XCTAssertEqual(result.reconciliations, 1)
    }

    @MainActor func testSuccessfulControlledRecycleLeavesSoftwareResponderOwnership() throws {
        let result = try controlledRecycleFixture(acquired: true)
        XCTAssertTrue(result.ownsAfter)
        XCTAssertFalse(result.passiveAfter)
    }

    @MainActor func testControlledRecyclePreservesMarkedCompositionAndEmitsNoRemoteText() throws {
        let result = try controlledRecycleFixture(acquired: true)
        XCTAssertTrue(result.marked)
        XCTAssertEqual(result.emissions, 0)
    }

    @MainActor func testRemoteSoftwareKeyboardSuppressesScribble() throws {
        let view = RemoteSoftwareKeyboardTextView(frame: .zero, textContainer: nil)
        let interaction = try XCTUnwrap(view.interactions.compactMap { $0 as? UIScribbleInteraction }.first)
        let delegate = try XCTUnwrap(interaction.delegate)
        XCTAssertEqual(delegate.scribbleInteraction?(interaction, shouldBeginAt: .zero), false)
    }

    @MainActor func testHardwarePresenceDoesNotBlockPostHideSoftwareRecovery() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.touchView.handleHardwareKey(.keyboardA, action: .keyDown)
        container.touchView.handleHardwareKey(.keyboardA, action: .keyUp)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(container.touchView.keyboardCaptureEnabled)
        XCTAssertEqual(attempts, 1)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.touchView.keyboardCaptureEnabled)
        XCTAssertTrue(container.touchView.passiveKeyboardCaptureEnabled)
    }

    @MainActor func testDidShowWithoutGeometryDoesNotResetHideRecoveryBudget() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        var lines: [String] = []
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(attempts, 1)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=1") == true)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2, "DidShow alone must not rearm a consumed recovery budget")
    }

    @MainActor func testOffscreenDidShowDoesNotResetHideRecoveryBudget() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        var lines: [String] = []
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2)
        let outside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height + 100, width: container.bounds.width, height: 200),
            to: window), to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: outside])
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2, "Offscreen geometry must not rearm recovery")
    }

    @MainActor func testGeometryProvenVisibleKeyboardResetsHideRecoveryBudget() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        var lines: [String] = []
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.touchView.diagnosticSink = { lines.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2)
        let inside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height - 200, width: container.bounds.width, height: 200),
            to: window), to: window.screen.coordinateSpace)
        for (index, name) in [UIResponder.keyboardWillShowNotification,
                              UIResponder.keyboardWillChangeFrameNotification,
                              UIResponder.keyboardDidShowNotification].enumerated() {
            NotificationCenter.default.post(name: name, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: inside])
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
            XCTAssertTrue(lines.last?.contains("native_keyboard_visible=1") == true)
            XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=0") == true)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(attempts, 3 + index)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(attempts, 3 + index, "One recovery per genuine visible-to-hidden episode")
        }
    }

    @MainActor func testMinimizedKeyboardHideShowLoopCannotTriggerRepeatedRecovery() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 2)
        let minimized = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height, width: container.bounds.width, height: 0),
            to: window), to: window.screen.coordinateSpace)
        let outside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height + 100, width: container.bounds.width, height: 100),
            to: window), to: window.screen.coordinateSpace)
        for frame: CGRect? in [nil, minimized, outside, nil] {
            let info = frame.map { [UIResponder.keyboardFrameEndUserInfoKey: $0] }
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil, userInfo: info)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(attempts, 2, "Never-visible hide/show loops get only one recovery")
        }
        let inside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height - 200, width: container.bounds.width, height: 200),
            to: window), to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: inside])
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 3, "A real visible presentation permits exactly one new recovery")
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 3)
    }

    @MainActor func testTwoDistinctHideEpisodesEachReceiveOneRecoveryAttempt() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(attempts, 1)
        for expected in [2, 3] {
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(attempts, expected)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(attempts, expected, "A duplicate completed hide must not retry")
            let visible = window.convert(container.convert(
                CGRect(x: 0, y: container.bounds.height - 200, width: container.bounds.width, height: 200),
                to: window), to: window.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visible])
        }
    }

    @MainActor func testPreservedSystemResponderLossReconcilesTouchCaptureWithoutDiscardingComposition() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        container.softwareResponderAcquisitionForTesting = { true }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(container.touchView.softwareResponderOwnsInput)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        var emissions: [SoftwareKeyboardEmission] = []
        container.softwareTextView.onEmission = { emissions.append($0) }
        container.softwareTextView.textViewDidEndEditing(container.softwareTextView)
        XCTAssertFalse(container.touchView.softwareResponderOwnsInput)
        XCTAssertTrue(container.touchView.passiveKeyboardCaptureEnabled)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertTrue(emissions.isEmpty)
    }

    @MainActor func testResponderRetainedButNativeKeyboardHiddenGetsOneBoundedPresentationRecovery() throws {
        let (window, container) = try sceneBackedKeyboardGapFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        XCTAssertTrue(container.softwareTextView.becomeFirstResponder())
        XCTAssertTrue(container.softwareTextView.isFirstResponder)
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return true }
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 1)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
    }

    @MainActor func testPostHideRecoveryPreservesVietnameseMarkedComposition() throws {
        let (window, container) = try sceneBackedKeyboardGapFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        XCTAssertTrue(container.softwareTextView.becomeFirstResponder())
        var emissions: [SoftwareKeyboardEmission] = []
        container.softwareTextView.onEmission = { emissions.append($0) }
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return container.softwareTextView.becomeFirstResponder() }
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(container.softwareTextView.isFirstResponder)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertTrue(emissions.isEmpty)
    }

    @MainActor func testExplicitSoftwareDismissCancelsPendingRecovery() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
    }

    @MainActor func testGenerationReplacementCancelsPendingRecovery() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var attempts = 0
        container.softwareResponderAcquisitionForTesting = { attempts += 1; return false }
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        container.configureRemoteKeyboard(active: true, generation: 309)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
    }

    @MainActor func testRecoveryOccursAfterSystemHideHasCompletedWithoutUnboundedLoop() throws {
        let (window, container) = try sceneBackedInitialKeyboardFixture()
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var responderAcquired = true
        var recoveryAttempts = 0
        container.softwareResponderAcquisitionForTesting = {
            recoveryAttempts += 1
            return responderAcquired
        }
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(recoveryAttempts, 1)

        responderAcquired = false
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertEqual(recoveryAttempts, 1)

        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(recoveryAttempts, 2)
        XCTAssertTrue(diagnostics.contains { $0.contains("reason=software_post_hide_recovery") || $0.contains("reason=software_post_hide_recovery_failed") })

        for _ in 0..<3 {
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        }
        XCTAssertEqual(recoveryAttempts, 2)
    }

    @MainActor func testWillShowRequiresIntersectingKeyboardFrameEvidence() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        let container = ConnectedPresentationContainer(frame: window.bounds)
        controller.view.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertTrue(container.window === window)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 306)
        // Geometry notifications are tested without asking UIKit to show a real keyboard.
        container.applyRemoteKeyboardMode(.softwareOpen)
        let outside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height + 100, width: container.bounds.width, height: 200),
            to: window), to: window.screen.coordinateSpace)
        let inside = window.convert(container.convert(
            CGRect(x: 0, y: container.bounds.height - 200, width: container.bounds.width, height: 200),
            to: window), to: window.screen.coordinateSpace)
        XCTAssertGreaterThan(inside.height, 0)
        XCTAssertGreaterThan(container.bounds.height, 0)
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: outside])
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true, lines.last ?? "No diagnostic")
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: inside])
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=1") == true, lines.last ?? "No diagnostic")
        XCTAssertTrue(lines.last?.contains("show_attempt=0") == true)
        container.retireRemoteKeyboard()
    }

    @MainActor func testNativeKeyboardDiagnosticsRetainFrameAndClearItOnHide() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        let container = ConnectedPresentationContainer(frame: window.bounds)
        controller.view.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertTrue(container.window === window)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 307)
        container.applyRemoteKeyboardMode(.softwareOpen)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 600, width: 1000, height: 200)])
        XCTAssertTrue(lines.last?.contains("keyboard_frame=") == true)
        XCTAssertFalse(lines.last?.contains("keyboard_frame=none") == true)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertTrue(lines.last?.contains("keyboard_frame=none") == true)
        XCTAssertTrue(lines.last?.contains("software_requested=1") == true)
        container.retireRemoteKeyboard()
    }

    @MainActor func testFirstResponderRequestDoesNotImplyNativeKeyboardVisible() {
        let container = ConnectedPresentationContainer(frame: .zero)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 301)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        XCTAssertTrue(lines.last?.contains("show_attempt=1") == true)
    }

    @MainActor private func keyboardVisibilityAfterDidShow(frame: CGRect?, preceding: CGRect? = nil, hide: Bool = false) throws -> String {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        let container = ConnectedPresentationContainer(frame: window.bounds)
        controller.view.addSubview(container)
        window.isHidden = false
        defer { container.retireRemoteKeyboard(); window.isHidden = true }
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 801)
        container.applyRemoteKeyboardMode(.softwareOpen)
        func info(_ local: CGRect?) -> [AnyHashable: Any]? {
            guard let local else { return nil }
            return [UIResponder.keyboardFrameEndUserInfoKey:
                window.convert(container.convert(local, to: window), to: window.screen.coordinateSpace)]
        }
        if let preceding {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info(preceding))
        }
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil, userInfo: info(frame))
        if hide { NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil) }
        return try XCTUnwrap(lines.last)
    }

    @MainActor func testKeyboardDidShowWithoutFrameDoesNotProveNativeVisibility() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: nil)
        XCTAssertTrue(line.contains("native_keyboard_visible=0"), line)
        XCTAssertTrue(line.contains("native_keyboard_suppressed=0"), line)
    }

    @MainActor func testKeyboardDidShowWithOffscreenFrameRemainsNotVisible() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: CGRect(x: 0, y: 900, width: 1000, height: 100))
        XCTAssertTrue(line.contains("native_keyboard_visible=0"), line)
    }

    @MainActor func testKeyboardDidShowWithIntersectingFrameBecomesVisible() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: CGRect(x: 0, y: 600, width: 1000, height: 200))
        XCTAssertTrue(line.contains("native_keyboard_visible=1"), line)
        XCTAssertTrue(line.contains("native_keyboard_suppressed=0"), line)
    }

    @MainActor func testKeyboardDidShowWithoutFramePreservesPreviouslyProvenVisibleGeometry() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: nil, preceding: CGRect(x: 0, y: 600, width: 1000, height: 200))
        XCTAssertTrue(line.contains("native_keyboard_visible=1"), line)
    }

    @MainActor func testMinimizedKeyboardCannotBeMarkedVisibleByDidShowOnly() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: nil, preceding: CGRect(x: 0, y: 800, width: 1000, height: 0))
        XCTAssertTrue(line.contains("native_keyboard_visible=0"), line)
    }

    @MainActor func testNativeVisibilityStillClearsOnDidHide() throws {
        let line = try keyboardVisibilityAfterDidShow(frame: CGRect(x: 0, y: 600, width: 1000, height: 200), hide: true)
        XCTAssertTrue(line.contains("native_keyboard_visible=0"), line)
    }

    @MainActor func testKeyboardDidShowAndDidHideTrackNativeVisibility() {
        let container = ConnectedPresentationContainer(frame: .zero)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 302)
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=1") == true)
        XCTAssertTrue(lines.last?.contains("software_requested=1") == true)
    }

    @MainActor func testSuppressionKeepsRequestWithoutRepeatedShowAttempts() {
        let container = ConnectedPresentationContainer(frame: .zero)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 303)
        container.keyboardButton.sendActions(for: .touchUpInside)
        for _ in 0..<5 {
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            container.configureRemoteKeyboard(active: true, generation: 303)
        }
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=1") == true)
        XCTAssertTrue(lines.last?.contains("show_attempt=1") == true)
        XCTAssertEqual(lines.filter { $0.contains("reason=native_show_request") }.count, 1)
        XCTAssertTrue(lines.filter { $0.contains("reason=software_hide_recovery") }.isEmpty)
    }

    @MainActor func testExplicitNewRequestAndRetirementResetNativeVisibilityState() {
        let container = ConnectedPresentationContainer(frame: .zero)
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 304)
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(lines.last?.contains("show_attempt=2") == true)
        XCTAssertTrue(lines.last?.contains("native_keyboard_suppressed=0") == true)
        container.configureRemoteKeyboard(active: false, generation: 305)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        XCTAssertEqual(container.keyboardMode, .none)
        XCTAssertTrue(lines.last?.contains("native_keyboard_visible=0") == true)
        XCTAssertTrue(lines.last?.contains("software_requested=0") == true)
    }

    @MainActor func testHardwarePresenceDoesNotHideSoftwareKeyboardButton() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 201)
        container.hardwarePresenceChanged(true)
        XCTAssertFalse(container.keyboardButton.isHidden)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testHardwareKeyActivityDoesNotClearSoftwareRequest() {
        let container = ConnectedPresentationContainer(frame: .zero)
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 202)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertTrue(diagnostics.last?.contains("software_requested=1") == true)
    }

    @MainActor func testHardwareKeyActivityDoesNotDiscardMarkedSoftwareComposition() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 203)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testSoftwareAndHardwareInputMayCoexist() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 204)
        container.keyboardButton.sendActions(for: .touchUpInside)
        var commands: [KeyboardInputCommand] = []
        var text: [String] = []
        container.touchView.onKeyboardInput = { commands.append($0) }
        container.onTextCommit = { text.append($0) }
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyUp))
        container.softwareTextView.insertText("đẹp")
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyUp])
        XCTAssertEqual(commands.map(\.virtualKey), [0x41, 0x41])
        XCTAssertEqual(text, ["đẹp"])
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
    }

    @MainActor func testExplicitSoftwareDismissStillClosesOnlySoftwareKeyboard() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 205)
        container.keyboardButton.sendActions(for: .touchUpInside)
        _ = container.touchView.handleHardwareKey(.keyboardA, action: .keyDown)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyUp))
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardB, action: .keyDown))
    }

    @MainActor func testGenerationRetirementStillClearsSoftwareCompositionAndRequest() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 206)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đ", selectedRange: NSRange(location: 1, length: 0))
        container.configureRemoteKeyboard(active: false, generation: 207)
        XCTAssertEqual(container.keyboardMode, .none)
        XCTAssertTrue(container.keyboardButton.isHidden)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
        XCTAssertNil(container.softwareTextView.markedTextRange)
        XCTAssertFalse(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
    }

    @MainActor func testPencilCandidateHidePreservesSoftwareOpenAndMarkedText() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 91)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        container.softwareTextView.textViewDidEndEditing(container.softwareTextView)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
    }

    @MainActor func testPencilSystemHideDoesNotRepeatExplicitShowAttempt() async {
        let container = ConnectedPresentationContainer(frame: .zero)
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 92)
        container.keyboardButton.sendActions(for: .touchUpInside)
        for _ in 0..<3 {
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            await Task.yield()
        }
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertEqual(diagnostics.filter { $0.contains("reason=software_hide_recovery") }.count, 0)
        XCTAssertEqual(diagnostics.filter { $0.contains("reason=native_show_request") }.count, 1)
    }

    @MainActor func testRealHardwarePreservesPendingSoftwareHideAndComposition() async {
        let container = ConnectedPresentationContainer(frame: .zero)
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 93)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        var commands: [KeyboardInputCommand] = []
        container.touchView.onKeyboardInput = { commands.append($0) }
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertEqual(commands.map(\.virtualKey), [0x41])
        XCTAssertEqual(diagnostics.filter { $0.contains("reason=software_hide_recovery") }.count, 0)
    }

    @MainActor func testExplicitSoftwareDismissDoesNotRecover() async {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 94)
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.softwareTextView.setMarkedText("đ", selectedRange: NSRange(location: 1, length: 0))
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        XCTAssertNil(container.softwareTextView.markedTextRange)
        XCTAssertFalse(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testRetiredKeyboardGenerationCannotRecoverSystemHide() async {
        let container = ConnectedPresentationContainer(frame: .zero)
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 95)
        container.keyboardButton.sendActions(for: .touchUpInside)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        container.configureRemoteKeyboard(active: true, generation: 96)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        XCTAssertTrue(diagnostics.filter { $0.contains("reason=software_hide_recovery") }.isEmpty)
    }

    @MainActor func testSoftwareResponderHardwarePressCoexistsAndDeliversFirstKeyOnce() {
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 9)
        container.applyRemoteKeyboardMode(.softwareOpen)
        container.softwareTextView.setMarkedText("đẹp", selectedRange: NSRange(location: 3, length: 0))
        let press = UIPress()
        let nextPress = UIPress()
        container.touchView.hardwareKeyUsageForTesting = { candidate in
            candidate === press ? .keyboardA : .keyboardB
        }
        var commands: [KeyboardInputCommand] = []
        var text: [String] = []
        container.touchView.onKeyboardInput = { commands.append($0) }
        container.onTextCommit = { text.append($0) }
        container.softwareTextView.pressesBegan([press], with: nil)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "đẹp")
        XCTAssertEqual(commands.map(\.action), [.keyDown])
        XCTAssertEqual(commands.map(\.virtualKey), [0x41])
        container.touchView.pressesBegan([nextPress], with: nil)
        container.touchView.pressesEnded([press, nextPress], with: nil)
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyDown, .keyUp, .keyUp])
        XCTAssertEqual(commands.map(\.virtualKey), [0x41, 0x42, 0x41, 0x42])
        XCTAssertTrue(text.isEmpty)
        container.hardwarePresenceChanged(false)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testPencilCandidateAppearanceAndRemovalNeverClaimSoftwareAuthority() {
        var present = false
        let monitor = HardwareKeyboardMonitor(candidatePresence: { present })
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 9)
        container.applyRemoteKeyboardMode(.softwareAvailable)
        var transitions: [Bool] = []
        monitor.onChanged = { transitions.append($0); container.hardwarePresenceChanged($0) }
        present = true
        monitor.refresh()
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        XCTAssertFalse(container.keyboardButton.isHidden)
        container.applyRemoteKeyboardMode(.softwareOpen)
        container.softwareTextView.setMarkedText("đ", selectedRange: NSRange(location: 1, length: 0))
        monitor.refresh()
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        present = false
        monitor.refresh(disconnected: true)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertTrue(transitions.isEmpty)
    }

    @MainActor func testUnidentifiedDisconnectRevokesAuthorityWithoutReopeningSoftwareKeyboard() {
        let monitor = HardwareKeyboardMonitor(candidatePresence: { true })
        var transitions: [Bool] = []
        monitor.onChanged = { transitions.append($0) }
        monitor.recordKeyActivity()
        monitor.refresh(disconnected: true)
        XCTAssertFalse(monitor.isConnected)
        XCTAssertEqual(transitions, [true, false])
        monitor.refresh()
        XCTAssertFalse(monitor.isConnected, "A remaining accessory object is not positive key activity")
    }

    @MainActor func testKeyboardCandidateDoesNotOwnAuthorityUntilActualKeyActivity() {
        var present = false
        let monitor = HardwareKeyboardMonitor(candidatePresence: { present })
        var authority: [Bool] = []
        monitor.onChanged = { authority.append($0) }
        XCTAssertFalse(monitor.isConnected)
        present = true
        monitor.refresh()
        XCTAssertFalse(monitor.isConnected, "Pencil-only candidate must not activate hardware")
        XCTAssertTrue(authority.isEmpty)
        let container = ConnectedPresentationContainer(frame: .zero)
        container.configureRemoteKeyboard(active: true, generation: 1)
        container.applyRemoteKeyboardMode(.softwareOpen)
        monitor.onChanged = { authority.append($0); container.hardwarePresenceChanged($0) }
        monitor.refresh()
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        monitor.recordKeyActivity()
        XCTAssertTrue(monitor.isConnected)
        monitor.recordKeyActivity()
        XCTAssertEqual(authority, [true])
        present = false
        monitor.refresh()
        XCTAssertFalse(monitor.isConnected)
        XCTAssertEqual(authority, [true, false])
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testFirstHardwareKeyCoexistsWithSoftwareAndIsDeliveredOnce() {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        container.configureRemoteKeyboard(active: true, generation: 1)
        container.applyRemoteKeyboardMode(.softwareOpen)
        container.softwareTextView.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        var commands: [KeyboardInputCommand] = []
        var textCommits: [String] = []
        container.touchView.onKeyboardInput = { commands.append($0) }
        container.onTextCommit = { textCommits.append($0) }
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        XCTAssertNotNil(container.softwareTextView.markedTextRange)
        XCTAssertEqual(container.softwareTextView.text, "pending")
        XCTAssertEqual(commands.map(\.action), [.keyDown])
        XCTAssertEqual(commands.map(\.virtualKey), [0x41])
        XCTAssertTrue(textCommits.isEmpty)
        XCTAssertTrue(container.touchView.handleHardwareKey(.keyboardA, action: .keyUp))
        XCTAssertEqual(commands.map(\.action), [.keyDown, .keyUp])
        container.hardwarePresenceChanged(false)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }

    @MainActor func testPencilAndRealHardwarePreserveRequestedSoftwareKeyboard() {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var diagnostics: [String] = []
        container.touchView.diagnosticSink = { diagnostics.append($0) }
        container.configureRemoteKeyboard(active: true, generation: 1)
        container.hardwarePresenceChanged(false)
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        container.applyRemoteKeyboardMode(.softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        // Pencil arbitration is local to the direct gesture machine, not keyboard authority.
        var gestures = DirectTouchGestureStateMachine()
        _ = gestures.pencilBegan(timestamp: 1)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertFalse(container.keyboardButton.isHidden)
        container.hardwarePresenceChanged(true)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
        XCTAssertTrue(diagnostics.contains { $0.contains("[KEYBOARD_AUTHORITY]") && $0.contains("gc_keyboard_present=") && $0.contains("software_first_responder=") })
        container.hardwarePresenceChanged(false)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareTextView.deliveryEnabled)
    }
    func testLocalPositionSurvivesHostPriorityAndNewGenerationStartsCentered() {
        var state = ClientCursorState()
        state.configure(ownership: nil, generation: 1)
        XCTAssertFalse(state.visible)
        state.update(CGPoint(x: 0.2, y: 0.8))
        state.configure(ownership: .hostActive, generation: 1)
        XCTAssertFalse(state.visible)
        XCTAssertEqual(state.normalizedPosition, CGPoint(x: 0.2, y: 0.8))
        state.update(CGPoint(x: 0.7, y: 0.1))
        state.configure(ownership: .clientActive, generation: 1)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.normalizedPosition, CGPoint(x: 0.7, y: 0.1))
        state.configure(ownership: nil, generation: 2)
        XCTAssertFalse(state.visible)
        XCTAssertEqual(state.normalizedPosition, CGPoint(x: 0.5, y: 0.5))
    }
    @MainActor func testCursorOwnershipAndTouchNeverCreateLocalCursorOverlay() {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        container.touchView.frame = container.bounds
        container.touchView.contentViewport = VideoContentViewport(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        container.touchView.configureDirectTouch(active: true, generation: 1)
        var packets: [DirectTouchContactCommand] = []
        container.touchView.onDirectTouchContact = { packets.append($0) }
        container.touchView.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 200, y: 150), 255)])
        container.configureClientCursor(ownership: .clientActive, generation: 1, active: true)
        XCTAssertFalse(container.subviews.contains { $0.accessibilityIdentifier == "client-local-cursor" })
        container.touchView.emitDirectOutputs([.directTouch(.update, 1, CGPoint(x: 210, y: 160), 255)])
        container.configureClientCursor(ownership: .hostActive, generation: 1, active: true)
        XCTAssertFalse(container.subviews.contains { $0.accessibilityIdentifier == "client-local-cursor" })
        XCTAssertEqual(packets.map(\.phase), [.down, .update])
        container.configureClientCursor(ownership: .clientActive, generation: 1, active: true)
        XCTAssertFalse(container.subviews.contains { $0.accessibilityIdentifier == "client-local-cursor" })
        XCTAssertEqual(packets.map(\.phase), [.down, .update])
        container.touchView.emitDirectOutputs([.directTouch(.up, 1, CGPoint(x: 200, y: 150), 255)])
        XCTAssertEqual(packets.map(\.phase), [.down, .update, .up])
    }
    @MainActor func testLetterboxRejectsDownAndTerminalUsesLastValidPoint() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        view.configureDirectTouch(active: true, generation: 1)
        var packets: [DirectTouchContactCommand] = []
        view.onDirectTouchContact = { packets.append($0) }
        view.emitDirectOutputs([.directTouch(.down, 1, .zero, 255), .directTouch(.up, 1, .zero, 255)])
        XCTAssertTrue(packets.isEmpty)
        view.emitDirectOutputs([.directTouch(.down, 2, CGPoint(x: 200, y: 150), 255),
            .directTouch(.update, 2, .zero, 255), .directTouch(.up, 2, .zero, 255)])
        XCTAssertEqual(packets.map(\.phase), [.down, .up])
        XCTAssertEqual(packets.first?.x, packets.last?.x)
        XCTAssertEqual(packets.first?.y, packets.last?.y)
    }
    @MainActor func testGenerationReplacementCancelsOnceAndNeverRevivesOldContact() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.configureDirectTouch(active: true, generation: 1)
        var packets: [DirectTouchContactCommand] = []
        view.onDirectTouchContact = { packets.append($0) }
        view.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 100, y: 100), 255)])
        view.configureDirectTouch(active: true, generation: 2)
        view.emitDirectOutputs([.directTouch(.update, 1, .zero, 255), .directTouch(.up, 1, .zero, 255)])
        XCTAssertEqual(packets.map(\.phase), [.down, .cancel])
        view.emitDirectOutputs([.directTouch(.down, 2, CGPoint(x: 100, y: 100), 255), .directTouch(.up, 2, CGPoint(x: 100, y: 100), 255)])
        XCTAssertEqual(packets.map(\.phase), [.down, .cancel, .down, .up])
    }
    func testFourthFingerAfterCommitTerminatesOnce() {
        var machine = DirectTouchGestureStateMachine()
        machine.begin(id: 1, point: .zero, timestamp: 0)
        machine.move(id: 1, point: CGPoint(x: 0, y: 13), timestamp: 1.1)
        machine.begin(id: 2, point: .zero, timestamp: 1.12)
        machine.begin(id: 3, point: .zero, timestamp: 1.13)
        let cancel = machine.begin(id: 4, point: .zero, timestamp: 1.14)
        XCTAssertEqual(cancel, [.directTouch(.cancel, 1, CGPoint(x: 0, y: 13), 255)])
        for id in UInt64(1)...4 {
            XCTAssertTrue(machine.end(id: id, point: .zero, timestamp: 1.2).isEmpty)
        }
    }
}
