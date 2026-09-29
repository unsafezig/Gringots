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
IPC port OK
IPC port reject OK
storage OK
storage reject OK
clock OK
crypto OK
gringots SOS OK
bridge TX file OK
datagram TX OK
datagram reject OK
hello service EL0
hello service done
Zinux init exit
```

(`aarch64-bridge` second boot additionally prints `store load OK`,
`bridge RX file OK` and `ACK OK`: persisted service state loads from
file, and the host reply is a real receiver-minted ACK that the guest
verifies end-to-end.)

The current smoke ABI is deliberately temporary and minimal:

| Item | Current rule |
|---|---|
| Guest mode | EL0t for init; EL1h for kernel/exception handling |
| Entry | `aarch64_init_entry` in the embedded ARM64 ELF |
| Trap | `svc #0` from EL0 |
| Dispatch input | saved `ESR_EL1`, saved `ELR_EL1` and saved `x8` in `Aarch64ExceptionFrame` |
| Syscall number | saved `x8` |
| Syscall args | saved `x1`-`x3` (never `x0`, which is return-only) |
| Syscall return | saved `x0` status; wider results via EL0-provided out-pointers |
| IPC operation | `SYS_IPC_SMOKE = 0` |
| Exit operation | `SYS_EXIT = 1` |
| Hello operations | `SYS_START_HELLO = 2`, `SYS_HELLO_DONE = 3` |
| Cap IPC operations | `SYS_IPC_CREATE = 4`, `SYS_IPC_SEND = 5`, `SYS_IPC_RECV = 6` |
| Datagram operations | `SYS_DATAGRAM_SEND = 11`, `SYS_DATAGRAM_RECV = 12` |
| File-shim operations | `SYS_DATAGRAM_SYNC_OUT = 13`, `SYS_DATAGRAM_SYNC_IN = 14` |
| Crypto self-test | `SYS_CRYPTO_SELFTEST = 15` (RFC 8032 + SOS round trip on target) |
| Gringots service ops | `SYS_GRINGOTS_SOS = 16` (mint + queue), `SYS_GRINGOTS_ACK = 17` (verify) |
| Service status/stream | `SYS_GRINGOTS_STATUS = 18` (bits + last nonce), `SYS_GRINGOTS_MINT_UNIQUE = 19` |
| Storage operations | `SYS_STORE_WRITE = 7`, `SYS_STORE_READ = 8` |
| Clock operations | `SYS_CLOCK_MONO = 9`, `SYS_CLOCK_WALL = 10` |
| IPC request | deterministic `IPC1` marker value |
| IPC response | deterministic `IPC2` marker value |
| Cap IPC demo | one `HELLO!!!` word, handle-checked; bad handle/rights/size fail closed |
| Storage demo | one Gringots-owned 4 KiB region, word at offset 0; OOB fails closed |
| Clock demo | monotonic ticks never go backwards; wall reads `NOT_READY` |
| Exit | semihosting `SYS_EXIT`, status 0 |
| Ownership | kernel owns the vector and UART; init owns the request sequence |

This ABI is not yet the final Zinux process ABI. Its exception vector now
preserves a full user context, and the first capability, storage and clock
stubs exist, but there is still no scheduler policy and no `gringotsd`.

### Exception-Frame Follow-Up

The shortcut above has now been replaced by an explicit
`Aarch64ExceptionFrame`. The lower-EL synchronous vector saves and restores
`x0` through `x30`, `ESR_EL1`, `ELR_EL1`, `SPSR_EL1`, `q0`-`q31` and
`FPCR`/`FPSR` in an 800-byte frame (272 + 512 + 16, still 16-aligned).
The Zig `extern` structure has host unit tests that lock its assembly
offsets (`x0=0`, `x8=64`, `x30=240`, `ESR=248`, `ELR=256`, `SPSR=264`,
`q0=272`, `q31=768`, `FPCR=784`, `FPSR=792`).

Restore-ordering rule (found by debugging): control registers (`FPCR`,
`FPSR`, `ELR_EL1`, `SPSR_EL1`) are restored through the `x9` scratch
BEFORE the x-register block. Restoring them after `ldp x0..x30` would
overwrite the guest's genuine `x9` — this produced a silent EL0 hang
(value mismatch, no fault) and is now a documented vector invariant.

