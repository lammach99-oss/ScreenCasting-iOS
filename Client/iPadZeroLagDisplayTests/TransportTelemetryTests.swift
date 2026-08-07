import XCTest
@testable import iPadCasting

final class TransportTelemetryTests: XCTestCase {
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
}
