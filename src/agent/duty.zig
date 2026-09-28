//! Battery-conscious broadcast scheduler (Phase 5).
//!
//! A civilian device must not become a permanent beacon — for privacy,
//! spectrum politeness, and battery life. This scheduler bounds SOS
//! burst activity by interval, hourly budget, quiet hours, and
//! acknowledgement cooldown, all on virtual time (no clock calls).
//!
//! An explicit user SOS activation bypasses quiet hours (never the hourly
//! budget): ringing the bell on purpose must work at night.

const std = @import("std");

pub const MAX_HISTORY: usize = 24;

pub const Policy = struct {
    /// Routine interval between SOS bursts.
    burst_interval_s: u64 = 30,
    /// Hard cap of bursts in any rolling 60-minute window (<= MAX_HISTORY).
    max_bursts_per_hour: u8 = 12,
    /// Quiet window (UTC hours, [start, end)); routine bursts suppressed.
    quiet_start_h: u8 = 22,
    quiet_end_h: u8 = 7,
    /// After a valid ACK, suppress routine bursts this long (they hear us).
    ack_cooldown_s: u64 = 600,
    /// Stretched interval when the OS reports low battery.
    low_battery_interval_s: u64 = 300,
};

pub const Scheduler = struct {
    policy: Policy,
    history: [MAX_HISTORY]u64 = [_]u64{0} ** MAX_HISTORY,
    hist_len: usize = 0,
    hist_at: usize = 0,
    last_ack_at: ?u64 = null,
    battery_low: bool = false,

    pub fn init(policy: Policy) Scheduler {
        std.debug.assert(policy.max_bursts_per_hour <= MAX_HISTORY);
        std.debug.assert(policy.max_bursts_per_hour > 0);
        return .{ .policy = policy };
    }

    fn hourOfDay(now: u64) u8 {
        return @intCast((now / 3600) % 24);
    }

    fn inQuiet(self: *const Scheduler, now: u64) bool {
        const h = hourOfDay(now);
        const s = self.policy.quiet_start_h;
        const e = self.policy.quiet_end_h;
        if (s == e) return false; // degenerate: no quiet window
        if (s < e) return h >= s and h < e;
        return h >= s or h < e; // wraps midnight
    }

    fn recentBursts(self: *const Scheduler, now: u64) usize {
        var n: usize = 0;
        const from = now -| 3600;
        for (0..self.hist_len) |i| {
            const t = self.history[(self.hist_at + MAX_HISTORY - 1 - i) % MAX_HISTORY];
            if (t > from and t <= now) n += 1;
        }
        return n;
    }

    /// Should a routine burst go out now? `last_burst_at == null` means
    /// never (first activation is always due, budget permitting).
    /// `user_active` bypasses quiet hours only.
    pub fn wantBurst(self: *const Scheduler, last_burst_at: ?u64, now: u64, user_active: bool) bool {
        if (self.last_ack_at) |ack| {
            if (now >= ack and now - ack < self.policy.ack_cooldown_s) return false;
        }
        if (self.inQuiet(now) and !user_active) return false;
        if (self.recentBursts(now) >= self.policy.max_bursts_per_hour) return false;
        const interval = if (self.battery_low)
            self.policy.low_battery_interval_s
        else
            self.policy.burst_interval_s;
        if (last_burst_at) |last| {
            if (now < last) return true; // clock moved back: stay safe, burst
            return now - last >= interval;
        }
        return true;
    }

    pub fn recordBurst(self: *Scheduler, now: u64) void {
        self.history[self.hist_at] = now;
        self.hist_at = (self.hist_at + 1) % MAX_HISTORY;
        if (self.hist_len < MAX_HISTORY) self.hist_len += 1;
    }

    pub fn recordAck(self: *Scheduler, now: u64) void {
        self.last_ack_at = now;
    }
};

const testing = std.testing;
const NOON: u64 = 12 * 3600; // 12:00 UTC, outside default quiet window

test "first burst due, then interval-gated" {
    var s = Scheduler.init(.{});
    try testing.expect(s.wantBurst(null, NOON, true));
    s.recordBurst(NOON);
    try testing.expect(!s.wantBurst(NOON, NOON + 29, true));
    try testing.expect(s.wantBurst(NOON, NOON + 30, true));
}

test "hourly budget caps bursts" {
    var s = Scheduler.init(.{ .burst_interval_s = 1, .max_bursts_per_hour = 3 });
    var t = NOON;
    var sent: usize = 0;
    var last: ?u64 = null;
    while (t < NOON + 3600) : (t += 1) {
        if (s.wantBurst(last, t, true)) {
            s.recordBurst(t);
            last = t;
            sent += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), sent);
    // Budget frees up after the window slides.
    try testing.expect(s.wantBurst(last, NOON + 3601, true));
}

test "quiet hours suppress routine bursts, not active SOS" {
    var s = Scheduler.init(.{});
    const night: u64 = 23 * 3600;
    try testing.expect(!s.wantBurst(null, night, false));
    try testing.expect(s.wantBurst(null, night, true));
    try testing.expect(s.wantBurst(null, NOON, false));
}

test "ack cooldown suppresses, then releases" {
    var s = Scheduler.init(.{});
    s.recordAck(NOON);
    try testing.expect(!s.wantBurst(null, NOON + 599, true));
    try testing.expect(s.wantBurst(null, NOON + 600, true));
}

test "low battery stretches interval" {
    var s = Scheduler.init(.{});
    s.battery_low = true;
    s.recordBurst(NOON);
    try testing.expect(!s.wantBurst(NOON, NOON + 299, true));
    try testing.expect(s.wantBurst(NOON, NOON + 300, true));
}
