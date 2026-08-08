#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOWNLOAD_ROOT="${1:?usage: $0 <download-root> <destination-root>}"
DESTINATION_ROOT="${2:?usage: $0 <download-root> <destination-root>}"
: "${EXPECTED_PUBLIC_SHA:?EXPECTED_PUBLIC_SHA is required}"
: "${EXPECTED_CACHE_KEY:?EXPECTED_CACHE_KEY is required}"
: "${EXPECTED_MANIFEST_SHA256:?EXPECTED_MANIFEST_SHA256 is required}"

mapfile -t manifests < <(find "$DOWNLOAD_ROOT" -type f -name 'native-deps.manifest.txt' -print)
[[ "${#manifests[@]}" == 1 ]] || { echo 'expected exactly one native dependency manifest' >&2; exit 1; }
manifest="${manifests[0]}"
artifact_root="$(dirname "$manifest")"
source_root="$artifact_root/Client/ThirdPartyBuild"
if [[ ! -d "$source_root" ]]; then
  mapfile -t roots < <(find "$artifact_root" -type d -name ThirdPartyBuild -print)
  [[ "${#roots[@]}" == 1 ]] || { echo 'native dependency artifact root layout is ambiguous' >&2; exit 1; }
  source_root="${roots[0]}"
fi
[[ -d "$source_root" ]] || { echo 'native dependency artifact root missing' >&2; exit 1; }

EXPECTED_PUBLIC_SHA="$EXPECTED_PUBLIC_SHA" \
EXPECTED_CACHE_KEY="$EXPECTED_CACHE_KEY" \
EXPECTED_MANIFEST_SHA256="$EXPECTED_MANIFEST_SHA256" \
  bash "$SCRIPT_DIR/verify_native_dependency_provenance.sh" "$source_root" "$manifest"

rm -rf "$DESTINATION_ROOT"
mkdir -p "$(dirname "$DESTINATION_ROOT")"
cp -R "$source_root" "$DESTINATION_ROOT"
[[ -d "$DESTINATION_ROOT/build" && -d "$DESTINATION_ROOT/xcframeworks" ]] || {
  echo 'native dependency artifact copy incomplete' >&2
  exit 1
}
echo 'NATIVE_DEPENDENCY_ARTIFACT=PASS'
