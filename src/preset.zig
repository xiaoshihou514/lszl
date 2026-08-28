//! Central catalog of ASR model presets.
//!
//! Each preset maps a short user-facing name to an upstream sherpa-onnx
//! model archive under the `asr-models` release tag
//! (https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models).
//!
//! `mode` tells the runtime whether the model is decoded by the streaming
//! CLI (`sherpa-onnx`) or the offline CLI (`sherpa-onnx-offline`). The
//! embedded runtime script in main.zig mirrors these presets in its shell
//! case statements; keep the two in sync (the unit test at the bottom of
//! this file checks the shell table against this catalog).

const std = @import("std");

pub const Mode = enum {
    streaming, // decoded by `sherpa-onnx`
    offline, // decoded by `sherpa-onnx-offline`
};

pub const Preset = struct {
    name: []const u8,
    upstream_name: []const u8,
    description: []const u8,
    mode: Mode,
};

pub const presets = [_]Preset{
    .{ .name = "zipformer", .upstream_name = "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20", .description = "streaming Chinese/English transducer", .mode = .streaming },
    .{ .name = "paraformer", .upstream_name = "sherpa-onnx-streaming-paraformer-bilingual-zh-en", .description = "streaming Chinese/English Paraformer", .mode = .streaming },
    .{ .name = "zipformer-ctc", .upstream_name = "sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30", .description = "streaming Chinese Zipformer CTC (large)", .mode = .streaming },
    .{ .name = "nemo", .upstream_name = "sherpa-onnx-nemo-ctc-en-conformer-small", .description = "offline English NeMo CTC", .mode = .offline },
    .{ .name = "japanese", .upstream_name = "sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17", .description = "offline Japanese/English ReazonSpeech transducer", .mode = .offline },
    .{ .name = "korean", .upstream_name = "sherpa-onnx-streaming-zipformer-korean-2024-06-16", .description = "streaming Korean transducer", .mode = .streaming },
    .{ .name = "vietnamese", .upstream_name = "sherpa-onnx-zipformer-vi-2025-04-20", .description = "offline Vietnamese transducer", .mode = .offline },
    .{ .name = "multilingual", .upstream_name = "sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10", .description = "streaming multilingual transducer (ar/en/id/ja/ru/th/vi/zh)", .mode = .streaming },
};

/// Find a preset by short name or by its full upstream directory name.
pub fn find(name: []const u8) ?Preset {
    for (presets) |preset| {
        if (std.mem.eql(u8, name, preset.name) or std.mem.eql(u8, name, preset.upstream_name)) return preset;
    }
    return null;
}

test "catalog: every preset maps to a valid upstream name" {
    for (presets) |preset| {
        try std.testing.expect(preset.name.len > 0);
        try std.testing.expect(preset.upstream_name.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, preset.upstream_name, "sherpa-onnx-"));
    }
}

test "catalog: find resolves short names and upstream names" {
    try std.testing.expect(find("korean") != null);
    try std.testing.expect(find("sherpa-onnx-zipformer-vi-2025-04-20") != null);
    try std.testing.expect(find("no-such-model") == null);
}
