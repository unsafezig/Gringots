# Gringots Protocol — Version 1 (Draft)

Status: **Draft / Phase 1**. Normative for `GRINGOTTS/1`.

This document defines the transport-independent Gringots message.
It covers framing, binary TLV encoding, message types, identity,
timing, signatures, acknowledgements, conditional location disclosure,
safety sessions, and transport bindings.

Companion documents:

* `SECURITY.md` — signature scope, replay, clock, privacy rules
* `THREAT_MODEL.md` — attacker model, non-goals, unknown machines
* `CIVILIAN_LICENSE.md` — permitted civilian use only
* `README.md` — overview and roadmap

Design choices fixed for v1 (per project decision):

* **Binary TLV** on the wire. Text form is debug-only.
* **Ed25519** ephemeral identity. The ephemeral ID *is* the public key.
* Reference implementation language: Zig 0.16 (Phase 2, not this document).

---

## 1. Goals and non-goals

### 1.1 Goals

* Give a civilian device one recognizable signal: `I am a civilian. I am not a threat.`
* Work without a shared network: BLE, Wi-Fi, mesh, LoRa, Zinux, audio — same message.
* No permanent beacon: a valid announcement carries **no location** by default.
* Location only after explicit, temporary, revocable, authenticated user consent.
* Small enough for constrained civilian devices (max frame ~521 bytes).

### 1.2 Non-goals

* The protocol does **not** identify enemies. It only lets civilians identify themselves if they choose to.
* A signature proves binding to a temporary ID. It does **not** prove a person is a civilian.
* The protocol cannot force any machine to respond or to behave safely.
* No confidentiality: frames are **authenticated, not encrypted**.

---

## 2. Notation

* `BE` = big-endian. All multi-byte integers are BE.
* `HEX` strings are lowercase, no `0x` prefix unless stated.
* `MUST / MUST NOT / SHOULD / MAY` per RFC 2119.
* Test timestamps use Unix seconds (e.g. `1798675200` = 2027-01-01T00:00:00Z).

---

## 3. Transport-independent frame

Every transport carries exactly the same byte string:

```
 0   1   2   3   4  ...  5+MLEN-1  5+MLEN ... 8+MLEN
+---+---+---+---+---+--- ... ---+--- ... ---+
| MAGIC |VER|  MLEN   |     BODY      |    CRC32    |
| 2B  |1B |  2B BE  |   MLEN bytes  |   4B BE     |
+---+---+---+---+---+--- ... ---+--- ... ---+
```

| Field | Value |
|---|---|
| `MAGIC` | `0x47 0x52` — ASCII `GR` |
| `VER` | `0x01` for this spec. Receivers MUST reject other versions. |
| `MLEN` | `BE u16`, length of `BODY` in bytes. MUST be `68..512`. |
| `BODY` | TLV sequence (Section 4). Canonical order RECOMMENDED, any order MUST be accepted. |
| `CRC32` | IEEE CRC32 (`poly 0x04C11DB7`, init `0xFFFFFFFF`, xorout `0xFFFFFFFF`) computed over `MAGIC || VER || MLEN || BODY`. |

Receivers MUST:

1. Check `MAGIC` and `VER`.
2. Check `MLEN` range and that enough bytes arrived.
3. Check `CRC32`. Drop frame on mismatch, no response.
4. Parse TLVs per Section 4, then verify signature per `SECURITY.md`.
5. Never respond to a frame that fails steps 1–4.

Minimum valid `BODY` is 141 bytes (SOS with zeroed signature, see Section 8).
Maximum total frame on wire: `2 + 1 + 2 + 512 + 4 = 521` bytes.

---

## 4. TLV encoding

```
TYPE(1B) | LEN(1B) | VALUE(LEN bytes)
```

