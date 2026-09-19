//! Ownership-safe native binding to the sherpa-onnx C API.
//!
//! The pinned sherpa-onnx runtime is **not linked at build time**. The
//! CPU and CUDA runtime bundles both export the same sonames, so which
//! one to use is a per-machine choice: this module `dlopen`s the chosen
//! bundle's libraries in dependency order (cuDNN first when present, so
//! ONNX Runtime's lazy provider loads resolve against our copy), then
//! binds the C API entry points used by ASR.
//!
//! All strings handed to C live in the owning object's arena, so they
//! outlive every call, and every returned C string is copied into
//! allocator-owned Zig data before the upstream result is destroyed.

const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    LibraryLoadFailed,
    SymbolMissing,
    ModelFilesMissing,
    RecognizerCreateFailed,
    PunctuatorCreateFailed,
    DecodeFailed,
    OutOfMemory,
};

pub const Provider = enum {
    cpu,
    cuda,

    pub fn label(self: Provider) [:0]const u8 {
        return @tagName(self);
    }
};

pub const Family = @import("preset.zig").Family;

const RTLD: std.c.RTLD = .{ .NOW = true, .GLOBAL = true };
const Sherpa = c.sherpa;

/// One loaded sherpa-onnx runtime bundle. Only one runtime can live in a
/// process: CPU and CUDA bundles share sonames.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    /// Absolute path of the loaded `lib/` directory.
    lib_dir: [:0]u8,
    provider: Provider,
    onnxruntime: ?*anyopaque = null,
    c_api: ?*anyopaque = null,
    /// Diagnostics from the last failed dlopen/dlsym, if any.
    load_error: [256]u8 = undefined,
    load_error_len: usize = 0,

    api: Api = undefined,

    pub const LoadOptions = struct {
        /// Absolute path to the runtime bundle's `lib/` directory.
        lib_dir: []const u8,
        /// Absolute path to a cuDNN 9 `lib/` directory; required for CUDA
        /// bundles so the CUDA provider can resolve libcudnn.so.9.
        cudnn_lib_dir: ?[]const u8 = null,
        io: std.Io,
    };

    pub fn load(allocator: std.mem.Allocator, options: LoadOptions) Error!*Runtime {
        const self = allocator.create(Runtime) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .lib_dir = allocator.dupeZ(u8, options.lib_dir) catch return error.OutOfMemory,
            .provider = .cpu,
        };

        // Whether this bundle is the CUDA build is visible from the
        // provider plugin it ships. CUDA stacks resolve libcudnn lazily,
        // so our managed cuDNN (if any) must be registered first.
        if (accessIn(options.io, self.lib_dir, "libonnxruntime_providers_cuda.so")) {
            if (options.cudnn_lib_dir) |cudnn_dir| self.preloadCudnn(options.io, cudnn_dir);
            self.preload("libonnxruntime_providers_shared.so");
            self.provider = .cuda;
        }
        self.onnxruntime = self.dlopenInDir("libonnxruntime.so") catch |err| {
            self.destroySelf();
            return err;
        };
        self.c_api = self.dlopenInDir("libsherpa-onnx-c-api.so") catch |err| {
            self.destroySelf();
            return err;
        };
        self.bindSymbols() catch |err| {
            self.destroySelf();
            return err;
        };
        return self;
    }

    /// Libraries are kept resident for the whole process: dlclose would
    /// run ONNX Runtime global destructors while its provider libraries
    /// stay registered. Only our own bookkeeping is freed.
    fn destroySelf(self: *Runtime) void {
        self.allocator.free(self.lib_dir);
        self.allocator.destroy(self);
    }

    /// Register every cuDNN 9 library we manage so that soname lookups
    /// from the CUDA provider and the cuDNN frontend hit our copies.
    /// Best effort: missing files only mean the provider will fail later
    /// with its own diagnostic.
    fn preloadCudnn(self: *Runtime, io: std.Io, cudnn_dir: []const u8) void {
        const allocator = self.allocator;
        if (std.fs.path.joinZ(allocator, &.{ cudnn_dir, "libcudnn.so.9" })) |abs| {
            defer allocator.free(abs);
            _ = std.c.dlopen(abs.ptr, RTLD);
        } else |_| {}

        var d = std.Io.Dir.openDirAbsolute(io, cudnn_dir, .{ .iterate = true }) catch return;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "libcudnn_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".so.9")) continue;
            const path = std.fs.path.joinZ(allocator, &.{ cudnn_dir, entry.name }) catch continue;
            defer allocator.free(path);
            _ = std.c.dlopen(path.ptr, RTLD);
        }
    }

    fn preload(self: *Runtime, soname: []const u8) void {
        _ = self.dlopenInDir(soname) catch {};
    }

    fn dlopenInDir(self: *Runtime, soname: []const u8) Error!*anyopaque {
        const path = std.fs.path.joinZ(self.allocator, &.{ self.lib_dir, soname }) catch
            return error.OutOfMemory;
        defer self.allocator.free(path);
        if (std.c.dlopen(path.ptr, RTLD)) |handle| return handle;
        self.recordDlError();
        return error.LibraryLoadFailed;
    }

    fn recordDlError(self: *Runtime) void {
        self.load_error_len = 0;
        if (std.c.dlerror()) |message| {
            const text = std.mem.span(message);
            const n = @min(text.len, self.load_error.len);
            @memcpy(self.load_error[0..n], text[0..n]);
            self.load_error_len = n;
        }
    }

    fn bindSymbols(self: *Runtime) Error!void {
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            const symbol = comptime symbolName(field.name);
            const ptr = std.c.dlsym(self.c_api, symbol.ptr) orelse {
                self.recordDlError();
                return error.SymbolMissing;
            };
            @field(self.api, field.name) = @ptrCast(@alignCast(ptr));
        }
    }
};

