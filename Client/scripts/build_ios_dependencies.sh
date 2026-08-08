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
OPENSSL_REV="openssl-3.3.2"
OPENSSL_TAG_OBJECT="98b3bf1433f8f4a29e64ca8b9bd42c58d3d1b98a"
OPENSSL_IPAD_DEVICE_TARGET="ios64-xcrun"
OPENSSL_IPAD_SIMULATOR_TARGET="iossimulator-x86_64-xcrun"
LIBSRTP_URL="https://github.com/cisco/libsrtp.git"
LIBSRTP_REV=24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5
OPUS_URL="https://github.com/xiph/opus.git"
OPUS_REV=ddbe48383984d56acd9e1ab6a090c54ca6b735a6

require() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
for tool in git cmake make perl xcodebuild xcrun; do require "$tool"; done
mkdir -p "$CACHE_ROOT/src" "$CACHE_ROOT/build" "$OUTPUT/xcframeworks"

clone_at() {
  local url="$1" name="$2" revision="$3" dir="$CACHE_ROOT/src/$2" expected_tag="${4:-}"
  if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout "$url" "$dir"; fi
  git -C "$dir" fetch --no-tags origin "$revision"
  git -C "$dir" checkout --force "$revision"
  if [[ -n "$expected_tag" ]]; then
    [[ "$(git -C "$dir" rev-parse "refs/tags/$revision")" == "$expected_tag" ]] || {
      echo "tag verification failed for $name" >&2; exit 1;
    }
  elif [[ "$(git -C "$dir" rev-parse HEAD)" != "$revision" ]]; then
    echo "revision verification failed for $name" >&2; exit 1;
  fi
}

openssl_target() {
  local kind="$1" target targets
  if [[ "$kind" == device ]]; then
    target="$OPENSSL_IPAD_DEVICE_TARGET"
  else
    target="$OPENSSL_IPAD_SIMULATOR_TARGET"
  fi
  targets="$(cd "$CACHE_ROOT/src/openssl" && ./Configure LIST 2>&1 || true)"
  grep -Fxq "$target" < <(printf '%s\n' "$targets" | tr ' ' '\n') || {
    echo "pinned OpenSSL source does not expose the required $kind target: $target" >&2
    exit 1
  }
  printf '%s\n' "$target"
}

build_openssl() {
  local sdk="$1" arch="$2" kind="$3"
  local build="$CACHE_ROOT/build/openssl-$kind"
  local target; target="$(openssl_target "$kind")"
  rm -rf "$build"; mkdir -p "$build"
  pushd "$CACHE_ROOT/src/openssl" >/dev/null
  make distclean >/dev/null 2>&1 || true
  ./Configure "$target" no-shared no-tests no-apps \
    --sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    --prefix="$build/install"
  make -j"$(sysctl -n hw.ncpu)" build_sw
  make install_sw
  popd >/dev/null
  [[ -f "$build/install/lib/libcrypto.a" ]] || { echo "OpenSSL libcrypto missing for $kind" >&2; exit 1; }
  echo "Human target: $([[ "$kind" == device ]] && echo 'iPad Device' || echo 'iPad Simulator') $arch"
  echo "OpenSSL Configure target: $target"
  echo "SDK identifier: $sdk"
  echo "Expected arch: $arch"
}

build_opus() {
  local sdk="$1" arch="$2" kind="$3"
  local build="$CACHE_ROOT/build/opus-$kind"
  cmake -S "$CACHE_ROOT/src/opus" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
  cmake --build "$build" --config Release --target opus
}

build_srtp() {
  local sdk="$1" arch="$2" kind="$3"
  local build="$CACHE_ROOT/build/libsrtp-$kind"
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

stage_slice_owned_headers() {
  local headers="$CACHE_ROOT/build/source-headers"
  rm -rf "$headers"
  mkdir -p "$headers"
  cp -R "$CACHE_ROOT/src/libsrtp/include" "$headers/libsrtp"
  cp -R "$CACHE_ROOT/src/opus/include" "$headers/opus"
}

package_xcframework() {
  local name="$1" device="$2" simulator="$3" device_headers="$4" simulator_headers="$5"
  rm -rf "$OUTPUT/xcframeworks/$name.xcframework"
  xcodebuild -create-xcframework \
    -library "$device" -headers "$device_headers" \
    -library "$simulator" -headers "$simulator_headers" \
    -output "$OUTPUT/xcframeworks/$name.xcframework"
}

clone_at "$OPENSSL_URL" openssl "$OPENSSL_REV" "$OPENSSL_TAG_OBJECT"
clone_at "$LIBSRTP_URL" libsrtp "$LIBSRTP_REV"
clone_at "$OPUS_URL" opus "$OPUS_REV"

build_openssl iphoneos arm64 device
build_openssl iphonesimulator x86_64 simulator
build_srtp iphoneos arm64 device
build_srtp iphonesimulator x86_64 simulator
build_opus iphoneos arm64 device
build_opus iphonesimulator x86_64 simulator
stage_slice_owned_headers

package_xcframework OpenSSLCrypto \
  "$CACHE_ROOT/build/openssl-device/install/lib/libcrypto.a" \
  "$CACHE_ROOT/build/openssl-simulator/install/lib/libcrypto.a" \
  "$CACHE_ROOT/build/openssl-device/install/include" \
  "$CACHE_ROOT/build/openssl-simulator/install/include"
package_xcframework libsrtp2 \
  "$CACHE_ROOT/build/libsrtp-device/Release-iphoneos/libsrtp2.a" \
  "$CACHE_ROOT/build/libsrtp-simulator/Release-iphonesimulator/libsrtp2.a" \
  "$CACHE_ROOT/src/libsrtp/include" \
  "$CACHE_ROOT/src/libsrtp/include"
package_xcframework libopus \
  "$CACHE_ROOT/build/opus-device/Release-iphoneos/libopus.a" \
  "$CACHE_ROOT/build/opus-simulator/Release-iphonesimulator/libopus.a" \
  "$CACHE_ROOT/src/opus/include" \
  "$CACHE_ROOT/src/opus/include"

"$SCRIPT_DIR/verify_ios_dependency_artifacts.sh" "$OUTPUT/xcframeworks" "$CACHE_ROOT/build"
printf 'OPENSSL_REV=%s\nLIBSRTP_REV=%s\nOPUS_REV=%s\nRUNNER_ARCH=%s\n' \
  "$OPENSSL_REV" "$LIBSRTP_REV" "$OPUS_REV" "$(uname -m)"
