const std = @import("std");
const preset = @import("preset.zig");
const gpu = @import("gpu.zig");
const model_store = @import("model_store.zig");
const transcribe = @import("transcribe.zig");

const Command = union(enum) {
    help,
    doctor,
    model_list,
    model_default: ?[]const u8,
    model_install: []const u8,
    transcribe: Transcribe,

    const Transcribe = struct {
        input: []const u8,
        model_name: ?[]const u8,
    };
};

const ParseError = error{
    MissingCommand,
    MissingModelName,
    MissingInput,
    UnknownCommand,
    UnknownOption,
};

fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingCommand;
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) return .help;
    if (std.mem.eql(u8, args[0], "doctor")) return .doctor;

    if (std.mem.eql(u8, args[0], "model")) {
        if (args.len < 2) return error.MissingCommand;
        if (std.mem.eql(u8, args[1], "list")) return .model_list;
        if (std.mem.eql(u8, args[1], "default")) {
            if (args.len > 3) return error.UnknownOption;
            return .{ .model_default = if (args.len == 3) args[2] else null };
        }
        if (std.mem.eql(u8, args[1], "install")) {
            if (args.len != 3) return error.MissingModelName;
            return .{ .model_install = args[2] };
        }
        return error.UnknownCommand;
    }

    if (std.mem.eql(u8, args[0], "transcribe")) {
        var model_name: ?[]const u8 = null;
        var input: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--model")) {
                i += 1;
                if (i == args.len) return error.MissingModelName;
                model_name = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                return error.UnknownOption;
            } else if (input == null) {
                input = args[i];
            } else {
                return error.UnknownOption;
            }
        }
        return .{ .transcribe = .{ .input = input orelse return error.MissingInput, .model_name = model_name } };
    }

    return error.UnknownCommand;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  lszl model list
        \\  lszl model install <name>
        \\  lszl model default <name>
        \\  lszl transcribe [--model <name>] <audio-or-video>
        \\  lszl doctor
        \\
        \\Models use short names shown by `lszl model list`.
        \\Without --model, transcribe uses the configured default model.
        \\LSZL_PROVIDER=cpu|cuda forces an execution provider (default: auto).
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const command = parseArgs(raw_args[1..]) catch |err| {
        std.debug.print("lszl: {s}\n", .{@errorName(err)});
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(exit_usage);
    };

    const code: u8 = switch (command) {
        .help => blk: {
            try printUsage(stdout);
            break :blk exit_ok;
        },
        .doctor => try runDoctor(allocator, io, stdout),
        .model_list => try runModelList(allocator, io, stdout),
        .model_default => |name| try runModelDefault(allocator, io, stdout, name),
        .model_install => |name| try runModelInstall(allocator, io, init.environ_map, stdout, name),
        .transcribe => |request| try runTranscribe(allocator, io, init.environ_map, stdout, request),
    };
    try stdout.flush();
    std.process.exit(code);
}

// --- exit codes ---------------------------------------------------------------

const exit_ok: u8 = 0;
const exit_usage: u8 = 2;
const exit_model: u8 = 3;
const exit_media: u8 = 4;
const exit_inference: u8 = 5;
const exit_runtime: u8 = 6;
const exit_fetch: u8 = 7;

// --- transcribe ----------------------------------------------------------------

fn runTranscribe(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    request: Command.Transcribe,
) !u8 {
    const data_dir = model_store.dataDirectory(allocator) catch |err| {
        if (err == error.HomeNotFound) std.debug.print("lszl: cannot determine the data directory (set HOME or XDG_DATA_HOME)\n", .{});
        return exit_runtime;
    };
    defer allocator.free(data_dir);
    const layout = model_store.Layout{ .data_dir = data_dir };

    // Resolve the model by name, or by the configured default.
    const configured: []const u8 = if (request.model_name) |name|
        name
    else blk: {
        const loaded = model_store.loadDefaultModel(allocator, io, data_dir) catch |err| {
            if (err == error.FileNotFound) {
                try stdout.writeAll("No default model configured.\n");
                try stdout.flush();
                std.debug.print("lszl: set one with: lszl model default <name>\n", .{});
                return exit_model;
            }
            return exit_model;
        };
        break :blk loaded;
    };
    defer if (request.model_name == null) allocator.free(configured);

    const model = preset.find(configured) orelse {
        std.debug.print("lszl: unsupported model name: {s}\n", .{configured});
        return exit_model;
    };
    if (!model_store.isInstalled(io, allocator, layout, model)) {
        std.debug.print("lszl: model is not installed: {s}. Run: lszl model install {s}\n", .{ model.name, model.name });
        return exit_model;
    }

    var report = transcribe.run(.{
        .io = io,
        .allocator = allocator,
        .environ_map = environ_map,
        .layout = layout,
        .model = model,
        .input = request.input,
    }) catch |err| switch (err) {
        error.OutOfMemory => return exit_inference,
        error.MediaFailed => {
            std.debug.print("lszl: failed to decode {s}\n", .{request.input});
            return exit_media;
        },
        error.InferenceFailed, error.PunctuationFailed => return exit_inference,
        error.RuntimeUnavailable => return exit_runtime,
        error.WriteFailed => return exit_media,
        error.ModelNotInstalled => return exit_model,
    };
    defer report.deinit(allocator);

    if (report.device_name) |device| {
        try stdout.print("Model: {s} ({s}, {s})\n", .{ model.name, report.provider.label(), device });
    } else {
        try stdout.print("Model: {s} ({s})\n", .{ model.name, report.provider.label() });
    }
    try stdout.print("Transcript: {s}\n", .{report.transcript_path});
    try stdout.print("Diagnostics: {s}\n", .{report.log_path});
    try stdout.print("Audio {d:.1}s in {d:.1}s ({d:.2}x realtime), {d} segments\n", .{
        report.audio_seconds,
        report.elapsed_seconds,
        if (report.elapsed_seconds > 0) report.audio_seconds / report.elapsed_seconds else 0,
        report.segments,
    });
    return exit_ok;
}

