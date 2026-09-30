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
gringots send OK
bridge TX file OK
datagram TX OK
datagram reject OK
identity rotated
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
| --- | --- |
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
| Service ops | `SYS_GRINGOTS_VERIFY = 20` (local verdict), `SYS_GRINGOTS_DESCRIBE = 21` (text), `SYS_GRINGOTS_SEND = 22` (shape-check + queue) |
| Rotation | `SYS_GRINGOTS_ROTATE = 23` (on-demand epoch); timed via `onWallTime` |
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
the production path under test. Implemented since: `VERIFY_FRAME` (staged verdict: valid/malformed/time/
bad-sig/semantics), `DESCRIBE_FRAME` (structure-only text, unverified)
and `SEND_FRAME` (shape-check + queue, same rule as the host service) as
SVC 20/21/22, demoed in EL0 against the guest's own SOS bytes
(valid + corrupted + empty cases).

### Rotation and wall time

Wall time drives identity rotation: desktop QEMU provides it through
semihosting `SYS_TIME` (documented shim; `SYS_CLOCK_WALL` now succeeds
and EL0 asserts a sane date), Android will deliver `HOST_TIME_SYNC`
(spec'd in `HOST_PROTOCOL.md` Section 7, reserved op `0x07`).
`service.onWallTime` stamps fresh regions and rotates past
`IDENTITY_LIFETIME_S` or on backwards jumps (new stream-derived seed,
acked + SOS state cleared, replay ring kept, all persisted);
`SYS_GRINGOTS_ROTATE` (SVC 23) rotates on demand with an `identity
rotated` marker, and EL0 proves SOS state clears. Expiry, backwards
jumps and restart-with-new-seed are host-tested.

Replay evidence: re-running the bridge gate WITHOUT wiping the store
file makes boot 2 report `ack: replay` — the persisted ring correctly
rejects the byte-identical second ACK. Gates wipe the store first so
every run is hermetic.

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

## Phase 4b: GRINGOTD relay daemon (desktop)

> Numbering note: this is a Phase 4 sub-slice (desktop relay), not a
> second Phase 5. The Android APK host below stays Phase 5.

### Purpose

GRINGOTD bridges the host bridge's datagram layer to one or more external
Gringots receivers. It sits between the local `gringotsd` clients (which
talk Zinux guest datagrams via the bridge) and the receiver network,
translating a single bridge listener into outbound sender sockets.

### Data flow

```
Bridge listener on localhost port
    ↓ UDP bind
GRINGOTD relay loop
    ├─→ classify()  -- validation gate
    ├─→ transmit (send_frame) → sender socket port 48481
    ├─→ respond   (ACK relay) → forward to client ports
    └─→ drop      (malformed)
```

### Implementation record

- `zinux/gringotd/gringotd.zig` created (uncommitted slice):
  - `GringotdRelay` struct owning a bridge listener socket and an external
    sender socket.
  - `init()` binds both sockets; `close()` tears them down.
  - `classify(raw, out_buf)` performs validation and produces a
    validated datagram copy when allowed; mirrors `bridge.classify`
    so the daemon layer decides forward / respond / drop.
  - `relayOne(payload)` dispatches the classification to `tx()`, a
    wrapped outbound frame via `forwardToReceiver()`, or silently drops
    (malformed).
  - `relayInbound(raw, out_buf) !bool` accepts decoded inbound frames from
    the receiver network and wraps them for delivery back to connected
    clients on the bridge listener port.

- `build.zig` updated:
  - Registers `gringotd` module pointing at
    `zinux/gringotd/gringotd.zig`.
  - Adds test entry-point file under `tests/host_bridge/`
    (`e2e_sos_ack.zig`) so the relay can be tested alongside Phase-4
    bridge tests.

- Tests:
  - New `classify: forward SOS payload via relayOne` host test
    validates framing, CRC and version checks; malformed datagrams are
    rejected before they reach `relayLoop`.
  - All existing e2e and protocol tests continue to pass.

### Known gaps in the uncommitted slice (must be closed before green)

- `relayOne` uses `try` on socket sends but is not fallible (`bool`
  return): make it `!bool` or map send errors to drop/error counters.
  A send failure must never unwind the relay loop.
- `relayInbound` copies `m.payload` into `out_buf` today; define whether
  the contract is "re-emit the full `HOST_FRAME_DELIVER` datagram" or
  "payload only", and add a host test that round-trips a real ACK.
- `tests/host_bridge/e2e_sos_ack.zig` carries a stray
  `const gringotd_mod = @import("bridge");` (wrong module, unused):
  wire the e2e to the real `gringotd` module or delete the import.
- Port table in code is receiver `127.0.0.1:48481`, bridge
  `127.0.0.1:48482` (`zinux/host_bridge/bridge.zig`
  `RECEIVER_PORT`/`BRIDGE_PORT`). The `48490` value drafted below was
  never in code — canonicalize on `48481`/`48482` in `HOST_PROTOCOL.md`.
- Typo sweep: `GringodRelay` -> `GringotdRelay`, `GRINGODT`/`GRINGTD` ->
  `GRINGOTD`.

### Next gates for GRINGOTD

- [ ] Close the known gaps above (`relayOne` fallibility, `relayInbound`
      contract + test, stray e2e import, `GringotdRelay` rename).
- [ ] Wire up multiple sender sockets so each receiver subnet can be reached
      independently (initially loopback: one socket to `127.0.0.1:48481`).
- [ ] Test relay inbound path end-to-end — ACK frames minted by the
      standalone receiver must traverse GRINGOTD back to the client bridge
      listener.
- [ ] Add watchdog / liveness markers so `gringotsd` or other clients can
      detect when the bridge socket is healthy.
- [ ] Document port assignments (bridge: 48482, receiver: 48481) in
      `HOST_PROTOCOL.md` as the canonical Zinux datagram ports.

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

### Implementation record (uncommitted slice: native lib + debug APK)

The native embedding path is proven; the VM host is not yet started:

- `src/jni.zig` (new, uncommitted): `RegisterNatives`-bound
  `GringotsBridge` natives (`version()I`, `makeSos([BJJ[B)[B`,
  `verifyFrame([BJ)I`) plus `JNI_OnLoad` reporting 1.6. Buffer-based
  and fixed-cap (600 B SOS / 1024 B verify); failures return null / 1,
  never throw. Not host-testable (no JVM on host); the underlying calls
  are covered by `ffi.zig` host tests.
- `src/ffi.zig` (modified, uncommitted): direct imports of
  `protocol/frame.zig`, `protocol/msg.zig`, `crypto/ed25519.zig`
  instead of via `root.zig`, so the JNI `.so` does not pull
  `transports/std.Io` (its thread-pool init references `getauxval`,
  which Bionic lacks). `export fn` -> `pub export fn`.
- `build.zig` (modified, uncommitted): `android-lib` step
  cross-compiles `libgringots.so` for `aarch64-linux-android`.
- `android/app/` (new, uncommitted): `AndroidManifest.xml`
  (`ee.vaino.gringots`, min 26 / target 35, INTERNET + Wi-Fi-multicast +
  foreground-service permissions, no location/BLE/audio), Java
  `GringotsBridge.java` binding, `MainActivity.java` debug console.
  Start runs a deterministic native self-test (mint SOS with fixed
  seed/nonce at `t0`, `verify(valid)==0`, `verify(expired)==1` ->
  `Gringots service ready`); stop returns to idle; `am start --ez
  selftest true` runs headless for device automation.
- `android/build-apk.ps1` + `android/package_apk.py` (new,
  uncommitted): no-Gradle pipeline (zig -> javac 17 -> d8 -> aapt2 ->
  python zipfile -> zipalign -> apksigner). `.so` entries are STORED
  (mmap-able), `classes.dex` is deflated. Outputs to `android/build/`
  (gitignored via `.gitignore`). Gate checks badging
  (`ee.vaino.gringots`, `native-code: 'arm64-v8a'`) and cert verify.
- `android/HOST_CAPABILITIES.md`, `android/CONSENT_FLOW.md` (committed
  drafts, normative for Phases 5-7). `android/README.md` still says
  "No APK sources yet" — stale after this slice, update on commit.

### Phase 5 gate commands

```text
Gringots/zig build test
Gringots/zig build android-lib
Gringots/android/build-apk.ps1   # requires ANDROID_HOME SDK 35
```

### Phase 5 next gates (VM host slice, not started)

- [ ] Update `android/README.md` (APK sources now exist).
- [ ] Bundle the Zinux ARM64 guest image in the APK; start/stop the
      guest VM or emulator from the debug console; allocate guest
      memory; connect virtual serial, storage and datagram devices;
      persist the guest filesystem in app-private storage.
- [ ] Report `Gringots service ready` from the real guest path
      (`init` -> `gringotsd`), replacing the current JNI self-test text
      when the VM slice lands (keep the self-test as a fallback gate).
- [ ] Install the built APK on the Redmi Note 8 Pro reference host and
      run the headless self-test (`adb shell am start --ez selftest`);
      record build, deployment and logcat conditions per the hardware
      reference rule. No desktop gate may be bypassed.

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

### Next gates

- [ ] Entry: Phase 5 VM-host slice green (guest boots, `gringotsd`
      reports ready in the APK console).
- [ ] Android host bridge: `GUEST_SOS_SEND` -> UDP broadcast on the
      Wi-Fi subnet (`HOST_CAPABILITIES.md` scoped `CAP_NETWORK_DATAGRAM`);
      `HOST_FRAME_DELIVER` path for returning ACKs. Guest still sees only
      host-protocol ops, never raw sockets.
- [ ] Desktop parity first: same SOS/ACK exchange over the desktop UDP
      loopback bridge (Phase 4/4b) must stay green while the Android
      transport adapter is added behind the same framing.
- [ ] Redmi Wi-Fi transport test per the hardware reference sequence
      (APK/debug-host gate -> Redmi smoke -> Redmi Wi-Fi); document
      SSID/subnet/firewall conditions and the independent receiver used.

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

### Next gates

- [ ] Entry: Phase 6 Wi-Fi SOS/ACK green on the Redmi reference host.
- [ ] Implement `HOST_CONSENT_REQUEST` / `HOST_CONSENT_DECISION` against
      `android/CONSENT_FLOW.md` (10-min TTL, bounded fix only, stale fix
      -> honest `DECLINE`, no `SESSION_ID` reuse, `--auto-approve`
      test-only and never shipped in the APK).
- [ ] Negative tests: deny -> `DECLINE`, expired consent -> no send,
      revoked session -> `DECLINE` + no further updates, SOS carrying
      `LAT`/`LON` rejected by the receiver.
- [ ] Desktop fixture first: consent decision injected via a fake host
      bridge so `gringotsd` queuing/expiry logic is tested without a phone.

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

### Next gates

- [ ] Entry: Phase 6 Wi-Fi path green; consent flow (Phase 7) specified
      against `CONSENT_FLOW.md`.
- [ ] Wire the existing BLE chunk codec to Android BLE APIs behind a
      compile-time flag (off until this phase); keep fragmentation and
      reassembly in the transport layer.
- [ ] Enforce advertisement rate and burst limits; test scan, send,
      receive, timeout and replay behavior against a desktop BLE fixture
      before phone testing.
- [ ] Document measured background/permission limits on the Redmi
      reference host; a failed transport is reported as failure, never
      as acknowledgement.

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

### Next gates

- [ ] Entry: Phase 8 BLE slice green or explicitly deferred with a
      recorded reason; Wi-Fi SOS/ACK remains the release transport.
- [ ] Wire the existing FSK, Reed-Solomon and WAV codec to Android
      `AudioTrack` / `AudioRecord` behind a compile-time flag; speaker
      output controlled, microphone capture only through explicit
      service behavior.
- [ ] Treat unknown audio as no acknowledgement; test with recorded
      fixtures before any phone microphone use.

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

### Next gates

- [ ] Entry: at least the Wi-Fi transport (Phase 6) green on the Redmi
      host.
- [ ] Integrate the existing duty scheduler with Android
      foreground-service behavior where required; respect battery level
      and quiet hours.
- [ ] Kill/restart test: process termination recovers keys and replay
      state from app-private storage (same rule as the guest
      `GRG1`-magic store load in Phase 4); expired sessions are swept.
- [ ] Offline gate: clean install -> boot -> SOS/ACK against a local
      receiver with no internet and no accounts.

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

### Next gates

- [ ] Entry: `gringotsd` running as a userland service through the APK
      (Phase 5 VM slice) with Wi-Fi SOS/ACK green (Phase 6).
- [ ] Define the `gringots.vpkg` manifest + capability request
      (`CAP_GRINGOTS_SEND/RECEIVE`, `CAP_CLOCK`,
      `CAP_PERSISTENT_STORAGE(gringots)`, `CAP_NETWORK_DATAGRAM` only)
      against `android/HOST_CAPABILITIES.md`; signature verification
      before any capability grant.
- [ ] Replace special-case startup with install/start; the debug console
      self-test stays as a post-install health check.

## Final First-Release Definition

The first release is successful when all of the following are demonstrated
(gate in parentheses):

- Android APK installs on the reference phone. (Phase 5 + Redmi smoke)
- APK starts an ARM64 Zinux guest. (Phase 5 VM slice)
- Zinux starts `gringotsd` as a userland service. (Phase 5 VM slice)
- Gringots creates a valid signed `CIVILIAN_SOS`. (Phase 4 file-shim,
  then Phase 6 live)
- Android Wi-Fi bridge transmits the frame. (Phase 6)
- Independent receiver verifies the frame. (Phase 4 negative suite +
  Phase 6 live)
- Valid `ACK` returns to Zinux. (Phase 4 file-shim, then Phase 6 live)
- Invalid, expired and replayed frames are rejected. (Phase 4 negative
  suite, re-run against the phone path)
- Location is never disclosed without user consent. (Phase 7)
- The system works without a centralized account. (Phase 10 offline gate)
- The complete test can be repeated from a clean build. (all desktop
  gates + `build-apk.ps1` from clean `android/build/`)

Close-out order towards the release:

```text
4b GRINGOTD gaps closed -> 5 VM host + Redmi smoke -> 6 Redmi Wi-Fi SOS/ACK
    -> 7 consent -> 10 reliability/offline -> 11 vpkg
    -> S5 Android integration security testing -> release
```

Phases 8 (BLE) and 9 (audio) are fallback transports: each may land
after the release transport (Wi-Fi) is green, or be explicitly deferred
with a recorded reason. Neither may block or bypass the Wi-Fi
SOS/ACK gate.

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
