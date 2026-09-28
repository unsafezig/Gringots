# ARM64 Zinux Guest — Minimal Milestone (Phase 1)

Status: **Defined, not yet implemented**. This doc is the build gate for
the ARM64 port; the x86_64/Limine path remains the supported target
until the gate below passes.

## Why ARM64

Android phones are ARM64. The Gringots first-release path needs a Zinux
ARM64 guest (emulation is acceptable at first; KVM cannot be assumed).

## Minimal guest devices (first boot)

```text
virtual RAM, timer, interrupt controller, serial console,
block device, datagram device, clock
```

Only these seven. No GPU, no USB, no wide device tree.

## Milestone

```text
Zinux ARM64 boot OK
zinux>
```

With a deterministic boot marker on the serial console so CI can grep it.

## Desktop reference test (gate)

Desktop QEMU `virt` machine, no KVM required:

```text
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512 \
  -kernel zig-out/bin/zinux-kernel-aarch64.elf \
  -nographic -serial mon:stdio
# expect: "Zinux ARM64 boot OK"
```

Until the kernel port lands, the standing compile gate is:

```text
zig build        # must pass, incl. host_protocol_aarch64 static lib
zig build test   # must pass on host
```

`host_protocol_aarch64` (see `../../build.zig`) proves the entire
guest-host boundary + `gringotsd` contract compiles for
`aarch64-freestanding` today. Kernel/arch port (`kernel/arch/aarch64/`,
PSCI boot, PL011 serial, `virt` timer/GIC) is the remaining work and
MUST NOT break the x86_64/Limine build.

## Tests (on completion)

* ARM64 kernel builds reproducibly.
* Guest boots in the desktop reference command above.
* Init starts; serial contains the deterministic boot marker.
* Invalid guest device requests are rejected.
* `zig build` (x86_64 ISO + QEMU smoke) still passes unmodified.
