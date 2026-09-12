#!/usr/bin/env python3
"""Regression tests for the public USB Type-C lineage verifier."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
CLIENT_ROOT = SCRIPT_DIR.parent
VERIFIER = SCRIPT_DIR / "verify_usb_type_c_lineage.py"
NETWORK = CLIENT_ROOT / "iPadZeroLagDisplay" / "NetworkManager.swift"
CONTENT = CLIENT_ROOT / "iPadZeroLagDisplay" / "ContentView.swift"


class UsbTypeCLineageVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.network = NETWORK.read_text(encoding="utf-8")
        cls.content = CONTENT.read_text(encoding="utf-8")

    def run_verifier(self, network: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            source_root = Path(temp_dir)
            source_dir = source_root / "iPadZeroLagDisplay"
            source_dir.mkdir()
            (source_dir / "NetworkManager.swift").write_text(
                network, encoding="utf-8"
            )
            (source_dir / "ContentView.swift").write_text(
                self.content, encoding="utf-8"
            )
            return subprocess.run(
                [sys.executable, str(VERIFIER), "--source-root", str(source_root)],
                capture_output=True,
                check=False,
                text=True,
            )

    def replace_once(self, source: str, old: str, new: str) -> str:
        self.assertEqual(source.count(old), 1, f"fixture anchor count for {old!r}")
        return source.replace(old, new, 1)

    def test_ping_authenticated_contract_passes(self) -> None:
        result = self.run_verifier(self.network)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("USB_TYPE_C_PUBLIC_LINEAGE=PASS", result.stdout)

    def test_ready_branch_cannot_authenticate_or_commit(self) -> None:
        ready_anchor = (
            "self.startWireReceiveLoop(generation: generation)\n"
            "                    self.recordUsbLifecycleDiagnostic("
        )
        unsafe_ready = self.replace_once(
            self.network,
            ready_anchor,
            "self.startWireReceiveLoop(generation: generation)"
            + "\n                    self.wireAuthenticatedGeneration = generation"
            + "\n                    self.commitLegacyTransport(generation: generation)"
            + "\n                    print(\"[IPAD][USB_SCDP_READY]\")"
            + "\n                    self.recordUsbLifecycleDiagnostic(",
        )

        result = self.run_verifier(unsafe_ready)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("USB ready branch contains forbidden text", result.stderr)

    def test_commit_requires_successful_pong_send(self) -> None:
        unsafe_completion = self.replace_once(
            self.network,
            "error == nil,",
            "error != nil,",
        )

        result = self.run_verifier(unsafe_completion)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ping/Pong commit sequence", result.stderr)

    def test_ping_payload_and_pong_echo_are_required(self) -> None:
        mutations = (
            ("guard header.type == .ping, payload.count == 16 else {",
             "guard header.type == .ping, payload.count == 8 else {"),
            ("payload: payload,\n                    sequence: header.sequence",
             "payload: Data(),\n                    sequence: header.sequence"),
            ("sequence: header.sequence\n                ) { [weak self] error in",
             "sequence: 0\n                ) { [weak self] error in"),
        )
        for old, new in mutations:
            with self.subTest(old=old):
                result = self.run_verifier(
                    self.replace_once(self.network, old, new)
                )
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
