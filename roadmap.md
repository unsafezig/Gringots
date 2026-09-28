# Gringots + Zinux Android Roadmap

## Purpose

The first real use of Zinux is Gringots.

The first Väinö Android application must therefore demonstrate this complete
path:

```text
Android APK
    ↓
Zinux ARM64 guest
    ↓
Zinux init
    ↓
Gringots service inside Zinux
    ↓
Zinux host IPC
    ↓
Android transport bridge
    ↓
Wi-Fi / Bluetooth / audio
    ↓
Gringots receiver
```

The goal is not to build a general-purpose Android Linux replacement first.
The goal is to prove that a real Zinux application can run inside an Android
host and use physical phone capabilities through explicit, restricted
interfaces.

## Current Constraints

The existing projects impose these constraints:

- Zinux currently focuses on x86_64, Limine and QEMU.
- Android requires an ARM64 guest target.
- A normal Android application cannot assume that KVM acceleration is
  available.
- Gringots already contains the protocol core, cryptography, replay handling,
  agent core, audio codec and a C ABI.
- Android owns physical radios, audio, location, storage and application
  lifecycle.
- Zinux must not receive unrestricted JNI, socket, Bluetooth or location
  access.
- Gringots protocol behavior remains defined by `PROTOCOL.md`, `SECURITY.md`
  and `THREAT_MODEL.md`.

The first implementation may use ARM64 emulation. Performance optimization is
not a prerequisite for proving the architecture.

## Hardware Reference

The first physical-device validation target is a **Xiaomi Redmi Note 8 Pro**.
The device is an ARM64 Android reference host, not a replacement for the
desktop QEMU gate. Every hardware milestone must keep a deterministic desktop
test and must document the Android build, deployment and transport conditions
used on the phone.

The Redmi validation sequence is deliberately late in the roadmap:

```text
desktop QEMU guest gate
    -> desktop host-bridge SOS/ACK gate
    -> APK/debug-host gate
    -> Redmi Note 8 Pro smoke test
    -> Redmi Wi-Fi transport test
```

Native boot on the phone is not required. The intended first phone path is an
Android APK hosting an emulated ARM64 guest with explicit serial, storage and
datagram bridges.

## Architectural Rule

Keep these layers separate:

```text
Gringots protocol
        ↓
Gringots Zinux service
        ↓
Zinux capability and IPC boundary
        ↓
Virtual device / host bridge
        ↓
Android API
        ↓
Physical phone hardware
```

The Android host owns physical resources. Zinux owns the application model.
Gringots owns protocol bytes and cryptographic verification. The Android UI
owns user consent. No layer may bypass another layer's authority.

## First Vertical Milestone

Do not begin with BLE, location, audio or a graphical desktop. The first
vertical milestone is:

```text
Android APK
    ↓
Start Zinux ARM64 VM
    ↓
Start Zinux init
    ↓
Start `gringotsd`
    ↓
Create signed `CIVILIAN_SOS`
    ↓
Send through a virtual datagram bridge
    ↓
Receiver verifies the frame
    ↓
Valid `ACK` returns to Zinux
    ↓
Zinux reports acknowledgement
```

The receiver may initially be a desktop Gringots process or a deterministic
test fixture. This milestone must work before platform-specific transport
work expands.

## Phase 0: Contracts and Repository Structure

### Objectives

- Define the Zinux guest-host boundary.
- Define the first virtual devices.
- Define the Gringots service API inside Zinux.
- Define which operations require Android consent.
- Keep the protocol transport-independent.

### Proposed structure

```text
Gringots/
├── src/
│   ├── protocol/          # wire format and message rules
│   ├── crypto/            # signing and verification
│   ├── identity/          # ephemeral identities
│   ├── replay/            # replay protection
│   ├── location/          # consent-bound sessions
│   ├── agent/             # platform-independent service core
│   ├── transports/        # transport codecs and bindings
│   └── platform/          # platform adapters
├── zinux/
│   ├── gringotsd/         # Zinux userland service
│   ├── host_protocol/     # guest-host message definitions
│   └── test_receiver/     # deterministic receiver fixture
├── android/
│   ├── host/              # VM and host bridges
│   ├── transport/         # Wi-Fi, BLE and audio adapters
│   └── ui/                # consent and status UI
└── tests/
    ├── protocol/
    ├── host_bridge/
    ├── zinux_guest/
    └── android/
```

### Required design documents

- `zinux/HOST_PROTOCOL.md`
- `zinux/GRINGOTS_SERVICE.md`
- `android/HOST_CAPABILITIES.md`
- `android/CONSENT_FLOW.md`

