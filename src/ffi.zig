//! C ABI for embedding Gringots in platform apps (Phase 5).
//!
//! An Android app (Kotlin/JNI), iOS app, or embedded firmware links the
//! static library (`zig build` installs `libgringots.a`) and drives the
//! agent through these functions. The ABI is deliberately stateless and
//! buffer-based: the host owns keys, clocks, UI, radios and location;
//! Gringots owns bytes and cryptography.
//!
//! Conventions: all buffers caller-owned. Lengths are `usize`.
//! Negative `i64` returns are errors; `verify` returns 0 = valid,
//! 1 = invalid (any cause: framing, parse, time, signature).

const std = @import("std");
// Direct imports (not via root.zig): the JNI .so must not pull
// transports/std.Io (thread-pool init references getauxval, which
// Bionic lacks). Keeps the embedded surface minimal.
const frame = @import("protocol/frame.zig");
const msg = @import("protocol/msg.zig");
const ed = @import("crypto/ed25519.zig");

/// Protocol version implemented by this library.
pub export fn gringots_version() u32 {
    return 1;
}

/// Build a signed CIVILIAN_SOS frame.
/// Returns frame length on success, -1 bad args, -2 crypto/encode failure.
pub export fn gringots_make_sos(
    seed: [*]const u8,
    seed_len: usize,
    timestamp: u64,
    expires: u64,
    nonce: [*]const u8,
    nonce_len: usize,
    out: [*]u8,
    out_cap: usize,
) i64 {
    if (seed_len < 32 or nonce_len < 16 or out_cap < 521) return -1;
    const kp = ed.keypairFromSeed(seed[0..32].*) catch return -2;
    var n: [16]u8 = undefined;
    @memcpy(&n, nonce[0..16]);
    const b = msg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = timestamp,
        .expires = expires,
        .nonce = n,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch return -2;
    @memcpy(out[0..wire.len], wire);
    return @intCast(wire.len);
}

/// Verify a received frame at time `now`. 0 = valid, 1 = invalid.
pub export fn gringots_verify_frame(frm: [*]const u8, len: usize, now: u64) i32 {
    _ = msg.verifyFrame(frm[0..len], now) catch return 1;
    return 0;
}

/// Debug text form into OUT. Returns bytes written, negative on error.
pub export fn gringots_describe(frm: [*]const u8, len: usize, out: [*]u8, out_cap: usize) i64 {
    const dec = frame.decodeFrame(frm[0..len]) catch return -1;
    const m = msg.parseBody(dec.body) catch return -1;
    const text = msg.formatDebug(&m, out[0..out_cap]) catch return -1;
    return @intCast(text.len);
}

const testing = std.testing;

test "ffi sos round-trips through verify and describe" {
    var seed: [32]u8 = [_]u8{0xE0} ** 32;
    var nonce: [16]u8 = [_]u8{0xF1} ** 16;
    var out: [600]u8 = undefined;
    const n = gringots_make_sos(&seed, 32, 1798675200, 1798675800, &nonce, 16, &out, 600);
    try testing.expect(n > 100);
    try testing.expectEqual(@as(i32, 0), gringots_verify_frame(&out, @intCast(n), 1798675200));
    try testing.expectEqual(@as(i32, 1), gringots_verify_frame(&out, @intCast(n), 1798675800 + 301));
    var text: [512]u8 = undefined;
    const tlen = gringots_describe(&out, @intCast(n), &text, 512);
    try testing.expect(tlen > 0);
    try testing.expect(std.mem.startsWith(u8, text[0..@intCast(tlen)], "GRINGOTTS/1 TYPE=CIVILIAN_SOS"));
    try testing.expectEqual(@as(i64, -1), gringots_make_sos(&seed, 4, 0, 0, &nonce, 16, &out, 600));
}
