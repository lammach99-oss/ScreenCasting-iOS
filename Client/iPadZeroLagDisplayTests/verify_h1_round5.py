"""Mirror the unchanged XCTest submission contract; no Swift execution claimed."""
from pathlib import Path
import re
import unittest

APP = Path(__file__).resolve().parents[1] / "iPadZeroLagDisplay"


def source():
    return (APP / "Renderer.swift").read_text(encoding="utf-8")


class PresentationSubmissionContracts(unittest.TestCase):
    def test_unchanged_xctest_authorization_submission_contract(self):
        # Same boundaries, regexp and all three assertions as the original test.
        renderer = source()
        start = renderer.index("let commitDecision: RenderCommitDecision =")
        present = renderer.index("commandBuffer.present(drawable)", start)
        authorization = renderer[start:present]
        success = re.sub(
            r"guard commitDecision == \.commit else \{[\s\S]*?\n        \}",
            "", authorization)
        self.assertFalse("lock.unlock()" in success,
                         "Session retirement must not run between authorization and submission")
        self.assertTrue("guard commitDecision == .commit else {\n            lock.unlock()" in authorization)
        self.assertTrue("commandBuffer.commit()\n        lock.unlock()" in renderer)

    def test_device_handler_preparation_precedes_final_locked_authorization(self):
        renderer = source()
        authorization = renderer.index("let commitDecision: RenderCommitDecision =")
        lock = renderer.rindex("        lock.lock()", 0, authorization)
        device = re.search(r"#if !targetEnvironment\(simulator\)(.*?)#endif", renderer, re.S)
        self.assertIsNotNone(device)
        self.assertLess(device.end(), lock,
                        "Prepare the callback before entering the submission critical section")
        self.assertIn("self.freshness.isCurrent(identity)", device[1])
        self.assertIn("CapturePresentationPolicy.confirmed(time: presented.presentedTime)", device[1])
        begin = renderer.split("public func beginSession(generation: UInt64)", 1)[1].split("func setPresentationMode", 1)[0]
        self.assertLess(begin.index("lock.lock()"), begin.index("freshness.beginSession"))
        self.assertLess(begin.index("freshness.beginSession"), begin.index("lock.unlock()"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
