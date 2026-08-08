#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_IPA="$CLIENT_DIR/check_ipa.sh"
# shellcheck source=Client/scripts/ipa_validation_helpers.sh
source "$SCRIPT_DIR/ipa_validation_helpers.sh"

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
    local output bundle_id family binary stage app plist index value
    output="$1"
    bundle_id="$2"
    family="$3"
    binary="$4"
    stage="$TEMP_DIR/$(basename "$output" .ipa)-stage"
    app="$stage/Payload/iPadCasting.app"
    plist="$app/Info.plist"
    rm -rf "$stage"
    mkdir -p "$app"
    : > "$plist"
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

echo 'check_ipa synthetic fixtures: PASS'
