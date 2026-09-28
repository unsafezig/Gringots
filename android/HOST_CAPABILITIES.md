# Android Host Capabilities — v1 (Draft)

Status: **Draft / Phase 0**. Normative for Phases 5–7.

The Android host owns physical resources. Zinux owns the application
model. Gringots owns protocol bytes. No layer bypasses another.

## 1. Capability table

| Capability | Owner | Granted to Zinux in first release? | Notes |
|---|---|---|---|
| `CAP_GRINGOTS_SEND` | Zinux kernel | yes | Emit SOS/frames via datagram bridge only. |
| `CAP_GRINGOTS_RECEIVE` | Zinux kernel | yes | Receive `HOST_FRAME_DELIVER`. |
| `CAP_CLOCK` | Zinux kernel | yes | Monotonic + wall clock reads. |
| `CAP_PERSISTENT_STORAGE(gringots)` | Zinux kernel | yes | App-private file backing. |
| `CAP_NETWORK_DATAGRAM` | Zinux kernel → Android bridge | yes, scoped | UDP/Wi-Fi via bridge; no raw sockets in guest. |
| `CAP_LOCATION` | Android | NO (Phase 7, consent-gated) | Only via consent flow, bounded fix. |
| `CAP_BLUETOOTH` | Android | NO (Phase 8) | Only via BLE bridge, rate-limited. |
| `CAP_AUDIO_OUT` | Android | NO (Phase 9) | Controlled speaker, no background loop. |
| `CAP_AUDIO_IN` | Android | NO (Phase 9) | Explicit capture only, never continuous. |
| Unrestricted JNI / sockets / GPS | — | NEVER | Explicit non-goal. |

## 2. Enforcement

* The guest MUST NEVER receive an Android `Socket`, `BluetoothAdapter`,
  `LocationManager`, `AudioRecord`, file path, or JNI handle.
* The bridge accepts ONLY `zinux/HOST_PROTOCOL.md` operations.
  Anything else → `HOST_ERROR(DENIED)`.
* Each transport adapter (Wi-Fi/BLE/audio) checks its capability before
  touching the Android API. Missing capability → user-visible denial,
  logged as `DENIED`, never silent success.
* Wi-Fi/UDP is first (Phase 6): `GUEST_SOS_SEND` → UDP broadcast on
  `udp/4848`. BLE (Phase 8) and audio (Phase 9) stay disabled until
  their phases land, with compile-time flags.

## 3. Lifecycle

* APK start → allocate guest memory → connect virtual serial/storage/
  datagram → boot ARM64 guest → `init` → `gringotsd` → report
  `Gringots service ready`.
* APK stop / process kill → guest paused, filesystem persisted in
  app-private storage. Restart recovers keys/replay state; expired
  sessions are swept, never resumed.
* Offline-first: boot and SOS/ACK work without internet or accounts.
