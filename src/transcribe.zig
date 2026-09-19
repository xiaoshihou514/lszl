//! The native transcription pipeline.
//!
//! decode (FFmpeg) → recognize (sherpa-onnx) → punctuate (ct-transformer)
//! → atomic write, with the feeding strategy chosen per model family:
//!
//! * Streaming models keep a constant working set, so the whole file is
//!   fed through ONE stream and ONE recognizer — no chunking at all.
//! * Offline models have utterance-sized activations, so the input is
//!   decoded into the longest slices that fit the free VRAM budget and
//!   decoded through ONE recognizer instance. The model — the dominant
//!   GPU allocation — is loaded exactly once; slice boundaries only
//!   bound transient activations, and the slice length adapts to
//!   observed occupancy (grow on headroom, halve on pressure).
//!
//! That replaces the old shell pipeline, which spawned a fresh process
//! per 60 s chunk and re-loaded the model into GPU memory every time.

const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const gpu = @import("gpu.zig");
const preset = @import("preset.zig");
const model_store = @import("model_store.zig");
const sherpa = @import("sherpa.zig");

pub const Error = error{
    ModelNotInstalled,
    RuntimeUnavailable,
    MediaFailed,
    InferenceFailed,
    PunctuationFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Report = struct {
    provider: sherpa.Provider,
    device_name: ?[]u8,
    threads: u32,
    transcript_path: []u8,
    log_path: []u8,
    audio_seconds: f64,
    elapsed_seconds: f64,
    segments: usize,
    /// Final offline slice length (0 for streaming models).
    slice_seconds: u32 = 0,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        if (self.device_name) |name| allocator.free(name);
        allocator.free(self.transcript_path);
        allocator.free(self.log_path);
    }
};

pub const Options = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    layout: model_store.Layout,
    model: *const preset.Preset,
    input: []const u8,
};

