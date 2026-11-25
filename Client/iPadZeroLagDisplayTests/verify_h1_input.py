"""Windows source contracts only. XCTest and Swift compilation remain CI gates."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[1] / "iPadZeroLagDisplay"


def source(name):
    return (APP / name).read_text(encoding="utf-8")


def body(text, marker):
    start = text.index("{", text.index(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


class H1InputContracts(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        self.assertTrue(member in container, msg or f"missing source contract: {member}")

    def assertNotIn(self, member, container, msg=None):
        self.assertFalse(member in container, msg or f"unexpected source contract: {member}")

    def test_terminal_network_lane_tracks_owned_input(self):
        text = source("NetworkManager.swift")
        for method in ("public func sendTouchEvent(type:", "public func sendKeyboardInput(_", "public func sendDirectTouchContact(_", "public func sendPointerInput(_"):
            block = body(text, method)
            self.assertNotIn("guard mirrorControl.allowsLegacyVirtualInput else", block)
            self.assertIn("legacyInputLifetime.accept", block)
            self.assertIn("requestedGeneration == self.connectionGeneration", block)

    def test_terminal_mirror_lane_requires_owned_down(self):
        text = source("RemoteControl/MirrorClientControl.swift")
        self.assertIn("struct InputLifetime", text)
        self.assertIn("inputLifetime.accept", body(text, "func encodeInput("))

    def test_terminal_callbacks_keep_registration_generation(self):
        text = source("MetalView.swift")
        for marker in ("touchView.onSendTouchEvent =", "touchView.onKeyboardInput =", "touchView.onDirectTouchContact =", "touchView.onPointerInput ="):
            block = body(text, marker)
            self.assertIn("inputGeneration", block)
            self.assertIn("legacySend", block)

    def test_terminal_remote_pause_retires_before_revision_rebind(self):
        block = body(source("NetworkManager.swift"), "func configure(_ value: RemoteSessionInputConfiguration)")
        self.assertTrue("suspend(reason: 0, preserveMonitorContext: value.monitorSelectionWhilePaused && value.ready)" in block.split("if retired", 1)[0])

    def test_geometry_retires_pencil_before_new_contract(self):
        text = source("PencilTouchView.swift")
        self.assertIn("retirePencil(); retireDirectTouch()", text)
        self.assertIn("retirePencil()", body(text, "override public func layoutSubviews()"))
        self.assertIn("emitPencilSample", text)

    def test_hover_exit_resets_remote_anchor(self):
        self.assertIn("mutating func hoverEnded", source("RemoteControl/RemoteMouseInput.swift"))
        block = body(source("PencilTouchView.swift"), "private func handleExternalPointerHover(")
        self.assertIn("hoverEnded", block)
        self.assertTrue("session.engine.hoverExited()" in block)
        legacy = block.split("if let input = remoteSessionInput",1)[1]
        self.assertLess(legacy.index("hoverEnded"),legacy.index("recognizer.state == .began"))

    def test_discrete_wheel_has_separate_event_admission(self):
        text = source("PencilTouchView.swift")
        block = body(text, "private func installExternalPointerRecognizers()")
        self.assertTrue(".discrete" in block)
        self.assertTrue("scroll.allowedScrollTypesMask = .continuous" in block)
        self.assertTrue("handleExternalPointerDiscreteScroll" in block)
        self.assertTrue("discretePoints" in text)

    def test_pencil_preempts_finger_scope_before_filtering(self):
        text = source("PencilTouchView.swift")
        block = body(text, "private func routeRemoteTouches(")
        self.assertTrue("prepareRemotePointerScope" in block)
        self.assertTrue("sample.device == .pencil" in body(source("RemoteControl/RemoteMouseInput.swift"), "mutating func touchBegan("))

    def test_scroll_reversal_discards_opposite_backlog_before_accumulating(self):
        block = body(source("PencilTouchView.swift"), "private mutating func wheel(")
        self.assertTrue("wheelRemainder = 0" in block.split("wheelRemainder += points", 1)[0])

    def test_casting_keys_delegate_to_software_text_owner(self):
        text = source("PencilTouchView.swift")
        block = body(text, "func unhandledHardwarePresses(")
        self.assertTrue("softwareResponderOwnsInput" in block.split("if let input", 1)[0])
        self.assertTrue("softwareResponderOwnsInput" in body(text, "func handleHardwareKey("))

    def test_extend_badge_and_keyboard_share_control_state(self):
        text = source("RemoteControl/ScreenPickerModel.swift")
        self.assertTrue("state?.mode == .virtualDisplay" in text)
        self.assertTrue("var canType: Bool { control == .on }" in text)
        block = body(source("SessionPanelOverlay.swift"), "struct ToolsSection: View")
        self.assertTrue("inputSession.canType" in block)
        self.assertNotIn("picker.control == .unavailable ||", block)

    def test_help_describes_touch_contact_and_remote_pointer(self):
        text = source("GestureHelp.swift")
        self.assertNotIn("Apple Pencil acts like a pen", text)
        # Precise Pencil binding supersedes the old mode-dependent Pencil behavior.
        self.assertTrue("Precise absolute mouse; tip drags with left button" in text)
        self.assertTrue("Double-tap or squeeze arms the next touch" in text)
        self.assertTrue("No Windows pen" in text)

    def test_preempted_palm_cancellation_cannot_retire_pencil(self):
        block = body(source("PencilTouchView.swift"), "private func routeRemoteTouches(")
        self.assertTrue("cancelRemotePointerScope" in block)
        self.assertTrue("remoteContacts[ObjectIdentifier($0)] != nil" in block.split("if flags == 1", 1)[0])

    def test_queued_starts_do_not_replay_across_local_pause(self):
        text = source("NetworkManager.swift")
        for method in ("public func sendTouchEvent(type:", "public func sendKeyboardInput(_", "public func sendDirectTouchContact(_", "public func sendPointerInput(_"):
            block = body(text, method)
            self.assertTrue("let requestedRevision" in block)
            self.assertTrue("mayStart && requestedRevision == self.mirrorControl.gestureRevision" in block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
