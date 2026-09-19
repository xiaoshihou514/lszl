//! Model and runtime storage under the lszl data directory.
//!
//! Layout (defaults to `$XDG_DATA_HOME/lszl` or `~/.local/share/lszl`;
//! `LSZL_DATA_HOME` overrides the whole directory, used by the portable
//! launcher):
//!
//!   data/
//!   ├── models/<upstream-name>/…     installed ASR models
//!   ├── models/<punctuation-name>/…  shared punctuation model
//!   ├── runtime/<runtime-name>/…     pinned sherpa-onnx CPU/CUDA bundles
//!   ├── cudnn/lib/…                  cuDNN 9 (optional, GPU only)
//!   ├── cache/…                      downloaded archives, staging dirs
//!   ├── transcripts/<model>/…        transcript outputs
//!   └── default-model                name of the default preset

const std = @import("std");
const preset = @import("preset.zig");
const fetch = @import("fetch.zig");
const archive = @import("archive.zig");
const gpu = @import("gpu.zig");
const sherpa = @import("sherpa.zig");

pub const max_archive_bytes: u64 = 1024 * 1024 * 1024;

const RuntimeInfo = struct {
    name: []const u8,
    url: []const u8,
    sha256: []const u8,
};

/// Pinned sherpa-onnx runtime bundles (same pins as the portable pack).
pub const runtime_cpu = struct {
    pub const name = "sherpa-onnx-v1.13.5-linux-x64-shared-no-tts";
    pub const url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/" ++ name ++ ".tar.bz2";
    pub const sha256: []const u8 = "a39369615d610cb835f225b6b7fbff684aedf46557eab8a90e1ccc11fac84166";
};

pub const runtime_gpu = struct {
    pub const name = "sherpa-onnx-v1.13.5-cuda-13.x-cudnn-9.x-onnxruntime1.27.1-linux-x64-gpu";
    pub const url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/" ++ name ++ ".tar.bz2";
    pub const sha256: []const u8 = "dde7732e0649dbe0702266f4b57d9b2ac1136f879057bed6754b984752ca7a35";
};

/// cuDNN 9 (CUDA 13): not redistributable auto-installed, only pinned here
/// for `doctor` guidance; `just install-cudnn` handles the setup.
pub const cudnn = struct {
    pub const version = "9.25.0.15";
    pub const url = "https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/linux-x86_64/cudnn-linux-x86_64-9.25.0.15_cuda13-archive.tar.xz";
    pub const sha256: []const u8 = "bdf8c65f92dd552141d011fd7e7a1bfbafdc6239667b15c44d604597fa927745";
};

pub const Error = error{
    UnsupportedModel,
    AlreadyInstalled,
    FetchFailed,
    VerifyFailed,
    ExtractFailed,
    HomeNotFound,
    OutOfMemory,
};

pub fn mapFetchError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DigestMismatch, error.DigestInvalid, error.TooLarge => error.VerifyFailed,
        else => error.FetchFailed,
    };
}

pub fn mapArchiveError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExtractFailed,
    };
}

pub const Layout = struct {
    data_dir: []const u8,

    pub fn modelsDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "models" });
    }
    pub fn cacheDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "cache" });
    }
    pub fn runtimeDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "runtime" });
    }
    pub fn cudnnLibDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "cudnn", "lib" });
    }
    pub fn transcriptsDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "transcripts" });
    }
    pub fn modelDir(self: Layout, allocator: std.mem.Allocator, upstream_name: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.data_dir, "models", upstream_name });
    }
};

/// Resolve the data directory: `LSZL_DATA_HOME` wins (used as-is), then
/// `$XDG_DATA_HOME/lszl`, then `$HOME/.local/share/lszl`.
pub fn dataDirectory(allocator: std.mem.Allocator) Error![]u8 {
    if (std.c.getenv("LSZL_DATA_HOME")) |value| {
        return allocator.dupe(u8, std.mem.span(value)) catch error.OutOfMemory;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |value| {
        return std.fs.path.join(allocator, &.{ std.mem.span(value), "lszl" }) catch error.OutOfMemory;
    }
    const home = std.c.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), ".local", "share", "lszl" }) catch error.OutOfMemory;
}

pub fn defaultModelPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, "default-model" });
}