Every message crossing the guest-host boundary must have a documented
encoding, direction, ownership rule and failure behavior.

## Phase 1: ARM64 Zinux Guest

### Objectives

- Build a minimal ARM64 Zinux target.
- Boot it in a desktop reference environment.
- Provide a serial console and deterministic boot output.

### Required guest devices

- virtual RAM
- virtual timer
- virtual interrupt controller
- virtual serial console
- virtual block device
- virtual datagram device
- virtual clock

### Milestone

```text
Zinux ARM64 boot OK
zinux>
```

### Tests

- ARM64 kernel builds reproducibly.
- Guest boots in the desktop reference environment.
- Serial output contains a deterministic boot marker.
- Semihosting smoke exit returns successfully.

The existing x86_64/Limine path must not be silently broken. The ARM64 guest
path is an additional target, not an implicit replacement.

## Phase 2: Minimal Zinux Application Runtime

### Objectives

- Start a userland service from `init`.
- Provide process lifecycle handling.
- Provide IPC ports and capability handles.
- Provide persistent application storage.
- Provide a monotonic and wall-clock interface.

The first ARM64 implementation must not claim this phase is complete from a
kernel boot marker alone. The guest must execute an actual EL0 `init` entry,
start a hello service, and complete one bounded IPC request/response exchange.

### Milestone

```text
Zinux init
    ↓
hello service
    ↓
IPC request/response OK
```

The first implementation slice now proves the lower-level prerequisite:

```text
EL1 kernel
    ↓ eret
EL0 init
    ↓ svc
EL1 syscall vector
    ↓ response
EL0 init exit
```

This is an IPC smoke path, not yet the complete hello-service/process-runtime
milestone. Process lifecycle, capability handles and a separately started
hello service remain required before Phase 2 is complete.

### Phase 2 Implementation Record

The current desktop reference implementation proves the following bounded
path in `Zinux`:

```text
QEMU virt / EL1 kernel
    -> VBAR_EL1 exception vector
    -> eret to EL0 init entry
    -> SVC IPC smoke request
    -> EL1 handler validates EC=0x15 (AArch64 SVC from EL0)
    -> deterministic IPC response
    -> SVC exit
    -> semihosting QEMU exit
```

Current deterministic serial output is:

```text
Zinux ARM64 boot OK
zinux>
Zinux init EL0
IPC request/response OK
Zinux init exit
```

The current smoke ABI is deliberately temporary and minimal:

| Item | Current rule |
|---|---|
| Guest mode | EL0t for init; EL1h for kernel/exception handling |
| Entry | `aarch64_init_entry` in the embedded ARM64 ELF |
| Trap | `svc #0` from EL0 |
| Dispatch input | ESR_EL1, ELR_EL1 and the current syscall register |
| IPC operation | `SYS_IPC_SMOKE = 0` |
| Exit operation | `SYS_EXIT = 1` |
| IPC request | deterministic `IPC1` marker value |
| IPC response | deterministic `IPC2` marker value |
| Exit | semihosting `SYS_EXIT`, status 0 |
| Ownership | kernel owns the vector and UART; init owns the request sequence |

This ABI is not yet the final Zinux process ABI. In particular, the current
vector saves only the registers needed by the smoke path. A service switch
must not be built on that shortcut.

### Phase 2 Next Gates

Implement the remaining work in this order:

1. Define an explicit `Aarch64ExceptionFrame` layout containing x0-x30,
   ESR_EL1, ELR_EL1 and SPSR_EL1. The assembly offsets and the Zig `extern`
   struct must be tested against each other.
2. Preserve and restore all user registers around the EL0 SVC path. The
   handler return value must be explicitly defined as x0; all other registers
   must return from the saved frame.
3. Define syscall dispatch independently from compiler scratch-register
   behavior. The syscall number must have one documented location and one
   documented clobber rule.
4. Add `START_HELLO` and `HELLO_DONE` operations. Init must save its ELR/SP
   state, enter a separate EL0 hello-service entry and return to init only
   after the service acknowledges completion.
5. Add a minimal process record containing pid, state, EL0 entry, stack and
   parent. The first state machine only needs `READY`, `RUNNING`, `WAITING`
   and `EXITED`; no scheduler policy is required yet.
6. Add a capability-backed IPC port rather than passing a raw kernel-global
   port identifier. Invalid handles, wrong rights and oversized messages must
   fail closed.