Syscall dispatch now receives only that frame: the syscall number is `x8`
and the response is written explicitly to saved `x0`. `ELR_EL1` already
points to the instruction after `svc`, so the smoke handler must not advance
it. The vector restores all other user registers from the frame before `eret`.
The
`aarch64-run` QEMU gate completed with all four Phase 2 output markers after
this change.

### Phase 2 Next Gates

Implement the remaining work in this order:

1. Completed: define and test the `Aarch64ExceptionFrame` layout containing
   x0-x30, ESR_EL1, ELR_EL1 and SPSR_EL1.
2. Completed: preserve and restore all user registers around the EL0 SVC
   path; the handler response is explicitly saved `x0`.
3. Completed for the smoke ABI: syscall dispatch reads only saved `x8`; the
   handler may modify saved `x0`, `ELR_EL1` and `SPSR_EL1` explicitly.
4. Completed: `SYS_START_HELLO` stores init's full EL0 exception frame,
   switches to a separate hello EL0 entry and stack, and `SYS_HELLO_DONE`
   restores init only after the hello service exits.
5. Completed for this two-process handoff: process records contain pid,
   state, EL0 entry, stack and parent, with `READY`, `RUNNING`, `WAITING` and
   `EXITED` states. There is still no scheduler policy.
6. Completed: capability-backed IPC ports (`cap_ipc.zig`). Handles are
   issued by `create`; every use validates handle, rights and size.
   Invalid handles, wrong rights, oversized and empty messages fail closed
   in host tests and in the QEMU EL0 demo (`IPC port OK` /
   `IPC port reject OK`).
7. Completed as stubs: Gringots-owned 4 KiB storage (`storage.zig`) with
   bounds-checked access and a monotonic tick counter plus not-ready wall
   clock (`clock.zig`). Negative paths (OOB, `NOT_READY`) are host-tested
   and QEMU-demonstrated (`storage OK` / `storage reject OK` / `clock OK`).

### Phase 2 Gate Commands

Every Phase 2 change must keep these commands passing:

```text
Zinux/zig build test
Zinux/zig build
Zinux/zig build aarch64
Zinux/zig build aarch64-verify
Zinux/zig build aarch64-run
Zinux/zig build aarch64-bridge
Gringots/zig build test
```

`aarch64-run` must continue to verify all of these markers, not only the
kernel boot marker:

```text
Zinux ARM64 boot OK
zinux>
Zinux init EL0
IPC request/response OK
IPC port OK
IPC port reject OK
storage OK
storage reject OK
clock OK
hello service EL0
hello service done
Zinux init exit
```

### Known Failed Experiment

A first hello-service experiment attempted to change `SP_EL0` and `ELR_EL1`
from the small SVC handler while restoring only a partial register set. Under
QEMU this produced nondeterministic syscall dispatch and was removed. The
full exception-frame ABI now resolves that prerequisite, but service switching
remains blocked until init and hello process contexts are represented by
process records rather than mutations of the current SVC frame.

A second constraint was found while wiring the capability/storage stubs:
EL1 runs with FP/SIMD disabled, so compiler-autovectorized code (struct
zeroing, fixed-count byte-shift loops, short-literal staging) faults with
Undefined Instruction under QEMU. The datagram-device slice resolved the
fault class at its root: the guest now enables FP/SIMD via `CPTR_EL2`
(no trap to EL2) and `CPACR_EL1.FPEN`, set in `boot.S` before `kmain`.
Scalar/volatile discipline stays as hygiene, but the fault class is closed.
Open consequence: the 272-byte exception frame still does not preserve
q-registers, so no service switch may rely on FP state surviving an SVC.
Full FPU context save/restore arrives with the scheduler, before any
preemptive or crypto-heavy service (`gringotsd`) runs in the guest.

No Android or Redmi Note 8 Pro test is allowed to bypass these desktop gates.

Do not add a package ecosystem, shell features or desktop UI unless required
by this milestone.

# Security Boundaries and Threat Modeling

**Objective:** Build security between Gringots and Zinux incrementally so that Gringots operates in a restricted environment, and the interface between the Android host and Zinux guest is clearly defined and testable.
Security is not left until the end of the project, but its implementation must not halt the construction of the first functional ARM64 environment and Gringots system.

---

## Phase S1 – Threat Model and Trust Boundary Definition

