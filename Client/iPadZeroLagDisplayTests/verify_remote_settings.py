"""H1 remote settings compatibility guards; XCTest is the runtime gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iPadZeroLagDisplay'

def read(name):
    return (APP / name).read_text(encoding='utf-8')

class RemoteSettingsChecks(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        self.assertTrue(member in container, msg or 'Missing settings contract: ' + member)

    def test_picture_controls_and_explanations(self):
        view = read('SettingsView.swift')
        picker = view.split('private var performancePicker:', 1)[1].split('var body:', 1)[0]
        for label in ('Frame rate', 'Smooth, 60 frames per second', 'Fast motion, up to 120 frames per second'):
            self.assertIn(f'.accessibilityLabel("{label}")', picker)
        self.assertIn('Smooth keeps a steady 60 frames per second. Fast motion uses up to 120 for games and video.', view)
        self.assertIn('Auto quality is saved for this PC. Using manual for this connection.', view)
        self.assertIn('switchTint: owner.switchTint', view)
        self.assertIn('.tint(switchTint)', view.split('struct AdaptiveQualityControls:', 1)[1])

    def test_files_and_troubleshooting_labels(self):
        view = read('SettingsView.swift')
        row = view.split('Text("Send or open files")', 1)[1].split('} header:', 1)[0]
        self.assertIn('.foregroundStyle(Color(uiColor: SessionInk.text))', row)
        self.assertIn('LabeledContent("PC is using"', view)
        self.assertIn('LabeledContent("Effective quality", value: summary)', view)

    def test_showing_row_feedback(self):
        view = read('SessionPanelOverlay.swift')
        row = view.split('struct ScreenSwitchButton: View', 1)[1].split('struct ModeChoices:', 1)[0]
        self.assertRegex(row, r'if owner\.cycle\.enabled\s*\{\s*Image\(systemName: "chevron.right"')
        self.assertIn('Text(owner.cycle.hint)', row)
        self.assertIn('.accessibilityHint(owner.cycle.hint)', row)
        self.assertIn('.accessibilityLabel(owner.cycle.accessibilityLabel)', row)
        self.assertIn('cycle.count > 0 || cycle.showingTypedExtend', view)

    def test_versioned_get_is_sent_for_every_committed_session(self):
        model = read('TrustedHostSettings.swift')
        self.assertIn('enum ClientSettingsWireCodec', model)
        get = model.split('static func get(requestID:', 1)[1].split('\n}', 1)[0]
        self.assertIn('payload[0] = 1', get)
        self.assertIn('payload.storeLittleEndian(requestID, at: 4)', get)
        network = read('NetworkManager.swift')
        request = network.split('private func requestCurrentSettingsIfNeeded(', 1)[1].split('public func forgetTrustedHost(', 1)[0]
        self.assertNotIn('activeTransportKind == .usb', request)
        self.assertIn('ClientSettingsWireCodec.get(requestID: requestID)', request)
        self.assertIn('wireAuthenticatedGeneration == generation', request)
        self.assertIn('committedTransportGeneration == generation', request)
        commit = network.split('committedTransportAudioAvailable = audioEnabled', 1)[1].split('private func clearPendingTransportOffer', 1)[0]
        self.assertLess(commit.index('requestCurrentSettingsIfNeeded(generation: generation)'), commit.index('if activeTransportKind == .usb'))

    def test_arbitrary_bps_stay_exact_and_rounding_cannot_reconcile_a_write(self):
        model = read('TrustedHostSettings.swift')
        decode = model.split('struct TrustedSettingsState:', 1)[1]
        self.assertNotIn('isMultiple(of: 1_000_000)', decode)
        self.assertIn('Double(bitrateBps) / 1_000_000', decode)
        self.assertIn('matchesReportedSettings', model)
        receive = read('NetworkManager.swift').split('func receiveSettingsState(', 1)[1].split('private func receiveAuthResponse', 1)[0]
        self.assertIn('let effective = state.preference', receive)
        self.assertNotIn('ClientStreamSettingsPreference.normalized(', receive)

    def test_remote_projection_is_enforced_at_send_and_rejection_cannot_loop(self):
        model = read('TrustedHostSettings.swift')
        projection = model.split('func forSession(remote: Bool, manualFallback: Bool = false)', 1)[1].split('\n    }', 1)[0]
        self.assertIn('audioEnabled: remote ? false : audioEnabled', projection)
        self.assertIn('adaptiveBitrateEnabled: !remote && !manualFallback && adaptiveBitrateEnabled', projection)
        decision = model.split('struct ClientSettingsReconciliationGate', 1)[1].split('struct ClientSettingsStateModel', 1)[0]
        self.assertIn('remote: Bool = false', decision)
        self.assertIn('if remote {', decision)
        self.assertLess(decision.index('if remote {'), decision.index('reason == .staleGeneration'))
        network = read('NetworkManager.swift')
        send = network.split('private func sendDesiredSettingsIfPossible(', 1)[1].split('private func requestCurrentSettingsIfNeeded', 1)[0]
        self.assertIn('ClientSettingsWireCodec.update(', send)
        self.assertIn('remote: remoteInputConnection', send)
        receive = network.split('func receiveSettingsState(', 1)[1].split('private func receiveAuthResponse', 1)[0]
        self.assertIn('remote: remoteInputConnection', receive)
        self.assertIn('if remoteInputConnection {', receive)

    def test_remote_controls_cannot_send_unsupported_options(self):
        view = read('SettingsView.swift')
        self.assertEqual(view.count('.disabled(!owner.supportsAudioAndAuto'), 2)
        self.assertIn('let manualFallback = owner.networkManager.legacyAutomaticBitrateUnavailable', view)
        self.assertIn('.disabled(!owner.supportsAudioAndAuto || manualFallback)', view)
        self.assertIn('let automaticBitrate = owner.draftAdaptiveBitrateEnabled && owner.supportsAudioAndAuto && !manualFallback', view)
        visibility = view.split('func showsBitrateSlider(autoQuality: Bool, automaticBitrate: Bool) -> Bool {', 1)[1]
        self.assertEqual(visibility.split('}', 1)[0].strip(), '!autoQuality && !automaticBitrate')
        lines = view.splitlines()
        start = next(i for i, line in enumerate(lines) if line.lstrip().startswith('if SettingsCopy.showsBitrateSlider('))
        indent = lines[start][:len(lines[start]) - len(lines[start].lstrip())]
        end = lines.index(indent + '}', start + 1)
        block = ' '.join(' '.join(lines[start:end]).split())
        self.assertTrue(block.startswith('if SettingsCopy.showsBitrateSlider(autoQuality: owner.networkManager.autoQualityEnabled, '
                                         'automaticBitrate: automaticBitrate) {'))
        self.assertIn('Slider(value: owner.$draftBitrate', block)
        self.assertIn('ClientStreamSettingsPreference.remoteUnsupportedReason', view)
        self.assertIn('if !owner.supportsAudioAndAuto { return }', view)
        self.assertIn('guard owner.supportsAudioAndAuto, !manualFallback else { return }', view)

    def test_real_writer_regressions_use_queue_safe_non_audio_seams(self):
        network = read('NetworkManager.swift')
        self.assertIn('func requestCurrentSettingsForTesting(generation:', network)
        self.assertIn('func sendDesiredSettingsForTesting()', network)
        tests = (ROOT / 'iPadZeroLagDisplayTests/TransportNegotiationTests.swift').read_text(encoding='utf-8')
        body = tests.split('final class RemoteSettingsCompatibilityTests:', 1)[1].split('final class VideoThroughputV1Tests:', 1)[0]
        for token in ['receiveCaptureTargetWireForTesting', 'beginTransferWriterForTesting()',
                      'controlSendForAudioTesting', 'realtimeAudioPlaybackForTesting',
                      'withCheckedContinuation', 'testCastingStillAutomaticallyReconcilesAudioAndAutoAndPreservesExactReadback']:
            self.assertIn(token, body)
        for forbidden in ['sleep(', 'AVAudioEngine', 'commitAudioTransportForTesting']:
            self.assertNotIn(forbidden, body)

if __name__ == '__main__':
    unittest.main()
