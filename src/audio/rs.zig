//! Reed-Solomon (255, 223) over GF(256), errors-only decoding.
//!
//! Narrow-sense code, first consecutive root α^0, primitive polynomial
//! 0x11D. Corrects up to 16 symbol errors per 255-byte block; more than
//! that is reported (never silently "fixed"). Shortened blocks pad
//! leading zeros, so any data length 1..223 works.
//!
//! Integrity ultimately rests on the Gringots CRC32 inside the frame:
//! this layer only repairs channel damage.

const std = @import("std");

pub const NSYM: usize = 32;
pub const DATA_LEN: usize = 223;
pub const CODE_LEN: usize = 255;
pub const CAPACITY: usize = NSYM / 2; // 16 correctable errors

// --- GF(256) tables (comptime) ---------------------------------------------

const EXP: [512]u8 = blk: {
    var e: [512]u8 = undefined;
    var x: u16 = 1;
    for (&e) |*v| {
        v.* = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    break :blk e;
};

const LOG: [256]u8 = blk: {
    var l: [256]u8 = undefined;
    l[0] = 0; // never used (zero has no log)
    for (EXP[0..255], 0..) |v, i| l[v] = @intCast(i);
    break :blk l;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return EXP[@as(usize, LOG[a]) + LOG[b]];
}

fn gfDiv(a: u8, b: u8) u8 {
    std.debug.assert(b != 0);
    if (a == 0) return 0;
    const la: usize = LOG[a];
    const lb: usize = LOG[b];
    return EXP[la + 255 - lb];
}

/// α^k for any k (wraps mod 255).
fn alphaPow(k: usize) u8 {
    return EXP[k % 255];
}

/// α^-k for any k.
fn alphaInvPow(k: usize) u8 {
    const m = k % 255;
    if (m == 0) return 1;
    return EXP[255 - m];
}

/// Evaluate polynomial (coeffs high-degree first) at x. Horner.
/// Used for codewords: C(x) = c_0·x^254 + ... + c_254.
fn polyEval(poly: []const u8, x: u8) u8 {
    var y: u8 = 0;
    for (poly) |c| y = gfMul(y, x) ^ c;
    return y;
}

/// Evaluate polynomial stored low-degree first (Λ, Ω, Λ').
fn polyEvalLow(poly: []const u8, x: u8) u8 {
    var y: u8 = 0;
    var xp: u8 = 1;
    for (poly) |c| {
        y ^= gfMul(c, xp);
        xp = gfMul(xp, x);
    }
    return y;
}

// --- Generator polynomial (degree 32, comptime) -----------------------------

const GEN: [NSYM + 1]u8 = blk: {
    @setEvalBranchQuota(100000);
    // g(x) = prod_{i=0}^{31} (x + α^i); GEN[0] is the x^32 coefficient (1).
    var g: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
    g[NSYM] = 1; // start with polynomial "1" (constant), aligned right
    var deg: usize = 0;
    for (0..NSYM) |i| {
        // multiply current g (degree deg) by (x + α^i)
        var next: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
        const a = alphaPow(i);
        for (0..deg + 1) |j| {
            const c = g[NSYM - deg + j];
            // x-term shifts left (toward index 0), constant term scales by a
            next[NSYM - deg - 1 + j] ^= c;
            next[NSYM - deg + j] ^= gfMul(c, a);
        }
        g = next;
        deg += 1;
    }
    break :blk g;
};

// --- Encode ------------------------------------------------------------------

/// Encode one block: DATA[0..k] (k in 1..223) -> OUT[0..255].
/// Short data is leading-zero padded; the full 255-byte codeword is
/// transmitted (simple, matches "RS(255,223) blocks" in the spec).
pub fn encodeBlock(data: []const u8, out: []u8) !void {
    const k = data.len;
    if (k == 0 or k > DATA_LEN) return error.BadLength;
    if (out.len < CODE_LEN) return error.NoSpace;
    var full: [CODE_LEN]u8 = [_]u8{0} ** CODE_LEN;
    @memcpy(full[DATA_LEN - k .. DATA_LEN], data);
    // LFSR division over the padded 223 data symbols; GEN[0] is leading 1.
    var parity: [NSYM]u8 = [_]u8{0} ** NSYM;
    for (full[0..DATA_LEN]) |d| {
        const fb = d ^ parity[0];
        std.mem.copyForwards(u8, parity[0 .. NSYM - 1], parity[1..NSYM]);
        parity[NSYM - 1] = 0;
        if (fb != 0) {
            for (0..NSYM) |j| parity[j] ^= gfMul(GEN[j + 1], fb);
        }
    }
    @memcpy(out[0..DATA_LEN], full[0..DATA_LEN]);
    @memcpy(out[DATA_LEN..CODE_LEN], &parity);
}

// --- Decode ------------------------------------------------------------------

fn syndromes(full: *const [CODE_LEN]u8, syn: *[NSYM]u8) bool {
    var clean = true;
    for (0..NSYM) |j| {
        // S_j = C(α^j): Horner over c_0 x^254 + ... + c_254.
        var y: u8 = 0;
        const x = alphaPow(j);
        for (full) |c| y = gfMul(y, x) ^ c;
        syn[j] = y;
        if (y != 0) clean = false;
    }
    return clean;
}

/// Decode one block: RX[0..255] -> DATA_OUT[0..k] (k in 1..223).
/// Corrects <= 16 symbol errors. Anything else is an error.
pub fn decodeBlock(rx: []const u8, data_out: []u8) !void {
    const k = data_out.len;
    if (k == 0 or k > DATA_LEN) return error.BadLength;
    if (rx.len != CODE_LEN) return error.BadLength;

    var full: [CODE_LEN]u8 = undefined;
    @memcpy(&full, rx[0..CODE_LEN]);

    var syn: [NSYM]u8 = undefined;
    if (syndromes(&full, &syn)) {
        @memcpy(data_out, full[DATA_LEN - k .. DATA_LEN - k + k]);
        return;
    }

    // Berlekamp-Massey: error locator Λ.
    var lam: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
    var old: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
    var lam_len: usize = 1; // significant length (degree+1)
    var old_len: usize = 1;
    lam[0] = 1;
    old[0] = 1;
    var L: usize = 0;
    var m: usize = 1;
    var b: u8 = 1;
    for (0..NSYM) |n| {
        var d: u8 = syn[n];
        for (1..L + 1) |i| {
            if (i < lam_len) d ^= gfMul(lam[i], syn[n - i]);
        }
        if (d == 0) {
            m += 1;
        } else {
            var tmp: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
            @memcpy(tmp[0..lam_len], lam[0..lam_len]);
            const tmp_len = lam_len;
            const coef = gfDiv(d, b);
            for (0..old_len) |i| {
                if (old[i] == 0) continue;
                const at = i + m;
                if (at > NSYM) continue;
                lam[at] ^= gfMul(coef, old[i]);
            }
            // recompute significant length
            lam_len = NSYM + 1;
            while (lam_len > 1 and lam[lam_len - 1] == 0) lam_len -= 1;
            if (2 * L <= n) {
                L = n + 1 - L;
                @memcpy(old[0..tmp_len], tmp[0..tmp_len]);
                old_len = tmp_len;
                b = d;
                m = 1;
            } else {
                m += 1;
            }
        }
    }
    if (L == 0 or L > CAPACITY) return error.TooManyErrors;
    const loc = lam[0..lam_len];

    // Chien search: error at index i (0-based from start) iff
    // Λ(α^-(254-i)) == 0. Location number X = α^(254-i).
    var err_idx: [CAPACITY]usize = undefined;
    var err_x: [CAPACITY]u8 = undefined;
    var nerr: usize = 0;
    for (0..CODE_LEN) |i| {
        const kpos = (CODE_LEN - 1) - i; // position from end
        if (polyEvalLow(loc, alphaInvPow(kpos)) == 0) {
            if (nerr >= CAPACITY) return error.TooManyErrors;
            err_idx[nerr] = i;
            err_x[nerr] = alphaPow(kpos);
            nerr += 1;
        }
    }
    if (nerr != L) return error.TooManyErrors;

    // Forney: Ω = (S·Λ) mod x^32; Y = X·Ω(X^-1)/Λ'(X^-1), FCR=0.
    var omega_full: [2 * NSYM]u8 = [_]u8{0} ** (2 * NSYM);
    for (0..NSYM) |i| {
        if (syn[i] == 0) continue;
        for (0..loc.len) |j| {
            if (loc[j] == 0) continue;
            omega_full[i + j] ^= gfMul(syn[i], loc[j]);
        }
    }
    const omega = omega_full[0..NSYM];
    // Formal derivative Λ' in characteristic 2: odd-degree terms only.
    var deriv: [NSYM + 1]u8 = [_]u8{0} ** (NSYM + 1);
    for (0..loc.len) |j| {
        if (j % 2 == 1 and j > 0) deriv[j - 1] = loc[j];
    }

    for (0..nerr) |e| {
        const xinv = gfDiv(1, err_x[e]);
        const num = gfMul(err_x[e], polyEvalLow(omega, xinv));
        const den = polyEvalLow(deriv[0..loc.len], xinv);
        if (den == 0) return error.TooManyErrors;
        full[err_idx[e]] ^= gfDiv(num, den);
    }

    // Defensive: corrected word must have zero syndromes (catches
    // miscorrections when errors exceeded capacity).
    var syn2: [NSYM]u8 = undefined;
    if (!syndromes(&full, &syn2)) return error.TooManyErrors;
    @memcpy(data_out, full[DATA_LEN - k .. DATA_LEN]);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn splitmix(s: *u64) u64 {
    s.* +%= 0x9E3779B97F4A7C15;
    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

test "generator sanity: valid codewords have zero syndromes" {
    var data: [DATA_LEN]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 37 + 11) & 0xFF);
    var cw: [CODE_LEN]u8 = undefined;
    try encodeBlock(&data, &cw);
    var full: [CODE_LEN]u8 = undefined;
    @memcpy(&full, &cw);
    var syn: [NSYM]u8 = undefined;
    try testing.expect(syndromes(&full, &syn));
}

test "round-trip with 0..16 random errors, all short lengths" {
    var seed: u64 = 0x12345678;
    inline for ([_]usize{ 1, 75, 222, 223 }) |k| {
        var data: [DATA_LEN]u8 = undefined;
        for (0..k) |i| data[i] = @intCast(splitmix(&seed) & 0xFF);
        var cw: [CODE_LEN]u8 = undefined;
        try encodeBlock(data[0..k], &cw);

        inline for ([_]usize{ 0, 1, 5, 16 }) |nerr| {
            var rx = cw;
            // Distinct random positions over the whole 255-byte block.
            var pos: [16]usize = undefined;
            var placed: usize = 0;
            while (placed < nerr) {
                const p: usize = @intCast(splitmix(&seed) % CODE_LEN);
                var dup = false;
                for (0..placed) |q| {
                    if (pos[q] == p) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    pos[placed] = p;
                    placed += 1;
                }
            }
            for (0..nerr) |q| {
                var v: u8 = @intCast(splitmix(&seed) & 0xFF);
                if (v == rx[pos[q]]) v ^= 0xFF;
                rx[pos[q]] = v;
            }
            var got: [DATA_LEN]u8 = undefined;
            try decodeBlock(&rx, got[0..k]);
            try testing.expectEqualSlices(u8, data[0..k], got[0..k]);
        }
    }
}

test "17 errors are reported, not hidden" {
    var fails: usize = 0;
    for (0..8) |trial| {
        var data: [223]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @intCast((i + trial * 7) & 0xFF);
        var cw: [CODE_LEN]u8 = undefined;
        try encodeBlock(&data, &cw);
        var rx = cw;
        for (0..17) |q| {
            const p: usize = (trial * 31 + q * 13) % cw.len;
            rx[p] ^= @as(u8, @intCast(1 + ((trial + q) & 0x7F)));
            if (rx[p] == cw[p]) rx[p] ^= 0x80;
        }
        var got: [223]u8 = undefined;
        decodeBlock(&rx, &got) catch {
            fails += 1;
            continue;
        };
        // A "success" with 17 errors must still reproduce the data
        // (astronomically unlikely otherwise) — else the test is wrong.
        try testing.expectEqualSlices(u8, &data, &got);
    }
    try testing.expect(fails == 8);
}

test "bad lengths rejected" {
    var out: [10]u8 = undefined;
    try testing.expectError(error.BadLength, encodeBlock(&[_]u8{}, &out));
    var big: [224]u8 = [_]u8{1} ** 224;
    var bigout: [300]u8 = undefined;
    try testing.expectError(error.BadLength, encodeBlock(&big, &bigout));
}