pub fn run(options: Options) Error!Report {
    const allocator = options.allocator;
    const io = options.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var samples_seen: usize = 0;

    const started = std.Io.Timestamp.now(options.io, .awake);

    // --- provider selection ------------------------------------------------
    var device: ?gpu.Device = null;
    var provider: sherpa.Provider = .cpu;
    if (probeDevice(allocator)) |probed| {
        device = probed;
        provider = .cuda;
    } else |_| {}

    // Environment override for debugging and forced fallbacks.
    if (std.c.getenv("LSZL_PROVIDER")) |value| {
        const requested = std.mem.span(value);
        if (std.mem.eql(u8, requested, "cpu")) {
            provider = .cpu;
            if (device) |*d| {
                d.deinit(allocator);
                device = null;
            }
        } else if (std.mem.eql(u8, requested, "cuda") and device == null) {
            std.debug.print("lszl: LSZL_PROVIDER=cuda requested but no NVIDIA device is reachable\n", .{});
            return error.InferenceFailed;
        }
    }

    // --- runtime -----------------------------------------------------------
    const runtime_lib_dir = ensureProviderRuntime(allocator, io, options, &provider, &device) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("lszl: cannot provision the {s} sherpa-onnx runtime\n", .{provider.label()});
            return error.RuntimeUnavailable;
        },
    };
    defer allocator.free(runtime_lib_dir);

    var cudnn_dir: ?[]const u8 = null;
    if (provider == .cuda) {
        const dir = options.layout.cudnnLibDir(arena) catch return error.OutOfMemory;
        if (dirHasFile(io, dir, "libcudnn.so.9")) cudnn_dir = dir;
    }

    const runtime = sherpa.Runtime.load(allocator, .{
        .lib_dir = runtime_lib_dir,
        .cudnn_lib_dir = cudnn_dir,
        .io = io,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        std.debug.print("lszl: cannot load the sherpa-onnx runtime from {s}\n", .{runtime_lib_dir});
        return error.RuntimeUnavailable;
    };

    // Free-VRAM reading must happen before the model occupies the device.
    var free_vram: u64 = 0;
    if (provider == .cuda) {
        if (probeDevice(allocator)) |fresh| {
            var current = fresh;
            free_vram = current.free_bytes;
            current.deinit(allocator);
        } else |_| {}
    }

    // --- recognizer (created once, used for the whole file) ----------------
    const model_dir = options.layout.modelDir(arena, options.model.upstream_name) catch return error.OutOfMemory;

    const created = createRecognizer(allocator, runtime, io, model_dir, options.model.family, provider) catch |err| {
        std.debug.print("lszl: cannot initialize the recognizer ({s})\n", .{@errorName(err)});
        return error.InferenceFailed;
    };
    var recognizer = created.recognizer;
    defer recognizer.deinit();
    if (created.fell_back_to_cpu) {
        provider = .cpu;
        if (device) |*d| {
            d.deinit(allocator);
            device = null;
        }
    }
    const threads = autoThreads(provider);

    // --- punctuation (loaded once) -----------------------------------------
    const punctuator = setupPunctuator(allocator, runtime, io, options, arena, provider) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (punctuator) |p| p.deinit();

    // --- decode + recognize -------------------------------------------------
    var decoder = ffmpeg.Decoder.open(allocator, options.input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        std.debug.print("lszl: cannot open media: {s}\n", .{options.input});
        return error.MediaFailed;
    };
    defer decoder.deinit();

    var segments = std.ArrayList([]u8).empty;
    defer {
        for (segments.items) |segment| allocator.free(segment);
        segments.deinit(allocator);
    }

    var slice_seconds: u32 = 0;
    switch (options.model.mode) {
        .streaming => try streamWholeFile(allocator, &decoder, recognizer, punctuator, &segments, &samples_seen),
        .offline => try offlineSlices(allocator, &decoder, recognizer, punctuator, &segments, free_vram, &slice_seconds, &samples_seen),
    }

    const ended = std.Io.Timestamp.now(options.io, .awake);
    const elapsed_seconds = @as(f64, @floatFromInt(ended.nanoseconds - started.nanoseconds)) / 1e9;
    const audio_seconds = @as(f64, @floatFromInt(samples_seen)) / @as(f64, @floatFromInt(ffmpeg.sample_rate));

    // --- output --------------------------------------------------------------
    const transcript_path = try outputPath(arena, io, options.layout, options.model.name, options.input);
    const log_path = std.fmt.allocPrint(arena, "{s}.log", .{transcript_path}) catch return error.OutOfMemory;

    writeTranscript(io, transcript_path, segments.items) catch return error.WriteFailed;
    writeLog(io, log_path, .{
        .model = options.model.name,
        .provider = provider.label(),
        .device = if (device) |*d| d.name else null,
        .threads = threads,
        .slice_seconds = slice_seconds,
        .audio_seconds = audio_seconds,
        .elapsed_seconds = elapsed_seconds,
        .segments = segments.items.len,
        .punctuated = punctuator != null,
    }) catch return error.WriteFailed;

    return .{
        .provider = provider,
        .device_name = if (device) |*d| allocator.dupe(u8, d.name) catch return error.OutOfMemory else null,
        .threads = threads,
        .transcript_path = allocator.dupe(u8, transcript_path) catch return error.OutOfMemory,
        .log_path = allocator.dupe(u8, log_path) catch return error.OutOfMemory,
        .audio_seconds = audio_seconds,
        .elapsed_seconds = elapsed_seconds,
        .segments = segments.items.len,
        .slice_seconds = slice_seconds,
    };
}

// --- runtime + recognizer setup ---------------------------------------------

/// Ensure the runtime bundle for `provider` exists; a GPU runtime that
/// cannot be provisioned falls back to the CPU bundle.
fn ensureProviderRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    provider: *sherpa.Provider,
    device: *?gpu.Device,
) model_store.Error![]u8 {
    return model_store.ensureRuntime(allocator, io, options.environ_map, options.layout, provider.*) catch |err| {
        if (provider.* != .cuda) return err;
        std.debug.print("lszl: GPU runtime unavailable ({s}); falling back to the CPU runtime\n", .{@errorName(err)});
        provider.* = .cpu;
        if (device.*) |*d| {
            d.deinit(allocator);
            device.* = null;
        }
        return model_store.ensureRuntime(allocator, io, options.environ_map, options.layout, .cpu);
    };
}

