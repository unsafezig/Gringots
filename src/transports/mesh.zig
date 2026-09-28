//! Local mesh relay: flood with TTL + nonce dedupe.
//!
//! Envelope: [MAGIC 'M'][TTL] ++ Gringots frame. Relays forward with
//! TTL-1 after validating framing and dropping duplicates / expired TTL.
//! Loop safety comes from the replay cache, not from topology: any mesh
//! that hears its own forward drops it as a duplicate.

const std = @import("std");
const t = @import("transport.zig");
const frame = @import("../protocol/frame.zig");
const replay = @import("../replay/cache.zig");

pub const MAGIC: u8 = t.mesh_magic;
pub const OVERHEAD: usize = t.mtu.mesh_overhead;

/// Wrap a frame with a TTL envelope. TTL must be 1..max_ttl.
pub fn wrap(frame_bytes: []const u8, ttl: u8, out: []u8) ![]u8 {
    if (ttl == 0 or ttl > t.max_ttl) return error.BadTtl;
    if (frame_bytes.len == 0 or frame_bytes.len > t.MAX_FRAME) return error.BadFrameLength;
    if (out.len < frame_bytes.len + OVERHEAD) return error.NoSpace;
    out[0] = MAGIC;
    out[1] = ttl;
    @memcpy(out[OVERHEAD .. OVERHEAD + frame_bytes.len], frame_bytes);
    return out[0 .. OVERHEAD + frame_bytes.len];
}

pub const Packet = struct {
    ttl: u8,
    frame: []const u8,
};

/// Split envelope. Non-mesh datagrams (direct Gringots frames) fail with
/// error.NotMesh — the caller may still handle them as direct traffic.
pub fn unwrap(packet: []const u8) !Packet {
    if (packet.len < OVERHEAD + 1) return error.NotMesh;
    if (packet[0] != MAGIC) return error.NotMesh;
    const ttl = packet[1];
    if (ttl == 0 or ttl > t.max_ttl) return error.BadTtl;
    return .{ .ttl = ttl, .frame = packet[OVERHEAD..] };
}

/// Flood relay decision. Returns the TTL to forward with, or null to drop.
/// Drops: TTL exhausted, duplicate (ID, NONCE), unparseable body.
/// NOTE: framing (CRC) must be checked by the caller before this — see CLI.
pub const Relay = struct {
    cache: replay.Cache = .{},

    pub fn shouldRelay(
        self: *Relay,
        ephemeral_id: [32]u8,
        nonce: [16]u8,
        ttl: u8,
        expires: u64,
        now: u64,
    ) ?u8 {
        // A relay must emit a valid envelope, whose TTL is at least one.
        // Therefore a packet at its last hop is delivered locally but not
        // forwarded with the invalid value zero.
        if (ttl <= 1) return null;
        if (self.cache.check(ephemeral_id, nonce, expires, now) == .duplicate) return null;
        return ttl - 1;
    }
};

const testing = std.testing;

test "envelope round-trips, rejects direct frames and bad ttl" {
    const fr = [_]u8{ 0x47, 0x52, 0x01 } ++ [_]u8{0} ** 65;
    var out: [600]u8 = undefined;
    const pkt = try wrap(&fr, 3, &out);
    try testing.expectEqual(@as(usize, fr.len + 2), pkt.len);
    const p = try unwrap(pkt);
    try testing.expectEqual(@as(u8, 3), p.ttl);
    try testing.expectEqualSlices(u8, &fr, p.frame);

    try testing.expectError(error.NotMesh, unwrap(&fr));
    try testing.expectError(error.BadTtl, wrap(&fr, 0, &out));
    try testing.expectError(error.BadTtl, wrap(&fr, 9, &out));
    var bad = pkt;
    bad[1] = 0;
    try testing.expectError(error.BadTtl, unwrap(bad[0..pkt.len]));
}

test "relay forwards once, then dedupes, ttl counts down" {
    var r = Relay{};
    const id = [_]u8{1} ** 32;
    const n = [_]u8{2} ** 16;
    try testing.expectEqual(@as(?u8, 2), r.shouldRelay(id, n, 3, 9999, 1000));
    try testing.expect(r.shouldRelay(id, n, 3, 9999, 1000) == null); // duplicate
    try testing.expect(r.shouldRelay(id, n, 0, 9999, 1000) == null); // ttl spent
    // TTL=1 is the last hop and must not be forwarded as TTL=0.
    const n2 = [_]u8{3} ** 16;
    try testing.expect(r.shouldRelay(id, n2, 1, 9999, 1000) == null);
}

test "mesh overhead keeps max frame inside udp payload" {
    try testing.expect(t.MAX_FRAME + OVERHEAD <= t.mtu.udp_payload);
    // Envelope + CRC-checked frame: framing check composes.
    var body: [68]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var fr: [128]u8 = undefined;
    const enc = try frame.encodeFrame(&body, &fr);
    var pkt: [600]u8 = undefined;
    const wrapped = try wrap(enc, 8, &pkt);
    const p = try unwrap(wrapped);
    const dec = try frame.decodeFrame(p.frame);
    try testing.expectEqualSlices(u8, enc, p.frame);
    try testing.expectEqual(@as(u16, 68), dec.body_len);
}
