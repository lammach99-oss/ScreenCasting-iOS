import XCTest
import Foundation
import Network
import AVFoundation
@testable import iPadCasting

#if targetEnvironment(simulator) && C1_LIFETIME_DIAGNOSTICS
// Diagnostic tests only. The entire neutral section is identical in N0 and N1.
private final class C1CompletionLedger {
    private let lock = NSLock()
    private var registered = 0
    private var invoked = 0
    private var pending: Set<Int> = []
    private var duplicate = 0
    private var afterTeardown = 0
    private var closed = false
    private var saved: [() -> Void] = []
    func register(_ body: @escaping () -> Void, retain: Bool = true) -> () -> Void {
        lock.lock(); registered += 1; let id = registered; pending.insert(id); lock.unlock()
        let callback: () -> Void = { [self] in
            lock.lock()
            let late = closed
            if late { afterTeardown += 1 }
            let first = pending.remove(id) != nil
            if first { invoked += 1 } else { duplicate += 1 }
            lock.unlock()
            if late || !first { print("[C1_CALLBACK_FAULT] late=\(late) duplicate=\(!first)") }
            if first && !late { body() }
        }
        if retain { lock.lock(); saved.append(callback); lock.unlock() }
        return callback
    }
    func take() -> [() -> Void] {
        lock.lock(); defer { lock.unlock() }
        let result = saved; saved.removeAll(); return result
    }
    var counts: (registered: Int, invoked: Int, pending: Int, duplicate: Int, late: Int) {
        lock.lock(); defer { lock.unlock() }
        return (registered, invoked, pending.count, duplicate, afterTeardown)
    }
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock(); closed = true; saved.removeAll(); lock.unlock()
        let c = counts
        print("[C1_LIFETIME] registered=\(c.registered) invoked=\(c.invoked) pending=\(c.pending) duplicate=\(c.duplicate) afterTeardown=\(c.late)")
        XCTAssertEqual(c.registered, c.invoked, file: file, line: line)
        XCTAssertEqual(c.pending, 0, file: file, line: line)
        XCTAssertEqual(c.duplicate, 0, file: file, line: line)
        XCTAssertEqual(c.late, 0, file: file, line: line)
    }
}

