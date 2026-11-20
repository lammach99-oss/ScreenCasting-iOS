"""DS7 integration checks runnable without Xcode."""
from pathlib import Path
import unittest


APP = Path(__file__).resolve().parents[1] / "iPadZeroLagDisplay"
NETWORK = (APP / "NetworkManager.swift").read_text(encoding="utf-8")


class SecureDesktopWiring(unittest.TestCase):
    def test_opt_in_and_authenticated_state_are_wired(self):
        self.assertTrue("requestSecureDesktop: remoteSecureDesktopEnabled" in NETWORK)
        self.assertTrue("remoteFeaturesPingChallenge == payload" in NETWORK)
        self.assertTrue("case .remoteSecureDesktopState:" in NETWORK)
        self.assertTrue("receiveRemoteSecureDesktopOnQueue(header, payload: payload)" in NETWORK)

    def test_ack_comes_from_renderer_presentation(self):
        callback = NETWORK.split("func recordCapturePresentation(", 1)[1].split("\n    }", 1)[0]
        self.assertTrue("remoteSecureDesktop.presented(sequence: sequence, decoder: generation)" in callback)
        self.assertTrue("sendRemoteSecureDesktopOnQueue(ack)" in callback)

    def test_cover_and_sas_are_wired(self):
        content = (APP / "ContentView.swift").read_text(encoding="utf-8")
        panel = (APP / "SessionPanelOverlay.swift").read_text(encoding="utf-8")
        self.assertTrue("if networkManager.remoteSecureDesktopCovered" in content)
        self.assertTrue("if owner.networkManager.remoteSecureDesktopCanSas" in panel)
        self.assertTrue("return remoteSecureDesktop.canSas" in NETWORK)

    def test_main_queue_rejects_superseded_secure_desktop_snapshots(self):
        publish = NETWORK.split("func publishRemoteSecureDesktopOnQueue()", 1)[1].split("\n    }", 1)[0]
        fence = publish.find("remoteSecureDesktopPublicationClock.advance()")
        dispatch = publish.index("DispatchQueue.main.async")
        validate = publish.find("remoteSecureDesktopPublicationClock.current == publication")
        reveal = publish.index("self.remoteSecureDesktopCovered = secure.covered")
        self.assertGreaterEqual(fence, 0)
        self.assertLess(fence, dispatch)
        self.assertLess(dispatch, validate)
        self.assertLess(validate, reveal)


if __name__ == "__main__":
    unittest.main()
