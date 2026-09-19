//! Native HTTPS downloads with SHA-256 verification, a hard size cap and
//! resumable `.part` files. No subprocess and no curl.
//!
//! The digest is always recomputed from the complete file on disk after
//! the transfer, so resumed (partly cached) downloads get the same
//! verification as fresh ones, and a cache hit can never silently bypass
//! verification.

const std = @import("std");

pub const Error = error{
    NetworkFailed,
    StatusFailed,
    TooLarge,
    DigestMismatch,
    DigestInvalid,
    OutOfMemory,
};

pub const Request = struct {
    url: []const u8,
    /// Final destination path; a sibling `<dest>.part` is used while
    /// downloading and renamed into place after verification.
    dest: []const u8,
    /// Expected SHA-256 of the complete file, 64 hex chars.
    expected_sha256: []const u8,
    /// Hard cap on the complete file size; exceeding it fails TooLarge.
    max_bytes: u64,
    /// Bytes already present in `<dest>.part` from an earlier attempt.
    resume_from: u64 = 0,
};

/// Called after each chunk with (bytes completed, total bytes; total is 0
/// when the server did not send a length).
pub const Progress = struct {
    callback: *const fn (done: u64, total: u64) void,
    /// Minimum byte delta between callbacks, to keep output readable.
    granularity: u64 = 64 * 1024 * 1024,
};

pub fn download(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    request: Request,
    progress: ?Progress,
) Error!void {
    var part_path_buf: [4096]u8 = undefined;
    const part_path = std.fmt.bufPrint(&part_path_buf, "{s}.part", .{request.dest}) catch
        return error.OutOfMemory;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    if (environ_map) |map| client.initDefaultProxies(allocator, map) catch {};

    const uri = std.Uri.parse(request.url) catch return error.NetworkFailed;

    var range_storage: [48]u8 = undefined;
    var extra_headers: []const std.http.Header = &.{};
    var want_resume = request.resume_from > 0;
    var range_header: std.http.Header = undefined;
    if (want_resume) {
        const range = std.fmt.bufPrint(&range_storage, "bytes={d}-", .{request.resume_from}) catch
            return error.OutOfMemory;
        range_header = .{ .name = "Range", .value = range };
        extra_headers = @constCast(&.{range_header});
    }

    var req = std.http.Client.request(&client, .GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = extra_headers,
    }) catch return error.NetworkFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.NetworkFailed;

    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch return error.NetworkFailed;

    // 416 means the .part already extends to (or past) EOF — the previous
    // attempt finished downloading; skip the body and just verify it.
    const already_complete = response.head.status == .range_not_satisfiable;
    switch (response.head.status) {
        .ok, .partial_content, .range_not_satisfiable => {},
        else => {
            std.debug.print("lszl: unexpected HTTP status {d} from {s}\n", .{ @intFromEnum(response.head.status), request.url });
            return error.StatusFailed;
        },
    }
    if (!want_resume and already_complete) return error.StatusFailed;

    if (!already_complete) {
        // A server that ignored our Range must not corrupt the part file:
        // a plain 200 means "restart from zero".
        if (response.head.status != .partial_content) want_resume = false;
        const resume_at: u64 = if (want_resume) request.resume_from else 0;

        if (response.head.content_length) |len| {
            if (resume_at +| len > request.max_bytes) return error.TooLarge;
        }

        const file = std.Io.Dir.cwd().createFile(
            io,
            part_path,
            .{ .truncate = resume_at == 0 },
        ) catch return error.NetworkFailed;
        var file_closed = false;
        defer if (!file_closed) file.close(io);

        var file_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &file_buffer);
        if (resume_at > 0) file_writer.seekTo(resume_at) catch return error.NetworkFailed;

        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        var total: u64 = resume_at;
        var last_report: u64 = total;
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk) catch return error.NetworkFailed;
            if (n == 0) break;
            total += n;
            if (total > request.max_bytes) return error.TooLarge;
            file_writer.interface.writeAll(chunk[0..n]) catch return error.NetworkFailed;
            if (progress) |p| {
                if (total -| last_report >= p.granularity) {
                    last_report = total;
                    const reported_total = if (response.head.content_length) |len| resume_at +| len else 0;
                    p.callback(total, reported_total);
                }
            }
        }
        file_writer.interface.flush() catch return error.NetworkFailed;
        file.close(io);
        file_closed = true;
    }

    // The digest is always recomputed from the complete file on disk —
    // never trust the stream alone (resume paths combine old and new bytes).
    try verifyAndPromote(allocator, io, part_path, request.dest, request.expected_sha256);
}

/// Recompute the digest of `part_path` from disk and, when it matches
/// the pin, atomically rename it to `dest`.
fn verifyAndPromote(
    allocator: std.mem.Allocator,
    io: std.Io,
    part_path: []const u8,
    dest: []const u8,
    expected_sha256: []const u8,
) Error!void {
    const actual = try digestOfFile(allocator, io, part_path);
    const expected = parseDigest(expected_sha256) orelse return error.DigestInvalid;
    if (!std.mem.eql(u8, &actual, &expected)) return error.DigestMismatch;
    std.Io.Dir.cwd().rename(part_path, .cwd(), dest, io) catch return error.NetworkFailed;
}

/// SHA-256 of a file, streamed in fixed chunks.
pub fn digestOfFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error![32]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.NetworkFailed;
    defer file.close(io);
    const io_buffer = allocator.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    defer allocator.free(io_buffer);
    const chunk_buffer = allocator.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    defer allocator.free(chunk_buffer);
    var file_reader = file.reader(io, io_buffer);
    const reader = &file_reader.interface;
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = reader.readSliceShort(chunk_buffer) catch return error.NetworkFailed;
        if (n == 0) break;
        sha.update(chunk_buffer[0..n]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return digest;
}

fn parseDigest(hex_digest: []const u8) ?[32]u8 {
    if (hex_digest.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex_digest) catch return null;
    return out;
}

test "parseDigest accepts 64 hex chars only" {
    try std.testing.expect(parseDigest("00" ** 32) != null);
    try std.testing.expect(parseDigest("zz" ** 32) == null);
    try std.testing.expect(parseDigest("00" ** 31) == null);
}
