//! BLE advertisement codec (no radio: pure bytes).
//!
//! Fragments a Gringots frame into <=180 B chunks and reassembles them.
//! Reassembly is keyed by frame NONCE, tolerates out-of-order delivery
//! and duplicates, and interleaves up to REASM_SLOTS concurrent frames.
//!
//! Radio transmission (LE Extended Advertising, ~1 Hz bursts per
//! PROTOCOL.md) needs platform BLE APIs and is NOT part of this module:
//! use `ble-encode` / `ble-decode` to move chunks across that gap.

const std = @import("std");
const t = @import("transport.zig");
const frame = @import("../protocol/frame.zig");

pub const MAX_CHUNKS: usize = t.max_chunks;

pub const Frag = struct {
    count: u8,
    lens: [MAX_CHUNKS]u8,
};

/// Split FRAME into chunks in OUT. NONCE is the frame's 0x05 value
/// (reassembly key). Returns count + per-chunk lengths.
pub fn fragment(frame_bytes: []const u8, nonce: [16]u8, out: *[MAX_CHUNKS][t.mtu.ble_chunk]u8) !Frag {
    if (frame_bytes.len == 0 or frame_bytes.len > t.MAX_FRAME) return error.BadFrameLength;
    const count: u8 = @intCast((frame_bytes.len + t.mtu.ble_payload - 1) / t.mtu.ble_payload);
    if (count == 0 or count > MAX_CHUNKS) return error.BadFrameLength;
    var lens = [_]u8{0} ** MAX_CHUNKS;
    var off: usize = 0;
    for (0..count) |i| {
        const rest = frame_bytes.len - off;
        const take = @min(rest, t.mtu.ble_payload);
        const c = &out[i];
        c[0] = t.chunk_magic;
        c[1] = count;
        c[2] = @intCast(i);
        @memcpy(c[3..19], &nonce);
        @memcpy(c[19 .. 19 + take], frame_bytes[off .. off + take]);
        lens[i] = @intCast(t.chunk_header_len + take);
        off += take;
    }
    return .{ .count = count, .lens = lens };
}

/// BLE AD manufacturer-specific field wrapping one chunk:
/// [len][0xFF][company_lo][company_hi][chunk...].
/// NOTE: 180 B chunks exceed classic 31 B advertising; the radio layer
/// MUST use LE Extended Advertising (or multiple AD sets).
pub fn buildAdv(chunk: []const u8, out: []u8) ![]u8 {
    if (chunk.len == 0 or chunk.len > t.mtu.ble_chunk) return error.BadChunk;
    const total = 1 + 2 + chunk.len; // type + company + payload
    if (total + 1 > out.len) return error.NoSpace;
    if (total > 255) return error.BadChunk;
    out[0] = @intCast(total);
    out[1] = 0xFF;
    std.mem.writeInt(u16, out[2..][0..2], t.company_id, .little);
    @memcpy(out[4 .. 4 + chunk.len], chunk);
    return out[0 .. 4 + chunk.len];
}

pub const ChunkError = error{
    BadMagic,
    BadTotal,
    BadIndex,
    BadLength,
    NoSlot,
    Mismatch,
};

const Slot = struct {
    active: bool = false,
    nonce: [16]u8 = [_]u8{0} ** 16,
    total: u8 = 0,
    got: u8 = 0, // bitmask of received indices
    lens: [MAX_CHUNKS]u16 = [_]u16{0} ** MAX_CHUNKS,
    data: [t.MAX_FRAME]u8 = [_]u8{0} ** t.MAX_FRAME,
};

pub const REASM_SLOTS: usize = 8;

/// Incremental reassembler. Feed chunks; returns the complete frame
/// (copied into FRAME_OUT) once all chunks arrived, else null.
pub const Reassembler = struct {
    slots: [REASM_SLOTS]Slot = [_]Slot{.{}} ** REASM_SLOTS,

    pub fn feed(self: *Reassembler, chunk: []const u8, frame_out: []u8) !?[]u8 {
        if (chunk.len < t.chunk_header_len or chunk.len > t.mtu.ble_chunk) return error.BadLength;
        if (chunk[0] != t.chunk_magic) return error.BadMagic;
        const total = chunk[1];
        const idx = chunk[2];
        if (total == 0 or total > MAX_CHUNKS) return error.BadTotal;
        if (idx >= total) return error.BadIndex;
        const payload = chunk[t.chunk_header_len..];
        if (payload.len > t.mtu.ble_payload) return error.BadLength;
        var nonce: [16]u8 = undefined;
        @memcpy(&nonce, chunk[3..19]);

        const slot = self.findOrAlloc(nonce, total) orelse return error.NoSlot;
        if (slot.total != total) return error.Mismatch;
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(idx));
        if (slot.got & bit != 0) {
            // Duplicate: must be identical to be harmless.
            const off = @as(usize, idx) * t.mtu.ble_payload;
            if (slot.lens[idx] != payload.len or !std.mem.eql(u8, slot.data[off .. off + payload.len], payload)) {
                return error.Mismatch;
            }
            return null;
        }
        const off = @as(usize, idx) * t.mtu.ble_payload;
        if (off + payload.len > slot.data.len) return error.BadLength;
        @memcpy(slot.data[off .. off + payload.len], payload);
        slot.lens[idx] = @intCast(payload.len);
        slot.got |= bit;

        var want: u8 = 0;
        for (0..total) |i| want |= @as(u8, 1) << @as(u3, @intCast(i));
        if (slot.got != want) return null;

        var total_len: usize = 0;
        for (0..total) |i| total_len += slot.lens[i];
        if (frame_out.len < total_len) return error.NoSpace;
        @memcpy(frame_out[0..total_len], slot.data[0..total_len]);
        slot.active = false;
        slot.got = 0;
        return frame_out[0..total_len];
    }

    fn findOrAlloc(self: *Reassembler, nonce: [16]u8, total: u8) ?*Slot {
        for (&self.slots) |*s| {
            if (s.active and std.mem.eql(u8, &s.nonce, &nonce)) return s;
        }
        for (&self.slots) |*s| {
            if (!s.active) {
                s.* = .{ .active = true, .nonce = nonce, .total = total };
                return s;
            }
        }
        return null;
    }
};

