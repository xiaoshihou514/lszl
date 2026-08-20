# Portable packaging flow

## Goal

Ship `lszl` as a self-contained, relocatable tarball that any Linux x86_64
user can unpack and run **without installing any system packages** (no zig,
no ffmpeg, no ffmpeg-devel, no jq, no sherpa-onnx). The build environment is
not part of the reproducibility contract; the produced bundle is.

The entry point is `scripts/portable-pack.sh`. It produces
`dist/lszl-<version>-linux-x86_64-portable.tar.gz` plus a `SHA256SUMS` file.

## Why the native build is not portable

`build.zig` links the executable against system FFmpeg (`libavformat`,
`libavcodec`, `libavutil`, `libswresample` via `pkg-config`) and against the
pinned sherpa-onnx C API distribution. A machine without those libraries
cannot even start the binary, and installing them is exactly the friction the
portable bundle removes.

The current CLI delegates all real work to bundled command-line tools through
an embedded shell script (`runtime_script` in `src/main.zig`), so the native
linkage is unused at runtime today. `-Dportable` therefore builds the binary
with **no** system library linkage: `zig build -Dportable
-Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe` produces a fully static
musl executable that runs on any Linux x86_64 distribution. The build-time
header test (`src/main.zig`, gated on `build_options.portable`) is skipped in
this mode.

## Runtime data relocation

The embedded script stores runtime, models, punctuation, cache and
transcripts under a data directory resolved by `dataDirectory()` in
`src/main.zig`:

1. `LSZL_DATA_HOME` (new, added for the portable bundle) → used **as-is** as
   the data directory
2. `XDG_DATA_HOME` → `<value>/lszl`
3. `HOME` → `$HOME/.local/share/lszl`

The launcher in the bundle exports `LSZL_DATA_HOME` to the bundle's own
`data/` directory, so the whole bundle stays self-contained: it can be moved,
copied, or carried on a USB stick, and models/transcripts never leak into the
user's home directory.

## Bundle layout

```text
lszl-portable/
├── lszl                  # launcher: sets LSZL_DATA_HOME + PATH, execs bin/lszl
├── README.txt            # end-user quick start
├── bin/
│   ├── lszl              # static musl executable (portable build)
│   ├── ffmpeg            # static FFmpeg 7.1.5 (BtbN/FFmpeg-Builds)
│   ├── ffprobe           # same static build
│   └── jq                # static jq 1.7.1
└── data/
    ├── runtime/sherpa-onnx-v1.13.5-linux-x64-shared-no-tts/   # pre-seeded
    └── models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/  # pre-seeded
```

The sherpa-onnx runtime and the punctuation model are pre-seeded so the first
`transcribe` needs no download beyond the ASR model itself. ASR models are
**not** bundled by default (paraformer alone is ~1 GB); users run
`./lszl model install <name>` once, or the packer passes
`--with-models paraformer,nemo` to embed them. With `--with-models`, the
bundle is fully offline-capable after unpacking.

## Pinned artifacts

Every external artifact is pinned by URL and SHA-256 inside
`scripts/portable-pack.sh`, so rebuilding the archive yields an identical
bundle. Downloads are cached in `.portable-cache/` and verified with
`sha256sum -c`; a cache hit is reused only when it matches the pinned digest.

| Artifact | Pin | SHA-256 |
| --- | --- | --- |
| sherpa-onnx CPU runtime | `v1.13.5` release tag | `a3936961…fac84166` |
| FFmpeg static build | BtbN release `autobuild-2026-08-15-13-02`, asset `ffmpeg-n7.1.5-16-g9a4bb2c579-linux64-gpl-7.1.tar.xz` | `198fafe8…b01643fa` |
| jq | `jq-1.7.1` release asset `jq-linux-amd64` | `5942c9b0…d19c8ff5` |
| punctuation model | `punctuation-models` release tag | `c0d5aa5f…328a6e1` |
| ASR models (optional) | `asr-models` release tag, one archive per preset | pinned per model in the script |

Notes:

- FFmpeg comes from BtbN/FFmpeg-Builds rather than johnvansickle.com because
  the latter blocks scripted access (HTTP 403); the BtbN release tag pins the
  exact git revision of the build.
- The GPU sherpa-onnx runtime is intentionally not bundled: the script
  auto-selects it only when a CUDA device and the managed cuDNN runtime are
  present, and it would otherwise just bloat the archive.

## Reproducing

```shell
# Requires: a zig 0.16.x toolchain and curl/tar on the packer's machine.
scripts/portable-pack.sh                      # default bundle (no ASR models)
scripts/portable-pack.sh --with-models paraformer,nemo   # fully offline bundle
```

The script:

1. builds the portable static binary into a staging prefix,
2. fetches and SHA-256-verifies every pinned artifact into `.portable-cache/`,
3. assembles `lszl-portable/` under `.portable-staging/`,
4. smoke-tests `./lszl help` and `./lszl model list` from the bundle,
5. writes `dist/lszl-<version>-linux-x86_64-portable.tar.gz` and `SHA256SUMS`.

## End-user flow

```shell
tar -xzf lszl-0.1.0-linux-x86_64-portable.tar.gz
cd lszl-portable
./lszl model install paraformer   # one-time model download into ./data
./lszl transcribe "录音.m4a"
```

Host dependencies that remain: `bash`, `curl`, `tar`, `sha256sum` and the
glibc needed by the bundled sherpa-onnx runtime — all present on any
mainstream Linux distribution. The `lszl` executable itself and `jq` are
statically linked; FFmpeg is a static build that only needs glibc.
