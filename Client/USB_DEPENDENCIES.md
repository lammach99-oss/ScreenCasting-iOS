# Public iOS native dependencies

The Xcode project consumes generated XCFrameworks under `Client/ThirdPartyBuild/`.
Run `scripts/build_ios_dependencies.sh` on macOS before building. The script
checks out immutable upstream commits and never commits generated binaries.

| Dependency | Revision | Upstream |
| --- | --- | --- |
| libsrtp | `24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5` | https://github.com/cisco/libsrtp |
| Opus | `ddbe48383984d56acd9e1ab6a090c54ca6b735a6` | https://github.com/xiph/opus |
