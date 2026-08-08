# Public CI fast feedback

The public workflow keeps the iPad-only R2/R3 qualification gates while
reusing verified deterministic work:

```text
prepare-native-deps
        |
        v
build-and-test
        |
        v
build-unsigned-ipad-app
        |
        v
package-unsigned-ipa
        |
        v
revalidate-uploaded-ipa
```

`prepare-native-deps` is the only job that can compile OpenSSL, libsrtp, or
Opus. It restores one exact cache key, always reruns strict archive/platform/
XCFramework/header/leakage validation, removes source clones, saves only after
validation, and uploads the verified generated tree for the current run.

## Cache contract

- Cache action: `actions/cache/restore@v6` and `actions/cache/save@v6`.
- Cache path: generated `Client/ThirdPartyBuild/` only.
- Schema: `NATIVE_CACHE_SCHEMA=v1`.
- Exact key inputs: schema, runner OS, runner architecture, a hash of actual
  `xcodebuild -version` plus `xcode-select -p`, all three immutable dependency
  pins, the dependency build/verification/helper hashes, the project hash,
  deployment target, architectures, OpenSSL targets, and compile flags.
- Broad `restore-keys`: none.
- Restore policy: every hit is strictly verified before use; an invalid hit
  fails closed.
- Save policy: only a successful `push` on `main` or `workflow_dispatch` may
  save. `pull_request` runs never save an authoritative cache, so an
  untrusted fork cannot populate the main cache namespace.
- Cache contents do not include source clones, `.git` metadata, credentials,
  Keychains, provisioning profiles, certificates, 3uTools data, or private
  Host content.

The cache is not the run-to-run handoff mechanism. Each run uploads
`ScreenCasting-native-deps` with a public-SHA/cache-key/toolchain/pin/variant
manifest. Both consumer jobs download it, verify the manifest and tree hash,
then rerun the strict dependency validator before building.

## Job responsibilities

`build-and-test` downloads the verified native-deps artifact, builds the iPad
Simulator, and runs the full XCTest suite. `build-unsigned-ipad-app` downloads
the same artifact and performs the generic iOS, signing-disabled, exact arm64,
iPad-only build and unsigned `.app` validation. It uploads only the app and a
manifest bound to the public SHA and native-deps manifest hash.

`package-unsigned-ipa` downloads that app artifact, validates its provenance,
creates `Payload/`, zips the IPA, runs `check_ipa.sh --unsigned`, and uploads
the final IPA plus SHA-256 manifest. It contains no `xcodebuild`, native
dependency compilation, or XCTest. `revalidate-uploaded-ipa` downloads the
final artifact and repeats SHA-256, provenance, and unsigned-validator checks.

Artifacts use short retention: three days for native dependencies and the
unsigned app, seven days for the final unsigned IPA.

## Retry semantics

For a failed packaging job in a run whose preparation, XCTest, and app jobs
already passed, use the GitHub Actions **Re-run failed jobs** control or:

```sh
gh run rerun <RUN_ID> --failed
```

The successful upstream jobs are not intentionally rerun. The same-run
verified app artifact remains the package input. A new commit creates a new
run; it does not retroactively change an old run. With unchanged native inputs,
the new run gets an exact cache hit, strictly verifies it, skips native
compilation, and still uploads a fresh run-scoped dependency artifact.

Concurrency separates manual qualification runs from push/PR build-test runs.
Superseded push/PR runs may be cancelled, while an unrelated push does not
cancel a long manual unsigned IPA run.

## Timing telemetry

The workflow logs elapsed seconds for cache restore, native build or skip,
native verification, Simulator build, XCTest, device app build, app/IPA
validation, packaging, and downloaded-artifact revalidation. Timing is
diagnostic only; acceptance is based on verified reuse and preserved gates, not
on a fixed wall-clock threshold.

Cold and warm evidence must be taken from actual terminal runs. No timing or
cache result is inferred from a local Windows checkout or fabricated in this
document.

## Boundaries

The workflow remains unsigned. Apple signing, provisioning, Apple ID, iCloud,
and 3uTools credentials remain local-only. The Windows Host remains private,
Wave 7 is not started, and physical iPad qualification remains deferred.
