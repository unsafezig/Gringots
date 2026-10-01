//! GRINGOTD daemon relay — bridges local gringotsd clients to the
//! external receiver network over Zinux datagram sockets.
//!
//! Design: one bridge listener (BRIDGE_PORT) accepts SOS frames from
//! local gringotsd instances; an outbound sender forwards them toward
//! every configured receiver target (default: RECEIVER_PORT).
//! Inbound ACK bytes return via relayInbound(), which wraps them as
//! HOST_FRAME_DELIVER exactly like bridge.wrapInbound.
//!
//! ```text
//! local gringotsd -> GRINGOTD bridge listener (48482)
//!     -> sender -> receiver targets (48481 + any addTarget)
//! receiver ACK bytes -> relayInbound -> HOST_FRAME_DELIVER -> client
//! ```
//!
//! Client-addressed replies: `relayOne` (no source address) keeps the
//! old drop-respond behavior so the loop can never re-inject its own
//! HOST_ERROR/HOST_STATUS into the receive queue. `relayOneFrom`
//! answers `respond` outcomes directly to the datagram source via the
//! listener socket — that is the only path that sends back to clients.
//!
//! Liveness: `RelayStats` counters plus `healthy()` / `statusReport()`
//! let clients poll the relay without touching Gringots crypto.
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
/// bridge port and forwards them toward every configured receiver
/// target. The sender binds an ephemeral port: binding the receiver's
/// own port would steal its inbound traffic (and collide with it in tests).
///
/// Per-subnet sockets (Wi-Fi broadcast vs loopback) arrive with the
/// Android transport: one socket already reaches every loopback target,
/// so targets are addresses today and become (socket, target) pairs
/// only when a transport needs a distinct interface per subnet.
pub const MAX_TARGETS: usize = 4;

/// Outcome of one relayed datagram: at most one of the flags is set.
/// `transmit` fans out to all targets; `respond` answers one client.
pub const RelayOutcome = struct {
    forwarded: bool = false,
    responded: bool = false,
};

/// Liveness counters. `send_fail` counts per-target/​per-reply socket
/// failures; the loop never unwinds on them, it keeps running.
pub const RelayStats = struct {
    forwarded: u64 = 0,
    responded: u64 = 0,
    dropped: u64 = 0,
    send_fail: u64 = 0,
};

