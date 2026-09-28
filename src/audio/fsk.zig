//! Non-coherent FSK modem: 1200 Hz (0) / 2400 Hz (1) at 300 baud.
//!
//! Transmitter uses continuous-phase synthesis with integer cycles per
//! bit (4 at 1200 Hz, 8 at 2400 Hz), so any rate divisible by 300 works
//! (default 44100 Hz -> 147 samples/bit, exact). Receiver correlates
//! each bit window against both tones (Goertzel) and picks the stronger:
//! no phase lock needed, volume-independent.
//!
//! Embedded note: f64 correlation is used for clarity; fixed-point is a
//! mechanical port for constrained firmware.

const std = @import("std");

pub const F0_HZ: f64 = 1200.0;
pub const F1_HZ: f64 = 2400.0;
pub const BAUD: u32 = 300;
pub const DEFAULT_RATE: u32 = 44100;
pub const AMPLITUDE: i16 = 12000;

pub const Modem = struct {
    rate: u32,
    /// Samples per bit. Always exact: rate % BAUD == 0 required.
    spb: u32,
    amp: i16,
    /// Goertzel coefficients for the two tones at this rate.
    coef0: f64,
    coef1: f64,

    pub fn init(rate: u32) !Modem {
        if (rate < 8000 or rate % BAUD != 0) return error.BadRate;
        const spb = rate / BAUD;
        return .{
            .rate = rate,
            .spb = spb,
            .amp = AMPLITUDE,
            .coef0 = 2.0 * @cos(2.0 * std.math.pi * F0_HZ / @as(f64, @floatFromInt(rate))),
            .coef1 = 2.0 * @cos(2.0 * std.math.pi * F1_HZ / @as(f64, @floatFromInt(rate))),
        };
    }

    /// Bits (0/1 bytes) -> PCM samples. OUT must hold bits.len * spb.
    pub fn modulate(self: *const Modem, bits: []const u8, out: []i16) []i16 {
        std.debug.assert(out.len >= bits.len * self.spb);
        const r: f64 = @floatFromInt(self.rate);
        const inc0 = 2.0 * std.math.pi * F0_HZ / r;
        const inc1 = 2.0 * std.math.pi * F1_HZ / r;
        var phase: f64 = 0;
        var o: usize = 0;
        for (bits) |b| {
            const inc = if (b == 0) inc0 else inc1;
            for (0..self.spb) |_| {
                phase += inc;
                const s = @sin(phase);
                out[o] = @intFromFloat(s * @as(f64, @floatFromInt(self.amp)));
                o += 1;
            }
        }
        return out[0..o];
    }

    fn goertzelMag2(samples: []const i16, coef: f64) f64 {
        var s0: f64 = 0;
        var s1: f64 = 0;
        var s2: f64 = 0;
        for (samples) |x| {
            s0 = @as(f64, @floatFromInt(x)) + coef * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        return s1 * s1 + s2 * s2 - coef * s1 * s2;
    }

    /// Samples -> bits. SAMPLES must be a whole number of bit windows.
    /// OUT must hold samples.len / spb bytes. ENERGIES (optional) gets
    /// per-bit total energy (squelch / sync ranking).
    pub fn demodulate(self: *const Modem, samples: []const i16, out: []u8, energies: ?[]f64) []u8 {
        const n = samples.len / self.spb;
        std.debug.assert(out.len >= n);
        if (energies) |e| std.debug.assert(e.len >= n);
        for (0..n) |i| {
            const w = samples[i * self.spb .. (i + 1) * self.spb];
            const m0 = goertzelMag2(w, self.coef0);
            const m1 = goertzelMag2(w, self.coef1);
            out[i] = if (m1 > m0) 1 else 0;
            if (energies) |e| e[i] = m0 + m1;
        }
        return out[0..n];
    }
};

const testing = std.testing;

test "bit round-trip exact, alternating and random" {
    const m = try Modem.init(44100);
    try testing.expectEqual(@as(u32, 147), m.spb);
    var bits: [512]u8 = undefined;
    for (&bits, 0..) |*b, i| b.* = @intCast(i & 1);
    var samples: [512 * 147]i16 = undefined;
    const s = m.modulate(&bits, &samples);
    try testing.expectEqual(@as(usize, 512 * 147), s.len);
    var got: [512]u8 = undefined;
    var e: [512]f64 = undefined;
    const d = m.demodulate(s, &got, &e);
    try testing.expectEqualSlices(u8, &bits, d);
    // Energies well above zero: healthy signal, no squelch trip.
    for (e) |v| try testing.expect(v > 1e9);
}

test "tolerates noise and volume change" {
    const m = try Modem.init(44100);
    var bits: [256]u8 = undefined;
    var seed: u64 = 0xA55AA55A;
    for (&bits) |*b| {
        seed +%= 0x9E3779B97F4A7C15;
        b.* = @intCast(seed & 1);
    }
    var samples: [256 * 147]i16 = undefined;
    _ = m.modulate(&bits, &samples);
    // Add uniform noise ±3000 (≈1/4 full scale) + halve the volume.
    for (&samples) |*s| {
        seed +%= 0x9E3779B97F4A7C15;
        var z = seed >> 33;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        const nz: i32 = @intCast(z % 6001);
        const v: i32 = @divTrunc(@as(i32, @intCast(s.*)), 2) + nz - 3000;
        s.* = @intCast(@max(-32768, @min(32767, v)));
    }
    var got: [256]u8 = undefined;
    const d = m.demodulate(&samples, &got, null);
    try testing.expectEqualSlices(u8, &bits, d);
}

test "bad rates rejected" {
    try testing.expectError(error.BadRate, Modem.init(8000 + 1));
    try testing.expectError(error.BadRate, Modem.init(100));
    try testing.expectError(error.BadRate, Modem.init(8000)); // 8000 % 300 != 0
    _ = try Modem.init(9000); // divisible: exact bit timing
}

test "silence decodes to zeros with ~zero energy" {
    const m = try Modem.init(44100);
    const quiet = [_]i16{0} ** (4 * 147);
    var got: [4]u8 = undefined;
    var e: [4]f64 = undefined;
    const d = m.demodulate(&quiet, &got, &e);
    try testing.expectEqual(@as(usize, 4), d.len);
    for (e) |v| try testing.expect(v < 1e-6);
}
