import XCTest
import SwiftUI
import UIKit
@testable import iPadCasting

final class InputBarAccessibilityTests: XCTestCase {
    @MainActor func testModifierActivationRespectsPreviewAuthorityAndReleasesExistingStates() {
        let session = IPadInputSession.preview()
        let control = SessionModifierButton(session: session, modifier: .control)
        session.setModifier(.control, .off)
        control.activate()
        XCTAssertEqual(session.modifierState(.control), session.canType ? .oneShot : .off)
        control.activate()
        XCTAssertEqual(session.modifierState(.control), .off)
        control.lock()
        XCTAssertEqual(session.modifierState(.control), session.canType ? .locked : .off)
        // A denied preview can still prove that release actions never require authority.
        session.setModifier(.control, .locked)
        control.activate()
        XCTAssertEqual(session.modifierState(.control), .off)
    }

    @MainActor func testNamedAccessibilityActionsSetExplicitStatesForEveryModifier() {
        let session = IPadInputSession.preview()
        for modifier in IPadModifier.allCases {
            let control = SessionModifierButton(session: session, modifier: modifier)
            control.useOnce()
            XCTAssertEqual(session.modifierState(modifier), session.canType ? .oneShot : .off)
            control.lock()
            XCTAssertEqual(session.modifierState(modifier), session.canType ? .locked : .off)
            session.setModifier(modifier, .locked)
            control.turnOff()
            XCTAssertEqual(session.modifierState(modifier), .off)
        }
    }

    @MainActor func testModifierTapCycleAndDoubleTapHaveExplicitStateTransitions() {
        XCTAssertEqual(SessionModifierButton.nextState(after: .off), .oneShot)
        XCTAssertEqual(SessionModifierButton.nextState(after: .oneShot), .off)
        XCTAssertEqual(SessionModifierButton.nextState(after: .locked), .off)
    }

    @MainActor func testModifierValuesAndLabelsExplainStateWithoutColour() {
        XCTAssertEqual(SessionModifierButton.title(for: .control), "Ctrl")
        XCTAssertEqual(SessionModifierButton.title(for: .win), "Win")
        XCTAssertEqual(SessionModifierButton.value(for: .off), "Off")
        XCTAssertEqual(SessionModifierButton.value(for: .oneShot), "One-shot")
        XCTAssertEqual(SessionModifierButton.value(for: .locked), "Locked")
    }

    func testWindowsShortcutsOfferStartAndBalancedChordsWithoutLockPC() {
        XCTAssertEqual(SessionWindowsShortcut.all.map(\.title),
                       ["Win", "Win+Tab", "Win+D", "Win+E", "Win+R", "Win+Space", "Win+H", "Win+Shift+S"])
        XCTAssertEqual(SessionWindowsShortcut.all.map(\.usage), [0xe3, 0x2b, 0x07, 0x08, 0x15, 0x2c, 0x0b, 0x16])
        XCTAssertEqual(SessionWindowsShortcut.all.filter(\.shift).map(\.title), ["Win+Shift+S"])
        XCTAssertFalse(SessionWindowsShortcut.all.contains { $0.usage == 0x0f })
    }

    func testSpecialKeysIncludeEditingNavigationAndEveryFunctionKey() {
        XCTAssertEqual(SessionSpecialKey.standard.map(\.usage),
                       [0x29, 0x2b, 0x28, 0x2a, 0x50, 0x52, 0x51, 0x4f, 0x4a, 0x4d, 0x4b, 0x4e, 0x4c])
        XCTAssertEqual(SessionSpecialKey.functions.map(\.title), (1...12).map { "F\($0)" })
        XCTAssertEqual(SessionSpecialKey.functions.map(\.usage), Array(UInt16(0x3a)...UInt16(0x45)))
    }

    @MainActor func testPointerPositionHasFiniteClampedSpokenValues() {
        XCTAssertEqual(AccessiblePointerControls.positionValue(CGPoint(x: 0.5, y: 0.5)),
                       "Horizontal 50 percent, vertical 50 percent")
        XCTAssertEqual(AccessiblePointerControls.positionValue(CGPoint(x: -1, y: 2)),
                       "Horizontal 0 percent, vertical 100 percent")
        XCTAssertEqual(AccessiblePointerControls.positionValue(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)),
                       "Horizontal 50 percent, vertical 50 percent")
    }

    @MainActor func testTargetsGrowWithDynamicTypeAndNeverShrinkBelow44Points() {
        var previousHeight: CGFloat = 0
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            let controller = UIHostingController(rootView: SessionInputControlLabel(title: "Right click")
                .environment(\.dynamicTypeSize, size))
            let measured = controller.sizeThatFits(in: CGSize(width: 280, height: 1000))
            XCTAssertGreaterThanOrEqual(measured.width, 44)
            XCTAssertGreaterThanOrEqual(measured.height, 44)
            XCTAssertGreaterThanOrEqual(measured.height, previousHeight)
            previousHeight = measured.height
        }
    }

    func testLatchChipLivesOutsidePanelAndBarVisibilityConditions() throws {
        let source = try clientSource("SessionPanelOverlay.swift")
        let overlay = try XCTUnwrap(source.components(separatedBy: ".overlay(alignment: .bottom)").last?
            .components(separatedBy: ".environment(\\.colorScheme").first)
        XCTAssertTrue(overlay.contains("SessionDraggingChip()"))
        XCTAssertFalse(overlay.contains("if isOpen"))
        XCTAssertLessThan(try XCTUnwrap(overlay.range(of: "SessionDraggingChip()")?.lowerBound),
                          try XCTUnwrap(overlay.range(of: "if inputBarVisible")?.lowerBound))
        let bar = try clientSource("SessionInputBar.swift")
        XCTAssertTrue(bar.contains("if inputSession.dragState == .latched"))
        XCTAssertTrue(bar.contains("Dragging - Release"))
        XCTAssertTrue(bar.contains("inputSession.releaseDrag()"))
    }

    func testAssistiveActivationUsesButtonsAndExplicitModifierActions() throws {
        let bar = try clientSource("SessionInputBar.swift")
        for name in ["Use once", "Lock", "Turn off"] {
            XCTAssertTrue(bar.contains(".accessibilityAction(named: Text(\"\(name)\"))"))
        }
        XCTAssertTrue(bar.contains("Button(action: activate)"))
        XCTAssertTrue(bar.contains(".accessibilityAction { activate() }"))
        XCTAssertTrue(bar.contains("TapGesture(count: 2)"))
        let pointer = try clientSource("AccessiblePointerControls.swift")
        XCTAssertTrue(pointer.contains("Button { move(direction) }"))
        XCTAssertTrue(pointer.contains(".accessibilityAdjustableAction"))
        XCTAssertTrue(pointer.contains("guard inputSession.canPoint"))
    }

    func testInputControlsContainNoTransportOrKeyOwnershipLogic() throws {
        for file in ["SessionInputBar.swift", "AccessiblePointerControls.swift",
                     "RemoteControl/RemoteMouseControls.swift", "RemoteControl/RemoteSpecialKeyBar.swift"] {
            let source = try clientSource(file)
            for forbidden in ["NetworkManager", "sendKey", "emitKey", "RemoteKeyboardState", "RemoteScanKeyCommand",
                              "NotificationCenter", "RemoteInputReset", "keyDown", "keyUp"] {
                XCTAssertFalse(source.contains(forbidden), "\(file): \(forbidden)")
            }
            XCTAssertFalse(source.contains(".minimumScaleFactor"))
        }
    }

    private func clientSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/" + path), encoding: .utf8)
    }
}