final class C1NeutralLifetimeTests: XCTestCase {
    private let pcm = Data(repeating: 0, count: 1920)
    private func install(_ ledger: C1CompletionLedger, _ audio: AudioManager) {
        audio.audioQueueForTesting.sync {
            audio.engineStartForTesting = { }
            audio.pcmScheduleForTesting = { _, completion in _ = ledger.register(completion) }
        }
        print("[C1_PATH] TEST_SEAM_ONLY")
    }
    private func retire(_ ledger: C1CompletionLedger, _ audio: AudioManager) {
        audio.reset(); audio.audioQueueForTesting.sync { }
        ledger.take().forEach { $0() }
        audio.audioQueueForTesting.sync {
            audio.engineStartForTesting = nil; audio.pcmScheduleForTesting = nil
        }
        ledger.finish()
    }
    func testPinnedRuntimeAndDiagnosticEnvironment() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let mode = ProcessInfo.processInfo.environment["C1_DIAGNOSTIC_MODE"]
        print("[C1_RUNTIME] os=\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) mode=\(mode ?? "missing")")
        XCTAssertEqual(version.majorVersion, 18); XCTAssertEqual(version.minorVersion, 5)
        XCTAssertTrue(["unsanitized", "asan", "malloc-scribble"].contains(mode ?? ""))
        if mode == "malloc-scribble" { XCTAssertEqual(ProcessInfo.processInfo.environment["MallocScribble"], "1") }
    }
    func test300PcmBuffersCompleteExactlyOnce() throws {
        let audio = AudioManager.makeForTesting(), ledger = C1CompletionLedger()
        install(ledger, audio); defer { retire(ledger, audio) }
        audio.beginLegacySession(generation: 70)
        for _ in 0..<300 {
            audio.playPCMData(pcm, generation: 70); audio.audioQueueForTesting.sync { }
            let callbacks = ledger.take()
            XCTAssertEqual(callbacks.count, 1); try XCTUnwrap(callbacks.first)()
            audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.queued, 0)
        }
        XCTAssertEqual(ledger.counts.registered, 300)
        XCTAssertEqual(audio.playbackStateForTesting.completions, 300)
    }
    func testResetPending1_8_20_100CannotMutateReplacement() {
        let audio = AudioManager.makeForTesting(), ledger = C1CompletionLedger()
        install(ledger, audio); defer { retire(ledger, audio) }
        for count in [1, 8, 20, 100] {
            let generation = UInt64(1000 + count)
            audio.beginLegacySession(generation: generation)
            // 48-frame packets keep even 100 pending below the unchanged 9600-frame bound.
            for _ in 0..<count { audio.playPCMData(Data(repeating: 0, count: 192), generation: generation) }
            audio.audioQueueForTesting.sync { }
            let stale = ledger.take(); XCTAssertEqual(stale.count, count)
            audio.reset(); audio.beginLegacySession(generation: generation + 1)
            audio.playPCMData(pcm, generation: generation + 1); audio.audioQueueForTesting.sync { }
            let before = audio.playbackStateForTesting
            stale.forEach { $0() }; audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.epoch, before.epoch)
            XCTAssertEqual(audio.playbackStateForTesting.generation, generation + 1)
            XCTAssertEqual(audio.playbackStateForTesting.queued, 480)
            XCTAssertEqual(audio.playbackStateForTesting.completions, before.completions)
            ledger.take().forEach { $0() }; audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.queued, 0)
        }
    }
    func test100SingletonLegacyReplacementsFenceStaleCallbacks() {
        let audio = AudioManager.shared, ledger = C1CompletionLedger()
        audio.reset(); audio.audioQueueForTesting.sync { }
        install(ledger, audio); defer { retire(ledger, audio) }
        var stale: [() -> Void] = []
        for generation in UInt64(2000)..<2100 {
            audio.reset(); audio.beginLegacySession(generation: generation)
            for _ in 0..<3 { audio.playPCMData(pcm, generation: generation) }
            audio.audioQueueForTesting.sync { }
            stale.forEach { $0() }; audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.queued, 1440)
            let current = ledger.take(); XCTAssertEqual(current.count, 3)
            current.prefix(2).forEach { $0() }; stale = Array(current.suffix(1))
            audio.audioQueueForTesting.sync { }
            XCTAssertEqual(audio.playbackStateForTesting.queued, 480)
        }
        audio.reset(); audio.audioQueueForTesting.sync { }
        stale.forEach { $0() }; audio.audioQueueForTesting.sync { }
        XCTAssertEqual(audio.playbackStateForTesting.queued, 0)
        XCTAssertEqual(ledger.counts.registered, 300)
    }
    func test100AudioObserverAndEngineResetFixtureLifetimes() throws {
        for generation in UInt64(3000)..<3100 {
            weak var observerOwner: AudioManager?
            try autoreleasepool {
                let audio = AudioManager.makeForTesting(), ledger = C1CompletionLedger()
                observerOwner = audio; install(ledger, audio)
                audio.beginLegacySession(generation: generation)
                audio.playPCMData(pcm, generation: generation); audio.audioQueueForTesting.sync { }
                XCTAssertEqual(ledger.counts.registered, 1)
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.engineForTesting)
                audio.audioQueueForTesting.sync { }
                retire(ledger, audio)
            }
            XCTAssertNil(observerOwner)
        }
    }
    func testListenerStopSavedAcceptAndCallbackQuiescence() throws {
        print("[C1_PATH] NETWORK_FRAMEWORK_NATIVE")
        for _ in 0..<20 {
            weak var owner: NetworkManager?
            try autoreleasepool {
                let manager = NetworkManager(); owner = manager
                manager.startListening(port: 0)
                let listener = try XCTUnwrap(manager.usbSessionSnapshot().listener)
                let accept = try XCTUnwrap(listener.newConnectionHandler)
                let cancelled = expectation(description: "listener terminal callback")
                let ledger = C1CompletionLedger()
                let benign = ledger.register({ }, retain: false)
                manager.networkQueueForTesting.sync {
                    let original = listener.stateUpdateHandler
                    var terminalSeen = false
                    listener.stateUpdateHandler = { state in
                        original?(state)
                        if state == .cancelled, !terminalSeen { terminalSeen = true; cancelled.fulfill() }
                    }
                }
                manager.networkQueueForTesting.async { benign() }
                manager.stopForTesting()
                wait(for: [cancelled], timeout: 10)
                let latePeer = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
                manager.networkQueueForTesting.sync { accept(latePeer); listener.stateUpdateHandler = nil }
                latePeer.cancel(); manager.networkQueueForTesting.sync { }
                let stopped = manager.usbSessionSnapshot()
                XCTAssertNil(stopped.listener); XCTAssertNil(stopped.connection); XCTAssertFalse(stopped.listenerIntent)
                manager.decoderForTesting.sessionQueueForTesting.sync { }
                AudioManager.shared.audioQueueForTesting.sync { }
                ledger.finish()
                let drained = expectation(description: "main publications drained")
                DispatchQueue.main.async { drained.fulfill() }; wait(for: [drained], timeout: 10)
            }
            XCTAssertNil(owner)
        }
    }
    func testOrdinaryPingWriterCompletionAndRetiredLateSend() throws {
        // Shared production writer, not C1 pending-Ping-purpose/fresh-fence state.
        print("[C1_PATH] CONTROL_WRITER_PING_TEST_SEAM_ONLY")
        let manager = NetworkManager(), ledger = C1CompletionLedger()
        let queue = manager.networkQueueForTesting
        var transportCompletion: (() -> Void)?; var delivered = 0
        let writer = ControlChannelWriter(queue: queue) { data, _, completion in
            XCTAssertEqual(data.count, 32); XCTAssertEqual(data[5], WireMessageType.ping.rawValue)
            transportCompletion = ledger.register({ completion(nil) }, retain: false)
        }
        var ping = Data(repeating: 0, count: 32)
        ping.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: WireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: WireProtocol.version, toByteOffset: 4, as: UInt8.self)
            bytes.storeBytes(of: WireMessageType.ping.rawValue, toByteOffset: 5, as: UInt8.self)
            bytes.storeBytes(of: UInt32(16).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        queue.sync { writer.begin(generation: 1); writer.enqueue(ping) { _ in delivered += 1 } }
        try XCTUnwrap(transportCompletion)(); queue.sync { }; XCTAssertEqual(delivered, 1)
        queue.sync { writer.enqueue(ping) { _ in delivered += 1 } }
        let late = try XCTUnwrap(transportCompletion)
        manager.stopForTesting(); queue.sync { writer.abandonConnection() }
        late(); queue.sync { }; XCTAssertEqual(delivered, 1)
        transportCompletion = nil
        manager.decoderForTesting.sessionQueueForTesting.sync { }
        AudioManager.shared.audioQueueForTesting.sync { }
        let mainDrained = expectation(description: "Ping writer main publications drained")
        DispatchQueue.main.async { mainDrained.fulfill() }; wait(for: [mainDrained], timeout: 10)
        ledger.finish()
    }
}

