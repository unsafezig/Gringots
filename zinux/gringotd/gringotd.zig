//! GRINGOTD daemon relay — bridges local gringotsd clients to the
//! external receiver network over Zinux datagram sockets.
//!
//! Design: one bridge listener (BRIDGE_PORT) accepts SOS frames from
//! local gringotsd instances; an outbound sender forwards them toward
//! the receiver network (RECEIVER_PORT). Inbound ACK bytes return via
//! relayInbound(), which wraps them as HOST_FRAME_DELIVER exactly like
//! bridge.wrapInbound.
//!
//! ```text
//! local gringotsd -> GRINGOTD bridge listener (48482)
//!     -> sender -> receiver network (48481)
//! receiver ACK bytes -> relayInbound -> HOST_FRAME_DELIVER -> client
//! ```
//!
//! Pure decision logic (classify/relayInbound) is fully unit-tested.
//! The socket pump (init/relayOne/relayLoop/close) binds fixed ports in
//! production, so its only socket test uses ephemeral ports via initOn
//! and never touches the canonical ones (parallel test binaries share
//! this machine, and fixed-port binds collide there).

const std = @import("std");
const hp = @import("host_protocol");
const svc_mod = @import("service_ipc");
const rx_mod = @import("test_receiver");
const udp_b = @import("bridge");

pub const Io = std.Io;
pub const net = Io.net;

/// Canonical desktop ports. Single source of truth is bridge.zig;
/// re-exported here so the relay cannot drift.
pub const RECEIVER_PORT: u16 = udp_b.RECEIVER_PORT;
pub const BRIDGE_PORT: u16 = udp_b.BRIDGE_PORT;

pub fn receiverAddr() net.IpAddress {
    return udp_b.receiverAddr();
}

pub fn bridgeAddr() net.IpAddress {
    return udp_b.bridgeAddr();
}

fn ephemeralAddr() net.IpAddress {
    return .{ .ip4 = .loopback(0) };
}

/// Stateless GRINGOTD frame classifier — mirrors bridge.classify so
/// that the relay can decide at the daemon layer what to forward,
/// respond, or drop.
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
            // No service state in the relay core — report not-acked.
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

/// Relay action returned by classify.  Mirrors bridge Action for
/// consistency across the GRINGOTD module boundary.
pub const ActionTag = enum { transmit, respond, drop };

pub const Action = struct {
    tag: ActionTag,
    payload: []const u8 = &.{},
    response: []const u8 = &.{},
};

/// Wrap one inbound receiver-side payload for a local client. Same
/// contract as bridge.wrapInbound, delegated there: valid Gringots
/// bytes become HOST_FRAME_DELIVER; anything else becomes
/// HOST_ERROR(BAD_PAYLOAD) — never a deliver, never an ACK.
pub fn relayInbound(payload: []const u8, out_buf: []u8) ![]u8 {
    return udp_b.wrapInbound(payload, out_buf);
}

/// GRINGOTD relay — accepts datagrams from gringotsd clients on the
/// bridge port and forwards them toward the receiver network. The
/// sender binds an ephemeral port: binding the receiver's own port
/// would steal its inbound traffic (and collide with it in tests).
pub const GringotdRelay = struct {
    /// Datagram socket on the bridge port for receiving SOS frames.
    br_sock: net.Socket,
    /// Ephemerally-bound outbound sender toward the receiver network.
    ext_sender: net.Socket,

    /// Production entry: bridge listener on the canonical port,
    /// sender ephemeral.
    pub fn init() !GringotdRelay {
        return initOn(bridgeAddr(), ephemeralAddr());
    }

    /// Bind explicitly. Tests pass ephemeral addresses so parallel test
    /// binaries never collide on the canonical ports.
    pub fn initOn(br_addr: net.IpAddress, ext_bind: net.IpAddress) !GringotdRelay {
        var threaded = std.Io.Threaded.init_single_threaded;
        const bridged_io: Io = threaded.io();
        var ext_threaded = std.Io.Threaded.init_single_threaded;
        const ext_io: Io = ext_threaded.io();
        const br_sock = try br_addr.bind(bridged_io, .{
            .mode = .dgram,
            .allow_broadcast = false,
        });
        const ext_sender = try ext_bind.bind(ext_io, .{
            .mode = .dgram,
            .allow_broadcast = false,
        });
        return .{
            .br_sock = br_sock,
            .ext_sender = ext_sender,
        };
    }

    /// Process one datagram received on the bridge listener. Returns
    /// true iff the payload was forwarded toward the receiver network.
    /// `respond`/`drop` outcomes return false and send nothing: replying
    /// through the listener socket would re-inject our own
    /// HOST_ERROR/HOST_STATUS into the receive queue and spin the loop.
    /// Client-addressed replies need the sender's source address and are
    /// a follow-up. Send failures propagate; relayLoop counts them as
    /// drops and keeps running.
    pub fn relayOne(self: *GringotdRelay, data: []const u8) !bool {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        var resp: [hp.MAX_DATAGRAM]u8 = undefined;
        const action = classify(data, &resp);
        switch (action.tag) {
            .transmit => {
                // Forward to the receiver network.
                var dest = receiverAddr();
                try self.ext_sender.send(io, &dest, action.payload);
                return true;
            },
            .respond, .drop => return false,
        }
    }

    /// Relay loop — forwards datagrams from the bridge port until a
    /// receive fails or zero bytes arrive. A forward failure never
    /// unwinds the loop; it counts as a drop.
    pub fn relayLoop(self: *GringotdRelay) !void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        var buf: [1500]u8 = undefined;
        while (true) {
            const im = try self.br_sock.receive(io, &buf);
            if (im.data.len == 0) break;
            _ = self.relayOne(im.data) catch false;
        }
    }

    pub fn close(self: *GringotdRelay) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();
        self.br_sock.close(io);
        self.ext_sender.close(io);
    }
};

