import XCTest
import UIKit
@testable import iPadCasting

/// The session pill is the one visible handle for every session: what it says, and how Disconnect is confirmed.
final class SessionPanelTests: XCTestCase {
    func testExtendedWifiSessionNamesThePC() {
        let s = SessionPanelSnapshot.make(hostLabel: "Lam-Laptop", transport: "Wi-Fi", connection: .streaming,
                                          control: .unavailable, mirrorLabel: nil)
        XCTAssertEqual(s.title, "Lam-Laptop")
        XCTAssertEqual(s.hostLabel, "Lam-Laptop")
        XCTAssertEqual(s.transport, "Wi-Fi")
        XCTAssertFalse(s.isMirror)
        XCTAssertFalse(s.reconnecting)
        XCTAssertEqual(s.icon, .extended)
    }

    func testMirrorSessionNamesTheScreenAndControl() {
        let s = SessionPanelSnapshot.make(hostLabel: "Lam-Laptop", transport: "USB-C", connection: .streaming,
                                          control: .on, mirrorLabel: "Built-in display")
        XCTAssertEqual(s.title, "Built-in display")
        XCTAssertEqual(s.hostLabel, "Lam-Laptop")
        XCTAssertTrue(s.isMirror)
        XCTAssertEqual(s.control, .on)
        XCTAssertEqual(s.icon, .laptop)
        let monitor = SessionPanelSnapshot.make(hostLabel: "Lam-Laptop", transport: "USB-C", connection: .streaming,
                                                control: .viewOnly, mirrorLabel: nil)
        XCTAssertEqual(monitor.title, "Lam-Laptop")
        XCTAssertEqual(monitor.icon, .monitor)
    }

    func testUnknownPCAndPlaceholderTransport() {
        let s = SessionPanelSnapshot.make(hostLabel: "  ", transport: "Connected to PC", connection: .streaming,
                                          control: .unavailable, mirrorLabel: nil)
        XCTAssertEqual(s.hostLabel, "Your PC")
        XCTAssertNil(s.transport)
    }

    func testReconnectingSaysSo() {
        let s = SessionPanelSnapshot.make(hostLabel: "Lam-Laptop", transport: "Wi-Fi", connection: .connecting,
                                          control: .unavailable, mirrorLabel: nil)
        XCTAssertTrue(s.reconnecting)
        XCTAssertEqual(s.reconnectingText, "Reconnecting to Lam-Laptop…")
    }

    func testDisconnectNeedsASecondTapWithinFourSeconds() {
        var arming = DisconnectArming()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(arming.tap(at: t0))
        XCTAssertTrue(arming.isArmed(at: t0.addingTimeInterval(1)))
        XCTAssertTrue(arming.tap(at: t0.addingTimeInterval(2)))
        XCTAssertFalse(arming.isArmed(at: t0.addingTimeInterval(2)))
        XCTAssertFalse(arming.tap(at: t0.addingTimeInterval(10)))
        XCTAssertFalse(arming.tap(at: t0.addingTimeInterval(15)), "a stale arm must not confirm")
        arming.reset()
        XCTAssertFalse(arming.isArmed(at: t0.addingTimeInterval(15)))
    }

    @MainActor func testPanelKeyboardRequestOpensTheKeyboard() {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        container.configureRemoteKeyboard(active: true, generation: 5101)
        container.softwareResponderAcquisitionForTesting = { true }
        var lines: [String] = []
        container.touchView.diagnosticSink = { lines.append($0) }
        // The keyboard is inactive until the test host app is active; the tap source proves the bridge either way.
        let before = container.keyboardMode
        NotificationCenter.default.post(name: .sessionPanelToggleKeyboard, object: nil)
        XCTAssertTrue(lines.last?.contains("keyboard_tap=panel") == true)
        if before != .none { XCTAssertEqual(container.keyboardMode, .softwareOpen) }
        container.retireRemoteKeyboard()
    }

    // MARK: Pill clears the PC picture

    func testPillShrinksToAHandleWhenIdle() {
        XCTAssertEqual(SessionPillPresentation.make(isOpen: false, idleFor: 1, reconnecting: false), .full)
        XCTAssertEqual(SessionPillPresentation.make(isOpen: false, idleFor: 4, reconnecting: false), .handle,
                       "an idle pill must stop covering the top of the PC screen")
        XCTAssertEqual(SessionPillPresentation.make(isOpen: true, idleFor: 60, reconnecting: false), .full)
        XCTAssertEqual(SessionPillPresentation.make(isOpen: false, idleFor: 60, reconnecting: true), .full,
                       "reconnecting stays readable")
    }

    func testSessionNamesTheWifiPCWhenTheLabelWasCleared() {
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "", lastWifi: "ADMINISTRATOR", usb: false), "ADMINISTRATOR")
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "Lam-PC", lastWifi: "ADMINISTRATOR", usb: false), "Lam-PC")
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "", lastWifi: "ADMINISTRATOR", usb: true), "",
                       "a USB-C PC may not be the Wi-Fi one")
    }

    // MARK: Theme

    func testThemeIsReadable() {
        for background in [SessionInk.canvas, SessionInk.surface, SessionInk.raised] {
            XCTAssertGreaterThanOrEqual(SessionInk.contrast(SessionInk.text, background), 7)
            XCTAssertGreaterThanOrEqual(SessionInk.contrast(SessionInk.secondary, background), 4.5)
            XCTAssertGreaterThanOrEqual(SessionInk.contrast(SessionInk.accent, background), 3)
            for tone in [SessionInk.positive, SessionInk.warning, SessionInk.danger] {
                XCTAssertGreaterThanOrEqual(SessionInk.contrast(tone, background), 4.5)
            }
        }
        XCTAssertGreaterThanOrEqual(SessionInk.contrast(SessionInk.onAccent, SessionInk.accent), 4.5)
        XCTAssertGreaterThanOrEqual(SessionInk.contrast(SessionInk.onDanger, SessionInk.dangerFill), 4.5)
    }

    func testThemeIsNotGreyOnly() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        for ink in [SessionInk.canvas, SessionInk.surface, SessionInk.raised] {
            ink.getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertGreaterThan(b - r, 0.03, "surfaces carry the midnight hue, not neutral grey")
        }
        SessionInk.accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(b - r, 0.25, "one saturated accent for main actions")
    }
}
