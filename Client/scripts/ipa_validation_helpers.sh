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

ipa_require_entitlement_profile_match() {
    local signed_app_id signed_team_id profile_app_id profile_team_id expected_team expected_bundle expected_app_id
    signed_app_id="$1"
    signed_team_id="$2"
    profile_app_id="$3"
    profile_team_id="$4"
    expected_team="$5"
    expected_bundle="$6"
    expected_app_id="$expected_team.$expected_bundle"

    ipa_require_exact_value 'signed application-identifier' "$signed_app_id" "$expected_app_id"
    ipa_require_exact_value 'signed team entitlement' "$signed_team_id" "$expected_team"
    ipa_require_exact_value 'profile application-identifier' "$profile_app_id" "$expected_app_id"
    ipa_require_exact_value 'profile team identifier' "$profile_team_id" "$expected_team"
    ipa_require_exact_value 'signed/profile application-identifier' "$signed_app_id" "$profile_app_id"
    ipa_require_exact_value 'signed/profile team identifier' "$signed_team_id" "$profile_team_id"
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
