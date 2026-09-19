//! Central catalog of ASR model presets.
//!
//! Each preset maps a short user-facing name to an upstream sherpa-onnx
//! model archive under the `asr-models` release tag
//! (https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models).
//!
//! `family` selects the sherpa-onnx config structure the native wrapper
//! fills in for this model (see src/sherpa.zig). `mode` records whether
//! that family decodes incrementally (streaming) or per utterance
//! (offline); the transcribe pipeline uses it to pick the feeding
//! strategy: streaming models run one pass over the whole file, offline
//! models decode VRAM-sized slices through a single recognizer.

const std = @import("std");

pub const Mode = enum {
    streaming,
    offline,
};

pub const Family = enum {
    online_transducer,
    online_paraformer,
    online_zipformer2_ctc,
    offline_transducer,
    offline_nemo_ctc,
};

pub const Preset = struct {
    name: []const u8,
    upstream_name: []const u8,
    description: []const u8,
    mode: Mode,
    family: Family,
    /// SHA-256 of the upstream .tar.bz2 archive, lowercase hex (64 chars).
    sha256: []const u8,
};

pub const presets = [_]Preset{
    .{
        .name = "zipformer",
        .upstream_name = "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
        .description = "streaming Chinese/English transducer",
        .mode = .streaming,
        .family = .online_transducer,
        .sha256 = "27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8",
    },
    .{
        .name = "paraformer",
        .upstream_name = "sherpa-onnx-streaming-paraformer-bilingual-zh-en",
        .description = "streaming Chinese/English Paraformer",
        .mode = .streaming,
        .family = .online_paraformer,
        .sha256 = "5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f",
    },
    .{
        .name = "zipformer-ctc",
        .upstream_name = "sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30",
        .description = "streaming Chinese Zipformer CTC (large)",
        .mode = .streaming,
        .family = .online_zipformer2_ctc,
        .sha256 = "23f32059d502e87f4fe4b1a17dbedb65582bb0c42950b3d615f218bb25feafd5",
    },
    .{
        .name = "nemo",
        .upstream_name = "sherpa-onnx-nemo-ctc-en-conformer-small",
        .description = "offline English NeMo CTC",
        .mode = .offline,
        .family = .offline_nemo_ctc,
        .sha256 = "83dcb462aece5bef4e8072c267419389f0b8d1f91152d8851765f284ff664caa",
    },
    .{
        .name = "japanese",
        .upstream_name = "sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17",
        .description = "offline Japanese/English ReazonSpeech transducer",
        .mode = .offline,
        .family = .offline_transducer,
        .sha256 = "dc03758608c0280e2cbcaac4597467ffcf846ae0b06436f1706738a11da86f5d",
    },
    .{
        .name = "korean",
        .upstream_name = "sherpa-onnx-streaming-zipformer-korean-2024-06-16",
        .description = "streaming Korean transducer",
        .mode = .streaming,
        .family = .online_transducer,
        .sha256 = "e346a5882a409650472be17326237e24df7bf409db6b4a8a52e1a61422bf2500",
    },
    .{
        .name = "vietnamese",
        .upstream_name = "sherpa-onnx-zipformer-vi-2025-04-20",
        .description = "offline Vietnamese transducer",
        .mode = .offline,
        .family = .offline_transducer,
        .sha256 = "501b2f6e12d5871ff35dc356cf41bb3197f7e32fb7480db744d603bc99a9ad02",
    },
    .{
        .name = "multilingual",
        .upstream_name = "sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10",
        .description = "streaming multilingual transducer (ar/en/id/ja/ru/th/vi/zh)",
        .mode = .streaming,
        .family = .online_transducer,
        .sha256 = "28044b67324f7f831689f0a3761473dd2ade380e93aa53f1dbcd479ef71c40d4",
    },
};

/// The punctuation model applied to every transcript; lives under the
/// `punctuation-models` release tag.
pub const punctuation = struct {
    pub const upstream_name = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8";
    pub const url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/" ++ upstream_name ++ ".tar.bz2";
    pub const sha256: []const u8 = "c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1";
};

/// Find a preset by short name or by its full upstream directory name.
pub fn find(name: []const u8) ?*const Preset {
    for (&presets) |*preset| {
        if (std.mem.eql(u8, name, preset.name) or std.mem.eql(u8, name, preset.upstream_name)) return preset;
    }
    return null;
}

/// Archive URL for a preset under the pinned `asr-models` release tag.
pub fn archiveUrl(preset: *const Preset) []const u8 {
    _ = preset;
    return archive_url_base;
}

pub const archive_url_base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models";

test "catalog: every preset is fully specified" {
    for (&presets) |*preset| {
        try std.testing.expect(preset.name.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, preset.upstream_name, "sherpa-onnx-"));
        try std.testing.expect(preset.sha256.len == 64);
        for (preset.sha256) |ch| try std.testing.expect(std.ascii.isHex(ch));
    }
}

test "catalog: find resolves short names and upstream names" {
    try std.testing.expect(find("korean") != null);
    try std.testing.expect(find("sherpa-onnx-zipformer-vi-2025-04-20") != null);
    try std.testing.expect(find("no-such-model") == null);
}
