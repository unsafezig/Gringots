//! Ed25519 wrapper (SECURITY.md Section 1).
//!
//! Deterministic signatures (RFC 8032, null noise): no RNG needed on the
//! signing path, which suits constrained devices. Key generation still
//! requires 32 CSPRNG bytes from the caller (see CLI keygen / identity).

const std = @import("std");

pub const E = std.crypto.sign.Ed25519;

pub fn keypairFromSeed(seed: [32]u8) !E.KeyPair {
    return E.KeyPair.generateDeterministic(seed);
}

/// Deterministic detached signature over MESSAGE.
pub fn signDetached(kp: E.KeyPair, message: []const u8) !([64]u8) {
    const sig = try kp.sign(message, null);
    return sig.toBytes();
}

/// Verify a detached signature. Any failure is an error.
pub fn verifyDetached(sig_bytes: [64]u8, message: []const u8, pub_bytes: [32]u8) !void {
    const pk = try E.PublicKey.fromBytes(pub_bytes);
    const sig = E.Signature.fromBytes(sig_bytes);
    try sig.verify(message, pk);
}

const testing = std.testing;

test "rfc8032 test 1 vector (empty message)" {
    // Independent cross-check against the published RFC 8032 vector,
    // so the wrapper is not only self-consistent.
    const seed_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const pk_hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    const sig_hex = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
    const frame = @import("../protocol/frame.zig");
    var seed: [32]u8 = undefined;
    var want_pk: [32]u8 = undefined;
    var want_sig: [64]u8 = undefined;
    _ = try frame.hexDecode(seed_hex, &seed);
    _ = try frame.hexDecode(pk_hex, &want_pk);
    _ = try frame.hexDecode(sig_hex, &want_sig);

    const kp = try keypairFromSeed(seed);
    try testing.expectEqualSlices(u8, &want_pk, &kp.public_key.toBytes());
    const got = try signDetached(kp, &[_]u8{});
    try testing.expectEqualSlices(u8, &want_sig, &got);
    try verifyDetached(want_sig, &[_]u8{}, want_pk);
    try testing.expectError(
        error.SignatureVerificationFailed,
        verifyDetached(want_sig, "TEST", want_pk),
    );
}

test "wrong key fails verification" {
    const kp = try keypairFromSeed([_]u8{1} ** 32);
    const other = try keypairFromSeed([_]u8{2} ** 32);
    const sig = try signDetached(kp, "hello");
    try verifyDetached(sig, "hello", kp.public_key.toBytes());
    try testing.expectError(
        error.SignatureVerificationFailed,
        verifyDetached(sig, "hello", other.public_key.toBytes()),
    );
}