/// True when `preset` has been installed (its tokens.txt exists).
pub fn isInstalled(io: std.Io, allocator: std.mem.Allocator, layout: Layout, model: *const preset.Preset) bool {
    const dir = layout.modelDir(allocator, model.upstream_name) catch return false;
    defer allocator.free(dir);
    return fileExistsAt(io, dir, "tokens.txt");
}

pub const InstallResult = enum { installed, already_present };

const install_progress = fetch.Progress{
    .callback = printProgress,
    .granularity = 128 * 1024 * 1024,
};

fn printProgress(done: u64, total: u64) void {
    if (total > 0) {
        std.debug.print("\r  downloading {d}/{d} MiB", .{ done / (1024 * 1024), total / (1024 * 1024) });
    } else {
        std.debug.print("\r  downloading {d} MiB", .{done / (1024 * 1024)});
    }
}

/// Download (or reuse the verified cache entry), extract and atomically
/// move a model into the store. Never overwrites an existing model.
pub fn installModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    layout: Layout,
    model: *const preset.Preset,
) Error!InstallResult {
    const dest = try layout.modelDir(allocator, model.upstream_name);
    defer allocator.free(dest);

    if (fileExistsAt(io, dest, "tokens.txt")) return .already_present;

    const cache_dir = try layout.cacheDir(allocator);
    defer allocator.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch return error.ExtractFailed;

    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.bz2", .{ cache_dir, model.upstream_name });
    defer allocator.free(archive_path);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.bz2", .{ preset.archive_url_base, model.upstream_name });
    defer allocator.free(url);

    try downloadAndExtract(allocator, io, environ_map, .{
        .url = url,
        .archive_path = archive_path,
        .sha256 = model.sha256,
        .dest_dir = cache_dir,
        .final_dir = dest,
        .top_level_name = model.upstream_name,
    });
    return .installed;
}

/// Same flow for the shared punctuation model.
pub fn installPunctuation(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    layout: Layout,
) Error!void {
    const models_dir = try layout.modelsDir(allocator);
    defer allocator.free(models_dir);
    std.Io.Dir.cwd().createDirPath(io, models_dir) catch return error.ExtractFailed;
    const dest = try layout.modelDir(allocator, preset.punctuation.upstream_name);
    defer allocator.free(dest);
    if (fileExistsAt(io, dest, "model.int8.onnx")) return;

    const cache_dir = try layout.cacheDir(allocator);
    defer allocator.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch return error.ExtractFailed;
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.bz2", .{ cache_dir, preset.punctuation.upstream_name });
    defer allocator.free(archive_path);

    try downloadAndExtract(allocator, io, environ_map, .{
        .url = preset.punctuation.url,
        .archive_path = archive_path,
        .sha256 = preset.punctuation.sha256,
        .dest_dir = cache_dir,
        .final_dir = dest,
        .top_level_name = preset.punctuation.upstream_name,
    });
}

/// Make sure the runtime bundle for `provider` exists, downloading it on
/// first use. Returns the absolute path of its `lib/` directory.
pub fn ensureRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    layout: Layout,
    provider: sherpa.Provider,
) Error![]u8 {
    const info: RuntimeInfo = switch (provider) {
        .cpu => .{ .name = runtime_cpu.name, .url = runtime_cpu.url, .sha256 = runtime_cpu.sha256 },
        .cuda => .{ .name = runtime_gpu.name, .url = runtime_gpu.url, .sha256 = runtime_gpu.sha256 },
    };
    const runtime_dir = try layout.runtimeDir(allocator);
    defer allocator.free(runtime_dir);
    const lib_dir = try std.fs.path.join(allocator, &.{ runtime_dir, info.name, "lib" });
    errdefer allocator.free(lib_dir);
    if (fileExistsAt(io, lib_dir, "libsherpa-onnx-c-api.so")) return lib_dir;

    std.Io.Dir.cwd().createDirPath(io, runtime_dir) catch return error.ExtractFailed;
    const cache_dir = try layout.cacheDir(allocator);
    defer allocator.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch return error.ExtractFailed;
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.bz2", .{ cache_dir, info.name });
    defer allocator.free(archive_path);

    try downloadAndExtract(allocator, io, environ_map, .{
        .url = info.url,
        .archive_path = archive_path,
        .sha256 = info.sha256,
        .dest_dir = runtime_dir,
        .final_dir = "",
        .top_level_name = info.name,
    });
    if (!fileExistsAt(io, lib_dir, "libsherpa-onnx-c-api.so")) return error.ExtractFailed;
    return lib_dir;
}

