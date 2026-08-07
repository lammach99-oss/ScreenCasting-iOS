#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="${SCREENCASTING_DEP_CACHE:-${TMPDIR:-/tmp}/screencasting-ios-deps}"
OUTPUT="$CLIENT_ROOT/ThirdPartyBuild"
LIBSRTP_REV=24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5
OPUS_REV=ddbe48383984d56acd9e1ab6a090c54ca6b735a6

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
for tool in git cmake xcodebuild xcrun; do require "$tool"; done
mkdir -p "$CACHE_ROOT/src" "$CACHE_ROOT/build" "$OUTPUT/xcframeworks"

clone_at() {
  local url="$1" name="$2" revision="$3" dir="$CACHE_ROOT/src/$2"
  if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout "$url" "$dir"; fi
  git -C "$dir" fetch --no-tags --depth 1 origin "$revision"
  git -C "$dir" checkout --force "$revision"
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$revision" ]] || { echo "revision verification failed for $name" >&2; exit 1; }
}

build_opus() {
  local sdk="$1" arch="$2" build="$CACHE_ROOT/build/opus-$sdk"
  cmake -S "$CACHE_ROOT/src/opus" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
  cmake --build "$build" --config Release
}

build_srtp() {
  local sdk="$1" arch="$2" build="$CACHE_ROOT/build/libsrtp-$sdk"
  cmake -S "$CACHE_ROOT/src/libsrtp" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_OPENSSL=OFF -DBUILD_TESTING=OFF
  cmake --build "$build" --config Release
}

clone_at https://github.com/cisco/libsrtp.git libsrtp "$LIBSRTP_REV"
clone_at https://github.com/xiph/opus.git opus "$OPUS_REV"
build_opus iphoneos arm64
build_opus iphonesimulator arm64
build_srtp iphoneos arm64
build_srtp iphonesimulator arm64

xcodebuild -create-xcframework \
  -library "$CACHE_ROOT/build/opus-iphoneos/Release-iphoneos/libopus.a" -headers "$CACHE_ROOT/src/opus/include" \
  -library "$CACHE_ROOT/build/opus-iphonesimulator/Release-iphonesimulator/libopus.a" -headers "$CACHE_ROOT/src/opus/include" \
  -output "$OUTPUT/xcframeworks/libopus.xcframework"
xcodebuild -create-xcframework \
  -library "$CACHE_ROOT/build/libsrtp-iphoneos/Release-iphoneos/libsrtp2.a" -headers "$CACHE_ROOT/src/libsrtp/include" \
  -library "$CACHE_ROOT/build/libsrtp-iphonesimulator/Release-iphonesimulator/libsrtp2.a" -headers "$CACHE_ROOT/src/libsrtp/include" \
  -output "$OUTPUT/xcframeworks/libsrtp2.xcframework"

echo "libsrtp=$LIBSRTP_REV"
echo "opus=$OPUS_REV"
