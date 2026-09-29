# Zinux Guest-Host Protocol — v1 (Draft)

Status: **Draft / Phase 0**. Normative for the first vertical milestone.

This document defines every message crossing the Zinux guest-host
boundary for the Gringots first-release path. Companion docs:

* `GRINGOTS_SERVICE.md` — `gringotsd` IPC inside the guest
* `../android/HOST_CAPABILITIES.md` — what the host may do
* `../android/CONSENT_FLOW.md` — consent-gated messages
* `../PROTOCOL.md`, `../SECURITY.md` — Gringots wire format (unchanged)

## 1. Framing

Every guest-host message is one datagram:

```text
 0   1   2   3   4   5  ...  5+LEN-1  5+LEN ... 8+LEN
+---+---+---+---+---+---+--- ... ---+--- ... ---+
| MAGIC |VER| OP|  LEN    |    PAYLOAD    |   CRC32   |
| 2B  |1B |1B | 2B BE   |   LEN bytes   |  4B BE    |
+---+---+---+---+---+---+--- ... ---+--- ... ---+
```

| Field | Value |
|---|---|
| `MAGIC` | `0x5A 0x47` — ASCII `ZG` |
| `VER` | `0x01`. Receivers MUST reject other versions. |
| `OP` | Operation code (Section 2). |
| `LEN` | `BE u16`, length of `PAYLOAD`. MUST be `0..1024`. |
| `PAYLOAD` | Operation body. |
| `CRC32` | IEEE CRC32 over `MAGIC \|\| VER \|\| OP \|\| LEN \|\| PAYLOAD`. Same polynomial as Gringots. |

Receivers MUST, in order:

1. Check `MAGIC` and `VER`.
2. Check `LEN` range and that enough bytes arrived.
3. Check `CRC32`. Drop on mismatch, no response.
4. Dispatch on `OP` + direction (Section 2). Wrong direction → drop + `HOST_ERROR(BAD_DIRECTION)` where a return path exists.
5. Validate `PAYLOAD` shape. Malformed → drop + `HOST_ERROR` where a return path exists.

Total max datagram: `2 + 1 + 1 + 2 + 1024 + 4 = 1034` bytes.

## 2. Operations

| OP | Name | Direction | Payload | Meaning |
|---|---|---|---|---|
| `0x01` | `GUEST_SOS_SEND` | guest → host | Gringots frame (`150..521` B) | `gringotsd` asks the host to transmit one frame. |
| `0x02` | `HOST_FRAME_DELIVER` | host → guest | Gringots frame (`150..521` B) | Host delivers one received frame (e.g. `ACK`). |
| `0x03` | `GUEST_STATUS_REQ` | guest → host | empty (`LEN=0`) | Poll host bridge status. |
| `0x04` | `HOST_STATUS_RESP` | host → guest | `acked:1B, pending_consents:1B, reserved:2B` | Bridge/service status snapshot. |
| `0x05` | `HOST_ERROR` | host → guest | `code:1B [, detail:UTF-8 ≤32B]` | Rejection notice. Never a Gringots `ACK`. |
| `0x06` | `HOST_CONSENT_DECISION` | host → guest | `req_id:4B BE, decision:1B (0=deny,1=approve), at:8B BE` | User consent result for a pending location request. |
| `0x07` | `HOST_TIME_SYNC` | host → guest | `wall:8B BE (unix seconds)` | Wall-clock delivery for identity rotation. Reserved for the Android bridge; the desktop shim uses semihosting `SYS_TIME` instead. |

Error codes (`HOST_ERROR.code`):

| Code | Name | When |
|---|---|---|
| `0x01` | `BAD_DIRECTION` | OP arrived on the wrong side. |
| `0x02` | `BAD_PAYLOAD` | PAYLOAD shape invalid (e.g. not a Gringots frame). |
| `0x03` | `DENIED` | Guest lacks the capability for this OP. |
| `0x04` | `TRANSPORT_FAIL` | Host transmit failed (radio off, no route). Not an ACK. |

## 3. Ownership rules

* The guest owns the application model: it creates protocol bytes and
  verifies inbound bytes. It never touches radios, sockets, GPS, or UI.
* The host owns physical resources: radios, clocks (wall time source),
  storage backing, and the consent UI. It never mints Gringots frames in
  the guest's identity and never auto-approves consent.
* Gringots bytes are opaque to the bridge: the bridge MUST NOT rewrite
  frames. It MAY drop oversized/direction-violating datagrams.
* Silence is the default failure: an unparsable guest-host datagram is
  dropped. `HOST_ERROR` is best-effort only when the datagram was
  attributable to a live guest port.

## 4. Capability binding (guest side)

The Zinux kernel grants `gringotsd` exactly:

```text
CAP_GRINGOTS_SEND
CAP_GRINGOTS_RECEIVE
CAP_CLOCK
CAP_PERSISTENT_STORAGE(gringots)
CAP_NETWORK_DATAGRAM
```

* `GUEST_SOS_SEND` requires `CAP_NETWORK_DATAGRAM` + `CAP_GRINGOTS_SEND`.
* `HOST_FRAME_DELIVER` receive requires `CAP_GRINGOTS_RECEIVE`.
* Location/microphone/speaker/Bluetooth capabilities are NOT granted in
  this phase. Any `OP` needing them MUST fail with `DENIED`.

## 7. Wall time (desktop vs Android)

`HOST_TIME_SYNC` carries the host's unix wall time for identity-rotation
decisions (`service.onWallTime` contract: stamp fresh regions, rotate past
`IDENTITY_LIFETIME_S` or on backwards jumps). On desktop QEMU the guest
reads semihosting `SYS_TIME` directly in its `CLOCK_WALL` handler — a
documented shim, not the protocol path. The Android bridge MUST deliver
`HOST_TIME_SYNC` (unsolicited, at bridge start and at most hourly
after); the guest MUST ignore wall times older than its stored
`created_at` except by rotating (never silently rewinding trust).

## 5. Failure behavior matrix

| Failure | Guest behavior | Host behavior |
|---|---|---|
| Invalid magic/version/len/CRC | drop, no response | drop, no response |
| Unsupported OP | drop + count | drop + `HOST_ERROR(BAD_PAYLOAD)` if from guest |
| Wrong direction | drop | `HOST_ERROR(BAD_DIRECTION)` |
| PAYLOAD not a Gringots frame | N/A (guest validates on deliver) | `HOST_ERROR(BAD_PAYLOAD)`, frame never transmitted |
| Transmit fails | reports `TRANSPORT_FAIL`, not ACK | sends `HOST_ERROR(TRANSPORT_FAIL)` |
| Unknown inbound Gringots frame | `RECEIVE_FRAME` returns `NO_ACK`, state unchanged | N/A |

A transport failure MUST NEVER be reported as a valid acknowledgement.
Only a verified Gringots `ACK` (`0x07` + correct `REF` + valid signature)
counts — see `GRINGOTS_SERVICE.md`.

## 6. Desktop reference mapping (Phase 4)

On desktop the "host bridge" is a loopback process:

```text
gringotsd (fake bridge) → GUEST_SOS_SEND → desktop bridge
    → UDP 127.0.0.1:4848 → test_receiver → ACK
    → HOST_FRAME_DELIVER → gringotsd.RECEIVE_FRAME → GET_STATUS(acked=true)
```

The desktop bridge speaks this exact framing; only the transport under it
(UDP loopback vs Android Wi-Fi/BLE) differs.
