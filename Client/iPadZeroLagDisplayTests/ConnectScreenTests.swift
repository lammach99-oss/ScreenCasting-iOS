import Combine
import XCTest
import Network
@testable import iPadCasting

// Some integration conditions combine state from multiple queues without a publisher.
// Sample those on the main actor and stop sampling as soon as the waiter returns.
@MainActor
func awaitFixtureCondition(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           condition: @escaping @MainActor () -> Bool) async throws {
    if condition() { return }
    let reached = XCTestExpectation(description: description)
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    let observation = Task { @MainActor in
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { reached.fulfill(); return }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
        }
    }
    defer { observation.cancel() }
    guard await XCTWaiter.fulfillment(of: [reached], timeout: 10) == .completed else {
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
        throw FixtureWaitError.timedOut
    }
}

private enum FixtureWaitError: Error { case timedOut }

final class DiscoveryLifecycleTests: XCTestCase {
    private final class Browser: DiscoveryBrowser, @unchecked Sendable {
        var results: (@Sendable ([NWEndpoint]) -> Void)?
        var state: (@Sendable (NWBrowser.State) -> Void)?
        private(set) var cancelled = false

        func start(queue: DispatchQueue, results: @escaping @Sendable ([DiscoveryAdvertisement]) -> Void,
                   state: @escaping @Sendable (NWBrowser.State) -> Void) {
            self.results = { endpoints in results(endpoints.map { DiscoveryAdvertisement(endpoint: $0) }) }
            self.state = state
        }

        func cancel() { cancelled = true }
    }

    @MainActor func testStopClearsPublishedRowsAndCancelsBrowser() async throws {
        let browser = Browser()
        let manager = DiscoveryManager(makeBrowser: { browser })
        let endpoint = try XCTUnwrap(WifiReconnectTarget.service(name: "Fixture A", type: "_screencasting._tcp", domain: "local.").endpoint)
        manager.startBrowsing()
        let published = XCTestExpectation(description: "Fixture A published by the active browser")
        let observation = manager.$discoveredHosts.first(where: { $0.map(\.endpoint) == [endpoint] })
            .sink { _ in published.fulfill() }
        defer { observation.cancel() }
        let publish = try XCTUnwrap(browser.results)
        publish([endpoint])
        guard await XCTWaiter.fulfillment(of: [published], timeout: 10) == .completed else {
            return XCTFail("Active browser did not publish Fixture A")
        }
        XCTAssertEqual(manager.discoveredHosts.map(\.name), ["Fixture A"])
        manager.stopBrowsing()
        XCTAssertTrue(browser.cancelled)
        XCTAssertTrue(manager.discoveredHosts.isEmpty)
    }

    @MainActor func testOldResultsAndFailureCannotPublishAfterRestart() async throws {
        let old = Browser(), current = Browser()
        var browsers = [old, current]
        let manager = DiscoveryManager(makeBrowser: { browsers.removeFirst() })
        let first = try XCTUnwrap(WifiReconnectTarget.service(name: "Fixture A", type: "_screencasting._tcp", domain: "local.").endpoint)
        let second = try XCTUnwrap(WifiReconnectTarget.service(name: "Fixture B", type: "_screencasting._tcp", domain: "local.").endpoint)
        manager.startBrowsing()
        old.results?([first]) // Queued publication has not run yet.
        manager.startBrowsing()
        await drainMainQueue()
        XCTAssertTrue(manager.discoveredHosts.isEmpty)
        current.results?([second])
        old.results?([first])
        old.state?(.failed(.posix(.ECANCELED)))
        await drainMainQueue()
        XCTAssertEqual(manager.discoveredHosts.map(\.endpoint), [second])
    }

    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }
}

