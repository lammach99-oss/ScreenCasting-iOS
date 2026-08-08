#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:?usage: $0 <path-to-ipa-file>}"
EXPECTED_BUNDLE_IDENTIFIER="${EXPECTED_BUNDLE_IDENTIFIER:-com.iPadZeroLagDisplay.client}"
EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-iPadCasting.app}"
REQUIRE_EMBEDDED_PROVISIONING="${REQUIRE_EMBEDDED_PROVISIONING:-1}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"

[[ -f "$IPA_PATH" ]] || { echo "missing IPA: $IPA_PATH" >&2; exit 1; }
for tool in unzip plutil lipo codesign; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }; done
command -v /usr/libexec/PlistBuddy >/dev/null || { echo 'missing required tool: PlistBuddy' >&2; exit 1; }
if [[ "$REQUIRE_EMBEDDED_PROVISIONING" == 1 ]]; then command -v security >/dev/null || { echo 'missing required tool: security' >&2; exit 1; }; fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TEMP_DIR"

PAYLOAD="$TEMP_DIR/Payload"
[[ -d "$PAYLOAD" ]] || { echo 'missing Payload directory' >&2; exit 1; }
shopt -s nullglob
APP_BUNDLES=("$PAYLOAD"/*.app)
shopt -u nullglob
[[ "${#APP_BUNDLES[@]}" == 1 ]] || { echo 'IPA must contain exactly one app bundle' >&2; exit 1; }
APP_DIR="${APP_BUNDLES[0]}"
[[ "$(basename "$APP_DIR")" == "$EXPECTED_APP_NAME" ]] || { echo "unexpected app bundle: $(basename "$APP_DIR")" >&2; exit 1; }

PLIST="$APP_DIR/Info.plist"
[[ -f "$PLIST" ]] || { echo 'missing app Info.plist' >&2; exit 1; }
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || { echo "bundle identifier mismatch: $bundle_id" >&2; exit 1; }

family="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$PLIST" 2>/dev/null || true)"
[[ "$family" == *' = 2'* && "$family" != *' = 1'* ]] || { echo "IPA is not iPad-only: $family" >&2; exit 1; }

executable="$(plutil -extract CFBundleExecutable raw -o - "$PLIST")"
EXEC_PATH="$APP_DIR/$executable"
[[ -f "$EXEC_PATH" ]] || { echo "missing declared executable: $EXEC_PATH" >&2; exit 1; }
architecture="$(lipo -archs "$EXEC_PATH" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -)"
[[ "$architecture" == 'arm64' ]] || {
  echo "IPA executable is not an exact arm64 device binary: {$architecture}" >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
signing_metadata="$(codesign -dvvv "$APP_DIR" 2>&1)" || { echo 'unable to inspect code signature' >&2; exit 1; }
grep -q "Identifier=$EXPECTED_BUNDLE_IDENTIFIER" <<<"$signing_metadata" || { echo 'code signature identifier mismatch' >&2; exit 1; }
if [[ -n "$EXPECTED_TEAM_ID" ]]; then
  grep -Eq "TeamIdentifier=$EXPECTED_TEAM_ID|TeamIdentifier=.+$EXPECTED_TEAM_ID" <<<"$signing_metadata" || { echo 'code signature team identifier mismatch' >&2; exit 1; }
fi

profile="$APP_DIR/embedded.mobileprovision"
if [[ -f "$profile" ]]; then
  security cms -D -i "$profile" -o "$TEMP_DIR/profile.plist"
  profile_app_id="$(plutil -extract Entitlements:application-identifier raw -o - "$TEMP_DIR/profile.plist")" || { echo 'provisioning profile is missing application-identifier' >&2; exit 1; }
  [[ "$profile_app_id" == *"$EXPECTED_BUNDLE_IDENTIFIER" ]] || { echo 'provisioning application identifier mismatch' >&2; exit 1; }
  if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    profile_team_id="$(plutil -extract TeamIdentifier.0 raw -o - "$TEMP_DIR/profile.plist")" || { echo 'provisioning profile is missing TeamIdentifier' >&2; exit 1; }
    [[ "$profile_team_id" == "$EXPECTED_TEAM_ID" ]] || { echo 'provisioning team identifier mismatch' >&2; exit 1; }
  fi
elif [[ "$REQUIRE_EMBEDDED_PROVISIONING" == 1 ]]; then
  echo 'missing embedded.mobileprovision' >&2
  exit 1
fi

echo "IPA PASS: bundle=$bundle_id family=iPad architecture=arm64"
