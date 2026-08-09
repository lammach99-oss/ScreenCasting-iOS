#!/usr/bin/env bash
set -euo pipefail

settings="$(cat)"
selected_settings="$(awk '
  function selected_key(line) {
    return line ~ /^[[:space:]]*(CONFIGURATION_BUILD_DIR|FRAMEWORK_SEARCH_PATHS|HEADER_SEARCH_PATHS|LIBRARY_SEARCH_PATHS|OTHER_LDFLAGS|PLATFORM_NAME|SDKROOT)[[:space:]]*=/
  }
  function normalized(line) {
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*=[[:space:]]*/, "=", line)
    return line
  }
  {
    if (selected_key($0)) {
      line = normalized($0)
      print line
      in_multiline = line ~ /=[[:space:]]*\([[:space:]]*$/
      next
    }
    if (in_multiline) {
      print $0
      if ($0 ~ /^[[:space:]]*\)[[:space:]]*;?[[:space:]]*$/) {
        in_multiline = 0
      }
    }
  }
' <<<"$settings")"

fail() { echo "$*" >&2; exit 1; }
require_setting() {
  local pattern="$1" description="$2"
  grep -Eq "$pattern" <<<"$selected_settings" || fail "missing device setting: $description"
}

require_setting '^SDKROOT=iphoneos([0-9]+([.][0-9]+)*)?[[:space:]]*$' 'SDKROOT=iphoneos'
require_setting '^PLATFORM_NAME=iphoneos[[:space:]]*$' 'PLATFORM_NAME=iphoneos'
require_setting '^CONFIGURATION_BUILD_DIR=.*iphoneos' 'device CONFIGURATION_BUILD_DIR'
grep -Fq 'ThirdPartyBuild/xcframeworks' <<<"$selected_settings" || fail 'public ThirdPartyBuild/xcframeworks path missing'

if grep -Eiq 'iphonesimulator|MacOSX|/opt/homebrew|/usr/local/opt|HostService|SessionAgent|MediaWorker|DriverBroker|MttVDD' <<<"$selected_settings"; then
  fail 'simulator, macOS, or private Host dependency path selected'
fi

echo 'DEVICE_DEPENDENCY_SEARCH_PATH=PASS'
