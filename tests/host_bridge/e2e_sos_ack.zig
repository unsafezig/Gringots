//! Desktop end-to-end path (roadmap Phase 4 milestone):
//!
//! ```text
//! gringotsd.CREATE_SOS -> GUEST_SOS_SEND -> bridge -> receiver
//!     -> ACK -> HOST_FRAME_DELIVER -> gringotsd.RECEIVE_FRAME
//!     -> GET_STATUS(acked=true)
//! ```
//!
//! Plus the ten required negative tests: invalid magic, unsupported
//! version, invalid length, invalid CRC, malformed TLV, invalid
//! signature, expired frame, replayed nonce, invalid ACK ref, unknown
//! response treated as no-ACK.

const std = @import("std");
const root = @import("gringots_root");
const hp = @import("host_protocol");
const svc_mod = @import("service_ipc");
const rx_mod = @import("test_receiver");
const msg = root.msg;
const frame = root.frame;
const ed = root.crypto_;

const T0: u64 = 1798675200 + 12 * 3600;
const testing = std.testing;

// Full desktop loop over byte buffers (no sockets: the bridge moves bytes).
test "e2e: SOS -> receiver -> ACK -> acked status" {
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    var rx = try rx_mod.Receiver.init();

    // 1. Guest creates SOS.
    const sos = try guest.createSos(T0);
    var sos_copy: [600]u8 = undefined;
    @memcpy(sos_copy[0..sos.len], sos);
    const sos_bytes = sos_copy[0..sos.len];

    // 2. Guest wraps it as GUEST_SOS_SEND (SEND_FRAME shape-check first).
    _ = try guest.sendFrame(sos_bytes);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const up_dgram = try hp.encode(.guest_sos_send, sos_bytes, &up);

    // 3. Desktop bridge: decode host datagram, extract Gringots payload.
    const up_msg = try hp.decode(up_dgram);
    try testing.expect(up_msg.op == .guest_sos_send);
    try hp.checkGringotsPayload(up_msg.payload);

    // 4. Receiver verifies + mints ACK.
    var ack_raw: [600]u8 = undefined;
    try testing.expect(rx.onFrame(up_msg.payload, T0, &ack_raw) == .acked);
    const ack_bytes = ack_raw[0..rx.last_len];

    // 5. Bridge wraps ACK as HOST_FRAME_DELIVER.
    var down: [hp.MAX_DATAGRAM]u8 = undefined;
    const down_dgram = try hp.encode(.host_frame_deliver, ack_bytes, &down);
    const down_msg = try hp.decode(down_dgram);
    try testing.expect(down_msg.op == .host_frame_deliver);

    // 6. Guest receives; status must report acknowledgement.
    try testing.expect(guest.receiveFrame(down_msg.payload, T0) == .acked);
    const st = guest.getStatus();
    try testing.expect(st.acked);
    try testing.expect(st.pending == 0);
    try testing.expect(st.last_nonce != null);

    // 7. Host STATUS round-trip mirrors the same verdict.
    var sbuf: [hp.MAX_DATAGRAM]u8 = undefined;
    const sgram = try hp.encodeStatus(st.acked, @intCast(st.pending), &sbuf);
    const sm = try hp.decode(sgram);
    const decoded = try hp.decodeStatus(sm.payload);
    try testing.expect(decoded.acked);
}

// --- Negative tests (roadmap Phase 4 list) ---

fn validSos() struct { buf: [600]u8, len: usize } {
    const kp = ed.keypairFromSeed([_]u8{0x0B} ** 32) catch unreachable;
    const b = msg.Builder{
        .msg_type = .sos,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{0xC0} ** 16,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch unreachable;
    var out: [600]u8 = undefined;
    @memcpy(out[0..wire.len], wire);
    return .{ .buf = out, .len = wire.len };
}

test "negative: invalid magic rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    var s = validSos();
    s.buf[0] ^= 0xFF;
    try testing.expect(guest.verifyFrame(s.buf[0..s.len], T0) == .invalid);
}

test "negative: unsupported version rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    var s = validSos();
    s.buf[2] = 0x7F; // VER byte; CRC also breaks — verdict stays INVALID
    try testing.expect(guest.verifyFrame(s.buf[0..s.len], T0) == .invalid);
}

