const std = @import("std");
const c = @import("c.zig");
const build_options = @import("build_options");

const Catalog = struct {
    /// The upstream release tag holding all supported ASR archives.
    pub const release_tag = "asr-models";
    pub const release_api = "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/asr-models";
    pub const max_archive_bytes: u64 = 1024 * 1024 * 1024;

    const Preset = struct {
        name: []const u8,
        upstream_name: []const u8,
        description: []const u8,
    };

    pub const presets = [_]Preset{
        .{ .name = "zipformer", .upstream_name = "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20", .description = "streaming Chinese/English transducer" },
        .{ .name = "paraformer", .upstream_name = "sherpa-onnx-streaming-paraformer-bilingual-zh-en", .description = "streaming Chinese/English Paraformer" },
        .{ .name = "zipformer-ctc", .upstream_name = "sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30", .description = "streaming Chinese Zipformer CTC (large)" },
        .{ .name = "nemo", .upstream_name = "sherpa-onnx-nemo-ctc-en-conformer-small", .description = "offline English NeMo CTC" },
    };

    fn isSupportedArchive(name: []const u8, size: u64) bool {
        return size <= max_archive_bytes and std.mem.endsWith(u8, name, ".tar.bz2") and
            (std.mem.startsWith(u8, name, "sherpa-onnx-") or std.mem.startsWith(u8, name, "icefall-asr-"));
    }
};

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
        \\
    );
}

fn presetName(name: []const u8) ?[]const u8 {
    for (Catalog.presets) |preset| {
        if (std.mem.eql(u8, name, preset.name) or std.mem.eql(u8, name, preset.upstream_name)) return preset.name;
    }
    return null;
}

