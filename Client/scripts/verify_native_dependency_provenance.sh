#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Client/scripts/native_dependency_helpers.sh
source "$SCRIPT_DIR/native_dependency_helpers.sh"

ROOT="${1:?usage: $0 <native-dependency-root> <manifest-path>}"
MANIFEST="${2:?usage: $0 <native-dependency-root> <manifest-path>}"
: "${EXPECTED_PUBLIC_SHA:?EXPECTED_PUBLIC_SHA is required}"
: "${EXPECTED_CACHE_KEY:?EXPECTED_CACHE_KEY is required}"
: "${EXPECTED_MANIFEST_SHA256:?EXPECTED_MANIFEST_SHA256 is required}"

[[ -f "$MANIFEST" ]] || native_dependency_fail "native dependency manifest missing: $MANIFEST"
actual_manifest_sha256="$(native_dependency_sha256 "$MANIFEST" | awk '{print $1}')"
[[ "$actual_manifest_sha256" == "$EXPECTED_MANIFEST_SHA256" ]] || native_dependency_fail 'native dependency manifest SHA-256 mismatch'

require_manifest_value() {
  local key="$1" expected="$2" actual
  actual="$(native_manifest_value "$MANIFEST" "$key")"
  [[ "$actual" == "$expected" ]] || native_dependency_fail "native dependency manifest mismatch for $key"
}

require_manifest_value 'Manifest-Version' 1
require_manifest_value 'Public SHA' "$EXPECTED_PUBLIC_SHA"
require_manifest_value 'Cache Key' "$EXPECTED_CACHE_KEY"
require_manifest_value 'Strict Validation' PASS
require_manifest_value 'Device Variants' 'OpenSSLCrypto:arm64,libsrtp2:arm64,libopus:arm64'
require_manifest_value 'Simulator Variants' 'OpenSSLCrypto:x86_64,libsrtp2:x86_64,libopus:x86_64'
[[ -n "$(native_manifest_value "$MANIFEST" 'Cache Schema')" ]] || native_dependency_fail 'native dependency cache schema missing'
[[ -n "$(native_manifest_value "$MANIFEST" 'Xcode Fingerprint')" ]] || native_dependency_fail 'native dependency Xcode fingerprint missing'

if find "$ROOT" -type d \( -name src -o -name .git -o -name HostService -o -name SessionAgent -o -name MediaWorker -o -name DriverBroker -o -name MttVDD \) -print -quit | grep -q .; then
  native_dependency_fail 'native dependency artifact contains source, Git, or private Host content'
fi

expected_tree_sha256="$(native_manifest_value "$MANIFEST" 'Native Output Tree SHA-256')"
actual_tree_sha256="$(native_dependency_tree_sha256 "$ROOT")"
[[ -n "$expected_tree_sha256" && "$actual_tree_sha256" == "$expected_tree_sha256" ]] || native_dependency_fail 'native dependency output tree SHA-256 mismatch'

echo 'NATIVE_DEPENDENCY_PROVENANCE=PASS'
echo "NATIVE_DEPENDENCY_MANIFEST_SHA256=$actual_manifest_sha256"
