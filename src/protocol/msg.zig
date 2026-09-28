//! Gringots message layer (PROTOCOL.md Sections 5-6, 9-10).
//!
//! Builder  -> encodeUnsigned -> signAndFrame -> wire bytes
//! wire bytes -> verifyFrame -> Message (framing + parse + time + signature)
//!
//! The signature covers MAGIC || VER || MLEN || BODY-without-0xFF-TLV.

const std = @import("std");
const types = @import("types.zig");
const frame = @import("frame.zig");
const ed = @import("../crypto/ed25519.zig");

pub const SIG_TLV_LEN: usize = 2 + 64;

pub const Message = struct {
    msg_type: types.MsgType,
    ephemeral_id: [32]u8,
    timestamp: u64,
    expires: u64,
    nonce: [16]u8,
    lat: ?i32 = null,
    lon: ?i32 = null,
    session_id: ?[16]u8 = null,
    ref: ?[16]u8 = null,
    /// Slice into the parsed body. Valid while body lives.
    text_hint: ?[]const u8 = null,
    signature: [64]u8,
};

/// High-level builder. Semantic rules enforced in encodeUnsigned.
pub const Builder = struct {
    msg_type: types.MsgType,
    ephemeral_id: [32]u8,
    timestamp: u64,
    expires: u64,
    nonce: [16]u8,
    lat: ?i32 = null,
    lon: ?i32 = null,
    session_id: ?[16]u8 = null,
    ref: ?[16]u8 = null,
    text_hint: ?[]const u8 = null,

    pub fn encodeUnsigned(self: *const Builder, out: []u8) ![]u8 {
        switch (self.msg_type) {
            .sos => {
                if (self.lat != null or self.lon != null) return error.LocationInSos;
            },
            .location_disclosed, .location_update => {
                if (self.lat == null or self.lon == null) return error.LocationRequired;
                if (self.session_id == null) return error.SessionRequired;
            },
            .location_consent, .moving_to_safety => {
                if (self.session_id == null) return error.SessionRequired;
            },
            .ack => {
                if (self.ref == null) return error.RefRequired;
            },
            else => {},
        }
        if ((self.lat == null) != (self.lon == null)) return error.LocationRequired;
        if (self.text_hint) |t| {
            if (t.len > 64) return error.TextHintTooLong;
            for (t) |c| {
                // Minimal UTF-8 sanity: reject bare continuation misuse is
                // overkill here; require printable ASCII or high bytes.
                if (c < 0x20 and c != 0x0A) return error.BadTextHint;
            }
        }

        var pos: usize = 0;
        pos = try frame.appendTlv(out, pos, types.tag.msg_type, &[_]u8{@intFromEnum(self.msg_type)});
        pos = try frame.appendTlv(out, pos, types.tag.ephemeral_id, &self.ephemeral_id);
        var tsb: [8]u8 = undefined;
        std.mem.writeInt(u64, &tsb, self.timestamp, .big);
        pos = try frame.appendTlv(out, pos, types.tag.timestamp, &tsb);
        var exb: [8]u8 = undefined;
        std.mem.writeInt(u64, &exb, self.expires, .big);
        pos = try frame.appendTlv(out, pos, types.tag.expires, &exb);
        pos = try frame.appendTlv(out, pos, types.tag.nonce, &self.nonce);
        if (self.lat) |la| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, la, .big);
            pos = try frame.appendTlv(out, pos, types.tag.lat, &b);
        }
        if (self.lon) |lo| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, lo, .big);
            pos = try frame.appendTlv(out, pos, types.tag.lon, &b);
        }
        if (self.session_id) |s| pos = try frame.appendTlv(out, pos, types.tag.session_id, &s);
        if (self.ref) |r| pos = try frame.appendTlv(out, pos, types.tag.ref, &r);
        if (self.text_hint) |t| pos = try frame.appendTlv(out, pos, types.tag.text_hint, t);
        return out[0..pos];
    }
};