/// The connect screen's one status line: plain words, one tone, at most one action.
final class ConnectScreenTests: XCTestCase {
    func testPhoneConnectPresentationFiltersHistoryAndPreviewsOnlyAdmittedTargets() throws {
        let host = "192.0.2.2"
        let remote = RecentRemoteHost(host: host, remoteControl: true, lastUsed: Date())
        let casting = RecentRemoteHost(host: host, remoteControl: false, lastUsed: Date())
        let malformed = RecentRemoteHost(host: "/", remoteControl: true, lastUsed: Date())
        let history = [casting, remote, malformed]
        let model = try XCTUnwrap(PhoneConnectScreenModel(capabilities: .resolve(.phone), history: history))
        XCTAssertEqual(model.sections.map(\.rawValue), ["Recent remote hosts", "Manual address", "Discovered remote hosts"])
        XCTAssertEqual(model.recentHosts, [remote])
        XCTAssertEqual(history, [casting, remote, malformed])
        let preview = try XCTUnwrap(model.preview(.recent(remote)))
        XCTAssertEqual(preview.destination, host)
        XCTAssertEqual(preview.purpose, "Remote control")
        XCTAssertNil(model.preview(.recent(casting)))
        XCTAssertNil(model.preview(.discovered(serviceType: "_sc-remote._tcp", resolved: nil)))
        XCTAssertNil(PhoneConnectScreenModel(capabilities: .resolve(.pad), history: history))
        XCTAssertNil(PhoneConnectScreenModel(capabilities: .resolve(.unspecified), history: history))
    }

    private func status(_ state: ConnectionState, pc: String? = "Lam-Laptop", found: Int = 0, attempt: Int = 0) -> ConnectScreenStatus {
        .make(state: state, pcName: pc, discoveredCount: found, reconnectAttempt: attempt)
    }

    func testIdleSearchesThenCountsPCs() {
        XCTAssertEqual(status(.idle), ConnectScreenStatus(text: "Looking for PCs on this Wi-Fi…", detail: nil, tone: .busy, action: .none))
        XCTAssertEqual(status(.idle, found: 1).text, "1 PC on this Wi-Fi")
        XCTAssertEqual(status(.idle, found: 3).text, "3 PCs on this Wi-Fi")
        XCTAssertEqual(status(.disconnected(reason: ""), found: 2).text, "2 PCs on this Wi-Fi")
    }

    func testConnectingCanBeCancelled() {
        XCTAssertEqual(status(.connecting), ConnectScreenStatus(text: "Connecting to Lam-Laptop…", detail: nil, tone: .busy, action: .cancel))
        XCTAssertEqual(status(.awaitingPIN).action, .cancel)
        XCTAssertEqual(status(.awaitingHostIdentity).text, "Check the code on the PC")
        XCTAssertEqual(status(.awaitingPIN).text, "Enter the PIN shown on the PC")
        XCTAssertEqual(status(.authFailed(reason: "bad")), ConnectScreenStatus(text: "Wrong PIN. Try again.", detail: nil, tone: .warning, action: .cancel))
    }

    func testUSBNeverBorrowsTheWifiPCOrItsRetry() {
        let usb = { (state: ConnectionState, attempt: Int) in
            ConnectScreenStatus.make(state: state, pcName: "Lam-Laptop", discoveredCount: 0, reconnectAttempt: attempt, usb: true)
        }
        XCTAssertEqual(usb(.connecting, 2).text, "Connecting to the PC over USB-C…")
        XCTAssertEqual(usb(.disconnected(reason: "Cable unplugged"), 0),
                       ConnectScreenStatus(text: "The USB-C connection ended.", detail: "Cable unplugged", tone: .danger, action: .restartUSB))
    }

    func testRetryOnlyWhenThereIsAPCToRetry() {
        let s = ConnectScreenStatus.make(state: .disconnected(reason: "Host unreachable"), pcName: "Lam-Laptop",
                                         discoveredCount: 0, reconnectAttempt: 0, canRetry: false)
        XCTAssertEqual(s.action, .none)
        XCTAssertEqual(s.tone, .danger)
    }

    func testReconnectingShowsTheTryAndCanStop() {
        let s = status(.connecting, attempt: 2)
        XCTAssertEqual(s.text, "Reconnecting to Lam-Laptop… try 2")
        XCTAssertEqual(s.tone, .warning)
        XCTAssertEqual(s.action, .stop)
        let waiting = status(.disconnected(reason: "Connection reset"), attempt: 3)
        XCTAssertEqual(waiting.text, "Reconnecting to Lam-Laptop… try 3")
        XCTAssertEqual(waiting.detail, "Connection reset")
    }

