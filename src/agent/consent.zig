//! Explicit user-consent queue (Phase 5).
//!
//! Every LOCATION_REQUEST becomes a pending item the user must approve
//! or deny. Nothing is disclosed without a decision inside the TTL.
//! Auto-approve exists ONLY for demos/tests — a shipping civilian app
//! MUST surface each request in system UI (Android) or CLI prompt.
//!
//! All time is caller-provided (virtual clock); no hidden clock calls.

const std = @import("std");

pub const DEFAULT_TTL_S: u64 = 120;
pub const CAPACITY: usize = 4;

pub const State = enum { pending, approved, denied, expired };

pub const Request = struct {
    id: u32,
    requester: [32]u8,
    req_nonce: [16]u8,
    session_id: [16]u8,
    received_at: u64,
    expires_at: u64,
    state: State = .pending,
};

pub const Queue = struct {
    slots: [CAPACITY]?Request = [_]?Request{null} ** CAPACITY,
    next_id: u32 = 1,

    /// Enqueue a request. Returns the id, or null when full (caller
    /// should DECLINE: a full queue must not silently drop consent).
    pub fn push(
        self: *Queue,
        requester: [32]u8,
        req_nonce: [16]u8,
        session_id: [16]u8,
        now: u64,
        ttl_s: u64,
    ) ?u32 {
        // Terminal entries are no longer useful, and an expired pending entry
        // must not permanently consume one of the limited UI slots.
        _ = self.sweep(now);
        for (&self.slots) |*slot| {
            if (slot.*) |r| {
                if (r.state != .pending) slot.* = null;
            }
        }
        // Refresh duplicates instead of stacking them.
        for (&self.slots) |*slot| {
            if (slot.*) |*r| {
                if (r.state == .pending and
                    std.mem.eql(u8, &r.requester, &requester) and
                    std.mem.eql(u8, &r.req_nonce, &req_nonce))
                {
                    r.received_at = now;
                    r.expires_at = now +| ttl_s;
                    return r.id;
                }
            }
        }
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                const id = self.next_id;
                self.next_id +%= 1;
                slot.* = .{
                    .id = id,
                    .requester = requester,
                    .req_nonce = req_nonce,
                    .session_id = session_id,
                    .received_at = now,
                    .expires_at = now +| ttl_s,
                };
                return id;
            }
        }
        return null;
    }

    /// Record a user decision. Late decisions on expired items fail.
    pub fn decide(self: *Queue, id: u32, approve: bool, now: u64) ?*Request {
        for (&self.slots) |*slot| {
            if (slot.*) |*r| {
                if (r.id != id or r.state != .pending) continue;
                if (now > r.expires_at) {
                    r.state = .expired;
                    return null;
                }
                r.state = if (approve) .approved else .denied;
                return r;
            }
        }
        return null;
    }

    /// Age out pending items past TTL. Returns the number expired.
    pub fn sweep(self: *Queue, now: u64) usize {
        var n: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.*) |*r| {
                if (r.state == .pending and now > r.expires_at) {
                    r.state = .expired;
                    n += 1;
                }
            }
        }
        return n;
    }

    pub fn pendingCount(self: *const Queue) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot) |r| {
                if (r.state == .pending) n += 1;
            }
        }
        return n;
    }

    pub fn get(self: *Queue, id: u32) ?*Request {
        for (&self.slots) |*slot| {
            if (slot.*) |*r| {
                if (r.id == id) return r;
            }
        }
        return null;
    }
};

const testing = std.testing;

test "push / approve / deny lifecycle" {
    var q = Queue{};
    const id = q.push([_]u8{1} ** 32, [_]u8{2} ** 16, [_]u8{3} ** 16, 1000, 120).?;
    try testing.expectEqual(@as(usize, 1), q.pendingCount());
    const r = q.decide(id, true, 1050).?;
    try testing.expect(r.state == .approved);
    try testing.expectEqual(@as(usize, 0), q.pendingCount());
    // Deciding twice fails.
    try testing.expect(q.decide(id, false, 1050) == null);

    const id2 = q.push([_]u8{4} ** 32, [_]u8{5} ** 16, [_]u8{6} ** 16, 1000, 120).?;
    _ = q.decide(id2, false, 1050).?;
    try testing.expect(q.get(id2).?.state == .denied);
}

test "expiry blocks late approval, sweep ages queue" {
    var q = Queue{};
    const id = q.push([_]u8{1} ** 32, [_]u8{2} ** 16, [_]u8{3} ** 16, 1000, 120).?;
    try testing.expect(q.decide(id, true, 1121) == null);
    try testing.expect(q.get(id).?.state == .expired);
    const id2 = q.push([_]u8{7} ** 32, [_]u8{8} ** 16, [_]u8{9} ** 16, 1000, 120).?;
    _ = id2;
    try testing.expectEqual(@as(usize, 1), q.sweep(2000));
    try testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "full queue returns null, duplicates refresh" {
    var q = Queue{};
    for (0..CAPACITY) |i| {
        var req = [_]u8{0} ** 32;
        req[0] = @intCast(i);
        try testing.expect(q.push(req, [_]u8{9} ** 16, [_]u8{8} ** 16, 1000, 120) != null);
    }
    try testing.expect(q.push([_]u8{99} ** 32, [_]u8{9} ** 16, [_]u8{8} ** 16, 1000, 120) == null);
    // Same (requester, nonce) refreshes instead of stacking.
    const req0 = [_]u8{0} ** 32;
    const again = q.push(req0, [_]u8{9} ** 16, [_]u8{8} ** 16, 1100, 120).?;
    try testing.expectEqual(@as(usize, 1), again); // first id reused
    try testing.expectEqual(@as(u64, 1100), q.get(again).?.received_at);
    try testing.expectEqual(@as(usize, CAPACITY), q.pendingCount());
}

test "completed entries are reusable" {
    var q = Queue{};
    const id = q.push([_]u8{1} ** 32, [_]u8{2} ** 16, [_]u8{3} ** 16, 1000, 120).?;
    _ = q.decide(id, false, 1000).?;
    try testing.expect(q.push([_]u8{4} ** 32, [_]u8{5} ** 16, [_]u8{6} ** 16, 1000, 120) != null);
}
