# Minimal Network.framework QUIC Reproducer

Isolated diagnostic app. One multiplex group, one outgoing bidirectional child
using `group.extract(connectionTo: nil, using: options)`, one synthetic request.
No DATAGRAM child, retry, timing intervention, or production dependency.
Group maxDatagramFrameSize remains 65535 like the sealed harness: this is not a
QUIC capability-removal experiment. This target is not A4.

Trust: exact host SSL policy, existing dedicated CA as the only trust anchor,
normal certificate validity evaluation. No validation bypass.

Wire constants are copied independently from ../PROTOCOL.md: big-endian length
17, version 1, request opcode 1, generation, sequence zero, body 0x5a; reply opcode
2 must echo every other field. Only one request is sent after child ready.

Build with Xcode 16.4 / iPhoneOS 18.5 and XcodeGen:

```sh
xcodegen generate --spec tools/WanQuicInterop/AppleMinimalQuicRepro/project.yml
xcodebuild -project tools/WanQuicInterop/AppleMinimalQuicRepro/MinimalQuicRepro.xcodeproj -scheme MinimalQuicRepro -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' CODE_SIGNING_ALLOWED=NO test
```

Physical gate: operator signs/installs the distinct bundle
com.screencasting.tools.quicminimalrepro, imports the existing ca-public.der,
then waits for a separately verified fresh Windows listener before one Connect.
Default endpoint 192.168.1.10:4433, generation 1, ALPN sc-wan-interop-v1.
Retire after result, export JSONL. Two untraced M0 attempts precede any trace.
No physical success is implied by native tests.

Evidence is owner-queue confined, fenced by run/group/control UUIDs, bounded at
256 records including reserved summary; optional diagnostics have a 128-record
budget. Any drop/storage error marks capture incomplete. Export snapshots do
not evict causal events. No full sysdiagnose may be committed or uploaded.
OS build is included in ProcessInfo OS string; model/framework image unavailable
through the selected public APIs is explicitly marked. IPA hash belongs to the
external manifest, not a self-referential field inside the IPA.
