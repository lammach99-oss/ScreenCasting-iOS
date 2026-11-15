# Capture availability protocol v1

Status: coordinator-owned implementation contract. Native/Host implementation is owned by Host workers; Client implementation is owned by H1 round two. MUST and MUST NOT are normative. This is capture suspension, not GPU recovery or a source-selection transaction.

## Reserved values and compatibility

- DisplayCapabilities (17) header advertisement flag: **0x0040**. Its 52-byte payload is unchanged. Example: 0x7e00 becomes 0x7e40. This bit is not a Ping/Pong flag.
- **80 (0x50) CaptureAvailabilityHello**, Client to casting Host only, exact 4-byte payload.
- **81 (0x51) CaptureAvailability**, casting Host to Client only, exact 8-byte payload.
- Both messages use the existing 16-byte SCST v1 header, header flags zero. Header sequence is independent of the payload's availability sequence.

Allocation checked in Host/iPadZeroLagDisplayUI/WireProtocol.cs and Client/iPadZeroLagDisplay/WireCommands.swift: enums previously ended at 79. The proposed 0x0400 is TAKEN by CaptureTargetProtocol on both sides. Other used DisplayCapabilities bits: 0x0200 connection control, 0x0800 picker, 0x1000 terminal switch, 0x2000 monitor switch, 0x4000 Mirror, 0x8000 realtime media. Ping/Pong additionally use message-local 0x0100/0x0080 for USB identity and 0x4000 for remote features. 0x0040 is unused by these definitions. Do not repurpose any existing bit or export.

Supporting Host advertises only when the whole suspension path is implemented. A Client MUST NOT send 80 unless this authenticated casting connection's DisplayCapabilities advertised 0x0040. Send Hello once per authenticated connection generation, after capabilities and authentication (including existing USB identity readiness where applicable); repeated capabilities do not resend it. A Host MUST NOT send 81 until it accepted a valid 80 in this generation. Old peers exchange neither 80 nor 81. Whole-PC remote negotiation is independent and unchanged.

Hello enables only availability observation. It grants no input, source-selection, route-change, authentication, or secure-desktop capture authority. Preserve all existing gates.

## Payload layouts (little endian)

CaptureAvailabilityHello (80):

| Offset | Size | Field | Required value |
|---|---|---|---|
| 0 | 2 | version u16 | 1 |
| 2 | 2 | reserved u16 | 0 |

CaptureAvailability (81):

| Offset | Size | Field | Required value |
|---|---|---|---|
| 0 | 1 | state u8 | 0 capturing, 1 suspended |
| 1 | 1 | reason u8 | 0 none, 1 Windows security prompt/secure desktop, 2 other desktop not accessible |
| 2 | 2 | reserved u16 | 0 |
| 4 | 4 | sequence u32 | strictly increasing per authenticated generation |

Allowed pairs: (state=0, reason=0), (state=1, reason=1), (state=1, reason=2). Native reacquiring state 2 maps to wire state 1 with the retained suspension reason; it MUST NOT briefly publish capturing during a retry.

First payload sequence may be zero. After the first accepted value only strictly greater unsigned values are current; duplicates, lower values, and wraparound are stale. Sequence is independent of SourceCatalogue/Mirror/Connection revisions and of video sequence counters. Host MUST NOT reset it within a generation, including a same-connection media-route change. A replacement authenticated generation starts a new sequence domain.

## Validation and ignore policy

Validate exact payload sizes, version, header flags, direction, reserved bytes, and state/reason combinations before changing state. A valid 81 also requires authentication, advertised capability, Hello sent in this generation, and the exact current connection owner/generation. Unsupported, unnegotiated, malformed, and stale 81 are ignored and logged; they MUST NOT close the session, alter input eligibility, or clear a notice. Malformed bounded 80 is ignored/logged by Host and never opts in; no unsolicited 81 is sent in reply.

