# Gringots Security

Companion to `PROTOCOL.md` (v1 draft). Normative where `MUST` is used.

Gringots is a safety signal, not a guarantee of protection.
Anyone can claim civilian status. Radio can be detected. Machines may ignore the signal.

---

## 1. Cryptographic identity (Ed25519)

* Each device generates an **ephemeral Ed25519 keypair** at boot or at SOS activation.
* `EPHEMERAL_ID` (`0x02`, 32 B) is the public key. It is the temporary identity — no separate ID table.
* Private key lives in RAM only. It MUST be zeroed on rotation, session end, or power-off.
* Rotation: new keypair at least every **24 h**, on every app restart, and whenever the user taps "new identity".
* All frames from one civilian "episode" (SOS → location → safety session) SHOULD share the same `EPHEMERAL_ID` so the receiver can link them. A new episode SHOULD use a new keypair.

Why Ed25519:

* Available in `std.crypto` (Zig 0.16), small keys/signatures (32/64 B), deterministic, well reviewed.
* No X25519 key exchange in v1 — frames are authenticated, not encrypted.

### 1.1 Signature scope (exact)

```
signed_bytes = MAGIC || VER || MLEN || BODY[0 .. offset_of_0xFF_TLV_header]
```

* `BODY` includes every TLV **before** the `0xFF` header, in received byte order (no reordering, no canonicalization).
* `SIGNATURE` TLV is `0xFF 0x40 <64 B>`, MUST be the last TLV.
* Sign with Ed25519 private key; verify with `EPHEMERAL_ID`.
* Verification failure → drop frame silently. MUST NOT send `ACK` or error reply (prevents oracle / amplification).

---

## 2. Time: timestamps, expiry, skew

Fields: `TIMESTAMP` (`0x03`, u64 BE), `EXPIRES` (`0x04`, u64 BE).

Rules:

1. `EXPIRES > TIMESTAMP`, else reject.
2. `EXPIRES - TIMESTAMP ≤ 3600` s, else reject (1 h cap).
3. Accept iff `TIMESTAMP - 300 ≤ now ≤ EXPIRES + 300` (300 s skew tolerance each way).
4. `now` is receiver-local Unix time. Receivers SHOULD have a sane clock; devices without a clock MUST set `TIMESTAMP = EXPIRES = 0` — such frames are valid only for live audio-range exchange and MUST be marked `untrusted-time` (no session, no location).
5. Disclosure TTL: `LOCATION_DISCLOSED` SHOULD use `EXPIRES ≤ now + 600` s.

Short lifetimes limit replay value and passive tracking.

---

## 3. Replay protection

* `NONCE` (`0x05`, 16 B) MUST come from a CSPRNG.
* Receivers keep a cache of seen `(EPHEMERAL_ID, NONCE)` for at least **1 h** (or until `EXPIRES + 300 s`, whichever is longer).
* Duplicate → drop silently, no second `ACK`.
* `ACK` rate limit: at most one `ACK` per `NONCE`.
* SOS bursts (BLE/audio retransmit of the identical frame) are expected — dedupe by `NONCE`, do not treat as attack.

---

## 4. Parsing hardening

* Enforce `MLEN 68..512`, `LEN` bounds, no overread.
* Duplicated `MSG_TYPE` → first wins; duplicated `SIGNATURE` or misplaced `SIGNATURE` → reject.
* `TEXT_HINT` (`0x14`) max 64 B, MUST be valid UTF-8, MUST NOT influence decisions.
* Unknown TLVs ignored but still signature-covered.
* Phase 2 MUST add unit + fuzz tests seeded with `PROTOCOL.md` Section 8 vectors.

---

## 5. Privacy

* `CIVILIAN_SOS` carries **no location**. Implementations MUST NOT add `LAT`/`LON` by default.
* Location TLVs (`0x10`/`0x11`) MUST only be sent after visible user consent (see `PROTOCOL.md` Section 9), with countdown/expiry shown.
* Revocation: user can cancel anytime → device stops sending location, rotates `EPHEMERAL_ID`, sends `DECLINE` if a session is open.
* Passive-tracking minimization: rotate keys, randomize `NONCE`, avoid stable BLE MACs where platform allows, cap retransmit bursts (≤1 Hz, ≤5 min).
* Audio fallback is overhearable by humans and machines. Users SHOULD be warned before speaker use.
* Radio frames are detectable (direction finding, metadata). Gringots provides **no anonymity against RF hunters** — see `THREAT_MODEL.md`.

---

## 6. Key limitations (must surface in UI/docs)

1. Anyone may claim civilian status — no vetting.
2. Transmissions may reveal presence / rough bearing.
3. Spoofing and replay are possible outside the time/nonce window; receivers decide trust themselves.
4. Machines may ignore Gringots entirely.
5. Location disclosure reveals sensitive data.
6. No protocol can control autonomous-system behavior.

The sender UI MUST NOT display "you are safe" or "acknowledged" without a verified `ACK` (`MSG_TYPE 0x07` + correct `REF` + valid signature + fresh). Otherwise display "no acknowledgement".
