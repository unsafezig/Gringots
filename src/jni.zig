//! JNI bridge for the Android APK (roadmap Phase 5).
//!
//! The APK loads `libgringots.so` and calls `GringotsBridge` static
//! natives, bound here with `RegisterNatives` (no name mangling).
//! Buffer-based and fixed-cap: all JNI arrays are range-checked before
//! touching native memory; failures return null / negative codes, never
//! throw. Function-table indices below are from NDK `jni.h`
//! (r30-verified: GetVersion 4, FindClass 6, GetArrayLength 171,
//! NewByteArray 176, GetByteArrayRegion 200, SetByteArrayRegion 208,
//! RegisterNatives 215; VM GetEnv 6).
//!
//! This file compiles for `aarch64-linux-android` (`zig build
//! android-lib`) and is NOT host-testable (no JVM on host); correctness
//! of the underlying calls is covered by `ffi.zig` host tests.

const ffi = @import("ffi.zig");
const hp = @import("host_protocol");

// Local getauxval (src/android_auxv.zig): resolves Zig libc startup's
// reference at static link time, since Bionic cannot be linked without an
// NDK sysroot. The comptime touch keeps the export in the shared object.
const auxv = @import("android_auxv.zig");
comptime {
    _ = auxv.getauxval;
}

pub const JNI_VERSION_1_6: i32 = 0x00010006;
pub const JNI_ERR: i32 = -1;
pub const JNI_OK: i32 = 0;

const Env = *anyopaque;
const Vm = *anyopaque;

fn tableFn(env: Env, comptime idx: usize, comptime F: type) F {
    const table_ptr: *[*]*const anyopaque = @ptrCast(@alignCast(env));
    return @ptrCast(@alignCast(table_ptr.*[idx]));
}

const JNINativeMethod = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    fn_ptr: ?*const anyopaque,
};

fn findClass(env: Env, name: [*:0]const u8) ?*anyopaque {
    const F = *const fn (Env, [*:0]const u8) callconv(.c) ?*anyopaque;
    return tableFn(env, 6, F)(env, name);
}

fn registerNatives(env: Env, clazz: *anyopaque, natives: [*]const JNINativeMethod, n: i32) i32 {
    const F = *const fn (Env, *anyopaque, [*]const JNINativeMethod, i32) callconv(.c) i32;
    return tableFn(env, 215, F)(env, clazz, natives, n);
}

fn getArrayLength(env: Env, arr: *anyopaque) i32 {
    const F = *const fn (Env, *anyopaque) callconv(.c) i32;
    return tableFn(env, 171, F)(env, arr);
}

fn newByteArray(env: Env, len: i32) ?*anyopaque {
    const F = *const fn (Env, i32) callconv(.c) ?*anyopaque;
    return tableFn(env, 176, F)(env, len);
}

fn getByteArrayRegion(env: Env, arr: *anyopaque, start: i32, len: i32, buf: [*]u8) void {
    const F = *const fn (Env, *anyopaque, i32, i32, [*]u8) callconv(.c) void;
    tableFn(env, 200, F)(env, arr, start, len, buf);
}

fn setByteArrayRegion(env: Env, arr: *anyopaque, start: i32, len: i32, buf: [*]const u8) void {
    const F = *const fn (Env, *anyopaque, i32, i32, [*]const u8) callconv(.c) void;
    tableFn(env, 208, F)(env, arr, start, len, buf);
}

/// version()I
fn jni_version(_: Env, _: *anyopaque) callconv(.c) i32 {
    return @intCast(ffi.gringots_version());
}

/// makeSos([BJJ[B)[B — null on any failure.
fn jni_make_sos(env: Env, _: *anyopaque, seed_arr: *anyopaque, ts: i64, exp: i64, nonce_arr: *anyopaque) callconv(.c) ?*anyopaque {
    if (getArrayLength(env, seed_arr) != 32) return null;
    if (getArrayLength(env, nonce_arr) != 16) return null;
    var seed: [32]u8 = undefined;
    var nonce: [16]u8 = undefined;
    getByteArrayRegion(env, seed_arr, 0, 32, &seed);
    getByteArrayRegion(env, nonce_arr, 0, 16, &nonce);
    var out: [600]u8 = undefined;
    const n = ffi.gringots_make_sos(&seed, 32, @bitCast(ts), @bitCast(exp), &nonce, 16, &out, 600);
    if (n <= 0 or n > 600) return null;
    const arr = newByteArray(env, @intCast(n)) orelse return null;
    setByteArrayRegion(env, arr, 0, @intCast(n), &out);
    return arr;
}

