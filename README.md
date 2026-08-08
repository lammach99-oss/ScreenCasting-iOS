# ScreenCasting iOS/iPad receiver

This repository contains the public Swift/iPadOS receiver client. The Windows
host is maintained separately and is not part of this repository.

## Build and test

On macOS with Xcode installed:

```sh
cd Client
./scripts/build_ios_dependencies.sh
xcodebuild -project iPadZeroLagDisplay/iPadCasting.xcodeproj -scheme iPadCasting \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project iPadZeroLagDisplay/iPadCasting.xcodeproj -scheme iPadCasting \
  -destination 'platform=iOS Simulator,name=iPad (10th generation),OS=latest' CODE_SIGNING_ALLOWED=NO
```

A signed IPA requires an Apple signing identity and provisioning profile. Use
the `build_unsigned_ipa` workflow-dispatch input to produce a validated unsigned
iPad IPA artifact. Download the `ScreenCasting-iPad-unsigned` artifact, move
the IPA to the Windows PC used for local signing, and use the user's local
3uTools workflow with their own Apple ID/free provisioning to sign and install
it on the intended iPad. Free provisioning may require periodic re-signing.
GitHub Actions never receives Apple or 3uTools credentials, and it does not
run 3uTools. The artifact is unsigned and physical iPad qualification remains
NOT RUN / DEFERRED.

Wave 6 code closeout: PASS.
Physical iPad: NOT RUN / DEFERRED.

Project license: NOT SPECIFIED.