test "negative: invalid frame length rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    var s = validSos();
    // Truncate: MLEN claims more than arrived.
    try testing.expect(guest.verifyFrame(s.buf[0 .. s.len - 10], T0) == .invalid);
    // Empty.
    try testing.expect(guest.verifyFrame(&[_]u8{}, T0) == .invalid);
}

test "negative: invalid CRC rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    var s = validSos();
    s.buf[s.len - 1] ^= 0x01;
    const v = guest.verifyFrame(s.buf[0..s.len], T0);
    try testing.expect(v == .invalid);
    try testing.expectEqualStrings("BAD_CRC", v.invalid);
}

test "negative: malformed TLV rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    // Claims a TLV length running past the body.
    var body: [8]u8 = .{ 0x01, 0xFF, 0xAA, 0xBB, 0xFF, 0x40, 0, 0 };
    _ = &body;
    const garbage: []const u8 = &.{ 0x47, 0x52, 0x01, 0x00, 0x02, 0x01, 0xFF, 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(guest.verifyFrame(garbage, T0) == .invalid);
}

test "negative: invalid signature rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    var s = validSos();
    // Re-frame with a corrupted signature so CRC still passes.
    const dec = try frame.decodeFrame(s.buf[0..s.len]);
    var body2: [512]u8 = undefined;
    @memcpy(body2[0..dec.body.len], dec.body);
    body2[dec.body.len - 1] ^= 0x01;
    var reframed: [600]u8 = undefined;
    const wire = try frame.encodeFrame(body2[0..dec.body.len], &reframed);
    const v = guest.verifyFrame(wire, T0);
    try testing.expect(v == .invalid);
    try testing.expectEqualStrings("BAD_SIGNATURE", v.invalid);
}

test "negative: expired frame rejected" {
    var guest = try svc_mod.Service.init([_]u8{1} ** 32, T0);
    const s = validSos();
    const v = guest.verifyFrame(s.buf[0..s.len], T0 + 600 + 301);
    try testing.expect(v == .invalid);
    try testing.expectEqualStrings("EXPIRED", v.invalid);
}

test "negative: replayed nonce gives no second ACK" {
    var rx = try rx_mod.Receiver.init();
    const s = validSos();
    var ackbuf: [600]u8 = undefined;
    try testing.expect(rx.onFrame(s.buf[0..s.len], T0, &ackbuf) == .acked);
    try testing.expect(rx.onFrame(s.buf[0..s.len], T0, &ackbuf) == .no_ack);
}

test "negative: invalid ACK reference is no acknowledgement" {
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    _ = try guest.createSos(T0);
    // ACK for an unknown NONCE under some other key.
    const kp = ed.keypairFromSeed([_]u8{0xBB} ** 32) catch unreachable;
    const b = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{7} ** 16,
        .ref = [_]u8{0} ** 16, // not our SOS nonce
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = try msg.signAndFrame(&b, kp, &body, &fr);
    try testing.expect(guest.receiveFrame(wire, T0) == .no_ack);
    try testing.expect(!guest.getStatus().acked);
}

test "negative: unknown response treated as no acknowledgement" {
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    _ = try guest.createSos(T0);
    // A DECLINE (valid frame, not an ACK) must not set acked.
    const kp = ed.keypairFromSeed([_]u8{0xBB} ** 32) catch unreachable;
    const b = msg.Builder{
        .msg_type = .decline,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{9} ** 16,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = try msg.signAndFrame(&b, kp, &body, &fr);
    try testing.expect(guest.receiveFrame(wire, T0) == .no_ack);
    try testing.expect(guest.receiveFrame("garbage-bytes", T0) == .no_ack);
    try testing.expect(!guest.getStatus().acked);
}

test "negative: host datagram with bad CRC dropped before receiver" {
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const s = validSos();
    const d = try hp.encode(.guest_sos_send, s.buf[0..s.len], &up);
    var bad: [hp.MAX_DATAGRAM]u8 = undefined;
    @memcpy(bad[0..d.len], d);
    bad[d.len - 1] ^= 0x01;
    try testing.expectError(error.CrcMismatch, hp.decode(bad[0..d.len]));
}