const symbol_pairs = .{
    .{ "version", "SherpaOnnxGetVersionStr" },
    .{ "create_online_recognizer", "SherpaOnnxCreateOnlineRecognizer" },
    .{ "destroy_online_recognizer", "SherpaOnnxDestroyOnlineRecognizer" },
    .{ "create_online_stream", "SherpaOnnxCreateOnlineStream" },
    .{ "destroy_online_stream", "SherpaOnnxDestroyOnlineStream" },
    .{ "accept_waveform_online", "SherpaOnnxOnlineStreamAcceptWaveform" },
    .{ "is_online_stream_ready", "SherpaOnnxIsOnlineStreamReady" },
    .{ "decode_online_stream", "SherpaOnnxDecodeOnlineStream" },
    .{ "online_stream_input_finished", "SherpaOnnxOnlineStreamInputFinished" },
    .{ "online_stream_is_endpoint", "SherpaOnnxOnlineStreamIsEndpoint" },
    .{ "online_stream_reset", "SherpaOnnxOnlineStreamReset" },
    .{ "get_online_stream_result", "SherpaOnnxGetOnlineStreamResult" },
    .{ "destroy_online_result", "SherpaOnnxDestroyOnlineRecognizerResult" },
    .{ "create_offline_recognizer", "SherpaOnnxCreateOfflineRecognizer" },
    .{ "destroy_offline_recognizer", "SherpaOnnxDestroyOfflineRecognizer" },
    .{ "create_offline_stream", "SherpaOnnxCreateOfflineStream" },
    .{ "destroy_offline_stream", "SherpaOnnxDestroyOfflineStream" },
    .{ "accept_waveform_offline", "SherpaOnnxAcceptWaveformOffline" },
    .{ "decode_offline_stream", "SherpaOnnxDecodeOfflineStream" },
    .{ "get_offline_stream_result", "SherpaOnnxGetOfflineStreamResult" },
    .{ "destroy_offline_result", "SherpaOnnxDestroyOfflineRecognizerResult" },
    .{ "create_punctuation", "SherpaOnnxCreateOfflinePunctuation" },
    .{ "destroy_punctuation", "SherpaOnnxDestroyOfflinePunctuation" },
    .{ "add_punct", "SherpaOfflinePunctuationAddPunct" },
    .{ "free_punct_text", "SherpaOfflinePunctuationFreeText" },
};

