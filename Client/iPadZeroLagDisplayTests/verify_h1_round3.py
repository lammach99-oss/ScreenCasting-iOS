"""Portable source regressions. Predicate evaluation is not Swift/UIKit execution."""
from pathlib import Path
import re
import hashlib
from itertools import product
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Client/iPadZeroLagDisplay"
TESTS = ROOT / "Client/iPadZeroLagDisplayTests"


def source(name):
    return (APP / name).read_text(encoding="utf-8")


def body(text, marker):
    start = text.index("{", text.index(marker))
    depth, end = 1, start + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start + 1:end - 1]


class RoundThreeContracts(unittest.TestCase):
    def test_old_host_registration_predicate_keeps_pre_h1_compatibility_and_capture_fences(self):
        method = body(source("RemoteControl/MirrorClientControl.swift"), "func legacyRegistrationIsCurrent")
        expression = body(method, "synchronized").strip()
        expression = expression.replace("&&", " and ").replace("||", " or ")
        expression = " ".join(re.sub(r"!(?!=)", "not ", expression).split())
        for typed in (False, True):
            for current in (False, True):
                for virtual, capture, descriptor, connection, target in product((False, True), repeat=5):
                    values = dict(legacyVirtualInputSuspended=virtual, typedSources=typed, captured=1, revision=1 if current else 2,
                                  captureSuspended=capture, captureDescriptorPending=descriptor,
                                  connectionInputBlocked=connection, captureTargetInputBlocked=target)
                    expected = not (virtual or capture or descriptor or connection) and (not typed or current and not target)
                    with self.subTest(**values):
                        self.assertEqual(eval(expression, {"__builtins__": {}}, values), expected)
        test = (TESTS / "CaptureTargetIntegrationTests.swift").read_text(encoding="utf-8")
        self.assertIn("XCTAssertEqual(network.legacyInputIsCurrent(revision: registration), !typed", test)

    def test_software_owned_event_keeps_entry_owner_through_reentrant_activity(self):
        s = source("PencilTouchView.swift")
        for marker in ("func handleHardwareKey(", "func unhandledHardwarePresses("):
            method = body(s, marker)
            # The v2 source router precedes this legacy-only delegation branch.
            method = method[method.index("if softwareResponderOwnsInput {"):]
            self.assertIn("if softwareResponderOwnsInput {", method)
            self.assertLess(method.index("if softwareResponderOwnsInput {"), method.index("onHardwareKeyActivity?()"))
            branch = body(method, "if softwareResponderOwnsInput")
            self.assertIn("return false" if marker.startswith("func handleHardwareKey") else "return presses", branch)
        test = body((TESTS / "WireProtocolTests.swift").read_text(encoding="utf-8"),
                    "func testHardwareTypingDelegatesWhileAcquiredSoftwareResponderOwnsComposition")
        self.assertIn("sceneBackedInitialKeyboardFixture()", test)
        self.assertIn("XCTAssertTrue(container.softwareTextView.becomeFirstResponder())", test)
        self.assertNotIn("softwareResponderOwnsInput = true", test)
        self.assertIn("softwareTextView.onHardwareCancellation?", test)

    def test_frozen_prefix_hash_matches_xctest_with_only_required_h1_scroll_edit(self):
        s = source("PencilTouchView.swift").replace("\r\n", "\n")
        prefix = s.split("struct ExternalPointerInputState", 1)[0]
        test = body((TESTS / "WireProtocolTests.swift").read_text(encoding="utf-8"),
                    "func testFrozenDirectTouchHelpersMatchQualifiedBaseline")
        expected = re.search(r'"([a-f0-9]{64})"', test)[1]
        self.assertEqual(hashlib.sha256(prefix.encode("utf-8")).hexdigest(), expected)
        reversal = "        if wheelRemainder * points < 0 { wheelRemainder = 0 }\n"
        self.assertEqual(prefix.count(reversal), 1)
        qualified = prefix.replace(reversal, "", 1)
        # Binding input-v2 override: physical Ctrl/Command share their side.
        qualified = qualified.replace("case 0xE0, 0xE3: return 0xA2 // Left Control / Command -> left Ctrl\n        case 0xE4, 0xE7: return 0xA3 // Right Control / Command -> right Ctrl",
                                      "case 0xE3, 0xE7: return 0xA2 // Command -> left Ctrl\n        case 0xE0, 0xE4: return 0xA3 // Control -> right Ctrl")
        self.assertEqual(hashlib.sha256(qualified.encode("utf-8")).hexdigest(),
                         "72d7fe3f8164388d339bf32aacc8a754c9c396c3a0a025b7e6fc19bcd4824b1e")
        self.assertIn("H1 fix 6", test)


if __name__ == "__main__":
    unittest.main(verbosity=2)
