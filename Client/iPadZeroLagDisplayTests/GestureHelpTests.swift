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

    func testDirectAndTrackpadExplainNativeTouchAndMouseDifferences() throws {
        func result(_ gesture: String, mode: IPadTouchMode) throws -> String {
            try XCTUnwrap(GestureGuideContent.items(for: .input(mode)).first { $0.gesture == gesture }?.result)
        }
        XCTAssertEqual(try result("Tap", mode: .direct), "Touch tap")
        XCTAssertEqual(try result("Tap", mode: .trackpad), "Left click")
        XCTAssertEqual(try result("Stationary hold", mode: .direct), "Native Windows press-and-hold; no extra right click")
        XCTAssertEqual(try result("Stationary hold", mode: .trackpad), "Right click; cancels the left tap")
        XCTAssertTrue(try result("Drag control", mode: .direct).contains("touch"))
        XCTAssertTrue(try result("Drag control", mode: .trackpad).contains("left mouse"))
        for mode in [IPadTouchMode.direct, .trackpad] {
            XCTAssertEqual(try result("Next tap while dragging", mode: mode), "Release only; no extra click")
            XCTAssertTrue(try result("Three/four fingers or system gestures", mode: mode).contains("No new PC shortcut"))
        }
    }

    func testHelpExplainsCommandAndTextSourceWithoutRetiredControls() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let helper = GestureGuideContent.helper(for: .input(mode))
            XCTAssertTrue(helper.contains("Command = Ctrl"))
            XCTAssertTrue(helper.contains("Hardware keyboard uses the PC input method"))
            XCTAssertTrue(helper.contains("on-screen keyboard uses the iPad input method"))
            XCTAssertFalse(helper.contains("Local IME"))
            XCTAssertFalse(helper.contains("Send"))
        }
    }

    func testPencilHelpDescribesTheSamePreciseMouseInBothModes() throws {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let description = GestureGuideContent.pencil(for: .input(mode))
            XCTAssertTrue(description.contains("always points absolutely"))
            XCTAssertTrue(description.contains("5 seconds")); XCTAssertTrue(description.contains("400 ms"))
            XCTAssertTrue(description.contains("No Windows pen, pressure or tilt"))
            XCTAssertFalse(description.contains("native touch contact"))
            XCTAssertEqual(try XCTUnwrap(GestureGuideContent.items(for: .input(mode))
                .first { $0.gesture == "Pencil" }?.result), "Precise absolute mouse; tip drags with left button")
        }
    }
}