fn validateMessageSemantics(m: *const Message) !void {
    switch (m.msg_type) {
        .sos => {
            if (m.lat != null or m.lon != null) return error.LocationInSos;
        },
        .location_disclosed, .location_update => {
            if (m.lat == null or m.lon == null) return error.LocationRequired;
            if (m.session_id == null) return error.SessionRequired;
        },
        .location_consent, .moving_to_safety => {
            if (m.session_id == null) return error.SessionRequired;
        },
        .ack => {
            if (m.ref == null) return error.RefRequired;
        },
        else => {},
    }
    if ((m.lat == null) != (m.lon == null)) return error.LocationRequired;
}

/// Parse BODY (order-independent, unknown tags ignored).
/// 0xFF must appear exactly once, last.
pub fn parseBody(body: []const u8) !Message {
    var m: Message = .{
        .msg_type = .sos,
        .ephemeral_id = [_]u8{0} ** 32,
        .timestamp = 0,
        .expires = 0,
        .nonce = [_]u8{0} ** 16,
        .signature = [_]u8{0} ** 64,
    };
    var seen_required: u8 = 0; // bits 0..4 for tags 01..05
    var have_sig = false;
    var pos: usize = 0;
    while (try frame.nextTlv(body, &pos)) |tlv| {
        switch (tlv.tag) {
            types.tag.msg_type => {
                if (seen_required & 0x01 != 0) return error.DuplicateField;
                seen_required |= 0x01;
                if (tlv.value.len != 1) return error.BadFieldLength;
                m.msg_type = types.MsgType.fromByte(tlv.value[0]) orelse return error.UnknownMsgType;
            },
            types.tag.ephemeral_id => {
                if (seen_required & 0x02 != 0) return error.DuplicateField;
                seen_required |= 0x02;
                if (tlv.value.len != 32) return error.BadFieldLength;
                @memcpy(&m.ephemeral_id, tlv.value[0..32]);
            },
            types.tag.timestamp => {
                if (seen_required & 0x04 != 0) return error.DuplicateField;
                seen_required |= 0x04;
                if (tlv.value.len != 8) return error.BadFieldLength;
                m.timestamp = std.mem.readInt(u64, tlv.value[0..8], .big);
            },
            types.tag.expires => {
                if (seen_required & 0x08 != 0) return error.DuplicateField;
                seen_required |= 0x08;
                if (tlv.value.len != 8) return error.BadFieldLength;
                m.expires = std.mem.readInt(u64, tlv.value[0..8], .big);
            },
            types.tag.nonce => {
                if (seen_required & 0x10 != 0) return error.DuplicateField;
                seen_required |= 0x10;
                if (tlv.value.len != 16) return error.BadFieldLength;
                @memcpy(&m.nonce, tlv.value[0..16]);
            },
            types.tag.lat => {
                if (m.lat != null) return error.DuplicateField;
                if (tlv.value.len != 4) return error.BadFieldLength;
                m.lat = std.mem.readInt(i32, tlv.value[0..4], .big);
            },
            types.tag.lon => {
                if (m.lon != null) return error.DuplicateField;
                if (tlv.value.len != 4) return error.BadFieldLength;
                m.lon = std.mem.readInt(i32, tlv.value[0..4], .big);
            },
            types.tag.session_id => {
                if (m.session_id != null) return error.DuplicateField;
                if (tlv.value.len != 16) return error.BadFieldLength;
                var s: [16]u8 = undefined;
                @memcpy(&s, tlv.value[0..16]);
                m.session_id = s;
            },
            types.tag.ref => {
                if (m.ref != null) return error.DuplicateField;
                if (tlv.value.len != 16) return error.BadFieldLength;
                var r: [16]u8 = undefined;
                @memcpy(&r, tlv.value[0..16]);
                m.ref = r;
            },
            types.tag.text_hint => {
                if (m.text_hint != null) return error.DuplicateField;
                if (tlv.value.len > 64) return error.BadFieldLength;
                m.text_hint = tlv.value;
            },
            types.tag.signature => {
                if (have_sig) return error.DuplicateField;
                if (tlv.value.len != 64) return error.BadFieldLength;
                if (pos != body.len) return error.SignatureNotLast;
                @memcpy(&m.signature, tlv.value[0..64]);
                have_sig = true;
            },
            else => {}, // forward compatibility: ignore, still signature-covered
        }
    }
    if (seen_required != 0x1F) return error.MissingField;
    if (!have_sig) return error.SignatureMissing;
    try validateMessageSemantics(&m);
    return m;
}