    func testFailureNamesThePCAndOffersRetry() {
        let s = status(.disconnected(reason: "Host unreachable"))
        XCTAssertEqual(s, ConnectScreenStatus(text: "Couldn't connect to Lam-Laptop.", detail: "Host unreachable", tone: .danger, action: .retry))
    }

    func testUSBWaitsAndUnknownPCIsYourPC() {
        XCTAssertEqual(status(.listening), ConnectScreenStatus(text: "Waiting for the PC over USB-C…", detail: nil, tone: .busy, action: .stop))
        XCTAssertEqual(status(.connecting, pc: "  ").text, "Connecting to your PC…")
        XCTAssertEqual(status(.streaming, pc: nil).text, "Connected to your PC")
    }

    func testTailnetFailureAppendsTailscaleHintToReason() {
        let s = ConnectScreenStatus.make(state: .disconnected(reason: "Host unreachable"), pcName: "office-pc",
                                         discoveredCount: 0, reconnectAttempt: 0, tailnetTarget: true)
        XCTAssertEqual(s, ConnectScreenStatus(text: "Couldn't connect to office-pc.",
                                             detail: "Host unreachable Check that Tailscale is connected on this iPad and on the PC.",
                                             tone: .danger, action: .retry))
        let noRetry = ConnectScreenStatus.make(state: .disconnected(reason: "Connection reset"), pcName: "100.64.0.10",
                                               discoveredCount: 0, reconnectAttempt: 0, canRetry: false, tailnetTarget: true)
        XCTAssertEqual(noRetry, ConnectScreenStatus(text: "Couldn't connect to 100.64.0.10.",
                                                   detail: "Connection reset Check that Tailscale is connected on this iPad and on the PC.",
                                                   tone: .danger, action: .none))
    }

