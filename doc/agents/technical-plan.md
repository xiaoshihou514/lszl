# lszl technical plan

## Purpose and boundaries

`lszl` is a Linux-only command-line program for offline audio transcription. It accepts an audio or video file, decodes its primary audio stream through the FFmpeg libraries installed on the host, resamples it into the format required by sherpa-onnx, and emits a transcript. The initial scope is local, non-streaming ASR; it does not record from a microphone, host a network service, or bundle models in the executable.

The implementation language is Zig. Inference is delegated exclusively to the upstream `libsherpa-onnx-c-api` prebuilt library and its supported C API. Media container and codec support is delegated exclusively to the host's FFmpeg shared libraries. No subprocess invocation of the `ffmpeg` executable is required.

## Supported platform and prerequisites

Target only Linux x86_64 for the first release. Fail configuration at compile time for other targets. Keep the layout ready to add Linux aarch64 later, but do not claim it is supported until a matching sherpa-onnx artifact and CI job exist.

Build and runtime prerequisites:

- Zig 0.16.x, recorded in `build.zig.zon`.
- Development files for system FFmpeg: `libavformat`, `libavcodec`, `libavutil`, and `libswresample` (headers plus shared libraries), found via `pkg-config`.
- A user-supplied or tool-managed, version-pinned prebuilt sherpa-onnx C API distribution for the selected Linux architecture.
- A locally available ASR model bundle, including its `tokens.txt` and all model files required by that model family.

Do not add Xmake, a Python runtime, ONNX Runtime packages, or FFmpeg source builds as project dependencies. The selected prebuilt sherpa artifact owns its ONNX Runtime dependency graph; the Linux dynamic loader resolves it from the installed sherpa library directory.

## User-facing interface

Start with two command families:

```text
lszl transcribe [options] <media-file>
lszl model <install|list|verify|remove|default> [options]
```

`transcribe` options in the first milestone:

- `--model <name>`: installed model name, never a filesystem path. Otherwise use the configured named default.
- `--format <text|json|srt|vtt>`: output encoding; default `text`.
- `--output <path>`: atomically write results to a file; otherwise write to stdout.
- `--language <tag>` and `--task <transcribe|translate>` when the chosen model family supports them.
- `--timestamps <none|segment>`: control timestamp-bearing outputs.

Use distinct exit codes for command-line misuse, unavailable dependencies, invalid media, decoding failure, model acquisition/validation failure, and inference failure. Human-readable diagnostics go to stderr; machine-readable transcripts never share stdout with logs.

## Repository layout

Create the following structure during implementation:

```text
build.zig                 Zig build graph and dependency discovery
build.zig.zon             package metadata and Zig version requirement
src/main.zig              process setup, dispatch, exit-code conversion
src/cli.zig               option parsing and command validation
src/config.zig            XDG paths and persistent configuration
src/model_store.zig       manifests, installation, verification, selection
src/download.zig          resumable downloads, checksum and archive handling
src/ffmpeg.zig            narrow FFmpeg C binding declarations and decoder
src/sherpa.zig            ownership-safe sherpa-onnx C API wrapper
src/transcribe.zig        pipeline orchestration and transcript assembly
src/render.zig            text, JSON, SRT, and WebVTT serializers
src/error.zig             project error sets and diagnostic context
src/c.zig                 @cImport boundary, if used for generated bindings
tests/                    unit, integration, and fixture metadata
doc/agents/               maintained implementation plans and decision records
```

Keep C imports isolated. Application code should consume Zig types rather than raw FFmpeg or sherpa pointers.

## Build and native-library integration

`build.zig` must reject non-Linux targets before dependency discovery. It must:

1. Use `pkg-config` to obtain FFmpeg compile and link flags. Do not hard-code `/usr/include`, `/usr/lib`, package versions, or library filenames.
2. Accept `-Dsherpa_prefix=<path>` (or the equivalent environment-derived configured location) whose `include/` contains `sherpa-onnx/c-api/c-api.h` and whose `lib/` contains `libsherpa-onnx-c-api.so` and any companion shared libraries.
3. Add the sherpa include and library paths, link `sherpa-onnx-c-api`, and set a build-tree runpath such as `$ORIGIN/../lib` only for packaged outputs. Avoid an absolute RPATH.
4. Provide `zig build`, `zig build test`, and a `zig build check-deps` step that reports exactly which pkg-config module or sherpa file was missing.
5. Copy no system FFmpeg libraries. A future distributable packaging recipe may copy only the explicitly selected sherpa prebuilt bundle after license review.

Before writing bindings, pin one sherpa-onnx release and commit a compatibility manifest recording: release version, architecture, source URL, SHA-256, exposed header version, library file list, and minimum glibc requirement. Upgrade it only as an intentional compatibility change.

## FFmpeg decoding design

Use the libav* APIs to select the best audio stream from an input container, open its decoder, decode frames, and convert them with `libswresample` to interleaved mono `f32` PCM at the sample rate expected by the selected sherpa-onnx recognizer (normally 16 kHz; model metadata is authoritative).

The decoder API must be a streaming iterator/callback rather than a function that materializes an entire media file. Its lifecycle is:

```text
open input -> find audio stream -> open codec -> read packets
  -> send packet -> receive frames -> resample -> deliver PCM chunks
  -> flush decoder -> flush resampler -> close every native resource
```

Treat FFmpeg error integers as structured Zig errors and render their `av_strerror` text in diagnostics. Guard every allocated `AVFormatContext`, `AVCodecContext`, `AVPacket`, `AVFrame`, and `SwrContext` with immediate `defer` cleanup. Preserve input timestamps and calculate emitted segment timing from decoded sample counts when the recognizer result does not provide timestamps.

## sherpa-onnx wrapper design

