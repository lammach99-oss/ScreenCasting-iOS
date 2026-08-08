#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Client/scripts/ipa_validation_helpers.sh
source "$SCRIPT_DIR/scripts/ipa_validation_helpers.sh"

IPA_PATH="${1:?usage: EXPORT_METHOD=<method> $0 <path-to-ipa-file>}"
EXPECTED_BUNDLE_IDENTIFIER="${EXPECTED_BUNDLE_IDENTIFIER:-com.iPadZeroLagDisplay.client}"
EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-iPadCasting.app}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
EXPORT_METHOD="${EXPORT_METHOD:-app-store}"
CHECK_IPA_MODE="${CHECK_IPA_MODE:-signed}"
CHECK_IPA_TEST_MODE="${CHECK_IPA_TEST_MODE:-0}"

[[ -f "$IPA_PATH" ]] || ipa_fail "missing IPA: $IPA_PATH"
case "$CHECK_IPA_MODE" in
    signed|unsigned)
        ;;
    *)
        ipa_fail "CHECK_IPA_MODE must be signed or unsigned, got $CHECK_IPA_MODE"
        ;;
esac
if [[ "$CHECK_IPA_MODE" == unsigned ]]; then
    [[ "$CHECK_IPA_TEST_MODE" == 1 ]] || ipa_fail 'unsigned mode is restricted to explicit deterministic fixtures'
fi

for tool in unzip plutil lipo; do
    command -v "$tool" >/dev/null || ipa_fail "missing required tool: $tool"
done
command -v /usr/libexec/PlistBuddy >/dev/null || ipa_fail 'missing required tool: PlistBuddy'

if [[ "$CHECK_IPA_MODE" == signed ]]; then
    [[ -n "$EXPECTED_TEAM_ID" ]] || ipa_fail 'EXPECTED_TEAM_ID is required in signed mode'
    command -v codesign >/dev/null || ipa_fail 'missing required tool: codesign'
    command -v security >/dev/null || ipa_fail 'missing required tool: security'
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TEMP_DIR"

PAYLOAD="$TEMP_DIR/Payload"
[[ -d "$PAYLOAD" ]] || ipa_fail 'missing Payload directory'
shopt -s nullglob
APP_BUNDLES=("$PAYLOAD"/*.app)
shopt -u nullglob
[[ "${#APP_BUNDLES[@]}" == 1 ]] || ipa_fail 'IPA must contain exactly one app bundle'
APP_DIR="${APP_BUNDLES[0]}"
[[ "$(basename "$APP_DIR")" == "$EXPECTED_APP_NAME" ]] || ipa_fail "unexpected app bundle: $(basename "$APP_DIR")"

PLIST="$APP_DIR/Info.plist"
[[ -f "$PLIST" ]] || ipa_fail 'missing app Info.plist'
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" || ipa_fail 'missing CFBundleIdentifier'
ipa_require_exact_value 'bundle identifier' "$bundle_id" "$EXPECTED_BUNDLE_IDENTIFIER"

family="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$PLIST" 2>/dev/null || true)"
ipa_require_ipad_only_family "$family"

executable="$(plutil -extract CFBundleExecutable raw -o - "$PLIST")" || ipa_fail 'missing CFBundleExecutable'
EXEC_PATH="$APP_DIR/$executable"
[[ -f "$EXEC_PATH" ]] || ipa_fail "missing declared executable: $EXEC_PATH"
architecture="$(lipo -archs "$EXEC_PATH" 2>/dev/null)" || ipa_fail 'unable to inspect executable architectures'
ipa_require_exact_architecture "$architecture" 'arm64'

SIGNED_APP_ID=""
SIGNED_TEAM_ID=""
if [[ "$CHECK_IPA_MODE" == signed ]]; then
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" || ipa_fail 'strict code-signature verification failed'
    signing_metadata="$(codesign -dvvv "$APP_DIR" 2>&1)" || ipa_fail 'unable to inspect code signature'
    signed_identifier="$(printf '%s\n' "$signing_metadata" | awk -F= '$1 == "Identifier" { print substr($0, index($0, "=") + 1); exit }')"
    signed_team="$(printf '%s\n' "$signing_metadata" | awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')"
    ipa_require_exact_value 'code-signature identifier' "$signed_identifier" "$EXPECTED_BUNDLE_IDENTIFIER"
    ipa_require_exact_value 'code-signature team identifier' "$signed_team" "$EXPECTED_TEAM_ID"

    signed_entitlements="$TEMP_DIR/signed-entitlements.plist"
    codesign -d --entitlements :- "$APP_DIR" > "$signed_entitlements" 2>/dev/null || ipa_fail 'unable to extract signed entitlements'
    SIGNED_APP_ID="$(plutil -extract 'application-identifier' raw -o - "$signed_entitlements")" || ipa_fail 'signed entitlements missing application-identifier'
    SIGNED_TEAM_ID="$(plutil -extract 'com.apple.developer.team-identifier' raw -o - "$signed_entitlements")" || ipa_fail 'signed entitlements missing team identifier'
fi

requires_profile=0
if ipa_method_requires_provisioning "$EXPORT_METHOD"; then
    requires_profile=1
else
    method_status=$?
    [[ "$method_status" == 1 ]] || ipa_fail "unsupported export method: $EXPORT_METHOD"
fi

profile="$APP_DIR/embedded.mobileprovision"
if [[ -f "$profile" ]]; then
    [[ "$CHECK_IPA_MODE" == signed ]] || ipa_fail 'embedded provisioning requires signed validation mode'
    security cms -D -i "$profile" -o "$TEMP_DIR/profile.plist" || ipa_fail 'unable to decode embedded provisioning profile'
    profile_app_id="$(plutil -extract 'Entitlements:application-identifier' raw -o - "$TEMP_DIR/profile.plist")" || ipa_fail 'profile missing application-identifier'
    profile_team_id="$(plutil -extract 'Entitlements:com.apple.developer.team-identifier' raw -o - "$TEMP_DIR/profile.plist")" || ipa_fail 'profile missing team entitlement'
    profile_team_identifier="$(plutil -extract 'TeamIdentifier.0' raw -o - "$TEMP_DIR/profile.plist")" || ipa_fail 'profile missing TeamIdentifier'
    ipa_require_exact_value 'profile TeamIdentifier' "$profile_team_identifier" "$EXPECTED_TEAM_ID"
    ipa_require_entitlement_profile_match "$SIGNED_APP_ID" "$SIGNED_TEAM_ID" "$profile_app_id" "$profile_team_id" "$EXPECTED_TEAM_ID" "$EXPECTED_BUNDLE_IDENTIFIER"
elif [[ "$requires_profile" == 1 ]]; then
    ipa_fail "export method $EXPORT_METHOD requires embedded.mobileprovision"
fi

if [[ "$CHECK_IPA_MODE" == signed && ! -f "$profile" ]]; then
    ipa_require_entitlement_profile_match "$SIGNED_APP_ID" "$SIGNED_TEAM_ID" "$SIGNED_APP_ID" "$SIGNED_TEAM_ID" "$EXPECTED_TEAM_ID" "$EXPECTED_BUNDLE_IDENTIFIER"
fi

echo "IPA PASS: bundle=$bundle_id family=iPad architecture=arm64 mode=$CHECK_IPA_MODE method=$EXPORT_METHOD"
