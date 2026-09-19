//! GPU discovery and the VRAM-aware slicing policy for offline models.
//!
//! NVIDIA state is probed in-process through NVML (`libnvidia-ml.so.1`,
//! the same library `nvidia-smi` uses), so no subprocess is involved.
//! The slice policy is the answer to "maximize speed within GPU memory":
//! offline models decode the longest utterance that provably fits the
//! free VRAM instead of a fixed 60 s chunk, and adapt after every slice.
//! Streaming models need no slicing at all — their working set is
//! constant in audio length, so the whole file feeds through one stream.

const std = @import("std");

pub const Device = struct {
    /// NUL-free device name, e.g. "NVIDIA GeForce RTX 3050 Ti".
    name: []const u8,
    total_bytes: u64,
    free_bytes: u64,

    pub fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Error = error{ NvmlUnavailable, NvmlFailed };

const Nvml = struct {
    handle: *anyopaque,
    init: *const fn () callconv(.c) c_int,
    shutdown: *const fn () callconv(.c) c_int,
    get_count: *const fn (*c_uint) callconv(.c) c_int,
    get_handle: *const fn (c_uint, *?*anyopaque) callconv(.c) c_int,
    get_name: *const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int,
    /// v1 memory query: no struct-version header, valid on every driver.
    get_memory: *const fn (?*anyopaque, *MemoryInfo) callconv(.c) c_int,

    const MemoryInfo = extern struct {
        total: u64,
        free: u64,
        used: u64,
    };

    fn open() Error!Nvml {
        // RTLD_NOW, never LAZY: lazy PLT binding inside NVML deadlocks.
        for ([_][]const u8{ "libnvidia-ml.so.1", "libnvidia-ml.so" }) |candidate| {
            const handle = std.c.dlopen(@ptrCast(candidate), .{ .NOW = true }) orelse continue;
            const nvml = fromHandle(handle) catch {
                continue;
            };
            return nvml;
        }
        return error.NvmlUnavailable;
    }

    fn fromHandle(handle: *anyopaque) Error!Nvml {
        var nvml: Nvml = .{
            .handle = handle,
            .init = undefined,
            .shutdown = undefined,
            .get_count = undefined,
            .get_handle = undefined,
            .get_name = undefined,
            .get_memory = undefined,
        };
        inline for (@typeInfo(Nvml).@"struct".fields[1..]) |field| {
            const sym = comptime symbolFull(field.name);
            const ptr = std.c.dlsym(handle, sym.ptr) orelse return error.NvmlUnavailable;
            @field(nvml, field.name) = @ptrCast(@alignCast(ptr));
        }
        return nvml;
    }

    fn symbolFull(comptime field_name: []const u8) [:0]const u8 {
        comptime {
            for (symbol_names) |pair| {
                if (std.mem.eql(u8, pair[0], field_name)) return "nvml" ++ pair[1];
            }
        }
        unreachable;
    }

    const symbol_names = .{
        .{ "init", "Init_v2" },
        .{ "shutdown", "Shutdown" },
        .{ "get_count", "DeviceGetCount_v2" },
        .{ "get_handle", "DeviceGetHandleByIndex_v2" },
        .{ "get_name", "DeviceGetName" },
        .{ "get_memory", "DeviceGetMemoryInfo" },
    };
};

/// Probe the NVIDIA device with the most free memory, if any.
/// Returns null when the machine has no usable NVIDIA driver.
pub fn probe(allocator: std.mem.Allocator) Error!?Device {
    const nvml = Nvml.open() catch |err| return err;
    // NVML stays resident for the process lifetime: dlclose while its
    // internal worker threads are alive is unsafe.

    if (nvml.init() != 0) return error.NvmlFailed;
    defer _ = nvml.shutdown();

    var count: c_uint = 0;
    if (nvml.get_count(&count) != 0 or count == 0) return null;

    var best: ?Device = null;
    var name_buf: [96]u8 = undefined;
    var index: c_uint = 0;
    while (index < count) : (index += 1) {
        var handle: ?*anyopaque = null;
        if (nvml.get_handle(index, &handle) != 0) continue;
        if (nvml.get_name(handle, &name_buf, name_buf.len) != 0) continue;
        var mem: Nvml.MemoryInfo = undefined;
        if (nvml.get_memory(handle, &mem) != 0) continue;

        const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;
        const better = best == null or mem.free > best.?.free_bytes;
        if (!better) continue;
        const name = allocator.dupe(u8, name_buf[0..name_len]) catch return error.NvmlFailed;
        if (best) |*previous| allocator.free(previous.name);
        best = .{ .name = name, .total_bytes = mem.total, .free_bytes = mem.free };
    }
    return best;
}

/// Policy constants for offline-slice sizing.
///
/// The sherpa-onnx C API does not catch ONNX Runtime C++ exceptions, so a
/// CUDA out-of-memory aborts the process instead of surfacing as an
/// error. Sizing therefore never reacts to OOM — it prevents it: slices
/// start small, activation growth is measured per audio-second after
/// every decode, and the next slice is bounded by that measurement with
/// a quadratic-safety factor (attention memory grows superlinearly with
/// utterance length) before any growth is applied.
pub const policy = struct {
    /// First decode duration on a GPU, seconds: small enough that even a
    /// 4 GB card cannot OOM, large enough to measure growth reliably.
    pub const gpu_start_seconds: u32 = 20;
    /// First decode duration on CPU (no VRAM constraint), seconds.
    pub const cpu_start_seconds: u32 = 300;
    /// Hard ceiling for one utterance, seconds. Offline quality degrades
    /// and activation memory becomes unpredictable beyond this length.
    pub const max_slice_seconds: u32 = 300;
    /// Smallest slice we still consider useful, seconds.
    pub const min_slice_seconds: u32 = 10;
    /// Safety margin kept free on the device at all times, bytes.
    pub const margin_bytes: u64 = 512 * 1024 * 1024;
    /// Growth rate cap between consecutive slices (gradualism).
    pub const grow_num: u32 = 3;
    pub const grow_den: u32 = 2;
    /// Superlinear-safety multiplier applied to measured activation
    /// growth before projecting it onto a longer slice.
    pub const safety_factor_num: u64 = 2;
    pub const safety_factor_den: u64 = 1;
};

/// Data-driven slice planner for offline models. One instance per file;
/// `observeBaseline` once after the model is loaded, then `recordDecode`
/// after every slice decode.
///
/// The ONNX Runtime arena never returns device memory, so the planner
/// distinguishes two regimes:
///
/// * Slice lengths at or below the largest already-successful length
///   (`max_ok_seconds`) reuse the arena that is already resident — no
///   fresh memory needed, so they are always safe.
/// * Growing beyond `max_ok_seconds` needs new device memory; the growth
///   is projected from the worst measured activation-bytes-per-second,
///   inflated by a safety factor (attention memory grows superlinearly
///   with utterance length), and only allowed when it provably fits.
pub const SlicePlanner = struct {
    slice_seconds: u32,
    free_bytes: u64,
    /// Device bytes in use by the recognizer (model + resident arena).
    used_bytes: u64 = 0,
    /// Worst-case activation bytes observed per audio-second.
    growth_bps: u64 = 0,
    /// Largest slice length decoded successfully so far.
    max_ok_seconds: u32 = 0,
    have_baseline: bool = false,

    pub fn init(free_vram: u64) SlicePlanner {
        return .{
            .slice_seconds = if (free_vram > 0) policy.gpu_start_seconds else policy.cpu_start_seconds,
            .free_bytes = free_vram,
        };
    }

    /// Snapshot device usage before the first decode (model resident).
    pub fn observeBaseline(self: *SlicePlanner, used_bytes: u64) void {
        self.used_bytes = used_bytes;
        self.have_baseline = true;
    }

    /// Feed back the device usage measured right after a slice decode.
    pub fn recordDecode(self: *SlicePlanner, slice_seconds: u32, used_after: u64) void {
        if (self.have_baseline and slice_seconds > 0) {
            const growth = used_after -| self.used_bytes;
            const per_second = growth / slice_seconds;
            // Keep the worst observation; activation curves are convex.
            if (per_second > self.growth_bps) self.growth_bps = per_second;
        }
        self.used_bytes = used_after;
        self.have_baseline = true;
        if (slice_seconds > self.max_ok_seconds) self.max_ok_seconds = slice_seconds;
    }

    /// Record a failed slice: shrink the working point. The resident
    /// arena keeps its high-water allocation, so memory is not returned.
    pub fn recordFailure(self: *SlicePlanner, attempted_seconds: u32) void {
        const shrunk = @max(attempted_seconds / 2, policy.min_slice_seconds);
        self.max_ok_seconds = @min(self.max_ok_seconds, shrunk);
        self.slice_seconds = @min(shrunk, self.max_ok_seconds);
        if (self.slice_seconds == 0) self.slice_seconds = policy.min_slice_seconds;
    }

    /// Choose the next slice length. `free_now` is the free device
    /// memory right now (pass 0 on CPU, where only policy caps apply).
    pub fn nextDuration(self: *SlicePlanner, free_now: u64) u32 {
        if (self.free_bytes == 0) {
            self.slice_seconds = @min(self.slice_seconds * policy.grow_num / policy.grow_den, policy.max_slice_seconds);
            return self.slice_seconds;
        }
        // A previously-proven length always fits in the resident arena.
        if (self.max_ok_seconds >= self.slice_seconds and self.max_ok_seconds > 0) {
            self.slice_seconds = self.max_ok_seconds;
        }
        if (self.max_ok_seconds >= policy.max_slice_seconds) return self.slice_seconds;

        // Try to grow beyond the proven length, gradually and only if
        // the projected activation growth provably fits.
        const grown = @min(self.max_ok_seconds * policy.grow_num / policy.grow_den, policy.max_slice_seconds);
        const candidate = @max(grown, policy.min_slice_seconds);
        const projected_bps = self.growth_bps * policy.safety_factor_num / policy.safety_factor_den;
        const extra_needed = projected_bps * (candidate -| self.max_ok_seconds);
        const budget = free_now -| policy.margin_bytes;
        if (self.used_bytes +| extra_needed <= budget) {
            self.slice_seconds = candidate;
        }
        return self.slice_seconds;
    }
};

test "planner starts small, proves growth, then rides the proven size" {
    const mib: u64 = 1024 * 1024;
    const gib: u64 = 1024 * mib;
    var planner = SlicePlanner.init(3 * gib);
    try std.testing.expectEqual(policy.gpu_start_seconds, planner.slice_seconds);

    // Model resident at 900 MB; the 20 s slice grew usage by 100 MB
    // (5 MB per audio-second).
    planner.observeBaseline(900 * mib);
    planner.recordDecode(policy.gpu_start_seconds, 1000 * mib);
    try std.testing.expectEqual(@as(u64, 5 * mib), planner.growth_bps);
    try std.testing.expectEqual(policy.gpu_start_seconds, planner.max_ok_seconds);

    // Growth to 30 s projects 2*5 MB/s * 10 s = 100 MB extra, fits.
    try std.testing.expectEqual(@as(u32, 30), planner.nextDuration(3 * gib));

    // A tiny card: growth beyond the proven 20 s does not fit.
    var small = SlicePlanner.init(700 * mib);
    small.observeBaseline(200 * mib);
    small.recordDecode(20, 240 * mib); // 2 MB/s growth
    // budget = 700-512 = 188 MB < used 240 MB: no growth allowed.
    try std.testing.expectEqual(@as(u32, 20), small.nextDuration(700 * mib));
}

test "planner failure shrinks and cpu mode grows to the cap" {
    var cpu = SlicePlanner.init(0);
    try std.testing.expectEqual(policy.cpu_start_seconds, cpu.slice_seconds);
    _ = cpu.nextDuration(0);
    try std.testing.expectEqual(policy.max_slice_seconds, cpu.slice_seconds);

    const mib: u64 = 1024 * 1024;
    const gib: u64 = 1024 * mib;
    var planner = SlicePlanner.init(3 * gib);
    planner.observeBaseline(900 * mib);
    planner.recordDecode(20, 1000 * mib);
    _ = planner.nextDuration(3 * gib); // plans 30 s
    planner.recordFailure(42);
    // Falls back to the largest proven-safe length, not the floor.
    try std.testing.expectEqual(@as(u32, 20), planner.slice_seconds);
    try std.testing.expectEqual(@as(u32, 20), planner.max_ok_seconds);
}
