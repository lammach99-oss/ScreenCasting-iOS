#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/verify_device_dependency_search_paths.sh"
PROJECT_FILE="$SCRIPT_DIR/../iPadZeroLagDisplay/iPadCasting.xcodeproj/project.pbxproj"

fail() { echo "$*" >&2; exit 1; }
[[ -f "$PROJECT_FILE" ]] || fail "iPad project file missing: $PROJECT_FILE"

require_target_framework_search_path() {
  local marker="$1" block
  block="$(awk -v marker="$marker" '
    index($0, marker) { in_block = 1 }
    in_block { print }
    in_block && /^[[:space:]]*};$/ { exit }
  ' "$PROJECT_FILE")"
  [[ -n "$block" ]] || fail "iPad target configuration missing: $marker"
  grep -Fq 'FRAMEWORK_SEARCH_PATHS = (' <<<"$block" ||
    fail "iPad target configuration lacks framework search paths: $marker"
  grep -Fq '$(PROJECT_DIR)/../ThirdPartyBuild/xcframeworks' <<<"$block" ||
    fail "iPad target configuration lacks public XCFramework path: $marker"
}

positive_settings() {
  cat <<'EOF'
Build settings for action build and target iPadCasting:
    EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64
    SDKROOT = iphoneos17.5
    PLATFORM_NAME = iphoneos
    CONFIGURATION_BUILD_DIR = /tmp/derived-data/Build/Products/Release-iphoneos
    FRAMEWORK_SEARCH_PATHS = (
        "$(inherited)",
        "/workspace/Client/ThirdPartyBuild/xcframeworks",
    )
    LIBRARY_SEARCH_PATHS = $(inherited)
    HEADER_SEARCH_PATHS = (
        "$(inherited)",
        "/workspace/Client/ThirdPartyBuild/xcframeworks",
    )
    OTHER_LDFLAGS = $(inherited) -framework OpenSSLCrypto
EOF
}

expect_pass() {
  local output
  output="$(positive_settings | bash "$HELPER")" || fail 'valid device settings were rejected'
  grep -Fq 'DEVICE_DEPENDENCY_SEARCH_PATH=PASS' <<<"$output" || fail 'pass marker missing'
}

expect_fail() {
  local name="$1" settings="$2"
  if bash "$HELPER" <<<"$settings" >/dev/null 2>&1; then
    fail "invalid device settings accepted: $name"
  fi
}

positive="$(positive_settings)"
require_target_framework_search_path '11111111111111111111110B /* Debug */ ='
require_target_framework_search_path '11111111111111111111110C /* Release */ ='
expect_pass
expect_fail 'selected simulator SDKROOT' "$(sed 's/SDKROOT = iphoneos17.5/SDKROOT = iphonesimulator17.5/' <<<"$positive")"
expect_fail 'selected simulator search path' "$(sed 's#/workspace/Client/ThirdPartyBuild/xcframeworks#/tmp/iphonesimulator/Selected/ThirdPartyBuild/xcframeworks#g' <<<"$positive")"
expect_fail 'selected private Host path' "$(sed 's#/workspace/Client/ThirdPartyBuild/xcframeworks#/tmp/HostService/ThirdPartyBuild/xcframeworks#g' <<<"$positive")"
expect_fail 'missing device SDKROOT' "$(sed '/SDKROOT = iphoneos/d' <<<"$positive")"
expect_fail 'missing public dependency path' "$(sed 's#ThirdPartyBuild/xcframeworks#OtherDependencies#g' <<<"$positive")"

echo 'device dependency search path fixtures: PASS'
