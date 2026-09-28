//! gringotsd service surface (zinux/GRINGOTS_SERVICE.md v1).
//!
//! Platform-neutral logic over the existing agent core: the same code
//! runs against the fake host bridge (host tests), the desktop bridge
//! (Phase 4), and later the Zinux syscall adapter + Android bridge.
//! No I/O, no clock calls — the host drives `now` and moves bytes.

const std = @import("std");
const root = @import("gringots_root");
const agent = root.service;
const msg = root.msg;
const frame = root.frame;
const location = root.alocation;

pub const VerifyVerdict = union(enum) {
    valid: msg.Message,
    invalid: []const u8, // short reason, e.g. "EXPIRED", "BAD_SIGNATURE"
};

pub fn reasonOf(err: anyerror) []const u8 {
    return switch (err) {
        error.CrcMismatch => "BAD_CRC",
        error.BadMagic => "BAD_MAGIC",
        error.BadVersion => "BAD_VERSION",
        error.BadLength => "BAD_LENGTH",
        error.Truncated => "BAD_LENGTH",
        error.MissingField, error.BadFieldLength, error.DuplicateField, error.SignatureNotLast, error.SignatureMissing, error.UnknownMsgType => "MALFORMED_TLV",
        error.SignatureVerificationFailed => "BAD_SIGNATURE",
        error.Expired => "EXPIRED",
        error.NotYetValid => "NOT_YET_VALID",
        error.BadTimeWindow => "BAD_TIME",
        error.TtlTooLong => "TTL_TOO_LONG",
        error.LocationInSos, error.LocationRequired, error.SessionRequired, error.RefRequired => "SEMANTICS",
        else => "INVALID",
    };
}

pub const ReceiveOutcome = enum { acked, no_ack };

pub const Status = struct {
    acked: bool,
    pending: usize,
    last_nonce: ?[16]u8,
};

/// gringotsd instance: agent core + capability set for this phase.
pub const Service = struct {
    agent: agent.Service,
    can_send: bool = true,
    can_receive: bool = true,
    can_datagram: bool = true,

    pub fn init(seed: [32]u8, now: u64) !Service {
        return .{ .agent = try agent.Service.init(.{ .seed = seed }, now) };
    }

    /// CREATE_SOS: tick + take SOS frame. Caller copies the returned slice
    /// before the next call (outbox storage).
    pub fn createSos(self: *Service, now: u64) ![]const u8 {
        if (!self.can_send) return error.Denied;
        try self.agent.tick(now);
        return self.agent.takeFrame() orelse error.NoFrame;
    }

    /// VERIFY_FRAME: local verdict, never transmits.
    pub fn verifyFrame(_: *Service, raw: []const u8, now: u64) VerifyVerdict {
        const m = msg.verifyFrame(raw, now) catch |err| {
            return .{ .invalid = reasonOf(err) };
        };
        return .{ .valid = m };
    }

    /// DESCRIBE_FRAME: structure-only text (unverified).
    pub fn describeFrame(_: *Service, raw: []const u8, out: []u8) ![]u8 {
        const dec = frame.decodeFrame(raw) catch |err| return err;
        const m = msg.parseBody(dec.body) catch |err| return err;
        return msg.formatDebug(&m, out);
    }

    /// SEND_FRAME: shape-check, then hand bytes to the host bridge.
    /// Returns the frame on success (caller wraps it in GUEST_SOS_SEND).
    pub fn sendFrame(self: *Service, raw: []const u8) ![]const u8 {
        if (!self.can_send or !self.can_datagram) return error.Denied;
        if (raw.len == 0 or raw.len > 521) return error.BadPayload;
        _ = frame.decodeFrame(raw) catch return error.BadPayload;
        return raw;
    }

    /// RECEIVE_FRAME: feed one HOST_FRAME_DELIVER payload.
    pub fn receiveFrame(self: *Service, raw: []const u8, now: u64) ReceiveOutcome {
        if (!self.can_receive) return .no_ack;
        const was = self.agent.acked;
        self.agent.onFrame(raw, now) catch return .no_ack;
        return if (!was and self.agent.acked) .acked else .no_ack;
    }

    pub fn getStatus(self: *const Service) Status {
        return .{
            .acked = self.agent.acked,
            .pending = self.agent.pendingConsents(),
            .last_nonce = self.agent.last_sos_nonce,
        };
    }
};

const testing = std.testing;
const T0: u64 = 1798675200 + 12 * 3600;

test "create + verify + describe round-trip" {
    var s = try Service.init([_]u8{3} ** 32, T0);
    const sos = try s.createSos(T0);
    var copy: [600]u8 = undefined;
    @memcpy(copy[0..sos.len], sos);
    const fr = copy[0..sos.len];
    const v = s.verifyFrame(fr, T0);
    try testing.expect(v == .valid);
    try testing.expect(v.valid.msg_type == .sos);
    var text: [512]u8 = undefined;
    const t = try s.describeFrame(fr, &text);
    try testing.expect(std.mem.startsWith(u8, t, "GRINGOTTS/1 TYPE=CIVILIAN_SOS"));
}

test "verify maps failures, never panics" {
    var s = try Service.init([_]u8{3} ** 32, T0);
    const sos = try s.createSos(T0);
    var copy: [600]u8 = undefined;
    @memcpy(copy[0..sos.len], sos);
    // Corrupt CRC -> BAD_CRC.
    copy[copy[0..sos.len].len - 1] ^= 0x01;
    const v = s.verifyFrame(copy[0..sos.len], T0);
    try testing.expect(v == .invalid);
    // Empty -> INVALID.
    const v2 = s.verifyFrame(&[_]u8{}, T0);
    try testing.expect(v2 == .invalid);
}

test "denied without capabilities, oversize never queued" {
    var s = try Service.init([_]u8{3} ** 32, T0);
    s.can_send = false;
    s.can_datagram = false;
    try testing.expectError(error.Denied, s.createSos(T0));
    try testing.expectError(error.Denied, s.sendFrame(&[_]u8{0} ** 150));
    s.can_send = true;
    s.can_datagram = true;
    try testing.expectError(error.BadPayload, s.sendFrame(&[_]u8{0} ** 522));
}
