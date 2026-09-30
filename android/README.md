# Android host bridge (Phase 5)

This directory holds the Android APK sources:

* `app/` — debug APK: `AndroidManifest.xml`, `GringotsBridge.java`
  (JNI binding to `libgringots.so`, see `src/jni.zig`), `MainActivity.java`
  (start/stop/status debug console with deterministic native self-test).
* `host/` — (next slice) VM/emulator lifecycle, guest memory, virtual
  serial/storage/datagram wiring, app-private persistence.
* `transport/` — Wi-Fi/UDP (Phase 6), BLE (Phase 8), audio (Phase 9)
  adapters speaking `zinux/HOST_PROTOCOL.md`.
* `ui/` — (later) consent UI (Phase 7); the debug console covers Phase 5.

Rules (normative): `HOST_CAPABILITIES.md`, `CONSENT_FLOW.md`.

Build (no Gradle): `android/build-apk.ps1` (requires `ANDROID_HOME`
SDK 35) runs zig -> javac -> d8 -> aapt2 -> zipalign -> apksigner and
writes `android/build/gringots.apk` (gitignored). The native side is
`src/jni.zig` via `zig build android-lib` (`aarch64-linux-android`).