7. Add persistent-storage and monotonic-clock interfaces as stubs with
   deterministic negative tests before `gringotsd` is attached.

### Phase 2 Gate Commands

Every Phase 2 change must keep these commands passing:

```text
Zinux/zig build test
Zinux/zig build
Zinux/zig build aarch64
Zinux/zig build aarch64-verify
Zinux/zig build aarch64-run
Gringots/zig build test
```

`aarch64-run` must continue to verify all of these markers, not only the
kernel boot marker:

```text
Zinux ARM64 boot OK
zinux>
Zinux init EL0
IPC request/response OK
Zinux init exit
```

### Known Failed Experiment

A first hello-service experiment attempted to change `SP_EL0` and `ELR_EL1`
from the small SVC handler while restoring only a partial register set. Under
QEMU this produced nondeterministic syscall dispatch and was removed. The
experiment is retained as design evidence: service switching is blocked until
the full exception-frame ABI and register restoration tests exist.

No Android or Redmi Note 8 Pro test is allowed to bypass these desktop gates.

Do not add a package ecosystem, shell features or desktop UI unless required
by this milestone.

## Phase 3: Gringots as the First Zinux Service

### Objectives

- Build `gringotsd` for the Zinux userland target.
- Reuse the protocol and crypto implementation.
- Add a Zinux adapter around the existing platform-independent agent core.
- Keep keys and replay state in Gringots-owned storage.
- Expose operations through Zinux IPC.

### Initial service operations

```text
CREATE_SOS
VERIFY_FRAME
DESCRIBE_FRAME
SEND_FRAME
RECEIVE_FRAME
GET_STATUS
```

### Initial capabilities

```text
CAP_GRINGOTS_SEND
CAP_GRINGOTS_RECEIVE
CAP_CLOCK
CAP_PERSISTENT_STORAGE(gringots)
CAP_NETWORK_DATAGRAM
```

Location, microphone, speaker and Bluetooth capabilities are explicitly not
granted in this phase.

### Milestone

```text
zinux> gringots sos
Gringots SOS created
Frame valid
```

## Phase 4: Desktop Host Bridge

### Objectives

- Implement the same host protocol outside Android.
- Provide a deterministic virtual datagram transport.
- Connect Zinux to a desktop Gringots receiver.
- Test the complete guest-to-receiver path quickly.

### Data flow

```text
gringotsd
    ↓ IPC
Zinux virtual datagram device
    ↓ host protocol
Desktop host bridge
    ↓ UDP loopback
Gringots receiver
```

### Required negative tests

- invalid magic
- unsupported protocol version
- invalid frame length
- invalid CRC
- malformed TLV
- invalid signature
- expired frame
- replayed nonce
- invalid ACK reference
- unknown response treated as no acknowledgement

### Milestone

```text
Zinux creates CIVILIAN_SOS
Desktop receiver verifies it
ACK returns to Zinux
Zinux reports valid acknowledgement
```

This is the first complete Zinux + Gringots demonstration and must be
implemented before Android radio integration.

## Phase 5: Android APK and VM Host

### Objectives

- Create the Android application.
- Bundle the Zinux ARM64 guest image.
- Start and stop the guest VM or emulator.
- Allocate guest memory.
- Connect virtual serial, storage and datagram devices.
- Persist the guest filesystem in Android app storage.

### First Android milestone

```text
Android phone
    ↓
Väinö APK
    ↓
Zinux ARM64 guest
    ↓
gringotsd
    ↓
Gringots service ready
```

The first Android UI may be a debug console with start, stop and status
controls. A general desktop interface is out of scope.

## Phase 6: Android Wi-Fi Transport

Wi-Fi/UDP is the first physical transport because it is easier to observe and
test than BLE background behavior.

### Data flow

```text
gringotsd
    ↓
Zinux datagram IPC
    ↓
Android host bridge
    ↓
UDP broadcast / Wi-Fi
```

The guest must never receive unrestricted Android sockets. The bridge should
accept only the operations defined by the host protocol.

### Milestone

The Android phone sends a signed `CIVILIAN_SOS` through Wi-Fi and receives a
valid `ACK` from an independent Gringots receiver.

## Phase 7: Android Consent and Location

### Objectives

- Implement location requests through Android UI.
- Keep the location provider on the Android side.
- Pass only approved, bounded location data to Zinux.
- Enforce expiry and revocation.

### Flow

```text
Gringots receiver
    ↓
LOCATION_REQUEST
    ↓
Zinux gringotsd
    ↓
Android consent UI
    ↓
LOCATION_APPROVED or LOCATION_DECLINED
    ↓
Zinux creates LOCATION_DISCLOSED
```

