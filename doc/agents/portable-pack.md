# Portable packaging flow

## Goal

Ship `lszl` as a self-contained, relocatable tarball that any Linux x86_64
user can unpack and run **without installing any system packages** (no zig,
no ffmpeg, no ffmpeg-devel, no jq, no sherpa-onnx, no cuDNN). The build
environment is not part of the reproducibility contract; the produced bundle
is.

The entry point is `scripts/portable-pack.sh`. It produces the app bundle, one
tarball per ASR model, plus a `SHA256SUMS` file:

- `lszl-<version>-linux-x86_64-portable.tar.gz` — the app bundle (binary,
  runtimes, ffmpeg, jq, punctuation model; **no ASR models**)
- `lszl-<version>-linux-x86_64-models-<name>.tar.gz` — one tarball per ASR
  model preset (`paraformer`, `zipformer`, `zipformer-ctc`, `nemo`,
  `japanese`, `korean`, `vietnamese`, `multilingual`)

Each model pack uses the same `lszl-portable/` top-level directory as the app
bundle, so unpacking it next to the app bundle merges that model's
`data/models/` into the bundle. Pass `--models <list>` to embed those models in
the app bundle as well (the model packs then carry the same list), or
`--no-models-pack` to skip the model packs.

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
    ├── default-model                     # pre-set to paraformer
    ├── runtime/
    │   ├── sherpa-onnx-v1.13.5-linux-x64-shared-no-tts/            # CPU, trimmed
    │   └── sherpa-onnx-v1.13.5-cuda-13.x-cudnn-9.x-...-linux-x64-gpu/  # GPU, trimmed
    ├── cudnn/                             # cuDNN 9 (CUDA 13), extracted
    ├── models/
    │   ├── sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/  # trimmed, in app bundle
    │   └── … ASR models live in the separate per-model packs (merged on unpack)
    └── transcripts/                       # created on demand
