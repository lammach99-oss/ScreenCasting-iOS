#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK_ROOT="${1:?usage: $0 <xcframework-root> <build-root>}"
BUILD_ROOT="${2:?usage: $0 <xcframework-root> <build-root>}"

require_file() { [[ -f "$1" ]] || { echo "missing file: $1" >&2; exit 1; }; }
require_dir() { [[ -d "$1" ]] || { echo "missing directory: $1" >&2; exit 1; }; }
fail() { echo "$*" >&2; exit 1; }

exact_arches() {
  local archive="$1"
  local value
  value="$(lipo -archs "$archive")"
  tr ' ' '\n' <<<"$value" | sed '/^$/d' | sort -u | paste -sd, -
}

verify_archive_arch() {
  local archive="$1" expected="$2" observed
  require_file "$archive"
  observed="$(exact_arches "$archive")"
  [[ "$observed" == "$expected" ]] || fail "wrong architecture set for $archive: expected {$expected}; got {$observed}"
  echo "ARCH PASS: $archive => {$observed}"
}

verify_archive_platform() {
  local archive="$1" expected="$2" temp object output platform
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' RETURN
  (cd "$temp" && ar -x "$archive")
  compgen -G "$temp/*.o" >/dev/null || fail "archive has no object members: $archive"
  while IFS= read -r object; do
    output="$(xcrun vtool -show-build "$object" 2>&1)" || fail "cannot inspect Mach-O platform: $object"
    platform="$(sed -n 's/.*platform[[:space:]]*//p' <<<"$output" | tr -d '[:space:]' | head -1)"
    case "$platform" in
      IOS|iOS|2) [[ "$expected" == ios ]] || fail "device/simulator platform mismatch in $object" ;;
      IOSSIMULATOR|iOSSimulator|7) [[ "$expected" == simulator ]] || fail "device/simulator platform mismatch in $object" ;;
      *) fail "unknown Apple platform '$platform' in $object" ;;
    esac
  done < <(find "$temp" -type f -name '*.o' -print)
  echo "PLATFORM PASS: $archive => $expected"
}

verify_headers() {
  local headers="$1"
  require_dir "$headers"
  find "$headers" -type f -print -quit | grep -q . || fail "empty header directory: $headers"
}

plist_value() {
  local plist="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$key" "$plist" 2>/dev/null || true
}

plist_array() {
  sed -n '/Array[[:space:]]*{/,$p' | sed -n '/}/q; /Array[[:space:]]*{/d; /^[[:space:]]*}/d; s/^[[:space:]]*//; /^[[:space:]]*$/d'
}

verify_xcframework() {
  local name="$1" device_arch="$2" simulator_arch="$3" framework
  framework="$XCFRAMEWORK_ROOT/$name.xcframework"
  local plist index identifier platform variant architectures device_count=0 simulator_count=0 total=0
  require_dir "$framework"
  plist="$framework/Info.plist"
  require_file "$plist"
  for index in $(seq 0 31); do
    identifier="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:LibraryIdentifier" "$plist" 2>/dev/null || true)"
    [[ -n "$identifier" ]] || continue
    total=$((total + 1))
    platform="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatform" "$plist" 2>/dev/null || true)"
    variant="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" "$plist" 2>/dev/null || true)"
    architectures="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedArchitectures" "$plist" 2>/dev/null | plist_array | paste -sd, - || true)"
    if [[ "$platform" == ios && -z "$variant" && "$architectures" == "$device_arch" ]]; then device_count=$((device_count + 1));
    elif [[ "$platform" == ios && "$variant" == simulator && "$architectures" == "$simulator_arch" ]]; then simulator_count=$((simulator_count + 1));
    else fail "$name.xcframework contains unexpected variant $identifier: platform=$platform variant=${variant:-device} architectures={$architectures}"; fi
  done
  [[ "$total" == 2 && "$device_count" == 1 && "$simulator_count" == 1 ]] || fail "$name.xcframework must contain exactly one device and one simulator variant"
  echo "XCFRAMEWORK PASS: $name device={$device_arch} simulator={$simulator_arch}"
}

verify_archive_arch "$BUILD_ROOT/openssl-device/install/lib/libcrypto.a" arm64
verify_archive_arch "$BUILD_ROOT/openssl-simulator/install/lib/libcrypto.a" x86_64
verify_archive_arch "$BUILD_ROOT/libsrtp-device/Release-iphoneos/libsrtp2.a" arm64
verify_archive_arch "$BUILD_ROOT/libsrtp-simulator/Release-iphonesimulator/libsrtp2.a" x86_64
verify_archive_arch "$BUILD_ROOT/opus-device/Release-iphoneos/libopus.a" arm64
verify_archive_arch "$BUILD_ROOT/opus-simulator/Release-iphonesimulator/libopus.a" x86_64

verify_archive_platform "$BUILD_ROOT/openssl-device/install/lib/libcrypto.a" ios
verify_archive_platform "$BUILD_ROOT/openssl-simulator/install/lib/libcrypto.a" simulator
verify_archive_platform "$BUILD_ROOT/libsrtp-device/Release-iphoneos/libsrtp2.a" ios
verify_archive_platform "$BUILD_ROOT/libsrtp-simulator/Release-iphonesimulator/libsrtp2.a" simulator
verify_archive_platform "$BUILD_ROOT/opus-device/Release-iphoneos/libopus.a" ios
verify_archive_platform "$BUILD_ROOT/opus-simulator/Release-iphonesimulator/libopus.a" simulator

verify_headers "$BUILD_ROOT/openssl-device/install/include"
verify_headers "$BUILD_ROOT/openssl-simulator/install/include"
verify_headers "$BUILD_ROOT/../src/libsrtp/include"
verify_headers "$BUILD_ROOT/../src/opus/include"

verify_xcframework OpenSSLCrypto arm64 x86_64
verify_xcframework libsrtp2 arm64 x86_64
verify_xcframework libopus arm64 x86_64

if find "$XCFRAMEWORK_ROOT" -type f \( -name '*.dylib' -o -name '*.framework' \) -print -quit | grep -q .; then fail 'dynamic/macOS dependency leaked into public artifacts'; fi
if find "$XCFRAMEWORK_ROOT" -type f -print0 | xargs -0 grep -IlE '/(usr/local/opt/openssl|opt/homebrew)|lib(crypto|ssl)\.dylib' 2>/dev/null | grep -q .; then fail 'macOS OpenSSL path or dylib leaked into public artifacts'; fi
echo 'DEPENDENCY_ARTIFACTS=PASS'
