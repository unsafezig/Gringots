# Android host bridge (Phase 5 stub)

This directory will hold the Android APK sources:

* `host/` — VM/emulator lifecycle, guest memory, virtual
  serial/storage/datagram wiring, app-private persistence.
* `transport/` — Wi-Fi/UDP (Phase 6), BLE (Phase 8), audio (Phase 9)
  adapters speaking `zinux/HOST_PROTOCOL.md`.
* `ui/` — debug console (start/stop/status) first; consent UI (Phase 7).

Rules (normative): `HOST_CAPABILITIES.md`, `CONSENT_FLOW.md`.

No APK sources yet — Phase 4 desktop bridge lands first per roadmap.
The C ABI the APK will bind is already stable: `src/ffi.zig`
(`libgringots.a`, cross-compile with `-Dtarget=aarch64-linux-android`).
