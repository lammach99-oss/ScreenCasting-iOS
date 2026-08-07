# Public source manifest

Private source commit: `10175a050082932ce5553e9d16d8a080b3a99862`.

Exported: `Client/**`

Explicitly excluded: Windows Host, HostService, SessionAgent, MediaWorker,
DriverBroker, MttVDD, Windows transport implementation, and private monorepo
history.

Generated dependencies:

- libsrtp `24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5`
- Opus `ddbe48383984d56acd9e1ab6a090c54ca6b735a6`
- OpenSSL tag `openssl-3.3.2`, immutable tag object `98b3bf1433f8f4a29e64ca8b9bd42c58d3d1b98a` from `https://github.com/openssl/openssl.git`

The required CI slice is iPad Simulator x86_64 on `macos-15-intel`; the
device slice is iPad arm64. Apple SDK identifiers `iphonesimulator` and
`iphoneos` are used only by the toolchain.
