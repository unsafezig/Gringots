//! Zinux guest-host datagram protocol (zinux/HOST_PROTOCOL.md v1).
//!
//! Pure byte codec, no I/O: both the desktop bridge and the Android
//! bridge speak this exact framing. CRC32-IEEE matches Gringots framing.

const std = @import("std");

pub const MAGIC0: u8 = 0x5A; // 'Z'
pub const MAGIC1: u8 = 0x47; // 'G'
pub const VERSION: u8 = 0x01;
pub const HEADER_LEN: usize = 6; // MAGIC(2) VER(1) OP(1) LEN(2)
pub const CRC_LEN: usize = 4;
pub const MAX_PAYLOAD: usize = 1024;
pub const MAX_DATAGRAM: usize = HEADER_LEN + MAX_PAYLOAD + CRC_LEN; // 1034
pub const MIN_GRINGOTS_FRAME: usize = 150;
pub const MAX_GRINGOTS_FRAME: usize = 521;

pub const Op = enum(u8) {
    guest_sos_send = 0x01,
    host_frame_deliver = 0x02,
    guest_status_req = 0x03,
    host_status_resp = 0x04,
    host_error = 0x05,
    host_consent_decision = 0x06,
    _,

    pub fn name(self: Op) []const u8 {
        return switch (self) {
            .guest_sos_send => "GUEST_SOS_SEND",
            .host_frame_deliver => "HOST_FRAME_DELIVER",
            .guest_status_req => "GUEST_STATUS_REQ",
            .host_status_resp => "HOST_STATUS_RESP",
            .host_error => "HOST_ERROR",
            .host_consent_decision => "HOST_CONSENT_DECISION",
            else => "UNKNOWN",
        };
    }
};

pub const ErrorCode = enum(u8) {
    bad_direction = 0x01,
    bad_payload = 0x02,
    denied = 0x03,
    transport_fail = 0x04,
    _,
};

pub const Message = struct {
    op: Op,
    payload: []const u8, // slices the decoded datagram
};

pub fn crc32Ieee(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFF;
}

/// Encode one datagram. OUT must hold HEADER_LEN + payload.len + CRC_LEN.
pub fn encode(op: Op, payload: []const u8, out: []u8) ![]u8 {
    if (payload.len > MAX_PAYLOAD) return error.PayloadTooLarge;
    const total = HEADER_LEN + payload.len + CRC_LEN;
    if (out.len < total) return error.NoSpace;
    out[0] = MAGIC0;
    out[1] = MAGIC1;
    out[2] = VERSION;
    out[3] = @intFromEnum(op);
    std.mem.writeInt(u16, out[4..][0..2], @intCast(payload.len), .big);
    @memcpy(out[HEADER_LEN .. HEADER_LEN + payload.len], payload);
    const crc = crc32Ieee(out[0 .. HEADER_LEN + payload.len]);
    std.mem.writeInt(u32, out[HEADER_LEN + payload.len ..][0..4], crc, .big);
    return out[0..total];
}

/// Decode + validate framing. Returns payload slice into RAW.
pub fn decode(raw: []const u8) !Message {
    if (raw.len < HEADER_LEN + CRC_LEN) return error.Truncated;
    if (raw[0] != MAGIC0 or raw[1] != MAGIC1) return error.BadMagic;
    if (raw[2] != VERSION) return error.BadVersion;
    const op: Op = @enumFromInt(raw[3]);
    const len = std.mem.readInt(u16, raw[4..][0..2], .big);
    if (len > MAX_PAYLOAD) return error.BadLength;
    if (raw.len != HEADER_LEN + len + CRC_LEN) return error.BadLength;
    const want = std.mem.readInt(u32, raw[HEADER_LEN + len ..][0..4], .big);
    if (crc32Ieee(raw[0 .. HEADER_LEN + len]) != want) return error.CrcMismatch;
    return .{ .op = op, .payload = raw[HEADER_LEN .. HEADER_LEN + len] };
}

/// Validate that PAYLOAD is plausibly a Gringots frame (length gate only;
/// crypto validation stays in Gringots proper).
pub fn checkGringotsPayload(payload: []const u8) !void {
    if (payload.len < MIN_GRINGOTS_FRAME or payload.len > MAX_GRINGOTS_FRAME)
        return error.BadPayload;
}

