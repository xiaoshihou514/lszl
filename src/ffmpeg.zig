//! Native FFmpeg decoder: turns any media file the host FFmpeg can demux
//! into interleaved mono f32 PCM at 16 kHz, the format every sherpa-onnx
//! ASR model expects.
//!
//! The decoder is a streaming iterator, never a whole-file materializer:
//! callers pull slices as they are produced, so transcription can run as a
//! decode/inference pipeline. Every libav* resource is owned here and
//! released exactly once.

const std = @import("std");
const c = @import("c.zig");

pub const sample_rate: i32 = 16000;

/// AVERROR(EAGAIN) and AVERROR(EOF); function-like libav macros are not
/// exported by translate-c, so the wire values are pinned here.
const AVERROR_EAGAIN: c_int = -11;
const AVERROR_EOF: c_int = -0x20464F45; // -FFERRTAG('E','O','F',' ')

pub const Error = error{
    OpenFailed,
    FindStreamFailed,
    NoAudioStream,
    OpenCodecFailed,
    ResampleSetupFailed,
    ReadFailed,
    ConvertFailed,
    OutOfMemory,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    format: ?*c.ffmpeg.AVFormatContext = null,
    codec: ?*c.ffmpeg.AVCodecContext = null,
    resampler: ?*c.ffmpeg.SwrContext = null,
    frame: ?*c.ffmpeg.AVFrame = null,
    packet: ?*c.ffmpeg.AVPacket = null,
    audio_stream: c_int = -1,
    format_opened: bool = false,
    codec_allocated: bool = false,
    codec_opened: bool = false,
    resampler_allocated: bool = false,
    frames_allocated: bool = false,
    input_closed: bool = false,
    decode_flushed: bool = false,
    resample_flushed: bool = false,
    /// Converted mono samples not yet returned to the caller.
    pending: std.ArrayList(f32) = .empty,
    /// How many leading samples of `pending` were already returned.
    consumed: usize = 0,
    /// Scratch buffer for one swr_convert call.
    scratch: []f32 = &.{},
    /// Text of the most recent libav error, for diagnostics.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) Error!Decoder {
        var self = Decoder{ .allocator = allocator };
        errdefer self.freeAll();

        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        if (c.ffmpeg.avformat_open_input(@ptrCast(&self.format), path_z.ptr, null, null) != 0)
            return error.OpenFailed;
        self.format_opened = true;
        if (c.ffmpeg.avformat_find_stream_info(self.format, null) < 0)
            return error.FindStreamFailed;

        var decoder_ref: ?*const c.ffmpeg.AVCodec = null;
        self.audio_stream = c.ffmpeg.av_find_best_stream(
            self.format,
            c.ffmpeg.AVMEDIA_TYPE_AUDIO,
            -1,
            -1,
            &decoder_ref,
            0,
        );
        if (self.audio_stream < 0) return error.NoAudioStream;
        const stream = self.format.?.streams[@intCast(self.audio_stream)];

        const codec = decoder_ref orelse c.ffmpeg.avcodec_find_decoder(stream.*.codecpar.*.codec_id) orelse
            return error.OpenCodecFailed;
        self.codec = c.ffmpeg.avcodec_alloc_context3(codec) orelse return error.OpenCodecFailed;
        self.codec_allocated = true;
        if (c.ffmpeg.avcodec_parameters_to_context(self.codec, stream.*.codecpar) < 0)
            return error.OpenCodecFailed;
        if (c.ffmpeg.avcodec_open2(self.codec, codec, null) < 0)
            return error.OpenCodecFailed;
        self.codec_opened = true;

        var out_layout: c.ffmpeg.AVChannelLayout = undefined;
        c.ffmpeg.av_channel_layout_default(&out_layout, 1);
        if (c.ffmpeg.swr_alloc_set_opts2(
            @ptrCast(&self.resampler),
            &out_layout,
            c.ffmpeg.AV_SAMPLE_FMT_FLT,
            sample_rate,
            &self.codec.?.ch_layout,
            self.codec.?.sample_fmt,
            self.codec.?.sample_rate,
            0,
            null,
        ) < 0) return error.ResampleSetupFailed;
        self.resampler_allocated = true;
        if (c.ffmpeg.swr_init(self.resampler) < 0) return error.ResampleSetupFailed;

        self.frame = c.ffmpeg.av_frame_alloc() orelse return error.OutOfMemory;
        self.packet = c.ffmpeg.av_packet_alloc() orelse return error.OutOfMemory;
        self.frames_allocated = true;
        return .{
            .allocator = self.allocator,
            .format = self.format,
            .codec = self.codec,
            .resampler = self.resampler,
            .frame = self.frame,
            .packet = self.packet,
            .audio_stream = self.audio_stream,
            .format_opened = true,
            .codec_allocated = true,
            .codec_opened = true,
            .resampler_allocated = true,
            .frames_allocated = true,
            .pending = self.pending,
            .scratch = self.scratch,
        };
    }

    /// Returns the next slice of mono 16 kHz PCM, up to one second long.
    /// The slice is owned by the decoder and stays valid until the next
    /// call to `next` or `deinit`. Returns null once the media is drained.
    pub fn next(self: *Decoder) Error!?[]const f32 {
        while (true) {
            if (self.takePending()) |slice| return slice;
            if (self.input_closed) {
                if (!self.decode_flushed) {
                    const recv = c.ffmpeg.avcodec_receive_frame(self.codec, self.frame);
                    if (recv == 0) {
                        defer c.ffmpeg.av_frame_unref(self.frame);
                        try self.convertFrame();
                        continue;
                    }
                    self.decode_flushed = true;
                }
                if (!self.resample_flushed) {
                    try self.convert(null);
                    self.resample_flushed = true;
                    continue;
                }
                return null;
            }
            try self.produceMore();
        }
    }

    pub fn deinit(self: *Decoder) void {
        self.freeAll();
        self.pending.deinit(self.allocator);
        self.allocator.free(self.scratch);
    }

    /// libav error text for the most recent failure, if any.
    pub fn errorMessage(self: *const Decoder) ?[]const u8 {
        if (self.last_error_len == 0) return null;
        return self.last_error[0..self.last_error_len];
    }

    fn freeAll(self: *Decoder) void {
        if (self.frames_allocated) {
            c.ffmpeg.av_packet_free(@ptrCast(&self.packet));
            c.ffmpeg.av_frame_free(@ptrCast(&self.frame));
            self.frames_allocated = false;
        }
        if (self.resampler_allocated) {
            c.ffmpeg.swr_free(@ptrCast(&self.resampler));
            self.resampler_allocated = false;
        }
        if (self.codec_allocated) {
            c.ffmpeg.avcodec_free_context(@ptrCast(&self.codec));
            self.codec_allocated = false;
        }
        if (self.format_opened) {
            c.ffmpeg.avformat_close_input(@ptrCast(&self.format));
            self.format_opened = false;
        }
    }

    fn recordError(self: *Decoder, errnum: c_int) void {
        self.last_error_len = 0;
        if (c.ffmpeg.av_strerror(errnum, &self.last_error, self.last_error.len) == 0) {
            self.last_error_len = std.mem.indexOfScalar(u8, &self.last_error, 0) orelse self.last_error.len;
        }
    }

    fn takePending(self: *Decoder) ?[]const f32 {
        // Reclaim the buffer only when every previous slice is dead: the
        // caller consumes each slice before calling next() again, so this
        // runs before a new slice is handed out. `items.len = 0` avoids
        // clearRetainingCapacity, which poisons the buffer in Debug and
        // would corrupt a still-live slice handed out earlier.
        if (self.consumed == self.pending.items.len and self.consumed > 0) {
            self.pending.items.len = 0;
            self.consumed = 0;
        }
        const available = self.pending.items.len - self.consumed;
        if (available == 0) return null;
        const take = @min(available, @as(usize, @intCast(sample_rate)));
        const slice = self.pending.items[self.consumed..][0..take];
        self.consumed += take;
        return slice;
    }

    /// Pull one more chunk of PCM out of the decoder pipeline.
    fn produceMore(self: *Decoder) Error!void {
        const recv = c.ffmpeg.avcodec_receive_frame(self.codec, self.frame);
        if (recv == 0) {
            defer c.ffmpeg.av_frame_unref(self.frame);
            try self.convertFrame();
            return;
        }
        if (recv != AVERROR_EAGAIN) {
            self.recordError(recv);
            return error.ReadFailed;
        }
        // The codec wants more input: feed it the next packet of its stream.
        while (true) {
            const read = c.ffmpeg.av_read_frame(self.format, self.packet);
            if (read == AVERROR_EOF) {
                self.input_closed = true;
                const sent = c.ffmpeg.avcodec_send_packet(self.codec, null);
                if (sent < 0 and sent != AVERROR_EOF) {
                    self.recordError(sent);
                    return error.ReadFailed;
                }
                return;
            }
            if (read < 0) {
                self.recordError(read);
                return error.ReadFailed;
            }
            defer c.ffmpeg.av_packet_unref(self.packet);
            if (self.packet.?.stream_index != self.audio_stream) continue;
            const sent = c.ffmpeg.avcodec_send_packet(self.codec, self.packet);
            if (sent < 0) {
                // EAGAIN here cannot make progress past the failed receive
                // above, so any negative return is a hard failure.
                self.recordError(sent);
                return error.ReadFailed;
            }
            return;
        }
    }

    fn convertFrame(self: *Decoder) Error!void {
        const frame = self.frame.?;
        if (frame.nb_samples == 0) return;
        try self.convert(self.frame);
    }

    /// Resample one decoded frame (or, with null, drain the resampler
    /// buffer) into `pending` as interleaved mono f32.
    fn convert(self: *Decoder, frame: ?*const c.ffmpeg.AVFrame) Error!void {
        const in_count: c_int = if (frame) |f| f.nb_samples else 0;
        var fed = false;
        while (true) {
            const want = c.ffmpeg.swr_get_out_samples(
                self.resampler,
                if (fed) 0 else in_count,
            );
            if (want <= 0) return;
            try self.ensureScratch(@intCast(want));
            var out_ptr: [*c]u8 = @ptrCast(self.scratch.ptr);
            const in_data: [*c]const [*c]const u8 = if (fed or frame == null)
                null
            else
                @ptrCast(@constCast(frame.?.extended_data));
            const got = c.ffmpeg.swr_convert(
                self.resampler,
                @ptrCast(&out_ptr),
                want,
                in_data,
                if (fed) 0 else in_count,
            );
            if (got < 0) {
                self.recordError(got);
                return error.ConvertFailed;
            }
            self.pending.appendSlice(self.allocator, self.scratch[0..@intCast(got)]) catch
                return error.OutOfMemory;
            if (got < want) return;
            fed = true;
        }
    }

    fn ensureScratch(self: *Decoder, want: usize) Error!void {
        if (self.scratch.len >= want) return;
        const grown = self.allocator.alloc(f32, want) catch return error.OutOfMemory;
        self.allocator.free(self.scratch);
        self.scratch = grown;
    }
};

