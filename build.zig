const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .linux) {
        @panic("lszl supports Linux only");
    }

    const default_sherpa_prefix = b.pathJoin(&.{
        b.graph.environ_map.get("XDG_DATA_HOME") orelse b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", ".local", "share" }),
        "lszl",
        "runtime",
        "sherpa-onnx-v1.13.5-linux-x64-shared-no-tts",
    });
    const sherpa_prefix = b.option([]const u8, "sherpa_prefix", "Pinned sherpa-onnx C API distribution prefix") orelse default_sherpa_prefix;
    const sherpa_include = b.pathJoin(&.{ sherpa_prefix, "include" });
    const sherpa_lib = b.pathJoin(&.{ sherpa_prefix, "lib" });

    const exe = b.addExecutable(.{
        .name = "lszl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureNativeDependencies(b, exe, sherpa_include, sherpa_lib);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run lszl").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureNativeDependencies(b, tests, sherpa_include, sherpa_lib);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const check_deps = b.addSystemCommand(&.{ "sh", "-ceu" });
    check_deps.addArg("pkg-config --exists libavformat libavcodec libavutil libswresample; test -f \"$1/sherpa-onnx/c-api/c-api.h\"; test -f \"$2/libsherpa-onnx-c-api.so\"");
    check_deps.addArg("lszl-check-deps");
    check_deps.addArg(sherpa_include);
    check_deps.addArg(sherpa_lib);
    b.step("check-deps", "Check FFmpeg and Sherpa C API prerequisites").dependOn(&check_deps.step);
}

fn configureNativeDependencies(b: *std.Build, compile: *std.Build.Step.Compile, sherpa_include: []const u8, sherpa_lib: []const u8) void {
    const module = compile.root_module;
    module.linkSystemLibrary("avformat", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("avcodec", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("avutil", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("swresample", .{ .use_pkg_config = .yes });
    module.addIncludePath(.{ .cwd_relative = sherpa_include });
    module.addLibraryPath(.{ .cwd_relative = sherpa_lib });
    module.linkSystemLibrary("sherpa-onnx-c-api", .{ .use_pkg_config = .no, .needed = true });
    _ = b;
}
