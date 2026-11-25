"""Deterministic AU5 boundary checks; XCTest remains required on iOS."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[1] / 'iPadZeroLagDisplay'

class AuthenticationBoundaries(unittest.TestCase):
    def test_auth_messages_are_stage_checked(self):
        n = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        self.assertTrue('wifiAuthentication.receive(header.type' in n)
        self.assertTrue('wifiAuthentication.mayPersistPairing' in n)
        self.assertTrue('wifiAuthentication.sentPIN()' in n)
        sender = n.split('private lazy var controlChannelWriter', 1)[1].split('private lazy var wireParser', 1)[0]
        self.assertIn('admitWifiAuthenticationWrite(data)', sender)

    def test_usb_requires_loopback_and_identified_peer(self):
        n = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        self.assertTrue('parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback)' in n)
        finish = n.split('private func finishUsbIdentityOnQueue', 1)[1].split('private func connectionControlNow', 1)[0]
        self.assertTrue('guard identified else' in finish)
        self.assertLess(finish.index('guard identified else'), finish.index('wireAuthenticatedGeneration = generation'))

    def test_trust_is_scoped_and_forget_is_offline(self):
        n = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        self.assertTrue('trustedHostFingerprintStore.load(endpoint:' in n)
        forget = n.split('public func forgetTrustedHost(endpoint', 1)[1].split('public func stop()', 1)[0]
        self.assertIn('requestTrustedHostForget(endpoint: requestedEndpoint, useCurrentSession: false)', forget)
        offline = forget.split('guard self.transportState == .streaming', 1)[1].split('guard self.pendingTrustedHostForget', 1)[0]
        self.assertIn('self.removeLocalTrust(fingerprint, endpoint: endpoint, confirmed: false, closeSession: true)', offline)
        self.assertTrue('func load(endpoint:' in (APP / 'TrustedHostSettings.swift').read_text(encoding='utf-8'))
        self.assertIn('Button("Forget last PC"', (APP / 'ContentView.swift').read_text(encoding='utf-8'))

    def test_transfer_consent_captures_offer_and_session(self):
        n = (APP / 'NetworkManager.swift').read_text(encoding='utf-8')
        m = (APP / 'DataTransfer/DataTransferManager.swift').read_text(encoding='utf-8')
        self.assertTrue('consent: DataTransferManager.Consent' in n)
        self.assertTrue('expectedTransferID: consent.transferID' in m)
        self.assertTrue('consent.sessionID == self.sessionID' in m)
        self.assertNotIn('expectedTransferID: nil', m)

if __name__ == '__main__':
    unittest.main()
