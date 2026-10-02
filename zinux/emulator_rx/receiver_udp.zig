//! Desktop UDP receiver for the emulator live loop (test-only).
//!
//! Binds 127.0.0.1:LIVE_PORT; the emulator app reaches it at 10.0.2.2.
//! Composition only, no new protocol: bridge.classify validates
//! framing/direction, the deterministic Receiver mints or denies ACKs,
//! bridge.wrapInbound frames the reply. Replies go to the datagram source;
//! unparsable input drops silently per HOST_PROTOCOL.md Section 1.

const std = @import("std");
const hp = @import("host_protocol");
const bridge = @import("bridge");
const rx_mod = @import("test_receiver");

const Io = std.Io;
const net = Io.net;

/// Test-only port. The canonical bridge pair (48481/48482) stays untouched.
pub const LIVE_PORT: u16 = 48483;

pub fn liveAddr() net.IpAddress {
    return .{ .ip4 = .loopback(LIVE_PORT) };
}

/// One inbound datagram -> reply bytes in OUT, or null on silent drop.
pub fn handle(rx: *rx_mod.Receiver, raw: []const u8, now: u64, out: []u8) ?[]u8 {
    var tmp: [hp.MAX_DATAGRAM]u8 = undefined;
    const a = bridge.classify(raw, &tmp);
    switch (a.tag) {
        .drop => return null,
        .respond => {
            if (out.len < a.response.len) return null;
            @memcpy(out[0..a.response.len], a.response);
            return out[0..a.response.len];
        },
        .transmit => {
            var ack: [600]u8 = undefined;
            if (rx.onFrame(a.payload, now, &ack) != .acked) {
                return hp.encodeError(.denied, "rejected", out) catch null;
            }
            return bridge.wrapInbound(ack[0..rx.last_len], out) catch null;
        },
    }
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: Io = threaded.io();
    var sock = try liveAddr().bind(io, .{ .mode = .dgram });
    defer sock.close(io);
    std.debug.print("emulator-rx: listening on 127.0.0.1:{d} (emulator sends to 10.0.2.2:{d})\n", .{ LIVE_PORT, LIVE_PORT });
    var rx = try rx_mod.Receiver.init();
    var in: [2048]u8 = undefined;
    var out: [hp.MAX_DATAGRAM]u8 = undefined;
    while (true) {
        const im = try sock.receive(io, &in);
        const now: u64 = @intCast(Io.Timestamp.now(io, .real).toSeconds());
        if (handle(&rx, im.data, now, &out)) |reply| {
            var dest = im.from;
            try sock.send(io, &dest, reply);
        }
    }
}

const root = @import("gringots_root");
const tmsg = root.msg;
const ted = root.crypto_;
const testing = std.testing;
const T0: u64 = 1798675200 + 12 * 3600;

fn makeSos(seed_byte: u8, nonce_byte: u8, ts: u64, buf: []u8) []u8 {
    const kp = ted.keypairFromSeed([_]u8{seed_byte} ** 32) catch unreachable;
    const b = tmsg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = ts,
        .expires = ts + 600,
        .nonce = [_]u8{nonce_byte} ** 16,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = tmsg.signAndFrame(&b, kp, &body, &fr) catch unreachable;
    @memcpy(buf[0..wire.len], wire);
    return buf[0..wire.len];
}

test "live SOS -> HOST_FRAME_DELIVER with verifiable ACK" {
    var rx = try rx_mod.Receiver.init();
    var sosbuf: [600]u8 = undefined;
    const sos = makeSos(0x11, 0x22, T0, &sosbuf);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const dg = try hp.encode(.guest_sos_send, sos, &up);
    var out: [hp.MAX_DATAGRAM]u8 = undefined;
    const reply = handle(&rx, dg, T0, &out) orelse return error.NoReply;
    const m = try hp.decode(reply);
    try testing.expect(m.op == .host_frame_deliver);
    const ack = try tmsg.verifyFrame(m.payload, T0);
    try testing.expect(ack.msg_type == .ack);
    const sm = try tmsg.verifyFrame(sos, T0);
    try testing.expectEqual(sm.nonce, ack.ref.?);
}

test "live replay -> HOST_ERROR denied, garbage drops silently" {
    var rx = try rx_mod.Receiver.init();
    var sosbuf: [600]u8 = undefined;
    const sos = makeSos(0x11, 0x33, T0, &sosbuf);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const dg = try hp.encode(.guest_sos_send, sos, &up);
    var out: [hp.MAX_DATAGRAM]u8 = undefined;
    _ = handle(&rx, dg, T0, &out) orelse return error.NoReply;
    const reply2 = handle(&rx, dg, T0, &out) orelse return error.NoReply;
    const m = try hp.decode(reply2);
    try testing.expect(m.op == .host_error);
    try testing.expect(m.payload[0] == @intFromEnum(hp.ErrorCode.denied));
    // Garbage: silence.
    try testing.expect(handle(&rx, "not a datagram", T0, &out) == null);
    // Wrong direction (host op from guest side): HOST_ERROR, never a deliver.
    var wrong: [hp.MAX_DATAGRAM]u8 = undefined;
    const w = try hp.encode(.host_frame_deliver, &[_]u8{0} ** 150, &wrong);
    const reply3 = handle(&rx, w, T0, &out) orelse return error.NoReply;
    const m3 = try hp.decode(reply3);
    try testing.expect(m3.op == .host_error);
}
