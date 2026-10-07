import XCTest
@testable import iPadCasting

final class TransportTelemetryTests: XCTestCase {
    func testFreshRateWindowCountsUniqueFramesWithoutDisplayRepeats() throws {
        var window = FreshFrameRateWindow()
        window.begin(generation: 7, at: 10)
        for sequence in UInt32(1)...120 {
            window.recordDecode(sequence: sequence, generation: 7)
            if sequence <= 80 {
                window.recordPresentation(sequence: sequence, generation: 7)
                window.recordPresentation(sequence: sequence, generation: 7)
            }
        }
        XCTAssertNil(window.sample(generation: 7, at: 10.9))
        let sample = try XCTUnwrap(window.sample(generation: 7, at: 11))
        XCTAssertEqual(sample.decodedFps, 120)
        XCTAssertEqual(sample.freshPresentedFps, 80)
        XCTAssertNil(window.sample(generation: 7, at: 11))
        window.begin(generation: 8, at: 12)
        window.recordDecode(sequence: 121, generation: 7)
        window.recordPresentation(sequence: 121, generation: 7)
        let reset = try XCTUnwrap(window.sample(generation: 8, at: 13))
        XCTAssertEqual(reset.decodedFps, 0)
        XCTAssertEqual(reset.freshPresentedFps, 0)
    }

    func testFreshRateWindowHealthyWrapAndDropsAreBounded() throws {
        var window = FreshFrameRateWindow()
        window.begin(generation: 1, at: 0)
        for i in UInt32(0)..<120 {
            let sequence = UInt32.max &- 60 &+ i
            window.recordDecode(sequence: sequence, generation: 1)
            window.recordPresentation(sequence: sequence, generation: 1)
        }
        window.recordDrop(generation: 2)
        window.recordDrop(generation: 1)
        let sample = try XCTUnwrap(window.sample(generation: 1, at: 1))
        XCTAssertEqual(sample.decodedFps, 120)
        XCTAssertEqual(sample.freshPresentedFps, 120)
        XCTAssertEqual(sample.droppedFrames, 1)
        XCTAssertNil(window.sample(generation: 1, at: .infinity))
    }

    func testPerformanceFeedbackAndCommittedModeAuthority() throws {
        XCTAssertEqual(WireMessageType.clientPerformanceFeedback.rawValue, 39)
        let feedback = ClientPerformanceFeedback(mode: .game, flags: 3,
            generation: 0x0102030405060708, targetFps: 120, decodedFpsX10: 1190,
            freshPresentedFpsX10: 800, windowMs: 1000, droppedFrames: 7)
        let bytes = feedback.encode()
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(bytes[4], 8)
        XCTAssertEqual(ClientPerformanceFeedback.decode(bytes), feedback)
        for offset in [0, 1, 2, 3] {
            var bad = bytes
            bad[offset] = 255
            XCTAssertNil(ClientPerformanceFeedback.decode(bad))
        }
        var mode = CommittedPipelineModeState()
        mode.request(.game)
        XCTAssertNil(mode.active)
        XCTAssertFalse(mode.acknowledge(.office))
        XCTAssertTrue(mode.acknowledge(.game, at: 10))
        XCTAssertEqual(mode.active?.targetFps, 120)
        XCTAssertFalse(mode.readyForFeedback(at: 11.999))
        XCTAssertTrue(mode.readyForFeedback(at: 12))
        mode.request(.office)
        XCTAssertNil(mode.active)
        XCTAssertFalse(mode.acknowledge(.game))
        XCTAssertTrue(mode.acknowledge(.office))
        XCTAssertEqual(mode.active?.targetFps, 60)
        mode.reset()
        XCTAssertNil(mode.active)
    }