pub const CheckOptions = struct {
    now: u64,
    allow_zero_time: bool = false,
};

/// Enforce SECURITY.md Section 2 timing rules.
pub fn checkTime(m: *const Message, opts: CheckOptions) !void {
    if (opts.allow_zero_time and m.timestamp == 0 and m.expires == 0) return;
    if (m.expires <= m.timestamp) return error.BadTimeWindow;
    if (m.expires - m.timestamp > types.MAX_TTL_S) return error.TtlTooLong;
    if (opts.now +| types.SKEW_S < m.timestamp) return error.NotYetValid;
    if (opts.now > m.expires +| types.SKEW_S) return error.Expired;
}

/// Build unsigned body, sign (scope: HDR || unsigned), append 0xFF, frame.
/// BODY_BUF must hold >= 512 B, FRAME_BUF >= 521 B.
pub fn signAndFrame(b: *const Builder, kp: ed.E.KeyPair, body_buf: []u8, frame_buf: []u8) ![]u8 {
    const unsigned = try b.encodeUnsigned(body_buf);
    const full_len = unsigned.len + SIG_TLV_LEN;
    if (full_len > types.MAX_BODY) return error.BadBodyLength;
    var hdr: [frame.HEADER_LEN]u8 = .{ types.MAGIC0, types.MAGIC1, types.VERSION, 0, 0 };
    std.mem.writeInt(u16, hdr[3..][0..2], @intCast(full_len), .big);
    var sig_input: [frame.HEADER_LEN + types.MAX_BODY]u8 = undefined;
    @memcpy(sig_input[0..frame.HEADER_LEN], &hdr);
    @memcpy(sig_input[frame.HEADER_LEN .. frame.HEADER_LEN + unsigned.len], unsigned);
    const sig = try ed.signDetached(kp, sig_input[0 .. frame.HEADER_LEN + unsigned.len]);
    const pos = try frame.appendTlv(body_buf, unsigned.len, types.tag.signature, &sig);
    std.debug.assert(pos == full_len);
    return frame.encodeFrame(body_buf[0..pos], frame_buf);
}

/// Full receive path: framing -> parse -> time -> signature.
pub fn verifyFrame(raw: []const u8, now: u64) !Message {
    const dec = try frame.decodeFrame(raw);
    const m = try parseBody(dec.body);
    try checkTime(&m, .{ .now = now });
    // Signed scope = everything except trailing CRC and 0xFF TLV.
    const signed = raw[0 .. raw.len - frame.CRC_LEN - SIG_TLV_LEN];
    try ed.verifyDetached(m.signature, signed, m.ephemeral_id);
    return m;
}

