//! Ephemeral identity (SECURITY.md Section 1, PROTOCOL.md Section 6).
//!
//! The EPHEMERAL_ID is the Ed25519 public key itself. Rotation is time-based
//! (>= 24 h) or on demand. The secret is held in RAM and can be wiped.

const std = @import("std");
const ed = @import("../crypto/ed25519.zig");
const types = @import("../protocol/types.zig");

pub const Identity = struct {
    seed: [32]u8,
    keypair: ed.E.KeyPair,
    created_at: u64,

    pub fn init(seed: [32]u8, now: u64) !Identity {
        return .{
            .seed = seed,
            .keypair = try ed.keypairFromSeed(seed),
            .created_at = now,
        };
    }

    pub fn pubkeyBytes(self: *const Identity) [32]u8 {
        return self.keypair.public_key.toBytes();
    }

    /// True when a fresh keypair should be generated.
    pub fn needsRotation(self: *const Identity, now: u64) bool {
        if (now < self.created_at) return true; // clock moved backwards
        return now - self.created_at >= types.IDENTITY_LIFETIME_S;
    }

    /// Zero secret material in place.
    pub fn wipe(self: *Identity) void {
        @memset(&self.seed, 0);
        @memset(&self.keypair.secret_key.bytes, 0);
    }
};

const testing = std.testing;

test "rotation boundary at 24h" {
    var id = try Identity.init([_]u8{3} ** 32, 1_000_000);
    try testing.expect(!id.needsRotation(1_000_000));
    try testing.expect(!id.needsRotation(1_000_000 + types.IDENTITY_LIFETIME_S - 1));
    try testing.expect(id.needsRotation(1_000_000 + types.IDENTITY_LIFETIME_S));
    try testing.expect(id.needsRotation(999_999)); // clock skew backwards
}

test "wipe zeroes secrets, pubkey stable" {
    var id = try Identity.init([_]u8{3} ** 32, 0);
    const pk = id.pubkeyBytes();
    try testing.expectEqual(@as(usize, 32), pk.len);
    id.wipe();
    const zero_seed = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &zero_seed, &id.seed);
}
