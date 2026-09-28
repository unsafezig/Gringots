//! Acoustic packet format (concrete form of PROTOCOL.md Section 11 audio).
//!
//! Bit layout after the attention gap:
//!   preamble:  64 alternating bits (1,0,1,0...) — AGC + clock settle
//!   sync:      32-bit word SYNC (searched fuzzily, <= 2 bit errors)
//!   len:       16-bit BE = total RS codeword bytes (multiple of 255, <= 765)
//!   flen:      16-bit BE = Gringots frame bytes (<= 521)
//!   payload:   RS(255,223) codewords covering the frame (shortened last)
//!
//! Unknown sounds and failed decodes are NEVER acknowledgements: this
//! layer returns frames or errors; the ACK decision lives in msg.zig.
//!
//! Limitation: file-grade timing (no clock-drift tracking). Over a live
//! microphone, add per-bit timing recovery; the preamble/sync structure
//! already supports it.

const std = @import("std");
const rs = @import("rs.zig");
const transport = @import("../transports/transport.zig");

pub const PREAMBLE_BITS: usize = 64;
pub const SYNC: u32 = 0xD5B7A25A;
pub const SYNC_BITS: usize = 32;
pub const HEADER_BITS: usize = PREAMBLE_BITS + SYNC_BITS + 16 + 16;
pub const MAX_BLOCKS: usize = 3;
pub const MAX_CODEWORD_BYTES: usize = MAX_BLOCKS * rs.CODE_LEN; // 765
pub const MAX_PACKET_BITS: usize = HEADER_BITS + MAX_CODEWORD_BYTES * 8; // 6248

pub const PacketInfo = struct {
    nblocks: usize,
    codeword_len: usize,
    frame_len: usize,
};

/// Split a frame into RS block data-lengths. Returns count + lengths.
pub fn planBlocks(frame_len: usize) ![MAX_BLOCKS]usize {
    if (frame_len == 0 or frame_len > transport.MAX_FRAME) return error.BadFrameLength;
    var ks = [_]usize{0} ** MAX_BLOCKS;
    var rest = frame_len;
    var n: usize = 0;
    while (rest > 0) {
        const k = @min(rest, rs.DATA_LEN);
        ks[n] = k;
        rest -= k;
        n += 1;
    }
    return ks;
}

/// Frame bytes -> packet bits (0/1 per byte). OUT must hold
/// HEADER_BITS + codewords*8; TMP must hold codeword bytes.
pub fn encodePacket(frame_bytes: []const u8, out_bits: []u8, tmp_cw: []u8) ![]u8 {
    const ks = try planBlocks(frame_bytes.len);
    var nblocks: usize = 0;
    for (ks) |k| {
        if (k == 0) break;
        nblocks += 1;
    }
    const cw_len = nblocks * rs.CODE_LEN;
    if (tmp_cw.len < cw_len) return error.NoSpace;
    if (out_bits.len < HEADER_BITS + cw_len * 8) return error.NoSpace;

    var off = frame_bytes;
    for (0..nblocks) |b| {
        const k = ks[b];
        // Full 255-byte codeword per block (leading-zero padded).
        try rs.encodeBlock(off[0..k], tmp_cw[b * rs.CODE_LEN ..][0..rs.CODE_LEN]);
        off = off[k..];
    }

    var p: usize = 0;
    for (0..PREAMBLE_BITS) |i| {
        out_bits[p] = if (i % 2 == 0) 1 else 0;
        p += 1;
    }
    for (0..SYNC_BITS) |i| {
        out_bits[p] = @intCast((SYNC >> @intCast(SYNC_BITS - 1 - i)) & 1);
        p += 1;
    }
    appendU16(out_bits[p..], @intCast(cw_len));
    p += 16;
    appendU16(out_bits[p..], @intCast(frame_bytes.len));
    p += 16;
    for (tmp_cw[0..cw_len]) |byte| {
        for (0..8) |i| {
            out_bits[p] = (byte >> @intCast(7 - i)) & 1;
            p += 1;
        }
    }
    return out_bits[0..p];
}

