#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/verify_device_dependency_search_paths.sh"

fail() { echo "$*" >&2; exit 1; }

positive_settings() {
  cat <<'EOF'
Build settings for action build and target iPadCasting:
    EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64
    SDKROOT = iphoneos
    PLATFORM_NAME = iphoneos
    CONFIGURATION_BUILD_DIR = /tmp/derived-data/Build/Products/Release-iphoneos
    FRAMEWORK_SEARCH_PATHS = $(inherited) /workspace/Client/ThirdPartyBuild/xcframeworks
    LIBRARY_SEARCH_PATHS = $(inherited)
    HEADER_SEARCH_PATHS = $(inherited) /workspace/Client/ThirdPartyBuild/xcframeworks
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
expect_pass
expect_fail 'selected simulator search path' "$(sed 's#FRAMEWORK_SEARCH_PATHS = .*#FRAMEWORK_SEARCH_PATHS = /tmp/iphonesimulator/Selected/ThirdPartyBuild/xcframeworks#' <<<"$positive")"
expect_fail 'selected private Host path' "$(sed 's#FRAMEWORK_SEARCH_PATHS = .*#FRAMEWORK_SEARCH_PATHS = /tmp/HostService/ThirdPartyBuild/xcframeworks#' <<<"$positive")"
expect_fail 'missing device SDKROOT' "$(sed '/SDKROOT = iphoneos/d' <<<"$positive")"
expect_fail 'missing public dependency path' "$(sed 's#ThirdPartyBuild/xcframeworks#OtherDependencies#g' <<<"$positive")"

echo 'device dependency search path fixtures: PASS'
