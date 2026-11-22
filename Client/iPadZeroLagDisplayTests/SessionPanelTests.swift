import XCTest
import UIKit
import SwiftUI
@testable import iPadCasting

/// The session pill is the one visible handle for every session: what it says, and how Disconnect is confirmed.
final class SessionPanelTests: XCTestCase {
    func testExpandedPillLeavesStatusToTheHeader() {
        let session = SessionPanelSnapshot.make(hostLabel: "PC", transport: "Wi-Fi", connection: .streaming,
            control: .viewOnly, mirrorLabel: "Display 2", kind: .castingMirror)
        let header = SessionHeaderPresentation(session: session, canRequestControl: true, permissionAsked: false)
        XCTAssertEqual(header.status, "Wi-Fi · View only")
        XCTAssertNil(header.pillStatus(isOpen: true))
        XCTAssertEqual(header.pillStatus(isOpen: false), header.status)
        XCTAssertEqual(header.controlAction, .ask)

        let reconnecting = SessionPanelSnapshot.make(hostLabel: "PC", transport: "Wi-Fi", connection: .connecting,
            control: .on, mirrorLabel: "Display 2", kind: .castingMirror)
        let reconnectingHeader = SessionHeaderPresentation(session: reconnecting, canRequestControl: true,
            permissionAsked: false)
        XCTAssertEqual(reconnectingHeader.status, reconnecting.reconnectingText)
        XCTAssertNil(reconnectingHeader.pillStatus(isOpen: true))
        XCTAssertNil(reconnectingHeader.controlAction)
    }

    func testControlActionRequiresARequestableCastingSession() {
        func action(_ control: ScreenPickerSnapshot.Control, kind: SessionPanelKind = .castingMirror,
                    canRequest: Bool = true, asked: Bool = false) -> SessionHeaderPresentation.ControlAction? {
            let session = SessionPanelSnapshot.make(hostLabel: "PC", transport: "Wi-Fi", connection: .streaming,
                control: control, mirrorLabel: "Display 2", kind: kind)
            return SessionHeaderPresentation(session: session, canRequestControl: canRequest,
                permissionAsked: asked).controlAction
        }
        XCTAssertEqual(action(.viewOnly), .ask)
        XCTAssertEqual(action(.on), .stop)
        XCTAssertNil(action(.viewOnly, canRequest: false))
        XCTAssertNil(action(.viewOnly, asked: true))
        XCTAssertNil(action(.unavailable))
        XCTAssertNil(action(.viewOnly, kind: .wholePCRemote))
    }

    func testPanelTelemetryRequiresIncomingFramesEvenWhenTrafficIsNonzero() {
        XCTAssertFalse(SessionTelemetryPresentation(fps: 0, frameReceiveMs: 20, videoRxMbps: 2).hasFrames)
        XCTAssertFalse(SessionTelemetryPresentation(fps: .nan, frameReceiveMs: 0, videoRxMbps: 0).hasFrames)
        XCTAssertTrue(SessionTelemetryPresentation(fps: 0.5, frameReceiveMs: 20, videoRxMbps: 2).hasFrames)
    }

    func testViewOnlyHidesKeyboardAndTouchControls() {
        let viewOnly = SessionInputPresentation(control: .viewOnly, canType: false, canPoint: false)
        XCTAssertFalse(viewOnly.showsKeyboard)
        XCTAssertFalse(viewOnly.showsTouch)
        let pointerOnly = SessionInputPresentation(control: .on, canType: false, canPoint: true)
        XCTAssertFalse(pointerOnly.showsKeyboard)
        XCTAssertTrue(pointerOnly.showsTouch)
        let controlled = SessionInputPresentation(control: .on, canType: true, canPoint: true)
        XCTAssertTrue(controlled.showsKeyboard)
        XCTAssertTrue(controlled.showsTouch)
    }

