#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Client/scripts/native_dependency_helpers.sh
source "$SCRIPT_DIR/native_dependency_helpers.sh"

ROOT="${1:?usage: $0 <native-dependency-root> <manifest-path>}"
MANIFEST="${2:?usage: $0 <native-dependency-root> <manifest-path>}"

: "${PUBLIC_SHA:?PUBLIC_SHA is required}"
: "${CACHE_SCHEMA:?CACHE_SCHEMA is required}"
: "${CACHE_KEY:?CACHE_KEY is required}"
: "${XCODE_FINGERPRINT:?XCODE_FINGERPRINT is required}"
: "${RUNNER_ARCH:?RUNNER_ARCH is required}"
: "${OPENSSL_PIN:?OPENSSL_PIN is required}"
: "${LIBSRTP_PIN:?LIBSRTP_PIN is required}"
: "${OPUS_PIN:?OPUS_PIN is required}"

[[ ! -d "$ROOT/src" ]] || native_dependency_fail 'native dependency source clones must not enter the cache or artifact'
tree_sha256="$(native_dependency_tree_sha256 "$ROOT")"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
Manifest-Version: 1
Public SHA: $PUBLIC_SHA
Cache Schema: $CACHE_SCHEMA
Cache Key: $CACHE_KEY
Xcode Fingerprint: $XCODE_FINGERPRINT
Runner Architecture: $RUNNER_ARCH
OpenSSL Pin: $OPENSSL_PIN
libsrtp Pin: $LIBSRTP_PIN
Opus Pin: $OPUS_PIN
Device Variants: OpenSSLCrypto:arm64,libsrtp2:arm64,libopus:arm64
Simulator Variants: OpenSSLCrypto:x86_64,libsrtp2:x86_64,libopus:x86_64
Strict Validation: PASS
Native Output Tree SHA-256: $tree_sha256
EOF

grep -Fq "Public SHA: $PUBLIC_SHA" "$MANIFEST"
grep -Fq "Cache Key: $CACHE_KEY" "$MANIFEST"
echo "NATIVE_DEPENDENCY_TREE_SHA256=$tree_sha256"
echo "NATIVE_DEPENDENCY_MANIFEST=$MANIFEST"
