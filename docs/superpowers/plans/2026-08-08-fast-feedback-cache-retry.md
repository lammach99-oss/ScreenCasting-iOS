# iOS Public CI Fast Feedback / Cache / Retry Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse one strictly verified native dependency build, split unsigned app creation from cheap IPA packaging, and preserve every R2/R3 correctness and security gate.

**Architecture:** `prepare-native-deps` restores or builds an exact-key cache, validates it, removes source clones from the reusable tree, saves the verified generated outputs, and uploads the same tree with a SHA-bound manifest. `build-and-test` and `build-unsigned-ipad-app` download and revalidate that artifact; the latter uploads only a provenance-bound unsigned `.app`. `package-unsigned-ipa` performs no `xcodebuild`, native compilation, or XCTest and produces the final IPA for a cheap same-run retry.

**Tech Stack:** GitHub Actions, official `actions/cache` restore/save, `actions/upload-artifact`, `actions/download-artifact`, Bash, Xcode command-line tools, existing IPA/dependency validators.

## Global Constraints

- Public repository: `lammach99-oss/ScreenCasting-iOS`.
- Product remains iPad-only with `TARGETED_DEVICE_FAMILY=2`.
- Private Windows Host source and metadata remain unpublished.
- No Apple ID, iCloud, 3uTools, P12/PFX, provisioning, certificate, or signing secrets enter GitHub.
- No Wave 7 and no physical qualification claim.
- Do not weaken dependency slice/platform checks, USB identity tests, IPA validators, provenance, or downloaded-artifact revalidation.
- Current exact-head R3 run `31265517951` at `8020dd04e8c389bff1182744cf34882635f1ad5b` remains untouched; optimization commits stay local until it is terminal.

## Read-only audit evidence

Captured on 2026-08-08 before implementation:

- `gh auth status`: logged in as `lammach99-oss`; token scopes include `repo` and `workflow`.
- `gh api user --jq .login`: `lammach99-oss`.
- `OPTIMIZATION_START_SHA=8020dd04e8c389bff1182744cf34882635f1ad5b`.
- `PUBLIC_ROOT_SHA=48ab264122e9a20c2b74b58ccb327f8e1e5b0048`.
- `WORKTREE_CLEAN=YES` on `main`; `git diff --check` passed.
- `ACTIVE_RUNS=31265517951` only; its `Build and XCTest` job was green and `Unsigned iPad IPA` was in the device dependency build.
- Existing graph rebuilds pinned native dependencies in both `Build and XCTest` and `Unsigned iPad IPA`; packaging was coupled to that device job.
- Current concurrency group is shared by pushes, pull requests, and manual runs with `cancel-in-progress: true`, so an unrelated push can cancel a long manual run.
- Current official action latest tags from the live GitHub API: checkout `v7.0.1`, cache `v6.1.0`, upload-artifact `v7.0.1`, download-artifact `v8.0.1`.

## Task 1: Make generated native outputs self-contained

**Files:**
- Modify: `Client/scripts/build_ios_dependencies.sh`
- Modify: `Client/scripts/verify_ios_dependency_artifacts.sh`

- [ ] Copy libsrtp and Opus public headers into `build/source-headers/` after their pinned builds.
- [ ] Make strict verification consume only the generated build tree and copied slice-owned headers, not a source clone that would be absent from a cache hit.
- [ ] Keep exact arm64/x86_64 archive, iOS/iOS Simulator platform, XCFramework metadata, header, and macOS leakage checks unchanged in meaning.
- [ ] Run Bash syntax and a mocked path/header contract test before committing.

## Task 2: Add exact cache and verified native-deps artifact preparation

**Files:**
- Modify: `.github/workflows/ios-public-ci.yml`
- Create: `Client/scripts/compute_native_dependency_manifest.sh`
- Create: `Client/scripts/verify_native_dependency_provenance.sh`