const Created = struct {
    recognizer: *sherpa.Recognizer,
    /// True when the CUDA provider was rejected and the recognizer now
    /// runs on the CPU provider of the same runtime.
    fell_back_to_cpu: bool = false,
};

fn createRecognizer(
    allocator: std.mem.Allocator,
    runtime: *sherpa.Runtime,
    io: std.Io,
    model_dir: []const u8,
    family: sherpa.Family,
    provider: sherpa.Provider,
) sherpa.Error!Created {
    const threads = autoThreads(provider);
    const recognizer = sherpa.Recognizer.create(allocator, runtime, .{
        .io = io,
        .model_dir = model_dir,
        .family = family,
        .provider = provider,
        .num_threads = threads,
    }) catch |err| {
        if (err != sherpa.Error.RecognizerCreateFailed or provider != .cuda) return err;
        // Explicit, single-step fallback: the CUDA bundle also runs on
        // its CPU execution provider, so no second runtime is needed.
        std.debug.print("lszl: CUDA provider rejected; retrying on the CPU provider of the same runtime\n", .{});
        const fallback = try sherpa.Recognizer.create(allocator, runtime, .{
            .io = io,
            .model_dir = model_dir,
            .family = family,
            .provider = .cpu,
            .num_threads = autoThreads(.cpu),
        });
        return .{ .recognizer = fallback, .fell_back_to_cpu = true };
    };
    return .{ .recognizer = recognizer };
}

fn setupPunctuator(
    allocator: std.mem.Allocator,
    runtime: *sherpa.Runtime,
    io: std.Io,
    options: Options,
    arena: std.mem.Allocator,
    provider: sherpa.Provider,
) Error!?*sherpa.Punctuator {
    const models_dir = options.layout.modelsDir(arena) catch return error.OutOfMemory;
    const punct_dir = sherpa.punctuationModelDir(arena, models_dir) catch return error.OutOfMemory;
    if (!dirHasFile(io, punct_dir, "model.int8.onnx")) {
        model_store.installPunctuation(allocator, io, options.environ_map, options.layout) catch |err| {
            std.debug.print("lszl: punctuation model unavailable ({s}); output will lack punctuation\n", .{@errorName(err)});
            return null;
        };
    }
    if (sherpa.Punctuator.create(allocator, runtime, io, punct_dir, provider, 1)) |p| {
        return p;
    } else |err| {
        if (provider == .cuda) {
            if (sherpa.Punctuator.create(allocator, runtime, io, punct_dir, .cpu, 1)) |p| {
                return p;
            } else |_| {}
        }
        std.debug.print("lszl: punctuation model failed to load ({s}); output will lack punctuation\n", .{@errorName(err)});
        return null;
    }
}

// --- streaming feeding ------------------------------------------------------

/// Whole-file single pass: the constant-memory streaming model never
/// sees a chunk boundary; segment splits come from endpoint detection.
fn streamWholeFile(
    allocator: std.mem.Allocator,
    decoder: *ffmpeg.Decoder,
    recognizer: *sherpa.Recognizer,
    punctuator: ?*sherpa.Punctuator,
    segments: *std.ArrayList([]u8),
    samples_seen: *usize,
) Error!void {
    var stream = recognizer.openStream() catch return error.InferenceFailed;
    defer stream.deinit();

    var acc = std.ArrayList(f32).empty;
    defer acc.deinit(allocator);
    const second: usize = @intCast(ffmpeg.sample_rate);
    while (true) {
        const chunk = decoder.next() catch return error.MediaFailed;
        const samples = chunk orelse break;
        samples_seen.* += samples.len;
        acc.appendSlice(allocator, samples) catch return error.OutOfMemory;
        while (acc.items.len >= second) {
            stream.feed(acc.items[0..second]);
            std.mem.copyForwards(f32, acc.items[0 .. acc.items.len - second], acc.items[second..]);
            acc.items.len -= second;
            if (stream.isEndpoint()) {
                try finalizeStreamSegment(allocator, &stream, punctuator, segments);
                stream.reset();
            }
        }
    }
    stream.finish();
    try finalizeStreamSegment(allocator, &stream, punctuator, segments);
}