A parser drains wrong-sized bounded 80/81 without payload-sized allocation and continues with the next SCST header. Nonzero flags and wrong-direction 80 received by Client are also ignored/logged. Existing corrupt SCST framing, global oversized-payload limits, authentication failures, and truncated transport handling retain their existing policy; this contract does not require trusting a corrupt frame boundary.

Log only message kind/rejection category/sequence/generation; no keys, text, addresses, host names, credentials, or packet dumps.

## State, media, and ordering

1. Native owns indefinite suspend/reacquire with cancellable 100-250 ms backoff on a healthy device. Preserve encoder, selected output, capture/session/source identities and epochs, transport, warm virtual-display lease, and GPU recovery budget. Do not publish a terminal GPU failure for desktop access loss. Genuine device removal/reset and real monitor removal retain existing recovery.
2. On suspension entry Host fences new input and retains failed terminal releases for retry. It stops cached-frame repetition and clears unsent stale media work, while keeping the last picture visible on Client. State 1 is sent reliably on the serialized control lane before any suspension-related catalogue/state refresh. Do not publish SourceRetiring, change source identity/epoch, publish ConnectionState Faulted/Idle, or publish Mirror Unavailable/Faulted merely because desktop capture is inaccessible.
3. Client retains applied source, presentation ownership, decoder session, and rendered picture. It retires held local input once, blocks new input/text and does not cache it for replay. Terminal input remains on the original generation/authority lane; suspension is not a grant revoke. Host must keep terminal ownership when injection is denied and retry when the interactive desktop returns, without vetoing video recovery.
4. Host sends wire state 0 when fresh capture returns, followed by a forced IDR carrying VPS/SPS/PPS as required by the codec. Publish state 0 before that IDR on a shared control/media lane. Control and RTP (or split USB lanes) have no cross-lane arrival ordering: an IDR received before capturing-81 may seed the decoder dependency chain, but MUST NOT prove resume, render a new picture, or restore input. Never send a cached pre-suspension IDR as resume evidence. After resume the capture cadence MUST continue producing encoded access units even for a static desktop, using the valid post-resume cached surface; a later P frame on that IDR chain is sufficient. A single early IDR followed by permanent silence is not a conforming resume. Normal genuine media-loss recovery remains responsible for a missing dependency root.
5. Client installs synchronous decode-output and render-queue fences at suspension entry, excluding already queued frames and stale callbacks while retaining the displayed picture. The render fence shares the final authorization/present/commit lock. Work already submitted to the display system before this linearization point cannot be recalled. State 0 alone does not remove the notice or permit new input. Completion requires BOTH (a) the latest valid 81 is state 0 with a payload sequence strictly newer than the suspended 81 and (b) an access unit first received by the client's serialized transport consumer AFTER that 81 is decoded AND actually presented by the current decoder/render owner. Receipt means the complete SCST video message or authenticated reassembled RTP access unit, before source/route buffering. A pre-81 buffered frame cannot become eligible when admitted or presented later; an untracked/evicted receipt fails closed. The eligible frame need not be an IDR if a received IDR has already seeded its dependency chain. A delayed pre-pause IDR, packet receipt alone, decoder enqueue, decode-only completion, or repeated rendering of the held picture is insufficient. A newer suspended 81 fences any partial resume again. Resume does not re-select the source or replace the decoder session.
6. While wire-suspended, or waiting for the resumed picture, intentional silence must not start stall/recovery episodes or keyframe-request storms. Every client deadline waiting for capture progress counts ACTIVE time only, excluding the entire interval from accepted suspended-81 through decoded-and-presented causal resume. This includes source-switch terminal/list/first-frame recovery waits, both legacy Mirror switch phases, and all route-switch phases (preflight, accepted, replacement, Completed-to-first-frame and overall cap). Keep ordinary transport liveness/telemetry running: socket closure, failed control-channel keepalive, authentication/identity and control-transport handshake deadlines are not capture-progress waits. Disconnect releases the clock pause while retaining its monotonic offset, so a retained handoff cannot freeze forever or observe backwards time; replacement generations renegotiate availability. Retain source recovery and dependency fences for genuine faults; suppression is not blanket permission to decode stale media. On resumed picture, restore input automatically under the existing source/session permission gates and resume normal loss recovery.
7. Client notice: reason 1 = "Windows security prompt on PC"; reason 2 = "PC screen temporarily unavailable". Bare unobtrusive text over retained video, no modal. Announce once through VoiceOver per suspension episode; repeated state/snapshot traffic does not repeat the announcement.

