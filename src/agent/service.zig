//! Device agent: the portable core of a civilian background service.
//!
//! An Android foreground service (or embedded daemon, or CLI demo) hosts
//! this struct: it owns identity, duty schedule, replay cache, consent
//! queue and safety session, and turns inbound frames + timer ticks into
//! outbound frames. No I/O, no clock calls — the host drives `tick` and
//! `onFrame` on virtual time and drains `takeFrame`.
//!
//! Safety notes (see THREAT_MODEL.md T5):
//! * Any keypair can mint an ACK referencing our NONCE, so `acked` means
//!   "someone claims acknowledgement", never "verified rescuer". Hosts
//!   MUST surface it with that caveat.
//! * One active safety session at a time (single-session scope).

const std = @import("std");
const msg = @import("../protocol/msg.zig");
const ed = @import("../crypto/ed25519.zig");
const identity = @import("../identity/ephemeral.zig");
const replay = @import("../replay/cache.zig");
const session = @import("../location/session.zig");
pub const duty = @import("duty.zig");
pub const consent = @import("consent.zig");
pub const location = @import("location.zig");

pub const OUTBOX_CAP: usize = 8;

pub const Config = struct {
    seed: [32]u8,
    policy: duty.Policy = .{},
    consent_ttl_s: u64 = consent.DEFAULT_TTL_S,
    sos_ttl_s: u64 = 600,
    location_max_age_s: u64 = 300,
};

pub const DecideOutcome = enum { none, declined, consented };

