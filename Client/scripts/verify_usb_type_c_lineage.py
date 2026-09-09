#!/usr/bin/env python3
"""Fail closed when the public iPad source loses the canonical USB-C contract."""

from pathlib import Path
import argparse
import re
import sys


def fail(message: str) -> None:
    print(f"USB Type-C lineage verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def section(source: str, start: str, end: str, name: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        fail(f"missing {name} start anchor: {start}")
    end_index = source.find(end, start_index + len(start))
    if end_index < 0:
        fail(f"missing {name} end anchor: {end}")
    return source[start_index:end_index]


def require(source: str, text: str, name: str) -> None:
    if text not in source:
        fail(f"{name} is missing: {text}")


def reject(source: str, text: str, name: str) -> None:
    if text in source:
        fail(f"{name} contains forbidden text: {text}")


def require_order(source: str, values: list[str], name: str) -> None:
    offset = 0
    for value in values:
        index = source.find(value, offset)
        if index < 0:
            fail(f"{name} is missing ordered step: {value}")
        offset = index + len(value)


parser = argparse.ArgumentParser()
parser.add_argument(
    "--source-root",
    type=Path,
    default=Path(__file__).resolve().parents[1],
    help="Client source root; defaults to the checkout containing this script.",
)
args = parser.parse_args()
source_root = args.source_root.resolve()

network_path = source_root / "iPadZeroLagDisplay" / "NetworkManager.swift"
content_path = source_root / "iPadZeroLagDisplay" / "ContentView.swift"
if not network_path.is_file() or not content_path.is_file():
    fail(f"expected client source files under {source_root}")

network = network_path.read_text(encoding="utf-8")
content = content_path.read_text(encoding="utf-8")

listener = section(
    network,
    "public func startListening(port: UInt16 = 42042)",
    "private func nextUsbTouchDiagnostic",
    "USB listener",
)
require(listener, "NWListener(", "USB listener")
if not re.search(r"NWListener\(\s*using:\s*\.tcp,\s*on:\s*listenerPort\)", listener):
    fail("USB listener is not plain NWParameters.tcp")
reject(listener, "buildUSBListenerParameters", "USB listener")
reject(listener, "awaitingPIN", "USB listener")
reject(listener, "12345", "USB listener")
require(listener, "[IPAD][USB_SCDP_LISTENING]", "USB listener diagnostic")

accepted = section(
    listener,
    "listener.newConnectionHandler",
    "listener.start(queue: networkQueue)",
    "accepted USB connection",
)
require_order(
    accepted,
    [
        "self.usbScdpConnection = newConnection",
        "self.connection = newConnection",
        "self.setupStateHandler(for: newConnection)",
        "newConnection.start(queue: self.networkQueue)",
    ],
    "accepted USB connection identity",
)

require(network, "private var usbScdpConnection: NWConnection?", "dedicated USB connection")
require(
    network,
    "activeTransportKind == .usb ? usbScdpConnection : connection",
    "active control connection routing",
)

state_handler = section(
    network,
    "private func setupStateHandler(for connection: NWConnection)",
    "// MARK: - Private: Auth Handshake",
    "connection state handler",
)
require(state_handler, "self.usbScdpConnection !== connection", "accepted-connection identity guard")
usb_ready = section(
    state_handler,
    "} else {",
    "case .failed",
    "USB ready branch",
)
require_order(
    usb_ready,
    [
        "self.startWireReceiveLoop(generation: generation)",
        "self.wireAuthenticatedGeneration = generation",
        "self.commitLegacyTransport(generation: generation)",
        "[IPAD][USB_SCDP_READY]",
    ],
    "USB receive/authenticate/commit sequence",
)
reject(usb_ready, "awaitingPIN", "USB ready branch")

transport_anchor = content.find('Picker("Connection Transport"')
if transport_anchor < 0:
    fail("missing connection transport controls")
transport_controls = content[transport_anchor:]

mode_change = section(
    transport_controls,
    ".onChange(of: useUSBMode)",
    "if useUSBMode {",
    "USB mode selection",
)
require(mode_change, "networkManager.stop()", "USB mode selection reset")
reject(mode_change, "startListening", "USB mode selection")

wifi_fields = section(
    transport_controls,
    "if !useUSBMode {",
    "Button(action:",
    "Wi-Fi-only fields",
)
require(wifi_fields, 'SecureField("4-digit PIN Code"', "Wi-Fi PIN field")

start_action = section(
    transport_controls,
    "Button(action:",
    "Label(",
    "explicit connection action",
)
require(start_action, "if useUSBMode", "explicit USB action")
require(start_action, "networkManager.startListening(port: 42042)", "explicit USB listener start")
reject(start_action, "12345", "explicit USB action")

for marker in (
    "[USB_TOUCH_SEND_GUARD]",
    "[USB_TOUCH_SEND_ATTEMPT]",
    "[USB_TOUCH_SEND_SUCCESS]",
    "[USB_TOUCH_SEND_FAILURE]",
):
    require(network, marker, "USB touch diagnostics")

print("USB_TYPE_C_PUBLIC_LINEAGE=PASS")