fn symbolName(comptime field_name: []const u8) [:0]const u8 {
    @setEvalBranchQuota(10000);
    inline for (symbol_pairs) |pair| {
        if (comptime std.mem.eql(u8, pair[0], field_name)) return pair[1];
    }
    @compileError("unknown api field: " ++ field_name);
}

pub const Api = struct {
    version: *const fn () callconv(.c) [*:0]const u8,

    create_online_recognizer: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizerConfig) callconv(.c) ?*const Sherpa.SherpaOnnxOnlineRecognizer,
    destroy_online_recognizer: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer) callconv(.c) void,
    create_online_stream: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer) callconv(.c) ?*const Sherpa.SherpaOnnxOnlineStream,
    destroy_online_stream: *const fn (?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) void,
    accept_waveform_online: *const fn (?*const Sherpa.SherpaOnnxOnlineStream, i32, [*c]const f32, i32) callconv(.c) void,
    is_online_stream_ready: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer, ?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) i32,
    decode_online_stream: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer, ?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) void,
    online_stream_input_finished: *const fn (?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) void,
    online_stream_is_endpoint: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer, ?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) i32,
    online_stream_reset: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer, ?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) void,
    get_online_stream_result: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizer, ?*const Sherpa.SherpaOnnxOnlineStream) callconv(.c) ?*const Sherpa.SherpaOnnxOnlineRecognizerResult,
    destroy_online_result: *const fn (?*const Sherpa.SherpaOnnxOnlineRecognizerResult) callconv(.c) void,

    create_offline_recognizer: *const fn (?*const Sherpa.SherpaOnnxOfflineRecognizerConfig) callconv(.c) ?*const Sherpa.SherpaOnnxOfflineRecognizer,
    destroy_offline_recognizer: *const fn (?*const Sherpa.SherpaOnnxOfflineRecognizer) callconv(.c) void,
    create_offline_stream: *const fn (?*const Sherpa.SherpaOnnxOfflineRecognizer) callconv(.c) ?*const Sherpa.SherpaOnnxOfflineStream,
    destroy_offline_stream: *const fn (?*const Sherpa.SherpaOnnxOfflineStream) callconv(.c) void,
    accept_waveform_offline: *const fn (?*const Sherpa.SherpaOnnxOfflineStream, i32, [*c]const f32, i32) callconv(.c) void,
    decode_offline_stream: *const fn (?*const Sherpa.SherpaOnnxOfflineRecognizer, ?*const Sherpa.SherpaOnnxOfflineStream) callconv(.c) void,
    get_offline_stream_result: *const fn (?*const Sherpa.SherpaOnnxOfflineStream) callconv(.c) ?*const Sherpa.SherpaOnnxOfflineRecognizerResult,
    destroy_offline_result: *const fn (?*const Sherpa.SherpaOnnxOfflineRecognizerResult) callconv(.c) void,

    create_punctuation: *const fn (?*const Sherpa.SherpaOnnxOfflinePunctuationConfig) callconv(.c) ?*const Sherpa.SherpaOnnxOfflinePunctuation,
    destroy_punctuation: *const fn (?*const Sherpa.SherpaOnnxOfflinePunctuation) callconv(.c) void,
    add_punct: *const fn (?*const Sherpa.SherpaOnnxOfflinePunctuation, [*:0]const u8) callconv(.c) ?[*:0]const u8,
    free_punct_text: *const fn (?[*:0]const u8) callconv(.c) void,
};

pub const sample_rate: i32 = 16000;