const runtime_script =
    \\set -eu
    \\action="$1"; shift
    \\data="$1"; shift
    \\cpu_runtime="sherpa-onnx-v1.13.5-linux-x64-shared-no-tts"
    \\gpu_runtime="sherpa-onnx-v1.13.5-cuda-13.x-cudnn-9.x-onnxruntime1.27.1-linux-x64-gpu"
    \\provider="cpu"
    \\cudnn_lib="$data/cudnn/lib"
    \\if [ ! -f "$cudnn_lib/libcudnn.so.9" ] && [ -x "$data/cuda-env/bin/python" ]; then
    \\  cudnn_lib="$("$data/cuda-env/bin/python" -c 'import nvidia.cudnn, os; print(os.path.join(os.path.dirname(nvidia.cudnn.__file__), "lib"))' 2>/dev/null || true)"
    \\fi
    \\if [ -f "$cudnn_lib/libcudnn.so.9" ] && nvidia-smi >/dev/null 2>&1; then
    \\  runtime_name="$gpu_runtime"; provider="cuda"
    \\else
    \\  runtime_name="$cpu_runtime"
    \\fi
    \\runtime="$data/runtime/$runtime_name"
    \\runtime_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/$runtime_name.tar.bz2"
    \\cuda_lib=""
    \\if [ -d /usr/local/cuda/targets/x86_64-linux/lib ]; then cuda_lib=":/usr/local/cuda/targets/x86_64-linux/lib"; fi
    \\model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    \\punctuation_name="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
    \\punctuation_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/$punctuation_name.tar.bz2"
    \\mkdir -p "$data/models" "$data/cache" "$data/transcripts" "$data/runtime"
    \\upstream_name() {
    \\  case "$1" in
    \\    zipformer) echo "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20" ;;
    \\    paraformer) echo "sherpa-onnx-streaming-paraformer-bilingual-zh-en" ;;
    \\    zipformer-ctc) echo "sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30" ;;
    \\    nemo) echo "sherpa-onnx-nemo-ctc-en-conformer-small" ;;
    \\    *) return 1 ;;
    \\  esac
    \\}
    \\install_runtime() {
    \\  if [ -x "$runtime/bin/sherpa-onnx" ]; then return; fi
    \\  archive="$data/cache/$runtime_name.tar.bz2"
    \\  curl -L --fail --retry 3 -C - -o "$archive" "$runtime_url"
    \\  tar -xjf "$archive" -C "$data/runtime"
    \\}
    \\install_model() {
    \\  model="$(upstream_name "$1")"
    \\  if [ -f "$data/models/$model/tokens.txt" ]; then echo "Model already installed: $model"; return; fi
    \\  archive="$data/cache/$model.tar.bz2"
    \\  curl -L --fail --retry 3 -C - -o "$archive" "$model_url/$model.tar.bz2"
    \\  tar -xjf "$archive" -C "$data/models"
    \\  test -f "$data/models/$model/tokens.txt"
    \\}
    \\install_punctuation() {
    \\  punctuation_dir="$data/models/$punctuation_name"
    \\  if [ -f "$punctuation_dir/model.int8.onnx" ]; then return; fi
    \\  archive="$data/cache/$punctuation_name.tar.bz2"
    \\  curl -L --fail --retry 3 -C - -o "$archive" "$punctuation_url"
    \\  tar -xjf "$archive" -C "$data/models"
    \\  test -f "$punctuation_dir/model.int8.onnx"
    \\}
    \\case "$action" in
    \\  install)
    \\    install_runtime
    \\    install_model "$1"
    \\    echo "Installed: $1 ($(upstream_name "$1"))"
    \\    ;;
    \\  list)
    \\    default="$(cat "$data/default-model" 2>/dev/null || true)"
    \\    case "$default" in
    \\      sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20) default=zipformer ;;
    \\      sherpa-onnx-streaming-paraformer-bilingual-zh-en) default=paraformer ;;
    \\      sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30) default=zipformer-ctc ;;
    \\      sherpa-onnx-nemo-ctc-en-conformer-small) default=nemo ;;
    \\    esac
    \\    for model in zipformer paraformer zipformer-ctc nemo; do
    \\      upstream="$(upstream_name "$model")"; status="installable"; marker=""
    \\      if [ -f "$data/models/$upstream/tokens.txt" ]; then status="installed"; fi
    \\      if [ "$model" = "$default" ]; then marker="default"; fi
    \\      printf '  %-15s %-11s %-7s %s\n' "$model" "$status" "$marker" "$upstream"
    \\    done
    \\    ;;
    \\  doctor)
    \\    echo "GPU acceleration probe"
    \\    if nvidia-smi --query-gpu=name,driver_version --format=csv,noheader >/dev/null 2>&1; then
    \\      nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    \\      if [ -f "$cudnn_lib/libcudnn.so.9" ] && ldconfig -p | grep -q 'libcublasLt.so.13'; then
    \\        echo "CUDA 13 and cuDNN 9 runtime libraries detected; lszl will select provider=cuda."
    \\      else
    \\        echo "CUDA device detected, but lszl's managed cuDNN 9 runtime is missing; GPU inference cannot start yet."
    \\      fi
    \\    else
    \\      echo "CUDA unavailable (nvidia-smi cannot contact a driver)."
    \\    fi
    \\    if rocm-smi --showproductname >/dev/null 2>&1; then
    \\      echo "ROCm device detected, but the upstream Linux release used by lszl is CPU/CUDA only."
    \\    else
    \\      echo "ROCm unavailable."
    \\    fi
    \\    ;;
    \\  transcribe)
    \\    model="$1"; input="$2"; upstream="$(upstream_name "$model")"
    \\    install_runtime; install_punctuation
    \\    test -f "$data/models/$upstream/tokens.txt" || { echo "Model is not installed: $model. Run: lszl model install $model" >&2; exit 2; }
    \\    command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 2; }
    \\    command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
    \\    work="$data/cache/run-$$"; mkdir -p "$work"
    \\    cleanup() { status=$?; if [ "$status" -eq 0 ]; then rm -rf "$work"; else echo "Work files retained after failure: $work" >&2; fi; }
    \\    trap cleanup EXIT
    \\    model_dir="$data/models/$upstream"; raw="$work/raw.txt"; diagnostics="$work/backend.log"
    \\    : >"$raw"; : >"$diagnostics"
    \\    if [ "$model" = nemo ]; then
    \\      ffmpeg -nostdin -y -i "$input" -ac 1 -ar 16000 -c:a pcm_s16le -f segment -segment_time 60 "$work/chunk-%04d.wav" >/dev/null 2>&1
    \\      for wav in "$work"/chunk-*.wav; do
    \\        result="$work/result.json"
    \\        LD_LIBRARY_PATH="$runtime/lib:$cudnn_lib$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$runtime/bin/sherpa-onnx-offline" --provider="$provider" --num-threads=1 --tokens="$model_dir/tokens.txt" --nemo-ctc-model="$model_dir/model.int8.onnx" "$wav" >"$result" 2>>"$diagnostics"
    \\        jq -r '.text' "$result" >>"$raw"
    \\      done
    \\    else
    \\      wav="$work/input.wav"; result="$work/result.txt"
    \\      ffmpeg -nostdin -y -i "$input" -ac 1 -ar 16000 -c:a pcm_s16le "$wav" >/dev/null 2>&1
    \\      case "$model" in
    \\        zipformer) LD_LIBRARY_PATH="$runtime/lib:$cudnn_lib$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$runtime/bin/sherpa-onnx" --provider="$provider" --num-threads=1 --tokens="$model_dir/tokens.txt" --encoder="$model_dir/encoder-epoch-99-avg-1.int8.onnx" --decoder="$model_dir/decoder-epoch-99-avg-1.int8.onnx" --joiner="$model_dir/joiner-epoch-99-avg-1.int8.onnx" "$wav" >"$result" 2>>"$diagnostics" ;;
    \\        paraformer) LD_LIBRARY_PATH="$runtime/lib:$cudnn_lib$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$runtime/bin/sherpa-onnx" --provider="$provider" --num-threads=1 --tokens="$model_dir/tokens.txt" --paraformer-encoder="$model_dir/encoder.int8.onnx" --paraformer-decoder="$model_dir/decoder.int8.onnx" "$wav" >"$result" 2>>"$diagnostics" ;;
    \\        zipformer-ctc) LD_LIBRARY_PATH="$runtime/lib:$cudnn_lib$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$runtime/bin/sherpa-onnx" --provider="$provider" --num-threads=1 --tokens="$model_dir/tokens.txt" --zipformer2-ctc-model="$model_dir/model.int8.onnx" "$wav" >"$result" 2>>"$diagnostics" ;;
    \\      esac
    \\      awk '/^\{ "text": / { print previous; exit } { previous=$0 }' "$diagnostics" >"$raw"
    \\      test -s "$raw" || { echo "Recognizer returned no transcript text" >&2; exit 3; }
    \\    fi
    \\    stem="$(basename "$input")"; output="$data/transcripts/$model/$stem.txt"; mkdir -p "$(dirname "$output")"
    \\    temporary="$output.tmp-$$"; : >"$temporary"
    \\    punctuation_model="$data/models/$punctuation_name/model.int8.onnx"
    \\    while IFS= read -r text; do
    \\      [ -z "$text" ] && continue
    \\      LD_LIBRARY_PATH="$runtime/lib:$cudnn_lib$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$runtime/bin/sherpa-onnx-offline-punctuation" --provider="$provider" --num-threads=1 --ct-transformer="$punctuation_model" "$text" >>"$temporary" 2>>"$diagnostics"
    \\    done <"$raw"
    \\    mv "$temporary" "$output"; cp "$diagnostics" "$output.log"
    \\    echo "Model: $model ($provider)"
    \\    echo "Transcript: $output"
    \\    echo "Diagnostics: $output.log"
    \\    ;;
    \\esac
