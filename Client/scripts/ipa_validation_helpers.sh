#!/usr/bin/env bash

ipa_fail() {
    printf 'IPA validation failed: %s\n' "$1" >&2
    return 1
}

ipa_require_exact_architecture() {
    local actual expected label normalized
    actual="$1"
    expected="$2"
    label="${3:-executable architecture}"
    normalized="$(printf '%s\n' "$actual" | awk '{$1=$1; print}')"
    [[ "$normalized" == "$expected" ]] || ipa_fail "$label must be exactly $expected, got ${normalized:-<empty>}"
}

ipa_require_ipad_only_family() {
    local family_entries
    family_entries="$(printf '%s\n' "$1" | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/{print $1}')"
    [[ "$family_entries" == '2' ]] || ipa_fail "UIDeviceFamily must contain only 2, got ${family_entries:-<empty>}"
}

ipa_require_exact_value() {
    local label actual expected
    label="$1"
    actual="$2"
    expected="$3"
    [[ -n "$actual" && "$actual" == "$expected" ]] || ipa_fail "$label mismatch: expected $expected, got ${actual:-<empty>}"
}

ipa_require_unsigned_material_absent() {
    local app_dir="$1" forbidden
    if [[ -e "$app_dir/_CodeSignature" || -e "$app_dir/embedded.mobileprovision" ]]; then
        ipa_fail 'unsigned app contains signing material'
        return 1
    fi
    forbidden="$(find "$app_dir" -type f \( -iname '*.p12' -o -iname '*.pfx' -o -iname '*.pem' -o -iname '*.mobileprovision' -o -iname '*.key' \) -print -quit)"
    [[ -z "$forbidden" ]] || { ipa_fail "unsigned app contains forbidden signing file: $forbidden"; return 1; }
}

ipa_require_public_content_boundary() {
    local root="$1" file
    local forbidden_pattern='HostService|SessionAgent|MediaWorker|DriverBroker|MttVDD|/(Users|home)/|[A-Za-z]:[/\\](Users|AI Agent)'
    while IFS= read -r -d '' file; do
        if grep -IEq "$forbidden_pattern" "$file"; then
            ipa_fail "private Host or developer-local path found in unsigned app: $file"
            return 1
        fi
    done < <(find "$root" -type f -print0)
}

ipa_require_no_simulator_linkage() {
    local executable="$1" linked
    command -v otool >/dev/null || { ipa_fail 'missing required tool: otool'; return 1; }
    linked="$(otool -L "$executable" 2>&1)" || { ipa_fail 'unable to inspect unsigned app linkage'; return 1; }
    if printf '%s\n' "$linked" | grep -Eiq 'iphonesimulator|MacOSX|/opt/homebrew|/usr/local/opt/(openssl|libsrtp|opus)|HostService|SessionAgent|MediaWorker|DriverBroker|MttVDD'; then
        ipa_fail 'unsigned app contains simulator, macOS, or private Host linkage'
        return 1
    fi
    echo 'UNSIGNED_LINKAGE=PASS'
}

ipa_validate_unsigned_app() {
    local app_dir="$1" expected_app_name="$2" expected_bundle_id="$3"
    local plist bundle_id family executable executable_path architecture
    [[ -d "$app_dir" ]] || { ipa_fail "missing unsigned app: $app_dir"; return 1; }
    [[ "$(basename "$app_dir")" == "$expected_app_name" ]] || { ipa_fail "unexpected unsigned app bundle: $(basename "$app_dir")"; return 1; }
    plist="$app_dir/Info.plist"
    [[ -f "$plist" ]] || { ipa_fail 'unsigned app missing Info.plist'; return 1; }
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")" || { ipa_fail 'unsigned app missing CFBundleIdentifier'; return 1; }
    ipa_require_exact_value 'unsigned app bundle identifier' "$bundle_id" "$expected_bundle_id" || return 1
    family="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$plist" 2>/dev/null || true)"
    ipa_require_ipad_only_family "$family" || return 1
    executable="$(plutil -extract CFBundleExecutable raw -o - "$plist")" || { ipa_fail 'unsigned app missing CFBundleExecutable'; return 1; }
    executable_path="$app_dir/$executable"
    [[ -f "$executable_path" ]] || { ipa_fail "unsigned app missing declared executable: $executable_path"; return 1; }
    architecture="$(lipo -archs "$executable_path" 2>/dev/null)" || { ipa_fail 'unable to inspect unsigned app architectures'; return 1; }
    ipa_require_exact_architecture "$architecture" arm64 'unsigned app executable architecture' || return 1
    ipa_require_unsigned_material_absent "$app_dir" || return 1
    ipa_require_public_content_boundary "$app_dir" || return 1
    ipa_require_no_simulator_linkage "$executable_path" || return 1
    echo 'UNSIGNED_APP_VALIDATION=PASS'
}

ipa_require_entitlement_profile_match() {
    local signed_app_id signed_team_id profile_app_id profile_team_id expected_team expected_bundle expected_app_id
    signed_app_id="$1"
    signed_team_id="$2"
    profile_app_id="$3"
    profile_team_id="$4"
    expected_team="$5"
    expected_bundle="$6"
    expected_app_id="$expected_team.$expected_bundle"

    ipa_require_exact_value 'signed application-identifier' "$signed_app_id" "$expected_app_id" || return 1
    ipa_require_exact_value 'signed team entitlement' "$signed_team_id" "$expected_team" || return 1
    ipa_require_exact_value 'profile application-identifier' "$profile_app_id" "$expected_app_id" || return 1
    ipa_require_exact_value 'profile team identifier' "$profile_team_id" "$expected_team" || return 1
    ipa_require_exact_value 'signed/profile application-identifier' "$signed_app_id" "$profile_app_id" || return 1
    ipa_require_exact_value 'signed/profile team identifier' "$signed_team_id" "$profile_team_id" || return 1
}

ipa_method_requires_provisioning() {
    case "$1" in
        app-store|ad-hoc|development|enterprise)
            return 0
            ;;
        validation|none)
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}