const testing = std.testing;

const SOS150 =
    "475201008d0101010220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b000408000000006b359d5805100102030405060708090a0b0c0d0e0f10ff4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000319d4099";

test "150 B frame fits one chunk, AD wraps it" {
    var raw: [256]u8 = undefined;
    const fr = try frame.hexDecode(SOS150, &raw);
    const nonce = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var chunks: [MAX_CHUNKS][t.mtu.ble_chunk]u8 = undefined;
    const f = try fragment(fr, nonce, &chunks);
    try testing.expectEqual(@as(u8, 1), f.count);
    try testing.expectEqual(@as(u8, 19 + 150), f.lens[0]);

    var ad: [256]u8 = undefined;
    const field = try buildAdv(chunks[0][0..f.lens[0]], &ad);
    try testing.expectEqual(@as(usize, 4 + 169), field.len);
    try testing.expectEqual(@as(u8, 0xFF), field[1]);

    var re = Reassembler{};
    var out: [600]u8 = undefined;
    const done = try re.feed(chunks[0][0..f.lens[0]], &out);
    try testing.expect(done != null);
    try testing.expectEqualSlices(u8, fr, done.?);
}

test "max frame fragments to 4, reassembles out-of-order with dups" {
    var big: [t.MAX_FRAME]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const nonce = [_]u8{0xAA} ** 16;
    var chunks: [MAX_CHUNKS][t.mtu.ble_chunk]u8 = undefined;
    const f = try fragment(&big, nonce, &chunks);
    try testing.expectEqual(@as(u8, 4), f.count);

    var re = Reassembler{};
    var out: [600]u8 = undefined;
    // Reverse order, each twice. The final chunk completes the frame.
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        const c = chunks[i][0..f.lens[i]];
        if (i == 0) {
            const done = try re.feed(c, &out);
            try testing.expect(done != null);
            try testing.expectEqualSlices(u8, &big, done.?);
            // Slot is freed on completion; a late duplicate starts over.
            try testing.expect(try re.feed(c, &out) == null);
        } else {
            try testing.expect(try re.feed(c, &out) == null);
            try testing.expect(try re.feed(c, &out) == null);
        }
    }
}

test "chunk errors: magic, total, index, conflicting duplicate" {
    var re = Reassembler{};
    var out: [600]u8 = undefined;
    var good: [30]u8 = .{ t.chunk_magic, 2, 0 } ++ [_]u8{7} ** 16 ++ [_]u8{9} ** 11;
    try testing.expect(try re.feed(&good, &out) == null);

    var bad = good;
    bad[0] = 0x00;
    try testing.expectError(error.BadMagic, re.feed(&bad, &out));
    bad = good;
    bad[1] = 0;
    try testing.expectError(error.BadTotal, re.feed(&bad, &out));
    bad = good;
    bad[2] = 5;
    try testing.expectError(error.BadIndex, re.feed(&bad, &out));

    // Conflicting duplicate (same idx, different bytes).
    var evil = good;
    evil[19] ^= 0xFF;
    try testing.expectError(error.Mismatch, re.feed(&evil, &out));
}

test "interleaved frames reassemble independently" {
    const n1 = [_]u8{1} ** 16;
    const n2 = [_]u8{2} ** 16;
    var f1b: [300]u8 = undefined;
    var f2b: [300]u8 = undefined;
    for (&f1b, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    for (&f2b, 0..) |*b, i| b.* = @intCast(255 - (i & 0xFF));
    var c1: [MAX_CHUNKS][t.mtu.ble_chunk]u8 = undefined;
    var c2: [MAX_CHUNKS][t.mtu.ble_chunk]u8 = undefined;
    const g1 = try fragment(&f1b, n1, &c1);
    const g2 = try fragment(&f2b, n2, &c2);
    try testing.expectEqual(@as(u8, 2), g1.count);
    try testing.expectEqual(@as(u8, 2), g2.count);

    var re = Reassembler{};
    var out: [600]u8 = undefined;
    try testing.expect(try re.feed(c1[0][0..g1.lens[0]], &out) == null);
    try testing.expect(try re.feed(c2[0][0..g2.lens[0]], &out) == null);
    const d2 = try re.feed(c2[1][0..g2.lens[1]], &out);
    try testing.expectEqualSlices(u8, &f2b, d2.?);
    const d1 = try re.feed(c1[1][0..g1.lens[1]], &out);
    try testing.expectEqualSlices(u8, &f1b, d1.?);
}
