//! Desktop host bridge (roadmap Phase 4).
//!
//! The same `HOST_PROTOCOL.md` framing the Android bridge will speak,
//! over UDP loopback instead of Wi-Fi: guest datagrams arrive as bytes,
//! Gringots payloads leave as UDP datagrams to the receiver at
//! 127.0.0.1:4848, and inbound UDP datagrams return as
//! `HOST_FRAME_DELIVER`. The bridge never mints Gringots frames, never
//! rewrites payloads, and never reports transport failure as an ACK.
//!
//! Layout: pure `classify` logic (no I/O, fully unit-tested) plus a thin
//! socket pump (`pumpOnce`) used by the loopback integration test below.

const std = @import("std");
const hp = @import("host_protocol");
const root = @import("gringots_root");
const svc_mod = @import("service_ipc");
const rx_mod = @import("test_receiver");

const Io = std.Io;
const net = Io.net;

/// Desktop loopback ports (fixed for determinism; production Wi-Fi uses
/// UDP broadcast on 4848 instead).
pub const RECEIVER_PORT: u16 = 48481;
pub const BRIDGE_PORT: u16 = 48482;

pub fn receiverAddr() net.IpAddress {
    return .{ .ip4 = .loopback(RECEIVER_PORT) };
}

pub fn bridgeAddr() net.IpAddress {
    return .{ .ip4 = .loopback(BRIDGE_PORT) };
}

pub const ActionTag = enum {
    /// Forward PAYLOAD to the receiver over UDP.
    transmit,
    /// Reply to the guest with this encoded datagram (HOST_ERROR).
    respond,
    /// Drop silently (unparsable framing is never attributable).
    drop,
};

pub const Action = struct {
    tag: ActionTag,
    /// Valid for `transmit`: Gringots payload slice into the input.
    payload: []const u8 = &.{},
    /// Valid for `respond`: encoded HOST_ERROR datagram.
    response: []const u8 = &.{},
};

/// Classify one guest-side datagram. RESPONSE_BUF holds a HOST_ERROR
/// encoding when the action is `respond`.
pub fn classify(raw: []const u8, response_buf: []u8) Action {
    const m = hp.decode(raw) catch return .{ .tag = .drop };
    switch (m.op) {
        .guest_sos_send => {
            hp.checkGringotsPayload(m.payload) catch {
                const enc = hp.encodeError(.bad_payload, "not a frame", response_buf) catch
                    return .{ .tag = .drop };
                return .{ .tag = .respond, .response = enc };
            };
            return .{ .tag = .transmit, .payload = m.payload };
        },
        .guest_status_req => {
            if (m.payload.len != 0) {
                const enc = hp.encodeError(.bad_payload, "status has body", response_buf) catch
                    return .{ .tag = .drop };
                return .{ .tag = .respond, .response = enc };
            }
            // No service state in the bridge core: report not-acked,
            // zero pending. The guest polls again after RECEIVE_FRAME.
            const enc = hp.encodeStatus(false, 0, response_buf) catch
                return .{ .tag = .drop };
            return .{ .tag = .respond, .response = enc };
        },
        else => {
            const enc = hp.encodeError(.bad_direction, m.op.name(), response_buf) catch
                return .{ .tag = .drop };
            return .{ .tag = .respond, .response = enc };
        },
    }
}

/// Wrap one inbound receiver-side UDP payload for the guest. Non-frame
/// bytes become HOST_ERROR(BAD_PAYLOAD), never a deliver.
pub fn wrapInbound(payload: []const u8, out: []u8) ![]u8 {
    hp.checkGringotsPayload(payload) catch {
        return hp.encodeError(.bad_payload, "inbound", out);
    };
    return hp.encode(.host_frame_deliver, payload, out);
}

const testing = std.testing;

test "sos payload is transmitted untouched" {
    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const payload = [_]u8{0xAB} ** 200;
    const d = try hp.encode(.guest_sos_send, &payload, &req);
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const a = classify(d, &resp);
    try testing.expect(a.tag == .transmit);
    try testing.expectEqualSlices(u8, &payload, a.payload);
}

