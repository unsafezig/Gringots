# ARM64 Zinux Guest — Minimal Milestone (Phase 1)

Status: **Phase 1 complete**. The ARM64 guest boots in the desktop QEMU
reference environment; the x86_64/Limine path remains an additional target.

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
  -kernel zig-out/bin/zinux-aarch64 \
  -display none -monitor none -serial file:zig-out/aarch64-boot.log \
  -no-reboot -semihosting-config enable=on,target=native
# expect: "Zinux ARM64 boot OK"
```

The reproducible build and smoke gate is:

```text
zig build aarch64
zig build aarch64-verify
zig build aarch64-run
zig build test
```

The current Phase 1 implementation is intentionally limited to the boot
kernel, PL011 output, deterministic boot marker, prompt marker and
semihosting smoke exit. Timer/GIC, block, datagram, clock and userland init
are Phase 2+ work and are not claimed by this milestone.

`host_protocol_aarch64` (see `../../build.zig`) also proves that the
guest-host boundary compiles for `aarch64-freestanding`.

## Tests (on completion)

* [x] ARM64 kernel builds reproducibly.
* [x] Guest boots in the desktop reference environment.
* [x] Serial output contains the deterministic boot marker and prompt.
* [x] Semihosting smoke exit returns successfully.
* [ ] Init starts as a userland process.
* [ ] Invalid guest device requests are rejected.
* [x] `zig build` and `zig build test` preserve the existing x86_64 path.