* `LEN` is the length of `VALUE` only.
* Unknown `TYPE` MUST be ignored (forward compatibility), **except** inside the signature scope it MUST still be covered (signature covers raw bytes, so unknown fields are authenticated automatically).
* Duplicate `TYPE` in one frame: receiver MUST keep the **first** occurrence and ignore later ones, except `0xFF` which MUST appear exactly once and MUST be last.
* Truncated TLV (`claimed LEN` beyond frame) → drop frame, no response.

### 4.1 Field registry (v1)

| TYPE | Name | LEN | Meaning |
|---|---|---|---|
| `0x01` | `MSG_TYPE` | 1 | Message type enum (Section 5) |
| `0x02` | `EPHEMERAL_ID` | 32 | Ed25519 public key, the temporary identity |
| `0x03` | `TIMESTAMP` | 8 | `u64 BE` Unix seconds, creation time |
| `0x04` | `EXPIRES` | 8 | `u64 BE` Unix seconds, expiry time |
| `0x05` | `NONCE` | 16 | Random bytes, replay protection |
| `0x10` | `LAT` | 4 | `i32 BE`, latitude × 1e7, only with consent |
| `0x11` | `LON` | 4 | `i32 BE`, longitude × 1e7, only with consent |
| `0x12` | `SESSION_ID` | 16 | Safety-session identifier |
| `0x13` | `REF` | 16 | Reference to another frame's `NONCE` (ACK / request link) |
| `0x14` | `TEXT_HINT` | 0..64 | UTF-8 hint, e.g. spoken fallback marker. MUST NOT affect handling. |
| `0xFF` | `SIGNATURE` | 64 | Ed25519 signature, MUST be last TLV |

`0x00`, `0x06..0x0F`, `0x15..0xFE` are reserved.

---

## 5. Message types (`0x01` value)

| Value | Name | Required extra TLVs | Description |
|---|---|---|---|
| `0x01` | `CIVILIAN_SOS` | — | "I am a civilian. I am not a threat." No location. |
| `0x02` | `LOCATION_REQUEST` | `REF` = SOS `NONCE` | Machine asks for location. Displayed to user. |
| `0x03` | `LOCATION_CONSENT` | `SESSION_ID`, (`REF` = request `NONCE`) | Device signals user accepted; carries TTL via `EXPIRES`, not location yet. |
| `0x04` | `LOCATION_DISCLOSED` | `LAT`, `LON`, `SESSION_ID` | Location bound to same `EPHEMERAL_ID`. |
| `0x05` | `MOVING_TO_SAFETY` | `SESSION_ID` | Civilian starts moving; invites update requests. |
| `0x06` | `LOCATION_UPDATE` | `LAT`, `LON`, `SESSION_ID` | Voluntary position update inside a session. |
| `0x07` | `ACK` | `REF` = acked `NONCE` | Recognized acknowledgement. Only this counts. |
| `0x08` | `DECLINE` | (`REF`) | User declined, or machine declines session. No reason required. |

Rules:

* `CIVILIAN_SOS` MUST NOT contain `LAT`/`LON`. Receivers MUST ignore location in SOS.
* `LOCATION_DISCLOSED` / `LOCATION_UPDATE` without matching `SESSION_ID` + same `EPHEMERAL_ID` MUST be rejected.
* `ACK` without `REF` MUST be rejected. An `ACK` for an unknown `NONCE` MUST be ignored.
* Silence, unknown sound, or any frame without a valid `ACK` (`0x07` + correct `REF` + valid signature) MUST be treated as **no acknowledgement** (see Section 7).

Text debug form (never on wire):

```
GRINGOTTS/1 TYPE=CIVILIAN_SOS ID=<hex:32B> TIMESTAMP=<u64> EXPIRES=<u64> SIGNATURE=<hex:64B>
```

---

## 6. Identity, time, signature

Full rules in `SECURITY.md`. Summary:

