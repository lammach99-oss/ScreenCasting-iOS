"""Windows source/fixture checks only; never substitutes for XCTest or a Swift build."""
from pathlib import Path
import hashlib
import hmac
import re
import json
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Client/iPadZeroLagDisplay'

class ConnectionControlSourceTests(unittest.TestCase):
    def test_connection_screen_retains_progress_and_wifi_recovery(self):
        source = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        self.assertTrue('ConnectScreenStatus.connectionChange(' in source, 'retired route must keep operation status visible')
        dashboard = source.split('struct DisconnectedDashboard: View', 1)[1].split('struct StatusLine: View', 1)[0]
        self.assertTrue('Reconnect over Wi-Fi' in dashboard, 'failed retirement needs the explicit recovery action')
    def test_codec_and_state_exist(self):
        for name in ('ConnectionControlProtocol.swift', 'ConnectionSwitchState.swift'):
            self.assertTrue((APP / name).is_file(), name)

    def test_contract_vectors_independent(self):
        contract = (ROOT / 'docs/connection-control-contract.md').read_text(encoding='utf-8')
        swift = (ROOT / 'Client/iPadZeroLagDisplayTests/ConnectionControlProtocolTests.swift').read_text(encoding="utf-8")
        fixtures = dict(hello='hello', state='snapshot', request='request', result='accepted',
                        **{'resume-usb': 'resumeUSB', 'resume-wifi': 'resumeWiFi'})
        for name, length in [('hello', 80), ('state', 160), ('request', 32), ('result', 64), ('resume-usb', 80), ('resume-wifi', 80)]:
            value = re.search(r'<!-- vector:' + name + r' -->\s*```text\s*([\da-f\s]+)```', contract)[1]
            frame = bytes.fromhex(value)
            self.assertEqual(len(frame), 16 + length)
            self.assertEqual(int.from_bytes(frame[8:12], 'little'), length)
            expression = re.search(r'static let ' + fixtures[name] + r' = bytes\((.*?)\)\s*\n', swift, re.S)[1]
            expression = re.sub(r'String\(repeating: "00", count: (\d+)\)',
                                lambda m: '"' + '00' * int(m[1]) + '"', expression)
            self.assertEqual(bytes.fromhex(''.join(re.findall(r'"([0-9a-f]+)"', expression))), frame, name)
        tail = bytes(range(16)) + bytes(range(32, 64))
        b = b'\x01\x02' + (3).to_bytes(8, 'little') + (1).to_bytes(8, 'little') + (2).to_bytes(8, 'little') + tail
        key = bytes(range(64, 96))
        digest = lambda label, value: hmac.new(key, label + value, hashlib.sha256).digest()
        for route in (1, 2):
            context = bytes([1, route]) + b[2:]
            self.assertIn(digest(b'SCCT1-W', context).hex(), swift)
        proof = bytes(range(16)) + hmac.new(bytes(range(112, 144)), bytes(range(48, 80)) + bytes(range(80, 112)) + bytes(range(48)) + b'\x01', hashlib.sha256).digest()
        self.assertIn(proof.hex(), swift)

    def test_wire_ids_and_parser(self):
        wire = (APP / 'WireCommands.swift').read_text(encoding='utf-8')
        self.assertTrue('connectionHello = 76' in wire)
        self.assertIn('ConnectionControlProtocol.validInbound', (APP / 'WireStreamParser.swift').read_text(encoding='utf-8'))

    def test_project_membership(self):
        project = (APP / 'iPadCasting.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        for name in ('ConnectionControlProtocol', 'ConnectionSwitchState', 'ConnectionControlProtocolTests', 'ConnectionSwitchStateTests', 'ConnectionControlIntegrationTests'):
            self.assertTrue(name + '.swift in Sources' in project, name)

    def test_ordinary_listener_preparation_is_raw_and_non_destructive(self):
        source = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        body = source.split('    private func ensureRouteUsbListenerOnQueue(', 1)[1].split('    private func rejectConnectionPreflightOnQueue', 1)[0]
        for forbidden in ('stop()', 'teardownCurrentSession()', 'connectionGenerationClock.advance()', 'buildUSBListenerParameters'):
            self.assertNotIn(forbidden, body)
        self.assertIn('createOrdinaryUsbListenerOnQueue(port: port)', body)
        factory = source.split('    private func createOrdinaryUsbListenerOnQueue(', 1)[1].split('    private func installUsbCandidate', 1)[0]
        self.assertIn('let parameters = NWParameters.tcp', factory)
        self.assertIn('parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback)', factory)
        self.assertIn('NWListener(using: parameters)', factory)
        self.assertNotIn('buildUSBListenerParameters', factory)
        for removed in ('prepareRouteCandidateListenerOnQueue', 'receiveRouteCandidateProofOnQueue', 'routeCandidateProven'):
            self.assertNotIn(removed, source)

    def test_usb_identity_is_offered_and_bound_before_connection_control(self):
        source = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        self.assertTrue('USBSessionIdentityProof()' in source)
        self.assertIn('receiveUsbIdentityOnQueue', source)
        self.assertIn('finishUsbIdentityOnQueue', source)
        codec = (APP / 'ConnectionControlProtocol.swift').read_text(encoding="utf-8")
        self.assertIn('static let offerFlag: UInt16 = 0x0100', codec)
        self.assertIn('static let optInFlag: UInt16 = 0x0080', codec)
        self.assertTrue('self.usbIdentity.remainingBudget(now:' in source, 'proof deadline must retain its original budget')
        self.assertTrue('if connectionHandoffInProgress { failConnectionControlOnQueue(.identityUnavailable); return }' in source,
                        'replacement must fail without PIN enrollment')

    def test_replacement_loss_recovers_and_background_keeps_handoff_deadline(self):
        source = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        terminal = source.split('    private func setupStateHandler(', 1)[1].split('    // MARK: - Private: Auth Handshake', 1)[0]
        self.assertIn('recoverConnectionControlOnQueue(.connectionLost)', terminal)
        background = source.split('    public func applicationDidEnterBackground()', 1)[1].split('    public func ', 1)[0]
        pending = background.split('if self.connectionSwitch.pending != nil {', 1)[1].split('}', 1)[0]
        self.assertIn('self.connectionStatusTickOnQueue()', pending)
        self.assertIn('return', pending)

    def test_swift_syntax(self):
        import tree_sitter
        import tree_sitter_swift
        parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
        paths = [*APP.glob('Connection*.swift'), *Path(__file__).parent.glob('Connection*.swift')]
        paths += [APP / name for name in ('NetworkManager.swift', 'ConnectScreenModel.swift', 'SessionPanelOverlay.swift', 'ContentView.swift', 'WireCommands.swift', 'WireStreamParser.swift', 'RemoteControl/MirrorClientControl.swift')]
        for path in paths:
            self.assertFalse(parser.parse(path.read_bytes()).root_node.has_error, path.name)

    def test_send_lane_rechecks_route_input_and_transaction_ownership(self):
        source = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        sender = source.split('private lazy var controlChannelWriter', 1)[1].split('private lazy var wireParser', 1)[0]
        self.assertTrue('connectionControlPacketIsCurrent(data)' in sender)

    def test_project_ids_unique(self):
        project = (APP / 'iPadCasting.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        ids = re.findall(r'^\t\t([0-9A-F]{24}) (?:/\*.*?\*/ )?=', project, re.M)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len([i for i in ids if i.startswith('F4C1')]), 10)

    def test_new_sources_ascii(self):
        for path in [*APP.glob('Connection*.swift'), *Path(__file__).parent.glob('Connection*.swift')]:
            source = path.read_text(encoding='utf-8')
            if path.name == 'ConnectionControlProtocolTests.swift':
                # The truncation fixture deliberately exercises a multibyte character.
                source = source.replace('prefix + "\u1ebf"', 'prefix')
            self.assertTrue(source.isascii(), path.name)

    def test_existing_xctest_source_literals_still_match_changed_files(self):
        # Concrete section bodies qualify their unchanged references with owner.
        # F5 replaces these presentation expressions. All historical
        # connection-safety literals and every other source assertion remain checked.
        approved_ui_replacements = {
            ('Client/iPadZeroLagDisplay/NetworkManager.swift', 'Pair this iPad before changing connection'):
                'USB host identity could not be verified. Pair over Wi-Fi first or update the PC host.',
            ('Client/iPadZeroLagDisplay/SessionPanelOverlay.swift', 'if let performance { performance }'):
                'if let performance = owner.performance { performance }',
            ('Client/iPadZeroLagDisplay/SessionPanelOverlay.swift', '!remoteInput.usesScanKeyboard || remoteInput.keyboardEnabled'):
                'inputSession.canType',
            # Input-v2 binding policy replaces the qualified presentation wording.
            ('Client/iPadZeroLagDisplay/GestureHelp.swift', 'do not send pen pressure'):
                'No Windows pen, pressure or tilt',
            ('Client/iPadZeroLagDisplay/NetworkManager.swift', 'RemoteFeatureNegotiation(requestedFeatures: 7)'):
                'RemoteFeatureNegotiation(requestedFeatures: 0x1f)',

            ('Client/iPadZeroLagDisplay/SessionPanelOverlay.swift',
             'networkManager.requestRemoteMonitor(tile.id, catalogue: catalogue)'):
                'networkManager.requestRemoteMonitor(targetId, catalogue: catalogue)',
            ('Client/iPadZeroLagDisplay/SessionPanelOverlay.swift',
             'networkManager.requestMirrorMonitor(tile.id, catalogue: catalogue)'):
                'networkManager.requestMirrorMonitor(targetId, catalogue: catalogue)',
            # Telemetry captions now live in the full VoiceOver label, not visible text.
            ('Client/iPadZeroLagDisplay/SessionPanelOverlay.swift',
             'metric("Frame receive"'):
                'Frame receive, ',
        }
        paths = subprocess.check_output(['git', 'diff', '--name-only', '--', 'Client'], cwd=ROOT, text=True).splitlines()
        literals = []
        for path in Path(__file__).parent.glob('*.swift'):
            revision = 'HEAD:' + path.relative_to(ROOT).as_posix()
            result = subprocess.run(['git', 'show', revision], cwd=ROOT, capture_output=True)
            if result.returncode: continue
            for match in re.finditer(r'"(?:\\.|[^"\\])*"', result.stdout.decode('utf-8')):
                try: value = json.loads(match.group())
                except ValueError: continue
                if len(value) > 20: literals.append((path.name, value))
        for name in paths:
            if not name.endswith('.swift') or 'Tests/' in name: continue
            before = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT).decode('utf-8').replace('\r\n', '\n')
            after = (ROOT / name).read_text(encoding='utf-8')
            for test, literal in literals:
                if literal in before:
                    expected = approved_ui_replacements.get((name, literal), literal)
                    self.assertTrue(expected in after or expected in after.replace("owner.", ""), (name, test, expected))

if __name__ == '__main__':
    unittest.main(verbosity=2)