const DownloadExtract = struct {
    url: []const u8,
    archive_path: []const u8,
    sha256: []const u8,
    /// Directory the archive is extracted into.
    dest_dir: []const u8,
    /// Final atomic destination (may be empty for in-place extraction).
    final_dir: []const u8,
    top_level_name: []const u8,
};

fn downloadAndExtract(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    spec: DownloadExtract,
) Error!void {
    // Reuse a previously verified download when it matches the pin.
    if (verifyDigest(allocator, io, spec.archive_path, spec.sha256)) |_| {
        std.debug.print("  using verified cache: {s}\n", .{spec.archive_path});
    } else |e| switch (e) {
        error.FileMissing => {
            const resume_from = partSize(io, spec.archive_path) catch 0;
            std.debug.print("  fetching {s}\n", .{spec.url});
            fetch.download(allocator, io, environ_map, .{
                .url = spec.url,
                .dest = spec.archive_path,
                .expected_sha256 = spec.sha256,
                .max_bytes = max_archive_bytes,
                .resume_from = resume_from,
            }, install_progress) catch |err| {
                std.debug.print("lszl: download error: {s}\n", .{@errorName(err)});
                return mapFetchError(err);
            };
            std.debug.print("\n", .{});
        },
        else => return mapFetchError(e),
    }

    if (spec.final_dir.len == 0) {
        // Runtime-style in-place extraction.
        archive.extractTarBz2(allocator, io, spec.archive_path, spec.dest_dir) catch |err|
            return mapArchiveError(err);
        return;
    }

    // Model-style staged extraction + atomic move. Never overwrite.
    var staging_buf: [4096]u8 = undefined;
    const staging = std.fmt.bufPrint(&staging_buf, "{s}/.staging-{d}", .{ spec.dest_dir, std.os.linux.getpid() }) catch
        return error.OutOfMemory;
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().createDirPath(io, staging) catch return error.ExtractFailed;
    errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    archive.extractTarBz2(allocator, io, spec.archive_path, staging) catch |err|
        return mapArchiveError(err);

    const extracted = try std.fs.path.join(allocator, &.{ staging, spec.top_level_name });
    defer allocator.free(extracted);
    if (!fileExistsAt(io, extracted, "tokens.txt")) return error.ExtractFailed;

    // Race-safe install: the rename only succeeds if the destination is
    // still free; a concurrent install wins and we report already-present.
    std.Io.Dir.cwd().rename(extracted, .cwd(), spec.final_dir, io) catch return error.AlreadyInstalled;
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
}

/// `error.FileMissing` means the archive is absent (or an unfinished
/// `.part` exists), any other error means it is present but fails the
/// pin. Success (`{}`) means verified.
fn verifyDigest(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, sha256: []const u8) (fetch.Error || error{FileMissing})!void {
    std.Io.Dir.accessAbsolute(io, archive_path, .{}) catch return error.FileMissing;
    const actual = try fetch.digestOfFile(allocator, io, archive_path);
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, sha256) catch return error.DigestInvalid;
    if (!std.mem.eql(u8, &actual, &expected)) return error.DigestMismatch;
}

fn partSize(io: std.Io, archive_path: []const u8) !u64 {
    var buf: [4096]u8 = undefined;
    const part = std.fmt.bufPrint(&buf, "{s}.part", .{archive_path}) catch return 0;
    const stat = std.Io.Dir.cwd().statFile(io, part, .{}) catch return 0;
    return stat.size;
}

fn fileExistsAt(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn saveDefaultModel(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, name: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch return error.AccessDenied;
    const path = try defaultModelPath(allocator, data_dir);
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = name });
}

pub fn loadDefaultModel(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) ![]u8 {
    const path = try defaultModelPath(allocator, data_dir);
    defer allocator.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    errdefer allocator.free(content);
    // Tolerate files written by hand (trailing newline).
    return allocator.dupe(u8, std.mem.trim(u8, content, " \t\r\n"));
}