pub const GringotdRelay = struct {
    /// Datagram socket on the bridge port for receiving SOS frames.
    br_sock: net.Socket,
    /// Ephemerally-bound outbound sender toward the receiver network.
    ext_sender: net.Socket,
    /// Receiver targets (fan-out list). Production: canonical receiver.
    targets: [MAX_TARGETS]net.IpAddress = undefined,
    targets_len: usize = 0,
    stats: RelayStats = .{},
    closed: bool = false,

    /// Production entry: bridge listener on the canonical port,
    /// sender ephemeral, single canonical receiver target.
    pub fn init() !GringotdRelay {
        var self = try initOn(bridgeAddr(), ephemeralAddr());
        try self.addTarget(receiverAddr());
        return self;
    }

    /// Bind explicitly. Tests pass ephemeral addresses so parallel test
    /// binaries never collide on the canonical ports. Starts with zero
    /// targets so tests never spray the canonical receiver port while a
    /// sibling test binary listens there; callers add targets explicitly.
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

    /// Register one receiver target. Fails closed when full so a
    /// misconfigured caller can never silently drop a subnet.
    pub fn addTarget(self: *GringotdRelay, addr: net.IpAddress) !void {
        if (self.targets_len >= MAX_TARGETS) return error.TargetsFull;
        self.targets[self.targets_len] = addr;
        self.targets_len += 1;
    }

    /// Drop all targets (test hermeticity; production always has one).
    pub fn clearTargets(self: *GringotdRelay) void {
        self.targets_len = 0;
    }

    pub fn targetCount(self: *const GringotdRelay) usize {
        return self.targets_len;
    }

    /// Watchdog snapshot: copy of the liveness counters.
    pub fn snapshot(self: *const GringotdRelay) RelayStats {
        return self.stats;
    }

    /// True while both sockets are bound. Clients poll this via
    /// `statusReport` without touching Gringots crypto.
    pub fn healthy(self: *const GringotdRelay) bool {
        return !self.closed;
    }

    /// Encode a liveness marker: HOST_STATUS_RESP(not-acked, no pending).
    /// Never an ACK — a transport being alive is not a delivery proof.
    pub fn statusReport(self: *const GringotdRelay, out: []u8) ![]u8 {
        _ = self;
        return hp.encodeStatus(false, 0, out);
    }

    /// Process one datagram received on the bridge listener. Returns
    /// true iff the payload was forwarded to at least one target.
    /// `respond`/`drop` outcomes return false and send nothing: without
    /// the sender's source address, replying through the listener socket
    /// would re-inject our own HOST_ERROR/HOST_STATUS into the receive
    /// queue and spin the loop. Use `relayOneFrom` when the source is
    /// known. Per-target send failures count as `send_fail` drops and
    /// never unwind the caller.
    pub fn relayOne(self: *GringotdRelay, data: []const u8) !bool {
        const r = try self.relayOneFrom(data, null);
        return r.forwarded;
    }

    /// Same as `relayOne`, but `respond` outcomes (HOST_ERROR /
    /// HOST_STATUS_RESP) are sent directly back to `client` via the
    /// listener socket instead of being dropped. `transmit` outcomes
    /// never reply: the ACK returns later through `relayInbound`.
    pub fn relayOneFrom(self: *GringotdRelay, data: []const u8, client: ?net.IpAddress) !RelayOutcome {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        var resp: [hp.MAX_DATAGRAM]u8 = undefined;
        const action = classify(data, &resp);
        switch (action.tag) {
            .transmit => {
                var sent: usize = 0;
                var i: usize = 0;
                while (i < self.targets_len) : (i += 1) {
                    var dest = self.targets[i];
                    self.ext_sender.send(io, &dest, action.payload) catch {
                        self.stats.send_fail += 1;
                        continue;
                    };
                    sent += 1;
                }
                if (sent > 0) {
                    self.stats.forwarded += 1;
                    return .{ .forwarded = true };
                }
                self.stats.dropped += 1;
                return .{};
            },
            .respond => {
                if (client) |c| {
                    var dst = c;
                    self.br_sock.send(io, &dst, action.response) catch {
                        self.stats.send_fail += 1;
                        self.stats.dropped += 1;
                        return .{};
                    };
                    self.stats.responded += 1;
                    return .{ .responded = true };
                }
                self.stats.dropped += 1;
                return .{};
            },
            .drop => {
                self.stats.dropped += 1;
                return .{};
            },
        }
    }

    /// Relay loop — forwards datagrams from the bridge port until a
    /// receive fails or zero bytes arrive. Replies go back to each
    /// datagram's source (`im.from`); forward failures count as drops
    /// and never unwind the loop.
    pub fn relayLoop(self: *GringotdRelay) !void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();

        var buf: [1500]u8 = undefined;
        while (true) {
            const im = try self.br_sock.receive(io, &buf);
            if (im.data.len == 0) break;
            _ = self.relayOneFrom(im.data, im.from) catch RelayOutcome{};
        }
    }

    pub fn close(self: *GringotdRelay) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io: Io = threaded.io();
        self.br_sock.close(io);
        self.ext_sender.close(io);
        self.closed = true;
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
    try testing.expect(relay.healthy());
    try testing.expectEqual(@as(usize, 0), relay.targetCount());
    relay.close();
    try testing.expect(!relay.healthy());
}

test "classify rejects host-direction ops from the guest side" {
    var resp: [hp.MAX_DATAGRAM]u8 = undefined;
    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    // HOST_TIME_SYNC (0x07) is host -> guest; a guest sending it gets
    // HOST_ERROR(BAD_DIRECTION), never a transmit.
    const t = try hp.encode(.host_time_sync, &[_]u8{0} ** 8, &req);
    const a = classify(t, &resp);
    try testing.expect(a.tag == .respond);
    const m = try hp.decode(a.response);
    try testing.expect(m.op == .host_error);
    try testing.expect(m.payload[0] == @intFromEnum(hp.ErrorCode.bad_direction));
}