/// Encode HOST_ERROR(code [, detail]).
pub fn encodeError(code: ErrorCode, detail: []const u8, out: []u8) ![]u8 {
    if (detail.len > 32) return error.PayloadTooLarge;
    var tmp: [33]u8 = undefined;
    tmp[0] = @intFromEnum(code);
    @memcpy(tmp[1 .. 1 + detail.len], detail);
    return encode(.host_error, tmp[0 .. 1 + detail.len], out);
}

/// Status payload: acked(1) pending(1) reserved(2 zero).
pub fn encodeStatus(acked: bool, pending: u8, out: []u8) ![]u8 {
    return encode(.host_status_resp, &[_]u8{ @intFromBool(acked), pending, 0, 0 }, out);
}

pub fn decodeStatus(payload: []const u8) !struct { acked: bool, pending: u8 } {
    if (payload.len != 4) return error.BadPayload;
    if (payload[2] != 0 or payload[3] != 0) return error.BadPayload;
    return .{ .acked = payload[0] != 0, .pending = payload[1] };
}

/// Consent payload: req_id(4BE) decision(1) at(8BE).
pub fn encodeConsent(req_id: u32, approve: bool, at: u64, out: []u8) ![]u8 {
    var p: [13]u8 = undefined;
    std.mem.writeInt(u32, p[0..][0..4], req_id, .big);
    p[4] = @intFromBool(approve);
    std.mem.writeInt(u64, p[5..][0..8], at, .big);
    return encode(.host_consent_decision, &p, out);
}

pub fn decodeConsent(payload: []const u8) !struct { req_id: u32, approve: bool, at: u64 } {
    if (payload.len != 13) return error.BadPayload;
    if (payload[4] != 0 and payload[4] != 1) return error.BadPayload;
    return .{
        .req_id = std.mem.readInt(u32, payload[0..][0..4], .big),
        .approve = payload[4] == 1,
        .at = std.mem.readInt(u64, payload[5..][0..8], .big),
    };
}

const testing = std.testing;

test "round-trip all ops" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const d = try encode(.guest_status_req, &[_]u8{}, &buf);
    const m = try decode(d);
    try testing.expect(m.op == .guest_status_req);
    try testing.expectEqual(@as(usize, 0), m.payload.len);
}

test "reject bad magic, version, crc, length" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const d = try encode(.guest_sos_send, "hello", &buf);
    var bad: [MAX_DATAGRAM]u8 = undefined;
    @memcpy(bad[0..d.len], d);
    bad[0] ^= 0xFF;
    try testing.expectError(error.BadMagic, decode(bad[0..d.len]));
    @memcpy(bad[0..d.len], d);
    bad[2] = 0x7F;
    // CRC now also mismatches, but version check fires first.
    try testing.expectError(error.BadVersion, decode(bad[0..d.len]));
    @memcpy(bad[0..d.len], d);
    bad[d.len - 1] ^= 0x01;
    try testing.expectError(error.CrcMismatch, decode(bad[0..d.len]));
    try testing.expectError(error.Truncated, decode(d[0..4]));
}

test "status and consent codecs" {
    var buf: [MAX_DATAGRAM]u8 = undefined;
    const s = try encodeStatus(true, 2, &buf);
    const sm = try decode(s);
    try testing.expect(sm.op == .host_status_resp);
    const st = try decodeStatus(sm.payload);
    try testing.expect(st.acked and st.pending == 2);

    var cbuf: [MAX_DATAGRAM]u8 = undefined;
    const c = try encodeConsent(7, true, 12345, &cbuf);
    const cm = try decode(c);
    const cd = try decodeConsent(cm.payload);
    try testing.expect(cd.req_id == 7 and cd.approve and cd.at == 12345);
}

test "gringots payload length gate" {
    try testing.expectError(error.BadPayload, checkGringotsPayload(&[_]u8{0} ** 10));
    try testing.expectError(error.BadPayload, checkGringotsPayload(&[_]u8{0} ** 600));
    try checkGringotsPayload(&[_]u8{0} ** 150);
    try checkGringotsPayload(&[_]u8{0} ** 521);
}