;

fn runRuntime(init: std.process.Init, action: []const u8, model: ?[]const u8, input: ?[]const u8, stdout: *std.Io.Writer) !void {
    const data = try dataDirectory(init.gpa);
    defer init.gpa.free(data);
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(init.gpa);
    try args.append(init.gpa, "bash");
    try args.append(init.gpa, "-ceu");
    try args.append(init.gpa, runtime_script);
    try args.append(init.gpa, "lszl-runtime");
    try args.append(init.gpa, action);
    try args.append(init.gpa, data);
    if (model) |value| try args.append(init.gpa, value);
    if (input) |value| try args.append(init.gpa, value);
    const result = try std.process.run(init.gpa, init.io, .{ .argv = args.items, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try stdout.writeAll(result.stdout);
    try stdout.writeAll(result.stderr);
    try stdout.flush();
    switch (result.term) {
        .exited => |code| if (code != 0) return error.RuntimeFailed,
        else => return error.RuntimeFailed,
    }
}

fn printModelList(writer: *std.Io.Writer) !void {
    try writer.writeAll("Models (name, status, upstream archive):\n");
}

fn autoExecutionProvider() []const u8 {
    // The first native sherpa integration will probe CUDA/ROCm provider
    // libraries from the selected prebuilt bundle. CPU is always safe.
    if (std.c.getenv("CUDA_VISIBLE_DEVICES") != null) return "cuda";
    if (std.c.getenv("ROCR_VISIBLE_DEVICES") != null) return "rocm";
    return "cpu";
}

fn modelNameIsValid(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, "/\\\n\r") == null;
}

/// Returns the directory for data owned by lszl itself, such as installed
/// models and the selected default. User-provided audio is never copied here.
///
/// The portable distribution sets LSZL_DATA_HOME to the bundle's `data/`
/// directory (used as-is, not a base), so the whole bundle — runtime, models,
/// transcripts — stays self-contained and no system packages are required.
fn dataDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("LSZL_DATA_HOME")) |value| return allocator.dupe(u8, std.mem.span(value));
    const base = if (std.c.getenv("XDG_DATA_HOME")) |value|
        std.mem.span(value)
    else if (std.c.getenv("HOME")) |value|
        try std.fmt.allocPrint(allocator, "{s}/.local/share", .{std.mem.span(value)})
    else
        return error.HomeNotFound;
    defer if (std.c.getenv("XDG_DATA_HOME") == null) allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/lszl", .{base});
}