```

### Trimming

The upstream sherpa-onnx runtimes ship ~35 binaries each (microphone, ALSA,
VAD, keyword spotter, diarization, websocket servers, …). lszl only invokes
three, so the packer deletes everything else:

- `sherpa-onnx` — streaming ASR (zipformer, paraformer, zipformer-ctc)
- `sherpa-onnx-offline` — offline ASR (nemo)
- `sherpa-onnx-offline-punctuation` — punctuation

The whole `lib/` directory is kept (the trimmed binaries link against
`libonnxruntime.so` and the sherpa C++ API). The punctuation model directory
is trimmed to `model.int8.onnx`.

### GPU support

The full bundle pre-seeds the CUDA 13 sherpa-onnx runtime and cuDNN 9 into
`data/runtime/` and `data/cudnn/` (the same layout the embedded script
already probes: `data/cudnn/lib/libcudnn.so.9`). At runtime the script
auto-selects `provider=cuda` when `nvidia-smi` works and the bundled cuDNN is
present; otherwise it falls back to the bundled CPU runtime. Only the NVIDIA
driver/CUDA-13 toolkit libraries must come from the host — the CUDA toolkit
cannot be redistributed in a bundle.

## Pinned artifacts

Every external artifact is pinned by URL and SHA-256 inside
`scripts/portable-pack.sh`, so rebuilding the archive yields an identical
bundle. Downloads are cached in `.portable-cache/` and verified with
`sha256sum -c`; a cache hit is reused only when it matches the pinned digest.

| Artifact | Pin | SHA-256 |
| --- | --- | --- |
| sherpa-onnx CPU runtime | `v1.13.5` release tag | `a3936961…fac84166` |
| sherpa-onnx CUDA runtime | `v1.13.5` release tag | `dde7732e…2ca7a35` |
| cuDNN 9 (CUDA 13) | NVIDIA redist `9.25.0.15_cuda13` | `bdf8c65f…fa927745` |
| FFmpeg static build | BtbN release `autobuild-2026-08-15-13-02`, asset `ffmpeg-n7.1.5-16-g9a4bb2c579-linux64-gpl-7.1.tar.xz` | `198fafe8…b01643fa` |
| jq | `jq-1.7.1` release asset `jq-linux-amd64` | `5942c9b0…d19c8ff5` |
| punctuation model | `punctuation-models` release tag | `c0d5aa5f…328a6e1` |
| ASR models (8 presets) | `asr-models` release tag | pinned per model in the script |

Notes:

- FFmpeg comes from BtbN/FFmpeg-Builds rather than johnvansickle.com because
  the latter blocks scripted access (HTTP 403); the BtbN release tag pins the
  exact git revision of the build.
- ASR model archives are large (paraformer ~1 GB, zipformer-ctc ~0.6 GB), so
  they ship as one tarball per model by default. `--models` embeds them in
  the app bundle; `--no-gpu` and `--no-models-pack` shrink the app bundle.

## Reproducing

```shell
# Requires: a zig 0.16.x toolchain and curl/tar on the packer's machine.
scripts/portable-pack.sh                                     # app bundle + 4 model packs
scripts/portable-pack.sh --models zipformer,paraformer       # embed + pack the list
scripts/portable-pack.sh --no-models --no-gpu                # minimal CPU app bundle
scripts/portable-pack.sh --no-models-pack                    # app bundle only
```

The script:

1. builds the portable static binary into a staging prefix,
2. fetches and SHA-256-verifies every pinned artifact into `.portable-cache/`,
3. assembles `lszl-portable/` under `.portable-staging/`, trimming each
   sherpa-onnx runtime to the three binaries lszl uses,
4. pre-sets `data/default-model` to `paraformer`,
5. smoke-tests `./lszl help` and `./lszl model list` from the bundle,
6. writes `dist/lszl-<version>-linux-x86_64-portable.tar.gz`, one
   `dist/lszl-<version>-linux-x86_64-models-<name>.tar.gz` per model
   (unless `--no-models-pack`), and `SHA256SUMS`.

Note: ASR model archives are large (paraformer ~1 GB, zipformer-ctc ~0.6 GB),
so they are kept out of the app bundle by default and shipped as one tarball
per model; the end user only downloads the models they actually use, instead
of a several-GB all-in-one archive or `lszl model install` over the network.

## End-user flow

### Portable mode (no fixed location)

```shell
tar -xzf lszl-0.1.1-linux-x86_64-portable.tar.gz
tar -xzf lszl-0.1.1-linux-x86_64-models-paraformer.tar.gz   # same directory: merges data/models/
cd lszl-portable
./lszl transcribe "录音.m4a"          # default model paraformer, fully offline
./lszl transcribe --model nemo "speech.wav"
./lszl doctor
```

The launcher resolves its own real path (`readlink -f`, so symlinks into
`~/.local/bin` work) and points `LSZL_DATA_HOME` at the bundle's `data/`.

### Standard install (~/.local/bin + ~/.local/share)

The bundle ships `install.sh`, which produces the conventional per-user
layout with a thin launcher in `bin` and the program plus all data under
`share`:

```shell
tar -xzf lszl-0.1.1-linux-x86_64-portable.tar.gz
tar -xzf lszl-0.1.1-linux-x86_64-models-paraformer.tar.gz   # same directory
cd lszl-portable
./install.sh
# -> $HOME/.local/bin/lszl          thin launcher, on PATH by default
# -> $HOME/.local/share/lszl/       full bundle (binary, runtimes, models, data)
lszl transcribe "录音.m4a"
```

Notes:

- `PREFIX=/path ./install.sh` relocates both directories under `PREFIX`.
- Uninstall: `$HOME/.local/share/lszl/install.sh --uninstall`.
- `install.sh` is idempotent: re-running refreshes the installed copy.
- Transcripts land in `$HOME/.local/share/lszl/data/transcripts/`.

Host dependencies that remain: `bash`, `curl`, `tar`, `sha256sum` and the
glibc needed by the bundled sherpa-onnx runtime — all present on any
mainstream Linux distribution. The `lszl` executable itself and `jq` are
statically linked; FFmpeg is a static build that only needs glibc.
