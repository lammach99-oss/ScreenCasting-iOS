#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK_ROOT="${1:?usage: $0 <xcframework-root> <build-root>}"
BUILD_ROOT="${2:?usage: $0 <xcframework-root> <build-root>}"

require_file() { [[ -f "$1" ]] || { echo "missing file: $1" >&2; exit 1; }; }
require_dir() { [[ -d "$1" ]] || { echo "missing directory: $1" >&2; exit 1; }; }

verify_archive_arch() {
  local archive="$1" expected="$2" observed
  require_file "$archive"
  command -v lipo >/dev/null || { echo "missing required tool: lipo" >&2; exit 1; }
  observed="$(lipo -info "$archive")"
  grep -Eq "(^|[[:space:]])${expected}([[:space:]]|$)" <<<"$observed" || {
    echo "wrong architecture for $archive: expected $expected; got $observed" >&2
    exit 1
  }
  echo "ARCH PASS: $archive => $observed"
}

verify_headers() {
  local headers="$1"
  require_dir "$headers"
  find "$headers" -type f -print -quit | grep -q . || {
    echo "empty header directory: $headers" >&2
    exit 1
  }
}

verify_xcframework() {
  local name="$1" device_arch="$2" simulator_arch="$3" framework="$XCFRAMEWORK_ROOT/$name.xcframework" plist index platform variant architectures found_device=0 found_simulator=0
  require_dir "$framework"
  plist="$framework/Info.plist"
  require_file "$plist"
  command -v plutil >/dev/null || { echo "missing required tool: plutil" >&2; exit 1; }
  command -v /usr/libexec/PlistBuddy >/dev/null || { echo "missing required tool: PlistBuddy" >&2; exit 1; }

  for index in 0 1 2 3 4 5 6 7; do
    platform="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatform" "$plist" 2>/dev/null || true)"
    [[ -n "$platform" ]] || continue
    variant="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" "$plist" 2>/dev/null || true)"
    architectures="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedArchitectures" "$plist" 2>/dev/null || true)"
    if [[ "$platform" == ios && -z "$variant" && "$architectures" == *"$device_arch"* ]]; then found_device=1; fi
    if [[ "$platform" == ios && "$variant" == simulator && "$architectures" == *"$simulator_arch"* ]]; then found_simulator=1; fi
  done
  [[ "$found_device" == 1 ]] || { echo "$name.xcframework lacks ios device $device_arch metadata" >&2; exit 1; }
  [[ "$found_simulator" == 1 ]] || { echo "$name.xcframework lacks ios simulator $simulator_arch metadata" >&2; exit 1; }
  echo "PLATFORM PASS: $name device=$device_arch simulator=$simulator_arch"
}

verify_archive_arch "$BUILD_ROOT/openssl-device/install/lib/libcrypto.a" arm64
verify_archive_arch "$BUILD_ROOT/openssl-simulator/install/lib/libcrypto.a" x86_64
verify_archive_arch "$BUILD_ROOT/libsrtp-device/Release-iphoneos/libsrtp2.a" arm64
verify_archive_arch "$BUILD_ROOT/libsrtp-simulator/Release-iphonesimulator/libsrtp2.a" x86_64
verify_archive_arch "$BUILD_ROOT/opus-device/Release-iphoneos/libopus.a" arm64
verify_archive_arch "$BUILD_ROOT/opus-simulator/Release-iphonesimulator/libopus.a" x86_64

verify_headers "$BUILD_ROOT/openssl-device/install/include"
verify_headers "$BUILD_ROOT/openssl-simulator/install/include"
verify_headers "$BUILD_ROOT/../src/libsrtp/include"
verify_headers "$BUILD_ROOT/../src/opus/include"

verify_xcframework OpenSSLCrypto arm64 x86_64
verify_xcframework libsrtp2 arm64 x86_64
verify_xcframework libopus arm64 x86_64

if find "$XCFRAMEWORK_ROOT" -type f \( -name '*.dylib' -o -name '*.framework' \) -print -quit | grep -q .; then
  echo 'dynamic/macOS dependency leaked into public artifacts' >&2
  exit 1
fi
if find "$XCFRAMEWORK_ROOT" -type f -print0 | xargs -0 grep -IlE '/(usr/local/opt/openssl|opt/homebrew)|lib(crypto|ssl)\.dylib' 2>/dev/null | grep -q .; then
  echo 'macOS OpenSSL path or dylib leaked into public artifacts' >&2
  exit 1
fi
echo 'DEPENDENCY_ARTIFACTS=PASS'
