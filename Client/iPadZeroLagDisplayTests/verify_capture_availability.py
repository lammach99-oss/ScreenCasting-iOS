"""Windows source contracts; does not compile Swift or execute XCTest."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Client/iPadZeroLagDisplay"


def source(name):
    p = APP / name
    return p.read_text(encoding="utf-8") if p.exists() else ""


class CaptureAvailabilityContracts(unittest.TestCase):
    def test_codec_matches_contract(self):
        s = source("CaptureAvailability.swift")
        for literal in ("0x0040", "Data([1, 0, 0, 0])", "payload.count == 8", "payload[2] == 0", "payload[3] == 0"):
            self.assertTrue(literal in s, literal)
        doc = (ROOT / "docs/capture-availability-contract.md").read_text(encoding="utf-8")
        for vector in ("5343535401500000040000000000000001000000", "534353540151000008000000000000000101000001000000"):
            self.assertIn(vector, doc)

    def test_negotiation_is_generation_bound(self):
        s = source("CaptureAvailability.swift")
        for literal in ("helloSent", "authenticated", "advertisementFlag", "generation == self.generation", "lastSequence"):
            self.assertTrue(literal in s, literal)

    def test_parser_ignores_bad_availability_without_failing_connection(self):
        s = source("WireStreamParser.swift")
        self.assertTrue("case .captureAvailabilityHello, .captureAvailability" in s)
        self.assertTrue("captureAvailability = 81" in source("WireCommands.swift"))

    def test_resume_requires_admitted_decoded_and_presented_frame(self):
        s = source("CaptureAvailability.swift")
        for literal in ("mutating func admitFrame", "mutating func observeFrame", "frame.decoded && frame.presented", "resetMediaDomain", "freshRoot"):
            self.assertIn(literal, s)

    def test_same_source_restoration_is_opt_in_and_requires_new_idr(self):
        s = source("RemoteControl/CaptureTargetState.swift")
        for literal in ("allowSameSourceReattach: Bool = false", "retainedPresentation", "anchorReattachedSource", "awaitingReattachIDR"):
            self.assertTrue(literal in s, literal)

    def test_capture_fence_preserves_input_lifetime(self):
        s = source("RemoteControl/MirrorClientControl.swift")
        self.assertTrue("func setCaptureSuspended" in s)
        self.assertTrue("mayStart: !captureSuspended" in s)

    def test_network_negotiates_and_fences_without_retiring_decoder(self):
        s = source("NetworkManager.swift")
        for literal in ("captureAvailability.hello(", "case .captureAvailability:", "captureAvailability.begin(", "func receiveCaptureAvailabilityOnQueue", "decoder.fenceCaptureContinuation()", "setCaptureSuspended(captureAvailability.inputBlocked)", "captureAvailability.observeFrame(", "captureAvailability.admitFrame("):
            self.assertTrue(literal in s, literal)
        block = s.split("private func receiveCaptureAvailabilityOnQueue", 1)[1].split("private func", 1)[0]
        self.assertNotIn("abandonCaptureTarget", block)
        self.assertNotIn("decoder.invalidate", block)
        self.assertIn("captureTargetRetireInput?()", block)

    def test_silence_suppresses_recovery_and_decoder_fence_keeps_session(self):
        s = source("RealtimeTransport/WifiMediaReceiver.swift")
        self.assertTrue("func setCaptureSuspended" in s)
        self.assertTrue("guard !captureSuspended else { return }" in s)
        s = source("DecoderManager.swift")
        self.assertTrue("func fenceCaptureContinuation" in s)
        block = s.split("func fenceCaptureContinuation", 1)[1].split("public func", 1)[0]
        self.assertNotIn("onSessionBegan?", block)
        self.assertNotIn("VTDecompressionSessionInvalidate", block)

    def test_notice_is_bare_text_announced_once_and_blocks_keyboard(self):
        s = source("SessionPanelOverlay.swift")
        for literal in ("struct CaptureAvailabilityNotice", "UIAccessibility.post(notification: .announcement", "announcement.update(message)", "!owner.networkManager.captureInputBlocked"):
            self.assertTrue(literal in s, literal)
        self.assertTrue("CaptureAvailabilityNotice(message: owner.networkManager.captureAvailabilityNotice)" in source("ContentView.swift"))
        self.assertTrue("!networkManager.captureInputBlocked" in source("MetalView.swift"))

    def test_transient_same_identity_mirror_metadata_keeps_media_without_grant(self):
        s = source("RemoteControl/MirrorClientControl.swift")
        for literal in ("captureDescriptorPending", "captureSuspended, let old=state", "next.mode == .unavailable || next.mode == .faulted"):
            self.assertTrue(literal in s, literal)

    def test_route_preserves_confirmed_source_only_for_capable_peer(self):
        self.assertTrue("preserveAppliedSource: captureAvailability.negotiated" in source("NetworkManager.swift"))
        self.assertTrue("preserveAppliedSource: Bool = false" in source("RemoteControl/CaptureTargetState.swift"))

    def test_availability_before_authentication_is_ignored(self):
        s = source("NetworkManager.swift")
        block = s.split("private func handleWireMessage", 1)[1]
        self.assertTrue('ignored=unauthenticated' in block.split('guard wireAuthenticatedGeneration == generation', 1)[0])

    def test_queued_text_cannot_cross_pause_and_resume(self):
        s = source("NetworkManager.swift").split("public func sendTextCommit", 1)[1].split("public func", 1)[0]
        self.assertTrue("requestedRevision == self.mirrorControl.gestureRevision" in s)

    def test_unavailable_catalogue_preserves_only_present_confirmed_source(self):
        self.assertTrue("preservingSuspendedPresentation: captureAvailability.inputBlocked" in source("NetworkManager.swift"))
        self.assertTrue("preservingSuspendedPresentation: Bool = false" in source("RemoteControl/CaptureTargetState.swift"))

    def test_suspend_purges_queued_starts_and_text_but_keeps_terminal_lane(self):
        s = source("NetworkManager.swift")
        self.assertTrue("controlChannelWriter.discardPending(where: CaptureAvailabilityProtocol.isNewInputPacket)" in s)
        self.assertTrue("func discardPending(where" in source("RealtimeTransport/ControlChannelWriter.swift"))
        self.assertTrue("MirrorClientControl.isRelease" in source("CaptureAvailability.swift"))

    def test_resume_uses_drawable_presentation_instead_of_gpu_completion(self):
        s = source("Renderer.swift")
        self.assertTrue("drawable.addPresentedHandler" in s)
        self.assertTrue("CapturePresentationPolicy.confirmed(time: presented.presentedTime)" in s)
        self.assertEqual(source("MetalView.swift").count("renderer.onFramePresented ="), 2)
        s = source("NetworkManager.swift").split("public func recordRenderCompletion", 1)[1].split("public func recordDrawableCommitted", 1)[0]
        self.assertNotIn("observeCaptureContinuationOnQueue", s)

    def test_project_registers_codec_and_xctest(self):
        s = source("iPadCasting.xcodeproj/project.pbxproj")
        for name in ("CaptureAvailability.swift", "SecureDesktopRecoveryTests.swift"):
            for section in ("PBXBuildFile", "PBXFileReference", "PBXGroup", "PBXSourcesBuildPhase"):
                block = s.split("/* Begin " + section + " section */", 1)[1].split("/* End " + section + " section */", 1)[0]
                self.assertTrue(name in block, (section, name))


if __name__ == "__main__":
    unittest.main(verbosity=2)
