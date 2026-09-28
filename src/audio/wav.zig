//! Minimal WAV (RIFF PCM16 mono) reader/writer.
//!
//! The WAV file is the device boundary for the acoustic fallback: any
//! recorder/player (phone app, `audio-listen`, speaker) can sit on either
//! side. No platform audio API is needed inside Gringots.

const std = @import("std");

pub const HEADER_LEN: usize = 44;

/// Write a mono PCM16 WAV. OUT must hold 44 + samples*2 bytes.
pub fn write(samples: []const i16, rate: u32, out: []u8) ![]u8 {
    if (rate == 0 or rate > 192000) return error.BadRate;
    const data_bytes_usize = std.math.mul(usize, samples.len, 2) catch return error.NoSpace;
    const total_len = std.math.add(usize, HEADER_LEN, data_bytes_usize) catch return error.NoSpace;
    const data_bytes: u32 = std.math.cast(u32, data_bytes_usize) orelse return error.NoSpace;
    if (out.len < total_len) return error.NoSpace;
    // RIFF header.
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..][0..4], 36 + data_bytes, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..][0..4], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, out[20..][0..2], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..][0..2], 1, .little); // mono
    std.mem.writeInt(u32, out[24..][0..4], rate, .little);
    std.mem.writeInt(u32, out[28..][0..4], rate * 2, .little); // byte rate
    std.mem.writeInt(u16, out[32..][0..2], 2, .little); // block align
    std.mem.writeInt(u16, out[34..][0..2], 16, .little); // bits
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..][0..4], data_bytes, .little);
    for (samples, 0..) |s, i| {
        std.mem.writeInt(i16, out[HEADER_LEN + i * 2 ..][0..2], s, .little);
    }
    return out[0 .. HEADER_LEN + data_bytes];
}

pub const Wav = struct {
    rate: u32,
    samples: []i16,
};

/// Parse a WAV made by `write` (strict: PCM16 mono, exact 44 B header).
/// Decoded samples are written to SAMPLES_OUT (no aliasing).
pub fn parse(bytes: []const u8, samples_out: []i16) !Wav {
    if (bytes.len < HEADER_LEN) return error.NotWav;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.NotWav;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWav;
    if (!std.mem.eql(u8, bytes[12..16], "fmt ")) return error.NotWav;
    if (std.mem.readInt(u16, bytes[20..][0..2], .little) != 1) return error.NotWav;
    if (std.mem.readInt(u16, bytes[22..][0..2], .little) != 1) return error.NotWav;
    if (std.mem.readInt(u16, bytes[34..][0..2], .little) != 16) return error.NotWav;
    if (!std.mem.eql(u8, bytes[36..40], "data")) return error.NotWav;
    const rate = std.mem.readInt(u32, bytes[24..][0..4], .little);
    if (rate == 0 or rate > 192000) return error.NotWav;
    const data_bytes = std.mem.readInt(u32, bytes[40..][0..4], .little);
    if (data_bytes % 2 != 0) return error.NotWav;
    const total_len = std.math.add(usize, HEADER_LEN, @as(usize, data_bytes)) catch return error.Truncated;
    if (bytes.len < total_len) return error.Truncated;
    const n: usize = data_bytes / 2;
    if (samples_out.len < n) return error.NoSpace;
    for (0..n) |i| {
        samples_out[i] = std.mem.readInt(i16, bytes[HEADER_LEN + i * 2 ..][0..2], .little);
    }
    return .{ .rate = rate, .samples = samples_out[0..n] };
}

const testing = std.testing;

test "wav round-trip preserves samples and rate" {
    var pcm = [_]i16{ 0, 12000, -12000, 32767, -32768, 1 };
    var buf: [256]u8 = undefined;
    const w = try write(&pcm, 44100, &buf);
    try testing.expectEqual(@as(usize, 44 + 12), w.len);
    var back: [16]i16 = undefined;
    const parsed = try parse(w, &back);
    try testing.expectEqual(@as(u32, 44100), parsed.rate);
    try testing.expectEqualSlices(i16, &pcm, parsed.samples);
}

test "wav rejects non-audio and truncation" {
    var back: [16]i16 = undefined;
    try testing.expectError(error.NotWav, parse("hello world, this is not wav...........", &back));
    var pcm = [_]i16{ 1, 2, 3 };
    var buf: [64]u8 = undefined;
    const w = try write(&pcm, 44100, &buf);
    try testing.expectError(error.Truncated, parse(w[0 .. w.len - 2], &back));
    var tiny: [1]i16 = undefined;
    try testing.expectError(error.NoSpace, parse(w, &tiny));
    var small: [10]u8 = undefined;
    try testing.expectError(error.NoSpace, write(&pcm, 44100, &small));
}