* `EPHEMERAL_ID` = 32-byte Ed25519 public key. Fresh keypair per power-cycle or at most 24 h lifetime.
* `TIMESTAMP` = creation time. `EXPIRES` = hard expiry. `EXPIRES - TIMESTAMP` MUST be `≤ 3600 s`.
* Clock skew tolerance: `±300 s`. Outside window → reject.
* `SIGNATURE` = `Ed25519(sign, privkey, MAGIC || VER || MLEN || BODY-without-0xFF-TLV)`. Covers every byte before the `0xFF` TLV header.
* Verification uses `EPHEMERAL_ID` as pubkey. Failure → drop, no response.

---

## 7. Acknowledgements and unknown machines

```
CIVILIAN DEVICE                    MACHINE
      |--- CIVILIAN_SOS ------------->|
      |                               | (may or may not understand)
      |<-- ACK(REF=sos.nonce) ---------|  only if Gringots-compatible
      |--- (silence otherwise)         |
```

* The **only** acknowledgement is a valid `ACK` frame (`0x07`) with correct `REF`, valid signature, unexpired.
* The civilian device MUST assume **no acknowledgement** unless such an `ACK` is received and verified.
* A machine MAY: understand Gringots, understand only audio, understand another protocol, understand nothing, ignore, or refuse. All are legal. The device MUST NOT retry in a way that becomes a permanent beacon (see Section 9).

---

## 8. Example vectors (structure-valid, signature-zeroed)

> Signatures below are `64 × 0x00` placeholders to illustrate layout and CRC.
> They are **not** valid signatures and MUST fail verification.
> Real signed vectors will ship with the Phase 2 reference implementation.

### 8.1 `CIVILIAN_SOS` (141-byte body, 150-byte frame)

Fields: `MSG_TYPE=0x01`, `EPHEMERAL_ID=000102...1f` (test key),
`TIMESTAMP=1798675200 (0x6B359B00)`, `EXPIRES=1798675800 (+600 s)`,
`NONCE=0102030405060708090a0b0c0d0e0f10`, `SIGNATURE=00×64`.

```
BODY (141 B):
0101010220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
0308000000006b359b000408000000006b359d58
05100102030405060708090a0b0c0d0e0f10
ff400000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000

FRAME (150 B, MAGIC+VER+MLEN+BODY+CRC32=319d4099):
475201008d<BODY>319d4099
```

Full frame hex:

```
475201008d0101010220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b000408000000006b359d5805100102030405060708090a0b0c0d0e0f10ff4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000319d4099
```

### 8.2 `ACK` (159-byte body)

`MSG_TYPE=0x07`, same test key, `TIMESTAMP=1798675210`, `EXPIRES=+300 s`,
`NONCE=aa×16`, `REF=010203...0f10` (acks the SOS above), zeroed signature.

```
FRAME (168 B, CRC32=3f292d3c):
475201009f0101070220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b0a0408000000006b359c360510aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa13100102030405060708090a0b0c0d0e0f10ff40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f292d3c
```

Decoders MUST reproduce these `CRC32` values for the given bytes.

---

## 9. Conditional location disclosure

No location without consent. Normal case carries no GPS.

```
 CIVILIAN_SOS (no LAT/LON)
       ↓
 LOCATION_REQUEST (REF=sos.nonce, signed by machine's own ephemeral key)
       ↓
 USER_CONSENT — phone UI:
   "A Gringots-enabled device is requesting your location.
    Share your location for 10 minutes? [ SHARE ] [ DECLINE ]"
       ↓
 LOCATION_CONSENT (SESSION_ID=new random, EXPIRES=now+600)
       ↓
 LOCATION_DISCLOSED (LAT, LON, SESSION_ID, same EPHEMERAL_ID)
```

Rules:

