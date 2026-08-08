#!/usr/bin/env bash
set -euo pipefail

WORKFLOW="${1:-.github/workflows/ios-public-ci.yml}"
[[ -f "$WORKFLOW" ]] || { echo "workflow missing: $WORKFLOW" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }
require_text() { grep -Fq "$1" "$WORKFLOW" || fail "workflow text missing: $1"; }
job_block() {
  local job="$1"
  awk -v job="$job" '
    $0 == "  " job ":" { in_job = 1; next }
    in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
    in_job { print }
  ' "$WORKFLOW"
}
step_block() {
  local step="$1"
  awk -v step="$step" '
    $0 == "      - name: " step { in_step = 1; next }
    in_step && $0 ~ /^      - name:/ { exit }
    in_step { print }
  ' "$WORKFLOW"
}

for job in prepare-native-deps build-and-test build-unsigned-ipad-app package-unsigned-ipa revalidate-uploaded-ipa; do
  require_text "  $job:"
done
for action in 'actions/checkout@v7' 'actions/cache/restore@v6' 'actions/cache/save@v6' 'actions/upload-artifact@v7' 'actions/download-artifact@v8'; do
  require_text "$action"
done
require_text 'NATIVE_CACHE_SCHEMA: v1'
require_text 'cache-hit'
require_text 'cancel-in-progress: ${{ github.event_name != '\''workflow_dispatch'\'' }}'

if grep -Fq 'restore-keys:' "$WORKFLOW"; then fail 'broad cache restore keys are present'; fi
if grep -Fq 'pull_request_target' "$WORKFLOW"; then fail 'pull_request_target is present'; fi
if grep -Eq 'mapfile|readarray' "$WORKFLOW"; then fail 'workflow requires Bash 4-only array helpers'; fi

strict_native_step="$(step_block 'Strictly verify restored or built native dependencies')"
cleanup_native_step="$(step_block 'Remove source clones before cache save and artifact staging')"
post_cleanup_native_step="$(step_block 'Re-verify cache-safe dependency tree after source cleanup')"
if grep -Fq 'DEP_ROOT/src' <<<"$strict_native_step"; then
  fail 'strict native verification checks source absence before cleanup'
fi
grep -Fq 'rm -rf "$DEP_ROOT/src"' <<<"$cleanup_native_step" || fail 'source cleanup is missing'
grep -Fq '[[ ! -e "$DEP_ROOT/src" ]]' <<<"$cleanup_native_step" || fail 'source cleanup does not assert absence'
[[ -n "$post_cleanup_native_step" ]] || fail 'post-cleanup native verification step is missing'
grep -Fq './Client/scripts/verify_ios_dependency_artifacts.sh' <<<"$post_cleanup_native_step" ||
  fail 'post-cleanup native verification is missing strict artifact validation'

package="$(job_block package-unsigned-ipa)"
[[ -n "$package" ]] || fail 'package job block is empty'
if grep -Eiq 'xcodebuild|build_ios_dependencies|xctest|xcodebuild test' <<<"$package"; then
  fail 'package job contains an expensive build or test command'
fi
grep -Fq './Client/check_ipa.sh --unsigned' <<<"$package" || fail 'package job lacks unsigned IPA validation'
grep -Fq 'ScreenCasting-iPad-unsigned' <<<"$package" || fail 'package job lacks final artifact'

app="$(job_block build-unsigned-ipad-app)"
grep -Fq "generic/platform=iOS" <<<"$app" || fail 'device app build is not generic iOS'
grep -Fq 'CODE_SIGNING_ALLOWED=NO' <<<"$app" || fail 'device app build is not unsigned'
grep -Fq 'ARCHS=arm64' <<<"$app" || fail 'device app build is not exact arm64'
grep -Fq 'ScreenCasting-iPad-unsigned-app' <<<"$app" || fail 'device app artifact missing'

revalidate="$(job_block revalidate-uploaded-ipa)"
grep -Fq 'actions/download-artifact@v8' <<<"$revalidate" || fail 'final artifact download missing'
grep -Fq 'DOWNLOADED_ARTIFACT_REVALIDATION=PASS' <<<"$revalidate" || fail 'final revalidation marker missing'

echo 'fast feedback workflow fixtures: PASS'