/// An ASR recognizer created from one installed model directory. Wraps
/// either the streaming or the offline C API depending on the model
/// family; all configuration strings live in `arena`.
pub const Recognizer = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    runtime: *Runtime,
    family: Family,
    online: ?*const Sherpa.SherpaOnnxOnlineRecognizer = null,
    offline: ?*const Sherpa.SherpaOnnxOfflineRecognizer = null,
    /// Sum of the model files used, for VRAM budgeting.
    model_bytes: u64 = 0,

    pub const CreateOptions = struct {
        io: std.Io,
        model_dir: []const u8,
        family: Family,
        provider: Provider,
        num_threads: u32,
    };

    pub fn create(allocator: std.mem.Allocator, runtime: *Runtime, options: CreateOptions) Error!*Recognizer {
        const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        const self = allocator.create(Recognizer) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .arena = arena, .runtime = runtime, .family = options.family };
        errdefer allocator.destroy(self);

        const model_dir = arena.allocator().dupe(u8, options.model_dir) catch return error.OutOfMemory;

        switch (options.family) {
            .online_transducer, .online_paraformer, .online_zipformer2_ctc => try self.createOnline(model_dir, options),
            .offline_transducer, .offline_nemo_ctc => try self.createOffline(model_dir, options),
        }
        return self;
    }

    pub fn deinit(self: *Recognizer) void {
        if (self.online) |handle| self.runtime.api.destroy_online_recognizer(handle);
        if (self.offline) |handle| self.runtime.api.destroy_offline_recognizer(handle);
        const arena = self.arena;
        const allocator = self.allocator;
        arena.deinit();
        allocator.destroy(arena);
        allocator.destroy(self);
    }

    fn createOnline(self: *Recognizer, model_dir: []const u8, options: CreateOptions) Error!void {
        const arena = self.arena.allocator();
        const a = &self.runtime.api;

        var config = std.mem.zeroes(Sherpa.SherpaOnnxOnlineRecognizerConfig);
        config.feat_config.sample_rate = sample_rate;
        config.feat_config.feature_dim = 80;
        config.decoding_method = "greedy_search";
        config.enable_endpoint = 1;
        config.rule1_min_trailing_silence = 2.0;
        config.rule2_min_trailing_silence = 1.0;
        config.rule3_min_utterance_length = 20.0;

        config.model_config.tokens = try findRequired(options.io, arena, model_dir, "tokens.txt");
        config.model_config.provider = options.provider.label();
        config.model_config.num_threads = @intCast(options.num_threads);

        switch (options.family) {
            .online_transducer => {
                config.model_config.transducer.encoder = try findOnnx(options.io, arena, model_dir, "encoder", &self.model_bytes);
                config.model_config.transducer.decoder = try findOnnx(options.io, arena, model_dir, "decoder", &self.model_bytes);
                config.model_config.transducer.joiner = try findOnnx(options.io, arena, model_dir, "joiner", &self.model_bytes);
            },
            .online_paraformer => {
                config.model_config.paraformer.encoder = try findOnnx(options.io, arena, model_dir, "encoder", &self.model_bytes);
                config.model_config.paraformer.decoder = try findOnnx(options.io, arena, model_dir, "decoder", &self.model_bytes);
            },
            .online_zipformer2_ctc => {
                config.model_config.zipformer2_ctc.model = try findOnnx(options.io, arena, model_dir, "model", &self.model_bytes);
            },
            else => unreachable,
        }

        self.online = a.create_online_recognizer(&config) orelse return error.RecognizerCreateFailed;
    }

    fn createOffline(self: *Recognizer, model_dir: []const u8, options: CreateOptions) Error!void {
        const arena = self.arena.allocator();
        const a = &self.runtime.api;

        var config = std.mem.zeroes(Sherpa.SherpaOnnxOfflineRecognizerConfig);
        config.feat_config.sample_rate = sample_rate;
        config.feat_config.feature_dim = 80;
        config.decoding_method = "greedy_search";
        config.model_config.tokens = try findRequired(options.io, arena, model_dir, "tokens.txt");
        config.model_config.provider = options.provider.label();
        config.model_config.num_threads = @intCast(options.num_threads);

        switch (options.family) {
            .offline_transducer => {
                config.model_config.transducer.encoder = try findOnnx(options.io, arena, model_dir, "encoder", &self.model_bytes);
                config.model_config.transducer.decoder = try findOnnx(options.io, arena, model_dir, "decoder", &self.model_bytes);
                config.model_config.transducer.joiner = try findOnnx(options.io, arena, model_dir, "joiner", &self.model_bytes);
            },
            .offline_nemo_ctc => {
                config.model_config.nemo_ctc.model = try findOnnx(options.io, arena, model_dir, "model", &self.model_bytes);
            },
            else => unreachable,
        }

        self.offline = a.create_offline_recognizer(&config) orelse return error.RecognizerCreateFailed;
    }

    /// Decode one utterance (usually a VRAM-sized slice) and return the
    /// transcript text, allocated with `allocator`.
    pub fn decodeUtterance(self: *Recognizer, allocator: std.mem.Allocator, samples: []const f32) Error![]u8 {
        const a = &self.runtime.api;
        const offline = self.offline orelse return error.DecodeFailed;
        const stream = a.create_offline_stream(offline) orelse return error.DecodeFailed;
        defer a.destroy_offline_stream(stream);
        a.accept_waveform_offline(stream, sample_rate, samples.ptr, @intCast(samples.len));
        a.decode_offline_stream(offline, stream);
        const result = a.get_offline_stream_result(stream) orelse return error.DecodeFailed;
        defer a.destroy_offline_result(result);
        return allocator.dupe(u8, std.mem.span(result.text)) catch return error.OutOfMemory;
    }

    /// Create a streaming session bound to this recognizer.
    pub fn openStream(self: *Recognizer) Error!OnlineStream {
        const a = &self.runtime.api;
        const online = self.online orelse return error.DecodeFailed;
        const stream = a.create_online_stream(online) orelse return error.DecodeFailed;
        return .{ .recognizer = self, .stream = stream };
    }
};