test "relayOne fans out one SOS to every target" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: Io = threaded.io();

    // Test-only ports (never the canonical 48481/48482: sibling test
    // binaries bind those in parallel). Sequential within this binary.
    const relay_addr: net.IpAddress = .{ .ip4 = .loopback(48882) };
    const rx1_addr: net.IpAddress = .{ .ip4 = .loopback(48881) };
    const rx2_addr: net.IpAddress = .{ .ip4 = .loopback(48884) };

    var relay = try GringotdRelay.initOn(relay_addr, ephemeralAddr());
    defer relay.close();

    var rx1 = try rx1_addr.bind(io, .{ .mode = .dgram });
    defer rx1.close(io);
    var rx2 = try rx2_addr.bind(io, .{ .mode = .dgram });
    defer rx2.close(io);
    try relay.addTarget(rx1_addr);
    try relay.addTarget(rx2_addr);
    try testing.expectEqual(@as(usize, 2), relay.targetCount());

    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    const sos = try guest.createSos(T0);
    _ = try guest.sendFrame(sos);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    const dgram = try hp.encode(.guest_sos_send, sos, &up);

    try testing.expect(try relay.relayOne(dgram));

    var buf1: [1500]u8 = undefined;
    const im1 = try rx1.receive(io, &buf1);
    try testing.expectEqualSlices(u8, sos, im1.data);
    var buf2: [1500]u8 = undefined;
    const im2 = try rx2.receive(io, &buf2);
    try testing.expectEqualSlices(u8, sos, im2.data);
    try testing.expectEqual(@as(u64, 1), relay.snapshot().forwarded);
}

test "relayOneFrom answers status and errors to the client only" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io: Io = threaded.io();

    const relay_addr: net.IpAddress = .{ .ip4 = .loopback(48885) };
    const client_addr: net.IpAddress = .{ .ip4 = .loopback(48886) };

    var relay = try GringotdRelay.initOn(relay_addr, ephemeralAddr());
    defer relay.close();

    // Client socket: the relay replies here, never to its own listener.
    var client = try client_addr.bind(io, .{ .mode = .dgram });
    defer client.close(io);

    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const s = try hp.encode(.guest_status_req, &[_]u8{}, &req);

    // Without a source address the response is dropped (no self-inject).
    const no_src = try relay.relayOneFrom(s, null);
    try testing.expect(!no_src.forwarded and !no_src.responded);

    // With a source address the client gets HOST_STATUS_RESP.
    const with_src = try relay.relayOneFrom(s, client_addr);
    try testing.expect(!with_src.forwarded and with_src.responded);
    var buf: [1500]u8 = undefined;
    const im = try client.receive(io, &buf);
    const m = try hp.decode(im.data);
    try testing.expect(m.op == .host_status_resp);
    const dec = try hp.decodeStatus(m.payload);
    try testing.expect(!dec.acked and dec.pending == 0);

    // Transmit never replies to the client, even with a source address.
    var guest = try svc_mod.Service.init([_]u8{0x0A} ** 32, T0);
    const sos = try guest.createSos(T0);
    _ = try guest.sendFrame(sos);
    var up: [hp.MAX_DATAGRAM]u8 = undefined;
    // No targets configured: nowhere to forward, counted as drop.
    const dgram = try hp.encode(.guest_sos_send, sos, &up);
    const tx = try relay.relayOneFrom(dgram, client_addr);
    try testing.expect(!tx.forwarded and !tx.responded);

    const st = relay.snapshot();
    try testing.expectEqual(@as(u64, 1), st.responded);
    try testing.expect(st.dropped >= 2); // null-source respond + targetless transmit
}

test "relay watchdog: stats, health and status marker" {
    var relay = try GringotdRelay.initOn(ephemeralAddr(), ephemeralAddr());
    defer relay.close();
    try testing.expect(relay.healthy());

    var req: [hp.MAX_DATAGRAM]u8 = undefined;
    const bad = try hp.encode(.guest_sos_send, &[_]u8{0} ** 10, &req);
    // BAD_PAYLOAD without a client: dropped, counted, never transmitted.
    const r = try relay.relayOneFrom(bad, null);
    try testing.expect(!r.forwarded and !r.responded);
    try testing.expectEqual(@as(u64, 1), relay.snapshot().dropped);

    // Liveness marker decodes as HOST_STATUS_RESP, never an ACK.
    var out: [hp.MAX_DATAGRAM]u8 = undefined;
    const rep = try relay.statusReport(&out);
    const m = try hp.decode(rep);
    try testing.expect(m.op == .host_status_resp);
    const dec = try hp.decodeStatus(m.payload);
    try testing.expect(!dec.acked);

    // Full target list fails closed instead of silently dropping a subnet.
    try relay.addTarget(ephemeralAddr());
    try relay.addTarget(ephemeralAddr());
    try relay.addTarget(ephemeralAddr());
    try relay.addTarget(ephemeralAddr());
    try testing.expectError(error.TargetsFull, relay.addTarget(ephemeralAddr()));
}
