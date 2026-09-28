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
CREATE_SOS      () -> FRAME(150..521B)
VERIFY_FRAME    (frame) -> VALID | INVALID(reason)
DESCRIBE_FRAME  (frame) -> TEXT(≤512B) | INVALID
SEND_FRAME      (frame) -> QUEUED(host OP GUEST_SOS_SEND) | DENIED | BAD_PAYLOAD
RECEIVE_FRAME   (frame) -> ACKED | NO_ACK(reason)   // HOST_FRAME_DELIVER payload
GET_STATUS      () -> { acked:bool, pending:u8, last_nonce:?16B }
```

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
