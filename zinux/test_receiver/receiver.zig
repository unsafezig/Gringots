//! Deterministic test receiver fixture (Phase 4 desktop bridge).
//!
//! A Gringots-compatible receiver with a FIXED test keypair: verifies an
//! inbound frame (framing -> TLV -> time -> signature -> replay), then
//! mints a valid ACK referencing the inbound NONCE. No I/O — the bridge
//! moves bytes; this struct owns crypto verdicts.

const std = @import("std");
const root = @import("gringots_root");
const msg = root.msg;
const frame = root.frame;
const ed = root.crypto_;
const replay = root.replay;

/// Fixed receiver identity for deterministic tests. NOT a secret.
pub const RECEIVER_SEED: [32]u8 = [_]u8{0x52} ** 32;

pub const HandleOutcome = enum {
    acked, // ACK bytes written to OUT
    no_ack, // frame invalid/expired/replayed/non-SOS: silence
};

pub const Receiver = struct {
    kp: ed.E.KeyPair,
    seen: replay.Cache = .{},
    last_len: usize = 0,

    pub fn init() !Receiver {
        return .{ .kp = try ed.keypairFromSeed(RECEIVER_SEED) };
    }

    /// Handle one inbound frame at NOW. On SOS success writes an ACK frame
    /// into OUT and returns .acked; otherwise returns .no_ack (never an ACK).
    pub fn onFrame(self: *Receiver, raw: []const u8, now: u64, out: []u8) HandleOutcome {
        const m = msg.verifyFrame(raw, now) catch return .no_ack;
        if (m.msg_type != .sos) return .no_ack;
        if (self.seen.check(m.ephemeral_id, m.nonce, m.expires, now) == .duplicate)
            return .no_ack;
        // Mint ACK(REF=sos.nonce) under the receiver's own ephemeral key.
        const b = msg.Builder{
            .msg_type = .ack,
            .ephemeral_id = self.kp.public_key.toBytes(),
            .timestamp = now,
            .expires = now +| 300,
            .nonce = deterministicNonce(m.nonce, now),
            .ref = m.nonce,
        };
        var body: [512]u8 = undefined;
        var fr: [600]u8 = undefined;
        const wire = msg.signAndFrame(&b, self.kp, &body, &fr) catch return .no_ack;
        if (out.len < wire.len) return .no_ack;
        @memcpy(out[0..wire.len], wire);
        // Stash length: caller slices out[0..rx.last_len].
        self.last_len = wire.len;
        return .acked;
    }
};

fn deterministicNonce(sos_nonce: [16]u8, now: u64) [16]u8 {
    var n: [16]u8 = undefined;
    // XOR-fold nonce with timestamp: deterministic, distinct per SOS.
    for (0..16) |i| {
        const shift: u6 = @intCast((i % 8) * 8);
        const t: u8 = @truncate((now >> shift) & 0xFF);
        n[i] = sos_nonce[i] ^ t ^ 0xA5;
    }
    return n;
}

const testing = std.testing;
const T0: u64 = 1798675200 + 12 * 3600;

fn makeSos(seed_byte: u8, nonce_byte: u8, ts: u64) struct { kp: ed.E.KeyPair, buf: [600]u8, len: usize } {
    const kp = ed.keypairFromSeed([_]u8{seed_byte} ** 32) catch unreachable;
    const b = msg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = ts,
        .expires = ts + 600,
        .nonce = [_]u8{nonce_byte} ** 16,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch unreachable;
    var out: [600]u8 = undefined;
    @memcpy(out[0..wire.len], wire);
    return .{ .kp = kp, .buf = out, .len = wire.len };
}

test "receiver acks valid SOS, ACK verifies with correct REF" {
    var rx = try Receiver.init();
    const s = makeSos(0x11, 0x22, T0);
    var ackbuf: [600]u8 = undefined;
    try testing.expect(rx.onFrame(s.buf[0..s.len], T0, &ackbuf) == .acked);
    const ack = ackbuf[0..rx.last_len];
    const m = try msg.verifyFrame(ack, T0);
    try testing.expect(m.msg_type == .ack);
    try testing.expectEqual(s.buf[0..0].len, s.buf[0..0].len); // keep linter honest
    // REF must equal the SOS nonce.
    const sm = try msg.verifyFrame(s.buf[0..s.len], T0);
    try testing.expectEqual(sm.nonce, m.ref.?);
}

test "receiver silent on replay, garbage, wrong type" {
    var rx = try Receiver.init();
    const s = makeSos(0x11, 0x33, T0);
    var ackbuf: [600]u8 = undefined;
    try testing.expect(rx.onFrame(s.buf[0..s.len], T0, &ackbuf) == .acked);
    // Replay of the same SOS: no second ACK.
    try testing.expect(rx.onFrame(s.buf[0..s.len], T0, &ackbuf) == .no_ack);
    // Garbage: silence.
    try testing.expect(rx.onFrame("not a frame", T0, &ackbuf) == .no_ack);
    // ACK addressed to nobody in particular is not SOS: no ACK back.
    const ack = ackbuf[0..rx.last_len];
    try testing.expect(rx.onFrame(ack, T0, &ackbuf) == .no_ack);
}
