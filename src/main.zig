//! Gringots CLI (Phase 2 core + Phase 3 local transports + Phase 4 audio).
//!
//! Transport-independent: frames are hex on stdout, so they can be piped
//! into any transport. Phase 3 adds live local transports:
//! UDP broadcast (Wi-Fi / Wi-Fi Direct group / Zinux IP), BLE chunk codec
//! (bytes only; radio needs platform APIs), and mesh flooding relay.
//! Phase 4 adds the audible fallback via WAV files (the device boundary:
//! play a file through a speaker, record one from a microphone).
//!
//! Usage:
//!   gringots keygen
//!   gringots send SOS [--seed <64hex>] [--nonce <32hex>]
//!                     [--timestamp N] [--expires N]
//!                     [--lat deg] [--lon deg] [--session <32hex>]
//!                     [--ref <32hex>] [--texthint "..."]
//!   gringots decode <frame-hex>
//!   gringots verify <frame-hex> [--now N]
//!   gringots broadcast <frame-hex> [--to host[:port]] [--port N]
//!   gringots listen [--port N] [--count N] [--timeout S] [--verify]
//!   gringots relay [--port N] [--to host[:port]] [--count N] [--ttl N]
//!   gringots ble-encode <frame-hex>
//!   gringots ble-decode <chunk-hex>...
//!   gringots audio-send <frame-hex> --out file.wav [--rate N]
//!                      [--repeat N] [--attention]
//!   gringots audio-listen <file.wav> [--verify]

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const root = @import("root.zig");
const types = root.types;
const frame = root.frame;
const msg = root.msg;
const ed = root.crypto_;
const transport = root.transport;
const ble = root.ble;
const udp = root.udp;
const mesh = root.mesh;
const fsk = root.fsk;
const apacket = root.apacket;
const wav = root.wav;
const agent = root.service;
const alocation = root.alocation;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        // Usage text is already printed for BadUsage; stay quiet otherwise
        // except for a one-line reason (no stack trace: CLI contract).
        if (err != error.BadUsage) std.debug.print("error: {t}\n", .{err});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len < 2) return usage();
    const cmd: []const u8 = args[1];
    if (std.mem.eql(u8, cmd, "keygen")) {
        try cmdKeygen(io, stdout);
    } else if (std.mem.eql(u8, cmd, "send")) {
        try cmdSend(io, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "decode")) {
        try cmdDecode(stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        try cmdVerify(io, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "broadcast")) {
        try cmdBroadcast(io, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "listen")) {
        try cmdListen(io, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "relay")) {
        try cmdRelay(io, stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ble-encode")) {
        try cmdBleEncode(stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ble-decode")) {
        try cmdBleDecode(stdout, args[2..]);
    } else if (std.mem.eql(u8, cmd, "audio-send")) {
        try cmdAudioSend(io, stdout, arena, args[2..]);
    } else if (std.mem.eql(u8, cmd, "audio-listen")) {
        try cmdAudioListen(io, stdout, arena, args[2..]);
    } else if (std.mem.eql(u8, cmd, "agent")) {
        try cmdAgent(io, stdout, arena, args[2..]);
    } else {
        return usage();
    }
    try stdout.flush();
}

fn usage() error{BadUsage} {
    std.debug.print(
        \\gringots — civilian SOS protocol demo (v1)
        \\
        \\  gringots keygen
        \\  gringots send SOS [--seed <64hex>] [--nonce <32hex>] [--timestamp N] [--expires N]
        \\                     [--lat deg] [--lon deg] [--session <32hex>] [--ref <32hex>]
        \\                     [--texthint "..."]
        \\  gringots decode <frame-hex>
        \\  gringots verify <frame-hex> [--now N]
        \\  gringots broadcast <frame-hex> [--to host[:port]] [--port N]
        \\                     [--from-port N]
        \\  gringots listen [--port N] [--count N] [--timeout S] [--verify]
        \\  gringots relay [--port N] [--to host[:port]] [--count N] [--ttl N]
        \\  gringots ble-encode <frame-hex>
        \\  gringots ble-decode <chunk-hex>...
        \\  gringots audio-send <frame-hex> --out file.wav [--rate N]
        \\                     [--repeat N] [--attention]
        \\  gringots audio-listen <file.wav> [--verify]
        \\  gringots agent [--seed H] [--now N] [--ticks N] [--tick-step S]
        \\                 [--inject H...] [--auto-approve | --auto-deny]
        \\                 [--mock-lat D --mock-lon D]
        \\                 [--live --port P [--to host[:port]] [--count N] [--sos]]
        \\
        \\Without --seed/--nonce/--timestamp the CLI uses OS randomness and the
        \\realtime clock. Explicit flags give deterministic, testable output.
        \\
    , .{});
    return error.BadUsage;
}

fn flagValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
    }
    return null;
}

