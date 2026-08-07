#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:-Client/iPadZeroLagDisplay/iPadCasting.xcodeproj}"
SCHEME="${2:-iPadCasting}"
settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings)"
family="$(printf '%s\n' "$settings" | awk -F'= ' '/TARGETED_DEVICE_FAMILY/{print $2; exit}')"
if [[ "$family" != "2" ]]; then
  echo "expected TARGETED_DEVICE_FAMILY=2, got '${family:-<unset>}'" >&2
  exit 1
fi
echo "TARGETED_DEVICE_FAMILY=2 (iPad only)"
