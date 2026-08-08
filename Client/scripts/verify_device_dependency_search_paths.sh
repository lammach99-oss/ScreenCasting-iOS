#!/usr/bin/env bash
set -euo pipefail

settings="$(cat)"
selected_settings="$(awk '
  /^[[:space:]]*(CONFIGURATION_BUILD_DIR|FRAMEWORK_SEARCH_PATHS|HEADER_SEARCH_PATHS|LIBRARY_SEARCH_PATHS|OTHER_LDFLAGS|PLATFORM_NAME|SDKROOT)[[:space:]]*=/ {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    gsub(/[[:space:]]*=[[:space:]]*/, "=", line)
    print line
  }
' <<<"$settings")"

fail() { echo "$*" >&2; exit 1; }
require_setting() {
  local pattern="$1" description="$2"
  grep -Eq "$pattern" <<<"$selected_settings" || fail "missing device setting: $description"
}

require_setting '^SDKROOT=iphoneos[[:space:]]*$' 'SDKROOT=iphoneos'
require_setting '^PLATFORM_NAME=iphoneos[[:space:]]*$' 'PLATFORM_NAME=iphoneos'
require_setting '^CONFIGURATION_BUILD_DIR=.*iphoneos' 'device CONFIGURATION_BUILD_DIR'
grep -Fq 'ThirdPartyBuild/xcframeworks' <<<"$selected_settings" || fail 'public ThirdPartyBuild/xcframeworks path missing'

if grep -Eiq 'iphonesimulator|MacOSX|/opt/homebrew|/usr/local/opt|HostService|SessionAgent|MediaWorker|DriverBroker|MttVDD' <<<"$selected_settings"; then
  fail 'simulator, macOS, or private Host dependency path selected'
fi

echo 'DEVICE_DEPENDENCY_SEARCH_PATH=PASS'
