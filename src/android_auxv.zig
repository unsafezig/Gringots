//! Local getauxval for Zig-built Android JNI libraries (roadmap Phase 5).
//!
//! Zig 0.16 cannot link Bionic without an NDK sysroot, so the JNI .so
//! ships without DT_NEEDED libc.so. Zig's libc startup (start.zig reads
//! AT_PHDR/AT_PHNUM for stack expansion) still references libc's
//! getauxval, and Android's classloader-namespace linker refuses to
//! resolve that bare reference at dlopen -- even though every device libc
//! exports the symbol (verified DEFINED on the API-36 emulator libc).
//!
//! Defining getauxval here resolves those references at static link time
//! against the real auxiliary vector, parsed from /proc/self/auxv with raw
//! syscalls (no libc, no TLS, no allocation). References from inside this
//! .so bind to this definition; the rest of the process keeps using
//! Bionic's own getauxval, so there is no interposition hazard.
//!
//! All Android ABIs are little-endian, so pairs decode little-endian.

const std = @import("std");
const linux = std.os.linux;

pub const AT_NULL: usize = 0;

/// Pure parser over one auxv snapshot. Entries are native-word pairs
/// (type, value) terminated by AT_NULL. Returns null on miss or on a
/// truncated snapshot (fail closed, like libc's ENOENT path returning 0).
pub fn lookup(auxv_bytes: []const u8, query: usize) ?usize {
    const w = @sizeOf(usize);
    var i: usize = 0;
    while (i + 2 * w <= auxv_bytes.len) : (i += 2 * w) {
        const t = std.mem.readInt(usize, auxv_bytes[i..][0..w], .little);
        const v = std.mem.readInt(usize, auxv_bytes[i + w ..][0..w], .little);
        if (t == AT_NULL) return null;
        if (t == query) return v;
    }
    return null;
}

/// Read one /proc/self/auxv snapshot into buf. Returns the byte count, or
/// null when it cannot be read. Callers treat null as "no value".
fn snapshot(buf: []u8) ?usize {
    const path: [*:0]const u8 = "/proc/self/auxv";
    const r = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = switch (linux.errno(r)) {
        .SUCCESS => @intCast(r),
        else => return null,
    };
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf[total..].ptr, buf.len - total);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            else => return null,
        }
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// getauxval(3): real values from the kernel aux vector. Returns 0 on miss
/// like Bionic. errno is deliberately left untouched: there is no libc
/// errno here, and touching the extern threadlocal errno would pull the
/// global-dynamic TLS model whose __tls_get_addr resolver Bionic's linker
/// does not provide.
pub export fn getauxval(query: c_ulong) c_ulong {
    var buf: [1024]u8 = undefined;
    const n = snapshot(&buf) orelse return 0;
    return @intCast(lookup(buf[0..n], query) orelse 0);
}

const testing = std.testing;

fn encodePair(blob: []u8, idx: usize, t: usize, v: usize) void {
    const w = @sizeOf(usize);
    std.mem.writeInt(usize, blob[idx * 2 * w ..][0..w], t, .little);
    std.mem.writeInt(usize, blob[idx * 2 * w + w ..][0..w], v, .little);
}

test "lookup hits, misses and AT_NULL query" {
    var blob: [3 * 2 * @sizeOf(usize)]u8 = undefined;
    encodePair(&blob, 0, 3, 0x400040);
    encodePair(&blob, 1, 9, 0x1000);
    encodePair(&blob, 2, AT_NULL, 0);
    try testing.expectEqual(@as(?usize, 0x400040), lookup(&blob, 3));
    try testing.expectEqual(@as(?usize, 0x1000), lookup(&blob, 9));
    try testing.expectEqual(@as(?usize, null), lookup(&blob, 7));
    // Querying AT_NULL itself terminates the scan: miss, like libc ENOENT.
    try testing.expectEqual(@as(?usize, null), lookup(&blob, AT_NULL));
}

test "lookup fails closed on truncated snapshot" {
    var blob: [2 * @sizeOf(usize) + 1]u8 = undefined;
    encodePair(&blob, 0, 3, 0x400040);
    blob[blob.len - 1] = 0xFF; // dangling byte, no complete pair, no terminator
    // A complete pair before the truncation is still readable ...
    try testing.expectEqual(@as(?usize, 0x400040), lookup(&blob, 3));
    // ... but the scan stops at the truncation instead of overrunning.
    try testing.expectEqual(@as(?usize, null), lookup(&blob, 7));
    try testing.expectEqual(@as(?usize, null), lookup("", 3));
}