- [ ] Compute `NATIVE_CACHE_SCHEMA=v1`, runner OS/architecture, hashed `xcodebuild -version` plus `xcode-select -p`, all immutable pins, deployment target, compile flags, project hash, build-script hash, and verification-script hash.
- [ ] Restore only the exact key with `actions/cache/restore@v6`; use no broad restore keys.
- [ ] Log `Native dependency cache: HIT` or `MISS`.
- [ ] On a miss, run the pinned build once; on hit, skip compilation.
- [ ] Always run strict dependency verification after restore; fail closed on any mismatch.
- [ ] Remove source clones before saving/cache-artifact staging so only public-safe generated outputs remain.
- [ ] Create a manifest containing public SHA, cache key, schema, pins, toolchain fingerprint, expected variants, and strict validation result without private paths.
- [ ] Save only after verification and only for trusted `push` on `main` or `workflow_dispatch`; never save an authoritative cache from `pull_request`.
- [ ] Upload `ScreenCasting-native-deps` with 3-day retention.

## Task 3: Consume one verified dependency artifact in both expensive jobs

**Files:**
- Modify: `.github/workflows/ios-public-ci.yml`

- [ ] Make `build-and-test` depend on `prepare-native-deps`, download the artifact, verify manifest/provenance, rerun strict dependency validation, then build Simulator and run the full XCTest suite.
- [ ] Make `build-unsigned-ipad-app` depend on `build-and-test`, download the same verified artifact, verify it again, preserve generic iOS/signing-disabled/exact-arm64/iPad-only checks, and remove native dependency compilation from this job.
- [ ] Emit timing markers for restore, native build, native verification, Simulator build, XCTest, and device app build.

## Task 4: Split unsigned app artifact from IPA packaging

**Files:**
- Modify: `.github/workflows/ios-public-ci.yml`

- [ ] Upload only `iPadCasting.app` and its exact-SHA/native-manifest-bound provenance as `ScreenCasting-iPad-unsigned-app` with 3-day retention.
- [ ] Add `package-unsigned-ipa` needing the app job; download and revalidate the app, create `Payload/`, zip the IPA, run `check_ipa.sh --unsigned`, write SHA-256/provenance, and upload `ScreenCasting-iPad-unsigned`.
- [ ] Ensure the packaging job contains no `xcodebuild`, native build script, dependency compile command, or XCTest.
- [ ] Keep `revalidate-uploaded-ipa` dependent on packaging and retain downloaded SHA-256, public-SHA, provenance, unsigned validator, and marker checks.

## Task 5: Audit concurrency, retry, public cache safety, and action versions

**Files:**
- Modify: `.github/workflows/ios-public-ci.yml`
- Create: `docs/CI_FAST_FEEDBACK.md`

- [ ] Separate manual unsigned runs from push/PR build-test concurrency; manual qualification runs must not be cancelled by an unrelated push.
- [ ] Preserve safe cancellation for superseded push/PR runs.
- [ ] Document `gh run rerun <RUN_ID> --failed`, same-SHA artifact reuse expectations, and the distinction between same-SHA reruns and new-SHA runs.
- [ ] Document exact cache key inputs, no broad restore keys, post-restore validation, fork-PR save policy, artifact retention, provenance, timing markers, and cold/warm evidence fields without fabricating values.
- [ ] Use the live-supported official action majors audited above.

## Task 6: Local validation and review

**Files:**
- Review all changed workflow/scripts/docs.

- [ ] Run `git diff --check`, YAML parse, Bash syntax, deterministic provenance/cache-key fixtures, IPA fixtures where host tools allow, and static boundary/security scans.
- [ ] Confirm no signing secret, private Host path, `pull_request_target`, Wave 7, or physical qualification claim is introduced.
- [ ] Wait for R3 run `31265517951` to reach a terminal result without cancelling it.
- [ ] Commit focused atomic changes locally on `codex/fast-feedback-cache-retry`; do not push until the active R3 run is terminal.
- [ ] After authorization remains applicable, push only after the current run is terminal, dispatch exact-head optimization CI, monitor to terminal, download/revalidate artifacts, and perform an independent read-only audit.

---

**Execution mode:** Inline in the existing Luna session. No agent is spawned.