final class C1NativeAVAudioLifetimeTests: XCTestCase {
    func test100NativeDataRenderedManualRenderStopResetCycles() throws {
        print("[C1_PATH] NATIVE_AVAUDIO_PATH manual_rendering=offline")
        let ledger = C1CompletionLedger()
        for _ in 0..<100 {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)); input.frameLength = 480
            let channels = try XCTUnwrap(input.floatChannelData)
            for index in 0..<2 { memset(channels[index], 0, 480 * MemoryLayout<Float>.size) }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 960))
            let rendered = expectation(description: "native dataRendered completion")
            let complete = ledger.register({ }, retain: false)
            player.scheduleBuffer(input, completionCallbackType: .dataRendered) { _ in complete(); rendered.fulfill() }
            try engine.start(); player.play()
            XCTAssertEqual(try engine.renderOffline(960, to: output), .success)
            wait(for: [rendered], timeout: 10)
            player.stop(); player.reset(); engine.stop(); engine.reset(); engine.disableManualRenderingMode()
        }
        ledger.finish(); XCTAssertEqual(ledger.counts.registered, 100)
    }
}

final class C1DecoderLifecycleInstrumentationTests: XCTestCase {
    func testSingleCallerAndAsyncCleanupPreserveLifecycleMeasurements() {
        let decoder = DecoderManager()
        let caller = DispatchQueue(label: "test.c1.lifecycle.caller")
        let finished = expectation(description: "caller completed lifecycle stress")
        let iterations = 1000
        caller.async {
            for generation in 1...iterations {
                decoder.invalidate(waitForCompletion: false)
                decoder.beginSession(generation: UInt64(generation))
            }
            finished.fulfill()
        }
        // Watchdog bounds a hung test; it is not a production latency requirement.
        wait(for: [finished], timeout: 30)
        caller.sync { }
        decoder.sessionQueueForTesting.sync { }
        let events = decoder.lifecycleEventsForTesting
        XCTAssertEqual(decoder.invalidateCountForTesting, iterations)
        XCTAssertEqual(decoder.sessionBeganCountForTesting, iterations)
        XCTAssertEqual(decoder.invalidateWaitModesForTesting, Array(repeating: false, count: iterations))
        XCTAssertEqual(events.count, iterations * 3)
        XCTAssertEqual(events.filter { $0 == "invalidate-begin" }.count, iterations)
        XCTAssertEqual(events.filter { $0 == "invalidate-end" }.count, iterations)
        XCTAssertEqual(events.filter { $0.hasPrefix("begin-") }.count, iterations)
    }
}

