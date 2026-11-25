"""Deterministic source contracts, not Apple SDK or XCTest execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Client/iPadZeroLagDisplay"


def source(name):
    return (APP / name).read_text(encoding="utf-8")


class CaptureReadinessDeadlines(unittest.TestCase):
    def test_progress_deadlines_use_active_clock_and_generation_reset_unfreezes(self):
        state = source("CaptureAvailability.swift")
        network = source("NetworkManager.swift")
        self.assertIn("struct CaptureReadinessClock", state)
        self.assertIn("captureReadinessClock.setSuspended(false", network)
        self.assertIn("captureReadinessClock.setSuspended(captureAvailability.inputBlocked", network)
        self.assertIn("captureReadinessClock.now(at: connectionControlNow())", network)
        tick = network.split("private func connectionStatusTickOnQueue", 1)[1].split("private func", 1)[0]
        self.assertIn("let now = connectionControlNow()", tick)
        scheduler = network.split("private func scheduleCaptureTargetCallback", 1)[1].split("private func cancelCaptureTargetRecovery", 1)[0]
        self.assertIn("let deadline = captureReadinessNow() + seconds", scheduler)
        self.assertIn("let remaining = deadline - self.captureReadinessNow()", scheduler)

    def test_resume_requires_capturing_and_post_message_receipt(self):
        state = source("CaptureAvailability.swift")
        self.assertIn("mutating func noteFrameReceived", state)
        self.assertIn("receivedAfterResume", state)
        self.assertIn("guard !wireSuspended", state)
        self.assertNotIn("!wireSuspended || frame.isIDR", state)
        network = source("NetworkManager.swift")
        self.assertGreaterEqual(network.count("captureAvailability.noteFrameReceived"), 3)
        self.assertIn("captureAvailability.mayPresent", network)

    def test_render_fence_is_synchronous_and_keeps_displayed_picture(self):
        decoder = source("DecoderManager.swift")
        block = decoder.split("func fenceCaptureContinuation(requiringAuthorization: Bool = true)", 1)[1].split("public func", 1)[0]
        self.assertIn("captureDeliveryLock.lock()", block)
        self.assertIn("onCaptureFenced?(", block)
        renderer = source("Renderer.swift")
        self.assertIn("mutating func fenceCaptureContinuation()", renderer)
        block = renderer.split("func fenceCaptureContinuation(generation:", 1)[1].split("func setPresentationMode", 1)[0]
        for text in ["lock.lock()", "freshness.fenceCaptureContinuation()", "officeHandoff.reset()", "gameHandoff.reset()"]:
            self.assertIn(text, block)
        self.assertNotIn("gameLastPresentedFrame = nil", block)
        self.assertNotIn("beginSession(", block)
        self.assertEqual(source("MetalView.swift").count("decoder.onCaptureFenced ="), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
