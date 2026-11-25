"""Deterministic source contracts only; does not execute Swift."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Client/iPadZeroLagDisplay"
def src(n):
    p=APP/n
    return p.read_text(encoding="utf-8") if p.exists() else ""
class InputV2Contracts(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        self.assertTrue(member in container,msg or f"missing source contract: {member}")
    def test_round11_cached_command_cannot_authorize_pointer_restoration(self):
        e=src("Input/IPadInputEngine.swift")
        restore=e.split("private func restorePointerCommand",1)[1].split("private func releasePhysical",1)[0]
        self.assertNotIn("?? query ?? commandEvidence.contains(key)",restore)
        self.assertIn("?? query ?? false",restore)
        self.assertIn("currentPointerCommandSides.contains(key)",restore)
        doc=(ROOT/"docs/ipad-input-behaviour.md").read_text(encoding="utf-8")
        for token in ["Cached press evidence alone never restores it", "never restore a Command owner", "Uncertainty release clears cached Command evidence"]: self.assertIn(token,doc)
        release=e.split("private func releasePhysical",1)[1].split("private func releaseUnknownActionModifiers",1)[0]
        self.assertIn("if isCommand(original) { commandEvidence.remove(original) }",release)
    def test_round11_ui_controls_cannot_acquire_command_from_keyboard_query(self):
        e=src("Input/IPadInputEngine.swift")
        self.assertIn("func withoutCommandRestoration",e)
        self.assertIn("guard enabled, typeEnabled, hardwareCaptureEnabled, commandRestorationEnabled",e)
        session=src("Input/IPadInputSession.swift")
        for method,next_method in [("func click(","func beginDrag"),("func beginDrag", "func releaseDrag"),("func tapKey", "func tapWindowsShortcut"),("func tapWindowsShortcut", "func moveAccessibleTarget"),("func moveAccessibleTarget", "func showSoftwareKeyboard")]:
            body=session.split(method,1)[1].split(next_method,1)[0]
            self.assertIn("withoutCommandRestoration",body,method)

    def test_round11_absent_flags_clear_command_even_on_terminal_or_unknown_press(self):
        p=src("PencilTouchView.swift")
        router=p.split("func unhandledHardwarePresses",1)[1].split("if softwareResponderOwnsInput",1)[0]
        self.assertIn("hardwareModifierFlags(for: press)?.contains(.command) == false",router)
        self.assertLess(router.index("withPointerCommand(false)"),router.index("guard let usage"))
        hover=p.split("@objc private func handleExternalPointerHover",1)[1].split("if let input = remoteSessionInput",1)[0]
        self.assertLess(hover.index("withPointerCommand("),hover.index("guard window != nil"))

    def test_round10_pointer_action_protects_and_restores_command(self):
        e=src("Input/IPadInputEngine.swift")
        for token in ["private var pointerActionIsActive", "!pointerActionIsActive", "lastPointerActionEnd", "restorePointerCommand", "func withPointerCommand", "commandEvidence", "currentPointerCommand"]: self.assertIn(token,e)
        begin=e.split("private func beginAction",1)[1].split("private func endAction",1)[0]
        self.assertLess(begin.index("restorePointerCommand"),begin.index("actionPhysicalEvidence ="))
        self.assertIn("currentPointerCommand.map { $0 && currentPointerCommandSides.contains(key) }",e)
        tick=e.split("func tick()",1)[1].split("guard enabled",1)[0]
        self.assertIn("if !pointerActionIsActive &&",tick)
        self.assertIn("now-lastPointerActionEnd >= 2.0",tick)
        active=e.split("private var pointerActionIsActive",1)[1].split("func withPointerCommand",1)[0]
        for token in ["!contacts.isEmpty", "native != nil", "!buttons.isEmpty", "drag != .idle", "externalScrolling", "isExternalTransforming", "inertiaStarted != nil"]: self.assertIn(token,active)
        p=src("PencilTouchView.swift")
        self.assertIn("event.map { $0.modifierFlags.contains(.command) }",p)
        self.assertGreaterEqual(p.count("withPointerCommand(recognizer.modifierFlags.contains(.command))"),3)

    def test_round10_uncertainty_is_command_only(self):
        e=src("Input/IPadInputEngine.swift")
        self.assertIn("private func isCommand",e)
        action=e.split("private func releaseUnknownActionModifiers",1)[1].split("func hardware(",1)[0]
        self.assertIn("state == nil && isCommand(key)",action)
        tick=e.split("func tick()",1)[1].split("func retire()",1)[0]
        self.assertIn("where isCommand(key) && physicalKeyIsDown?(key) == nil",tick)
        flags=e.split("func hardwareModifiers",1)[1].split("func hardwareDisconnected",1)[0]
        self.assertIn("if !held && isCommand(left)",flags)

    def test_round9_unknown_modifier_has_action_idle_and_flag_recovery(self):
        e=src("Input/IPadInputEngine.swift")
        for token in ["actionPhysicalEvidence", "releaseUnknownActionModifiers", "state == nil && isCommand(key) && physicalEvidence[key] == actionPhysicalEvidence[key]", "now-lastHardwareEvent >= 2.0", "physical.allSatisfy", "uncertainModifiers", "func hardwareModifiers"]:
            self.assertIn(token,e)
        p=src("PencilTouchView.swift")
        for token in ["press.key?.modifierFlags", "override public func pressesChanged", "refreshHardwareModifiers(from: press)", "if phase == .cancelled", "if oldValue != softwareResponderOwnsInput"]:
            self.assertIn(token,p)
        self.assertIn("softwareTextView.onHardwareFocusLost",src("MetalView.swift"))
        doc=(ROOT/"docs/ipad-input-behaviour.md").read_text(encoding="utf-8")
        for token in ["two seconds without any hardware key event", "last action using it", "restore Ctrl before the ordinary key Down", "Uncertainty release applies only to a Command-created owner", "idle interval restarts after the last pointer action"]: self.assertIn(token,doc)
    def test_round9_nested_actions_release_only_last_modifier_owner(self):
        e=src("Input/IPadInputEngine.swift")
        for token in ["private var actionOwners: Set<String>", "actionModifierOwners[m,default: []].insert(owner)", "actionModifierOwners[m]?.remove(owner)", "actionModifierOwners[m]?.isEmpty == true", 'beginAction("tap")', 'endAction("tap")', 'beginAction("shortcut")', 'endAction("shortcut")', 'endAction("hardware\\(original)")']:
            self.assertIn(token,e)
        self.assertNotIn("actionActive",e)
    def test_round9_scroll_terminal_precedes_geometry(self):
        p=src("PencilTouchView.swift")
        self.assertIn("func routeV2Scroll(state:",p)
        route=p.split("func routeV2Scroll(state:",1)[1].split("@objc private func handleExternalPointerDiscreteScroll",1)[0]
        self.assertIn("defer { if terminal",route)
        self.assertLess(route.index("defer { if terminal"),route.index("guard window != nil"))
        self.assertIn("session.engine.endExternalScroll(); return true",route)
        pointer=p.split("func routeV2IndirectPointer(",1)[1].split("\n    }",1)[0]
        self.assertIn("guard !cancelled, let normalized else { session.engine.hoverExited(); return }",pointer)
        self.assertIn("session.engine.external(point: point, normalized: normalized, buttons: buttons)",pointer)
        self.assertIn("buttons: UInt(truncatingIfNeeded: event?.buttonMask.rawValue ?? 0)",p)
        self.assertIn("guard window != nil || phase == 4",p)
    def test_round9_partial_cancellation_is_sticky_until_all_contacts_lift(self):
        e=src("Input/IPadInputEngine.swift")
        for token in ["private var gestureCancelled = false", "if cancelled && !c.pencil && maximumFingers >= 2", "gestureCancelled = true; suppressedTap = true", "if !isPencil && gestureCancelled { return }", "guard enabled, !gestureCancelled", "if !gestureCancelled && maximumFingers == 2"]:
            self.assertIn(token,e)
        end=e.split("func end(id:",1)[1].split("private func relative",1)[0]
        self.assertNotIn("gestureCancelled = false",end)

    def test_final_writer_blocks_new_v2_on_route_retirement(self):
        n=src("NetworkManager.swift")
        gate=n.split("private func connectionControlPacketIsCurrent",1)[1].split("private func",1)[0]
        self.assertIn("83",gate)
        self.assertIn("82",gate)
        self.assertIn("isNewRemoteV2InputPacket",gate)
    def test_main_actor_immutable_routes_and_frozen_surface(self):
        session=src("Input/IPadInputSession.swift")
        for token in ["@MainActor final class IPadInputSession", "objectWillChange.send()", "func showSoftwareKeyboard()", "static func preview()", "input.touchMode.v2", "input.scrollInertia.v1", "input.reverseScroll.v1"]: self.assertIn(token,session)
        self.assertNotIn("textMode",session)
        routing=src("Input/IPadInputRouting.swift")
        for token in ["let generation =", "let ticket =", "let context =", "features & 8 != 0", "features & 0x10 != 0", "network.remoteKeyboardGeneration == generation"]: self.assertIn(token,routing)
    def test_resource_and_every_new_target_membership(self):
        p=src("iPadCasting.xcodeproj/project.pbxproj")
        for name in ["IPadInputCodec.swift", "IPadInputEngine.swift", "IPadInputSession.swift", "IPadInputRouting.swift", "SessionInputBar.swift", "AccessiblePointerControls.swift", "IPadInputV2Tests.swift", "InputBarAccessibilityTests.swift"]:
            self.assertEqual(p.count(name+" in Sources */ ="),1,name)
        self.assertIn("path = Fixtures/IPadInputV2Golden.json",p)
        self.assertIn("IPadInputV2Golden.json in Resources",p)
        tests=(APP.parent/"iPadZeroLagDisplayTests/IPadInputV2Tests.swift").read_text(encoding="utf-8")
        self.assertIn("Bundle(for: IPadInputV2Tests.self)",tests)
    def test_key_source_and_modifier_canonicalization(self):
        p=src("PencilTouchView.swift")
        key=p.split("func handleHardwareKey",1)[1].split("func unhandledHardwarePresses",1)[0]
        self.assertLess(key.index("if let session = inputSession"),key.index("if softwareResponderOwnsInput"))
        s=src("Input/IPadInputEngine.swift")
        self.assertIn("original == 0xe3 ? 0xe0 : original == 0xe7 ? 0xe4",s)
        self.assertIn("physicalKeyIsDown?(key) == false",s)
    def test_wheel_axis_and_renderer_atomicity_are_preserved(self):
        self.assertIn("send(.pointer(3,0,y,-x))",src("Input/IPadInputEngine.swift"))
        self.assertIn("commandBuffer.commit()\n        lock.unlock()",src("Renderer.swift"))

    def test_codecs_and_negotiation(self):
        self.assertIn("struct IPadPointerV2Command",src("Input/IPadInputCodec.swift"))
        self.assertIn("remoteDirectTouch = 82",src("WireCommands.swift"))
        self.assertIn("iPadPointerV2 = 83",src("WireCommands.swift"))
        self.assertIn("knownFeatures: UInt64 = 0x1f",src("RemoteControl/RemoteFeatureNegotiation.swift"))
    def test_clock_driven_gesture_regressions_are_connected_to_uikit(self):
        p=src("PencilTouchView.swift")
        self.assertIn("session.engine.moveBatch(samples)",p)
        self.assertIn("event?.allTouches ?? touches",p)
        self.assertIn("RunLoop.main.add(timer,forMode: .common)",src("Input/IPadInputSession.swift"))
        e=src("Input/IPadInputEngine.swift")
        self.assertIn("if inertiaStarted != nil { cancelInertia() }",e)
        self.assertIn("!buttons.contains(b)",e)
    def test_swift_syntax_for_owned_sources_and_new_tests(self):
        from tree_sitter import Parser,Language
        import tree_sitter_swift
        parser=Parser(Language(tree_sitter_swift.language()))
        paths=list((APP/"Input").glob("*.swift"))
        paths += [APP/n for n in ["WireCommands.swift","WireStreamParser.swift","NetworkManager.swift","MetalView.swift","PencilTouchView.swift","ContentView.swift","RemoteControl/RemoteFeatureNegotiation.swift","RemoteControl/MirrorControlProtocol.swift","RemoteControl/MirrorClientControl.swift","RemoteControl/RemoteHardwareKeyboard.swift","SessionInputBar.swift"]]
        paths += [APP.parent/"iPadZeroLagDisplayTests"/n for n in ["IPadInputV2Tests.swift","WireProtocolTests.swift","RemoteMonitorIntegrationTests.swift","InputBarAccessibilityTests.swift"]]
        for path in paths: self.assertFalse(parser.parse(path.read_bytes()).root_node.has_error,path.name)
    def test_every_modified_line_and_new_file_is_ascii(self):
        import subprocess
        names=["WireCommands.swift","WireStreamParser.swift","NetworkManager.swift","MetalView.swift","PencilTouchView.swift","ContentView.swift","RemoteControl/RemoteFeatureNegotiation.swift","RemoteControl/MirrorControlProtocol.swift","RemoteControl/MirrorClientControl.swift","RemoteControl/RemoteHardwareKeyboard.swift","SessionInputBar.swift"]
        paths=[str((APP/n).relative_to(ROOT)) for n in names]
        diff=subprocess.check_output(["git","diff","--unified=0","--",*paths],cwd=ROOT).decode("utf-8")
        additions=[x[1:] for x in diff.splitlines() if x.startswith("+") and not x.startswith("+++")]
        self.assertTrue(all(x.isascii() for x in additions))
        for p in (APP/"Input").glob("*.swift"): self.assertTrue(p.read_bytes().isascii(),p.name)
        self.assertTrue((APP.parent/"iPadZeroLagDisplayTests/IPadInputV2Tests.swift").read_bytes().isascii())
    def test_local_retirement_purges_queued_starts_before_terminals(self):
        s=src("Input/IPadInputSession.swift").split("func releaseAll()",1)[1].split("func tapKey",1)[0]
        self.assertIn("retireQueuedInput?()",s)
        self.assertLess(s.index("retireQueuedInput?()"),s.index("engine.retire()"))
        self.assertIn("func retireIPadInputScope",src("NetworkManager.swift"))
    def test_explicit_release_serializes_revoke_after_owned_terminals(self):
        s=src("NetworkManager.swift").split("public func releaseMirrorControl()",1)[1].split("public func requestMirrorControl",1)[0]
        self.assertLess(s.index("networkQueue.async"),s.index("suspendInput()"))
    def test_amended_button_transactions_cross_codec_engine_and_lifetime(self):
        codec=src("Input/IPadInputCodec.swift")
        for token in ["transaction: UInt32", "d.storeLittleEndian(transaction, at: 4)", "d[8..<12]", "transaction != 0"]: self.assertIn(token,codec)
        engine=src("Input/IPadInputEngine.swift")
        for token in ["func beginConnection", "buttonTransactions", "lastButtonTransaction < UInt32.max", "case button(UInt8, UInt8, UInt32)"]: self.assertIn(token,engine)
        self.assertIn("command.transaction",src("RemoteControl/MirrorClientControl.swift"))
    def test_standalone_windows_key_uses_zero_shortcut_convention(self):
        engine=src("Input/IPadInputEngine.swift")
        shortcut=engine.split("func shortcut",1)[1].split("private func button",1)[0]
        self.assertIn("key != 0 &&",shortcut)
        bar=src("SessionInputBar.swift")
        self.assertIn('label: "Windows Start", usage: 0)',bar)
        self.assertIn("tapWindowsShortcut(hidUsage: shortcut.usage",bar)
        self.assertNotIn("one-shot Win fallback",bar)
    def test_legacy_same_side_second_owner_does_not_emit_extra_down(self):
        key=src("PencilTouchView.swift").split("func handleHardwareKey",1)[1].split("func unhandledHardwarePresses",1)[0]
        self.assertIn("if alreadyOwned { return true }",key)
    def test_amended_fixture_names_and_button_golden_bytes(self):
        import json
        f=json.loads((APP.parent/"iPadZeroLagDisplayTests/Fixtures/IPadInputV2Golden.json").read_text(encoding="utf-8"))
        by_name={v["name"]:v for v in f["vectors"]}
        self.assertEqual(bytes.fromhex(by_name["casting-middle-down"]["hex"]), bytes([1,2,0,3,1,0,0,0]+[0]*16))
        self.assertEqual(bytes.fromhex(by_name["casting-middle-up"]["hex"]), bytes([1,2,0,3,1,0,0,0]+[0]*4+[1]+[0]*11))
        malformed={v["name"] for v in f["malformed"]}
        self.assertTrue({"casting-button-zero-transaction","casting-kind-0-transaction","casting-kind-1-transaction","casting-kind-3-transaction","casting-kind-4-transaction"} <= malformed)
        states={v["name"] for v in f["stateCases"]}
        self.assertTrue({"old-up-after-retirement-and-successor-down","nonincreasing-button-down-transaction","transaction-survives-mode-and-capture-retirement"} <= states)
    def test_audio_binding_failure_path_is_independent_of_input_manager(self):
        server=src("RealtimeTransport/UsbLaneServer.swift")
        receive=server.split("private func receiveBinding(",1)[1].split("private func finishBinding",1)[0]
        self.assertIn("if let error {\n                connection.cancel()",receive)
        self.assertIn("if expectedLane != .audio",receive)
        self.assertNotIn("NetworkManager",receive)
        tests=(APP.parent/"iPadZeroLagDisplayTests/WireProtocolTests.swift").read_text(encoding="utf-8")
        test=tests.split("final class OptionalUsbAudioBindingTests",1)[1].split("final class ForegroundPerformanceFeedbackTests",1)[0]
        self.assertNotIn("NetworkManager",test)
        self.assertIn("let queue = DispatchQueue",test)
        self.assertIn("received.fulfill()",test)
    def test_shared_engine_and_lifecycle(self):
        s=src("Input/IPadInputEngine.swift")
        for token in ["final class IPadInputEngine", "func retire()", "func tick()", "0.080", "6000", "0.200", "2400", "0.800", "0.500", "0.150", "1.0 / 30"]:
            self.assertIn(token,s)
    def test_scene_and_routing(self):
        self.assertIn(".environmentObject(inputSession)",src("ContentView.swift"))
        self.assertIn("routeV2Touches",src("PencilTouchView.swift"))
        self.assertIn("sendIPadPointerV2",src("NetworkManager.swift"))
if __name__ == "__main__": unittest.main(verbosity=2)