    func testExistingStatusCasesStayUnchangedWithDefaultAndTailnetTarget() {
        let cases: [(state: ConnectionState, pc: String?, found: Int, attempt: Int, usb: Bool, canRetry: Bool, expected: ConnectScreenStatus)] = [
            (.idle, "Lam-Laptop", 0, 0, false, true,
             .init(text: "Looking for PCs on this Wi-Fi…", detail: nil, tone: .busy, action: .none)),
            (.idle, "Lam-Laptop", 1, 0, false, true,
             .init(text: "1 PC on this Wi-Fi", detail: nil, tone: .neutral, action: .none)),
            (.idle, "Lam-Laptop", 3, 0, false, true,
             .init(text: "3 PCs on this Wi-Fi", detail: nil, tone: .neutral, action: .none)),
            (.listening, "Lam-Laptop", 0, 0, true, true,
             .init(text: "Waiting for the PC over USB-C…", detail: nil, tone: .busy, action: .stop)),
            (.connecting, "Lam-Laptop", 0, 0, false, true,
             .init(text: "Connecting to Lam-Laptop…", detail: nil, tone: .busy, action: .cancel)),
            (.connecting, "  Lam-Laptop  ", 0, 0, false, true,
             .init(text: "Connecting to Lam-Laptop…", detail: nil, tone: .busy, action: .cancel)),
            (.connecting, "  ", 0, 0, false, true,
             .init(text: "Connecting to your PC…", detail: nil, tone: .busy, action: .cancel)),
            (.connecting, "Lam-Laptop", 0, 2, false, true,
             .init(text: "Reconnecting to Lam-Laptop… try 2", detail: nil, tone: .warning, action: .stop)),
            (.connecting, "Lam-Laptop", 0, 2, true, true,
             .init(text: "Connecting to the PC over USB-C…", detail: nil, tone: .busy, action: .cancel)),
            (.awaitingHostIdentity, "Lam-Laptop", 0, 0, false, true,
             .init(text: "Check the code on the PC", detail: nil, tone: .busy, action: .cancel)),
            (.awaitingPIN, "Lam-Laptop", 0, 0, false, true,
             .init(text: "Enter the PIN shown on the PC", detail: nil, tone: .busy, action: .cancel)),
            (.authFailed(reason: "bad"), "Lam-Laptop", 0, 0, false, true,
             .init(text: "Wrong PIN. Try again.", detail: nil, tone: .warning, action: .cancel)),
            (.streaming, "Lam-Laptop", 0, 0, false, true,
             .init(text: "Connected to Lam-Laptop", detail: nil, tone: .ready, action: .none)),
            (.streaming, nil, 0, 0, false, true,
             .init(text: "Connected to your PC", detail: nil, tone: .ready, action: .none)),
            (.streaming, "Lam-Laptop", 0, 0, true, true,
             .init(text: "Connected to the PC over USB-C", detail: nil, tone: .ready, action: .none)),
            (.disconnected(reason: ""), "Lam-Laptop", 0, 0, false, true,
             .init(text: "Looking for PCs on this Wi-Fi…", detail: nil, tone: .busy, action: .none)),
            (.disconnected(reason: ""), "Lam-Laptop", 1, 0, false, true,
             .init(text: "1 PC on this Wi-Fi", detail: nil, tone: .neutral, action: .none)),
            (.disconnected(reason: ""), "Lam-Laptop", 2, 0, false, true,
             .init(text: "2 PCs on this Wi-Fi", detail: nil, tone: .neutral, action: .none)),
            (.disconnected(reason: ""), "Lam-Laptop", 0, 2, false, true,
             .init(text: "Reconnecting to Lam-Laptop… try 2", detail: nil, tone: .warning, action: .stop)),
            (.disconnected(reason: "Connection reset"), "Lam-Laptop", 0, 3, false, true,
             .init(text: "Reconnecting to Lam-Laptop… try 3", detail: "Connection reset", tone: .warning, action: .stop)),
            (.disconnected(reason: ""), "Lam-Laptop", 2, 0, true, true,
             .init(text: "2 PCs on this Wi-Fi", detail: nil, tone: .neutral, action: .none)),
            (.disconnected(reason: "Cable unplugged"), "Lam-Laptop", 0, 0, true, true,
             .init(text: "The USB-C connection ended.", detail: "Cable unplugged", tone: .danger, action: .restartUSB)),
            (.disconnected(reason: "Cable unplugged"), "Lam-Laptop", 0, 2, true, false,
             .init(text: "The USB-C connection ended.", detail: "Cable unplugged", tone: .danger, action: .restartUSB))
        ]
        for (index, entry) in cases.enumerated() {
            let omitted = ConnectScreenStatus.make(state: entry.state, pcName: entry.pc, discoveredCount: entry.found,
                                                    reconnectAttempt: entry.attempt, usb: entry.usb, canRetry: entry.canRetry)
            XCTAssertEqual(omitted, entry.expected, "Default case \(index)")
            for tailnetTarget in [false, true] {
                let explicit = ConnectScreenStatus.make(state: entry.state, pcName: entry.pc, discoveredCount: entry.found,
                                                         reconnectAttempt: entry.attempt, usb: entry.usb,
                                                         canRetry: entry.canRetry, tailnetTarget: tailnetTarget)
                XCTAssertEqual(explicit, entry.expected, "Case \(index), tailnetTarget \(tailnetTarget)")
            }
        }
        for canRetry in [false, true] {
            let expected = ConnectScreenStatus(text: "Couldn't connect to Lam-Laptop.", detail: "Host unreachable",
                                               tone: .danger, action: canRetry ? .retry : .none)
            let omitted = ConnectScreenStatus.make(state: .disconnected(reason: "Host unreachable"), pcName: "Lam-Laptop",
                                                    discoveredCount: 0, reconnectAttempt: 0, canRetry: canRetry)
            let nonTailnet = ConnectScreenStatus.make(state: .disconnected(reason: "Host unreachable"), pcName: "Lam-Laptop",
                                                       discoveredCount: 0, reconnectAttempt: 0, canRetry: canRetry, tailnetTarget: false)
            XCTAssertEqual(omitted, expected)
            XCTAssertEqual(nonTailnet, expected)
        }
    }
}