fn finalizeStreamSegment(
    allocator: std.mem.Allocator,
    stream: *sherpa.OnlineStream,
    punctuator: ?*sherpa.Punctuator,
    segments: *std.ArrayList([]u8),
) Error!void {
    const text = stream.takeText(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InferenceFailed,
    };
    defer allocator.free(text);
    try appendSegment(allocator, punctuator, segments, text);
}

// --- offline feeding with VRAM-budget slices --------------------------------

fn offlineSlices(
    allocator: std.mem.Allocator,
    decoder: *ffmpeg.Decoder,
    recognizer: *sherpa.Recognizer,
    punctuator: ?*sherpa.Punctuator,
    segments: *std.ArrayList([]u8),
    free_vram: u64,
    slice_seconds_out: *u32,
    samples_seen: *usize,
) Error!void {
    var planner = gpu.SlicePlanner.init(free_vram);
    var slice_seconds: u32 = planner.slice_seconds;

    // Baseline device usage: model resident, no activations yet.
    if (free_vram > 0) {
        if (probeDeviceUsedBytes(allocator)) |used| planner.observeBaseline(used);
    }

    const samples_per_second: usize = @intCast(ffmpeg.sample_rate);
    var buffer = std.ArrayList(f32).empty;
    defer buffer.deinit(allocator);

    while (true) {
        while (buffer.items.len < @as(usize, slice_seconds) * samples_per_second) {
            const chunk = decoder.next() catch return error.MediaFailed;
            const samples = chunk orelse break;
            samples_seen.* += samples.len;
            buffer.appendSlice(allocator, samples) catch return error.OutOfMemory;
        }
        if (buffer.items.len == 0) break;

        const decoded = try decodeBuffered(allocator, recognizer, &buffer, &slice_seconds);
        planner.slice_seconds = slice_seconds;
        slice_seconds_out.* = slice_seconds;
        defer allocator.free(decoded);
        try appendSegment(allocator, punctuator, segments, decoded);

        // Measure activation growth and size the next slice from it.
        if (free_vram > 0) {
            if (probeDeviceUsedBytes(allocator)) |used| planner.recordDecode(slice_seconds, used);
            const free_now: u64 = if (probeDevice(allocator)) |probed| blk: {
                var fresh = probed;
                const free = fresh.free_bytes;
                fresh.deinit(allocator);
                break :blk free;
            } else |_| 0;
            slice_seconds = planner.nextDuration(free_now);
        } else {
            slice_seconds = planner.nextDuration(0);
        }
    }
}

/// Device bytes currently in use, or null when unavailable.
fn probeDeviceUsedBytes(allocator: std.mem.Allocator) ?u64 {
    const probed = gpu.probe(allocator) catch return null;
    const device = probed orelse return null;
    var d = device;
    defer d.deinit(allocator);
    return d.total_bytes - d.free_bytes;
}