**Timeline:** Before locking the Gringots service and Android host interface.

- Define trust boundaries between the Android host, Zinux kernel, Gringots service, and receiving device.
- Document the threat model: What happens if the Android host, guest system, or Gringots service is compromised?
- Define what data and operations the Android host is allowed to provide to Zinux.
- Restrict Zinux and Gringots permissions to the essential.
- Define which security features the virtual machine provides and which it does not guarantee.

**Acceptance Criteria:** Threat model and trust boundaries are documented, and interface security requirements are defined.

---
## Phase S2 – Host-Guest Interface Protection

**Timeline:** As part of the implementation of the Gringots service and host interface.

- Define a restricted messaging protocol between the Android host and Zinux.
- Allow only predefined operations, such as `SEND_FRAME`, `RECEIVE_FRAME`, `GET_STATUS`, and `GET_TIME`.
- Validate message versions, lengths, and content before processing.
- Set timeouts and error handling.
- Prevent the Gringots service from having direct, unrestricted access to Android files, network, and JNI interfaces.
- Keep private keys and their usage within Zinux. Keys are not transmitted via the host interface.

**Acceptance Criteria:** The interface accepts only defined operations and rejects erroneous, oversized, or unknown messages in a controlled manner.

---
## Phase S3 – Zinux Isolation and Service Boundaries

**Timeline:** Alongside ARM64 user space and Gringots service development.

- Implement permission boundaries between processes and services.
- Restrict Gringots service access to system resources.
- Develop a capability-based IPC model and test its permission enforcement.
- Ensure that service crashes do not unnecessarily compromise the rest of the system.
- Test handling of invalid IPC requests and unauthorized resource requests.

**Acceptance Criteria:** The Gringots service operates within its granted permissions, and unauthorized requests are rejected.

---
## Phase S4 – Message Authenticity and Replay Attack Prevention

**Timeline:** As part of Gringots end-to-end testing.

- Maintain verification of Gringots signatures and message authenticity at the receiving end.
- Test the functionality of signature verification, message integrity, and replay attack prevention.
- Ensure that an invalid or outdated message does not lead to an accepted acknowledgment.
- Define how the state required for replay attack prevention persists across restarts.
- Test that the host interface cannot bypass receiver verification.

**Acceptance Criteria:** The receiver accepts only protocol-compliant, verified, and fresh messages.

---
## Phase S5 – Android Integration Security Testing

**Timeline:** Before releasing the Android version.

- Test host interface error conditions, malformed messages, and resource limits.
- Test Zinux guest crashes, restarts, and recovery.
- Ensure that permissions for access to location, audio, and wireless connections are requested in Android with user consent.
- Ensure that security errors lead to a safe failure state and not unauthorized communication.
- Document known limitations, especially that the virtual machine alone does not guarantee protection against a compromised Android host.

**Acceptance Criteria:** Android integration security tests are passed, known limitations are documented, and error conditions are handled in a controlled manner.

---
## Security Progress Principle

Security requirements progress in parallel with core development:

1. First, boundaries and threat models.
2. Then, a restricted and testable interface.
3. Next, service isolation and message verification.
4. Finally, Android integration security testing before release.

This section complements the ARM64 user space, Gringots service, desktop integration, and Android host phases. It does not replace their functional acceptance criteria.


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

### Implementation record (desktop slice)

Two halves of the data flow are proven, the guest-bridge hop is next:

- Guest virtual datagram device (`Zinux/kernel/arch/aarch64/datagram.zig`):
  bounded TX/RX rings (4 x 1034 B), v1 framing validation
  (magic/version/length/CRC32), `SYS_DATAGRAM_SEND/RECV`, EL0 demo with
  `datagram TX OK` / `datagram reject OK` markers in `aarch64-run`.
- Desktop bridge (`zinux/host_bridge/bridge.zig`): the same framing over
  UDP loopback (receiver `127.0.0.1:48481`, bridge `127.0.0.1:48482`).
  `classify` transmits valid `GUEST_SOS_SEND` payloads untouched, answers
  wrong-op/bad-payload datagrams with `HOST_ERROR`, and drops unparsable
  framing silently. A loopback test runs real SOS bytes through real
  sockets: service -> bridge -> receiver -> ACK -> service reports acked.

