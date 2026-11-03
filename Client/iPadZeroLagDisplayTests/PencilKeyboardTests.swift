import XCTest
import UIKit
@testable import iPadCasting

/// iPadOS withholds the on-screen keyboard while it expects Apple Pencil handwriting (Scribble).
/// The keyboard request must then stay on, say why, and let the next tap retry.
final class PencilKeyboardTests: XCTestCase {
    @MainActor private func fixture(pencilExpected: Bool, lines: @escaping (String) -> Void,
                                    attempts: @escaping () -> Void = {}) -> ConnectedPresentationContainer {
        let container = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        container.configureRemoteKeyboard(active: true, generation: 4101)
        container.softwareResponderAcquisitionForTesting = { attempts(); return true }
        container.pencilInputExpected = { pencilExpected }
        container.keyboardWithheldDelay = 0.05
        container.touchView.diagnosticSink = lines
        return container
    }

    @MainActor private func settle() {
        let done = expectation(description: "withheld check ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    @MainActor func testTapSourceNamesPencilAndFinger() {
        XCTAssertEqual(KeyboardTapSource(touchType: .pencil), .pencil)
        XCTAssertEqual(KeyboardTapSource(touchType: .direct), .finger)
        XCTAssertEqual(KeyboardTapSource(touchType: nil), .unknown)
    }

    @MainActor func testWithheldKeyboardWhilePencilExpectedShowsHintAndKeepsRequest() {
        var lines: [String] = []
        let container = fixture(pencilExpected: true, lines: { lines.append($0) })
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(lines.last?.contains("keyboard_tap=unknown") == true)
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        settle()
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertTrue(container.softwareKeyboardWithheld)
        XCTAssertFalse(container.keyboardHintLabel.isHidden)
        XCTAssertTrue(container.keyboardHintLabel.text?.contains("Scribble") == true)
        let withheld = lines.filter { $0.contains("reason=native_keyboard_withheld") }
        XCTAssertEqual(withheld.count, 1)
        XCTAssertTrue(withheld.first?.contains("pencil_expected=1") == true)
        container.retireRemoteKeyboard()
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        XCTAssertFalse(container.softwareKeyboardWithheld)
    }

    @MainActor func testTapWhileWithheldRetriesInsteadOfClosing() {
        var lines: [String] = []
        var attempts = 0
        let container = fixture(pencilExpected: true, lines: { lines.append($0) }, attempts: { attempts += 1 })
        container.keyboardButton.sendActions(for: .touchUpInside)
        settle()
        XCTAssertEqual(attempts, 1)
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(container.keyboardMode, .softwareOpen)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        XCTAssertFalse(container.softwareKeyboardWithheld)
        XCTAssertTrue(lines.contains { $0.contains("reason=native_show_retry") })
        container.retireRemoteKeyboard()
    }

    @MainActor func testRetriesStopAfterTwoSoTheButtonCanStillClose() {
        var attempts = 0
        let container = fixture(pencilExpected: true, lines: { _ in }, attempts: { attempts += 1 })
        container.keyboardButton.sendActions(for: .touchUpInside)
        settle()
        container.keyboardButton.sendActions(for: .touchUpInside) // retry 1
        settle()
        container.keyboardButton.sendActions(for: .touchUpInside) // retry 2
        settle()
        XCTAssertTrue(container.softwareKeyboardWithheld)
        container.keyboardButton.sendActions(for: .touchUpInside) // closes
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        container.retireRemoteKeyboard()
    }

    @MainActor func testWithheldWithoutPencilOnlyLogsAndKeepsToggle() {
        var lines: [String] = []
        let container = fixture(pencilExpected: false, lines: { lines.append($0) })
        container.keyboardButton.sendActions(for: .touchUpInside)
        settle()
        XCTAssertFalse(container.softwareKeyboardWithheld)
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        XCTAssertTrue(lines.contains { $0.contains("reason=native_keyboard_withheld") && $0.contains("pencil_expected=0") })
        container.keyboardButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        container.retireRemoteKeyboard()
    }

    @MainActor func testClosingBeforeTheCheckLogsNothingWithheld() {
        var lines: [String] = []
        let container = fixture(pencilExpected: true, lines: { lines.append($0) })
        container.keyboardButton.sendActions(for: .touchUpInside)
        container.keyboardButton.sendActions(for: .touchUpInside)
        settle()
        XCTAssertEqual(container.keyboardMode, .softwareAvailable)
        XCTAssertFalse(lines.contains { $0.contains("reason=native_keyboard_withheld") })
        XCTAssertTrue(container.keyboardHintLabel.isHidden)
        container.retireRemoteKeyboard()
    }
}
