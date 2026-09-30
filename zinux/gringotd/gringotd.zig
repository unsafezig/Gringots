//! GRINGOTD daemon relay — bridges local gringotsd clients to the
//! external receiver network over Zinux datagram sockets.
//!
//! Design: one bridge listener (BRIDGE_LISTEN_PORT) accepts SOS frames
//! from local gringotd instances; an outbound sender forwards them on
//! the external net interface port 48481 toward the receiver layer.
//! Inbound ACKs come back via wrapInbound() through the same bridged
//! address (no separate inbound relay per client).
//!
//! ```text
//! local_gringotsd(48482) -> GRINGTD bridge listener -> sender(48481 ext)
//!     receiver network ACKs -> wrapInbound() -> gringotd bridge port
//! ```

const std = @import("std");
const hp = @import("host_protocol");
const root = @import("gringots_root");
const service = root.service;
const udp_b = @import("bridge");

pub const Io = std.Io;
pub const net = Io.net;

/// Bridge address where local gringotd instances send SOS frames /
/// receive inbound ACKs from the relayer.
pub const bridge_addr: net.IpAddress = udp_b.bridgeAddr();

/// Receiver network destination port (external).
const RECV_PORT: u16 = 48481;

fn receiver_net_addr() net.IpAddress {
    // In production bind to the external interface instead of
    // loopback. For Phase-4 desktop testing on one machine use
    // loopback as a stand-in for the "receiver subnet".
    return .{ .ip4 = .loopback(RECV_PORT) };
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

/// GRINGOTD relay loop — accept datagrams from the gringotsd client
/// on BRIDGE_LISTEN_PORT and forward them outward to the receiver
/// network at port RECV_PORT.  Uses an ephemeral sender port so that
/// inbound ACKs route back through Zinux routing to the client's own
/// bridge listener address (no separate relay needed).
pub const GringodRelay = struct {
    /// Datagram socket on local bridge port for receiving SOS frames.
    br_sock: net.Socket,
    /// Outbound sender bound to external net interface (port 48481).
    ext_sender: net.Socket,

    pub fn init() !GringodRelay {
        var threaded = std.Io.Threaded.init_single_threaded;
        const bridged_io: Io = threaded.io();
        var ext_threaded = std.Io.Threaded.init_single_threaded;
        const ext_io: Io = ext_threaded.io();
        // Bind bridge listener on the Zinux address.
        const bind_addr = udp_b.bridgeAddr();
        const br_sock = try bind_addr.bind(bridged_io, .{
            .mode = .dgram,
            .allow_broadcast = false,
        });
        // Sender: bind to external net interface port 48481.
        const ext_addr = receiver_net_addr();
        const ext_sender = try ext_addr.bind(ext_io, .{
            .mode = .dgram,
            .allow_broadcast = false,
        });
        return .{
            .br_sock = br_sock,
            .ext_sender = ext_sender,
        };
    }

    /// Process one datagram received on the bridge listener.  Returns
    /// true if the frame was forwarded to the receiver network, or if
    /// a response was written back to the client through the bridge
    /// listener (status / error).  In all other cases returns false
    /// (silent drop: unparseable framing or non-SOS op).
    pub fn relayOne(self: *GringodRelay, data: []const u8) bool {
        const threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        const action = classify(data, &[_]u8{});
        switch (action.tag) {
            .transmit => {
                // Forward to the receiver network.
                const dest = receiver_net_addr();
                try self.ext_sender.send(io, &dest, action.payload);
                return true;
            },
            .respond => {
                // Send the encoded response back via the bridge listener.
                try self.br_sock.send(io, &bridge_addr, action.response);
                return false;
            },
            .drop => return false,
        }
    }

    /// Relay loop — accepts and processes datagrams from the Zinux
    /// bridge port until an error occurs or zero bytes are received.
    pub fn relayLoop(self: *GringodRelay) !void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        var buf: [1500]u8 = undefined;
        while (true) {
            const im = try self.br_sock.receive(io, &buf);
            if (im.data.len == 0) break;
            // Relay the frame through GRINGOTD's bridge.
            _ = self.relayOne(im.data);
        }
    }

    pub fn close(self: *GringodRelay) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();
        self.br_sock.close(io);
        self.ext_sender.close(io);
    }
};

/// Validate one inbound receiver frame and forward it to a client.
/// OUT is the bridge listener address to write the wrapped datagram to.
pub fn relayInbound(raw: []const u8, out_buf: []u8) !bool {
    const m = hp.decode(raw) catch return false;
    switch (m.op) {
        .host_frame_deliver => {
            hp.checkGringotsPayload(m.payload) catch return false;
            // Already a valid HOST_FRAME_DELIVER — relay unchanged.
            try std.mem.copy(u8, out_buf[0..m.payload.len], m.payload);
            return true;
        },
        else => return false,
    }
}

const testing = std.testing;

test "classify: forward SOS payload via relayOne" {
    var rx = try GringodRelay.init();
    defer rx.close();
    // Relay accepts valid datagrams and drops malformed ones.
    const action = classify(
        &[_]u8{ 0, 1, 2 }, // invalid framing
        &[_]u8{},
    );
    try testing.expect(action.tag == .drop);

    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const s_a = classify(
        &[_]u8{ 0x5A, 0x47, 0x01, 0x01 }, // valid op=guest_sos_send header (no CRC)
        &resp,
    );
    try testing.expect(s_a.tag == .drop); // still drops: no CRC / truncated.
}

test "classify rejects bad direction" {
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    const payload: []const u8 = &[_]u8{ 0x5A, 0x47, 0x01, @intFromEnum(hp.Op.host_frame_deliver) };
    // truncated datagram — decode fails on CRC/length check
    const a = classify(payload, &resp);
    try testing.expect(a.tag == .drop);
}
