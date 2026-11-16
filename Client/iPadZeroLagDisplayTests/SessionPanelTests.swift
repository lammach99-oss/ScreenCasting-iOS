import XCTest
import UIKit
import SwiftUI
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

    func testTouchChoicesNeverPresentUnsupportedDirectAsSelected() {
        let unsupported = RemoteTouchPresentation(mode: .direct, canPoint: true, canDirect: false)
        XCTAssertFalse(unsupported.directSelected)
        XCTAssertFalse(unsupported.enabled(.direct))
        XCTAssertTrue(unsupported.enabled(.trackpad))
        let denied = RemoteTouchPresentation(mode: .trackpad, canPoint: false, canDirect: true)
        XCTAssertFalse(denied.enabled(.direct))
        XCTAssertFalse(denied.enabled(.trackpad))
        XCTAssertTrue(RemoteTouchPresentation(mode: .direct, canPoint: true, canDirect: true).directSelected)
        XCTAssertEqual(unsupported.helper, "Direct sends Windows touch. Trackpad moves the PC mouse pointer.")
    }

    func testSharedInputControlsAreNotGatedOnRemoteNegotiation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        let touch = try XCTUnwrap(panel.components(separatedBy: "private var touchSection:").last?
            .components(separatedBy: "private var connectionPicker:").first)
        XCTAssertTrue(touch.contains("RemoteMouseControls()"))
        XCTAssertTrue(touch.contains("AccessiblePointerControls()"))
        XCTAssertTrue(touch.contains("RemoteMouseExtras()"))
        XCTAssertTrue(touch.contains("Scroll inertia"))
        XCTAssertTrue(touch.contains("Reverse scroll direction"))
        XCTAssertFalse(touch.contains("usesEnhancedPointer"))
        XCTAssertFalse(touch.contains("usesScanKeyboard"))
        XCTAssertFalse(panel.contains("emitKey("))
        XCTAssertTrue(panel.contains("inputSession.showSoftwareKeyboard()"))
        XCTAssertTrue(panel.contains("SessionInputBar("))
    }

    func testUnavailableDirectPrefersTheSessionsSpecificExplanation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controls = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/RemoteControl/RemoteMouseControls.swift"), encoding: .utf8)
        XCTAssertTrue(controls.contains("if !inputSession.canDirect && inputSession.unavailableReason == nil"))
        XCTAssertTrue(controls.contains("inputSession.unavailableReason ?? RemoteTouchPresentation.directUnavailable"))
    }

    func testActionsReflowByAvailableWidthAndAccessibilityTextSize() {
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 388, idealWidths: [100, 110, 90], accessibility: false), 3)
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 288, idealWidths: [100, 110, 90], accessibility: false), 2)
        XCTAssertEqual(SessionPanelLayout.actionColumns(width: 200, idealWidths: [100, 110, 90], accessibility: false), 1)
        for width in [Double(288), 388] {
            XCTAssertEqual(SessionPanelLayout.actionColumns(width: width, idealWidths: [100, 110, 90], accessibility: true), 1)
        }
    }

    func testGestureHelpDescribesSharedModesWithoutPromisingPenPressure() {
        for mode in [IPadTouchMode.trackpad, .direct] {
            let guide = GestureGuideContent.items(for: .input(mode))
            XCTAssertTrue(guide.contains { $0.gesture == "Double-tap then move" })
            XCTAssertTrue(guide.contains { $0.gesture == "Two-finger pan" && $0.result.contains("wheel") })
            XCTAssertTrue(guide.contains { $0.gesture == "Two-finger tap" && $0.result.contains("Right click") })
            XCTAssertTrue(guide.contains { $0.gesture == "Pinch" && $0.result.contains("Ctrl-wheel") })
            XCTAssertTrue(GestureGuideContent.pencil(for: .input(mode)).contains("No Windows pen, pressure or tilt"))
        }
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
        XCTAssertTrue(panel.contains("Frame receive, "))
        XCTAssertTrue(panel.contains("Video RX, "))
    }

    func testTelemetryFormatsEachFieldWithAtMostOneDecimal() {
        let normal = SessionTelemetryPresentation(fps: 112.0, frameReceiveMs: 6, videoRxMbps: 151.4)
        XCTAssertEqual(normal.fpsValue, "112")
        XCTAssertEqual(normal.frameReceiveValue, "6.0")
        XCTAssertEqual(normal.videoRxValue, "151.4")
        XCTAssertEqual(normal.visibleText, "112 FPS  6.0 ms  151.4 Mbps")
        XCTAssertEqual(SessionTelemetryPresentation(fps: 8.36, frameReceiveMs: 6.26, videoRxMbps: 9.96).visibleText,
                       "8.4 FPS  6.3 ms  10.0 Mbps")
        XCTAssertEqual(SessionTelemetryPresentation(fps: 9.99, frameReceiveMs: 1, videoRxMbps: 1).fpsValue, "10")
        XCTAssertEqual(SessionTelemetryPresentation(fps: 59.8, frameReceiveMs: 1, videoRxMbps: 1).fpsValue, "60")
    }

    func testTelemetryIdleAndInvalidValuesNeverPresentUnavailableTimingAsZero() {
        let idle = SessionTelemetryPresentation(fps: 0, frameReceiveMs: 0, videoRxMbps: 0)
        XCTAssertTrue(idle.isIdle)
        XCTAssertEqual(idle.visibleText, "0 FPS  - ms  0.0 Mbps")
        XCTAssertEqual(SessionTelemetryPresentation(fps: 0, frameReceiveMs: 6, videoRxMbps: 0).frameReceiveValue, "-")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let values = SessionTelemetryPresentation(fps: invalid, frameReceiveMs: invalid, videoRxMbps: invalid)
            XCTAssertEqual(values.visibleText, "- FPS  - ms  - Mbps")
            XCTAssertTrue(values.isIdle)
            XCTAssertEqual(SessionTelemetryPresentation(fps: 112, frameReceiveMs: invalid,
                videoRxMbps: 151.4).frameReceiveValue, "-")
        }
        XCTAssertEqual(SessionTelemetryPresentation(fps: 112, frameReceiveMs: 0, videoRxMbps: 151.4).frameReceiveValue, "-")
    }

    func testTelemetryAccessibilityUsesFullMetricNamesAndUnavailableWording() {
        XCTAssertEqual(SessionTelemetryPresentation(fps: 112, frameReceiveMs: 6, videoRxMbps: 151.4).accessibilityLabel,
            "112 frames per second. Frame receive, 6.0 milliseconds. Video RX, 151.4 megabits per second.")
        XCTAssertEqual(SessionTelemetryPresentation(fps: 0, frameReceiveMs: 0, videoRxMbps: 0).accessibilityLabel,
            "0 frames per second. Frame receive, unavailable. Video RX, 0.0 megabits per second.")
    }

    func testTelemetryOverflowStaysWithinItsFixedNumberFields() {
        let huge = SessionTelemetryPresentation(fps: 1200, frameReceiveMs: 1200, videoRxMbps: 12000)
        XCTAssertEqual(huge.visibleText, "999+ FPS  999.9+ ms  9999.9+ Mbps")
        XCTAssertEqual(SessionTelemetryPresentation(fps: .greatestFiniteMagnitude,
            frameReceiveMs: .greatestFiniteMagnitude, videoRxMbps: .greatestFiniteMagnitude), huge)
    }

    @MainActor func testTelemetryIntrinsicSizeDoesNotShiftWithValuesAndDynamicTypeIsCapped() {
        var cappedSizes: [CGSize] = []
        for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            var sizes: [CGSize] = []
            for (fps, ms, mbps) in [(0.0, 0.0, 0.0), (9.9, 9.9, 9.9), (112, 6, 151.4), (1200, 1200, 12000)] {
                let controller = UIHostingController(rootView: SessionPerformanceReadout(fps: fps,
                    frameReceiveMs: ms, videoRxMbps: mbps).environment(\.dynamicTypeSize, typeSize))
                sizes.append(controller.sizeThatFits(in: CGSize(width: 500, height: 100)))
            }
            for size in sizes.dropFirst() {
                XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
                XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5)
            }
            XCTAssertLessThan(sizes[0].height, 32, "One compact line even at accessibility sizes")
            if typeSize != .large { cappedSizes.append(sizes[0]) }
        }
        XCTAssertEqual(cappedSizes[0].width, cappedSizes[1].width, accuracy: 0.5)
        XCTAssertEqual(cappedSizes[0].height, cappedSizes[1].height, accuracy: 0.5)
    }

    func testTelemetryHasNoPanelDecorationAndNeverInterceptsInput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/ContentView.swift"), encoding: .utf8)
        let readout = try XCTUnwrap(panel.components(separatedBy: "struct SessionPerformanceReadout: View").last?
            .components(separatedBy: "private struct SessionPillHeightKey:").first)
        XCTAssertTrue(readout.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(readout.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
        XCTAssertTrue(readout.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertFalse(readout.contains("RoundedRectangle")); XCTAssertFalse(readout.contains("Capsule"))
        XCTAssertFalse(readout.contains("Divider")); XCTAssertFalse(readout.contains("Image("))
        XCTAssertTrue(readout.contains("if contrast == .increased"))
        let hud = try XCTUnwrap(content.components(separatedBy: "private var streamingHUD:").last)
        XCTAssertFalse(hud.contains(".background(")); XCTAssertFalse(hud.contains(".overlay("))
        XCTAssertTrue(hud.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(hud.contains("presentationGeometry?.safeAreaInsets"))
    }

    func testKeyboardAvailabilityComesFromSharedSessionWithoutScanNegotiation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        let tools = try XCTUnwrap(panel.components(separatedBy: "private var tools:").last?
            .components(separatedBy: "private var touchSection:").first)
        XCTAssertTrue(tools.contains("let canType = inputSession.canType"))
        XCTAssertFalse(tools.contains("usesScanKeyboard"))
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

extension SessionPanelTests {
    func testExtendWithoutMirrorGeometryShowsControlAndEnablesKeyboard() {
        let extend = MirrorControlState(revision: 1, epoch: 1, source: 0, mode: .virtualDisplay,
            token: MirrorToken(low: 0, high: 0), geometry: nil, firstFrame: nil, lastSent: nil)
        let legacy = ScreenPickerSnapshot.make(catalogue: nil, state: extend, switchingTo: nil,
            switchPending: false, pickerSupported: false, permissionAsked: false)
        let typed = ScreenPickerSnapshot.make(captureTargets: CaptureTargetState(), state: extend)
        for snapshot in [legacy, typed] {
            XCTAssertEqual(snapshot.control, .on)
            XCTAssertTrue(snapshot.canType)
        }
        let unknown = ScreenPickerSnapshot.make(catalogue: nil, state: nil, switchingTo: nil,
            switchPending: false, pickerSupported: false, permissionAsked: false)
        XCTAssertEqual(unknown.control, .unavailable)
        XCTAssertFalse(unknown.canType)
        let oldHost = ScreenPickerSnapshot.make(catalogue: nil, state: nil, switchingTo: nil,
            switchPending: false, pickerSupported: false, permissionAsked: false, legacyInputAvailable: true)
        XCTAssertEqual(oldHost.control, .on)
        XCTAssertTrue(oldHost.canType)
        var targets = CaptureTargetState(); targets.begin(generation: 7)
        _ = targets.advertise(flags: 0x7c00, generation: 7)
        let catalogue = CaptureTargetCatalogue(state: 1, allowed: true, owner: 2, revision: 1,
            currentId: 1, epoch: 5, entries: [CaptureTargetEntry(id: 1, kind: .extend, name: "Extend iPad"),
                CaptureTargetEntry(id: 4, kind: .physical, name: "Screen 1")])
        _ = targets.receiveCatalogue(catalogue, session: targets.session)
        _ = targets.select(4, catalogue: catalogue, session: targets.session)
        let pending = ScreenPickerSnapshot.make(captureTargets: targets, state: extend)
        XCTAssertEqual(pending.control, .viewOnly)
        XCTAssertFalse(pending.canType)
    }
}

extension SessionPanelTests {
    func testPencilHelpMatchesTouchAndPointerCapabilities() {
        let casting = GestureGuideContent.helper(for: .input(.direct)) + GestureGuideContent.pencil(for: .input(.direct))
        XCTAssertTrue(casting.contains("touch contact"))
        XCTAssertTrue(casting.contains("No Windows pen, pressure or tilt"))
        XCTAssertFalse(casting.contains("acts like a pen"))
        let trackpad = GestureGuideContent.pencil(for: .input(.trackpad))
        XCTAssertTrue(trackpad.contains("relative mouse"))
        XCTAssertTrue(trackpad.contains("No Windows pen, pressure or tilt"))
    }
}