* `LOCATION_REQUEST` without `REF` SHOULD be shown as generic request, not linked.
* `LOCATION_DISCLOSED` MUST use the same `EPHEMERAL_ID` as the SOS so the receiver can link "same civilian".
* Disclosure SHOULD carry `EXPIRES ≤ now + 600 s` (10 min default). User MAY revoke → device sends `DECLINE(REF=session-request-nonce)` and stops.
* `LAT`/`LON` are `i32 BE` degrees × 1e7 (e.g. `60.1699° → 601699000`).

---

## 10. Moving to safety (temporary session)

```
CIVILIAN_SOS → LOCATION_DISCLOSED → MOVING_TO_SAFETY(SESSION_ID)
  → LOCATION_UPDATE_REQUEST (= LOCATION_REQUEST + SESSION_ID)
  → USER_CONSENT → LOCATION_UPDATE (new LAT/LON, same SESSION_ID)
```

* The device MUST NOT become a periodic beacon. Each `LOCATION_UPDATE` requires either a fresh request + consent, or a session consent that explicitly covers N updates / T minutes.
* Session ends on `EXPIRES`, explicit `DECLINE`, new `EPHEMERAL_ID`, or user revocation. After that, `SESSION_ID` MUST NOT be reused.

---

## 11. Transport bindings

All transports carry the Section 3 frame unchanged, except for fragmentation headers noted below. The message stays the same; only the transport changes.

| Transport | Binding |
|---|---|
| UDP broadcast / Wi-Fi / mesh / Zinux | Frame as datagram payload on `udp/4848`. |
| BLE 5.x Adv | Manufacturer-specific AD (company `0xFFFF` reserved), Gringots UUID TBD. Fragment into ≤180 B chunks: `[0x47][total:1B][idx:1B][frame-nonce:16B][payload]`. Reassemble by frame `NONCE`. Advertise ≤1 Hz, ≤5 min per SOS burst. |
| LoRa | Frame as raw payload. Duty-cycle compliant. Spreading-factor TBD Phase 6. |
| Audio (fallback) | FSK 1200/2400 Hz, 300 baud (coherent, 4/8 cycles per bit; 44100 Hz default = 147 samples/bit). Packet bits: 64 alternating preamble + 32-bit sync `0xD5B7A25A` (searched fuzzily, ≤2 errors) + `len:u16BE` (RS codeword bytes) + `flen:u16BE` (frame bytes) + RS(255,223) blocks covering the full frame (≤3 blocks). Reference codec exchanges PCM16 mono WAV files as the speaker/microphone boundary. Followed by optional spoken `"Civilian. I am not a threat."` |

Audio fallback concept:

```
PHONE: BLE ❌, Wi-Fi ❌, Mesh ❌, LoRa ❌ → Speaker 🔊 → Robot mic 🎙️ → GRINGOTTS MESSAGE
```

Receivers announce supported transports in `ACK` only via future TLV (reserved, not v1).

---

## 12. Receiver handling (normative)

1. Validate framing → TLV → time window → signature → nonce-freshness.
2. On `CIVILIAN_SOS`: register civilian presence, MAY send `ACK`, MAY send `LOCATION_REQUEST`.
3. On `LOCATION_DISCLOSED`/`UPDATE`: accept only if session + ID link checks pass.
4. Rate-limit `ACK`s: at most one per `NONCE`.
5. Never assume location from signal strength. Never treat non-`ACK` as `ACK`.

## 13. Versioning

* `VER=0x01`. Minor clarifications keep `VER`, incompatible wire changes bump `VER`.
* Unknown TLVs ignored → forward compatible within a major version.

---

## Appendix A — Checklist for Phase 2 implementers

* [ ] Encoder/decoder round-trips the two Section 8 vectors (CRC match).
* [ ] Rejects bad magic/version/length/CRC/truncation/duplicates.
* [ ] Enforces time window + expiry cap + nonce cache.
* [ ] Verifies Ed25519 over the exact scope in Section 6.
* [ ] `decode --text` prints the Section 5 debug form.
* [ ] Fuzz corpus seeded with Section 8 frames.
