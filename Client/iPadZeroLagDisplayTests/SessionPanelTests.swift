import XCTest
import UIKit
@testable import iPadCasting

/// The session pill is the one visible handle for every session: what it says, and how Disconnect is confirmed.
final class SessionPanelTests: XCTestCase {
    func testScreenCycleUsesCatalogueOrderAndWrapsWithoutNamesAsIdentity() {
        let entries = [ScreenPickerTile(id: 30, label: "Screen", isBuiltIn: false, status: .available),
                       ScreenPickerTile(id: 10, label: "Screen", isBuiltIn: false, status: .available),
                       ScreenPickerTile(id: 20, label: "Screen", isBuiltIn: false, status: .available)]
        for (current, next, position) in [(UInt64(30), UInt64(10), 1), (10, 20, 2), (20, 30, 3)] {
            let cycle = ScreenCyclePresentation.make(candidates: entries, currentId: current, pending: false)
            XCTAssertEqual(cycle.nextTargetId, next)
            XCTAssertEqual(cycle.position, position)
            XCTAssertEqual(cycle.count, 3)
            XCTAssertTrue(cycle.enabled)
        }
        XCTAssertEqual(ScreenCyclePresentation.make(candidates: Array(entries.prefix(2)), currentId: 10,
            pending: false).nextTargetId, 30)
    }

    func testSingleScreenDisablesOnlyWhenItIsCurrentAndRecoveryRemainsSelectable() {
        let entries = [ScreenPickerTile(id: 7, label: "Screen 1", isBuiltIn: false, status: .available)]
        let current = ScreenCyclePresentation.make(candidates: entries, currentId: 7, pending: false)
        XCTAssertFalse(current.enabled)
        XCTAssertEqual(current.reason, "Only one screen is available.")
        let recovery = ScreenCyclePresentation.make(candidates: entries, currentId: nil, pending: false)
        XCTAssertTrue(recovery.enabled)
        XCTAssertEqual(recovery.currentLabel, "Choose a screen")
        XCTAssertEqual(recovery.nextTargetId, 7)
        XCTAssertEqual(recovery.accessibilityValue, "Choose a screen")
    }

    func testCycleEmptyPendingAndPermissionHaveExplicitReasons() {
        XCTAssertEqual(ScreenCyclePresentation.make(candidates: [], currentId: nil, pending: false).reason,
                       "No screens are available.")
        let entries = [ScreenPickerTile(id: 7, label: "Screen 1", isBuiltIn: false, status: .locked)]
        let pending = ScreenCyclePresentation.make(candidates: entries, currentId: nil, pending: true)
        XCTAssertFalse(pending.enabled)
        XCTAssertEqual(pending.reason, "Switching screens\u{2026}")
        let locked = ScreenCyclePresentation.make(candidates: entries, currentId: nil, pending: false,
            disabledReason: "Screen switching is off on the PC.")
        XCTAssertFalse(locked.enabled)
        XCTAssertEqual(locked.reason, "Screen switching is off on the PC.")
    }

    func testTouchChoicesPreserveAutomaticAndForcedAllDeviceTrackpad() {
        XCTAssertTrue(RemoteTouchPresentation(mode: .auto).trackpadSelected)
        XCTAssertTrue(RemoteTouchPresentation(mode: .trackpad).trackpadSelected)
        XCTAssertFalse(RemoteTouchPresentation(mode: .direct).trackpadSelected)
        XCTAssertEqual(RemoteTouchPresentation.trackpadChoice, .auto)
        XCTAssertEqual(RemoteTouchPresentation.advancedChoice(enabled: true), .trackpad)
        XCTAssertEqual(RemoteTouchPresentation.advancedChoice(enabled: false), .auto)
    }