#if C1_CANDIDATE_SEMANTICS
private final class C1OneShotPingRecorder {
    private let lock = NSLock()
    private var signal: XCTestExpectation?
    private var payload: Data?
    func arm(_ expectation: XCTestExpectation) { lock.lock(); signal = expectation; payload = nil; lock.unlock() }
    func record(_ data: Data) {
        guard data.count == 32, data[5] == WireMessageType.ping.rawValue else { return }
        lock.lock(); guard let ready = signal else { lock.unlock(); return }
        signal = nil; payload = Data(data.dropFirst(16)); lock.unlock(); ready.fulfill()
    }
    func take() -> Data? { lock.lock(); defer { lock.unlock() }; let value = payload; payload = nil; return value }
    func cancel() { lock.lock(); signal = nil; payload = nil; lock.unlock() }
}

final class C1AlternateSemanticTests: XCTestCase {
    func testAlternateForegroundPcmFenceWithExplicitOwners() async throws {
        print("[C1_PATH] TEST_SEAM_ONLY semantic=S2")
        let domain = "test.c1.s2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let manager = NetworkManager(userDefaults: defaults), audio = AudioManager.shared
        let pcmLedger = C1CompletionLedger(), sends = C1CompletionLedger(), pings = C1OneShotPingRecorder()
        var client: NWConnection?; var server: NWConnection?; var listener: NWListener?
        audio.reset(); audio.audioQueueForTesting.sync { }
        audio.audioQueueForTesting.sync {
            audio.engineStartForTesting = { }
            audio.pcmScheduleForTesting = { _, completion in _ = pcmLedger.register(completion) }
        }
        manager.networkQueueForTesting.sync {
            manager.controlSendForAudioTesting = { data, completion in
                let done = sends.register({ completion(nil) }, retain: false)
                pings.record(data); done()
            }
        }
        func retire() async {
            pings.cancel()
            var terminals: [XCTestExpectation] = []
            manager.networkQueueForTesting.sync {
                if let endpoint = listener {
                    let terminal = expectation(description: "S2 listener terminal")
                    terminals.append(terminal)
                    if endpoint.state == .cancelled { terminal.fulfill() } else {
                        let original = endpoint.stateUpdateHandler
                        var seen = false
                        endpoint.stateUpdateHandler = { state in
                            original?(state)
                            if state == .cancelled, !seen { seen = true; terminal.fulfill() }
                        }
                    }
                }
                for connection in [client, server].compactMap({ $0 }) {
                    let terminal = expectation(description: "S2 connection terminal")
                    terminals.append(terminal)
                    if connection.state == .cancelled { terminal.fulfill() } else {
                        let original = connection.stateUpdateHandler
                        var seen = false
                        connection.stateUpdateHandler = { state in
                            original?(state)
                            if state == .cancelled, !seen { seen = true; terminal.fulfill() }
                        }
                    }
                }
            }
            manager.stopForTesting(); client?.cancel(); server?.cancel()
            if !terminals.isEmpty { await fulfillment(of: terminals, timeout: 10) }
            manager.networkQueueForTesting.sync {
                manager.controlSendForAudioTesting = nil
                client?.stateUpdateHandler = nil; server?.stateUpdateHandler = nil
                listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
            }
            manager.decoderForTesting.sessionQueueForTesting.sync { }
            audio.reset(); audio.audioQueueForTesting.sync { }
            pcmLedger.take().forEach { $0() }
            audio.audioQueueForTesting.sync { audio.engineStartForTesting = nil; audio.pcmScheduleForTesting = nil }
            let mainDrained = expectation(description: "S2 main publications drained")
            DispatchQueue.main.async { mainDrained.fulfill() }; await fulfillment(of: [mainDrained], timeout: 10)
            pcmLedger.finish(); sends.finish(); defaults.removePersistentDomain(forName: domain)
        }
        do {
            manager.startListening(port: 0)
            let endpoint = try XCTUnwrap(manager.usbSessionSnapshot().listener); listener = endpoint
            let ready = expectation(description: "S2 listener ready")
            manager.networkQueueForTesting.sync {
                if endpoint.state == .ready { ready.fulfill() } else {
                    let original = endpoint.stateUpdateHandler
                    endpoint.stateUpdateHandler = { state in
                        original?(state)
                        if state == .ready { endpoint.stateUpdateHandler = original; ready.fulfill() }
                    }
                }
            }
            await fulfillment(of: [ready], timeout: 10)
            let port = try XCTUnwrap(endpoint.port), accepted = expectation(description: "S2 accepted candidate")
            let originalAccept = try XCTUnwrap(endpoint.newConnectionHandler)
            manager.networkQueueForTesting.sync {
                endpoint.newConnectionHandler = { connection in
                    originalAccept(connection); server = connection
                    endpoint.newConnectionHandler = originalAccept
                    let originalState = connection.stateUpdateHandler
                    connection.stateUpdateHandler = { state in
                        originalState?(state)
                        if state == .ready { connection.stateUpdateHandler = originalState; accepted.fulfill() }
                    }
                }
            }
            client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            client?.start(queue: manager.networkQueueForTesting)
            await fulfillment(of: [accepted], timeout: 10)
            let owner = try manager.networkQueueForTesting.sync { try XCTUnwrap(server) }
            let initial = expectation(description: "S2 initial Ping")
            pings.arm(initial); manager.simulateSessionAuthenticatedAndCommitted()
            await fulfillment(of: [initial], timeout: 10)
            let generation = manager.usbSessionSnapshot().generation
            manager.receiveUsbWireForTesting(type: .pong, payload: try XCTUnwrap(pings.take()), generation: generation, connection: owner)
            audio.audioQueueForTesting.sync { }
            manager.applicationDidEnterBackground()
            let resumed = expectation(description: "S2 foreground Ping")
            pings.arm(resumed); manager.applicationDidBecomeActive(); await fulfillment(of: [resumed], timeout: 10)
            let pong = try XCTUnwrap(pings.take())
            for _ in 0..<100 { manager.receiveUsbWireForTesting(type: .audio, payload: Data(repeating: 0, count: 1920), generation: generation, connection: owner) }
            audio.audioQueueForTesting.sync { }
            XCTAssertEqual(pcmLedger.counts.registered, 0); XCTAssertEqual(audio.playbackStateForTesting.queued, 0)
            manager.receiveUsbWireForTesting(type: .pong, payload: pong, generation: generation, connection: owner)
            for _ in 0..<300 {
                manager.receiveUsbWireForTesting(type: .audio, payload: Data(repeating: 0, count: 1920), generation: generation, connection: owner)
                audio.audioQueueForTesting.sync { }
                let callbacks = pcmLedger.take(); XCTAssertEqual(callbacks.count, 1); try XCTUnwrap(callbacks.first)()
                audio.audioQueueForTesting.sync { }
            }
            XCTAssertEqual(pcmLedger.counts.registered, 300); XCTAssertEqual(audio.playbackStateForTesting.queued, 0)
            var diagnostic: String?
            audio.publishDiagnostics(generation: generation, profile: "usb", opus: false, receiveRejects: "") { diagnostic = $0 }
            audio.audioQueueForTesting.sync { }
            XCTAssertTrue(diagnostic?.contains("pcm_reject=0") == true)
            XCTAssertTrue(diagnostic?.contains("pcm_resume_fence_drop=100") == true)
            await retire()
        } catch { await retire(); throw error }
    }
}