// --- model management ------------------------------------------------------------

fn runModelInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    name: []const u8,
) !u8 {
    const model = preset.find(name) orelse {
        std.debug.print("lszl: unsupported model name: {s}\n", .{name});
        return exit_model;
    };
    const data_dir = model_store.dataDirectory(allocator) catch return exit_runtime;
    defer allocator.free(data_dir);
    const layout = model_store.Layout{ .data_dir = data_dir };

    _ = model_store.installModel(allocator, io, environ_map, layout, model) catch |err| switch (err) {
        error.AlreadyInstalled => {
            try stdout.print("Model already installed: {s}\n", .{model.name});
            return exit_ok;
        },
        error.OutOfMemory => return exit_fetch,
        error.VerifyFailed => {
            std.debug.print("lszl: downloaded archive failed SHA-256 verification\n", .{});
            return exit_fetch;
        },
        error.FetchFailed => {
            std.debug.print("lszl: download failed\n", .{});
            return exit_fetch;
        },
        else => {
            std.debug.print("lszl: installation failed ({s})\n", .{@errorName(err)});
            return exit_fetch;
        },
    };
    try stdout.print("Installed: {s} ({s})\n", .{ model.name, model.upstream_name });
    return exit_ok;
}

fn runModelDefault(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    name: ?[]const u8,
) !u8 {
    const data_dir = model_store.dataDirectory(allocator) catch return exit_runtime;
    defer allocator.free(data_dir);

    if (name) |requested| {
        const model = preset.find(requested) orelse {
            std.debug.print("lszl: unsupported model name: {s}\n", .{requested});
            return exit_model;
        };
        model_store.saveDefaultModel(allocator, io, data_dir, model.name) catch return exit_runtime;
        try stdout.print("Default model set to {s}.\n", .{model.name});
        return exit_ok;
    }

    const current = model_store.loadDefaultModel(allocator, io, data_dir) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.writeAll("No default model configured.\n");
            return exit_ok;
        }
        return exit_runtime;
    };
    defer allocator.free(current);
    const shown = if (preset.find(current)) |model| model.name else current;
    try stdout.print("Default model: {s}\n", .{shown});
    return exit_ok;
}

