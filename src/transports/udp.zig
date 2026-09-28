//! UDP broadcast transport: Wi-Fi / Wi-Fi Direct (formed group) / Zinux IP.
//!
//! One Gringots frame = one UDP datagram to DEFAULT_PORT (4848).
//! All socket calls need `std.Io`; address parsing below is pure and
//! unit-tested. Live send/receive is exercised through the CLI
//! (`broadcast` / `listen` / `relay`) on loopback.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const t = @import("transport.zig");

pub const port: u16 = t.DEFAULT_PORT;

/// Parse `--to` targets:
///   null                -> 255.255.255.255:default_port (broadcast)
///   "1.2.3.4"           -> that host :default_port
///   "1.2.3.4:5678"      -> literal with port
///   "[::1]" / "[::1]:5" -> IPv6 literal forms
pub fn parseTarget(text: ?[]const u8, default_port: u16) !net.IpAddress {
    const s = text orelse return .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = default_port } };
    if (s.len == 0) return error.InvalidAddress;
    if (net.IpAddress.parseLiteral(s)) |lit| {
        var a = lit;
        if (a.getPort() == 0) a.setPort(default_port);
        return a;
    } else |_| {}
    return net.IpAddress.parse(s, default_port) catch return error.InvalidAddress;
}

pub fn parsePort(text: ?[]const u8) !u16 {
    const s = text orelse return port;
    return std.fmt.parseInt(u16, s, 10) catch return error.InvalidPort;
}

/// Bind 0.0.0.0:listen_port for datagrams (broadcast-capable).
pub fn bindListener(io: Io, listen_port: u16) !net.Socket {
    const addr = net.IpAddress{ .ip4 = .unspecified(listen_port) };
    return addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
}

/// Bind a local port for sending (0 = ephemeral).
pub fn bindSender(io: Io, local_port: u16) !net.Socket {
    const addr = net.IpAddress{ .ip4 = .unspecified(local_port) };
    return addr.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
}

/// Send one frame-sized datagram. Oversize payloads are rejected, never
/// silently truncated (UDP has no framing to recover it).
pub fn sendFrame(io: Io, sock: *const net.Socket, dest: *const net.IpAddress, payload: []const u8) !void {
    if (payload.len == 0 or payload.len > t.mtu.udp_payload) return error.PayloadTooLarge;
    try sock.send(io, dest, payload);
}

const testing = std.testing;

test "parseTarget covers broadcast, host, host:port, ipv6" {
    const b = try parseTarget(null, 4848);
    try testing.expect(b.eql(&net.IpAddress{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = 4848 } }));

    const h = try parseTarget("192.168.1.7", 4848);
    try testing.expectEqual(@as(u16, 4848), h.getPort());

    const hp = try parseTarget("192.168.1.7:9999", 4848);
    try testing.expectEqual(@as(u16, 9999), hp.getPort());

    const v6 = try parseTarget("[::1]:1234", 4848);
    try testing.expectEqual(@as(u16, 1234), v6.getPort());

    try testing.expectError(error.InvalidAddress, parseTarget("not a host!!", 4848));
    try testing.expectError(error.InvalidAddress, parseTarget("", 4848));
    try testing.expectEqual(@as(u16, 4848), try parsePort(null));
    try testing.expectEqual(@as(u16, 1), try parsePort("1"));
    try testing.expectError(error.InvalidPort, parsePort("abc"));
}
