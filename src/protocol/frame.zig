//! Transport-independent framing + TLV codec (PROTOCOL.md Sections 3-4).
//!
//! Layout: MAGIC(2) | VER(1) | MLEN u16BE | BODY(MLEN) | CRC32 u32BE.
//! CRC32 is IEEE (IsoHdlc), computed over MAGIC..BODY.
//!
//! All functions operate on caller-provided buffers: no allocator needed,
//! suitable for constrained civilian devices.

const std = @import("std");
const types = @import("types.zig");

pub const HEADER_LEN: usize = 5;
pub const CRC_LEN: usize = 4;

pub const FrameError = error{
    BadMagic,
    BadVersion,
    BadLength,
    Truncated,
    TrailingBytes,
    CrcMismatch,
};

pub const TlvError = error{
    TruncatedTlv,
    ValueTooLong,
    NoSpace,
};

/// Encode BODY into OUT as a full frame. Returns the frame slice.
pub fn encodeFrame(body: []const u8, out: []u8) (FrameError || TlvError)![]u8 {
    if (body.len < types.MIN_BODY or body.len > types.MAX_BODY) return error.BadLength;
    const total = HEADER_LEN + body.len + CRC_LEN;
    if (out.len < total) return error.NoSpace;
    out[0] = types.MAGIC0;
    out[1] = types.MAGIC1;
    out[2] = types.VERSION;
    std.mem.writeInt(u16, out[3..][0..2], @intCast(body.len), .big);
    @memcpy(out[HEADER_LEN .. HEADER_LEN + body.len], body);
    const crc = std.hash.Crc32.hash(out[0 .. HEADER_LEN + body.len]);
    std.mem.writeInt(u32, out[HEADER_LEN + body.len ..][0..4], crc, .big);
    return out[0..total];
}

pub const DecodedFrame = struct {
    body: []const u8,
    body_len: u16,
};

/// Validate a raw frame. Returns BODY slice on success.
/// The frame must be exact-length: no leading/trailing bytes.
pub fn decodeFrame(raw: []const u8) (FrameError || TlvError)!DecodedFrame {
    if (raw.len < HEADER_LEN + CRC_LEN) return error.Truncated;
    if (raw[0] != types.MAGIC0 or raw[1] != types.MAGIC1) return error.BadMagic;
    if (raw[2] != types.VERSION) return error.BadVersion;
    const mlen = std.mem.readInt(u16, raw[3..][0..2], .big);
    if (mlen < types.MIN_BODY or mlen > types.MAX_BODY) return error.BadLength;
    const total: usize = HEADER_LEN + mlen + CRC_LEN;
    if (raw.len < total) return error.Truncated;
    if (raw.len > total) return error.TrailingBytes;
    const want = std.mem.readInt(u32, raw[HEADER_LEN + mlen ..][0..4], .big);
    const got = std.hash.Crc32.hash(raw[0 .. HEADER_LEN + mlen]);
    if (want != got) return error.CrcMismatch;
    return .{ .body = raw[HEADER_LEN .. HEADER_LEN + mlen], .body_len = mlen };
}

/// Append one TLV to BUF at POS. Returns the new position.
pub fn appendTlv(buf: []u8, pos: usize, tag: u8, value: []const u8) TlvError!usize {
    if (value.len > 255) return error.ValueTooLong;
    if (pos + 2 + value.len > buf.len) return error.NoSpace;
    buf[pos] = tag;
    buf[pos + 1] = @intCast(value.len);
    @memcpy(buf[pos + 2 .. pos + 2 + value.len], value);
    return pos + 2 + value.len;
}

pub const Tlv = struct {
    tag: u8,
    value: []const u8,
};

/// Iterate TLVs in BODY. POS starts at 0; returns null at end.
pub fn nextTlv(body: []const u8, pos: *usize) TlvError!?Tlv {
    if (pos.* == body.len) return null;
    if (pos.* + 2 > body.len) return error.TruncatedTlv;
    const tag = body[pos.*];
    const len: usize = body[pos.* + 1];
    if (pos.* + 2 + len > body.len) return error.TruncatedTlv;
    const v = body[pos.* + 2 .. pos.* + 2 + len];
    pos.* += 2 + len;
    return .{ .tag = tag, .value = v };
}

const HEXDIGITS = "0123456789abcdef";

/// Lowercase hex encode. OUT must be >= 2x input.
pub fn hexEncode(bytes: []const u8, out: []u8) TlvError![]u8 {
    if (out.len < bytes.len * 2) return error.NoSpace;
    for (bytes, 0..) |b, i| {
        out[2 * i] = HEXDIGITS[b >> 4];
        out[2 * i + 1] = HEXDIGITS[b & 0x0F];
    }
    return out[0 .. bytes.len * 2];
}

pub const HexError = error{ BadHex, NoSpace };

fn hexVal(c: u8) HexError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.BadHex,
    };
}

/// Hex decode (upper or lower case). OUT must hold s.len/2 bytes.
pub fn hexDecode(s: []const u8, out: []u8) HexError![]u8 {
    if (s.len % 2 != 0) return error.BadHex;
    if (out.len < s.len / 2) return error.NoSpace;
    for (0..s.len / 2) |i| {
        const hi = try hexVal(s[2 * i]);
        const lo = try hexVal(s[2 * i + 1]);
        out[i] = hi << 4 | lo;
    }
    return out[0 .. s.len / 2];
}

// ---------------------------------------------------------------------------
// Tests: golden vectors from PROTOCOL.md Section 8 (structure-valid,
// signature-zeroed). These pin the CRC and framing.
// ---------------------------------------------------------------------------

const testing = std.testing;

