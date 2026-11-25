"""Guard concrete SwiftUI metadata boundaries; independent of an iPad stack size."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ["SessionPanelOverlay.swift", "SessionInputBar.swift", "GestureHelp.swift",
         "AccessiblePointerControls.swift", "RemoteControl/RemoteMouseControls.swift",
         "RemoteControl/RemoteSpecialKeyBar.swift", "ContentView.swift", "SettingsView.swift",
         "DataTransfer/TransferCenterSheet.swift"]


def source(name):
    path = "Client/iPadZeroLagDisplay/" + name
    revision = os.environ.get("SCDP_PANEL_BASELINE")
    if revision:
        return subprocess.check_output(["git", "show", revision + ":" + path], cwd=ROOT).decode("utf-8")
    return (ROOT / path).read_text(encoding="utf-8")


def builders(text):
    # These builders use balanced braces, including balanced interpolation braces.
    for match in re.finditer(r"(?:var\s+\w+\s*:\s*some View|func\s+\w+\s*\([^{}]*?\)\s*->\s*some View)\s*\{", text):
        start = match.end()
        depth, end = 1, start
        while depth and end < len(text):
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        yield text[match.start():start].strip(), text[start:end - 1]


class PanelMetadataTests(unittest.TestCase):
    def assertRegex(self, text, pattern, msg=None):
        self.assertTrue(re.search(pattern, text), msg or "Missing metadata boundary: " + pattern)

    def test_panel_composition_has_concrete_metadata_boundaries(self):
        panel = source(FILES[0])
        self.assertRegex(panel, r"func panel\(width: CGFloat, maxHeight: CGFloat\) -> PanelContent")
        self.assertRegex(panel, r"var panelSections: PanelSections")
        for name in ["PanelContent", "PanelSections", "ScreenSection", "ConnectionSection",
                     "CastingControlSection", "ToolsSection", "TouchSection", "MoreInputSection",
                     "RemoteActionsSection", "PanelHeader", "PanelFooter", "OverlaySurface"]:
            self.assertRegex(panel, rf"struct {name}: View")

    def test_panel_builders_stay_below_75_source_lines(self):
        for name in FILES:
            text = source(name)
            self.assertNotIn("AnyView(", text, name)
            for header, body in builders(text):
                lines = sum(bool(line.strip()) and not line.strip().startswith("//")
                            for line in body.splitlines())
                with self.subTest(file=name, builder=header):
                    self.assertLessEqual(lines, 75, "Extract a concrete View, not another opaque helper")

    def test_open_panel_is_hosted_on_main_thread_in_ci(self):
        tests = (ROOT / "Client/iPadZeroLagDisplayTests/SessionPanelTests.swift").read_text(encoding="utf-8")
        for required in ["testOpenPanelMetadataInHostingWindow", "UIWindow(", "layoutIfNeeded()",
                         "accessibility5", "accessibilityEnabled", "expandedInputForTesting(voiceOver:"]:
            self.assertIn(required, tests)
        self.assertNotIn("stackSize =", tests, "UIKit hosting must stay on the main thread")

    def test_three_finger_and_pill_reach_the_same_open_panel(self):
        content, panel, metal = source("ContentView.swift").replace("owner.", ""), source(FILES[0]), source("MetalView.swift")
        self.assertIn("isSessionPanelOpen = true", content)
        self.assertIn("private func open() { isOpen = true }", panel)
        self.assertIn(".onChange(of: isSessionPanelOpen) { _, open in", content)
        self.assertIn("inputSession.panelPresentationChanged(open, surfaceActive:", content)
        self.assertIn("sharedInput.engine.openSettings = { [weak touchView] in touchView?.onOpenSettings?() }", metal)


if __name__ == "__main__":
    unittest.main()