fn runModelList(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !u8 {
    const data_dir = model_store.dataDirectory(allocator) catch return exit_runtime;
    defer allocator.free(data_dir);
    const layout = model_store.Layout{ .data_dir = data_dir };

    const default_name = model_store.loadDefaultModel(allocator, io, data_dir) catch null;
    defer if (default_name) |name| allocator.free(name);

    try stdout.writeAll("Models (name, status, upstream archive):\n");
    for (&preset.presets) |*model| {
        const status: []const u8 = if (model_store.isInstalled(io, allocator, layout, model)) "installed" else "installable";
        const marker: []const u8 = if (default_name) |current|
            (if (std.mem.eql(u8, current, model.name)) "default" else "")
        else
            "";
        try stdout.print("  {s:<15} {s:<11} {s:<7} {s}\n", .{ model.name, status, marker, model.upstream_name });
    }
    try stdout.flush();
    return exit_ok;
}

// --- doctor ----------------------------------------------------------------------

const RuntimePresence = enum { present, absent, partial };

fn runDoctor(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !u8 {
    const data_dir = model_store.dataDirectory(allocator) catch return exit_runtime;
    defer allocator.free(data_dir);
    const layout = model_store.Layout{ .data_dir = data_dir };

    try stdout.writeAll("GPU acceleration probe\n");
    var any_cuda = false;
    if (gpu.probe(allocator)) |probed| {
        if (probed) |probed_device| {
            any_cuda = true;
            var device = probed_device;
            try stdout.print("  {s}: {d} MiB total, {d} MiB free\n", .{
                device.name,
                device.total_bytes / (1024 * 1024),
                device.free_bytes / (1024 * 1024),
            });
            device.deinit(allocator);
        } else {
            try stdout.writeAll("  no NVIDIA device is reachable (driver/NVML missing)\n");
        }
    } else |_| {
        try stdout.writeAll("  no NVIDIA device is reachable (driver/NVML missing)\n");
    }

    if (any_cuda) {
        const cudnn_dir = layout.cudnnLibDir(allocator) catch return exit_runtime;
        defer allocator.free(cudnn_dir);
        if (hasFileIn(io, cudnn_dir, "libcudnn.so.9")) {
            try stdout.print("  cuDNN 9 runtime found at {s}; lszl will select provider=cuda.\n", .{cudnn_dir});
        } else {
            try stdout.print("  CUDA device detected, but the managed cuDNN 9 runtime is missing at {s}.\n  Install it with: just install-cudnn\n", .{cudnn_dir});
        }
        if (systemCudaLibsPresent(io)) {
            try stdout.writeAll("  CUDA 13 runtime libraries (cublas/cudart) detected on the system.\n");
        } else {
            try stdout.writeAll("  CUDA 13 runtime libraries not found on the system; GPU inference cannot start.\n");
        }
        switch (runtimePresence(allocator, io, layout, model_store.runtime_gpu.name)) {
            .present => try stdout.writeAll("  sherpa-onnx CUDA runtime: installed.\n"),
            .partial => try stdout.writeAll("  sherpa-onnx CUDA runtime: incomplete; it is re-fetched automatically on first use.\n"),
            .absent => try stdout.writeAll("  sherpa-onnx CUDA runtime: not installed yet; it is downloaded automatically on first use.\n"),
        }
    } else {
        try stdout.writeAll("  lszl will use the CPU execution provider.\n");
    }

    if (rocmSmiPresent(io)) {
        try stdout.writeAll("ROCm device detected, but the pinned sherpa-onnx runtime is CPU/CUDA only.\n");
    }

    switch (runtimePresence(allocator, io, layout, model_store.runtime_cpu.name)) {
        .present => try stdout.writeAll("sherpa-onnx CPU runtime: installed.\n"),
        .partial => try stdout.writeAll("sherpa-onnx CPU runtime: incomplete; it is re-fetched automatically on first use.\n"),
        .absent => try stdout.writeAll("sherpa-onnx CPU runtime: not installed yet; it is downloaded automatically on first use.\n"),
    }
    try stdout.flush();
    return exit_ok;
}

fn runtimePresence(allocator: std.mem.Allocator, io: std.Io, layout: model_store.Layout, runtime_name: []const u8) RuntimePresence {
    const runtime_dir = layout.runtimeDir(allocator) catch return .absent;
    defer allocator.free(runtime_dir);
    const lib_dir = std.fs.path.join(allocator, &.{ runtime_dir, runtime_name, "lib" }) catch return .absent;
    defer allocator.free(lib_dir);
    const c_api = hasFileIn(io, lib_dir, "libsherpa-onnx-c-api.so");
    const ort = hasFileIn(io, lib_dir, "libonnxruntime.so");
    if (c_api and ort) return .present;
    if (c_api or ort) return .partial;
    return .absent;
}

fn hasFileIn(io: std.Io, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ dir, name }) catch return false;
    defer std.heap.page_allocator.free(path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn systemCudaLibsPresent(io: std.Io) bool {
    const candidates = [_][]const u8{
        "/usr/local/cuda/targets/x86_64-linux/lib/libcublasLt.so.13",
        "/usr/local/cuda/lib64/libcublasLt.so.13",
        "/usr/lib64/libcublasLt.so.13",
        "/usr/lib/x86_64-linux-gnu/libcublasLt.so.13",
    };
    for (candidates) |path| {
        if (std.Io.Dir.accessAbsolute(io, path, .{})) {
            return true;
        } else |_| {}
    }
    return false;
}

fn rocmSmiPresent(io: std.Io) bool {
    const path_env = std.c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(std.heap.page_allocator, &.{ dir, "rocm-smi" }) catch continue;
        defer std.heap.page_allocator.free(candidate);
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

// --- tests -------------------------------------------------------------------------

test "model default can query without a model name" {
    const command = try parseArgs(&.{ "model", "default" });
    switch (command) {
        .model_default => |name| try std.testing.expect(name == null),
        else => return error.TestUnexpectedResult,
    }
}

test "transcribe addresses models by name" {
    const command = try parseArgs(&.{ "transcribe", "--model", "paraformer", "clip.mp4" });
    switch (command) {
        .transcribe => |request| {
            try std.testing.expectEqualStrings("paraformer", request.model_name.?);
            try std.testing.expectEqualStrings("clip.mp4", request.input);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "preset names are short and legacy upstream names migrate" {
    try std.testing.expectEqualStrings("paraformer", preset.find("paraformer").?.name);
    try std.testing.expectEqualStrings("paraformer", preset.find("sherpa-onnx-streaming-paraformer-bilingual-zh-en").?.name);
    try std.testing.expect(preset.find("unknown") == null);
}

test "all pipeline modules are wired into the test build" {
    _ = @import("ffmpeg.zig");
    _ = @import("sherpa.zig");
    _ = @import("archive.zig");
    _ = @import("fetch.zig");
    _ = @import("gpu.zig");
    _ = @import("model_store.zig");
    _ = @import("transcribe.zig");
}