const testing = std.testing;

const T0: u64 = 1798675200 + 12 * 3600;

test "classify forwards a real SOS payload untouched" {
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    const sos = try guest.createSos(T0);
    _ = try guest.sendFrame(sos);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const dgram = try hp.encode(.guest_sos_send, sos, &up);
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const a = classify(dgram, &resp);
    try testing.expect(a.tag == .transmit);
    try testing.expectEqualSlices(u8, sos, a.payload);
}

test "classify drops unparseable framing, responds to bad ops" {
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    // Unparseable framing: silent drop.
    try testing.expect(classify(&[_]u8{ 0, 1, 2 }, &resp).tag == .drop);
    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const d = try hp.encode(.guest_sos_send, "hello", &req);
    var bad: [hp.MAX_DATAGRAM]u8 = undefined;
    @memcpy(bad[0..d.len], d);
    bad[d.len - 1] ^= 0x01;
    try testing.expect(classify(bad[0..d.len], &resp).tag == .drop);
    // Guest-side wrong direction: HOST_ERROR(BAD_DIRECTION).
    const f = try hp.encode(.host_frame_deliver, &[_]u8{0} ** 150, &req);
    const b = classify(f, &resp);
    try testing.expect(b.tag == .respond);
    const m2 = try hp.decode(b.response);
    try testing.expect(m2.op == .host_error);
    try testing.expect(m2.payload[0] == @intFromEnum(hp.ErrorCode.bad_direction));
    // SOS wrapper around 10 bytes: HOST_ERROR(BAD_PAYLOAD).
    const g = try hp.encode(.guest_sos_send, &[_]u8{0} ** 10, &req);
    try testing.expect(classify(g, &resp).tag == .respond);
    // Well-formed empty status request: HOST_STATUS_RESP(not-acked).
    const s = try hp.encode(.guest_status_req, &[_]u8{}, &req);
    const st = classify(s, &resp);
    try testing.expect(st.tag == .respond);
    const sm = try hp.decode(st.response);
    try testing.expect(sm.op == .host_status_resp);
    const dec = try hp.decodeStatus(sm.payload);
    try testing.expect(!dec.acked and dec.pending == 0);
}

test "relayInbound wraps a real ACK as HOST_FRAME_DELIVER" {
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    var rx = try rx_mod.Receiver.init();
    const sos = try guest.createSos(T0);
    var ack_raw: [600]u8 = undefined;
    try testing.expect(rx.onFrame(sos, T0, &ack_raw) == .acked);
    var down: [hp.MAX_DATAGRAM]u8 = undefined;
    const dgram = try relayInbound(ack_raw[0..rx.last_len], &down);
    const m = try hp.decode(dgram);
    try testing.expect(m.op == .host_frame_deliver);
    try testing.expect(guest.receiveFrame(m.payload, T0) == .acked);
    try testing.expect(guest.getStatus().acked);
    // Non-frame bytes become HOST_ERROR, never a deliver.
    var ebuf: [hp.MAX_DATAGRAM]u8 = undefined;
    const egram = try relayInbound("not-a-frame-at-all", &ebuf);
    const em = try hp.decode(egram);
    try testing.expect(em.op == .host_error);
}

test "relay sockets bind and close on ephemeral ports" {
    var relay = try GringotdRelay.initOn(ephemeralAddr(), ephemeralAddr());
    relay.close();
}