SourceCatalogue (73), MirrorState (52), and ConnectionState (77) describe their original authorities and retain their existing ordering. Availability 81 is orthogonal. Unchanged-source catalogue/state refreshes while suspended must not abandon applied selection or show Choose a screen. A genuine newer explicit selection, removed source, permission revoke, Stop, or owner replacement still wins. Do not mask a genuine source/owner change as suspension.

Defensive same-source reattachment: when the Client has abandoned an applied presentation, remember its confirmed owner/source/target identity. A subsequent authoritative catalogue containing that same current source/owner can restore its presentation automatically without a pending user selection. Retain the old first-frame floor for unchanged epoch, use a fresh IDR boundary for changed epoch, and wait for actual render before input. A catalogue naming another current source, another owner, or a missing target does not resurrect the old selection. Expired user-request outcomes remain unknown; do not turn that path into an implicit selection.

## Reconnect and route switches

- Disconnect/replacement discards capability, Hello, payload sequence, notice, and availability authority for the old generation. Client defaults to capturing until the new generation's negotiated state says otherwise. Old callbacks/messages cannot suspend or resume a replacement.
- Every new authenticated Wi-Fi or USB connection repeats advertisement/Hello. Host sends its current availability snapshot after Hello; a suspension spanning reconnect is therefore re-announced in the new generation. Send a snapshot even if no new native state transition occurred (capturing snapshot is permitted too).
- A Wi-Fi/USB media-route switch that retains the authenticated connection retains availability sequence and current suspension. If connection-control switching replaces the connection, apply the new-generation rule above. Host re-sends current state after route resume, and before resumed media/refreshes; a duplicate unchanged snapshot is harmless and stale on Client.
- A suspended route switch does not consume or create a source-selection transaction. Old peer behavior is unchanged: picture pauses/resumes, without the new notice or negotiation.

## Golden vectors

All complete frames below use SCST header sequence 0 and flags 0.

Hello payload:
```text
01000000
```
Hello frame (20 bytes):
```text
5343535401500000040000000000000001000000
```
Suspended, security prompt, payload sequence 1 (8 bytes):
```text
0101000001000000
```
Suspended frame (24 bytes):
```text
534353540151000008000000000000000101000001000000
```
Other desktop inaccessible, payload sequence 2:
```text
0102000002000000
```
Capturing, payload sequence 3:
```text
0000000003000000
```
Capturing frame (24 bytes):
```text
534353540151000008000000000000000000000003000000
```

## Native API and Host obligations

ScCaptureAvailabilityV1 is pack 8, six 4-byte fields, sizeof 24; offsets 0 structSize, 4 state, 8 signed original HRESULT, 12 suspendCount, 16 resumeCount, 20 suspendedForMs. Caller sets structSize=24. Add ScGetCaptureAvailability; all 47 existing exports stay unchanged. Poll alongside existing native failure polling at about 100 ms. Native resumes state 0 only with fresh capture; managed observes and never rebuilds for suspension.

Host must retain/retry failed native input terminals independently of capture recovery, publish/snapshot 81 only after opt-in, retain identity/epochs/lease/budget, and force resumed IDR with parameter sets. An about-one-second desktop-return-to-picture goal requires actual device testing; no synthetic test establishes that latency or secure-desktop access.