Guest-bridge hop (file shim, `Zinux/zig build aarch64-bridge`): the guest
spills its TX datagram via semihosting `SYS_OPEN/WRITE` to
`zig-out/guest-tx.dat` (`bridge TX file OK`); the host shim
(`Zinux/tools/datagram_shim.zig`) validates v1 framing and writes a canned
`HOST_FRAME_DELIVER`; the next boot reads it via `SYS_OPEN/FLEN/READ`,
validates framing, injects it into the RX queue and verifies the payload
byte-for-byte (`bridge RX file OK`). A missing reply file is the normal
first-boot case (`NOT_FOUND`, silent). What still carries demo bytes
instead of crypto: the shim reply is canned, because the guest cannot yet
mint or verify Gringots frames.

In-guest crypto is proven: `Zinux/kernel/arch/aarch64/gringots/`
vendors `types`/`frame`/`msg`/`ed25519` from Gringots ef2c743 (flat
imports, provenance headers) and `selftest.zig` runs the RFC 8032 vector
plus an SOS mint/verify round trip on target (`crypto OK` in
`aarch64-run`, same file host-tested). The 800-byte frame now preserves
q-registers across SVC, which the crypto path requires.

Remaining before the milestone: the shim loop carries a real SOS out and
a real ACK back — guest mints SOS via the vendored subset, desktop
receiver verifies and replies, guest verifies the ACK and reports it.
`gringotsd` as a proper service (keys/replay in Gringots-owned storage,
IPC operations) follows once that loop is green.

### Milestone — achieved (file-shim path)

```text
Zinux creates CIVILIAN_SOS        # gringots SOS OK (guest-minted, TX file)
Desktop receiver verifies it      # file-bridge: SOS verified (real crypto)
ACK returns to Zinux              # host-rx.dat, HOST_FRAME_DELIVER
Zinux reports valid acknowledgement  # ACK OK (guest-verified signature+ref)
```

Demonstrated by `Zinux/zig build aarch64-bridge`: boot 1 spills the SOS,
the host bridge verifies it and mints a real ACK, boot 2 verifies the
ACK's signature, type, `ref` and replay-freshness on target. Transport is
still files, not radio — Wi-Fi/BLE/audio arrive in Phases 6-9 behind the
same framing both ends already speak.

Layering evidence from this slice: the ACK handler first fed the whole
host datagram to Gringots verification (`ack: bad frame`). The guest must
strip transport framing (`op` + payload range) before protocol
verification — a service built directly on RX bytes would mis-verify.
Staged reject markers (`ack: no rx` / `no sos` / `bad frame` / `not ack` /
`no ref` / `ref mismatch` / `replay` / `not deliver`) stay for `gringotsd`
diagnostics.

### Service v1 (gringotsd precursor)

`Zinux/kernel/arch/aarch64/gringots/service.zig` owns identity seed,
boot counter, nonce stream (splitmix64), replay ring, ack flag and last
nonce in Gringots-owned storage (exact layout in `GRINGOTS_SERVICE.md`
Section 2), behind an injectable backend: semihosting files on target,
RAM buffers in host tests. Every mutation persists; `init` loads or
fresh-starts with a `GRG1` magic check. Proven in gates: boot counter
bumps per boot, stream nonces differ within and across boots, replay +
acked + last nonce survive a simulated restart (host test) and a real one
(`store load OK` on bridge boot 2). The bridge demo mint stays a fixed
vector (deterministic across the two-boot file protocol); the stream is
the production path under test. Remaining service surface: `VERIFY_FRAME`,
`DESCRIBE_FRAME`, `SEND_FRAME` as IPC ops, identity rotation once the
host provides wall time.

### Gate-integrity finding (test discovery)

`zig build test` silently skipped every ARM64 kernel test: Zig does not
run test blocks across a NAMED-module import boundary, so the
`tests/host/*_test.zig` wrappers compiled but never executed. This hid
real latent bugs (single-pointer signatures in `cap_ipc`/`storage`,
an alignment panic in `writeWord`). Fixed with
`kernel/arch/aarch64/host_tests.zig`: one test binary rooted next to the
files, relative imports, 19 tests actually running. Rule for new code:
host-run tests must live behind a relative import from a test root, or
they do not run. (Gringots was unaffected: each of its test binaries is
rooted at the tested file.)

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
