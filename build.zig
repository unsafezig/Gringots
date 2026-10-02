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

    // Android auxv fallback unit tests (host-runnable parser tests).
    const auxv_test_mod = b.createModule(.{
        .root_source_file = b.path("src/android_auxv.zig"),
        .target = target,
        .optimize = optimize,
    });
    const auxv_tests = b.addTest(.{ .root_module = auxv_test_mod });
    test_step.dependOn(&b.addRunArtifact(auxv_tests).step);

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

    // Phase 4 desktop bridge: same framing over UDP loopback.
    const bridge_mod = b.createModule(.{
        .root_source_file = b.path("zinux/host_bridge/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addImport("host_protocol", hp_mod);
    bridge_mod.addImport("gringots_root", gringots_root_mod);
    bridge_mod.addImport("service_ipc", svc_ipc_mod);
    bridge_mod.addImport("test_receiver", rx_mod);
    const bridge_tests = b.addTest(.{ .root_module = bridge_mod });
    test_step.dependOn(&b.addRunArtifact(bridge_tests).step);

    // Phase 4b GRINGOTD relay daemon library.
    const gringotd_mod = b.createModule(.{
        .root_source_file = b.path("zinux/gringotd/gringotd.zig"),
        .target = target,
        .optimize = optimize,
    });
    gringotd_mod.addImport("host_protocol", hp_mod);
    gringotd_mod.addImport("service_ipc", svc_ipc_mod);
    gringotd_mod.addImport("test_receiver", rx_mod);
    gringotd_mod.addImport("bridge", bridge_mod);
    const gringotd_tests = b.addTest(.{ .root_module = gringotd_mod });
    test_step.dependOn(&b.addRunArtifact(gringotd_tests).step);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/host_bridge/e2e_sos_ack.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("host_protocol", hp_mod);
    e2e_mod.addImport("service_ipc", svc_ipc_mod);
    e2e_mod.addImport("test_receiver", rx_mod);
    e2e_mod.addImport("gringots_root", gringots_root_mod);
    e2e_mod.addImport("gringotd", gringotd_mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);

    // Emulator live-loop receiver (test-only desktop tool): UDP endpoint
    // the emulator app talks to. Pure composition over bridge.classify +
    // test_receiver; socket loop only in main().
    const rx_udp_mod = b.createModule(.{
        .root_source_file = b.path("zinux/emulator_rx/receiver_udp.zig"),
        .target = target,
        .optimize = optimize,
    });
    rx_udp_mod.addImport("host_protocol", hp_mod);
    rx_udp_mod.addImport("gringots_root", gringots_root_mod);
    rx_udp_mod.addImport("test_receiver", rx_mod);
    rx_udp_mod.addImport("bridge", bridge_mod);
    const rx_udp_tests = b.addTest(.{ .root_module = rx_udp_mod });
    test_step.dependOn(&b.addRunArtifact(rx_udp_tests).step);
    const rx_udp_exe = b.addExecutable(.{
        .name = "emulator_rx",
        .root_module = rx_udp_mod,
    });
    const install_rx_udp = b.addInstallArtifact(rx_udp_exe, .{});
    const rx_udp_step = b.step("emulator-rx", "Build desktop UDP receiver for the emulator live loop (test-only)");
    rx_udp_step.dependOn(&install_rx_udp.step);

    // Phase 5: JNI shared library for the Android APK. The APK bundles
    // this .so and binds GringotsBridge natives in JNI_OnLoad.
    const android_query = std.Target.Query{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    };
    const android_target = b.resolveTargetQuery(android_query);
    const jni_mod = b.createModule(.{
        .root_source_file = b.path("src/jni.zig"),
        .target = android_target,
        .optimize = optimize,
    });
    // Live-loop framing (wrapSos/unwrapDeliver) reuses the tested
    // host_protocol codec instead of reimplementing framing in Java.
    jni_mod.addImport("host_protocol", hp_mod);
    const jni_lib = b.addLibrary(.{
        .name = "gringots",
        .root_module = jni_mod,
        .linkage = .dynamic,
    });
    const install_jni = b.addInstallArtifact(jni_lib, .{});
    const android_step = b.step("android-lib", "Cross-compile libgringots.so for aarch64-linux-android");
    android_step.dependOn(&install_jni.step);

    // Emulator-only test slice: same JNI library for x86_64-linux-android.
    // The x86_64 emulator (sdk_gphone64_x86_64) runs ARM64 code through a
    // native bridge, so a native x86_64 .so sidesteps translation and
    // proves the Java/JNI + protocol path on the emulator. NEVER shipped:
    // the release APK stays arm64-v8a-only (see android/build-apk.ps1 gate).
    const android_x86_query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .android,
    };
    const android_x86_target = b.resolveTargetQuery(android_x86_query);
    const jni_x86_mod = b.createModule(.{
        .root_source_file = b.path("src/jni.zig"),
        .target = android_x86_target,
        .optimize = optimize,
    });
    jni_x86_mod.addImport("host_protocol", hp_mod);
    // The JNI entry points are short synchronous calls that never spawn
    // threads; single_threaded lets the backend lower thread-locals
    // (e.g. std panic state) without the global-dynamic TLS model, whose
    // __tls_get_addr resolver Bionic's linker does not provide.
    jni_x86_mod.single_threaded = true;
    jni_x86_mod.link_libc = false; // must stay false: Zig 0.16 cannot link
    // Bionic without an NDK sysroot. The local getauxval in
    // src/android_auxv.zig (imported by jni.zig) resolves Zig startup's
    // libc reference at static link time instead.
    const jni_x86_lib = b.addLibrary(.{
        .name = "gringots_x86_64",
        .root_module = jni_x86_mod,
        .linkage = .dynamic,
    });
    const install_jni_x86 = b.addInstallArtifact(jni_x86_lib, .{});
    const android_x86_step = b.step("android-lib-x86_64", "Cross-compile TEST-ONLY libgringots_x86_64.so for x86_64-linux-android (emulator)");
    android_x86_step.dependOn(&install_jni_x86.step);

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
