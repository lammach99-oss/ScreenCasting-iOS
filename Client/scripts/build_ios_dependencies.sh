#!/usr/bin/env bash
set -euo pipefail

# Apple calls the device SDK "iphoneos" and the simulator SDK
# "iphonesimulator". These are toolchain identifiers; both outputs are for
# the iPad-only app (device arm64 and Intel iPad Simulator x86_64).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="${SCREENCASTING_DEP_CACHE:-${TMPDIR:-/tmp}/screencasting-ios-deps}"
OUTPUT="$CLIENT_ROOT/ThirdPartyBuild"
OPENSSL_URL="https://github.com/openssl/openssl.git"
OPENSSL_REV="98b3bf1433f8f4a29e64ca8b9bd42c58d3d1b98a"
LIBSRTP_URL="https://github.com/cisco/libsrtp.git"
LIBSRTP_REV=24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5
OPUS_URL="https://github.com/xiph/opus.git"
OPUS_REV=ddbe48383984d56acd9e1ab6a090c54ca6b735a6

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
for tool in git cmake make perl xcodebuild xcrun; do require "$tool"; done
mkdir -p "$CACHE_ROOT/src" "$CACHE_ROOT/build" "$OUTPUT/xcframeworks"

clone_at() {
  local url="$1" name="$2" revision="$3" dir="$CACHE_ROOT/src/$2"
  if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout "$url" "$dir"; fi
  git -C "$dir" fetch --no-tags origin "$revision"
  git -C "$dir" checkout --force "$revision"
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$revision" ]] || {
    echo "revision verification failed for $name" >&2; exit 1;
  }
}

openssl_target() {
  local source="$CACHE_ROOT/src/openssl" kind="$1" target
  if [[ "$kind" == device ]]; then
    target="$(cd "$source" && ./Configure LIST | tr ' ' '\n' | grep -E '^ios64-' | head -n1)"
  else
    target="$(cd "$source" && ./Configure LIST | tr ' ' '\n' | grep -E '^iossimulator' | head -n1)"
  fi
  [[ -n "$target" ]] || { echo "pinned OpenSSL source has no $kind target" >&2; exit 1; }
  printf '%s\n' "$target"
}

build_openssl() {
  local sdk="$1" arch="$2" kind="$3" build="$CACHE_ROOT/build/openssl-$kind"
  local target; target="$(openssl_target "$kind")"
  rm -rf "$build"; mkdir -p "$build"
  pushd "$CACHE_ROOT/src/openssl" >/dev/null
  make distclean >/dev/null 2>&1 || true
  ./Configure "$target" no-shared no-tests no-apps \
    --sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -arch "$arch" --prefix="$build/install"
  make -j"$(sysctl -n hw.ncpu)" build_sw
  make install_sw
  popd >/dev/null
  [[ -f "$build/install/lib/libcrypto.a" ]] || { echo "OpenSSL libcrypto missing for $kind" >&2; exit 1; }
  echo "openssl $kind target=$target sdk=$sdk arch=$arch"
}

build_opus() {
  local sdk="$1" arch="$2" kind="$3" build="$CACHE_ROOT/build/opus-$kind"
  cmake -S "$CACHE_ROOT/src/opus" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
  cmake --build "$build" --config Release --target opus
}

build_srtp() {
  local sdk="$1" arch="$2" kind="$3" build="$CACHE_ROOT/build/libsrtp-$kind"
  local openssl_root="$CACHE_ROOT/build/openssl-$kind/install"
  cmake -S "$CACHE_ROOT/src/libsrtp" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_C_FLAGS="-Werror -Wno-error=shorten-64-to-32" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_OPENSSL=ON -DBUILD_TESTING=OFF \
    -DOPENSSL_ROOT_DIR="$openssl_root" -DOPENSSL_INCLUDE_DIR="$openssl_root/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_root/lib/libcrypto.a" -DOPENSSL_SSL_LIBRARY="" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE
  cmake --build "$build" --config Release --target srtp2
}

package_xcframework() {
  local name="$1" device="$2" simulator="$3" headers="$4"
  rm -rf "$OUTPUT/xcframeworks/$name.xcframework"
  xcodebuild -create-xcframework \
    -library "$device" -headers "$headers" \
    -library "$simulator" -headers "$headers" \
    -output "$OUTPUT/xcframeworks/$name.xcframework"
}

verify_artifacts() {
  local root="$OUTPUT/xcframeworks"
  for artifact in OpenSSLCrypto libsrtp2 libopus; do [[ -d "$root/$artifact.xcframework" ]] || { echo "missing $artifact.xcframework" >&2; exit 1; }; done
  ! find "$root" -type f \( -name '*.dylib' -o -name '*.framework' \) -print -quit | grep -q . || { echo "dynamic/macOS dependency leaked into public artifacts" >&2; exit 1; }
}

clone_at "$OPENSSL_URL" openssl "$OPENSSL_REV"
clone_at "$LIBSRTP_URL" libsrtp "$LIBSRTP_REV"
clone_at "$OPUS_URL" opus "$OPUS_REV"

build_openssl iphoneos arm64 device
build_openssl iphonesimulator x86_64 simulator
build_srtp iphoneos arm64 device
build_srtp iphonesimulator x86_64 simulator
build_opus iphoneos arm64 device
build_opus iphonesimulator x86_64 simulator

package_xcframework OpenSSLCrypto \
  "$CACHE_ROOT/build/openssl-device/install/lib/libcrypto.a" \
  "$CACHE_ROOT/build/openssl-simulator/install/lib/libcrypto.a" \
  "$CACHE_ROOT/src/openssl/include"
package_xcframework libsrtp2 \
  "$CACHE_ROOT/build/libsrtp-device/Release-iphoneos/libsrtp2.a" \
  "$CACHE_ROOT/build/libsrtp-simulator/Release-iphonesimulator/libsrtp2.a" \
  "$CACHE_ROOT/src/libsrtp/include"
package_xcframework libopus \
  "$CACHE_ROOT/build/opus-device/Release-iphoneos/libopus.a" \
  "$CACHE_ROOT/build/opus-simulator/Release-iphonesimulator/libopus.a" \
  "$CACHE_ROOT/src/opus/include"

verify_artifacts
printf 'OPENSSL_REV=%s\nLIBSRTP_REV=%s\nOPUS_REV=%s\nRUNNER_ARCH=%s\n' \
  "$OPENSSL_REV" "$LIBSRTP_REV" "$OPUS_REV" "$(uname -m)"