/// Decode buffered audio through the single recognizer. On failure
/// (typically CUDA OOM) the slice is halved and retried — the model
/// itself stays resident, only transient activations shrink. Consumed
/// samples are drained from `buffer`.
fn decodeBuffered(
    allocator: std.mem.Allocator,
    recognizer: *sherpa.Recognizer,
    buffer: *std.ArrayList(f32),
    slice_seconds: *u32,
) Error![]u8 {
    const samples_per_second: usize = @intCast(ffmpeg.sample_rate);
    var attempt_seconds: usize = @min(buffer.items.len / samples_per_second + 1, slice_seconds.*);
    while (true) {
        const take = @min(buffer.items.len, attempt_seconds * samples_per_second);
        const text = recognizer.decodeUtterance(allocator, buffer.items[0..take]) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (attempt_seconds <= gpu.policy.min_slice_seconds) {
                std.debug.print("lszl: recognizer failed on a {d}s slice\n", .{attempt_seconds});
                return error.InferenceFailed;
            }
            attempt_seconds = @max(attempt_seconds / 2, gpu.policy.min_slice_seconds);
            slice_seconds.* = @intCast(attempt_seconds);
            std.debug.print("lszl: decode failed at {d}s; retrying with {d}s slices\n", .{ attempt_seconds * 2, attempt_seconds });
            continue;
        };
        const rest = buffer.items.len - take;
        std.mem.copyForwards(f32, buffer.items[0..rest], buffer.items[take..]);
        buffer.shrinkRetainingCapacity(rest);
        return text;
    }
}

// --- shared helpers ---------------------------------------------------------

fn appendSegment(
    allocator: std.mem.Allocator,
    punctuator: ?*sherpa.Punctuator,
    segments: *std.ArrayList([]u8),
    raw: []const u8,
) Error!void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return;
    if (punctuator) |p| {
        const punctuated = p.punctuate(allocator, trimmed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PunctuationFailed,
        };
        segments.append(allocator, punctuated) catch return error.OutOfMemory;
        return;
    }
    segments.append(allocator, allocator.dupe(u8, trimmed) catch return error.OutOfMemory) catch
        return error.OutOfMemory;
}

fn autoThreads(provider: sherpa.Provider) u32 {
    if (provider == .cuda) return 1;
    const cores = std.Thread.getCpuCount() catch return 1;
    return @intCast(std.math.clamp(cores, 1, 4));
}

fn probeDevice(allocator: std.mem.Allocator) gpu.Error!gpu.Device {
    return (try gpu.probe(allocator)) orelse error.NvmlUnavailable;
}

fn dirHasFile(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn outputPath(
    arena: std.mem.Allocator,
    io: std.Io,
    layout: model_store.Layout,
    model_name: []const u8,
    input: []const u8,
) Error![]const u8 {
    const transcripts_dir = layout.transcriptsDir(arena) catch return error.OutOfMemory;
    const stem = std.fs.path.basename(input);
    const dir = std.fmt.allocPrint(arena, "{s}/{s}", .{ transcripts_dir, model_name }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.WriteFailed;
    return std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ dir, stem }) catch return error.OutOfMemory;
}

fn writeTranscript(io: std.Io, path: []const u8, segments: []const []u8) !void {
    var tmp_buf: [4096]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{d}", .{ path, std.os.linux.getpid() });
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        for (segments) |segment| {
            try writer.interface.writeAll(segment);
            try writer.interface.writeAll("\n");
        }
        try writer.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, .cwd(), path, io);
}

const LogInfo = struct {
    model: []const u8,
    provider: []const u8,
    device: ?[]const u8,
    threads: u32,
    slice_seconds: u32,
    audio_seconds: f64,
    elapsed_seconds: f64,
    segments: usize,
    punctuated: bool,
};

fn writeLog(io: std.Io, path: []const u8, info: LogInfo) !void {
    var tmp_buf: [4096]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{d}", .{ path, std.os.linux.getpid() });
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        var buffer: [2048]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.print(
            \\model: {s}
            \\provider: {s}
            \\device: {s}
            \\threads: {d}
            \\slice_seconds: {d}
            \\audio_seconds: {d:.1}
            \\elapsed_seconds: {d:.1}
            \\realtime_factor: {d:.2}
            \\segments: {d}
            \\punctuated: {}
            \\
        , .{
            info.model,
            info.provider,
            info.device orelse "cpu",
            info.threads,
            info.slice_seconds,
            info.audio_seconds,
            info.elapsed_seconds,
            if (info.elapsed_seconds > 0) info.audio_seconds / info.elapsed_seconds else 0,
            info.segments,
            info.punctuated,
        });
        try writer.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, .cwd(), path, io);
}