pub const Service = struct {
    ident: identity.Identity,
    rng: u64,
    sched: duty.Scheduler,
    consents: consent.Queue = .{},
    seen: replay.Cache = .{},
    safety: session.Session = .{},
    sos_ttl: u64,
    consent_ttl: u64,
    location_max_age: u64,
    active: bool = true,
    last_burst_at: ?u64 = null,
    last_sos_nonce: ?[16]u8 = null,
    acked: bool = false,
    acked_from: ?[32]u8 = null,
    outbox: [OUTBOX_CAP][600]u8 = [_][600]u8{[_]u8{0} ** 600} ** OUTBOX_CAP,
    out_lens: [OUTBOX_CAP]usize = [_]usize{0} ** OUTBOX_CAP,
    out_head: usize = 0,
    out_count: usize = 0,

    pub fn init(cfg: Config, now: u64) !Service {
        const seed64 = std.mem.readInt(u64, cfg.seed[0..8], .little);
        return .{
            .ident = try identity.Identity.init(cfg.seed, now),
            .rng = seed64 ^ 0x9E3779B97F4A7C15,
            .sched = duty.Scheduler.init(cfg.policy),
            .sos_ttl = cfg.sos_ttl_s,
            .consent_ttl = cfg.consent_ttl_s,
            .location_max_age = cfg.location_max_age_s,
        };
    }

    pub fn activate(self: *Service, on: bool) void {
        self.active = on;
    }

    fn nextNonce(self: *Service) [16]u8 {
        var n: [16]u8 = undefined;
        std.mem.writeInt(u64, n[0..][0..8], splitmix(&self.rng), .little);
        std.mem.writeInt(u64, n[8..][0..8], splitmix(&self.rng), .little);
        return n;
    }

    fn nextSessionId(self: *Service) [16]u8 {
        return self.nextNonce();
    }

    fn emit(self: *Service, b: *const msg.Builder) !void {
        var body: [512]u8 = undefined;
        var fr: [600]u8 = undefined;
        const wire = try msg.signAndFrame(b, self.ident.keypair, &body, &fr);
        var idx: usize = (self.out_head + self.out_count) % OUTBOX_CAP;
        if (self.out_count == OUTBOX_CAP) {
            idx = self.out_head; // full: overwrite oldest, never grow
            self.out_head = (self.out_head + 1) % OUTBOX_CAP;
        } else {
            self.out_count += 1;
        }
        @memcpy(self.outbox[idx][0..wire.len], wire);
        self.out_lens[idx] = wire.len;
    }

    /// Oldest queued outbound frame, or null. Valid until overwritten.
    pub fn takeFrame(self: *Service) ?[]const u8 {
        if (self.out_count == 0) return null;
        const idx = self.out_head;
        self.out_head = (self.out_head + 1) % OUTBOX_CAP;
        self.out_count -= 1;
        return self.outbox[idx][0..self.out_lens[idx]];
    }

    pub fn pendingConsents(self: *const Service) usize {
        return self.consents.pendingCount();
    }

    /// Timer tick: rotate identity, expire consents, maybe SOS-burst.
    pub fn tick(self: *Service, now: u64) !void {
        if (self.ident.needsRotation(now)) {
            var ns: [32]u8 = undefined;
            for (0..4) |i| std.mem.writeInt(u64, ns[i * 8 ..][0..8], splitmix(&self.rng), .little);
            const next = try identity.Identity.init(ns, now);
            self.ident.wipe();
            self.ident = next;
        }
        _ = self.consents.sweep(now);
        if (!self.sched.wantBurst(self.last_burst_at, now, self.active)) return;
        const nonce = self.nextNonce();
        const b = msg.Builder{
            .msg_type = .sos,
            .ephemeral_id = self.ident.pubkeyBytes(),
            .timestamp = now,
            .expires = now +| self.sos_ttl,
            .nonce = nonce,
        };
        try self.emit(&b);
        self.sched.recordBurst(now);
        self.last_burst_at = now;
        self.last_sos_nonce = nonce;
        self.acked = false;
        self.acked_from = null;
    }

    /// Inbound datagram payload. Drops anything invalid silently.
    pub fn onFrame(self: *Service, raw: []const u8, now: u64) !void {
        const m = msg.verifyFrame(raw, now) catch return;
        if (self.seen.check(m.ephemeral_id, m.nonce, m.expires, now) == .duplicate) return;
        switch (m.msg_type) {
            .ack => {
                if (m.ref) |r| {
                    if (self.last_sos_nonce) |n| {
                        if (std.mem.eql(u8, &r, &n)) {
                            self.acked = true;
                            self.acked_from = m.ephemeral_id;
                            self.sched.recordAck(now);
                        }
                    }
                }
            },
            .location_request => {
                const sid = self.nextSessionId();
                const id = self.consents.push(m.ephemeral_id, m.nonce, sid, now, self.consent_ttl);
                if (id == null) {
                    const b = msg.Builder{
                        .msg_type = .decline,
                        .ephemeral_id = self.ident.pubkeyBytes(),
                        .timestamp = now,
                        .expires = now +| self.sos_ttl,
                        .nonce = self.nextNonce(),
                        .ref = m.nonce,
                    };
                    try self.emit(&b);
                }
            },
            else => {},
        }
    }

    /// Apply a user consent decision. `loc` must be a fresh fix; a null
    /// (missing/stale) location turns approval into an honest DECLINE.
    pub fn decide(self: *Service, id: u32, approve: bool, loc: ?location.Fix, now: u64) !DecideOutcome {
        const req = self.consents.decide(id, approve, now) orelse return .none;
        const decline = msg.Builder{
            .msg_type = .decline,
            .ephemeral_id = self.ident.pubkeyBytes(),
            .timestamp = now,
            .expires = now +| self.sos_ttl,
            .nonce = self.nextNonce(),
            .ref = req.req_nonce,
        };
        if (!approve) {
            try self.emit(&decline);
            return .declined;
        }
        const fix = loc orelse {
            try self.emit(&decline);
            return .declined;
        };
        if (now >= fix.at and now - fix.at > self.location_max_age) {
            try self.emit(&decline);
            return .declined;
        }
        self.safety = session.Session{};
        try self.safety.request(req.session_id, now +| self.sos_ttl);
        try self.safety.consent();
        const cb = msg.Builder{
            .msg_type = .location_consent,
            .ephemeral_id = self.ident.pubkeyBytes(),
            .timestamp = now,
            .expires = now +| self.sos_ttl,
            .nonce = self.nextNonce(),
            .session_id = req.session_id,
            .ref = req.req_nonce,
        };
        try self.emit(&cb);
        try self.safety.disclose();
        const db = msg.Builder{
            .msg_type = .location_disclosed,
            .ephemeral_id = self.ident.pubkeyBytes(),
            .timestamp = now,
            .expires = now +| self.sos_ttl,
            .nonce = self.nextNonce(),
            .lat = fix.lat,
            .lon = fix.lon,
            .session_id = req.session_id,
            .ref = req.req_nonce,
        };
        try self.emit(&db);
        return .consented;
    }
};

