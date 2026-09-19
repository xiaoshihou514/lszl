const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .linux) {
        @panic("lszl supports Linux only");
    }

    // The sherpa-onnx runtime is dlopen'd at run time (see src/sherpa.zig);
    // only its headers are needed at build time. FFmpeg is linked from the
    // host system via pkg-config.
    const default_sherpa_prefix = b.pathJoin(&.{
        b.graph.environ_map.get("XDG_DATA_HOME") orelse b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", ".local", "share" }),
        "lszl",
        "runtime",
        "sherpa-onnx-v1.13.5-linux-x64-shared-no-tts",
    });
    const sherpa_prefix = b.option([]const u8, "sherpa_prefix", "Pinned sherpa-onnx distribution prefix (headers only)") orelse default_sherpa_prefix;
    const sherpa_include = b.pathJoin(&.{ sherpa_prefix, "include" });

    // FFmpeg is linked from the host system via pkg-config by default.
    // A prefix (include/ + lib/ with shared libav* libraries) overrides
    // it; the portable pack builds against a pinned shared FFmpeg tree
    // and ships the libraries next to the binary.
    const ffmpeg_prefix = b.option([]const u8, "ffmpeg_prefix", "FFmpeg prefix with include/ and lib/ (default: pkg-config)") orelse null;

    const exe = b.addExecutable(.{
        .name = "lszl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureNativeDependencies(b, exe, sherpa_include, ffmpeg_prefix);
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
    configureNativeDependencies(b, tests, sherpa_include, ffmpeg_prefix);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const check_deps = b.addSystemCommand(&.{ "sh", "-ceu" });
    if (ffmpeg_prefix) |prefix| {
        check_deps.addArgs(&.{
            "test -f \"$1/include/libavformat/avformat.h\"; test -f \"$1/lib/libavformat.so\"; test -f \"$2/sherpa-onnx/c-api/c-api.h\"",
            "lszl-check-deps",
            prefix,
            sherpa_include,
        });
    } else {
        check_deps.addArg("pkg-config --exists libavformat libavcodec libavutil libswresample; test -f \"$1/sherpa-onnx/c-api/c-api.h\"");
        check_deps.addArg("lszl-check-deps");
        check_deps.addArg(sherpa_include);
    }
    b.step("check-deps", "Check FFmpeg and Sherpa header prerequisites").dependOn(&check_deps.step);
}

fn configureNativeDependencies(b: *std.Build, compile: *std.Build.Step.Compile, sherpa_include: []const u8, ffmpeg_prefix: ?[]const u8) void {
    const module = compile.root_module;
    if (ffmpeg_prefix) |prefix| {
        module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        module.linkSystemLibrary("avformat", .{ .use_pkg_config = .no, .needed = true });
        module.linkSystemLibrary("avcodec", .{ .use_pkg_config = .no, .needed = true });
        module.linkSystemLibrary("avutil", .{ .use_pkg_config = .no, .needed = true });
        module.linkSystemLibrary("swresample", .{ .use_pkg_config = .no, .needed = true });
    } else {
        module.linkSystemLibrary("avformat", .{ .use_pkg_config = .yes });
        module.linkSystemLibrary("avcodec", .{ .use_pkg_config = .yes });
        module.linkSystemLibrary("avutil", .{ .use_pkg_config = .yes });
        module.linkSystemLibrary("swresample", .{ .use_pkg_config = .yes });
    }
    module.addIncludePath(.{ .cwd_relative = sherpa_include });
}