    func testGameRepeatsNeverInvokeFreshDrawableCallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/Renderer.swift"), encoding: .utf8)
        XCTAssertTrue(source.replacingOccurrences(of: "\r\n", with: "\n")
            .contains("if drawKind != .gameRepeated {\n            onDrawableCommitted?"))
    }

    func testDeleteStoredLogsRemovesOnlyManagedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = [
            "ScreenCasting-Telemetry-old.csv",
            "ScreenCasting-Frame-Telemetry-old.csv",
            "ScreenCasting-Diagnostics-old.log"
        ]
        let unrelated = ["unrelated.csv", "notes.log", "some-document.txt"]
        for name in managed + unrelated {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }

        let telemetry = TransportTelemetry()
        let deleted = expectation(description: "managed logs deleted")
        telemetry.deleteStoredLogs(directoryURL: directory) { result in
            XCTAssertEqual(try? result.get(), 3)
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 2)

        for name in managed {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path))
        }
        for name in unrelated {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path))
        }
    }

    func testDeleteStoredLogsProtectsActiveTripletAndLoggingContinues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = TransportTelemetry()
        let started = expectation(description: "logging started")
        _ = telemetry.startLogging(directoryURL: directory) { url in
            XCTAssertNotNil(url)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        for name in [
            "ScreenCasting-Telemetry-old.csv",
            "ScreenCasting-Frame-Telemetry-old.csv",
            "ScreenCasting-Diagnostics-old.log"
        ] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }

        let deleted = expectation(description: "old logs deleted")
        telemetry.deleteStoredLogs(directoryURL: directory) { result in
            XCTAssertEqual(try? result.get(), 3)
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 2)
        let activeFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(activeFiles.count, 3)
        let diagnosticURL = try XCTUnwrap(activeFiles.first {
            $0.lastPathComponent.hasPrefix("ScreenCasting-Diagnostics-")
        })

        telemetry.recordDiagnosticLine("after-delete")
        let stopped = expectation(description: "active logging stopped")
        telemetry.stopLogging { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertTrue(
            try String(contentsOf: diagnosticURL, encoding: .utf8)
                .contains("after-delete"))
    }

    func testDeleteStoredLogsRemovesCompletedLoggingSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = TransportTelemetry()
        let started = expectation(description: "logging started")
        _ = telemetry.startLogging(directoryURL: directory) { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let stopped = expectation(description: "logging stopped")
        telemetry.stopLogging { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)

        let deleted = expectation(description: "completed logs deleted")
        telemetry.deleteStoredLogs(directoryURL: directory) { result in
            XCTAssertEqual(try? result.get(), 3)
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [])
    }

    func testDeleteStoredLogsPreservesRuntimeTelemetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent(
            "ScreenCasting-Telemetry-old.csv"))
        let telemetry = TransportTelemetry()
        telemetry.recordPayloadReceived(sequence: 9, receiveDurationMs: 4)
        telemetry.recordDecodeCallback(
            sequence: 9,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 6)
        telemetry.recordRtt(durationMs: 8)

        let deleted = expectation(description: "stored logs deleted")
        telemetry.deleteStoredLogs(directoryURL: directory) { result in
            XCTAssertEqual(try? result.get(), 1)
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 2)

        XCTAssertEqual(telemetry.makeFeedback().2, 8)
        XCTAssertEqual(telemetry.hudSnapshot().frameReceiveMs, 4)
        XCTAssertEqual(telemetry.hudSnapshot().decodeMs, 6)
        XCTAssertNotEqual(
            telemetry.feedbackValidityFlags() &
                VideoFeedbackValidityFlags.frameReceive,
            0)
    }

    func testRuntimeTelemetryRemainsActiveWithoutPersistentLogging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = TransportTelemetry()

        telemetry.recordPayloadReceived(sequence: 11, receiveDurationMs: 4)
        telemetry.recordDecodeCallback(
            sequence: 11,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 6)
        telemetry.recordRtt(durationMs: 8)
        telemetry.recordDiagnosticLine("logging-disabled")
        let drained = expectation(description: "disabled sink drained")
        telemetry.stopLogging { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        let feedback = telemetry.makeFeedback()
        XCTAssertEqual(feedback.2, 8)
        XCTAssertNotEqual(
            telemetry.feedbackValidityFlags() &
                VideoFeedbackValidityFlags.frameReceive,
            0)
        XCTAssertNotEqual(
            telemetry.feedbackValidityFlags() & VideoFeedbackValidityFlags.decode,
            0)
        XCTAssertEqual(telemetry.hudSnapshot().frameReceiveMs, 4)
        XCTAssertEqual(telemetry.hudSnapshot().decodeMs, 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPersistentLoggingStartIsIdempotentAndStopPreservesRuntimeState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = TransportTelemetry()
        telemetry.recordPayloadReceived(sequence: 41, receiveDurationMs: 3)

        var firstURL: URL?
        let firstStarted = expectation(description: "first logging start")
        _ = telemetry.startLogging(directoryURL: directory) { url in
            firstURL = url
            firstStarted.fulfill()
        }
        wait(for: [firstStarted], timeout: 2)

        var secondURL: URL?
        let secondStarted = expectation(description: "idempotent logging start")
        _ = telemetry.startLogging(directoryURL: directory) { url in
            secondURL = url
            secondStarted.fulfill()
        }
        wait(for: [secondStarted], timeout: 2)
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            3)

        telemetry.recordDiagnosticLine("before-disable")
        let stopped = expectation(description: "logging stopped")
        telemetry.stopLogging { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        let diagnosticURL = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ScreenCasting-Diagnostics-") })
        let sizeAfterStop = try Data(contentsOf: diagnosticURL).count

        telemetry.recordDiagnosticLine("after-disable")
        let stoppedAgain = expectation(description: "logging stop is idempotent")
        telemetry.stopLogging { stoppedAgain.fulfill() }
        wait(for: [stoppedAgain], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: diagnosticURL).count, sizeAfterStop)
        XCTAssertEqual(telemetry.hudSnapshot().frameReceiveMs, 3)
    }

    func testWifiCompletedFrameRecordsOneReceiveSample() {
        let telemetry = TransportTelemetry()
        telemetry.recordWifiPacket(
            sequence: 7, marker: false, isIDR: false, bytes: 600,
            arrivalTime: 1.000, generation: 3)
        telemetry.recordWifiPacket(
            sequence: 7, marker: true, isIDR: false, bytes: 400,
            arrivalTime: 1.004, generation: 3)
        telemetry.recordWifiReassembly(
            outcome: .completed(
                accessUnit: Data([1]), frameSequence: 7, captureTime90k: 1),
            observedAt: 1.005,
            generation: 3)

        let counts = telemetry.summaryCountsForTesting()
        XCTAssertEqual(counts.receive, 1)
        XCTAssertEqual(telemetry.frameReceivePercentilesMs().p50, 4)
    }

    func testWifiExpiredFrameDoesNotRecordSuccessfulReceive() {
        let telemetry = TransportTelemetry()
        telemetry.recordWifiPacket(
            sequence: 8, marker: false, isIDR: false, bytes: 600,
            arrivalTime: 2.000, generation: 3)
        telemetry.recordWifiPacket(
            sequence: 8, marker: true, isIDR: false, bytes: 400,
            arrivalTime: 2.006, generation: 3)
        telemetry.recordWifiReassembly(
            outcome: .expired(frameSequence: 8),
            observedAt: 2.040,
            generation: 3)

        XCTAssertEqual(telemetry.summaryCountsForTesting().receive, 0)
    }

    func testWifiAuthenticatedFeedbackRttReachesTelemetryOnce() {
        let telemetry = TransportTelemetry()
        let queue = DispatchQueue(label: "test.wifi.rtt.telemetry")
        let receiver = WifiMediaReceiver(
            networkQueue: queue,
            decoder: { _, _, _, _ in },
            audioConsumer: { _, _, _, _ in },
            onProbeAuthenticated: { _, _ in },
            onCommittedFailure: { _, _ in },
            rttObserver: { telemetry.recordRtt(durationMs: $0) })

        queue.sync {
            receiver.recordAcceptedRttSampleForTesting(milliseconds: 5)
        }

        XCTAssertEqual(telemetry.summaryCountsForTesting().rtt, 1)
        XCTAssertEqual(telemetry.makeFeedback().2, 5)
    }

    func testWifiSecurityDropSnapshotIsOperationallyVisible() {
        let telemetry = TransportTelemetry()
        var counters = WifiSecurityDropCounters()
        counters.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_543))
        counters.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_542))
        counters.recordWrongEndpoint()
        telemetry.recordWifiSecurityDrops(counters)

        XCTAssertEqual(
            telemetry.wifiSecurityDropSnapshot(),
            TransportTelemetry.SecurityDropSnapshot(
                authentication: 1,
                replay: 1,
                wrongEndpoint: 1))
    }

    func testWireSequenceIdentitySurvivesDecodeAndPresentation() {
        let telemetry = TransportTelemetry()
        telemetry.recordPayloadReceived(sequence: 41, receiveDurationMs: 1)
        telemetry.recordDecodeCallback(
            sequence: 41,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 2)
        telemetry.recordRenderCompletion(sequence: 41, generation: 0)
        let feedback = telemetry.makeFeedback()
        XCTAssertEqual(feedback.0, 41)
        XCTAssertEqual(feedback.1, 41)
    }

    func testDroppedSequenceReleasesPendingState() {
        let telemetry = TransportTelemetry()
        telemetry.recordPayloadReceived(sequence: 7, receiveDurationMs: 1)
        telemetry.recordDropped(sequence: 7)
        telemetry.recordPayloadReceived(sequence: 8, receiveDurationMs: 1)
        telemetry.recordDecodeCallback(
            sequence: 8,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 1)
        XCTAssertEqual(telemetry.makeFeedback().1, 8)
    }

    func testDroppedFrameExportsOneTerminalSequenceRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let telemetry = TransportTelemetry()
        let started = expectation(description: "dropped-frame export started")
        _ = try XCTUnwrap(telemetry.startLogging(
            directoryURL: directory,
            completion: { url in
                XCTAssertNotNil(url)
                started.fulfill()
            }))
        wait(for: [started], timeout: 2)
        telemetry.recordPayloadReceived(
            sequence: 12,
            receiveDurationMs: 1,
            receivedAt: 100,
            payloadBytes: 123,
            isIDR: true,
            generation: 4,
            transportKind: StreamingTransportKind.wifi.rawValue)
        telemetry.recordDropped(sequence: 12, generation: 4, observedAt: 101)
        telemetry.recordRenderDrop(sequence: 12, generation: 4)
        let finished = expectation(description: "dropped frame export finished")
        telemetry.stopLogging { finished.fulfill() }
        wait(for: [finished], timeout: 2)

        let frameURL = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ScreenCasting-Frame-Telemetry-") })
        let rows = try String(contentsOf: frameURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        let fields = rows[1].split(
            separator: ",",
            omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, SequenceLatencyReporter.csvHeader.count)
        XCTAssertEqual(fields[0], "4")
        XCTAssertEqual(fields[1], "\"wifi\"")
        XCTAssertEqual(fields[2], "12")
        XCTAssertEqual(fields[3], "true")
        XCTAssertEqual(fields[6], "123")
        XCTAssertEqual(fields[7], "0")
        XCTAssertEqual(fields[9], "\"legacy_tls\"")
        let droppedIndex = try XCTUnwrap(
            SequenceLatencyReporter.csvHeader.firstIndex(
                of: "dropped_local_ms"))
        XCTAssertEqual(fields[droppedIndex], "101000.000")
    }

    func testMailboxAgeAndDropsAreReportedOncePerFeedback() {
        let telemetry = TransportTelemetry()
        telemetry.recordPayloadReceived(
            sequence: 9,
            receiveDurationMs: 1,
            receivedAt: 100)
        telemetry.recordMailboxAge(sequence: 9, ageMs: 7)
        telemetry.recordDropped(sequence: 9)

        let first = telemetry.makeFeedback()
        let second = telemetry.makeFeedback()
        XCTAssertEqual(first.4, 7)
        XCTAssertEqual(first.5, 1)
        XCTAssertEqual(second.5, 0)
    }

    func testFrameReceivePercentilesRemainSeparateFromDecode() {
        let telemetry = TransportTelemetry()
        for (index, duration) in [1.0, 2.0, 3.0, 4.0, 20.0].enumerated() {
            telemetry.recordPayloadReceived(
                sequence: UInt32(index), receiveDurationMs: duration)
        }
        telemetry.recordDecodeCallback(
            sequence: 0,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 2)

        let receive = telemetry.frameReceivePercentilesMs()
        let stages = telemetry.frameStageP95Ms()
        XCTAssertEqual(receive.p50, 3)
        XCTAssertEqual(receive.p95, 20)
        XCTAssertEqual(receive.p99, 20)
        XCTAssertEqual(stages.receive, 20)
        XCTAssertEqual(stages.decode, 2)
    }

    func testValidityFlagsDistinguishMissingStagesFromZeroValues() {
        let telemetry = TransportTelemetry()
        XCTAssertEqual(telemetry.feedbackValidityFlags(), 0)
        telemetry.recordPayloadReceived(sequence: 1, receiveDurationMs: 0)
        let flags = telemetry.feedbackValidityFlags()
        XCTAssertNotEqual(flags & VideoFeedbackValidityFlags.frameReceive, 0)
        XCTAssertEqual(flags & VideoFeedbackValidityFlags.decode, 0)
        XCTAssertEqual(flags & VideoFeedbackValidityFlags.queue, 0)
    }

    func testMeasuredRttIsIncludedInVideoFeedback() {
        let telemetry = TransportTelemetry()
        telemetry.recordRtt(durationMs: 2)
        telemetry.recordRtt(durationMs: 9)
        XCTAssertEqual(telemetry.makeFeedback().2, 9)
    }

    func testUsbQualificationRequiresNonceMatchedRttByTenSeconds() {
        let telemetry = TransportTelemetry()
        telemetry.beginAuthenticatedGeneration(
            transportKind: .usbTypeC,
            connectionGeneration: 7,
            authenticatedAt: 100)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 7,
                now: 109.9),
            .pending)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 7,
                now: 110),
            .rejectedMissingNonceMatchedRtt)
        telemetry.recordAuthenticatedRtt(
            durationMs: 2,
            transportKind: .usbTypeC,
            connectionGeneration: 7,
            observedAt: 105)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 7,
                now: 110),
            .qualified)
    }

    func testUsbQualificationRejectsPreAuthStaleAndWifiRttSamples() {
        let telemetry = TransportTelemetry()
        telemetry.recordRtt(durationMs: 1)
        telemetry.beginAuthenticatedGeneration(
            transportKind: .usbTypeC,
            connectionGeneration: 9,
            authenticatedAt: 200)
        telemetry.recordAuthenticatedRtt(
            durationMs: 2,
            transportKind: .usbTypeC,
            connectionGeneration: 8,
            observedAt: 201)
        telemetry.recordAuthenticatedRtt(
            durationMs: 3,
            transportKind: .wifi,
            connectionGeneration: 9,
            observedAt: 202)
        telemetry.recordAuthenticatedRtt(
            durationMs: 4,
            transportKind: .usbTypeC,
            connectionGeneration: 9,
            observedAt: 211)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 9,
                now: 210),
            .rejectedMissingNonceMatchedRtt)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 8,
                now: 205),
            .notAuthenticatedUsbGeneration)

        telemetry.beginAuthenticatedGeneration(
            transportKind: .wifi,
            connectionGeneration: 10,
            authenticatedAt: 300)
        telemetry.recordAuthenticatedRtt(
            durationMs: 1,
            transportKind: .wifi,
            connectionGeneration: 10,
            observedAt: 301)
        XCTAssertEqual(
            telemetry.usbQualificationRttState(
                connectionGeneration: 10,
                now: 310),
            .notAuthenticatedUsbGeneration)
    }

    func testCsvLoggerWritesIntervalsAndCumulativeFinalRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let telemetry = TransportTelemetry()
        telemetry.setSessionContext(TransportTelemetryContext(
            transportKind: .usbTypeC,
            transportBackend: "iproxy,\"edge\"",
            connectionGeneration: 7,
            udidSha256_12: "ABCDEF123456",
            tunnelStartMs: 12,
            tlsMs: 8,
            authMs: 4,
            reconnectMs: 0,
            helperExitCode: nil,
            helperRestartCount: 1))
        let started = expectation(description: "telemetry export started")
        let url = try XCTUnwrap(telemetry.startLogging(
            directoryURL: directory,
            completion: { actualURL in
                XCTAssertNotNil(actualURL)
                started.fulfill()
            }))
        wait(for: [started], timeout: 2)
        telemetry.recordBitrateMbps(18)
        telemetry.recordRtt(durationMs: 1)
        telemetry.recordRtt(durationMs: 2)
        telemetry.recordRtt(durationMs: 20)
        telemetry.recordPayloadReceived(sequence: 1, receiveDurationMs: 3)
        telemetry.recordDecodeCallback(
            sequence: 1,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 4)
        telemetry.recordRenderCompletion(sequence: 1, generation: 0)
        telemetry.recordDropped(sequence: 2)
        var securityDrops = WifiSecurityDropCounters()
        securityDrops.recordCryptoFailure(
            RealtimeCryptoError.nativeFailure(-2_147_180_543))
        securityDrops.recordWrongEndpoint()
        telemetry.recordWifiSecurityDrops(securityDrops)
        telemetry.flushIntervalSummary()
        telemetry.recordRtt(durationMs: 100)
        telemetry.recordPayloadReceived(sequence: 3, receiveDurationMs: 30)
        telemetry.recordDecodeCallback(
            sequence: 3,
            generation: 0,
            decodeStartedAt: ProcessInfo.processInfo.systemUptime,
            durationMs: 40)
        telemetry.recordRenderCompletion(sequence: 3, generation: 0)
        let finished = expectation(description: "telemetry export finished")
        telemetry.stopLogging { finished.fulfill() }
        wait(for: [finished], timeout: 2)

        let csv = try String(contentsOf: url, encoding: .utf8)
        let rows = csv.split(separator: "\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].contains("rtt_p50_ms"))
        XCTAssertTrue(rows[0].contains("presentation_p99_ms"))
        XCTAssertTrue(rows[0].contains("connection_generation"))
        XCTAssertTrue(rows[0].contains("wifi_srtp_replay_drops"))
        XCTAssertTrue(rows[1].contains(",periodic,"))
        XCTAssertTrue(rows[2].contains(",final_cumulative,"))
        XCTAssertTrue(rows[2].contains(",\"usb_type_c\",\"iproxy,\"\"edge\"\"\",7,\"ABCDEF123456\",12.000,8.000,4.000,0.000,,1,"))
        XCTAssertTrue(rows[2].hasSuffix(",1,1,18.000,1,0,1"))
        XCTAssertTrue(rows[2].contains(",4,2.000,100.000,100.000,"))
        XCTAssertTrue(rows[2].contains(",2,3.000,30.000,30.000,"))
    }

    func testDiagnosticMarkersAreWrittenWithoutChangingTelemetryCsv() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let telemetry = TransportTelemetry()
        let started = expectation(description: "diagnostic export started")
        let telemetryURL = try XCTUnwrap(telemetry.startLogging(
            directoryURL: directory,
            completion: { actualURL in
                XCTAssertNotNil(actualURL)
                started.fulfill()
            }))
        wait(for: [started], timeout: 2)

        telemetry.recordDiagnosticLine(
            "[VIDEO_QUALITY] stage=cv_pixel_buffer generation=3 sequence=5")
        telemetry.recordDiagnosticLine(
            "[INPUT_GEOMETRY] event=down sessionGeneration=3")

        let finished = expectation(description: "diagnostic export finished")
        telemetry.stopLogging { finished.fulfill() }
        wait(for: [finished], timeout: 2)

        let diagnosticURL = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ScreenCasting-Diagnostics-") })
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("[VIDEO_QUALITY]"))
        XCTAssertTrue(diagnostics.contains("[INPUT_GEOMETRY]"))

        let telemetryCsv = try String(contentsOf: telemetryURL, encoding: .utf8)
        XCTAssertFalse(telemetryCsv.contains("[VIDEO_QUALITY]"))
        XCTAssertFalse(telemetryCsv.contains("[INPUT_GEOMETRY]"))
    }
}