/// Debug text form: "GRINGOTTS/1 TYPE=... ID=... TIMESTAMP=... EXPIRES=... SIGNATURE=..."
pub fn formatDebug(m: *const Message, out: []u8) ![]u8 {
    var id_hex: [64]u8 = undefined;
    var sig_hex: [128]u8 = undefined;
    const idh = try frame.hexEncode(&m.ephemeral_id, &id_hex);
    const sigh = try frame.hexEncode(&m.signature, &sig_hex);
    return std.fmt.bufPrint(out, "GRINGOTTS/1 TYPE={s} ID={s} TIMESTAMP={d} EXPIRES={d} SIGNATURE={s}", .{
        m.msg_type.name(), idh, m.timestamp, m.expires, sigh,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testKeypair() ed.E.KeyPair {
    // Deterministic test identity (NOT the 00..1F structure vector).
    const seed = [_]u8{0x42} ** 32;
    return ed.keypairFromSeed(seed) catch unreachable;
}

fn testBuilder() Builder {
    return .{
        .msg_type = .sos,
        .ephemeral_id = testKeypair().public_key.toBytes(),
        .timestamp = 1798675200,
        .expires = 1798675800,
        .nonce = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
    };
}

test "sign -> verify round-trip, tamper fails" {
    const kp = testKeypair();
    var b = testBuilder();
    var body: [512]u8 = undefined;
    var fr: [521]u8 = undefined;
    const wire = try signAndFrame(&b, kp, &body, &fr);

    const m = try verifyFrame(wire, 1798675200);
    try testing.expect(m.msg_type == .sos);
    try testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &m.ephemeral_id);

    // Flip a body byte: CRC must now fail (exact bytes covered).
    var tampered: [521]u8 = undefined;
    @memcpy(tampered[0..wire.len], wire);
    tampered[10] ^= 0x01;
    try testing.expectError(error.CrcMismatch, verifyFrame(tampered[0..wire.len], 1798675200));

    // Re-sign over tampered content is out of scope; instead corrupt the
    // signature TLV and re-frame to get a pure signature failure.
    const dec = try frame.decodeFrame(wire);
    var body2: [512]u8 = undefined;
    @memcpy(body2[0..dec.body.len], dec.body);
    body2[dec.body.len - 1] ^= 0x01; // inside signature value
    const reframed = try frame.encodeFrame(body2[0..dec.body.len], &tampered);
    try testing.expectError(error.SignatureVerificationFailed, verifyFrame(reframed, 1798675200));
}

test "time window enforced" {
    const kp = testKeypair();
    var b = testBuilder();
    var body: [512]u8 = undefined;
    var fr: [521]u8 = undefined;
    const wire = try signAndFrame(&b, kp, &body, &fr);

    try testing.expectError(error.Expired, verifyFrame(wire, 1798675800 + 301));
    try testing.expectError(error.NotYetValid, verifyFrame(wire, 1798675200 - 301));
    // Inside skew is fine.
    _ = try verifyFrame(wire, 1798675800 + 300);

    // TTL cap: 3601 s must fail at build-independent check level.
    var bad = b;
    bad.expires = bad.timestamp + 3601;
    const wire2 = try signAndFrame(&bad, kp, &body, &fr);
    try testing.expectError(error.TtlTooLong, verifyFrame(wire2, bad.timestamp));
}

test "sos must not carry location; disclosed needs session+coords" {
    var b = testBuilder();
    b.lat = 601699000;
    b.lon = 24938000;
    var body: [512]u8 = undefined;
    try testing.expectError(error.LocationInSos, b.encodeUnsigned(&body));

    var d = testBuilder();
    d.msg_type = .location_disclosed;
    d.lat = 601699000;
    d.lon = 24938000;
    try testing.expectError(error.SessionRequired, d.encodeUnsigned(&body));
    d.session_id = [_]u8{9} ** 16;
    _ = try d.encodeUnsigned(&body);

    var a = testBuilder();
    a.msg_type = .ack;
    try testing.expectError(error.RefRequired, a.encodeUnsigned(&body));
    a.ref = [_]u8{1} ** 16;
    _ = try a.encodeUnsigned(&body);
}

test "golden SOS structure vector parses (signature zeroed -> verify fails)" {
    const body_hex =
        "0101010220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0308000000006b359b000408000000006b359d5805100102030405060708090a0b0c0d0e0f10ff4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    var body: [256]u8 = undefined;
    const bytes = try frame.hexDecode(body_hex, &body);
    try testing.expectEqual(@as(usize, 141), bytes.len);
    const m = try parseBody(bytes);
    try testing.expect(m.msg_type == .sos);
    try testing.expectEqual(@as(u64, 1798675200), m.timestamp);
    try testing.expectEqual(@as(u64, 1798675800), m.expires);
    try testing.expect(m.lat == null);
    // Zeroed signature is structurally fine but must never verify.
    var fr: [256]u8 = undefined;
    const wire = try frame.encodeFrame(bytes, &fr);
    try testing.expectError(error.SignatureVerificationFailed, verifyFrame(wire, 1798675200));

    var dbg: [512]u8 = undefined;
    const text = try formatDebug(&m, &dbg);
    try testing.expect(std.mem.startsWith(u8, text, "GRINGOTTS/1 TYPE=CIVILIAN_SOS ID=000102"));
}

test "fuzz body parser never panics (deep: zig test -ffuzz on ELF/MachO)" {
    try std.testing.fuzz({}, fuzzBody, .{});
}

fn fuzzBody(_: void, smith: *std.testing.Smith) !void {
    var buf: [600]u8 = undefined;
    const len = smith.valueRangeAtMost(u16, 0, 600);
    smith.bytes(buf[0..len]);
    const m = parseBody(buf[0..len]) catch return;
    checkTime(&m, .{ .now = 1798675200 }) catch {};
    var dbg: [512]u8 = undefined;
    _ = formatDebug(&m, &dbg) catch {};
}

test "unknown TLV ignored, bad sig placement and duplicates rejected" {
    const kp = testKeypair();
    const b = testBuilder();
    var body: [600]u8 = undefined;
    const unsigned = try b.encodeUnsigned(&body);
    // splice unknown tag 0x42 after nonce, before signature
    var crafted: [600]u8 = undefined;
    @memcpy(crafted[0..unsigned.len], unsigned);
    var pos = unsigned.len;
    pos = try frame.appendTlv(&crafted, pos, 0x42, "hi");
    var hdr: [frame.HEADER_LEN]u8 = .{ types.MAGIC0, types.MAGIC1, types.VERSION, 0, 0 };
    const full: usize = pos + SIG_TLV_LEN;
    std.mem.writeInt(u16, hdr[3..][0..2], @intCast(full), .big);
    var sig_input: [600]u8 = undefined;
    @memcpy(sig_input[0..5], &hdr);
    @memcpy(sig_input[5 .. 5 + pos], crafted[0..pos]);
    const sig = try ed.signDetached(kp, sig_input[0 .. 5 + pos]);
    _ = try frame.appendTlv(&crafted, pos, types.tag.signature, &sig);
    var fr: [600]u8 = undefined;
    const wire = try frame.encodeFrame(crafted[0..full], &fr);
    const m = try verifyFrame(wire, 1798675200);
    try testing.expect(m.msg_type == .sos);

    // Signature TLV not last: build body with trailing data after sig.
    var badbody: [600]u8 = undefined;
    @memcpy(badbody[0..full], crafted[0..full]);
    var badpos = full;
    badpos = try frame.appendTlv(&badbody, badpos, 0x42, "x");
    // parseBody works on body level: sig-not-last fires before CRC matters.
    try testing.expectError(error.SignatureNotLast, parseBody(badbody[0..badpos]));

    // Duplicate MSG_TYPE.
    var dup: [600]u8 = undefined;
    @memcpy(dup[0..unsigned.len], unsigned);
    _ = try frame.appendTlv(&dup, unsigned.len, types.tag.msg_type, &[_]u8{0x01});
    try testing.expectError(error.DuplicateField, parseBody(dup[0 .. unsigned.len + 3]));
}

test "parser enforces message semantics, not just the builder" {
    var b = testBuilder();
    var body: [512]u8 = undefined;
    const unsigned = try b.encodeUnsigned(&body);
    // Change the type after building to model a malicious, structurally valid
    // body. The zero signature is sufficient because parseBody does not verify it.
    body[2] = @intFromEnum(types.MsgType.location_disclosed);
    const zero_sig = [_]u8{0} ** 64;
    const end = try frame.appendTlv(&body, unsigned.len, types.tag.signature, &zero_sig);
    try testing.expectError(error.LocationRequired, parseBody(body[0..end]));
}