test "swr converts s16 to f32 in isolation" {
    const in_raw = [_]i16{ 0, 4439, 8354, 11281, 12791, 12791, 11281, 8354 };
    var out_buf: [64]f32 = undefined;
    var out_ptr: [*c]u8 = @ptrCast(&out_buf);
    var out_layout: c.ffmpeg.AVChannelLayout = undefined;
    c.ffmpeg.av_channel_layout_default(&out_layout, 1);
    var in_layout: c.ffmpeg.AVChannelLayout = undefined;
    c.ffmpeg.av_channel_layout_default(&in_layout, 1);
    var swr: ?*c.ffmpeg.SwrContext = null;
    try std.testing.expectEqual(0, c.ffmpeg.swr_alloc_set_opts2(
        @ptrCast(&swr),
        &out_layout,
        c.ffmpeg.AV_SAMPLE_FMT_FLT,
        16000,
        &in_layout,
        c.ffmpeg.AV_SAMPLE_FMT_S16,
        16000,
        0,
        null,
    ));
    try std.testing.expect(c.ffmpeg.swr_init(swr) >= 0);
    var in_ptr: [*c]const u8 = @ptrCast(&in_raw);
    const got = c.ffmpeg.swr_convert(swr, @ptrCast(&out_ptr), 64, @ptrCast(&in_ptr), in_raw.len);
    std.debug.print("isolated swr got={d} out={any}\n", .{ got, out_buf[0..@intCast(got)] });
    try std.testing.expect(got == in_raw.len);
    try std.testing.expect(@abs(out_buf[1]) > 0.1);
}