Rules:

- `CIVILIAN_SOS` never contains location.
- No location is disclosed without explicit user consent.
- Consent has an expiration time.
- The user can revoke the session.
- Silence is never treated as acknowledgement.
- Zinux cannot grant location access to itself.

## Phase 8: Bluetooth LE

### Objectives

- Connect the existing BLE chunk codec to Android BLE APIs.
- Keep fragmentation and reassembly in the transport layer.
- Enforce advertisement rate and burst limits.
- Test scan, send, receive, timeout and replay behavior.

### Data flow

```text
gringotsd
    ↓
Zinux BLE transport request
    ↓
Android BLE bridge
    ↓
BLE advertisement / scan
```

Android background execution and permission limitations must be documented as
part of the implementation, not hidden behind an always-running loop.

## Phase 9: Audible Fallback

### Objectives

- Connect the existing FSK, Reed-Solomon and WAV codec to Android audio APIs.
- Add controlled speaker output.
- Add microphone capture only through explicit Android service behavior.
- Treat unknown audio as no acknowledgement.

### Data flow

```text
gringotsd
    ↓
Zinux audio request
    ↓
Android AudioTrack / AudioRecord
    ↓
speaker / microphone
```

Continuous microphone monitoring is not part of the first implementation.

## Phase 10: Reliability, Battery and Offline Operation

### Objectives

- Integrate the existing duty scheduler.
- Add Android foreground-service behavior where required.
- Respect battery level and quiet hours.
- Persist only necessary state.
- Recover safely after process termination.
- Support operation without internet access.

### Required behavior

- Boot works offline.
- Installed Gringots service works offline.
- Local keys and replay state survive normal restarts.
- Expired sessions are removed.
- A failed transport does not become an infinite beacon.
- No transport failure is reported as a successful acknowledgement.

## Phase 11: Gringots Package in Zinux

Once the service works as an integrated application, package it as the first
normal Zinux package:

```text
gringots.vpkg
├── manifest
├── executable
├── protocol metadata
├── capability request
└── signature
```

The goal is to replace special-case startup with the normal Zinux application
model:

```text
zinux> install gringots
Verifying signature...
Granting capabilities...
Starting gringotsd...
Gringots installed.
```

## Final First-Release Definition

The first release is successful when all of the following are demonstrated:

- Android APK installs on the reference phone.
- APK starts an ARM64 Zinux guest.
- Zinux starts `gringotsd` as a userland service.
- Gringots creates a valid signed `CIVILIAN_SOS`.
- Android Wi-Fi bridge transmits the frame.
- Independent receiver verifies the frame.
- Valid `ACK` returns to Zinux.
- Invalid, expired and replayed frames are rejected.
- Location is never disclosed without user consent.
- The system works without a centralized account.
- The complete test can be repeated from a clean build.

## Explicit Non-Goals for the First Release

Do not build these before the first vertical milestone works:

- direct native Zinux boot on a phone
- a complete Android replacement
- a graphical desktop environment
- a general package store
- POSIX compatibility
- LoRa hardware support
- continuous GPS beaconing
- unrestricted JNI access from Zinux
- a large collection of virtual devices
- AI-generated Android or Zinux security policy

## Security and Research Rules

- The Android host is a security boundary.
- The Zinux kernel is the capability authority.
- Gringots protocol validation is deterministic and independent of AI.
- AI may propose a host adapter or driver plan, but it cannot grant itself
  capabilities.
- Generated code must pass compilation, static validation, capability
  validation, sandboxing and tests.
- Human-written work, generated work and manually corrected generated work
  must be recorded separately.
- Every phase must have a reproducible test and a clear success marker.
- A failed experiment is valid evidence and must not be hidden.

## Recommended First Tasks for the Implementing Agent

1. Inspect both repositories and confirm the current build commands.
2. Add `zinux/HOST_PROTOCOL.md` with a minimal datagram request/response ABI.
3. Define the smallest ARM64 guest milestone and its desktop test command.
4. Create a platform-neutral Gringots service interface around the existing
   agent core.
5. Implement `gringotsd` against a fake Zinux host bridge.
6. Make the desktop end-to-end SOS/ACK test pass.
7. Only then begin the Android VM host.

The implementation must not claim the Android phase is complete merely because
the native Gringots library builds. Completion requires the complete path:

```text
Android → Zinux → Gringots → host bridge → receiver → ACK → Zinux
```