/// verifyFrame([BJ)I — 0 valid, 1 invalid.
fn jni_verify(env: Env, _: *anyopaque, frame_arr: *anyopaque, now: i64) callconv(.c) i32 {
    const len = getArrayLength(env, frame_arr);
    if (len <= 0 or len > 1024) return 1;
    var buf: [1024]u8 = undefined;
    getByteArrayRegion(env, frame_arr, 0, len, &buf);
    return ffi.gringots_verify_frame(&buf, @intCast(len), @bitCast(now));
}

/// describeFrame([B)[B — debug text bytes, null on any failure.
fn jni_describe(env: Env, _: *anyopaque, frame_arr: *anyopaque) callconv(.c) ?*anyopaque {
    const len = getArrayLength(env, frame_arr);
    if (len <= 0 or len > 1024) return null;
    var buf: [1024]u8 = undefined;
    getByteArrayRegion(env, frame_arr, 0, len, &buf);
    var out: [512]u8 = undefined;
    const n = ffi.gringots_describe(&buf, @intCast(len), &out, 512);
    if (n <= 0 or n > 512) return null;
    const arr = newByteArray(env, @intCast(n)) orelse return null;
    setByteArrayRegion(env, arr, 0, @intCast(n), &out);
    return arr;
}

const methods = [_]JNINativeMethod{
    .{ .name = "version", .signature = "()I", .fn_ptr = @ptrCast(&jni_version) },
    .{ .name = "makeSos", .signature = "([BJJ[B)[B", .fn_ptr = @ptrCast(&jni_make_sos) },
    .{ .name = "verifyFrame", .signature = "([BJ)I", .fn_ptr = @ptrCast(&jni_verify) },
    .{ .name = "describeFrame", .signature = "([B)[B", .fn_ptr = @ptrCast(&jni_describe) },
    .{ .name = "wrapSos", .signature = "([B)[B", .fn_ptr = @ptrCast(&jni_wrap_sos) },
    .{ .name = "unwrapDeliver", .signature = "([B)[B", .fn_ptr = @ptrCast(&jni_unwrap_deliver) },
};

/// wrapSos([B)[B — GUEST_SOS_SEND datagram bytes, null on any failure.
fn jni_wrap_sos(env: Env, _: *anyopaque, sos_arr: *anyopaque) callconv(.c) ?*anyopaque {
    const len = getArrayLength(env, sos_arr);
    if (len <= 0 or len > hp.MAX_PAYLOAD) return null;
    var sos: [hp.MAX_PAYLOAD]u8 = undefined;
    getByteArrayRegion(env, sos_arr, 0, len, &sos);
    const slen: usize = @intCast(len);
    hp.checkGringotsPayload(sos[0..slen]) catch return null;
    var out: [hp.MAX_DATAGRAM]u8 = undefined;
    const dg = hp.encode(.guest_sos_send, sos[0..slen], &out) catch return null;
    const arr = newByteArray(env, @intCast(dg.len)) orelse return null;
    setByteArrayRegion(env, arr, 0, @intCast(dg.len), dg.ptr);
    return arr;
}

/// unwrapDeliver([B)[B — HOST_FRAME_DELIVER payload bytes, null otherwise
/// (HOST_ERROR and anything else mean "no acknowledgement").
fn jni_unwrap_deliver(env: Env, _: *anyopaque, dg_arr: *anyopaque) callconv(.c) ?*anyopaque {
    const len = getArrayLength(env, dg_arr);
    if (len <= 0 or len > hp.MAX_DATAGRAM) return null;
    var buf: [hp.MAX_DATAGRAM]u8 = undefined;
    getByteArrayRegion(env, dg_arr, 0, len, &buf);
    const ulen: usize = @intCast(len);
    const m = hp.decode(buf[0..ulen]) catch return null;
    if (m.op != .host_frame_deliver) return null;
    const arr = newByteArray(env, @intCast(m.payload.len)) orelse return null;
    setByteArrayRegion(env, arr, 0, @intCast(m.payload.len), m.payload.ptr);
    return arr;
}

/// JNI_OnLoad: bind GringotsBridge natives, report 1.6.
export fn JNI_OnLoad(vm: Vm, _: ?*anyopaque) i32 {
    const GetEnv = *const fn (Vm, **anyopaque, i32) callconv(.c) i32;
    const vm_table: *[*]*const anyopaque = @ptrCast(@alignCast(vm));
    const getenv: GetEnv = @ptrCast(@alignCast(vm_table.*[6]));
    var env: *anyopaque = undefined;
    if (getenv(vm, @ptrCast(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    const clazz = findClass(env, "ee/vaino/gringots/GringotsBridge") orelse return JNI_ERR;
    if (registerNatives(env, clazz, &methods, methods.len) != JNI_OK) return JNI_ERR;
    return JNI_VERSION_1_6;
}