const SOS_FRAME_HEX =
    "475201008d0101010220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b000408000000006b359d5805100102030405060708090a0b0c0d0e0f10ff4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000319d4099";

const ACK_FRAME_HEX =
    "475201009f0101070220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b0a0408000000006b359c360510aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa13100102030405060708090a0b0c0d0e0f10ff40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f292d3c";

test "golden SOS frame decodes, CRC matches spec" {
    var raw_buf: [256]u8 = undefined;
    const raw = try hexDecode(SOS_FRAME_HEX, &raw_buf);
    try testing.expectEqual(@as(usize, 150), raw.len);
    const dec = try decodeFrame(raw);
    try testing.expectEqual(@as(u16, 141), dec.body_len);
    // Re-encode must reproduce the exact bytes (CRC included).
    var out: [256]u8 = undefined;
    const enc = try encodeFrame(dec.body, &out);
    try testing.expectEqualSlices(u8, raw, enc);
}

test "golden ACK frame decodes, CRC matches spec" {
    var raw_buf: [256]u8 = undefined;
    const raw = try hexDecode(ACK_FRAME_HEX, &raw_buf);
    const dec = try decodeFrame(raw);
    try testing.expectEqual(@as(u16, 159), dec.body_len);
    var out: [256]u8 = undefined;
    const enc = try encodeFrame(dec.body, &out);
    try testing.expectEqualSlices(u8, raw, enc);
}

test "frame rejects bad magic, version, crc, truncation, trailing" {
    var raw_buf: [256]u8 = undefined;
    const raw = try hexDecode(SOS_FRAME_HEX, &raw_buf);

    var bad: [256]u8 = undefined;
    @memcpy(bad[0..raw.len], raw);

    bad[0] = 0x00;
    try testing.expectError(error.BadMagic, decodeFrame(bad[0..raw.len]));
    bad[0] = 0x47;

    bad[2] = 0x02;
    try testing.expectError(error.BadVersion, decodeFrame(bad[0..raw.len]));
    bad[2] = 0x01;

    bad[10] ^= 0xFF;
    try testing.expectError(error.CrcMismatch, decodeFrame(bad[0..raw.len]));
    bad[10] ^= 0xFF;

    try testing.expectError(error.Truncated, decodeFrame(bad[0 .. raw.len - 1]));
    try testing.expectError(error.Truncated, decodeFrame(bad[0..3]));
    try testing.expectError(error.TrailingBytes, decodeFrame(bad[0 .. raw.len + 1]));
}

test "tlv iterator walks fields, rejects truncation" {
    var raw_buf: [256]u8 = undefined;
    const raw = try hexDecode(SOS_FRAME_HEX, &raw_buf);
    const dec = try decodeFrame(raw);
    var pos: usize = 0;
    var count: usize = 0;
    var saw_sig = false;
    while (try nextTlv(dec.body, &pos)) |tlv| {
        count += 1;
        if (tlv.tag == 0xFF) {
            saw_sig = true;
            try testing.expectEqual(@as(usize, 64), tlv.value.len);
            try testing.expectEqual(dec.body.len, pos); // sig last
        }
    }
    try testing.expect(saw_sig);
    try testing.expectEqual(@as(usize, 6), count);

    var p2: usize = dec.body.len - 1;
    try testing.expectError(error.TruncatedTlv, nextTlv(dec.body, &p2));
}

test "hex codec round-trips, rejects odd length and bad digits" {
    const src = [_]u8{ 0x00, 0xAB, 0xFF, 0x47 };
    var enc: [8]u8 = undefined;
    try testing.expectEqualStrings("00abff47", try hexEncode(&src, &enc));
    var dec: [4]u8 = undefined;
    try testing.expectEqualSlices(u8, &src, try hexDecode("00ABff47", &dec));
    var tiny: [1]u8 = undefined;
    try testing.expectError(error.NoSpace, hexDecode("00AB", &tiny));
    try testing.expectError(error.BadHex, hexDecode("0", &dec));
    try testing.expectError(error.BadHex, hexDecode("zz", &dec));
}

test "fuzz frame decoder never panics (deep: zig test -ffuzz on ELF/MachO)" {
    try std.testing.fuzz({}, fuzzFrame, .{});
}

fn fuzzFrame(_: void, smith: *std.testing.Smith) !void {
    // Strategy 1: pure garbage.
    var garbage: [600]u8 = undefined;
    const glen = smith.valueRangeAtMost(u16, 0, 600);
    smith.bytes(garbage[0..glen]);
    _ = decodeFrame(garbage[0..glen]) catch {};

    // Strategy 2: mutated golden frame, possibly truncated.
    var raw_buf: [256]u8 = undefined;
    const golden = try hexDecode(SOS_FRAME_HEX, &raw_buf);
    var mut: [256]u8 = undefined;
    @memcpy(mut[0..golden.len], golden);
    const nmut = smith.valueRangeAtMost(u16, 0, 8);
    var i: usize = 0;
    while (i < nmut) : (i += 1) {
        const at = smith.valueRangeAtMost(u16, 0, @intCast(golden.len - 1));
        mut[at] = smith.value(u8);
    }
    const cut = smith.valueRangeAtMost(u16, 0, @intCast(golden.len));
    _ = decodeFrame(mut[0..cut]) catch {};
}

test "encoder enforces body bounds" {
    var out: [600]u8 = undefined;
    const small = [_]u8{0} ** 10;
    try testing.expectError(error.BadLength, encodeFrame(&small, &out));
    const big = [_]u8{0} ** 513;
    try testing.expectError(error.BadLength, encodeFrame(&big, &out));
    const ok = [_]u8{0} ** 68;
    const enc = try encodeFrame(&ok, &out);
    try testing.expectEqual(@as(usize, 5 + 68 + 4), enc.len);
}
