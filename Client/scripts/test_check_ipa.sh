#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_IPA="$CLIENT_DIR/check_ipa.sh"
# shellcheck source=Client/scripts/ipa_validation_helpers.sh
source "$SCRIPT_DIR/ipa_validation_helpers.sh"

if grep -q 'Entitlements:' "$CHECK_IPA" || ! grep -q 'Entitlements.application-identifier' "$CHECK_IPA" || ! grep -q 'Entitlements.com.apple.developer.team-identifier' "$CHECK_IPA"; then
    ipa_fail 'check_ipa profile paths are not dot-delimited'
fi

for tool in clang lipo plutil zip; do
    command -v "$tool" >/dev/null || ipa_fail "missing fixture tool: $tool"
done
command -v /usr/libexec/PlistBuddy >/dev/null || ipa_fail 'missing fixture tool: PlistBuddy'

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/fixture.c" <<'EOF'
int screencasting_fixture(void) {
    return 0;
}
EOF
clang -target arm64-apple-ios17.0 -c "$TEMP_DIR/fixture.c" -o "$TEMP_DIR/arm64.o"
clang -target x86_64-apple-ios17.0 -c "$TEMP_DIR/fixture.c" -o "$TEMP_DIR/x86_64.o"
lipo -create "$TEMP_DIR/arm64.o" "$TEMP_DIR/x86_64.o" -output "$TEMP_DIR/fat.o"

make_ipa() {
    local output bundle_id family binary profile_source stage app plist index value
    output="$1"
    bundle_id="$2"
    family="$3"
    binary="$4"
    profile_source="${5:-}"
    stage="$TEMP_DIR/$(basename "$output" .ipa)-stage"
    app="$stage/Payload/iPadCasting.app"
    plist="$app/Info.plist"
    rm -rf "$stage"
    mkdir -p "$app"
    cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
EOF
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string iPadCasting' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :UIDeviceFamily array' "$plist"
    index=0
    for value in $family; do
        /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:$index integer $value" "$plist"
        index=$((index + 1))
    done
    cp "$binary" "$app/iPadCasting"
    if [[ -n "$profile_source" ]]; then
        cp "$profile_source" "$app/embedded.mobileprovision"
    fi
    (cd "$stage" && zip -q -r "$output" Payload)
}

positive="$TEMP_DIR/positive.ipa"
wrong_bundle="$TEMP_DIR/wrong-bundle.ipa"
iphone_family="$TEMP_DIR/iphone-family.ipa"
fat_architecture="$TEMP_DIR/fat-architecture.ipa"
make_ipa "$positive" 'com.iPadZeroLagDisplay.client' '2' "$TEMP_DIR/arm64.o"
make_ipa "$wrong_bundle" 'com.example.wrong' '2' "$TEMP_DIR/arm64.o"
make_ipa "$iphone_family" 'com.iPadZeroLagDisplay.client' '1 2' "$TEMP_DIR/arm64.o"
make_ipa "$fat_architecture" 'com.iPadZeroLagDisplay.client' '2' "$TEMP_DIR/fat.o"

CHECK_IPA_TEST_MODE=1 CHECK_IPA_MODE=unsigned EXPORT_METHOD=none "$CHECK_IPA" "$positive" >/dev/null

expect_unsigned_failure() {
    local label path method
    label="$1"
    path="$2"
    method="${3:-none}"
    if CHECK_IPA_TEST_MODE=1 CHECK_IPA_MODE=unsigned EXPORT_METHOD="$method" "$CHECK_IPA" "$path" >/dev/null 2>&1; then
        ipa_fail "$label unexpectedly passed"
    fi
}

expect_unsigned_failure 'wrong bundle fixture' "$wrong_bundle"
expect_unsigned_failure 'iPhone-family fixture' "$iphone_family"
expect_unsigned_failure 'fat-architecture fixture' "$fat_architecture"
expect_unsigned_failure 'missing provisioning fixture' "$positive" app-store

if CHECK_IPA_MODE=signed EXPORT_METHOD=app-store EXPECTED_TEAM_ID=ABCDE12345 "$CHECK_IPA" "$positive" >/dev/null 2>&1; then
    ipa_fail 'unsigned fixture unexpectedly passed signed validation'
fi

ipa_require_entitlement_profile_match \
    'ABCDE12345.com.iPadZeroLagDisplay.client' \
    'ABCDE12345' \
    'ABCDE12345.com.iPadZeroLagDisplay.client' \
    'ABCDE12345' \
    'ABCDE12345' \
    'com.iPadZeroLagDisplay.client'