    func testActionsReflowByAvailableWidthAndAccessibilityTextSize() {
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 388, idealWidths: [100, 110, 90], accessibility: false), 3)
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 288, idealWidths: [100, 110, 90], accessibility: false), 2)
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 200, idealWidths: [100, 110, 90], accessibility: false), 1)
        for width in [Double(288), 388] {
            XCTAssertEqual(SessionPanelLayout.actionColumns(width: width, idealWidths: [100, 110, 90], accessibility: true), 1)
        }
    }

    func testGestureHelpFollowsTheActualEngineAndDoesNotAdvertiseRemotePenPressure() {
        for mode in [RemoteMouseMode.auto, .trackpad, .direct] {
            let guide = GestureGuideContent.items(for: .remote(mode))
            XCTAssertTrue(guide.contains { $0.gesture == "Double-tap and hold" })
            XCTAssertTrue(guide.contains { $0.gesture == "Move two fingers" && $0.result == "Scroll" })
            XCTAssertTrue(guide.contains { $0.gesture == "Two-finger tap" && $0.result == "Right-click" })
            XCTAssertFalse(guide.contains { $0.gesture == "Pinch" || $0.gesture == "Three-finger tap" || $0.gesture == "Swipe one finger" })
        }
        XCTAssertTrue(GestureGuideContent.items(for: .casting).contains { $0.gesture == "Swipe one finger" })
        XCTAssertTrue(GestureGuideContent.items(for: .casting).contains { $0.gesture == "Pinch" })
        XCTAssertTrue(GestureGuideContent.pencil(for: .remote(.direct)).contains("do not send pen pressure"))
        XCTAssertTrue(GestureGuideContent.pencil(for: .remote(.trackpad)).contains("Trackpad"))
    }

    func testLegacyModeChoiceShowsKnownModeWithoutInventingTypedRequests() {
        let modes = CaptureModePresentation.make(targets: CaptureTargetState(), kind: .castingExtend, lastPhysicalId: nil)
        XCTAssertTrue(modes.extend.selected); XCTAssertFalse(modes.mirror.selected)
        XCTAssertFalse(modes.extend.enabled); XCTAssertFalse(modes.mirror.enabled)
        XCTAssertNil(modes.extend.targetId); XCTAssertNil(modes.mirror.targetId)
        XCTAssertEqual(modes.explanation, "Update ScreenCasting on the PC to change Extend or Mirror.")
    }

    func testSharedShellHasOneCycleActionAndFixedSectionOrderForAllSizes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertEqual(panel.components(separatedBy: ".accessibilityIdentifier(\"session.switch-screen\")").count - 1, 1)
        XCTAssertFalse(panel.contains("tileView("))
        let sections = try XCTUnwrap(panel.components(separatedBy: "private var panelSections:").last?
            .components(separatedBy: "private var panelHeader:").first)
        var previous = sections.startIndex
        for name in ["screens(picker)", "connectionPicker", "castingControl", "tools", "touchSection", "remoteActions"] {
            let range = try XCTUnwrap(sections.range(of: name))
            XCTAssertGreaterThanOrEqual(range.lowerBound, previous)
            previous = range.upperBound
        }
        XCTAssertTrue(panel.contains("min(420, proxy.size.width - 24)"))
        XCTAssertTrue(panel.contains("footer(session)"))
        XCTAssertFalse(panel.contains("minimumScaleFactor"))
    }

    func testPerformanceAppearsOnceAndUsesMeasuredPillHeightWithoutChangingMetrics() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/ContentView.swift"), encoding: .utf8)
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("if isHudVisible && !isSessionPanelOpen"))
        XCTAssertTrue(content.contains("performance: isHudVisible ? SessionPerformanceReadout"))
        XCTAssertTrue(content.contains("sessionPillHeight + 24"))
        XCTAssertTrue(panel.contains("if let performance { performance }"))
        XCTAssertTrue(panel.contains("metric(\"Frame receive\""))
        XCTAssertTrue(panel.contains("metric(\"Video RX\""))
    }

    func testLegacyKeyboardRemainsAvailableWithoutScanNegotiation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("!remoteInput.usesScanKeyboard || remoteInput.keyboardEnabled"))
    }

    func testMissingLegacyCurrentNeverClaimsToStillShowAStaleScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("Couldn't switch screens. Choose a screen to restore the picture."))
        XCTAssertFalse(panel.contains("?.label ?? \"the current screen\""))
    }
    func testPermissionRequestExplainsPCApprovalPopup() {
        XCTAssertEqual(CastingPermissionCopy.requestSent, "Request sent. Approve it in the pop-up on the PC.")
    }
    func testExplicitSessionKindTitleAndRouteDoNotDependOnControl() {
        for control in [ScreenPickerSnapshot.Control.on, .viewOnly, .unavailable] {
            let extended = SessionPanelSnapshot.make(hostLabel: nil, transport: "Wi-Fi", connection: .streaming,
                control: control, mirrorLabel: nil, kind: .castingExtend)
            XCTAssertEqual(extended.title, "Extend iPad")
            XCTAssertEqual(extended.control, control)
            XCTAssertFalse(extended.isMirror)
            XCTAssertEqual(extended.icon, .extended)
            let mirror = SessionPanelSnapshot.make(hostLabel: nil, transport: "USB-C", connection: .streaming,
                control: control, mirrorLabel: "Screen 1", kind: .castingMirror)
            XCTAssertEqual(mirror.title, "Screen 1")
            XCTAssertEqual(mirror.transport, "USB")
            XCTAssertTrue(mirror.isMirror)
            let remote = SessionPanelSnapshot.make(hostLabel: nil, transport: "Wi-Fi", connection: .streaming,
                control: control, mirrorLabel: "Screen 1", kind: .wholePCRemote, tailnet: true)
            XCTAssertEqual(remote.title, "Screen 1")
            XCTAssertEqual(remote.transport, "Tailnet")
            XCTAssertFalse(remote.isMirror)
        }
    }

    func testSessionKindUsesAuthoritativeTargetAndLegacyMode() {
        var targets = CaptureTargetState(); targets.begin(generation: 7)
        let legacy = MirrorControlState(revision: 1, epoch: 1, source: 0, mode: .virtualDisplay,
            token: MirrorToken(low: 0, high: 0), geometry: nil, firstFrame: nil, lastSent: nil)
        XCTAssertEqual(SessionPanelKind.make(remote: false, targets: targets, legacy: legacy, catalogue: nil), .castingExtend)
        _ = targets.advertise(flags: 0x7c00, generation: 7)
        XCTAssertEqual(SessionPanelKind.make(remote: false, targets: targets, legacy: legacy, catalogue: nil), .castingUnknown)
        _ = targets.receiveCatalogue(CaptureTargetCatalogue(state: 1, allowed: false, owner: 2, revision: 1,
            currentId: 4, epoch: 5, entries: [CaptureTargetEntry(id: 4, kind: .physical, name: "Screen 1")]), session: targets.session)
        XCTAssertEqual(SessionPanelKind.make(remote: false, targets: targets, legacy: legacy, catalogue: nil), .castingMirror)
        XCTAssertEqual(SessionPanelKind.make(remote: true, targets: targets, legacy: legacy, catalogue: nil), .wholePCRemote)
    }

    func testNoCurrentScreenNeverFallsBackToAnOldScreenOrHost() {
        for kind in [SessionPanelKind.wholePCRemote, .castingMirror, .castingUnknown] {
            let s = SessionPanelSnapshot.make(hostLabel: nil, transport: "Connected to PC", connection: .streaming,
                control: .unavailable, mirrorLabel: nil, kind: kind)
            XCTAssertEqual(s.title, "Choose a screen")
            XCTAssertEqual(s.hostLabel, "Your PC")
            XCTAssertEqual(s.transport, kind == .wholePCRemote ? "Network" : nil)
        }
    }

    func testReconnectingSaysSo() {
        let s = SessionPanelSnapshot.make(hostLabel: nil, transport: "Wi-Fi", connection: .connecting,
            control: .unavailable, mirrorLabel: nil, kind: .castingUnknown)
        XCTAssertTrue(s.reconnecting)
        XCTAssertEqual(s.reconnectingText, "Reconnecting to Your PC\u{2026}")
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
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "", lastWifi: "Previous PC", usb: false), "Previous PC")
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "Current PC", lastWifi: "Previous PC", usb: false), "Current PC")
        XCTAssertEqual(SessionPanelSnapshot.sessionHost(current: "", lastWifi: "Previous PC", usb: true), "",
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