/// A streaming decode state. Feed slices as they arrive from the media
/// decoder; the stream decodes eagerly and marks endpoint boundaries so
/// each utterance can be punctuated separately. The recognizer — and the
/// GPU memory it holds — stays loaded for the whole file.
pub const OnlineStream = struct {
    recognizer: *Recognizer,
    stream: ?*const Sherpa.SherpaOnnxOnlineStream,

    pub fn feed(self: *OnlineStream, samples: []const f32) void {
        const a = &self.recognizer.runtime.api;
        a.accept_waveform_online(self.stream, sample_rate, samples.ptr, @intCast(samples.len));
        self.decodeReady();
    }

    /// Decode everything currently buffered (never waits on input).
    pub fn decodeReady(self: *OnlineStream) void {
        const a = &self.recognizer.runtime.api;
        while (a.is_online_stream_ready(self.recognizer.online, self.stream) != 0) {
            a.decode_online_stream(self.recognizer.online, self.stream);
        }
    }

    /// Signal end of input and drain the remaining frames.
    pub fn finish(self: *OnlineStream) void {
        const a = &self.recognizer.runtime.api;
        a.online_stream_input_finished(self.stream);
        self.decodeReady();
    }

    pub fn isEndpoint(self: *OnlineStream) bool {
        const a = &self.recognizer.runtime.api;
        return a.online_stream_is_endpoint(self.recognizer.online, self.stream) != 0;
    }

    pub fn reset(self: *OnlineStream) void {
        const a = &self.recognizer.runtime.api;
        a.online_stream_reset(self.recognizer.online, self.stream);
    }

    /// Copy the accumulated text for the current utterance.
    pub fn takeText(self: *OnlineStream, allocator: std.mem.Allocator) Error![]u8 {
        const a = &self.recognizer.runtime.api;
        const result = a.get_online_stream_result(self.recognizer.online, self.stream) orelse
            return error.DecodeFailed;
        defer a.destroy_online_result(result);
        return allocator.dupe(u8, std.mem.span(result.text)) catch return error.OutOfMemory;
    }

    pub fn deinit(self: *OnlineStream) void {
        if (self.stream) |stream| {
            self.recognizer.runtime.api.destroy_online_stream(stream);
        }
        self.stream = null;
    }
};

