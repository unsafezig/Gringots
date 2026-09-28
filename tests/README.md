# Tests

| Dir | Content | Command |
|---|---|---|
| `../src/` (unit) | Protocol, crypto, replay, agent, transports, audio, FFI | `zig build test` |
| `host_bridge/` | Desktop e2e SOS/ACK + 10 negative tests (Phase 4 gate) | `zig build test` |
| `protocol/` | (planned) wire-vector fixtures from `PROTOCOL.md` §8 | — |
| `zinux_guest/` | (planned) ARM64 boot-marker + device-reject tests | — |
| `android/` | (planned) bridge/consent instrumented tests | — |

Live loopback demo on desktop (no guest needed yet):

```text
zig build run -- listen --port 4848 --verify
zig build run -- broadcast <frame-hex> --to 127.0.0.1:4848
```
