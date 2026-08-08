#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPUTE="$SCRIPT_DIR/compute_native_dependency_manifest.sh"
VERIFY="$SCRIPT_DIR/verify_native_dependency_provenance.sh"
ARTIFACT_HELPER="$SCRIPT_DIR/verify_native_dependency_artifact.sh"
# shellcheck source=Client/scripts/native_dependency_helpers.sh
source "$SCRIPT_DIR/native_dependency_helpers.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() { echo "$*" >&2; exit 1; }
expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "invalid provenance accepted: $name"; fi
}

dependency_root="$TEMP_ROOT/Client/ThirdPartyBuild"
manifest="$TEMP_ROOT/native-deps.manifest.txt"
mkdir -p "$dependency_root/build/source-headers/libsrtp" \
  "$dependency_root/build/source-headers/opus" \
  "$dependency_root/xcframeworks/OpenSSLCrypto.xcframework"
printf 'safe generated dependency output\n' > "$dependency_root/build/libcrypto.a"
printf 'srtp header\n' > "$dependency_root/build/source-headers/libsrtp/srtp.h"
printf 'opus header\n' > "$dependency_root/build/source-headers/opus/opus.h"
printf 'xcframework metadata\n' > "$dependency_root/xcframeworks/OpenSSLCrypto.xcframework/Info.plist"

export PUBLIC_SHA=8020dd04e8c389bff1182744cf34882635f1ad5b
export CACHE_SCHEMA=v1
export CACHE_KEY=native-ios-v1-macos-X64-toolchain-openssl-3.3.2-libsrtp-opus-build
export XCODE_FINGERPRINT=toolchain
export RUNNER_ARCH=X64
export OPENSSL_PIN=openssl-3.3.2-98b3bf14
export LIBSRTP_PIN=24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5
export OPUS_PIN=ddbe48383984d56acd9e1ab6a090c54ca6b735a6

bash "$COMPUTE" "$dependency_root" "$manifest"
manifest_sha256="$(native_dependency_sha256 "$manifest" | awk '{print $1}')"
EXPECTED_PUBLIC_SHA="$PUBLIC_SHA" EXPECTED_CACHE_KEY="$CACHE_KEY" EXPECTED_MANIFEST_SHA256="$manifest_sha256" \
  bash "$VERIFY" "$dependency_root" "$manifest"

download_root="$TEMP_ROOT/download"
destination_root="$TEMP_ROOT/consumer/Client/ThirdPartyBuild"
mkdir -p "$download_root/Client"
cp -R "$dependency_root" "$download_root/Client/ThirdPartyBuild"
cp "$manifest" "$download_root/native-deps.manifest.txt"
EXPECTED_PUBLIC_SHA="$PUBLIC_SHA" EXPECTED_CACHE_KEY="$CACHE_KEY" EXPECTED_MANIFEST_SHA256="$manifest_sha256" \
  bash "$ARTIFACT_HELPER" "$download_root" "$destination_root"
cmp "$dependency_root/build/libcrypto.a" "$destination_root/build/libcrypto.a"

printf 'changed output\n' >> "$dependency_root/build/libcrypto.a"
expect_fail 'changed generated output' env EXPECTED_PUBLIC_SHA="$PUBLIC_SHA" EXPECTED_CACHE_KEY="$CACHE_KEY" EXPECTED_MANIFEST_SHA256="$manifest_sha256" bash "$VERIFY" "$dependency_root" "$manifest"

printf 'safe generated dependency output\n' > "$dependency_root/build/libcrypto.a"
expect_fail 'wrong public SHA' env EXPECTED_PUBLIC_SHA=wrong EXPECTED_CACHE_KEY="$CACHE_KEY" EXPECTED_MANIFEST_SHA256="$manifest_sha256" bash "$VERIFY" "$dependency_root" "$manifest"

echo 'native dependency provenance fixtures: PASS'
