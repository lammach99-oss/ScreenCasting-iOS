#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Client/scripts/ipa_validation_helpers.sh
source "$SCRIPT_DIR/ipa_validation_helpers.sh"

APP_PATH="${1:?usage: $0 <path-to-app>}"
EXPECTED_BUNDLE_IDENTIFIER="${EXPECTED_BUNDLE_IDENTIFIER:-com.iPadZeroLagDisplay.client}"
EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-iPadCasting.app}"

ipa_validate_unsigned_app "$APP_PATH" "$EXPECTED_APP_NAME" "$EXPECTED_BUNDLE_IDENTIFIER"
