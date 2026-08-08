#!/usr/bin/env bash

native_dependency_fail() {
  echo "$*" >&2
  return 1
}

native_dependency_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    native_dependency_fail 'missing SHA-256 tool: shasum or sha256sum'
  fi
}

native_dependency_tree_sha256() {
  local root="$1" entries
  [[ -d "$root/build" ]] || native_dependency_fail "native dependency build tree missing: $root/build"
  [[ -d "$root/xcframeworks" ]] || native_dependency_fail "native dependency XCFramework tree missing: $root/xcframeworks"
  entries="$(
    cd "$root"
    find build xcframeworks -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      printf '%s  %s\n' "$(native_dependency_sha256 "$file" | awk '{print $1}')" "$file"
    done
  )"
  [[ -n "$entries" ]] || native_dependency_fail "native dependency output tree is empty: $root"
  printf '%s\n' "$entries" | native_dependency_sha256 | awk '{print $1}'
}

native_manifest_value() {
  local manifest="$1" key="$2"
  awk -F': ' -v expected_key="$key" '$1 == expected_key { print substr($0, length($1) + 3); exit }' "$manifest"
}
