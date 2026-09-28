//! Safety-session state machine (PROTOCOL.md Section 10).
//!
//! idle -> requested -> consented -> disclosed -> moving -> (updates)
//! Any state --revoke--> closed. No periodic beacon: each LOCATION_UPDATE
//! is an explicit step, not a timer.

const std = @import("std");

pub const State = enum {
    idle,
    requested,
    consented,
    disclosed,
    moving,
    closed,
};

pub const Session = struct {
    state: State = .idle,
    session_id: [16]u8 = [_]u8{0} ** 16,
    expires: u64 = 0,

    pub fn request(self: *Session, session_id: [16]u8, expires: u64) !void {
        if (self.state != .idle) return error.BadState;
        self.session_id = session_id;
        self.expires = expires;
        self.state = .requested;
    }

    pub fn consent(self: *Session) !void {
        if (self.state != .requested) return error.BadState;
        self.state = .consented;
    }

    pub fn disclose(self: *Session) !void {
        if (self.state != .consented) return error.BadState;
        self.state = .disclosed;
    }

    pub fn startMoving(self: *Session) !void {
        if (self.state != .disclosed) return error.BadState;
        self.state = .moving;
    }

    pub fn revoke(self: *Session) void {
        self.state = .closed;
    }

    pub fn isExpired(self: *const Session, now: u64) bool {
        return now > self.expires;
    }
};

const testing = std.testing;

test "happy path to moving, revoke closes" {
    var s = Session{};
    try s.request([_]u8{5} ** 16, 5000);
    try testing.expect(s.state == .requested);
    try s.consent();
    try s.disclose();
    try s.startMoving();
    try testing.expect(s.state == .moving);
    try testing.expect(!s.isExpired(4999));
    try testing.expect(s.isExpired(5001));
    s.revoke();
    try testing.expect(s.state == .closed);
}

test "out-of-order transitions rejected" {
    var s = Session{};
    try testing.expectError(error.BadState, s.consent());
    try testing.expectError(error.BadState, s.disclose());
    try testing.expectError(error.BadState, s.startMoving());
    try s.request([_]u8{5} ** 16, 5000);
    try testing.expectError(error.BadState, s.request([_]u8{5} ** 16, 5000));
    try testing.expectError(error.BadState, s.disclose());
}
