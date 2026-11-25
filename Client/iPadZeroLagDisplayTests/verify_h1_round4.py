"""Compile-boundary source checks only; Windows cannot type-check Apple SDK APIs."""
from pathlib import Path
import re
import unittest

APP = Path(__file__).resolve().parents[1] / "iPadZeroLagDisplay"


class RoundFourCompileBoundaries(unittest.TestCase):
    def test_raw_touch_constants_are_shared_with_availability_classifier(self):
        wire = (APP / "WireCommands.swift").read_text(encoding="utf-8")
        network = (APP / "NetworkManager.swift").read_text(encoding="utf-8")
        self.assertRegex(wire, r"(?m)^enum TouchWireProtocol \{")
        self.assertNotIn("enum TouchWireProtocol", network)
        self.assertIn("static let packetSize = 8", wire)

    def test_drawable_presentation_api_is_excluded_from_simulator(self):
        renderer = (APP / "Renderer.swift").read_text(encoding="utf-8")
        device = re.search(r"#if !targetEnvironment\(simulator\)(.*?)#endif", renderer, re.S)
        self.assertIsNotNone(device, "Simulator module has no drawable presentation callback")
        self.assertIn("drawable.addPresentedHandler", device[1])
        self.assertIn("(presented: MTLDrawable)", device[1])
        self.assertIn("presented.presentedTime", device[1])

    def test_simulator_fallback_requires_success_and_current_frame(self):
        renderer = (APP / "Renderer.swift").read_text(encoding="utf-8")
        completed = renderer.split("commandBuffer.addCompletedHandler", 1)[1].split("commandBuffer.commit()", 1)[0]
        self.assertIn("(completedBuffer: MTLCommandBuffer)", completed)
        fallback = re.search(r"#if targetEnvironment\(simulator\)([^#]*CapturePresentationPolicy\.simulatorCompleted.*?)#endif", completed, re.S)
        self.assertIsNotNone(fallback)
        self.assertIn("CapturePresentationPolicy.simulatorCompleted", fallback[1])
        self.assertIn("RenderCommandCompletionPolicy.succeeded(completedBuffer.status)", fallback[1])
        self.assertIn("current: isCurrent", fallback[1])
        self.assertIn("onFramePresented?(identity.sequence, identity.generation, sourceFrameSize)", fallback[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