fn appendU16(bits: []u8, v: u16) void {
    for (0..16) |i| bits[i] = @intCast((v >> @intCast(15 - i)) & 1);
}

fn readU16(bits: []const u8) u16 {
    var v: u16 = 0;
    for (0..16) |i| v = (v << 1) | bits[i];
    return v;
}

fn hamming32(a: u32, b: u32) u8 {
    return @popCount(a ^ b);
}

fn syncAt(bits: []const u8, pos: usize) u32 {
    var w: u32 = 0;
    for (0..SYNC_BITS) |i| w = (w << 1) | bits[pos + i];
    return w;
}

/// Bitstream -> frame bytes. Searches sync candidates (<=2 errors, best
/// first), RS-decodes each, returns the first fully valid frame.
/// Garbage / silence -> error.NoSignal. Never an acknowledgement.
pub fn decodePacket(bits: []const u8, frame_out: []u8, tmp_cw: []u8) ![]u8 {
    if (bits.len < HEADER_BITS) return error.NoSignal;
    // Collect candidates: (errors, position), capped.
    var cand_err: [32]u8 = undefined;
    var cand_pos: [32]usize = undefined;
    var ncand: usize = 0;
    var pos: usize = 0;
    while (pos + HEADER_BITS <= bits.len and ncand < cand_err.len) : (pos += 1) {
        // Preamble sanity: first 64 bits should mostly alternate.
        // Cheap gate before the expensive path: require sync closeness.
        const e = hamming32(syncAt(bits, pos + PREAMBLE_BITS), SYNC);
        if (e <= 2) {
            // Insert sorted by error count.
            var at = ncand;
            while (at > 0 and cand_err[at - 1] > e) {
                cand_err[at] = cand_err[at - 1];
                cand_pos[at] = cand_pos[at - 1];
                at -= 1;
            }
            cand_err[at] = e;
            cand_pos[at] = pos;
            ncand += 1;
        }
    }
    if (ncand == 0) return error.NoSignal;

    for (cand_pos[0..ncand]) |cp| {
        const hdr = cp + PREAMBLE_BITS + SYNC_BITS;
        const cw_len: usize = readU16(bits[hdr..][0..16]);
        const frame_len: usize = readU16(bits[hdr + 16 ..][0..16]);
        if (cw_len == 0 or cw_len % rs.CODE_LEN != 0) continue;
        if (cw_len > MAX_CODEWORD_BYTES) continue;
        if (frame_len == 0 or frame_len > transport.MAX_FRAME) continue;
        if (frame_out.len < frame_len) continue;
        const nblocks = cw_len / rs.CODE_LEN;
        const body_start = hdr + 32;
        if (body_start + cw_len * 8 > bits.len) continue;
        if (tmp_cw.len < cw_len) continue;
        // Bits -> codeword bytes.
        for (0..cw_len) |i| {
            var byte: u8 = 0;
            for (0..8) |j| byte = (byte << 1) | bits[body_start + i * 8 + j];
            tmp_cw[i] = byte;
        }
        // RS-decode blocks; frame lengths must agree with header.
        var ok = true;
        var foff: usize = 0;
        var coff: usize = 0;
        var remaining = frame_len;
        for (0..nblocks) |_| {
            const k = @min(remaining, rs.DATA_LEN);
            rs.decodeBlock(tmp_cw[coff .. coff + rs.CODE_LEN], frame_out[foff .. foff + k]) catch {
                ok = false;
                break;
            };
            foff += k;
            coff += rs.CODE_LEN;
            remaining -= k;
        }
        if (ok and remaining == 0 and foff == frame_len) return frame_out[0..frame_len];
    }
    return error.NoSignal;
}

const testing = std.testing;
const fsk = @import("fsk.zig");