fn splitmix(s: *u64) u64 {
    s.* +%= 0x9E3779B97F4A7C15;
    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const testing = std.testing;
const T0: u64 = 1798675200 + 12 * 3600; // 2027-01-01 midday UTC

fn requesterKp() ed.E.KeyPair {
    return ed.keypairFromSeed([_]u8{0xBB} ** 32) catch unreachable;
}

fn makeRequest(ref_nonce: [16]u8, ts: u64, nonce_byte: u8) struct { buf: [600]u8, len: usize } {
    const kp = requesterKp();
    const b = msg.Builder{
        .msg_type = .location_request,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = ts,
        .expires = ts + 600,
        .nonce = [_]u8{nonce_byte} ** 16,
        .ref = ref_nonce,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch unreachable;
    var out: [600]u8 = undefined;
    @memcpy(out[0..wire.len], wire);
    return .{ .buf = out, .len = wire.len };
}

fn wireLen(svc: *Service) usize {
    return svc.out_count;
}

test "tick bursts SOS, ack links by nonce" {
    var svc = try Service.init(.{ .seed = [_]u8{1} ** 32 }, T0);
    try svc.tick(T0);
    try testing.expectEqual(@as(usize, 1), wireLen(&svc));
    const sos = svc.takeFrame().?;
    const m = try msg.verifyFrame(sos, T0);
    try testing.expect(m.msg_type == .sos);
    try testing.expect(svc.takeFrame() == null);

    // Wrong REF: ignored.
    const kp = requesterKp();
    const bad_ack = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{7} ** 16,
        .ref = [_]u8{0} ** 16,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const badw = try msg.signAndFrame(&bad_ack, kp, &body, &fr);
    try svc.onFrame(badw, T0);
    try testing.expect(!svc.acked);

    // Correct REF: acknowledged (claimed, see caveat).
    const good_ack = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{8} ** 16,
        .ref = m.nonce,
    };
    const goodw = try msg.signAndFrame(&good_ack, kp, &body, &fr);
    try svc.onFrame(goodw, T0);
    try testing.expect(svc.acked);
    try testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &svc.acked_from.?);
    // Duplicate ACK: no double effects, no frames emitted.
    try svc.onFrame(goodw, T0);
    try testing.expect(svc.acked);
    try testing.expectEqual(@as(usize, 0), wireLen(&svc));
}

test "request -> approve emits consent + disclosed with fix" {
    var svc = try Service.init(.{ .seed = [_]u8{1} ** 32 }, T0);
    try svc.tick(T0);
    const sm = try msg.verifyFrame(svc.takeFrame().?, T0);

    const req = makeRequest(sm.nonce, T0, 9);
    try svc.onFrame(req.buf[0..req.len], T0);
    try testing.expectEqual(@as(usize, 1), svc.pendingConsents());

    const fix = location.Fix{ .lat = 601699000, .lon = 24938000, .at = T0, .accuracy_m = 8 };
    try testing.expect(try svc.decide(1, true, fix, T0) == .consented);
    try testing.expectEqual(@as(usize, 2), wireLen(&svc));
    const c1 = try msg.verifyFrame(svc.takeFrame().?, T0);
    try testing.expect(c1.msg_type == .location_consent);
    const c2 = try msg.verifyFrame(svc.takeFrame().?, T0);
    try testing.expect(c2.msg_type == .location_disclosed);
    try testing.expectEqual(@as(?i32, 601699000), c2.lat);
    try testing.expectEqual(@as(?i32, 24938000), c2.lon);
    try testing.expectEqual(c1.session_id, c2.session_id);
    try testing.expect(svc.safety.state == .disclosed);
}