/// Presence check for value-less boolean flags (--verify).
fn hasFlag(args: []const [:0]const u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn realtimeUnix(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .real);
    const ns = ts.raw.nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn parseHexFlag(value: []const u8, out: []u8) ![]u8 {
    return frame.hexDecode(value, out) catch return error.BadHexFlag;
}

fn cmdKeygen(io: Io, stdout: *Io.Writer) !void {
    var seed: [32]u8 = undefined;
    io.random(&seed); // OS CSPRNG via Io
    const kp = try ed.keypairFromSeed(seed);
    var seed_hex: [64]u8 = undefined;
    var pub_hex: [64]u8 = undefined;
    const sh = try frame.hexEncode(&seed, &seed_hex);
    const ph = try frame.hexEncode(&kp.public_key.toBytes(), &pub_hex);
    try stdout.print("seed={s}\npub={s}\n", .{ sh, ph });
}

fn cmdSend(io: Io, stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    const mt = types.MsgType.fromName(args[0]) orelse {
        std.debug.print("error: unknown message type '{s}'\n", .{args[0]});
        return error.BadUsage;
    };

    var seed: [32]u8 = undefined;
    var generated_seed = false;
    if (flagValue(args, "--seed")) |s| {
        var tmp: [32]u8 = undefined;
        _ = try parseHexFlag(s, &tmp);
        seed = tmp;
        if (tmp.len != 0 and s.len != 64) return error.BadHexFlag;
    } else {
        io.random(&seed);
        generated_seed = true;
    }
    const kp = try ed.keypairFromSeed(seed);

    var nonce: [16]u8 = undefined;
    if (flagValue(args, "--nonce")) |s| {
        var tmp: [16]u8 = undefined;
        const got = try parseHexFlag(s, &tmp);
        if (got.len != 16) return error.BadHexFlag;
        nonce = tmp;
    } else {
        io.random(&nonce);
    }

    const timestamp: u64 = if (flagValue(args, "--timestamp")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        realtimeUnix(io);
    const expires: u64 = if (flagValue(args, "--expires")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        timestamp +| types.DEFAULT_DISCLOSE_TTL_S;

    var b = msg.Builder{
        .msg_type = mt,
        .ephemeral_id = kp.public_key.toBytes(),
        .timestamp = timestamp,
        .expires = expires,
        .nonce = nonce,
    };
    if (flagValue(args, "--lat")) |s| {
        const deg = try std.fmt.parseFloat(f64, s);
        if (!(deg >= -90.0 and deg <= 90.0)) return error.BadCoord;
        b.lat = @intFromFloat(@round(deg * 1e7));
    }
    if (flagValue(args, "--lon")) |s| {
        const deg = try std.fmt.parseFloat(f64, s);
        if (!(deg >= -180.0 and deg <= 180.0)) return error.BadCoord;
        b.lon = @intFromFloat(@round(deg * 1e7));
    }
    var session_buf: [16]u8 = undefined;
    if (flagValue(args, "--session")) |s| {
        const got = try parseHexFlag(s, &session_buf);
        if (got.len != 16) return error.BadHexFlag;
        b.session_id = session_buf;
    }
    var ref_buf: [16]u8 = undefined;
    if (flagValue(args, "--ref")) |s| {
        const got = try parseHexFlag(s, &ref_buf);
        if (got.len != 16) return error.BadHexFlag;
        b.ref = ref_buf;
    }
    if (flagValue(args, "--texthint")) |s| b.text_hint = s;

    var body: [512]u8 = undefined;
    var fr: [600]u8 = undefined;
    const wire = msg.signAndFrame(&b, kp, &body, &fr) catch |err| {
        std.debug.print("error: cannot build {s}: {t}\n", .{ mt.name(), err });
        return err;
    };
    var hx: [1200]u8 = undefined;
    const out = try frame.hexEncode(wire, &hx);
    try stdout.print("{s}\n", .{out});
    if (generated_seed) {
        var sh: [64]u8 = undefined;
        std.debug.print("info: ephemeral seed={s} (save to verify/ack this episode)\n", .{
            try frame.hexEncode(&seed, &sh),
        });
    }
}

fn cmdDecode(stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    var raw: [600]u8 = undefined;
    const bytes = frame.hexDecode(args[0], &raw) catch return error.BadHexFlag;
    const dec = frame.decodeFrame(bytes) catch |err| {
        try stdout.print("INVALID framing: {t}\n", .{err});
        stdout.flush() catch {};
        return error.DecodeFailed;
    };
    const m = msg.parseBody(dec.body) catch |err| {
        try stdout.print("INVALID body: {t}\n", .{err});
        stdout.flush() catch {};
        return error.DecodeFailed;
    };
    try printMessage(stdout, &m, false);
}

fn cmdVerify(io: Io, stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    var raw: [600]u8 = undefined;
    const bytes = frame.hexDecode(args[0], &raw) catch return error.BadHexFlag;
    const now: u64 = if (flagValue(args, "--now")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        realtimeUnix(io);
    const m = msg.verifyFrame(bytes, now) catch |err| {
        // Silence/unknown must never read as acknowledgement.
        try stdout.print("INVALID (no acknowledgement): {t}\n", .{err});
        stdout.flush() catch {};
        return error.VerifyFailed;
    };
    try stdout.print("VALID\n", .{});
    try printMessage(stdout, &m, true);
}

fn printMessage(stdout: *Io.Writer, m: *const msg.Message, verified: bool) !void {
    var idh: [64]u8 = undefined;
    var noh: [32]u8 = undefined;
    var sigh: [128]u8 = undefined;
    try stdout.print("type:      {s} (0x{x:0>2})\n", .{ m.msg_type.name(), @intFromEnum(m.msg_type) });
    try stdout.print("id:        {s}\n", .{try frame.hexEncode(&m.ephemeral_id, &idh)});
    try stdout.print("timestamp: {d}\nexpires:   {d}\n", .{ m.timestamp, m.expires });
    try stdout.print("nonce:     {s}\n", .{try frame.hexEncode(&m.nonce, &noh)});
    if (m.lat) |la| try stdout.print("lat:       {d} (x1e7)\n", .{la});
    if (m.lon) |lo| try stdout.print("lon:       {d} (x1e7)\n", .{lo});
    if (m.session_id) |s| {
        var sh: [32]u8 = undefined;
        try stdout.print("session:   {s}\n", .{try frame.hexEncode(&s, &sh)});
    }
    if (m.ref) |r| {
        var rh: [32]u8 = undefined;
        try stdout.print("ref:       {s}\n", .{try frame.hexEncode(&r, &rh)});
    }
    if (m.text_hint) |t| try stdout.print("texthint:  {s}\n", .{t});
    try stdout.print("signature: {s}\n", .{try frame.hexEncode(&m.signature, &sigh)});
    if (verified) {
        var dbg: [512]u8 = undefined;
        try stdout.print("{s}\n", .{try msg.formatDebug(m, &dbg)});
    } else {
        try stdout.print("note: structure only — signature NOT verified (use verify)\n", .{});
    }
}

// ---------------------------------------------------------------------------
// Phase 3: local transports
// ---------------------------------------------------------------------------

fn parseCount(text: ?[]const u8) !u64 {
    const s = text orelse return 0; // 0 = unlimited
    return std.fmt.parseInt(u64, s, 10) catch return error.BadCount;
}

fn printHexLine(stdout: *Io.Writer, bytes: []const u8) !void {
    var hx: [1400]u8 = undefined;
    try stdout.print("{s}\n", .{try frame.hexEncode(bytes, &hx)});
}

/// broadcast <frame-hex> [--to host[:port]] [--port N] [--from-port N]
fn cmdBroadcast(io: Io, stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    const port = try udp.parsePort(flagValue(args, "--port"));
    var raw: [1500]u8 = undefined;
    const payload = frame.hexDecode(args[0], &raw) catch return error.BadHexFlag;

    // Fixed source port lets a co-located listener catch unicast replies.
    const from_port: u16 = if (flagValue(args, "--from-port")) |s|
        try std.fmt.parseInt(u16, s, 10)
    else
        0;
    var sock = try udp.bindSender(io, from_port);
    defer sock.close(io);
    var dest = try udp.parseTarget(flagValue(args, "--to"), port);
    try udp.sendFrame(io, &sock, &dest, payload);
    try stdout.print("sent {d} bytes to ", .{payload.len});
    try dest.format(stdout);
    try stdout.print(" (udp/{d})\n", .{dest.getPort()});
}

/// listen [--port N] [--count N] [--timeout S] [--verify]
fn cmdListen(io: Io, stdout: *Io.Writer, args: []const [:0]const u8) !void {
    const port = try udp.parsePort(flagValue(args, "--port"));
    const count = try parseCount(flagValue(args, "--count"));
    const want_verify = hasFlag(args, "--verify");
    const timeout_s: ?i64 = if (flagValue(args, "--timeout")) |s|
        std.fmt.parseInt(i64, s, 10) catch return error.BadCount
    else
        null;

    var sock = try udp.bindListener(io, port);
    defer sock.close(io);
    try stdout.print("listening udp/{d} (broadcast-capable)\n", .{port});
    try stdout.flush();

    var buf: [1500]u8 = undefined;
    var n: u64 = 0;
    while (count == 0 or n < count) {
        const im = if (timeout_s) |s| blk: {
            const to: Io.Timeout = .{ .duration = .{
                .raw = Io.Duration.fromSeconds(s),
                .clock = .real,
            } };
            break :blk sock.receiveTimeout(io, &buf, to) catch |err| {
                if (err == error.Timeout) {
                    try stdout.print("timeout: no datagram in {d}s\n", .{s});
                    try stdout.flush();
                    return;
                }
                return err;
            };
        } else try sock.receive(io, &buf);
        n += 1;
        try stdout.print("--- datagram {d} from ", .{n});
        try im.from.format(stdout);
        try stdout.print(" len={d}\n", .{im.data.len});
        try printHexLine(stdout, im.data);
        if (want_verify) {
            const m = msg.verifyFrame(im.data, realtimeUnix(io)) catch |err| {
                try stdout.print("INVALID (no acknowledgement): {t}\n", .{err});
                try stdout.flush();
                continue;
            };
            try stdout.print("VALID\n", .{});
            try printMessage(stdout, &m, true);
        } else if (frame.decodeFrame(im.data)) |dec| {
            if (msg.parseBody(dec.body)) |m| {
                try stdout.print("framing OK: {s} (unverified, use --verify)\n", .{m.msg_type.name()});
            } else |err| {
                try stdout.print("framing OK, body INVALID: {t}\n", .{err});
            }
        } else |err| {
            // May be a mesh envelope or garbage: report, don't crash.
            if (mesh.unwrap(im.data)) |p| {
                try stdout.print("mesh packet ttl={d} inner_len={d} (use relay to forward)\n", .{ p.ttl, p.frame.len });
            } else |_| {
                try stdout.print("not a Gringots frame: {t}\n", .{err});
            }
        }
        try stdout.flush();
    }
}

/// relay [--port N] [--to host[:port]] [--count N] [--ttl N]
/// Forwards validated mesh packets with TTL-1. Direct (non-mesh) frames
/// are reported, never forwarded: relaying must be explicit (TTL envelope).
fn cmdRelay(io: Io, stdout: *Io.Writer, args: []const [:0]const u8) !void {
    const port = try udp.parsePort(flagValue(args, "--port"));
    const count = try parseCount(flagValue(args, "--count"));
    const default_ttl: u8 = if (flagValue(args, "--ttl")) |s|
        std.fmt.parseInt(u8, s, 10) catch return error.BadCount
    else
        transport.max_ttl;
    if (default_ttl == 0 or default_ttl > transport.max_ttl) return error.BadCount;

    var sock = try udp.bindListener(io, port);
    defer sock.close(io);
    var dest = try udp.parseTarget(flagValue(args, "--to"), port);
    var relay_state = mesh.Relay{};
    try stdout.print("relaying udp/{d} -> ", .{port});
    try dest.format(stdout);
    try stdout.print(" (ttl cap {d})\n", .{default_ttl});
    try stdout.flush();

    var buf: [1500]u8 = undefined;
    var fwd: [1500]u8 = undefined;
    var n: u64 = 0;
    while (count == 0 or n < count) {
        const im = try sock.receive(io, &buf);
        n += 1;
        const p = mesh.unwrap(im.data) catch {
            try stdout.print("drop: direct frame is not relayed (needs TTL envelope)\n", .{});
            try stdout.flush();
            continue;
        };
        const dec = frame.decodeFrame(p.frame) catch |err| {
            try stdout.print("drop: inner framing INVALID: {t}\n", .{err});
            try stdout.flush();
            continue;
        };
        const m = msg.parseBody(dec.body) catch |err| {
            try stdout.print("drop: inner body INVALID: {t}\n", .{err});
            try stdout.flush();
            continue;
        };
        const ttl = @min(p.ttl, default_ttl);
        const next = relay_state.shouldRelay(m.ephemeral_id, m.nonce, ttl, m.expires, realtimeUnix(io)) orelse {
            try stdout.print("drop: duplicate or TTL spent ({s})\n", .{m.msg_type.name()});
            try stdout.flush();
            continue;
        };
        const out = try mesh.wrap(p.frame, next, &fwd);
        try udp.sendFrame(io, &sock, &dest, out);
        try stdout.print("forwarded {s} ttl {d}->{d} len={d}\n", .{ m.msg_type.name(), p.ttl, next, out.len });
        try stdout.flush();
    }
}

/// ble-encode <frame-hex>: print BLE chunk(s) as hex, one per line.
fn cmdBleEncode(stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    var raw: [600]u8 = undefined;
    const bytes = frame.hexDecode(args[0], &raw) catch return error.BadHexFlag;
    const dec = try frame.decodeFrame(bytes);
    const m = try msg.parseBody(dec.body);
    var chunks: [ble.MAX_CHUNKS][transport.mtu.ble_chunk]u8 = undefined;
    // Fragment the complete frame. The body is only the reassembly payload;
    // callers must receive a normal frame that still has its CRC and header.
    const f = try ble.fragment(bytes, m.nonce, &chunks);
    try stdout.print("chunks: {d}\n", .{f.count});
    for (0..f.count) |i| {
        try printHexLine(stdout, chunks[i][0..f.lens[i]]);
    }
}

/// ble-decode <chunk-hex>...: feed chunks, print frame when complete.
fn cmdBleDecode(stdout: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    var re = ble.Reassembler{};
    var cbuf: [256]u8 = undefined;
    var fbuf: [600]u8 = undefined;
    for (args) |c| {
        const chunk = frame.hexDecode(c, &cbuf) catch return error.BadHexFlag;
        if (try re.feed(chunk, &fbuf)) |fr| {
            try stdout.print("complete: {d} bytes\n", .{fr.len});
            try printHexLine(stdout, fr);
            return;
        }
    }
    try stdout.print("incomplete: need more chunks\n", .{});
}

// ---------------------------------------------------------------------------
// Phase 4: audible fallback (WAV as the device boundary)
// ---------------------------------------------------------------------------

/// Human-readable fallback sentence (spoken by user or device TTS;
/// the WAV below carries only the machine-readable packet).
pub const SPOKEN_SENTENCE = "Civilian. I am not a threat.";

fn attentionLen(rate: u32) usize {
    const beep: usize = @intCast(rate * 15 / 100); // 0.15 s
    const gap: usize = @intCast(rate / 10); // 0.10 s
    const tail: usize = @intCast(rate * 3 / 10); // 0.30 s
    return 3 * (beep + gap) + tail;
}

fn fillAttention(samples: []i16, rate: u32) void {
    const beep: usize = @intCast(rate * 15 / 100);
    const gap: usize = @intCast(rate / 10);
    const r: f64 = @floatFromInt(rate);
    const inc = 2.0 * std.math.pi * 880.0 / r;
    var phase: f64 = 0;
    var o: usize = 0;
    for (0..3) |_| {
        for (0..beep) |_| {
            phase += inc;
            samples[o] = @intFromFloat(@sin(phase) * @as(f64, @floatFromInt(fsk.AMPLITUDE)));
            o += 1;
        }
        for (0..gap) |_| {
            samples[o] = 0;
            o += 1;
        }
    }
    for (o..samples.len) |i| samples[i] = 0;
}

/// audio-send <frame-hex> --out f.wav [--rate N] [--repeat N] [--attention]
fn cmdAudioSend(io: Io, stdout: *Io.Writer, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    const out_path = flagValue(args, "--out") orelse {
        std.debug.print("error: --out file.wav is required (refusing to guess)\n", .{});
        return error.BadUsage;
    };
    const rate: u32 = if (flagValue(args, "--rate")) |s|
        std.fmt.parseInt(u32, s, 10) catch return error.BadCount
    else
        fsk.DEFAULT_RATE;
    const repeat: usize = if (flagValue(args, "--repeat")) |s|
        std.fmt.parseInt(usize, s, 10) catch return error.BadCount
    else
        1;
    if (repeat == 0 or repeat > 5) return error.BadCount;
    const attention = hasFlag(args, "--attention");

    var rawbuf: [600]u8 = undefined;
    const full = frame.hexDecode(args[0], &rawbuf) catch return error.BadHexFlag;
    _ = try frame.decodeFrame(full); // validate framing before encoding audio

    const modem = try fsk.Modem.init(rate);
    const bits = try arena.alloc(u8, apacket.MAX_PACKET_BITS);
    const cw = try arena.alloc(u8, apacket.MAX_CODEWORD_BYTES);
    const pkt = try apacket.encodePacket(full, bits, cw);

    const gap: usize = @intCast(rate / 2); // 0.5 s silence between repeats
    const att = if (attention) attentionLen(rate) else 0;
    const per: usize = pkt.len * modem.spb;
    const total = att + repeat * per + (repeat - 1) * gap;
    const samples = try arena.alloc(i16, total);
    var o: usize = 0;
    if (attention) {
        fillAttention(samples[0..att], rate);
        o = att;
    }
    for (0..repeat) |r| {
        const s = modem.modulate(pkt, samples[o .. o + per]);
        o += s.len;
        if (r + 1 < repeat) {
            for (samples[o .. o + gap]) |*x| x.* = 0;
            o += gap;
        }
    }

    const wbytes = try arena.alloc(u8, wav.HEADER_LEN + total * 2);
    const w = try wav.write(samples, rate, wbytes);
    var f = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, w);

    const ms: u64 = @intCast(total * 1000 / rate);
    try stdout.print("wrote {s}: rate={d} bits={d} repeats={d} duration={d}ms\n", .{ out_path, rate, pkt.len, repeat, ms });
    try stdout.print("human fallback — say aloud: \"{s}\"\n", .{SPOKEN_SENTENCE});
}

/// audio-listen <file.wav> [--verify]
/// Decodes acoustic packets. Silence/garbage is reported as NO SIGNAL;
/// it is never an acknowledgement.
fn cmdAudioListen(io: Io, stdout: *Io.Writer, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 1) return usage();
    const data = try Io.Dir.cwd().readFileAlloc(io, args[0], arena, Io.Limit.limited(32 * 1024 * 1024));
    const sbuf = try arena.alloc(i16, data.len / 2 + 1);
    const w = try wav.parse(data, sbuf);
    const modem = try fsk.Modem.init(w.rate);
    const nbits = w.samples.len / modem.spb;
    if (nbits == 0) {
        try stdout.print("NO SIGNAL (no acknowledgement)\n", .{});
        stdout.flush() catch {};
        return error.NoSignal;
    }
    const bits = try arena.alloc(u8, nbits);
    const dbits = modem.demodulate(w.samples[0 .. nbits * modem.spb], bits, null);
    const cw = try arena.alloc(u8, apacket.MAX_CODEWORD_BYTES);
    const frbuf = try arena.alloc(u8, 600);
    const fr = apacket.decodePacket(dbits, frbuf, cw) catch {
        try stdout.print("NO SIGNAL (no acknowledgement)\n", .{});
        stdout.flush() catch {};
        return error.NoSignal;
    };
    try stdout.print("ACOUSTIC FRAME len={d}\n", .{fr.len});
    try printHexLine(stdout, fr);
    if (hasFlag(args, "--verify")) {
        const m = msg.verifyFrame(fr, realtimeUnix(io)) catch |err| {
            try stdout.print("INVALID (no acknowledgement): {t}\n", .{err});
            stdout.flush() catch {};
            return error.VerifyFailed;
        };
        try stdout.print("VALID\n", .{});
        try printMessage(stdout, &m, true);
    } else {
        const dec = try frame.decodeFrame(fr);
        const m = try msg.parseBody(dec.body);
        try printMessage(stdout, &m, false);
    }
}

// ---------------------------------------------------------------------------
// Phase 5: device agent (background-service core demo)
// ---------------------------------------------------------------------------

const AgentPolicy = enum { ask, auto_approve, auto_deny };

/// Collect values following `--inject` until the next `--flag` or end.
fn injectList(arena: std.mem.Allocator, args: []const [:0]const u8) ![]const []const u8 {
    var list: [64][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--inject")) continue;
        i += 1;
        while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
            if (n >= list.len) return error.TooManyInjects;
            list[n] = args[i];
            n += 1;
        }
        // step back: outer loop will re-examine the flag token
        if (i < args.len) i -= 1;
    }
    const out = try arena.alloc([]const u8, n);
    @memcpy(out, list[0..n]);
    return out;
}

fn drainOutbox(stdout: *Io.Writer, svc: *agent.Service, sink: ?FrameSink) !void {
    while (svc.takeFrame()) |fr| {
        // Live mode: replies go straight back to the sender (unicast).
        if (sink) |s| try udp.sendFrame(s.io, s.sock, s.dest, fr);
        try stdout.print("out: ", .{});
        try printHexLine(stdout, fr);
        const dec = try frame.decodeFrame(fr);
        const m = try msg.parseBody(dec.body);
        var dbg: [512]u8 = undefined;
        try stdout.print("     {s}\n", .{try msg.formatDebug(&m, &dbg)});
    }
}

fn handleConsents(
    stdout: *Io.Writer,
    svc: *agent.Service,
    policy: AgentPolicy,
    fix: ?alocation.Fix,
    now: u64,
    sink: ?FrameSink,
) !void {
    // Snapshot pending ids first (decide mutates the queue).
    var ids: [4]u32 = undefined;
    var n: usize = 0;
    for (&svc.consents.slots) |*slot| {
        if (slot.*) |r| {
            if (r.state == .pending and n < ids.len) {
                ids[n] = r.id;
                n += 1;
            }
        }
    }
    for (ids[0..n]) |id| {
        switch (policy) {
            .ask => try stdout.print("CONSENT NEEDED id={d} (no policy: left pending)\n", .{id}),
            .auto_approve => {
                const o = try svc.decide(id, true, fix, now);
                try stdout.print("consent id={d} AUTO-APPROVED -> {t}\n", .{ id, o });
                try drainOutbox(stdout, svc, sink);
            },
            .auto_deny => {
                const o = try svc.decide(id, false, null, now);
                try stdout.print("consent id={d} AUTO-DENIED -> {t}\n", .{ id, o });
                try drainOutbox(stdout, svc, sink);
            },
        }
    }
}

/// Where drained outbox frames go in live mode (unicast reply path).
/// Inject (offline) mode passes null: frames are only printed.
const FrameSink = struct {
    io: Io,
    sock: *const net.Socket,
    dest: *const net.IpAddress,
};

/// agent: deterministic inject mode by default; --live binds UDP.
fn cmdAgent(io: Io, stdout: *Io.Writer, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    var seed: [32]u8 = undefined;
    if (flagValue(args, "--seed")) |s| {
        var tmp: [32]u8 = undefined;
        const got = try parseHexFlag(s, &tmp);
        if (got.len != 32) return error.BadHexFlag;
        seed = tmp;
    } else {
        io.random(&seed);
        var sh: [64]u8 = undefined;
        std.debug.print("info: agent seed={s}\n", .{try frame.hexEncode(&seed, &sh)});
    }
    var now: u64 = if (flagValue(args, "--now")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        realtimeUnix(io);
    const ticks: u64 = if (flagValue(args, "--ticks")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        3;
    const step: u64 = if (flagValue(args, "--tick-step")) |s|
        try std.fmt.parseInt(u64, s, 10)
    else
        30;
    const policy: AgentPolicy = if (hasFlag(args, "--auto-approve"))
        .auto_approve
    else if (hasFlag(args, "--auto-deny"))
        .auto_deny
    else
        .ask;
    if (policy == .auto_approve) {
        std.debug.print("warning: --auto-approve is for demos/tests only; ship with UI consent\n", .{});
    }
    var mock = alocation.Mock{};
    if (flagValue(args, "--mock-lat")) |la| {
        const lon_s = flagValue(args, "--mock-lon") orelse return error.BadCount;
        const lat = try std.fmt.parseFloat(f64, la);
        const lon = try std.fmt.parseFloat(f64, lon_s);
        try mock.setDeg(lat, lon, now, 10);
    } else {
        try mock.setDeg(60.1699, 24.9384, now, 10); // documented mock default
    }
    const fix = mock.provider().get(now);
    try stdout.print("mock fix: lat=60.1699000 lon=24.9384000 (MOCK, at={d})\n", .{now});

    var svc = try agent.Service.init(.{ .seed = seed }, now);

    if (hasFlag(args, "--live")) {
        return cmdAgentLive(io, stdout, &svc, policy, args);
    }

    // Deterministic inject mode.
    const injects = try injectList(arena, args);
    for (injects) |hex| {
        const buf = try arena.alloc(u8, hex.len / 2 + 1);
        const raw = frame.hexDecode(hex, buf) catch return error.BadHexFlag;
        try svc.onFrame(raw, now);
        try stdout.print("in: {d} bytes processed\n", .{raw.len});
        try drainOutbox(stdout, &svc, null);
    }
    try handleConsents(stdout, &svc, policy, fix, now, null);

    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        now +|= step;
        try svc.tick(now);
        // Refresh mock fix timestamp so it never goes stale mid-run.
        if (mock.fix) |*f| f.at = now;
        const fresh = mock.provider().get(now);
        try drainOutbox(stdout, &svc, null);
        try handleConsents(stdout, &svc, policy, fresh, now, null);
    }
    try stdout.print("agent done: acked={} pending={d}\n", .{ svc.acked, svc.pendingConsents() });
}

/// Live UDP mode: optional opening SOS burst, then receive -> handle ->
/// reply to sender. Consent per policy with the mock fix.
fn cmdAgentLive(
    io: Io,
    stdout: *Io.Writer,
    svc: *agent.Service,
    policy: AgentPolicy,
    args: []const [:0]const u8,
) !void {
    const port = try udp.parsePort(flagValue(args, "--port"));
    const count = try parseCount(flagValue(args, "--count"));
    var sock = try udp.bindListener(io, port);
    defer sock.close(io);
    try stdout.print("agent live on udp/{d}\n", .{port});
    try stdout.flush();

    if (hasFlag(args, "--sos")) {
        const now = realtimeUnix(io);
        try svc.tick(now);
        var dest = try udp.parseTarget(flagValue(args, "--to"), port);
        while (svc.takeFrame()) |fr| {
            try udp.sendFrame(io, &sock, &dest, fr);
            try stdout.print("sos burst: {d} bytes\n", .{fr.len});
        }
        try stdout.flush();
    }

    var buf: [1500]u8 = undefined;
    var n: u64 = 0;
    while (count == 0 or n < count) {
        const im = try sock.receive(io, &buf);
        n += 1;
        const now = realtimeUnix(io);
        try svc.onFrame(im.data, now);
        try stdout.print("in: {d} bytes from ", .{im.data.len});
        try im.from.format(stdout);
        try stdout.print("\n", .{});
        // Replies (immediate + consent-driven) go back to the sender.
        const sink = FrameSink{ .io = io, .sock = &sock, .dest = &im.from };
        try drainOutbox(stdout, svc, sink);
        // Consent decisions for anything still pending.
        try handleConsentsLive(stdout, svc, policy, now, sink);
        try stdout.flush();
    }
}

fn handleConsentsLive(stdout: *Io.Writer, svc: *agent.Service, policy: AgentPolicy, now: u64, sink: FrameSink) !void {
    // Live mode has no UI: without an auto policy, requests stay pending
    // (visible in the pending count) until the host decides via FFI.
    if (policy == .ask) {
        if (svc.pendingConsents() > 0) {
            try stdout.print("pending consents: {d} (no auto policy)\n", .{svc.pendingConsents()});
        }
        return;
    }
    // NOTE: live demo fix would come from the platform provider; the CLI
    // demo reuses the documented mock default via a fresh timestamp.
    var mock = alocation.Mock{};
    try mock.setDeg(60.1699, 24.9384, now, 10);
    const fix = mock.provider().get(now);
    try handleConsents(stdout, svc, policy, fix, now, sink);
}
