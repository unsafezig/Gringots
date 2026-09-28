const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI executable. main.zig imports root.zig relatively, so no
    // cross-module wiring is needed.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "gringots",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the Gringots CLI (use -- <args> after -- to pass args)");
    run_step.dependOn(&run_cmd.step);

    // Static C-ABI library for platform embedding (Android JNI, iOS,
    // firmware). Cross-compile e.g.: zig build -Dtarget=aarch64-linux-android
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "gringots",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Unit tests: root.zig aggregates tests from all library files.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // FFI self-tests (C ABI callable directly in-process).
    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ffi_tests = b.addTest(.{ .root_module = ffi_test_mod });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);
    test_step.dependOn(&run_ffi_tests.step);

    // Phase 0/4: Zinux guest-host boundary + gringotsd + receiver + e2e.
    // Zig 0.16 forbids relative @import outside the module root and
    // duplicate files across modules, so src/ is exposed once via
    // root.zig and the new zinux/ files import that single module.
    const gringots_root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hp_mod = b.createModule(.{
        .root_source_file = b.path("zinux/host_protocol/host_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hp_tests = b.addTest(.{ .root_module = hp_mod });
    test_step.dependOn(&b.addRunArtifact(hp_tests).step);

    const svc_ipc_mod = b.createModule(.{
        .root_source_file = b.path("zinux/gringotsd/service_ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    svc_ipc_mod.addImport("gringots_root", gringots_root_mod);
    const svc_ipc_tests = b.addTest(.{ .root_module = svc_ipc_mod });
    test_step.dependOn(&b.addRunArtifact(svc_ipc_tests).step);

    const rx_mod = b.createModule(.{
        .root_source_file = b.path("zinux/test_receiver/receiver.zig"),
        .target = target,
        .optimize = optimize,
    });
    rx_mod.addImport("gringots_root", gringots_root_mod);
    const rx_tests = b.addTest(.{ .root_module = rx_mod });
    test_step.dependOn(&b.addRunArtifact(rx_tests).step);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/host_bridge/e2e_sos_ack.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("host_protocol", hp_mod);
    e2e_mod.addImport("service_ipc", svc_ipc_mod);
    e2e_mod.addImport("test_receiver", rx_mod);
    e2e_mod.addImport("gringots_root", gringots_root_mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);

    // Phase 1 smoke: new guest/host code must also compile for
    // aarch64-freestanding (no kernel port yet — compile gate only).
    const aarch64_query = std.Target.Query{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const aarch64_target = b.resolveTargetQuery(aarch64_query);
    const hp_aarch64_mod = b.createModule(.{
        .root_source_file = b.path("zinux/host_protocol/host_protocol.zig"),
        .target = aarch64_target,
        .optimize = optimize,
    });
    hp_aarch64_mod.single_threaded = true;
    const hp_aarch64_lib = b.addLibrary(.{
        .name = "host_protocol_aarch64",
        .root_module = hp_aarch64_mod,
        .linkage = .static,
    });
    b.installArtifact(hp_aarch64_lib);
}
