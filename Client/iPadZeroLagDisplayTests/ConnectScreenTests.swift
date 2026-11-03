import XCTest
@testable import iPadCasting

/// The connect screen's one status line: plain words, one tone, at most one action.
final class ConnectScreenTests: XCTestCase {
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
        XCTAssertEqual(status(.awaitingHostIdentity).text, "Confirm on the PC to finish connecting")
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
}