if ipa_require_entitlement_profile_match \
    'ABCDE12345.com.iPadZeroLagDisplay.client' \
    'ABCDE12345' \
    'ABCDE12345.com.example.wrong' \
    'ABCDE12345' \
    'ABCDE12345' \
    'com.iPadZeroLagDisplay.client' >/dev/null 2>&1; then
    ipa_fail 'profile bundle-mismatch fixture unexpectedly passed'
fi

if ipa_require_entitlement_profile_match \
    'ABCDE12345.com.iPadZeroLagDisplay.client' \
    'ABCDE12345' \
    'ABCDE12345.com.iPadZeroLagDisplay.client' \
    'WRONGTEAM' \
    'ABCDE12345' \
    'com.iPadZeroLagDisplay.client' >/dev/null 2>&1; then
    ipa_fail 'profile team-mismatch fixture unexpectedly passed'
fi

TEAM_ID='ABCDE12345'
BUNDLE_ID='com.iPadZeroLagDisplay.client'
MOCK_BIN="$TEMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$TEMP_DIR/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
</dict></plist>
EOF

write_profile() {
    local destination profile_app_id profile_team_identifier profile_entitlement_team
    destination="$1"
    profile_app_id="$2"
    profile_team_identifier="$3"
    profile_entitlement_team="$4"
    cat > "$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>$profile_team_identifier</string></array>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>$profile_app_id</string>
<key>com.apple.developer.team-identifier</key><string>$profile_entitlement_team</string>
</dict>
</dict></plist>
EOF
}

cat > "$MOCK_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    --verify)
        exit 0
        ;;
    -dvvv)
        printf 'Identifier=%s\nTeamIdentifier=%s\n' "$MOCK_BUNDLE_ID" "$MOCK_TEAM_ID"
        ;;
    -d)
        cat "$MOCK_ENTITLEMENTS"
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == cms ]] || exit 1
output=''
while (($# > 0)); do
    if [[ "$1" == -o && $# -ge 2 ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "$output" ]]
cp "$MOCK_PROFILE_SOURCE" "$output"
EOF
chmod +x "$MOCK_BIN/codesign" "$MOCK_BIN/security"

valid_profile="$TEMP_DIR/profile-valid.plist"
bundle_mismatch_profile="$TEMP_DIR/profile-bundle-mismatch.plist"
team_mismatch_profile="$TEMP_DIR/profile-team-mismatch.plist"
signed_ipa="$TEMP_DIR/signed-profile.ipa"
bundle_mismatch_ipa="$TEMP_DIR/signed-profile-bundle-mismatch.ipa"
team_mismatch_ipa="$TEMP_DIR/signed-profile-team-mismatch.ipa"
write_profile "$valid_profile" "$TEAM_ID.$BUNDLE_ID" "$TEAM_ID" "$TEAM_ID"
write_profile "$bundle_mismatch_profile" "$TEAM_ID.com.example.wrong" "$TEAM_ID" "$TEAM_ID"
write_profile "$team_mismatch_profile" "$TEAM_ID.$BUNDLE_ID" "$TEAM_ID" WRONGTEAM
make_ipa "$signed_ipa" "$BUNDLE_ID" '2' "$TEMP_DIR/arm64.o" "$valid_profile"
make_ipa "$bundle_mismatch_ipa" "$BUNDLE_ID" '2' "$TEMP_DIR/arm64.o" "$bundle_mismatch_profile"
make_ipa "$team_mismatch_ipa" "$BUNDLE_ID" '2' "$TEMP_DIR/arm64.o" "$team_mismatch_profile"

run_mock_signed_validation() {
    local profile_source ipa_path
    profile_source="$1"
    ipa_path="$2"
    PATH="$MOCK_BIN:$PATH" \
        MOCK_ENTITLEMENTS="$TEMP_DIR/entitlements.plist" \
        MOCK_PROFILE_SOURCE="$profile_source" \
        MOCK_TEAM_ID="$TEAM_ID" \
        MOCK_BUNDLE_ID="$BUNDLE_ID" \
        CHECK_IPA_MODE=signed EXPORT_METHOD=app-store EXPECTED_TEAM_ID="$TEAM_ID" \
        "$CHECK_IPA" "$ipa_path"
}

run_mock_signed_validation "$valid_profile" "$signed_ipa" >/dev/null

if run_mock_signed_validation "$bundle_mismatch_profile" "$bundle_mismatch_ipa" >/dev/null 2>&1; then
    ipa_fail 'signed profile bundle-mismatch fixture unexpectedly passed check_ipa'
fi

if run_mock_signed_validation "$team_mismatch_profile" "$team_mismatch_ipa" >/dev/null 2>&1; then
    ipa_fail 'signed profile team-mismatch fixture unexpectedly passed check_ipa'
fi

echo 'check_ipa synthetic fixtures: PASS'
