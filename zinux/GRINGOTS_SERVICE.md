# Gringots Service (`gringotsd`) — Zinux Userland API — v1 (Draft)

Status: **Draft / Phase 0**. Implements roadmap Phase 3 service surface.

`gringotsd` is the first Zinux userland service. It wraps the existing
platform-independent agent core (`src/agent/service.zig`) with a Zinux
adapter. Keys and replay state live in Gringots-owned storage; the
service is driven through Zinux IPC ports and capability handles.

Reference implementation: `zinux/gringotsd/service_ipc.zig`
(host-testable pure logic) + a thin Zinux syscall adapter (Phase 2/3).

## 1. Operations

All operations are request/response over a Zinux IPC port. Encodings
below are the canonical host-test byte forms; the Zinux port adapter
carries the same fields.

```text
CREATE_SOS      () -> FRAME(150..521B)                          [SVC 16]
VERIFY_FRAME    (frame) -> VALID | MALFORMED | TIME | BAD_SIG | SEMANTICS  [SVC 20]
DESCRIBE_FRAME  (frame) -> TEXT(≤512B) | INVALID                 [SVC 21]
SEND_FRAME      (frame) -> QUEUED(host OP GUEST_SOS_SEND) | DENIED | BAD_PAYLOAD  [SVC 22]
RECEIVE_FRAME   (frame) -> ACKED | NO_ACK(reason)   // HOST_FRAME_DELIVER payload  [SVC 17]
GET_STATUS      () -> { acked:bool, pending:u8, last_nonce:?16B }  [SVC 18]
```

Guest SVC mapping (`Zinux/kernel/arch/aarch64/syscall.zig`): 16 = mint
demo SOS into EL0 out-struct + queue, 17 = verify one RX datagram as our
ACK (staged reject codes), 18 = status bits + last nonce, 19 = unique
nonce mint (service stream, not enqueued), 20/21/22 as above. EL0
exercises valid + corrupted + empty cases; mismatches hang the gate
visibly. `LOCATION_CONSENT`/`LOCATION_DISCLOSED` stay refused without a
`HOST_CONSENT_DECISION(approve)`.

### Semantics

* `CREATE_SOS` — tick the agent (`tick(now)`), take the SOS frame from
  the outbox. Requires `CAP_GRINGOTS_SEND`. Never includes location.
* `VERIFY_FRAME` — `msg.verifyFrame(frame, now)`: framing → TLV → time
  window → Ed25519. Failure returns `INVALID` with one of:
  `BAD_MAGIC, BAD_VERSION, BAD_LENGTH, BAD_CRC, MALFORMED_TLV,
  BAD_SIGNATURE, EXPIRED, NOT_YET_VALID, TTL_TOO_LONG, REPLAYED`.
  Never responds to the sender; this is a local verdict.
* `DESCRIBE_FRAME` — structure-only parse + `formatDebug`. Does NOT
  verify the signature; callers must use `VERIFY_FRAME` for trust.
* `SEND_FRAME` — validate locally (`decodeFrame` shape check), then emit
  host-protocol `GUEST_SOS_SEND`. Requires `CAP_NETWORK_DATAGRAM`.
  Oversize/wrong bytes → `BAD_PAYLOAD`, never transmitted.
* `RECEIVE_FRAME` — feed one inbound frame (`onFrame`). Returns `ACKED`
  only when the frame is a valid `ACK` referencing the last SOS `NONCE`.
  Everything else (including silence/garbage) → `NO_ACK`. Replayed
  nonces → `NO_ACK(REPLAYED)`.
* `GET_STATUS` — `{ acked, pendingConsents, last_sos_nonce }`.
  `acked` means "someone claims acknowledgement" (any keypair can mint
  an ACK); hosts MUST surface that caveat in UI.

### Initial capabilities

```text
CAP_GRINGOTS_SEND
CAP_GRINGOTS_RECEIVE
CAP_CLOCK
CAP_PERSISTENT_STORAGE(gringots)
CAP_NETWORK_DATAGRAM
```

Location, microphone, speaker and Bluetooth are explicitly NOT granted
in this phase. Consent-gated location ops (`LOCATION_CONSENT`,
`LOCATION_DISCLOSED`) exist in the agent core but the service MUST
refuse to emit them without a `HOST_CONSENT_DECISION(approve)` — see
`../android/CONSENT_FLOW.md`.

## 2. State

* Ephemeral identity: per power-cycle / ≤24 h rotation (agent core).
* Replay cache: 64-entry ring, `(EPHEMERAL_ID, NONCE)` keyed.
* One active safety session at a time (single-session scope).
* Outbox: 8 frames max, oldest-overwritten, never grows.
* Persistent: seed + replay window + session expiry in
  `CAP_PERSISTENT_STORAGE(gringots)` so restarts survive normally.

### 2.1 Guest storage layout (service v1, implemented)

Byte offsets in the 4 KiB Gringots-owned region, integers little-endian
(`Zinux/kernel/arch/aarch64/gringots/service.zig`):

```text
0..32    identity seed
32..40   created_at wall time (0 = demo/unset)
40..48   boot counter (++ per service init)
48..52   magic "GRG1" (absent = fresh start)
52..56   reserved
56..64   demo SOS count
64..72   nonce stream state (splitmix64, reseeded per boot)
72..80   flags (bit0 = acked)
80..96   last demo nonce (16 B)
96..104  replay validity bitmap (u64)
104..3688 replay ring: 64 x (id 32 B + nonce 16 B + expires u64)
3688..3696 replay cursor (u64)
```

File backing on desktop: `zig-out/gringots-store.dat` via semihosting
(loaded at service init, stored on every mutation).

### 2.2 Identity rotation (implemented)

* Drive: `service.onWallTime(wall)` after init; fresh regions stamp
  `created_at`, expired (`IDENTITY_LIFETIME_S`) or backwards clocks start
  a new epoch. Desktop wall time comes from semihosting `SYS_TIME`;
  Android will use `HOST_TIME_SYNC`.
* Epoch: stream-derived seed, `created_at` update, acked + SOS state
  cleared, replay ring kept, everything persisted.
* On-demand: `SYS_GRINGOTS_ROTATE` (SVC 23) rotates immediately and
  prints `identity rotated`; the EL0 demo proves SOS state clears.
* Demo mint stays on the fixed vector (bridge determinism); the stream
  is the production nonce path under test.

## 3. Milestone (Phase 3)

```text
zinux> gringots sos
Gringots SOS created
Frame valid
```

Host-test equivalent (no kernel needed):

```text
zig build test -- gringotsd   # service_ipc + e2e SOS/ACK pass
```

## 4. Non-goals in this phase

No package ecosystem, shell features, desktop UI, BLE/audio transports,
or background location. Those arrive in Phases 6–11 behind explicit
capabilities and consent.