test "decoder resamples a synthetic wav to 16 kHz mono" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // A 0.5 s 8 kHz sine wav must resample to 0.5 s of 16 kHz mono f32.
    const in_rate: u32 = 8000;
    const in_samples: usize = @as(usize, in_rate) / 2;
    var wav = std.ArrayList(u8).empty;
    defer wav.deinit(allocator);
    var header: [44]u8 = @splat(0);
    const data_len: u32 = @intCast(in_samples * 2);
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_len, .little);
    @memcpy(header[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], 1, .little);
    std.mem.writeInt(u32, header[24..28], in_rate, .little);
    std.mem.writeInt(u32, header[28..32], in_rate * 2, .little);
    std.mem.writeInt(u16, header[32..34], 2, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_len, .little);
    try wav.appendSlice(allocator, &header);
    var i: usize = 0;
    while (i < in_samples) : (i += 1) {
        const t: f64 = @floatFromInt(i);
        const v: f64 = 0.4 * @sin(t * 2.0 * std.math.pi * 440.0 / 8000.0);
        const s16: i16 = @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 32767.0);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, s16, .little);
        try wav.appendSlice(allocator, &bytes);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sine.wav", .data = wav.items });

    const path = try tmp.dir.realPathFileAlloc(io, "sine.wav", allocator);
    defer allocator.free(path);

    var decoder = try Decoder.open(allocator, path);
    defer decoder.deinit();

    var total: usize = 0;
    var energy: f32 = 0;
    while (try decoder.next()) |chunk| {
        for (chunk) |s| {
            try std.testing.expect(s >= -1.0 and s <= 1.0);
            energy += @abs(s);
        }
        total += chunk.len;
        if (total <= chunk.len) {
            std.debug.print("first chunk first samples: {any}\n", .{chunk[0..@min(4, chunk.len)]});
        }
    }
    std.debug.print("total={d} energy={d:.2}\n", .{ total, energy });
    try std.testing.expect(energy > 100); // decoded audio must not be silence
    // Resampling 0.5 s from 8 kHz to 16 kHz yields 0.5 s at 16 kHz,
    // with a few samples of tolerance for filter tails.
    try std.testing.expect(total >= 7900 and total <= 8100);
}
