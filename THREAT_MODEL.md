# Gringots Threat Model (v1 draft)

Companion to `PROTOCOL.md` and `SECURITY.md`.

Principle: Gringots is designed for an imperfect world. No recognition means no guarantee.

---

## 1. Assets

* A1 — Civilian life and safety (primary).
* A2 — Location privacy (revealed only with consent).
* A3 — Unlinkability over time (ephemeral IDs, no permanent beacon).
* A4 — Availability of the SOS signal across transports.

## 2. Actors

| Actor | Capability | Intent |
|---|---|---|
| Civilian device | Sends SOS, consents to location, verifies ACK | Survive, be recognized |
| Compatible machine | Receives, verifies, ACKs, requests location | Deconflict / assist |
| Unknown machine | May do anything below | Unknown |
| Passive listener | Receives all radio/audio, direction-finds | Track / surveil |
| Active forger | Injects spoofed/replayed frames | Mislead machines, lure civilians |
| Network / environment | Drops, delays, jams | Accidental or hostile |

## 3. Unknown machines (normative handling)

A machine may:

1. Understand Gringots fully → verifies, ACKs.
2. Understand another protocol → sees RF energy, not the message.
3. Understand only audio fallback → decodes speaker signal.
4. Understand nothing → no reaction.
5. Ignore the signal → no reaction.
6. Deliberately refuse / deceive → fake ACK, fake request, silence.

Sender rules:

* Treat cases 2–6 identically: **no recognized ACK = no acknowledgement**.
* Never treat silence, unknown sound, or an unsigned/expired frame as ACK.
* A `LOCATION_REQUEST` from an unverified or unknown machine MUST still go through the same user-consent UI. Consent is to share location, not a trust verdict.
* Fake `ACK`s fail signature/expiry/nonce checks and are dropped — but an attacker can still jam or replay within the window (see Section 4).

## 4. Attacks and mitigations

| # | Attack | Effect | Mitigation in v1 | Residual risk |
|---|---|---|---|---|
| T1 | Passive RF tracking / fingerprinting | Presence + movement inferred | Ephemeral ID rotation, short bursts, no location by default | **High** — radio is physical; no crypto fix |
| T2 | Replay within window | Duplicate SOS / stale location | NONCE cache + TTL ≤1 h + skew ±300 s | Replays within seconds still possible; dedupe only |
| T3 | Spoofed SOS (attacker claims civilian) | Machines misled, resources diverted | Signatures bind ID, but anyone can keygen → **no vetting** | **Accepted** — protocol never proves civilianhood |
| T4 | Spoofed LOCATION_REQUEST | Lure user to disclose location | Consent UI shows requester key fingerprint + TTL; user can decline | Social engineering remains |
| T5 | Spoofed ACK | False sense of safety | ACK must be signed/fresh/linked (`REF`); UI shows "no ack" otherwise | Attacker can still jam the real ACK (DoS) |
| T6 | Audio eavesdropping | Bystanders hear fallback | Warn user; TEXT_HINT minimal; spoken sentence generic | **Accepted** for fallback |
| T7 | Jamming / DoS | Signal never arrives | Multi-transport retry (BLE→Wi-Fi→mesh→LoRa→audio) | Determined jammer wins |
| T8 | Long-term linkability | Episodes joined into track | Key rotation ≤24 h, new SESSION_ID per episode, no stable IDs | BLE MAC / RF fingerprint may still link |
| T9 | Malicious receiver stores location | Location reused after expiry | Short TTL, revocable sessions, rotated IDs | **Accepted** — disclosure is disclosure |

## 5. Non-goals (explicitly out of scope)

* Verifying that a claimant is "really" a civilian.
* Confidentiality of SOS frames (no encryption in v1).
* Anonymity against radio direction finding.
* Forcing or certifying machine behavior.
* Military use — prohibited, see `CIVILIAN_LICENSE.md`.

## 6. Assumptions

* CSPRNG available on sender and receiver.
* Receiver has roughly correct wall clock (±300 s) except noted zero-time audio case.
* Attacker does not break Ed25519 or SHA-512 (Ed25519 internals).
* Users can read a consent prompt; implementations MUST NOT auto-share location.

## 7. Phase mapping

* Phase 1 (this doc): model fixed.
* Phase 2: nonce cache, parser hardening, fuzz, golden vectors.
* Phase 3+: per-transport risks (BLE MAC stability, Wi-Fi probe leakage, mesh relay trust).
* Phase 4: acoustic side-channels (audibility range, recording/replay of audio packets).