    func testSwitchScreenRowRequiresMultiplePhysicalScreensInMirror() {
        let screens: [ScreenPickerTile] = [
            .init(id: 1, label: "Display 1", isBuiltIn: false, status: .showing),
            .init(id: 2, label: "Display 2", isBuiltIn: false, status: .available)
        ]
        let extend = ScreenPickerTile(id: 3, label: "Extend iPad", isBuiltIn: false, status: .available, isExtend: true)
        let multiple = ScreenCyclePresentation.make(candidates: screens + [extend], currentId: 1, pending: false)
        let one = ScreenCyclePresentation.make(candidates: [screens[0], extend], currentId: 1, pending: false)
        let pending = ScreenCyclePresentation.make(candidates: screens, currentId: 1, pending: true)
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .castingMirror, cycle: multiple))
        XCTAssertTrue(SessionScreenPresentation.showsSwitchRow(kind: .wholePCRemote, cycle: multiple))
        XCTAssertFalse(SessionScreenPresentation.showsSwitchRow(kind: .castingExtend, cycle: multiple))
        XCTAssertFalse(SessionScreenPresentation.showsSwitchRow(kind: .castingMirror, cycle: one))
        XCTAssertFalse(SessionScreenPresentation.showsSwitchRow(kind: .castingMirror, cycle: pending))
    }

    func testConnectionShowsOneActiveRouteAndOneNextAction() throws {
        func snapshot(allowed: Bool, usb: ConnectionAvailability = .available) throws -> ConnectionSwitchState {
            var state = ConnectionSwitchState()
            state.begin(generation: 1)
            XCTAssertNotNil(state.advertise(flags: 0x0200, authenticated: true, generation: 1))
            var bytes = Array(try ConnectionSwitchStateTests.snapshot(allowed: allowed).encode())
            bytes[3] = usb == .available ? ConnectionRoute.usb.rawValue : ConnectionRoute.unknown.rawValue
            bytes[5] = usb.rawValue
            let reason: ConnectionReason = usb == .detectedUnverified ? .deviceUnverified
                : usb == .unknown ? .notChecked : .none
            MirrorControlCodec.put(UInt64(reason.rawValue), &bytes, 38, 2)
            XCTAssertTrue(state.receive(try ConnectionControlState.decode(Data(bytes)), generation: 1, now: 0))
            return state
        }
        func presentation(_ state: ConnectionSwitchState, route: ConnectionRoute? = .wifi,
                          hasWifiEndpoint: Bool = true) -> SessionConnectionPresentation {
            SessionConnectionPresentation(state: state, streamingRoute: route, hasWifiEndpoint: hasWifiEndpoint)
        }
        var allowed = try snapshot(allowed: true)
        XCTAssertEqual(presentation(allowed).activeRoute, .wifi)
        XCTAssertEqual(presentation(allowed).action?.title, "Switch to USB (faster)")
        let detected = try snapshot(allowed: true, usb: .detectedUnverified)
        XCTAssertEqual(presentation(detected).action?.title, "Switch to USB")
        let requestable = try snapshot(allowed: false)
        XCTAssertEqual(presentation(requestable).action?.title, "Ask PC to switch to USB")
        XCTAssertNil(presentation(try snapshot(allowed: false, usb: .unknown)).action)

        XCTAssertNotNil(allowed.select(.usb, now: 0))
        XCTAssertEqual(presentation(allowed).activeRoute, .wifi)
        XCTAssertEqual(presentation(allowed).action, .waiting(allowed.message, showsProgress: true))
        allowed.cancel(reason: .connectionLost)
        XCTAssertNil(presentation(allowed, route: nil).activeRoute)
        XCTAssertEqual(presentation(allowed, route: nil).action?.title, "Reconnect over Wi-Fi")
        XCTAssertNil(presentation(allowed, route: nil, hasWifiEndpoint: false).action)

        var stale = try snapshot(allowed: true)
        stale.tick(now: ConnectionControlProtocol.lease + 1)
        XCTAssertEqual(presentation(stale).action?.title, "Refresh connection status")
        XCTAssertEqual(presentation(ConnectionSwitchState(), route: .usb).activeRoute, .usb)
        XCTAssertNil(presentation(ConnectionSwitchState(), route: .usb).action)
    }

    func testDeclinedRouteOutcomeSurvivesReadyPublicationAndKeepsNextAction() throws {
        var state = ConnectionSwitchState()
        state.begin(generation: 1)
        _ = state.advertise(flags: ConnectionControlProtocol.advertisementFlag, authenticated: true, generation: 1)
        XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.snapshot(), generation: 1, now: 0))
        XCTAssertNotNil(state.select(.usb, now: 0))
        XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.snapshot(revision: 3), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.result(.denied, reason: .permissionDenied), generation: 1, now: 1))
        XCTAssertTrue(state.receive(try ConnectionSwitchStateTests.snapshot(revision: 4), generation: 1, now: 2))
        let panel = SessionConnectionPresentation(state: state, streamingRoute: .wifi, hasWifiEndpoint: true)
        XCTAssertEqual(panel.outcome, ConnectionReason.permissionDenied.text(target: .usb))
        XCTAssertNotNil(panel.action)
        let switchingScreen = SessionConnectionPresentation(state: state, streamingRoute: .wifi,
            hasWifiEndpoint: true, screenSwitchInProgress: true)
        XCTAssertEqual(switchingScreen.action, .waiting("Wait for the screen switch to finish.", showsProgress: false))
    }

    @MainActor func testFaultedSourceOffersRestartGuidanceInsteadOfRefresh() throws {
        var targets = CaptureTargetState()
        targets.begin(generation: 1)
        _ = targets.advertise(flags: CaptureTargetProtocol.advertisementFlag, generation: 1)
        var bytes = Array(CaptureTargetIntegrationTests.catalogue(revision: 3, current: 0, allowed: false))
        bytes[1] = 3
        XCTAssertTrue(targets.receiveCatalogue(try CaptureTargetCatalogue.decode(Data(bytes)), session: targets.session))
        let notice = try XCTUnwrap(SessionPanelOverlay.ScreenNotice.typedCatalogueNotice(for: targets))
        XCTAssertTrue(notice.message.contains("Stop and restart the session."))
        XCTAssertNil(notice.action)

        targets.begin(generation: 2)
        _ = targets.advertise(flags: CaptureTargetProtocol.advertisementFlag, generation: 2)
        targets.markListUnavailable(session: targets.session)
        let unavailable = try XCTUnwrap(SessionPanelOverlay.ScreenNotice.typedCatalogueNotice(for: targets))
        XCTAssertEqual(unavailable.action, .refresh)
    }

    func testFooterLeavesGestureHelpInsideMoreInput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"),
            encoding: .utf8)
        let footer = try XCTUnwrap(source.components(separatedBy: "struct PanelFooter: View").last?
            .components(separatedBy: "struct PanelActionButton: View").first)
        XCTAssertTrue(footer.contains("\"Disconnect\""))
        XCTAssertFalse(footer.contains("Gestures"))
        let moreInput = try XCTUnwrap(source.components(separatedBy: "struct MoreInputSection: View").last?
            .components(separatedBy: "struct ConnectionSection: View").first)
        XCTAssertTrue(moreInput.contains("\"Gesture help\""))
    }

    func testExtractedCallbacksUseTheirActualOwnerAndLocalIcon() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iPadZeroLagDisplay")
        let content = try String(contentsOf: app.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let panel = try String(contentsOf: app.appendingPathComponent("SessionPanelOverlay.swift"), encoding: .utf8)
        let video = try XCTUnwrap(content.components(separatedBy: "struct ConnectedVideoSurface: View").last?
            .components(separatedBy: "struct DisconnectedDashboard:").first)
        XCTAssertTrue(video.contains("owner.isSessionPanelOpen = true"))
        XCTAssertFalse(video.contains("\n                        isSessionPanelOpen = true"))
        let action = try XCTUnwrap(panel.components(separatedBy: "struct PanelActionButton: View").last?
            .components(separatedBy: "struct RouteAndControl:").first)
        XCTAssertTrue(action.contains("Image(systemName: icon)"))
        XCTAssertFalse(action.contains("Image(systemName: owner.icon)"))
    }

    @MainActor func testPanelBlocksSurfaceHardwareDelegatesToUIKitAndDoesNotReplayHeldKeys() {
        var now: TimeInterval = 0
        let session = IPadInputSession(clock: { now }, automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        session.configure(identity: "panel", point: true, type: true, direct: true, zoom: true,
                          reason: nil, sink: { events.append($0) })
        let view = PencilUIKitView(frame: .zero); view.inputSession = session
        XCTAssertTrue(view.handleHardwareKey(.keyboardA, action: .keyDown))
        session.panelPresentationChanged(true)
        XCTAssertEqual(events.last, .key(4, 1)); events.removeAll()
        XCTAssertFalse(view.handleHardwareKey(.keyboardB, action: .keyDown))
        XCTAssertTrue(events.isEmpty)
        session.tapKey(hidUsage: 0x50) // Intentional on-screen actions still work.
        XCTAssertEqual(events, [.key(0x50, 0), .key(0x50, 1)]); events.removeAll()
        now = 10; session.panelPresentationChanged(false)
        XCTAssertTrue(view.handleHardwareKey(.keyboardA, action: .keyDown))
        XCTAssertTrue(view.handleHardwareKey(.keyboardB, action: .keyDown))
        XCTAssertTrue(events.isEmpty, "Held/repeating keys cannot cross the panel boundary")
        _ = view.handleHardwareKey(.keyboardA, action: .keyUp)
        _ = view.handleHardwareKey(.keyboardB, action: .keyUp)
        _ = view.handleHardwareKey(.keyboardA, action: .keyDown)
        _ = view.handleHardwareKey(.keyboardA, action: .keyUp)
        XCTAssertEqual(events, [.key(4, 0), .key(4, 1)])
        session.panelPresentationChanged(true)
        session.panelPresentationChanged(false, surfaceActive: false)
        XCTAssertFalse(view.handleHardwareKey(.keyboardC, action: .keyDown), "A sheet/guide still owns input")
    }

    @MainActor func testPanelClosePreservesDragArmedOrLatchedInsidePanel() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            for latched in [false, true] {
                let session = IPadInputSession(clock: { 0 }, automaticallyTicks: false)
                var events: [IPadInputEvent] = []
                session.configure(identity: "panel", point: true, type: true, direct: true, zoom: true,
                                  reason: nil, sink: { events.append($0) })
                session.engine.mode = mode
                session.panelPresentationChanged(true); session.beginDrag()
                if latched { session.click(.left); session.moveAccessibleTarget(.right, coarse: true) }
                XCTAssertEqual(session.dragState, latched ? .latched : .armed)
                let before = events
                session.panelPresentationChanged(false)
                XCTAssertEqual(session.dragState, latched ? .latched : .armed)
                XCTAssertEqual(events, before)
                session.releaseAll(); XCTAssertEqual(session.dragState, .idle)
            }
        }
    }

    @MainActor func testPanelOpeningRetiresPointerBeforePhysicalModifier() {
        let session = IPadInputSession(clock: { 0 }, automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        session.configure(identity: "panel", point: true, type: true, direct: true, zoom: true,
                          reason: nil, sink: { events.append($0) })
        session.engine.mode = .direct
        session.engine.hardware(usage: 0xe0, down: true)
        session.engine.begin(id: 1, pencil: false, point: .zero, normalized: .zero)
        events.removeAll()
        session.panelPresentationChanged(true)
        XCTAssertEqual(events, [.touch(.cancel, 1, .zero, 255), .key(0xe0, 1)])
        session.panelPresentationChanged(false)
        events.removeAll()
        session.engine.hardware(usage: 0xe0, down: true)
        XCTAssertTrue(events.isEmpty, "A held modifier cannot replay across the panel boundary")
        session.engine.hardware(usage: 0xe0, down: false)
        session.engine.hardware(usage: 0xe0, down: true)
        XCTAssertEqual(events, [.key(0xe0, 0)])
    }

    func testOnlyActiveResumeAvoidsRemoteConfigurationRetirement() {
        let paused = RemoteSessionInputConfiguration(remote: true, connected: true, active: false,
            generation: 1, features: 0x1f, context: nil, ready: true, revision: 1)
        let resumed = RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: 1, features: 0x1f, context: nil, ready: true, revision: 1)
        XCTAssertFalse(resumed.requiresRetirement(comparedTo: paused))
        XCTAssertTrue(paused.requiresRetirement(comparedTo: resumed))
        let replaced = RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: 2, features: 0x1f, context: nil, ready: true, revision: 1)
        XCTAssertTrue(replaced.requiresRetirement(comparedTo: paused))
    }
    func testPanelBuildersHaveBoundedMetadataComposition() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("iPadZeroLagDisplay")
        let files = ["SessionPanelOverlay.swift", "SessionInputBar.swift", "GestureHelp.swift",
                     "AccessiblePointerControls.swift", "RemoteControl/RemoteMouseControls.swift",
                     "RemoteControl/RemoteSpecialKeyBar.swift", "ContentView.swift", "SettingsView.swift",
                     "DataTransfer/TransferCenterSheet.swift"]
        let builder = try NSRegularExpression(pattern: #"(?:var\s+\w+\s*:\s*some View|func\s+\w+\s*\([^{}]*?\)\s*->\s*some View)\s*\{"#)
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("AnyView("), file)
            for match in builder.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let range = try XCTUnwrap(Range(match.range, in: text))
                let start = range.upperBound
                var cursor = start, depth = 1
                while cursor < text.endIndex && depth > 0 {
                    if text[cursor] == "{" { depth += 1 }
                    if text[cursor] == "}" { depth -= 1 }
                    cursor = text.index(after: cursor)
                }
                let lines = text[start..<cursor].split(separator: "\n").filter {
                    let line = $0.trimmingCharacters(in: .whitespaces)
                    return !line.isEmpty && !line.hasPrefix("//")
                }.count - 1 // Exclude the builder's closing brace.
                XCTAssertLessThanOrEqual(lines, 75, "\(file): \(text[range]) - extract a concrete View")
            }
        }
        let panel = try String(contentsOf: app.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(panel.contains("-> PanelContent"))
        XCTAssertTrue(panel.contains("var panelSections: PanelSections"))
        for section in ["PanelContent", "PanelSections", "ScreenSection", "ConnectionSection",
                        "CastingControlSection", "ToolsSection", "TouchSection", "MoreInputSection",
                        "RemoteActionsSection", "PanelHeader", "PanelFooter", "OverlaySurface"] {
            XCTAssertTrue(panel.contains("struct \(section): View"), section)
        }
    }

    #if targetEnvironment(simulator)
    @MainActor func testThreeFingerPanelCallbackCanRetireInputReentrantly() {
        var now: TimeInterval = 0
        let input = IPadInputSession(clock: { now }, automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        input.configure(identity: "panel", point: true, type: true, direct: true, zoom: true,
                        reason: nil, sink: { events.append($0) })
        input.engine.mode = .direct
        input.engine.hardware(usage: 0xe1, down: true)
        var opened = 0
        input.engine.openSettings = {
            opened += 1
            input.releaseAll() // Same synchronous retirement as ContentView's panel onChange.
        }
        for id in UInt64(1)...UInt64(3) {
            now += 0.01
            input.engine.begin(id: id, pencil: false, point: CGPoint(x: CGFloat(id) * 20, y: 20),
                               normalized: CGPoint(x: 0.5, y: 0.5))
        }
        for id in UInt64(1)...UInt64(3) {
            now += 0.01
            input.engine.end(id: id, point: CGPoint(x: CGFloat(id) * 20, y: 20),
                             normalized: CGPoint(x: 0.5, y: 0.5), cancelled: false)
        }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(events.filter { $0 == .key(0xe1, 1) }.count, 1)
        XCTAssertEqual(events.filter { if case .touch(.cancel, _, _, _) = $0 { return true }; return false }.count, 1)
        let retired = events
        input.releaseAll()
        XCTAssertEqual(events, retired, "Panel retirement must remain idempotent")
    }

    /// Exercise the previously unopened branch, including every eagerly built input section.
    /// UIKit cannot be hosted on a background Thread with an artificially small stack.
    @MainActor func testOpenPanelMetadataInHostingWindow() async throws {
        for variant in ["extend", "mirror", "remote", "typed-extend", "typed-mirror", "unavailable"] {
            let network = NetworkManager()
            network.controlSendForAudioTesting = { _, done in done(nil) }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS,
                remote: variant == "remote")
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            if variant == "remote" {
                network.beginRemoteMonitorForTesting(acceptedFeatures: 0x1f)
            } else if variant != "unavailable" {
                network.receiveCaptureTargetWireForTesting(type: .displayCapabilities,
                    payload: CaptureTargetIntegrationTests.modes, flags: variant.hasPrefix("typed") ? 0x7c00 : 0x6000,
                    generation: peer.generation, connection: peer.connection)
                network.receiveCaptureTargetWireForTesting(type: .mirrorState,
                    payload: try CaptureTargetIntegrationTests.mode(revision: 1, epoch: 5,
                        physical: variant.contains("mirror"), active: variant.contains("mirror")),
                    generation: peer.generation, connection: peer.connection)
                if variant.hasPrefix("typed") {
                    network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue,
                        payload: CaptureTargetIntegrationTests.catalogue(revision: 3,
                            current: variant.contains("mirror") ? 4 : 1),
                        generation: peer.generation, connection: peer.connection)
                } else if variant == "mirror" {
                    // One selected physical screen in the old monitor-catalogue format.
                    network.receiveCaptureTargetWireForTesting(type: .mirrorCatalogue,
                        payload: Self.panelMirrorCatalogue(),
                        generation: peer.generation, connection: peer.connection)
                    // Production exposes the list only after this source's frame was presented.
                    let decoder = try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
                    network.recordRenderCompletion(sequence: 0, generation: decoder)
                }
            }
            await drainPanelPublications(network)
            XCTAssertEqual(network.isRemoteControlSession, variant == "remote")
            XCTAssertEqual(network.captureTargetState.enabled, variant.hasPrefix("typed"))
            let kind = SessionPanelKind.make(remote: network.isRemoteControlSession,
                targets: network.captureTargetState, legacy: network.mirrorControlState,
                catalogue: network.mirrorMonitorCatalogue)
            let expected: SessionPanelKind = variant == "unavailable" ? .castingUnknown
                : (variant == "remote" ? .wholePCRemote : (variant.contains("mirror") ? .castingMirror : .castingExtend))
            XCTAssertEqual(kind, expected, variant)
            let input = IPadInputSession(automaticallyTicks: false)
            input.configure(identity: variant, point: variant != "unavailable", type: variant != "unavailable",
                            direct: variant != "unavailable", zoom: true,
                            reason: variant == "unavailable" ? "Control unavailable" : nil, sink: { _ in })
            for size in [DynamicTypeSize.large, .accessibility5] {
                for voiceOver in [false, true] {
                    let panel = SessionPanelOverlay(networkManager: network, hostLabel: "PC", isOpen: .constant(true),
                        remoteInput: RemoteSessionInputState(), tailnetTarget: false, performance: nil,
                        onPillHeightChange: { _ in }, onFiles: {}, onSettings: {}, onGestures: {})
                        .expandedInputForTesting(voiceOver: voiceOver)
                        .environmentObject(input)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.accessibilityEnabled, voiceOver)
                    assertHostedInWindow(panel, context: variant)
                    assertHostedInWindow(SessionInputBar(onClose: {}, expandedSections: true)
                        .environmentObject(input).environment(\.dynamicTypeSize, size)
                        .environment(\.accessibilityEnabled, voiceOver), context: "input " + variant)
                }
            }
        }
    }

    @MainActor func testMirrorPanelKindRequiresTheMatchingPresentationReceipt() async throws {
        let network = NetworkManager()
        network.controlSendForAudioTesting = { _, done in done(nil) }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities,
            payload: CaptureTargetIntegrationTests.modes, flags: 0x6000,
            generation: peer.generation, connection: peer.connection)
        network.receiveCaptureTargetWireForTesting(type: .mirrorState,
            payload: try CaptureTargetIntegrationTests.mode(revision: 1, epoch: 5, physical: true, active: true),
            generation: peer.generation, connection: peer.connection)
        network.receiveCaptureTargetWireForTesting(type: .mirrorCatalogue, payload: Self.panelMirrorCatalogue(),
            generation: peer.generation, connection: peer.connection)
        await drainPanelPublications(network)
        XCTAssertNil(network.mirrorMonitorCatalogue, "A catalogue alone cannot claim a presented source")
        func kind() -> SessionPanelKind {
            SessionPanelKind.make(remote: network.isRemoteControlSession, targets: network.captureTargetState,
                legacy: network.mirrorControlState, catalogue: network.mirrorMonitorCatalogue)
        }
        XCTAssertEqual(kind(), .castingUnknown)
        let decoder = try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        network.recordRenderCompletion(sequence: 0, generation: decoder &+ 1)
        await drainPanelPublications(network)
        XCTAssertEqual(kind(), .castingUnknown, "A different decoder cannot publish this catalogue")
        network.recordRenderCompletion(sequence: 0, generation: decoder)
        await drainPanelPublications(network)
        XCTAssertEqual(kind(), .castingMirror)
        XCTAssertEqual(network.mirrorMonitorCatalogue?.selected, 6)
    }

    @MainActor func testRemotePanelRoleComesFromConnectionBeforeFeaturesOrHosting() async {
        let network = NetworkManager()
        network.controlSendForAudioTesting = { _, done in done(nil) }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        defer { network.stopForTesting() }
        await drainPanelPublications(network)
        XCTAssertTrue(network.isRemoteControlSession)
        XCTAssertEqual(SessionPanelKind.make(remote: network.isRemoteControlSession, targets: network.captureTargetState,
            legacy: network.mirrorControlState, catalogue: network.mirrorMonitorCatalogue), .wholePCRemote)
    }

    private static func panelMirrorCatalogue() -> Data {
        var bytes = [UInt8](repeating: 0, count: 30)
        bytes[0] = 1; bytes[1] = 1; bytes[2] = 1
        MirrorControlCodec.put(1, &bytes, 4, 8)
        MirrorControlCodec.put(6, &bytes, 12, 8)
        MirrorControlCodec.put(6, &bytes, 20, 8)
        bytes[28] = 6
        return Data(bytes + Array("Screen".utf8))
    }

    @MainActor private func drainPanelPublications(_ network: NetworkManager) async {
        // All fixture operations enqueue their publications before this network-to-main barrier.
        // A continuation waits for those actual queues, not a guessed number of run-loop turns.
        let queue = network.networkQueueForTesting
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @MainActor private func assertHostedInWindow<V: View>(_ root: V, context: String,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        let controller = UIHostingController(rootView: root)
        let container = PanelHostingContainer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = container
        window.isHidden = false
        container.view.frame = window.bounds
        container.addChild(controller)
        controller.beginAppearanceTransition(true, animated: false)
        container.view.addSubview(controller.view)
        controller.view.frame = window.bounds
        controller.didMove(toParent: container)
        controller.endAppearanceTransition()
        defer {
            controller.willMove(toParent: nil)
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            controller.endAppearanceTransition()
            controller.removeFromParent()
            window.isHidden = true; window.rootViewController = nil
        }
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let size = controller.sizeThatFits(in: window.bounds.size)
        XCTAssertTrue(size.width.isFinite && size.height.isFinite, context, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, context, file: file, line: line)
        XCTAssertTrue(controller.view.window === window, context, file: file, line: line)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { renderer in
            window.layer.render(in: renderer.cgContext)
        }
        XCTAssertEqual(image.cgImage?.width, 834, context, file: file, line: line)
        XCTAssertEqual(image.cgImage?.height, 1194, context, file: file, line: line)
    }
    #endif

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
        let touch = try XCTUnwrap(panel.components(separatedBy: "struct TouchSection: View").last?
            .components(separatedBy: "struct ConnectionSection: View").first)
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

    func testUnavailableDirectIsHiddenAndAvailableModesKeepTheirHints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controls = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/RemoteControl/RemoteMouseControls.swift"), encoding: .utf8)
        XCTAssertTrue(controls.contains("if presentation.enabled(.direct)"))
        XCTAssertTrue(controls.contains("inputSession.unavailableReason ?? RemoteTouchPresentation.directUnavailable"))
        XCTAssertTrue(controls.contains(": presentation.helper"))
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
        let sections = try XCTUnwrap(panel.components(separatedBy: "struct PanelSections: View").last?
            .components(separatedBy: "struct PanelHeader: View").first)
        var previous = sections.startIndex
        for name in ["owner.screens", "connectionPicker", "tools", "touchSection", "remoteActions"] {
            let range = try XCTUnwrap(sections.range(of: name))
            XCTAssertGreaterThanOrEqual(range.lowerBound, previous)
            previous = range.upperBound
        }
        XCTAssertTrue(panel.contains("min(420, proxy.size.width - 24)"))
        XCTAssertTrue(panel.contains("footer(owner.session)"))
        XCTAssertFalse(panel.contains("minimumScaleFactor"))
    }

    func testPerformanceAppearsOnceAndUsesMeasuredPillHeightWithoutChangingMetrics() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/ContentView.swift"), encoding: .utf8)
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("if isHudVisible && !isSessionPanelOpen"))
        XCTAssertTrue(content.contains("performance: owner.isHudVisible ? SessionPerformanceReadout"))
        XCTAssertTrue(content.contains("sessionPillHeight + 24"))
        XCTAssertTrue(panel.contains("if let performance = owner.performance, performance.showsInPanel { performance }"))
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
        let hud = try XCTUnwrap(content.components(separatedBy: "private var streamingHUD:").last?
            .components(separatedBy: "@MainActor private struct AuthenticationOverlay").first)
        XCTAssertFalse(hud.contains(".background(")); XCTAssertFalse(hud.contains(".overlay("))
        XCTAssertTrue(hud.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(hud.contains("presentationGeometry?.safeAreaInsets"))
    }

    func testKeyboardAvailabilityComesFromSharedSessionWithoutScanNegotiation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        let tools = try XCTUnwrap(panel.components(separatedBy: "struct ToolsSection: View").last?
            .components(separatedBy: "struct TouchSection: View").first)
        XCTAssertTrue(tools.contains("if owner.inputPresentation.showsKeyboard"))
        XCTAssertTrue(panel.contains("canType: inputSession.canType && !networkManager.captureInputBlocked"))
        XCTAssertFalse(tools.contains("usesScanKeyboard"))
    }

    func testMissingLegacyCurrentNeverClaimsToStillShowAStaleScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("ScreenNotice(\"Couldn't switch screens.\", action: .recover, isFailure: true)"))
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
        XCTAssertTrue(casting.contains("always points absolutely"))
        XCTAssertTrue(casting.contains("No Windows pen, pressure or tilt"))
        XCTAssertFalse(casting.contains("acts like a pen"))
        let trackpad = GestureGuideContent.pencil(for: .input(.trackpad))
        XCTAssertTrue(trackpad.contains("always points absolutely"))
        XCTAssertTrue(trackpad.contains("No Windows pen, pressure or tilt"))
    }
}

#if targetEnvironment(simulator)
/// The host owns appearance forwarding, so immediate test teardown cannot interrupt an implicit transition.
@MainActor private final class PanelHostingContainer: UIViewController {
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
}
#endif