fn saveDefaultModel(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    if (!modelNameIsValid(name)) return error.InvalidModelName;
    const directory = try dataDirectory(allocator);
    defer allocator.free(directory);
    try std.Io.Dir.createDirPath(.cwd(), io, directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/default-model", .{directory});
    defer allocator.free(path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = name });
}

fn loadDefaultModel(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const directory = try dataDirectory(allocator);
    defer allocator.free(directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/default-model", .{directory});
    defer allocator.free(path);
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(4096));
}

pub fn main(init: std.process.Init) !void {
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const command = parseArgs(raw_args[1..]) catch |err| {
        std.debug.print("lszl: {s}\n", .{@errorName(err)});
        try printUsage(stdout);
        try stdout.flush();
        return;
    };

    switch (command) {
        .help => try printUsage(stdout),
        .doctor => try runRuntime(init, "doctor", null, null, stdout),
        .model_list => {
            try printModelList(stdout);
            try stdout.flush();
            try runRuntime(init, "list", null, null, stdout);
        },
        .model_default => |name| {
            if (name) |model_name| {
                const selected = presetName(model_name) orelse return error.UnsupportedModel;
                try saveDefaultModel(init.io, init.gpa, selected);
                try stdout.print("Default model set to {s}.\n", .{selected});
            } else {
                const default_name = loadDefaultModel(init.io, init.gpa) catch |err| {
                    if (err == error.FileNotFound) {
                        try stdout.writeAll("No default model configured.\n");
                        try stdout.flush();
                        return;
                    }
                    return err;
                };
                defer init.gpa.free(default_name);
                try stdout.print("Default model: {s}\n", .{presetName(default_name) orelse default_name});
            }
        },
        .model_install => |name| {
            if (presetName(name)) |selected| {
                try runRuntime(init, "install", selected, null, stdout);
            } else {
                try stdout.print("Unsupported model name: {s}\n", .{name});
            }
        },
        .transcribe => |request| {
            const configured = request.model_name orelse try loadDefaultModel(init.io, init.gpa);
            defer if (request.model_name == null) init.gpa.free(configured);
            const selected = presetName(configured) orelse return error.UnsupportedModel;
            try runRuntime(init, "transcribe", selected, request.input, stdout);
        },
    }
    try stdout.flush();
}

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
    try std.testing.expectEqualStrings("paraformer", presetName("paraformer").?);
    try std.testing.expectEqualStrings("paraformer", presetName("sherpa-onnx-streaming-paraformer-bilingual-zh-en").?);
    try std.testing.expect(presetName("unknown") == null);
}

test "catalog excludes non archives and files over one gibibyte" {
    try std.testing.expect(Catalog.isSupportedArchive("sherpa-onnx-whisper-small.tar.bz2", Catalog.max_archive_bytes));
    try std.testing.expect(!Catalog.isSupportedArchive("model.onnx", 1));
    try std.testing.expect(!Catalog.isSupportedArchive("sherpa-onnx-too-large.tar.bz2", Catalog.max_archive_bytes + 1));
}

test "native API headers are available" {
    // Portable builds deliberately skip the system FFmpeg/sherpa-onnx
    // linkage, so the native headers are not present at compile time.
    if (build_options.portable) return error.SkipZigTest;
    _ = c.ffmpeg.AV_NOPTS_VALUE;
    _ = c.sherpa.SherpaOnnxGetVersionStr;
}
