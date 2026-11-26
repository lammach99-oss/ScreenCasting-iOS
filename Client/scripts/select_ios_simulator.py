"""Select an available simulator on the requested iOS runtime (or latest >= 17)."""
import json
import subprocess
import sys


def select(devices, family, requested):
    candidates = []
    for runtime, entries in devices.items():
        prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        if not runtime.startswith(prefix):
            continue
        version = runtime[len(prefix):].replace("-", ".")
        if requested != "latest" and version != requested:
            continue
        parts = tuple(map(int, version.split(".")))
        if parts[0] < 17:
            continue
        for device in entries:
            if (device.get("isAvailable") and device.get("deviceTypeIdentifier", "").startswith(
                    "com.apple.CoreSimulator.SimDeviceType." + family + "-")):
                candidates.append((parts, device["udid"]))
    if not candidates:
        raise SystemExit(f"No available {family} simulator for iOS {requested}")
    return max(candidates)[1]


if __name__ == "__main__":
    listing = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    print(select(json.loads(listing)["devices"], *sys.argv[1:]))
