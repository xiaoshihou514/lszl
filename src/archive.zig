//! Native archive handling: .tar.bz2 extraction without subprocesses.
//!
//! bzip2 is loaded with `dlopen` (it is a ubiquitous runtime library and
//! Zig's std has no bz2 decoder), the stream is decompressed to a
//! sibling `.tar`, and extraction uses std.tar, whose `sanitizePath`
//! rejects absolute paths and `..` traversal entries.

const std = @import("std");

pub const Error = error{
    Bz2Unavailable,
    ArchiveOpenFailed,
    DecompressFailed,
    ArchiveTooLarge,
    ExtractFailed,
    OutOfMemory,
};

/// Decompressed-size sanity cap: the largest supported model archive is
/// 1 GiB compressed, which expands to well under this bound.
const max_tar_bytes: u64 = 6 * 1024 * 1024 * 1024;

const BZ_OK: c_int = 0; // needs more input (or more output space)
const BZ_RUN_OK: c_int = 1;
const BZ_STREAM_END: c_int = 4;

const bz_stream = extern struct {
    next_in: ?[*]u8 = null,
    avail_in: c_uint = 0,
    total_in_lo32: c_uint = 0,
    total_in_hi32: c_uint = 0,
    next_out: ?[*]u8 = null,
    avail_out: c_uint = 0,
    total_out_lo32: c_uint = 0,
    total_out_hi32: c_uint = 0,
    state: ?*anyopaque = null,
    bzalloc: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) ?*anyopaque = null,
    bzfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    opaque_: ?*anyopaque = null,
};

const Bz2 = struct {
    init: *const fn (*bz_stream, c_int, c_int) callconv(.c) c_int,
    decompress: *const fn (*bz_stream) callconv(.c) c_int,
    end: *const fn (*bz_stream) callconv(.c) c_int,

    /// Candidate sonames across distributions (Fedora/Arch: .so.1,
    /// Debian: .so.1.0 with a .so.1 symlink).
    const candidates = [_][]const u8{
        "libbz2.so.1",
        "libbz2.so.1.0",
        "libbz2.so.0",
        "libbz2.so",
    };

    fn open() Error!Bz2 {
        for (candidates) |candidate| {
            const handle = std.c.dlopen(@ptrCast(candidate), .{ .NOW = true }) orelse continue;
            inline for (.{ "BZ2_bzDecompressInit", "BZ2_bzDecompress", "BZ2_bzDecompressEnd" }) |_| {}
            const init_ptr = std.c.dlsym(handle, "BZ2_bzDecompressInit") orelse continue;
            const decompress_ptr = std.c.dlsym(handle, "BZ2_bzDecompress") orelse continue;
            const end_ptr = std.c.dlsym(handle, "BZ2_bzDecompressEnd") orelse continue;
            return .{
                .init = @ptrCast(@alignCast(init_ptr)),
                .decompress = @ptrCast(@alignCast(decompress_ptr)),
                .end = @ptrCast(@alignCast(end_ptr)),
            };
        }
        return error.Bz2Unavailable;
    }
};

/// Extract `archive_path` (a .tar.bz2) into the existing directory
/// `dest_dir`, stripping the archive's single top-level directory.
pub fn extractTarBz2(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_dir: []const u8) Error!void {
    const bz2 = try Bz2.open();

    var tar_path_buf: [4096]u8 = undefined;
    const tar_path = std.fmt.bufPrint(&tar_path_buf, "{s}.tar", .{archive_path}) catch
        return error.OutOfMemory;
    defer std.Io.Dir.cwd().deleteFile(io, tar_path) catch {};

    try decompressToFile(allocator, io, bz2, archive_path, tar_path);

    var dest = std.Io.Dir.openDirAbsolute(io, dest_dir, .{}) catch return error.ExtractFailed;
    defer dest.close(io);

    const tar_file = std.Io.Dir.cwd().openFile(io, tar_path, .{}) catch return error.ExtractFailed;
    defer tar_file.close(io);

    var tar_buffer: [512 * 1024]u8 = undefined;
    var file_reader = tar_file.reader(io, &tar_buffer);
    // Archives keep their own top-level directory (e.g.
    // sherpa-onnx-<model>/...), so nothing is stripped.
    std.tar.extract(io, dest, &file_reader.interface, .{
        .mode_mode = .ignore,
    }) catch return error.ExtractFailed;
}

fn decompressToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    bz2: Bz2,
    archive_path: []const u8,
    tar_path: []const u8,
) Error!void {
    const archive = std.Io.Dir.cwd().openFile(io, archive_path, .{}) catch return error.ArchiveOpenFailed;
    defer archive.close(io);

    const tar_file = std.Io.Dir.cwd().createFile(io, tar_path, .{ .truncate = true }) catch
        return error.ArchiveOpenFailed;
    defer tar_file.close(io);

    var stream = std.mem.zeroes(bz_stream);
    if (bz2.init(&stream, 0, 0) != BZ_OK) return error.DecompressFailed;
    defer _ = bz2.end(&stream);

    // Four distinct buffers: the reader's internal buffer must not alias
    // the decompress-input window, and the writer's buffer must not alias
    // the decompress-output window (memcpy would panic on aliasing).
    const io_buffer = allocator.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    defer allocator.free(io_buffer);
    const in_buffer = allocator.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    defer allocator.free(in_buffer);
    const out_buffer = allocator.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    defer allocator.free(out_buffer);
    const writer_buffer = allocator.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    defer allocator.free(writer_buffer);

    var archive_reader = archive.reader(io, io_buffer);
    const reader = &archive_reader.interface;
    var tar_writer = tar_file.writer(io, writer_buffer);
    const writer = &tar_writer.interface;

    var input_done = false;
    var total: u64 = 0;
    while (true) {
        if (!input_done and stream.avail_in == 0) {
            const n = reader.readSliceShort(in_buffer) catch return error.ArchiveOpenFailed;
            if (n == 0) {
                input_done = true;
            } else {
                stream.next_in = in_buffer.ptr;
                stream.avail_in = @intCast(n);
            }
        }
        stream.next_out = out_buffer.ptr;
        stream.avail_out = @intCast(out_buffer.len);
        const rc = bz2.decompress(&stream);
        const produced = out_buffer.len - stream.avail_out;
        if (produced > 0) {
            total += produced;
            if (total > max_tar_bytes) return error.ArchiveTooLarge;
            writer.writeAll(out_buffer[0..produced]) catch return error.ExtractFailed;
        }
        switch (rc) {
            BZ_STREAM_END => return,
            BZ_OK, BZ_RUN_OK => {
                // BZ_OK: the engine wants more input (or has nothing to
                // emit yet). A stall with the input exhausted is fatal.
                if (input_done and stream.avail_in == 0 and produced == 0)
                    return error.DecompressFailed;
            },
            else => return error.DecompressFailed,
        }
    }
}

test "bz_stream layout matches the C ABI" {
    // x86_64: 8 + 4 + 4 + 4 (+4 pad) + 8 + 4 + 4 + 4 (+4 pad) + 8 + 8 + 8 + 8
    // x86_64 layout: 4 pointers, two runs of 3 uints (with tail padding
    // to pointer alignment), then state + 3 callback pointers.
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(bz_stream));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(bz_stream));
}