private final class C1SequenceObserver: NSObject, XCTestObservation {
    private let lock = NSLock()
    private var started: [String] = []
    func testCaseWillStart(_ testCase: XCTestCase) { lock.lock(); started.append(testCase.name); lock.unlock() }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return started }
}

final class C1OrderedSequenceTests: XCTestCase {
    private func selected(_ type: XCTestCase.Type, _ method: String) throws -> XCTestCase {
        // Obtain XCTest's own invocation, including its async-method adaptation.
        let cases = type.defaultTestSuite.tests.compactMap { $0 as? XCTestCase }.filter { $0.name.contains(method) }
        XCTAssertEqual(cases.count, 1)
        return try XCTUnwrap(cases.first)
    }
    private func runPair(_ type: XCTestCase.Type, _ method: String, wifiFirst: Bool) throws {
        let semantic = try selected(type, method)
        let wifi = try selected(WifiForegroundDecoderRecoveryTests.self, "testReplacementWifiGenerationCannotRearmStaleSession")
        let suite = XCTestSuite(name: "C1 ordered exact fixture pair")
        if wifiFirst { suite.addTest(wifi); suite.addTest(semantic) }
        else { suite.addTest(semantic); suite.addTest(wifi) }
        print("[C1_ORDER] first=\(wifiFirst ? wifi.name : semantic.name) second=\(wifiFirst ? semantic.name : wifi.name)")
        let observer = C1SequenceObserver()
        XCTestObservationCenter.shared.addTestObserver(observer)
        defer { XCTestObservationCenter.shared.removeTestObserver(observer) }
        suite.run()
        let expected = wifiFirst ? [wifi.name, semantic.name] : [semantic.name, wifi.name]
        XCTAssertEqual(observer.names, expected, "Verify actual start order, not just insertion intent")
        print("[C1_OBSERVED_ORDER] \(observer.names)")
        let run = try XCTUnwrap(suite.testRun)
        XCTAssertEqual(run.executionCount, 2, "Both original fixtures must actually execute")
        XCTAssertTrue(run.hasSucceeded)
    }
    func testS1ThenWifi() throws { try runPair(USBListenerLifetimeTests.self, "testLegacyUsbForegroundDropsPreFencePcmAndMatchingPongReleasesFreshPcm", wifiFirst: false) }
    func testWifiThenS1() throws { try runPair(USBListenerLifetimeTests.self, "testLegacyUsbForegroundDropsPreFencePcmAndMatchingPongReleasesFreshPcm", wifiFirst: true) }
    func testS2ThenWifi() throws { try runPair(C1AlternateSemanticTests.self, "testAlternateForegroundPcmFenceWithExplicitOwners", wifiFirst: false) }
    func testWifiThenS2() throws { try runPair(C1AlternateSemanticTests.self, "testAlternateForegroundPcmFenceWithExplicitOwners", wifiFirst: true) }
}
#endif
#endif