Translate only the C API structures and functions required by non-streaming ASR; avoid binding unsupported API surface preemptively. Model-family setup must be a tagged union so that a Whisper configuration cannot be passed to a transducer-only constructor.

Expose a small ownership-safe interface:

```zig
const Recognizer = struct {
    pub fn init(config: Config) InitError!Recognizer;
    pub fn acceptWaveform(self: *Recognizer, sample_rate: i32, samples: []const f32) AcceptError!void;
    pub fn decode(self: *Recognizer) DecodeError!void;
    pub fn result(self: *const Recognizer, allocator: std.mem.Allocator) ResultError!Transcript;
    pub fn deinit(self: *Recognizer) void;
};
```

The wrapper owns every C handle it creates and calls the matched upstream delete function exactly once. Convert Zig strings passed to C into sentinel-terminated buffers that remain alive through each call. Copy returned C strings into allocator-owned Zig data before deleting the upstream result object. Keep all ABI-dependent declarations in one place and test them against the pinned header.

## Model acquisition and storage

Use the XDG data directory by default, e.g. `$XDG_DATA_HOME/lszl/models` (falling back to `~/.local/share/lszl/models`). Never write into the source repository or executable directory.

`lszl model default <name>` validates that `<name>` is installed and records it as the user default. `lszl model default` prints the current default. Each installed model directory contains an `lszl-model.json` manifest with:

- immutable model ID and upstream release/source URL;
- supported recognizer family and expected input sample rate;
- complete relative file list, byte sizes, and SHA-256 hashes;
- `tokens.txt` path and all model/configuration paths consumed by sherpa;
- creation timestamp and lszl manifest schema version.

`lszl model install <model-id>` downloads a curated catalog entry to a temporary directory in the same filesystem, verifies the archive and every required file, extracts with path-traversal protections, writes the manifest, and atomically renames it into the model store. Existing directories are never overwritten; an explicit `--replace` requires a complete new verification before the atomic swap. `verify` re-hashes files and reports missing, extra, or mismatched assets.

The catalog synchronizes the immutable `asr-models` release tag and exposes every ASR `.tar.bz2` archive at or below 1 GiB. It begins with the jiyi presets: streaming bilingual zh/en Zipformer, streaming bilingual zh/en Paraformer, streaming zh Zipformer CTC xlarge int8, and Nemo CTC English Conformer small. Persist a reviewed snapshot with archive IDs, byte sizes, URLs, and SHA-256 digests before download; do not use an unverified `latest` tag. Support `install --url ... --sha256 ...` only after the catalog path is complete, and require a digest for arbitrary URLs.

## Security and reliability rules

- Download with HTTPS, enforce redirect policy, size limits, SHA-256 checks, and archive-entry path validation; reject absolute paths and `..` traversal.
- Never shell out for downloading, archive extraction, or media decoding in the initial version. If Zig's HTTP/archive APIs prove unstable for the selected compiler, invoke a narrowly constrained `curl` only after recording the rationale and retaining checksum verification.
- Keep model paths, input paths, and generated output paths separate. Do not evaluate user-provided strings as shell syntax.
- Use explicit Zig error sets at module boundaries; avoid `anyerror`, `catch unreachable`, and silent fallback to a different model or decoder.
- Make output writes atomic: create a sibling temporary file, flush/close it, then rename it after successful transcription.
- Determine inference threads automatically from Linux CPU affinity and available memory; do not expose a user `--threads` override in the initial CLI.
- Probe the selected sherpa bundle for CUDA and ROCm ONNX Runtime providers and select the first usable GPU provider. Fall back to CPU with an explicit diagnostic when no compatible GPU runtime/device is present.

## Test strategy

Unit tests cover argument validation, XDG resolution, manifest parsing, digest verification, safe archive-path handling, timestamp conversion, result rendering, and FFI ownership wrappers using test doubles where possible.

Integration tests use tiny, license-cleared audio/video fixtures. They verify that WAV, MP3/Opus, and a video container decode to the same normalized PCM properties, and that transcript output formats are deterministic. A separate, opt-in integration test downloads no assets: it runs only when the pinned sherpa bundle and a verified test model are already available locally.

CI stages:

1. format check (`zig fmt --check`), compile, and unit tests;
2. FFmpeg package-discovery and decoder integration test on Linux x86_64;
3. opt-in sherpa smoke test using a cached, checksum-verified fixture model;
4. release smoke test from the staged installation directory to validate dynamic-loader paths and `lszl model verify`.

## Implementation sequence

1. Scaffold the Zig package, Linux build guard, CLI skeleton, error conventions, and dependency-check step.
2. Add the narrow FFmpeg binding and streaming PCM decoder with fixture tests.
3. Pin and document the sherpa prebuilt artifact; implement and smoke-test the C API wrapper against one non-streaming model family.
4. Connect decode -> resample -> recognition -> plain-text output, including cleanup and failure-path tests.
5. Add the model manifest, curated catalog, verified installation, and selection flow.
6. Add JSON/SRT/VTT rendering, timestamps, documentation for packagers, and CI.

## Decisions to confirm before implementation

- First model family: Whisper is the most broadly familiar default, while transducer/zipformer models may be smaller or faster. The initial catalog should choose one family and establish its exact files before generalizing.
- Distribution channel for the sherpa prebuilt archive: repository-managed checksum manifest versus a separately packaged system location.
- Whether `lszl model remove` should use a confirmation prompt by default; the implementation must never delete a model without an explicit named target.

## References

- [sherpa-onnx C API documentation](https://k2-fsa.github.io/sherpa/onnx/c-api/index.html)
- [sherpa-onnx upstream releases](https://github.com/k2-fsa/sherpa-onnx/releases)
- [FFmpeg library documentation](https://ffmpeg.org/doxygen/trunk/)