test "framing errors drop silently" {
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    try testing.expect(classify(&[_]u8{ 0, 1, 2 }, &resp).tag == .drop);
    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const d = try hp.encode(.guest_sos_send, "hello", &req);
    var bad: [hp.MAX_DATAGRAM]u8 = undefined;
    @memcpy(bad[0..d.len], d);
    bad[d.len - 1] ^= 0x01;
    try testing.expect(classify(bad[0..d.len], &resp).tag == .drop);
}

test "wrong op and bad payload get HOST_ERROR, never transmit" {
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    // guest_status_req with a body: BAD_PAYLOAD.
    const s = try hp.encode(.guest_status_req, "x", &req);
    const a = classify(s, &resp);
    try testing.expect(a.tag == .respond);
    const m = try hp.decode(a.response);
    try testing.expect(m.op == .host_error);
    try testing.expect(m.payload[0] == @intFromEnum(hp.ErrorCode.bad_payload));
    // host_frame_deliver arriving from the guest side: BAD_DIRECTION.
    const f = try hp.encode(.host_frame_deliver, &[_]u8{0} ** 150, &req);
    const b = classify(f, &resp);
    try testing.expect(b.tag == .respond);
    const m2 = try hp.decode(b.response);
    try testing.expect(m2.payload[0] == @intFromEnum(hp.ErrorCode.bad_direction));
    // SOS wrapper around 10 bytes: BAD_PAYLOAD, frame never forwarded.
    const g = try hp.encode(.guest_sos_send, &[_]u8{0} ** 10, &req);
    const c = classify(g, &resp);
    try testing.expect(c.tag == .respond);
}

// Full loop over real loopback sockets: guest bytes -> bridge classify ->
// UDP to receiver -> receiver socket reads the exact Gringots payload.
test "loopback: transmit reaches the receiver socket" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: Io = threaded.io();

    var rx_sock = try receiverAddr().bind(io, .{ .mode = .dgram });
    defer rx_sock.close(io);
    var tx_sock = try bridgeAddr().bind(io, .{ .mode = .dgram });
    defer tx_sock.close(io);

    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const payload = [_]u8{0xCD} ** 200;
    const d = try hp.encode(.guest_sos_send, &payload, &req);
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const a = classify(d, &resp);
    try testing.expect(a.tag == .transmit);

    var dest = receiverAddr();
    try tx_sock.send(io, &dest, a.payload);

    // Blocking receive: single-threaded test Io has no timeout support,
    // and loopback delivery does not drop. The send above precedes it.
    var buf: [1500]u8 = undefined;
    const im = try rx_sock.receive(io, &buf);
    try testing.expectEqualSlices(u8, &payload, im.data);
}

// Desktop Phase 4 milestone over real sockets with real crypto:
// service SOS -> bridge -> UDP -> receiver -> ACK -> bridge -> service.
test "loopback: SOS -> receiver -> ACK -> acked status" {
    const T0: u64 = 1798675200 + 12 * 3600;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: Io = threaded.io();

    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    var rx = try rx_mod.Receiver.init();

    var rx_sock = try receiverAddr().bind(io, .{ .mode = .dgram });
    defer rx_sock.close(io);
    var tx_sock = try bridgeAddr().bind(io, .{ .mode = .dgram });
    defer tx_sock.close(io);

    // Guest -> bridge.
    const sos = try guest.createSos(T0);
    _ = try guest.sendFrame(sos);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const up_dgram = try hp.encode(.guest_sos_send, sos, &up);
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const a = classify(up_dgram, &resp);
    try testing.expect(a.tag == .transmit);

    // Bridge -> receiver over UDP; receiver mints ACK.
    var dest = receiverAddr();
    try tx_sock.send(io, &dest, a.payload);
    var air: [1500]u8 = undefined;
    const im = try rx_sock.receive(io, &air);
    var ack_raw: [600]u8 = undefined;
    try testing.expect(rx.onFrame(im.data, T0, &ack_raw) == .acked);

    // Receiver -> bridge -> guest.
    var down: [hp.MAX_DATAGRAM]u8 = undefined;
    const down_dgram = try wrapInbound(ack_raw[0..rx.last_len], &down);
    const down_msg = try hp.decode(down_dgram);
    try testing.expect(down_msg.op == .host_frame_deliver);
    try testing.expect(guest.receiveFrame(down_msg.payload, T0) == .acked);
    try testing.expect(guest.getStatus().acked);
}
