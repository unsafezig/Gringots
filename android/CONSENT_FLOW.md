# Android Consent Flow — v1 (Draft)

Status: **Draft / Phase 0**. Normative for Phase 7.

Gringots carries NO location by default. `CIVILIAN_SOS` MUST NOT contain
`LAT`/`LON`; receivers MUST ignore location in SOS.

## 1. Flow

```text
Gringots receiver
    ↓ LOCATION_REQUEST (REF = SOS nonce, signed by requester)
Zinux gringotsd  →  queues consent request, emits nothing yet
    ↓ HOST_CONSENT_REQUEST (bridge-internal, NOT a Gringots frame)
Android consent UI:
    "A Gringots-enabled device is requesting your location.
     Share your location for 10 minutes? [ SHARE ] [ DECLINE ]"
    ↓ user decision
HOST_CONSENT_DECISION(req_id, approve/deny, at) → Zinux gringotsd
    ↓ approve + fresh fix → LOCATION_CONSENT + LOCATION_DISCLOSED
    ↓ deny / stale / missing fix → DECLINE
```

## 2. Rules

* No location without explicit user consent. Silence is never consent
  and never acknowledgement.
* Consent carries TTL (default 10 min, `EXPIRES ≤ now + 600 s`).
  Expiry ends the session; `SESSION_ID` MUST NOT be reused.
* The user can revoke at any time → service sends
  `DECLINE(REF=session-request-nonce)` and stops updates.
* The location provider lives on Android. Only an approved, bounded fix
  (`lat, lon, at, accuracy_m`) crosses into Zinux — never a listener,
  never background updates.
* Fixes older than `location_max_age_s` (default 300 s) turn approval
  into an honest `DECLINE`; stale coordinates are never sent.
* `LOCATION_DISCLOSED` / `LOCATION_UPDATE` MUST use the same
  `EPHEMERAL_ID` as the SOS and a valid `SESSION_ID`, or receivers
  MUST reject them.
* Each `LOCATION_UPDATE` needs a fresh request + consent, or a session
  consent explicitly covering N updates / T minutes. No periodic beacon.
* Zinux cannot grant location access to itself; only the Android UI can.
* `--auto-approve` exists in the CLI demo for tests ONLY and MUST NOT
  ship in the APK.