test "deny and missing-fix approvals emit decline" {
    var svc = try Service.init(.{ .seed = [_]u8{1} ** 32 }, T0);
    try svc.tick(T0);
    const sm = try msg.verifyFrame(svc.takeFrame().?, T0);

    const r1 = makeRequest(sm.nonce, T0, 11);
    try svc.onFrame(r1.buf[0..r1.len], T0);
    try testing.expect(try svc.decide(1, false, null, T0) == .declined);
    const d1 = try msg.verifyFrame(svc.takeFrame().?, T0);
    try testing.expect(d1.msg_type == .decline);

    const r2 = makeRequest(sm.nonce, T0, 12);
    try svc.onFrame(r2.buf[0..r2.len], T0);
    // Approved but no fix available: honest decline, never stale coords.
    try testing.expect(try svc.decide(2, true, null, T0) == .declined);
    const d2 = try msg.verifyFrame(svc.takeFrame().?, T0);
    try testing.expect(d2.msg_type == .decline);

    // Unknown id: nothing emitted.
    try testing.expect(try svc.decide(99, true, null, T0) == .none);
    try testing.expectEqual(@as(usize, 0), wireLen(&svc));
}

test "ack cooldown suppresses next burst, rotation swaps identity" {
    var svc = try Service.init(.{ .seed = [_]u8{1} ** 32 }, T0);
    try svc.tick(T0);
    const sm = try msg.verifyFrame(svc.takeFrame().?, T0);
    const kp = requesterKp();
    const ack = msg.Builder{
        .msg_type = .ack,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = T0,
        .expires = T0 + 600,
        .nonce = [_]u8{8} ** 16,
        .ref = sm.nonce,
    };
    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    try svc.onFrame(try msg.signAndFrame(&ack, kp, &body, &fr), T0);
    try svc.tick(T0 + 30); // interval due, but cooldown holds
    try testing.expectEqual(@as(usize, 0), wireLen(&svc));
    try svc.tick(T0 + 601); // cooldown over
    try testing.expectEqual(@as(usize, 1), wireLen(&svc));
    _ = svc.takeFrame();

    // 24 h later the identity rotates: new SOS carries a new pubkey.
    try svc.tick(T0 + 86400 + 601);
    const rot = try msg.verifyFrame(svc.takeFrame().?, T0 + 86400 + 601);
    try testing.expect(!std.mem.eql(u8, &rot.ephemeral_id, &sm.ephemeral_id));
}

test "stale fix is declined and old identity secret is wiped on rotation" {
    var svc = try Service.init(.{ .seed = [_]u8{1} ** 32, .location_max_age_s = 10 }, T0);
    try svc.tick(T0);
    const sm = try msg.verifyFrame(svc.takeFrame().?, T0);
    const req = makeRequest(sm.nonce, T0, 31);
    try svc.onFrame(req.buf[0..req.len], T0);
    const stale = location.Fix{ .lat = 1, .lon = 2, .at = T0 - 11, .accuracy_m = 5 };
    try testing.expect(try svc.decide(1, true, stale, T0) == .declined);
    try testing.expect((try msg.verifyFrame(svc.takeFrame().?, T0)).msg_type == .decline);

    const old_seed = svc.ident.seed;
    try svc.tick(T0 + 86400);
    try testing.expect(!std.mem.eql(u8, &old_seed, &svc.ident.seed));
}
