"""Windows source checks only. Does not execute Swift or qualify iPad behavior."""
from pathlib import Path
import hashlib
import os
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "iPadZeroLagDisplay"
BASELINE = Path(os.environ["QS_C_BASELINE"]) if "QS_C_BASELINE" in os.environ else None
SWIFT_FILES = [
    "NetworkManager.swift", "MetalView.swift", "SessionPanelOverlay.swift", "WireCommands.swift",
    "WireStreamParser.swift", "RemoteControl/MirrorClientControl.swift", "RemoteControl/ScreenPickerModel.swift",
    "RemoteControl/CaptureTargetProtocol.swift", "RemoteControl/CaptureTargetState.swift",
]


class CaptureTargetSourceChecks(unittest.TestCase):
    def test_f5_telemetry_formatting_and_fixed_fields(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertTrue('struct SessionTelemetryPresentation: Equatable' in panel)
        self.assertTrue('presentation.fpsValue, unit: "FPS", columns: 4' in panel)
        self.assertTrue('presentation.frameReceiveValue, unit: "ms", columns: 6' in panel)
        self.assertTrue('presentation.videoRxValue, unit: "Mbps", columns: 7' in panel)
        self.assertTrue('.frame(width: digitWidth * CGFloat(columns), alignment: .trailing)' in panel)
        self.assertTrue('Frame receive, ' in panel and 'Video RX, ' in panel)

    def test_f5_telemetry_is_text_only_and_does_not_capture_touches(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        content = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        readout = panel.split('struct SessionPerformanceReadout: View', 1)[1].split('private struct SessionPillHeightKey:', 1)[0]
        hud = content.split('private var streamingHUD:', 1)[1].split('@MainActor private struct AuthenticationOverlay', 1)[0]
        self.assertTrue('.background(' not in hud and '.overlay(' not in hud)
        self.assertTrue('.allowsHitTesting(false)' in readout)
        self.assertTrue('RoundedRectangle' not in readout and 'Capsule' not in readout and 'Image(' not in readout)
        self.assertTrue(readout.count('.shadow(') >= 2)
        self.assertTrue('.accessibilityLabel(presentation.accessibilityLabel)' in readout)
        self.assertTrue('if contrast == .increased' in readout)
        self.assertTrue('presentationGeometry?.safeAreaInsets' in hud)

    def test_f5_cycle_presentation_and_single_action(self):
        model = (APP / 'RemoteControl/ScreenPickerModel.swift').read_text(encoding='utf-8')
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertIn('public struct ScreenCyclePresentation', model)
        self.assertEqual(panel.count('.accessibilityIdentifier("session.switch-screen")'), 1)
        self.assertNotIn('tileView(', panel)
        self.assertNotIn('DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }', panel)

    def test_f5_cycle_retains_authority_disabled_reasons(self):
        model = (APP / 'RemoteControl/ScreenPickerModel.swift').read_text(encoding='utf-8')
        self.assertIn('selectionDisabledReason', model)
        self.assertIn('public func cycle(kind:', model)
        self.assertIn('isSwitching: remote.pending != nil || catalogue.state == 2', model)

    def test_f5_shared_section_order_and_accessibility(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertIn('private var panelSections:', panel)
        body = panel.split('struct PanelSections: View', 1)[1].split('struct PanelHeader: View', 1)[0].replace('owner.', '')
        positions = [body.index(x) for x in ('{ screens }', 'connectionPicker', 'tools', 'touchSection', 'remoteActions')]
        self.assertEqual(positions, sorted(positions))
        header = panel.split('struct PanelHeader: View', 1)[1].split('private struct', 1)[0]
        self.assertIn('CastingControlSection(owner: owner, action: .ask)', header)
        self.assertIn('CastingControlSection(owner: owner, action: .stop)', panel)
        self.assertIn('.frame(width: 96, height: 44)', panel)
        self.assertIn('@AccessibilityFocusState', panel)
        self.assertIn('accessibilityReduceMotion', panel)
        self.assertNotIn('minimumScaleFactor', panel)

    def test_f5_input_extras_gestures_and_shared_stats(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        mouse = (APP / 'RemoteControl/RemoteMouseControls.swift').read_text(encoding='utf-8')
        keys = (APP / 'RemoteControl/RemoteSpecialKeyBar.swift').read_text(encoding='utf-8')
        help_source = (APP / 'GestureHelp.swift').read_text(encoding='utf-8')
        content = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        self.assertIn('Text("More input")', panel)
        self.assertIn('Text("Special keys")', keys)
        self.assertNotIn('keyLabel("Ctrl+Alt+Del")', keys)
        self.assertIn('Direct sends Windows touch', mouse)
        self.assertIn('inputSession.selectTouchMode', mouse)
        self.assertNotIn('RemoteMouseMode.allCases', mouse)
        self.assertIn('Double-tap then move', help_source)
        self.assertIn('if isHudVisible && !isSessionPanelOpen', content)
        self.assertEqual(content.count('SessionPerformanceReadout('), 2)

    def test_f5_stats_follow_measured_pill_height(self):
        content = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertTrue('sessionPillHeight + 24' in content)
        self.assertTrue('onPillHeightChange' in panel)
        self.assertTrue('SessionPillHeightKey.self' in panel)

    def test_f5_legacy_keyboard_remains_available_without_scan_negotiation(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertTrue('inputSession.canType' in panel)
        routing = (APP / 'Input/IPadInputRouting.swift').read_text(encoding="utf-8")
        self.assertIn('features & 1 == 0 ? legacy : ready', routing)

    def test_f5_legacy_failure_with_no_current_never_claims_a_stale_screen(self):
        panel = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        self.assertRegex(panel, r'cycle\.position == nil \{\s*return ScreenNotice\("Couldn.t switch screens\.", action: \.recover, isFailure: true\)')
        self.assertRegex(panel, r'case \.recover:\s*owner\.cycleScreen\(\)')
        self.assertFalse('?.label ?? "the current screen"' in panel)

    def test_codec_and_csharp_vectors_are_present(self):
        codec = APP / "RemoteControl/CaptureTargetProtocol.swift"
        self.assertTrue(codec.exists(), "typed capture target codec missing")
        source = codec.read_text(encoding="utf-8")
        for literal in ["0x0400", "34228", "30000", "validInbound", "case accepted = 9"]:
            self.assertIn(literal, source)
        tests = (ROOT / "iPadZeroLagDisplayTests/CaptureTargetProtocolTests.swift").read_text(encoding="utf-8")
        host = (ROOT.parent / "Tests/ProtocolTests/CaptureTargetProtocolTests.cs").read_text(encoding="utf-8")
        for vector in ["01000000010000000000000000000000",
                       "01000000000000000100000000000000020000000000000003000000000000000400000000000000",
                       "01000100000000000100000000000000020000000000000003000000000000000100000000000000050000000000000006000000000000000100000000000000"]:
            self.assertIn(vector, tests)
            self.assertIn(vector, host)

    def test_transaction_state_is_implemented(self):
        self.assertTrue((APP / "RemoteControl/CaptureTargetState.swift").exists(),
                        "typed source transaction state missing")
        source = (APP / "RemoteControl/CaptureTargetState.swift").read_text(encoding="utf-8")
        self.assertIn("value.status == .timedOut", source)

    def test_integration_has_registered_runnable_xctests(self):
        path = ROOT / "iPadZeroLagDisplayTests/CaptureTargetIntegrationTests.swift"
        self.assertTrue(path.exists(), "typed source integration XCTest missing")
        source = path.read_text(encoding="utf-8")
        self.assertIn("testActualScopedRecoveryDeadlineNeverOpensInputFromLateRender", source)
        network = (APP / "NetworkManager.swift").read_text(encoding="utf-8")
        self.assertIn("func receiveCaptureTargetWireForTesting", network)

    def test_frozen_touch_prefix_and_existing_remote_literals(self):
        source = (APP / "PencilTouchView.swift").read_text(encoding="utf-8")
        prefix = source.split("struct ExternalPointerInputState")[0]
        # H1 changes only reversal handling in this otherwise frozen gesture prefix.
        prefix = prefix.replace("        if wheelRemainder * points < 0 { wheelRemainder = 0 }\n", "")
        # Binding input-v2 override, independently exclude only the side mapping.
        prefix = prefix.replace("case 0xE0, 0xE3: return 0xA2 // Left Control / Command -> left Ctrl\n        case 0xE4, 0xE7: return 0xA3 // Right Control / Command -> right Ctrl",
                                "case 0xE3, 0xE7: return 0xA2 // Command -> left Ctrl\n        case 0xE0, 0xE4: return 0xA3 // Control -> right Ctrl")
        self.assertEqual(hashlib.sha256(prefix.encode()).hexdigest(),
                         "72d7fe3f8164388d339bf32aacc8a754c9c396c3a0a025b7e6fc19bcd4824b1e")
        panel = (APP / "SessionPanelOverlay.swift").read_text(encoding="utf-8")
        for literal in ["ScreenPickerSnapshot.shouldShowPicker",
                        "networkManager.requestRemoteMonitor(targetId, catalogue: catalogue)",
                        "networkManager.requestMirrorMonitor(targetId, catalogue: catalogue)"]:
            self.assertIn(literal, panel)

    def test_existing_metal_and_network_source_assertions(self):
        metal = (APP / "MetalView.swift").read_text(encoding="utf-8")
        for literal in ["if note.name == UIApplication.willResignActiveNotification {\n            retireRemotePointerInputs()",
                        "uiView.retireRemotePointerInputs()", "container?.retireRemotePointerInputs()",
                        "let admitted = remoteKeyboardActive && (ticket != nil || legacy)",
                        "touchView.configureExternalPointer(active: admitted", "touchView.configureDirectTouch(active: admitted"]:
            self.assertIn(literal, metal)
        self.assertNotIn("touchpadModeEnabled", metal)
        network = (APP / "NetworkManager.swift").read_text(encoding="utf-8")
        for literal in ["RemoteFeatureNegotiation(requestedFeatures: 0x1f | RemoteFeatureNegotiation.remoteVideoStandby)",
                        "remoteMonitors.begin(session: UUID(), acceptedFeatures:", "remoteMonitors.session == session",
                        "case .remoteMonitorCatalogueRequest:", "case .remoteMonitorSelectRequest:"]:
            self.assertIn(literal, network)
        usb = network.split("private func sendClientCapabilities(for kind: ActiveTransportKind)", 1)[1].split("let baseModes", 1)[0]
        self.assertIn("modes: RealtimeTransportMode.legacyTLS,", usb)
        self.assertNotIn("usbSplitTLS", usb)
        lane = network.split("    private func startUsbLaneReceiveLoop(", 1)[1].split("    // MARK: Telemetry Timer", 1)[0]
        for literal in ["case .failure", "case .discardedFixedControl", "guard !terminated", "terminated = true"]:
            self.assertIn(literal, lane)
        self.assertNotIn("guard case .message(let message) = event else { return }", lane)
        retirement = network.split("    private func teardownCurrentSession()", 1)[1].split("    private func reconcileRealtimeAudioPlayback", 1)[0]
        self.assertEqual(retirement.count("connection?.cancel()"), 1)
        self.assertNotIn("usbListener?.cancel()", retirement); self.assertNotIn("usbListener = nil", retirement)
        ready = network.split("private func receiveDisplayReady", 1)[1].split("private func receiveDisplayConfigurationFailure", 1)[0]
        gate = ready.index("guard displayRequestGate.effective?.requestId == ready.requestId else { return }")
        self.assertLess(gate, ready.index("self?.effectiveDisplayState = ready"))
        self.assertNotIn("decoder.configureRefreshRate", ready)
        self.assertIn("if !remoteInputConnection { decoder.configureRefreshRate(UInt32(mode.targetFps)) }", network)

    def test_retirement_and_recovery_use_correct_owners_and_send_lane(self):
        network = (APP / "NetworkManager.swift").read_text(encoding="utf-8")
        request = network.split("@MainActor public func requestCaptureTarget", 1)[1].split("private func refreshCaptureTargetsOnQueue", 1)[0]
        self.assertLess(request.index("captureTargetRetireInput?()"), request.index("setCaptureTargetInputBlocked(true"))
        self.assertIn("networkQueue.sync { mirrorControl.setCaptureTargetInputBlocked(true, session: generation) }", request)
        self.assertLess(request.index("setCaptureTargetInputBlocked(true"), request.index("type: .sourceSwitchRequest"))
        for forbidden in ["beginTerminalSwitch", "suspendInput", "requestMirrorMonitor"]:
            self.assertNotIn(forbidden, request)
        self.assertIn("CaptureTargetProtocol.terminalWait", request)
        self.assertIn("telemetry: coalesceFeedback && type == .videoFeedback && flags != CaptureTargetProtocol.recoveryFlag", network)
        self.assertIn("self.captureTargets.session == typed.session", network)
        self.assertIn("self.currentCaptureTargetDecoderOwner == typed", network)
        legacy = network.split("public func legacyInputIsCurrent", 1)[1].split("@MainActor public func requestCaptureTarget", 1)[0]
        self.assertNotIn("&& mirrorControl.allowsLegacyVirtualInput", legacy)
        self.assertIn("captureTargets.catalogue?.epoch != applied.epoch", network)
        render = network.split("if let typed, typed.decoder == generation", 1)[1].split("if let captured,", 1)[0]
        self.assertNotIn("self.captureTargets.observeRendered(sequence: sequence, session: typed.session) else", render)
        self.assertIn("for second in 1...5", network)
        self.assertIn("if second == 5 { self.abandonCaptureTargetPresentationOnQueue() }", network)
        self.assertIn("captureTargets.retireRoute()", network)
        metal = (APP / "MetalView.swift").read_text(encoding="utf-8")
        hook = metal.split("networkManager.captureTargetRetireInput =", 1)[1].split("let binding", 1)[0]
        for literal in ["retireMirrorInputScope()", "retireRemotePointerInputs()", "retireRemoteKeyboard()"]:
            self.assertIn(literal, hook)
        pencil = (APP / "PencilTouchView.swift").read_text(encoding="utf-8")
        held = pencil.split("func retireMirrorInputScope()", 1)[1].split("private var activeTouchIdentifier", 1)[0]
        for literal in ["retirePencil()", "retireDirectTouch()", "retireExternalPointer()", "releaseActiveRemoteKeys()"]:
            self.assertIn(literal, held)
        terminal = pencil.split("func retirePencil()", 1)[1].split("private func handlePencilTouches", 1)[0]
        self.assertIn("emitPencilSample", terminal)
        self.assertIn("pointerFlags: 4", terminal)

    def test_five_swift_files_are_registered_in_all_four_project_sections(self):
        project = (APP / "iPadCasting.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for name in ["CaptureTargetProtocol.swift", "CaptureTargetState.swift", "CaptureTargetProtocolTests.swift",
                     "CaptureTargetStateTests.swift", "CaptureTargetIntegrationTests.swift"]:
            for section in ["PBXBuildFile", "PBXFileReference", "PBXGroup", "PBXSourcesBuildPhase"]:
                text = project.split(f"/* Begin {section} section */", 1)[1].split(f"/* End {section} section */", 1)[0]
                self.assertIn(name, text, (name, section))
        definitions = re.findall(r"^\s*(C81[45][0-9A-F]{20}) /\*[^\n]+?\*/ =", project, re.M)
        self.assertEqual(len(definitions), 10); self.assertEqual(len(set(definitions)), 10)

    def test_scoped_recovery_and_virtual_permission_vectors_match_host_tests(self):
        swift = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "iPadZeroLagDisplayTests").glob("CaptureTarget*Tests.swift"))
        host = (ROOT.parent / "Tests/ProtocolTests/CaptureTargetRecoveryTests.cs").read_text(encoding="utf-8").lower()
        recovery = "53435354010800101800000000000000020000000000000005000000000000000600000000000000"
        self.assertIn(recovery, swift); self.assertIn(recovery, host)
        permission = "0108000005000000000000000000000000000000000000000000000000000000"
        self.assertIn(permission, swift)
        self.assertIn(permission, (ROOT.parent / "Tests/ProtocolTests/CaptureTargetWalkthroughTests.cs").read_text(encoding="utf-8").lower())

    def test_changed_swift_syntax_with_available_tree_sitter(self):
        try:
            import tree_sitter
            import tree_sitter_swift
        except ImportError:
            self.skipTest("Optional installed syntax parser unavailable; this is not a Swift compiler")
        parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
        paths = [APP / name for name in SWIFT_FILES] + list((ROOT / "iPadZeroLagDisplayTests").glob("CaptureTarget*Tests.swift"))
        for path in paths:
            self.assertFalse(parser.parse(path.read_bytes()).root_node.has_error, path.name)

    @unittest.skipUnless(BASELINE, "Baseline byte preservation audit requires QS_C_BASELINE")
    def test_preserves_existing_tests_remote_adapter_and_source_contract_dependencies(self):
        for before in (BASELINE / "Client/iPadZeroLagDisplayTests").glob("*.swift"):
            self.assertEqual(before.read_bytes(), (ROOT / "iPadZeroLagDisplayTests" / before.name).read_bytes(), before.name)
        for name in ["PencilTouchView.swift", "DecoderManager.swift", "Renderer.swift", "RemoteControl/MirrorControlProtocol.swift",
                     "RemoteControl/RemoteMonitorProtocol.swift", "RemoteControl/RemoteMonitorState.swift"]:
            self.assertEqual((BASELINE / "Client/iPadZeroLagDisplay" / name).read_bytes(), (APP / name).read_bytes(), name)
        before = (BASELINE / "Client/iPadZeroLagDisplay/RemoteControl/ScreenPickerModel.swift").read_text(encoding="utf-8")
        after = (APP / "RemoteControl/ScreenPickerModel.swift").read_text(encoding="utf-8")
        start, end = "    public static func make(remote:", '    /// The Host names a laptop'
        self.assertEqual(before.split(start)[1].split(end)[0], after.split(start)[1].split(end)[0])
        before = (BASELINE / "Client/iPadZeroLagDisplay/NetworkManager.swift").read_text(encoding="utf-8")
        after = (APP / "NetworkManager.swift").read_text(encoding="utf-8")
        start, end = "    public func requestMirrorMonitor", "    public func setMirrorInputForeground"
        self.assertEqual(before.split(start)[1].split(end)[0], after.split(start)[1].split(end)[0])
        before = (BASELINE / "Client/iPadZeroLagDisplay/RemoteControl/MirrorClientControl.swift").read_text(encoding="utf-8")
        after = (APP / "RemoteControl/MirrorClientControl.swift").read_text(encoding="utf-8")
        start, end = "    public func helloIfAdvertised", "    public var currentState"
        self.assertEqual(before.split(start)[1].split(end)[0], after.split(start)[1].split(end)[0])

    @unittest.skipUnless(BASELINE, "Encoding preservation audit requires QS_C_BASELINE")
    def test_added_lines_are_ascii_and_existing_encoding_and_line_endings_are_preserved(self):
        import difflib
        for name in SWIFT_FILES + ["iPadCasting.xcodeproj/project.pbxproj"]:
            path = APP / name; before = BASELINE / "Client/iPadZeroLagDisplay" / name
            raw = path.read_bytes()
            if before.exists():
                old = before.read_bytes()
                self.assertEqual(raw.startswith(b"\xef\xbb\xbf"), old.startswith(b"\xef\xbb\xbf"), name)
                old_crlf, old_lf = old.count(b"\r\n"), old.replace(b"\r\n", b"").count(b"\n")
                if old_crlf and not old_lf: self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), name)
                if old_lf and not old_crlf: self.assertNotIn(b"\r\n", raw, name)
                additions = [line[1:] for line in difflib.ndiff(old.decode("utf-8-sig").splitlines(), raw.decode("utf-8-sig").splitlines()) if line.startswith("+ ")]
                self.assertTrue(all(line.isascii() for line in additions), name)
            else: self.assertTrue(raw.isascii(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