test "packet bit layout sizes" {
    // 150 B frame -> 1 full block (255 codeword bytes).
    var bits: [MAX_PACKET_BITS]u8 = undefined;
    var cw: [MAX_CODEWORD_BYTES]u8 = undefined;
    var fr: [150]u8 = undefined;
    for (&fr, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const p = try encodePacket(&fr, &bits, &cw);
    try testing.expectEqual(HEADER_BITS + 255 * 8, p.len);
    // 521 B frame -> 3 blocks -> 765 cw bytes.
    var big: [521]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast((i * 3) & 0xFF);
    const p2 = try encodePacket(&big, &bits, &cw);
    try testing.expectEqual(HEADER_BITS + 765 * 8, p2.len);
}

test "decode recovers frame, rejects garbage and short input" {
    var bits: [MAX_PACKET_BITS]u8 = undefined;
    var cw: [MAX_CODEWORD_BYTES]u8 = undefined;
    var fr: [150]u8 = undefined;
    for (&fr, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xFF);
    const p = try encodePacket(&fr, &bits, &cw);

    var fout: [600]u8 = undefined;
    var tmp: [MAX_CODEWORD_BYTES]u8 = undefined;
    const got = try decodePacket(p, &fout, &tmp);
    try testing.expectEqualSlices(u8, &fr, got);

    // Pure garbage of the same length: no false decode.
    var seed: u64 = 99;
    var rnd: [MAX_PACKET_BITS]u8 = undefined;
    for (rnd[0..p.len]) |*b| {
        seed +%= 0x9E3779B97F4A7C15;
        b.* = @intCast((seed >> 17) & 1);
    }
    try testing.expectError(error.NoSignal, decodePacket(rnd[0..p.len], &fout, &tmp));
    try testing.expectError(error.NoSignal, decodePacket(p[0..10], &fout, &tmp));
    try testing.expectError(error.BadFrameLength, planBlocks(0));
    try testing.expectError(error.BadFrameLength, planBlocks(522));
}

test "full acoustic chain: bits -> samples -> noise -> bits -> frame" {
    const modem = try fsk.Modem.init(44100);
    // A real 141-byte SOS body (structure vector layout, arbitrary bytes).
    var fr: [141]u8 = undefined;
    for (&fr, 0..) |*b, i| b.* = @intCast((i * 13 + 5) & 0xFF);
    var bits: [MAX_PACKET_BITS]u8 = undefined;
    var cw: [MAX_CODEWORD_BYTES]u8 = undefined;
    const pkt = try encodePacket(&fr, &bits, &cw);

    var samples: [MAX_PACKET_BITS * 147]i16 = undefined;
    const sig = modem.modulate(pkt, &samples);
    try testing.expectEqual(pkt.len * 147, sig.len);

    // Heavy channel: uniform noise ±4000 (~1/3 full scale) + dropout burst.
    var seed: u64 = 0xBEEF;
    for (sig) |*s| {
        seed +%= 0x9E3779B97F4A7C15;
        const nz: i32 = @intCast((seed >> 11) % 8001);
        const v: i32 = @as(i32, @intCast(s.*)) + nz - 4000;
        s.* = @intCast(@max(-32768, @min(32767, v)));
    }
    // 0.1 s dropout mid-packet (burst erasure).
    const drop_at = sig.len / 2;
    const drop_len: usize = 4410;
    for (sig[drop_at .. drop_at + drop_len]) |*s| s.* = 0;

    var got_bits: [MAX_PACKET_BITS]u8 = undefined;
    const dbits = modem.demodulate(sig, &got_bits, null);
    try testing.expectEqual(pkt.len, dbits.len);

    var fout: [600]u8 = undefined;
    var tmp: [MAX_CODEWORD_BYTES]u8 = undefined;
    const got = try decodePacket(dbits, &fout, &tmp);
    try testing.expectEqualSlices(u8, &fr, got);
}