/// Offline punctuation applied to transcript lines. The ct-transformer
/// model is loaded once and reused for the whole file.
pub const Punctuator = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    runtime: *Runtime,
    handle: ?*const Sherpa.SherpaOnnxOfflinePunctuation = null,

    pub fn create(allocator: std.mem.Allocator, runtime: *Runtime, io: std.Io, model_dir: []const u8, provider: Provider, num_threads: u32) Error!*Punctuator {
        const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const self = allocator.create(Punctuator) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .arena = arena, .runtime = runtime };
        errdefer allocator.destroy(self);

        const dir = arena.allocator().dupe(u8, model_dir) catch return error.OutOfMemory;
        var config = std.mem.zeroes(Sherpa.SherpaOnnxOfflinePunctuationConfig);
        var ignored_bytes: u64 = 0;
        config.model.ct_transformer = try findOnnx(io, arena.allocator(), dir, "model", &ignored_bytes);
        config.model.provider = provider.label();
        config.model.num_threads = @intCast(num_threads);

        self.handle = runtime.api.create_punctuation(&config) orelse return error.PunctuatorCreateFailed;
        return self;
    }

    pub fn deinit(self: *Punctuator) void {
        if (self.handle) |handle| self.runtime.api.destroy_punctuation(handle);
        const arena = self.arena;
        const allocator = self.allocator;
        arena.deinit();
        allocator.destroy(arena);
        allocator.destroy(self);
    }

    /// Return `text` with punctuation restored; allocated with `allocator`.
    pub fn punctuate(self: *Punctuator, allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
        const text_z = self.arena.allocator().dupeZ(u8, text) catch return error.OutOfMemory;
        const out = self.runtime.api.add_punct(self.handle, text_z) orelse return error.DecodeFailed;
        defer self.runtime.api.free_punct_text(out);
        return allocator.dupe(u8, std.mem.span(out)) catch return error.OutOfMemory;
    }
};

/// Absolute path of the punctuation model directory inside `models_dir`.
pub fn punctuationModelDir(allocator: std.mem.Allocator, models_dir: []const u8) Error![]u8 {
    return std.fs.path.join(allocator, &.{ models_dir, @import("preset.zig").punctuation.upstream_name }) catch error.OutOfMemory;
}

fn findRequired(io: std.Io, arena: std.mem.Allocator, dir: []const u8, name: []const u8) Error![:0]const u8 {
    const path = std.fs.path.joinZ(arena, &.{ dir, name }) catch return error.OutOfMemory;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return error.ModelFilesMissing;
    return path;
}

/// Find a model file whose name starts with `prefix` and ends in `.onnx`,
/// preferring the int8 variant. Records the chosen file's size into
/// `total_bytes` when non-null.
fn findOnnx(io: std.Io, arena: std.mem.Allocator, dir: []const u8, prefix: []const u8, total_bytes: ?*u64) Error![:0]const u8 {
    var d = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return error.ModelFilesMissing;
    defer d.close(io);
    var it = d.iterate();
    var int8: ?[]const u8 = null;
    var plain: ?[]const u8 = null;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".onnx")) continue;
        if (std.mem.endsWith(u8, entry.name, ".int8.onnx")) {
            int8 = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        } else if (plain == null) {
            plain = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        }
    }
    const chosen = int8 orelse plain orelse return error.ModelFilesMissing;
    const path = std.fs.path.joinZ(arena, &.{ dir, chosen }) catch return error.OutOfMemory;
    if (total_bytes) |total| {
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            total.* += stat.size;
        } else |_| {}
    }
    return path;
}

fn accessIn(io: std.Io, dir: [:0]const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "api symbol table covers every field" {
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        const symbol = comptime symbolName(field.name);
        try std.testing.expect(symbol.len > 8);
    }
}

test "findOnnx prefers the int8 variant" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "encoder-epoch-99-avg-1.onnx", .data = "aaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = "encoder-epoch-99-avg-1.int8.onnx", .data = "bb" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tokens.txt", .data = "" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, "tokens.txt", allocator);
    defer allocator.free(dir_path);
    const model_dir = std.fs.path.dirname(dir_path).?;

    var total: u64 = 0;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const chosen = try findOnnx(io, arena_state.allocator(), model_dir, "encoder", &total);
    try std.testing.expect(std.mem.endsWith(u8, chosen, ".int8.onnx"));
    try std.testing.expectEqual(@as(u64, 2), total);
    try std.testing.expectError(error.ModelFilesMissing, findOnnx(io, arena_state.allocator(), model_dir, "joiner", &total));
}
