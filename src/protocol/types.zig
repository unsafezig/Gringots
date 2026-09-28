//! Gringots v1 constants: framing limits, TLV tags, message types.
//! See PROTOCOL.md Sections 3-5.

pub const VERSION: u8 = 0x01;
pub const MAGIC0: u8 = 0x47; // 'G'
pub const MAGIC1: u8 = 0x52; // 'R'

/// BODY length bounds (MLEN field). Max total frame = 5 + 512 + 4 = 521.
pub const MAX_BODY: usize = 512;
pub const MIN_BODY: usize = 68;

/// Timing rules (SECURITY.md Section 2).
pub const MAX_TTL_S: u64 = 3600;
pub const SKEW_S: u64 = 300;
pub const DEFAULT_DISCLOSE_TTL_S: u64 = 600;

/// Identity rotation (SECURITY.md Section 1).
pub const IDENTITY_LIFETIME_S: u64 = 24 * 3600;

/// TLV type tags (PROTOCOL.md Section 4.1).
pub const tag = struct {
    pub const msg_type: u8 = 0x01;
    pub const ephemeral_id: u8 = 0x02;
    pub const timestamp: u8 = 0x03;
    pub const expires: u8 = 0x04;
    pub const nonce: u8 = 0x05;
    pub const lat: u8 = 0x10;
    pub const lon: u8 = 0x11;
    pub const session_id: u8 = 0x12;
    pub const ref: u8 = 0x13;
    pub const text_hint: u8 = 0x14;
    pub const signature: u8 = 0xFF;
};

pub const MsgType = enum(u8) {
    sos = 0x01,
    location_request = 0x02,
    location_consent = 0x03,
    location_disclosed = 0x04,
    moving_to_safety = 0x05,
    location_update = 0x06,
    ack = 0x07,
    decline = 0x08,
    _,

    pub fn fromByte(b: u8) ?MsgType {
        return switch (b) {
            0x01 => .sos,
            0x02 => .location_request,
            0x03 => .location_consent,
            0x04 => .location_disclosed,
            0x05 => .moving_to_safety,
            0x06 => .location_update,
            0x07 => .ack,
            0x08 => .decline,
            else => null,
        };
    }

    pub fn name(self: MsgType) []const u8 {
        return switch (self) {
            .sos => "CIVILIAN_SOS",
            .location_request => "LOCATION_REQUEST",
            .location_consent => "LOCATION_CONSENT",
            .location_disclosed => "LOCATION_DISCLOSED",
            .moving_to_safety => "MOVING_TO_SAFETY",
            .location_update => "LOCATION_UPDATE",
            .ack => "ACK",
            .decline => "DECLINE",
            _ => "UNKNOWN",
        };
    }

    /// Parse "SOS" / "CIVILIAN_SOS" / "sos" etc. (CLI convenience).
    pub fn fromName(s: []const u8) ?MsgType {
        if (eqlIgnoreCase(s, "SOS") or eqlIgnoreCase(s, "CIVILIAN_SOS")) return .sos;
        if (eqlIgnoreCase(s, "LOCATION_REQUEST")) return .location_request;
        if (eqlIgnoreCase(s, "LOCATION_CONSENT")) return .location_consent;
        if (eqlIgnoreCase(s, "LOCATION_DISCLOSED")) return .location_disclosed;
        if (eqlIgnoreCase(s, "MOVING_TO_SAFETY")) return .moving_to_safety;
        if (eqlIgnoreCase(s, "LOCATION_UPDATE")) return .location_update;
        if (eqlIgnoreCase(s, "ACK")) return .ack;
        if (eqlIgnoreCase(s, "DECLINE")) return .decline;
        return null;
    }

    pub fn needsLocation(self: MsgType) bool {
        return self == .location_disclosed or self == .location_update;
    }

    pub fn needsSession(self: MsgType) bool {
        return switch (self) {
            .location_consent, .location_disclosed, .moving_to_safety, .location_update => true,
            else => false,
        };
    }

    pub fn needsRef(self: MsgType) bool {
        return self == .ack;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        var x = ca;
        var y = cb;
        if (x >= 'a' and x <= 'z') x -= 32;
        if (y >= 'a' and y <= 'z') y -= 32;
        if (x != y) return false;
    }
    return true;
}

test "msgtype names round-trip" {
    const t = MsgType.fromByte(0x01).?;
    try @import("std").testing.expect(t == .sos);
    try @import("std").testing.expectEqualStrings("CIVILIAN_SOS", t.name());
    try @import("std").testing.expect(MsgType.fromByte(0x09) == null);
    try @import("std").testing.expect(MsgType.fromName("sos") == .sos);
    try @import("std").testing.expect(MsgType.fromName("ack") == .ack);
    try @import("std").testing.expect(MsgType.fromName("bogus") == null);
    try @import("std").testing.expect(MsgType.ack.needsRef());
    try @import("std").testing.expect(!MsgType.sos.needsSession());
}
