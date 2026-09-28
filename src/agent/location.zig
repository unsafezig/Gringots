//! Location provider interface + mock (Phase 5).
//!
//! The agent never touches GPS directly: a platform (Android fused
//! provider, embedded GNSS, test mock) implements `Provider` and the
//! agent consumes fixes through it. Stale fixes are rejected —
//! disclosing an old position as "current" is a safety bug.

const std = @import("std");

/// A position fix. Coordinates are degrees × 1e7 (wire format).
pub const Fix = struct {
    lat: i32,
    lon: i32,
    at: u64,
    accuracy_m: u32,
};

/// Degrees -> wire integer, range-checked.
pub fn degToI32(deg: f64, is_lat: bool) !i32 {
    const lim: f64 = if (is_lat) 90.0 else 180.0;
    // The negated range check also rejects NaN (both ordered comparisons
    // would otherwise be false) before the integer conversion.
    if (!(deg >= -lim and deg <= lim)) return error.BadCoord;
    return @intFromFloat(@round(deg * 1e7));
}

pub fn i32ToDeg(v: i32) f64 {
    return @as(f64, @floatFromInt(v)) / 1e7;
}

pub const Provider = struct {
    ptr: *anyopaque,
    getFn: *const fn (ptr: *anyopaque, now: u64) ?Fix,

    pub fn get(self: Provider, now: u64) ?Fix {
        return self.getFn(self.ptr, now);
    }
};

/// Scripted provider for tests and CLI demos.
pub const Mock = struct {
    fix: ?Fix = null,
    /// Fixes older than this are treated as missing.
    staleness_s: u64 = 300,

    pub fn provider(self: *Mock) Provider {
        return .{ .ptr = self, .getFn = getImpl };
    }

    fn getImpl(ptr: *anyopaque, now: u64) ?Fix {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        const f = self.fix orelse return null;
        if (now < f.at) return f; // clock skew tolerance: accept future-dated
        if (now - f.at > self.staleness_s) return null;
        return f;
    }

    pub fn setDeg(self: *Mock, lat_d: f64, lon_d: f64, at: u64, accuracy_m: u32) !void {
        self.fix = .{
            .lat = try degToI32(lat_d, true),
            .lon = try degToI32(lon_d, false),
            .at = at,
            .accuracy_m = accuracy_m,
        };
    }
};

const testing = std.testing;

test "degree conversion round-trips at wire scale" {
    try testing.expectEqual(@as(i32, 601699000), try degToI32(60.1699, true));
    try testing.expectEqual(@as(i32, -1224194000), try degToI32(-122.4194, false));
    try testing.expectError(error.BadCoord, degToI32(90.1, true));
    try testing.expectError(error.BadCoord, degToI32(180.1, false));
    try testing.expectError(error.BadCoord, degToI32(std.math.nan(f64), true));
    try testing.expectApproxEqAbs(@as(f64, 60.1699), i32ToDeg(601699000), 1e-7);
}

test "mock serves fresh fixes, drops stale and missing" {
    var m = Mock{};
    try testing.expect(m.provider().get(1000) == null);
    try m.setDeg(60.0, 24.0, 1000, 10);
    const f = m.provider().get(1100).?;
    try testing.expectEqual(@as(i32, 600000000), f.lat);
    try testing.expect(m.provider().get(1000 + 301) == null); // stale
    try testing.expect(m.provider().get(1000 + 300) != null); // boundary ok
}
