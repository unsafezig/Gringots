//! Replay protection: (EPHEMERAL_ID, NONCE) cache (SECURITY.md Section 3).
//!
//! Fixed-capacity ring, no allocator. Callers pass `now`; entries whose
//! EXPIRES + skew has passed are treated as free.

const std = @import("std");
const types = @import("../protocol/types.zig");

pub const CAPACITY: usize = 64;

const Entry = struct {
    id: [32]u8,
    nonce: [16]u8,
    expires: u64,
};

pub const Verdict = enum { fresh, duplicate };

pub const Cache = struct {
    slots: [CAPACITY]?Entry = [_]?Entry{null} ** CAPACITY,
    cursor: usize = 0,

    pub fn check(self: *Cache, id: [32]u8, nonce: [16]u8, expires: u64, now: u64) Verdict {
        for (self.slots) |slot| {
            if (slot) |e| {
                if (e.expires +| types.SKEW_S < now) continue;
                if (std.mem.eql(u8, &e.id, &id) and std.mem.eql(u8, &e.nonce, &nonce)) {
                    return .duplicate;
                }
            }
        }
        self.slots[self.cursor] = .{ .id = id, .nonce = nonce, .expires = expires };
        self.cursor = (self.cursor + 1) % CAPACITY;
        return .fresh;
    }

    pub fn liveCount(self: *const Cache, now: u64) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot) |e| {
                if (!(e.expires +| types.SKEW_S < now)) n += 1;
            }
        }
        return n;
    }
};

const testing = std.testing;

test "duplicate detected, expiry frees the slot" {
    var c = Cache{};
    const id = [_]u8{7} ** 32;
    const n = [_]u8{8} ** 16;
    try testing.expect(c.check(id, n, 2000, 1000) == .fresh);
    try testing.expect(c.check(id, n, 2000, 1000) == .duplicate);
    // Same nonce, different identity -> fresh.
    try testing.expect(c.check([_]u8{9} ** 32, n, 2000, 1000) == .fresh);
    // After EXPIRES + skew the entry no longer blocks.
    try testing.expect(c.check(id, n, 2000, 2000 + types.SKEW_S + 1) == .fresh);
    try testing.expectEqual(@as(usize, 3), c.liveCount(1000));
}

test "ring evicts oldest after capacity" {
    var c = Cache{};
    for (0..CAPACITY + 4) |i| {
        var n = [_]u8{0} ** 16;
        n[0] = @intCast(i & 0xFF);
        n[1] = @intCast((i >> 8) & 0xFF);
        try testing.expect(c.check([_]u8{1} ** 32, n, 99999, 0) == .fresh);
    }
    // First nonce was evicted -> fresh again.
    try testing.expect(c.check([_]u8{1} ** 32, [_]u8{0} ** 16, 99999, 0) == .fresh);
}
