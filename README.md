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

An IPA requires an Apple signing identity and provisioning profile. Use the
protected manual workflow for signed exports. Wave 6 code closeout: PASS.
Physical iPad: NOT RUN / DEFERRED.

Project license: NOT SPECIFIED.
