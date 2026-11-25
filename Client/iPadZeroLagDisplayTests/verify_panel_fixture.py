"""CI panel metadata fixtures must supply the production role and presentation receipt."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iPadZeroLagDisplay'

class PanelFixtureChecks(unittest.TestCase):
    def test_committed_fixture_publishes_the_same_remote_role_as_connect(self):
        text = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        fixture = text.split('func simulateCommittedWifiSessionForTesting(', 1)[1].split('func stopForTesting()', 1)[0]
        for token in ['remote: Bool = false', 'remoteInputConnection = remote',
                      'self.isRemoteControlSession = remote']:
            self.assertTrue(token in fixture, 'Missing fixture role: ' + token)

    def test_open_panel_fixture_supplies_a_matching_presented_frame(self):
        text = (ROOT / 'iPadZeroLagDisplayTests/SessionPanelTests.swift').read_text(encoding='utf-8')
        fixture = text.split('func testOpenPanelMetadataInHostingWindow()', 1)[1].split('private func assertHostedInWindow', 1)[0]
        for token in ['remote: variant == "remote"', 'mirrorDecoderGenerationForTesting',
                      'network.recordRenderCompletion(sequence: 0', 'XCTAssertEqual(kind, expected, variant)']:
            self.assertTrue(token in fixture, 'Incomplete panel setup: ' + token)
        self.assertIn('testMirrorPanelKindRequiresTheMatchingPresentationReceipt', text)

    def test_publication_barrier_is_causal_without_a_fixed_poll_count(self):
        text = (ROOT / 'iPadZeroLagDisplayTests/SessionPanelTests.swift').read_text(encoding='utf-8')
        fixture = text.split('func testOpenPanelMetadataInHostingWindow()', 1)[1].split('private func assertHostedInWindow', 1)[0]
        self.assertNotIn('panel model publication', fixture)
        self.assertNotIn('0..<4', fixture)
        self.assertIn('await drainPanelPublications(network)', fixture)
        self.assertIn('withCheckedContinuation', text)
        self.assertNotIn('Task.sleep', text)

    def test_hosted_controller_has_balanced_explicit_appearance_transitions(self):
        text = (ROOT / 'iPadZeroLagDisplayTests/SessionPanelTests.swift').read_text(encoding='utf-8')
        for token in ['PanelHostingContainer', 'shouldAutomaticallyForwardAppearanceMethods: Bool { false }',
                      'controller.beginAppearanceTransition(true, animated: false)',
                      'controller.beginAppearanceTransition(false, animated: false)',
                      'controller.endAppearanceTransition()', 'controller.removeFromParent()']:
            self.assertTrue(token in text, 'Incomplete hosting lifecycle: ' + token)

    def test_combined_panel_help_test_retains_the_precise_pencil_binding(self):
        text = (ROOT / 'iPadZeroLagDisplayTests/SessionPanelTests.swift').read_text(encoding='utf-8')
        test = text.split('func testPencilHelpMatchesTouchAndPointerCapabilities()', 1)[1]
        self.assertNotIn('contains("relative mouse")', test)
        self.assertNotIn('contains("touch contact")', test)
        self.assertIn('always points absolutely', test)

if __name__ == '__main__':
    unittest.main()
