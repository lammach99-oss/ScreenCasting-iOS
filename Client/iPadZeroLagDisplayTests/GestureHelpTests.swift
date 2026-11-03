import XCTest
import CoreGraphics
@testable import iPadCasting

/// Gesture help: which finger gestures earn a confirming toast, and that each one stops after three.
final class GestureHelpTests: XCTestCase {
    private let p = CGPoint(x: 10, y: 20)

    func testHintComesFromTheGesturesOwnOutputs() {
        XCTAssertEqual(GestureHint.from([.pointer(.rightClick, p, 0)]), .rightClick)
        XCTAssertEqual(GestureHint.from([.pointer(.zoomWheel, p, 120)]), .zoom)
        XCTAssertEqual(GestureHint.from([.directTouch(.down, 7, p, 255), .directTouch(.update, 7, p, 255)]), .drag)
    }

    func testPlainTapsWheelsAndPanelOpenGetNoToast() {
        XCTAssertNil(GestureHint.from([.directTouch(.down, 7, p, 255), .directTouch(.up, 7, p, 255)]))
        XCTAssertNil(GestureHint.from([.pointer(.verticalWheel, p, 120)]), "scroll is reported once per swipe, not per wheel step")
        XCTAssertNil(GestureHint.from([.openSettings]))
        XCTAssertNil(GestureHint.from([.directTouch(.update, 7, p, 255)]))
    }

    func testEachGestureToastsThreeTimesThenGoesQuiet() throws {
        let suite = "GestureHelpTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = GestureToastLedger(defaults: defaults)
        XCTAssertEqual(ledger.toast(for: .rightClick), "Right-click")
        XCTAssertEqual(ledger.toast(for: .rightClick), "Right-click")
        XCTAssertEqual(ledger.toast(for: .rightClick), "Right-click")
        XCTAssertNil(ledger.toast(for: .rightClick))
        XCTAssertEqual(ledger.toast(for: .scroll), "Scrolling", "each gesture has its own count")
        XCTAssertNil(GestureToastLedger(defaults: defaults).toast(for: .rightClick), "the count survives a relaunch")
    }

    func testToastWording() {
        XCTAssertEqual(GestureHint.drag.toastText, "Dragging")
        XCTAssertEqual(GestureHint.zoom.toastText, "Zoom")
    }
}
