#!/usr/bin/env bash
# Pack a self-contained, relocatable lszl distribution.
#
# The native lszl binary decodes media through the FFmpeg shared libraries
# and drives sherpa-onnx through its C API (dlopen at run time), so the
# bundle contains no CLI subprocesses at all:
#   - the lszl executable (dynamic) + shared FFmpeg libav* libraries
#   - the sherpa-onnx CPU runtime (libraries only, trimmed)
#   - the punctuation model
#   - GPU support: the CUDA sherpa-onnx runtime and cuDNN 9 (auto-selected
#     when an NVIDIA driver with CUDA 13 libraries is present)
#
# The four ASR model presets are NOT embedded in the app bundle by default;
# each is shipped as its own dist/lszl-<version>-linux-x86_64-models-<name>.tar.gz
# (same lszl-portable/ top-level directory, so unpacking one next to the app
# bundle merges that model into data/models/). Pass --models <list> to embed
# those models in the app bundle as well; the models packs then carry the
# same list. --no-models-pack disables the models packs entirely.
#
# Every external artifact is pinned by URL and SHA-256, so the produced
# bundle is reproducible; the build environment itself is whatever machine
# you run this on (a zig 0.16.x toolchain is the only requirement).
#
# Usage:
#   scripts/portable-pack.sh                 # app bundle + 4 model packs
#   scripts/portable-pack.sh --models zipformer,paraformer   # embed + pack list
#   scripts/portable-pack.sh --no-models --no-gpu            # minimal CPU bundle
#   scripts/portable-pack.sh --no-models-pack                # app bundle only
set -euo pipefail

version="0.2.0"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$repo_root/.portable-cache"
staging="$repo_root/.portable-staging"
dist_dir="$repo_root/dist"
bundle_name="lszl-portable"
bundle_dir="$staging/$bundle_name"
models_pack_root="$staging/models-pack"
archive="$dist_dir/lszl-${version}-linux-x86_64-portable.tar.gz"
models_archive_prefix="lszl-${version}-linux-x86_64-models-"

models_to_bundle=""
bundle_models_pack="1"
bundle_gpu="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --models) models_to_bundle="${2:-}"; shift 2 ;;
    --no-models) models_to_bundle="none"; shift ;;
    --no-models-pack) bundle_models_pack="0"; shift ;;
    --no-gpu) bundle_gpu="0"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Pinned external artifacts (URL + SHA-256) -------------------------------
# sherpa-onnx CPU runtime, trimmed to the binaries lszl actually invokes.
sherpa_runtime="sherpa-onnx-v1.13.5-linux-x64-shared-no-tts"
sherpa_runtime_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/${sherpa_runtime}.tar.bz2"
sherpa_runtime_sha256="a39369615d610cb835f225b6b7fbff684aedf46557eab8a90e1ccc11fac84166"

# sherpa-onnx CUDA 13 runtime, used only when a working NVIDIA driver is found.
sherpa_gpu_runtime="sherpa-onnx-v1.13.5-cuda-13.x-cudnn-9.x-onnxruntime1.27.1-linux-x64-gpu"
sherpa_gpu_runtime_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/${sherpa_gpu_runtime}.tar.bz2"
sherpa_gpu_runtime_sha256="dde7732e0649dbe0702266f4b57d9b2ac1136f879057bed6754b984752ca7a35"

# cuDNN 9 for CUDA 13, extracted into data/cudnn (same layout the runtime
# script already probes: data/cudnn/lib/libcudnn.so.9).
cudnn_archive="cudnn-linux-x86_64-9.25.0.15_cuda13-archive"
cudnn_url="https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/linux-x86_64/${cudnn_archive}.tar.xz"
cudnn_sha256="bdf8c65f92dd552141d011fd7e7a1bfbafdc6239667b15c44d604597fa927745"

# Shared FFmpeg build from BtbN/FFmpeg-Builds (libav* .so libraries; the
# binary is built against this exact tree via -Dffmpeg_prefix). BtbN prunes
# old autobuild tags, so by default the newest release is resolved at pack
# time and the resolved URL + SHA-256 are recorded in dist/FFMPEG-SOURCE.txt.
# Export FFMPEG_URL (and FFMPEG_SHA256) to pin an exact artifact instead.
ffmpeg_url="${FFMPEG_URL:-}"
ffmpeg_sha256="${FFMPEG_SHA256:-}"
if [ -z "$ffmpeg_url" ]; then
  echo "==> resolving newest BtbN shared FFmpeg build"
  ffmpeg_url="$(curl -sL --fail "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*linux64-gpl-shared[^"]*\.tar\.xz"' \
    | head -1 | cut -d'"' -f4)"
  test -n "$ffmpeg_url" || { echo "cannot resolve a BtbN shared FFmpeg build" >&2; exit 2; }
fi

# jq is no longer needed: the native pipeline replaced every jq call.

# Punctuation model, needed by every transcribe.
punctuation_name="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
punctuation_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/${punctuation_name}.tar.bz2"
punctuation_sha256="c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1"

# ASR model archives.
model_url_base="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
model_sha256_zipformer="27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8"
model_sha256_paraformer="5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f"
model_sha256_zipformer_ctc="23f32059d502e87f4fe4b1a17dbedb65582bb0c42950b3d615f218bb25feafd5"
model_sha256_nemo="83dcb462aece5bef4e8072c267419389f0b8d1f91152d8851765f284ff664caa"
model_sha256_japanese="dc03758608c0280e2cbcaac4597467ffcf846ae0b06436f1706738a11da86f5d"
model_sha256_korean="e346a5882a409650472be17326237e24df7bf409db6b4a8a52e1a61422bf2500"
model_sha256_vietnamese="501b2f6e12d5871ff35dc356cf41bb3197f7e32fb7480db744d603bc99a9ad02"
model_sha256_multilingual="28044b67324f7f831689f0a3761473dd2ade380e93aa53f1dbcd479ef71c40d4"
model_upstream_zipformer="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
model_upstream_paraformer="sherpa-onnx-streaming-paraformer-bilingual-zh-en"
model_upstream_zipformer_ctc="sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30"
model_upstream_nemo="sherpa-onnx-nemo-ctc-en-conformer-small"
model_upstream_japanese="sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17"
model_upstream_korean="sherpa-onnx-streaming-zipformer-korean-2024-06-16"
model_upstream_vietnamese="sherpa-onnx-zipformer-vi-2025-04-20"
model_upstream_multilingual="sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10"

# --- Helpers -----------------------------------------------------------------
mkdir -p "$cache"
fetch() { # url dest sha256
  if [ -e "$2" ] && printf '%s  %s\n' "$3" "$2" | sha256sum -c --quiet 2>/dev/null; then
    echo "cached: $2"; return
  fi
  echo "fetching: $1"
  curl -L --fail --retry 3 -C - -o "$2.part" "$1"
  printf '%s  %s\n' "$3" "$2.part" | sha256sum -c --quiet
  mv "$2.part" "$2"
}

# Extract a sherpa-onnx runtime and trim it to the binaries lszl invokes
# (streaming CLI, offline CLI, punctuation CLI) plus the shared libraries.
install_runtime() { # archive_dir top_name
  dir="$bundle_dir/data/runtime/$2"
  tar -xjf "$cache/$1" -C "$bundle_dir/data/runtime"
  # lszl drives sherpa-onnx through the C API (dlopen); no CLI needed.
  rm -rf "$dir/bin"
  test -f "$dir/lib/libsherpa-onnx-c-api.so"
  test -f "$dir/lib/libonnxruntime.so"
}

# --- Fetch the shared FFmpeg tree ---------------------------------------------
echo "==> fetching shared FFmpeg: $ffmpeg_url"
if [ -n "$ffmpeg_sha256" ]; then
  fetch "$ffmpeg_url" "$cache/ffmpeg-shared.tar.xz" "$ffmpeg_sha256"
else
  if [ -e "$cache/ffmpeg-shared.tar.xz" ]; then echo "cached (unpinned): $cache/ffmpeg-shared.tar.xz";
  else
    curl -L --fail --retry 3 -C - -o "$cache/ffmpeg-shared.tar.xz.part" "$ffmpeg_url"
    mv "$cache/ffmpeg-shared.tar.xz.part" "$cache/ffmpeg-shared.tar.xz"
  fi
  ffmpeg_sha256="$(sha256sum "$cache/ffmpeg-shared.tar.xz" | cut -d' ' -f1)"
fi
mkdir -p "$staging/ffmpeg"
tar -xJf "$cache/ffmpeg-shared.tar.xz" -C "$staging/ffmpeg" --strip-components=1
test -f "$staging/ffmpeg/lib/libavformat.so"
mkdir -p "$dist_dir"
printf 'url: %s\nsha256: %s\n' "$ffmpeg_url" "$ffmpeg_sha256" > "$dist_dir/FFMPEG-SOURCE.txt"

# --- Build the portable binary -----------------------------------------------
echo "==> building portable lszl binary"
# zig-local may be a symlink to a tmpfs on filesystems where zig's cache
# rename fails (e.g. WSL2 drvfs/9p); mkdir -p tolerates it.
mkdir -p "$cache/zig-global" "$cache/zig-local" 2>/dev/null || true
zig_global_cache="${ZIG_GLOBAL_CACHE_DIR:-$cache/zig-global}"
zig_local_cache="${ZIG_LOCAL_CACHE_DIR:-$cache/zig-local}"
ZIG_GLOBAL_CACHE_DIR="$zig_global_cache" ZIG_LOCAL_CACHE_DIR="$zig_local_cache" \
  zig build -Doptimize=ReleaseSafe -Dffmpeg_prefix="$staging/ffmpeg" --prefix "$staging/zig-out"
test -x "$staging/zig-out/bin/lszl"

# --- Assemble the bundle -------------------------------------------------------
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/bin" "$bundle_dir/data/runtime" "$bundle_dir/data/models"

install -m755 "$staging/zig-out/bin/lszl" "$bundle_dir/bin/lszl"

echo "==> bundling trimmed CPU runtime"
fetch "$sherpa_runtime_url" "$cache/sherpa-runtime.tar.bz2" "$sherpa_runtime_sha256"
install_runtime sherpa-runtime.tar.bz2 "$sherpa_runtime"

echo "==> bundling punctuation model"
fetch "$punctuation_url" "$cache/punctuation.tar.bz2" "$punctuation_sha256"
tar -xjf "$cache/punctuation.tar.bz2" -C "$bundle_dir/data/models"
punctuation_dir="$bundle_dir/data/models/$punctuation_name"
find "$punctuation_dir" -mindepth 1 -maxdepth 1 ! -name 'model.int8.onnx' -exec rm -rf {} +
test -f "$punctuation_dir/model.int8.onnx"

if [ "$bundle_gpu" = "1" ]; then
  echo "==> bundling GPU runtime and cuDNN"
  fetch "$sherpa_gpu_runtime_url" "$cache/sherpa-gpu-runtime.tar.bz2" "$sherpa_gpu_runtime_sha256"
  install_runtime sherpa-gpu-runtime.tar.bz2 "$sherpa_gpu_runtime"
  fetch "$cudnn_url" "$cache/cudnn.tar.xz" "$cudnn_sha256"
  mkdir -p "$bundle_dir/data/cudnn"
  tar -xJf "$cache/cudnn.tar.xz" -C "$bundle_dir/data/cudnn" --strip-components=1
  test -f "$bundle_dir/data/cudnn/lib/libcudnn.so.9"
fi

echo "==> bundling shared FFmpeg libraries"
mkdir -p "$bundle_dir/lib"
for so in "$staging/ffmpeg"/lib/libavformat.so* "$staging/ffmpeg"/lib/libavcodec.so* \
          "$staging/ffmpeg"/lib/libavutil.so* "$staging/ffmpeg"/lib/libswresample.so*; do
  cp -a "$so" "$bundle_dir/lib/"
done
test -e "$bundle_dir/lib/libavformat.so"

# Extract one ASR model archive into a data/models directory.
# Usage: bundle_model <model> <dest_data_models_dir>
bundle_model() { # model dest
  case "$1" in
    zipformer) upstream="$model_upstream_zipformer"; model_sha256="$model_sha256_zipformer" ;;
    paraformer) upstream="$model_upstream_paraformer"; model_sha256="$model_sha256_paraformer" ;;
    zipformer-ctc) upstream="$model_upstream_zipformer_ctc"; model_sha256="$model_sha256_zipformer_ctc" ;;
    nemo) upstream="$model_upstream_nemo"; model_sha256="$model_sha256_nemo" ;;
    japanese) upstream="$model_upstream_japanese"; model_sha256="$model_sha256_japanese" ;;
    korean) upstream="$model_upstream_korean"; model_sha256="$model_sha256_korean" ;;
    vietnamese) upstream="$model_upstream_vietnamese"; model_sha256="$model_sha256_vietnamese" ;;
    multilingual) upstream="$model_upstream_multilingual"; model_sha256="$model_sha256_multilingual" ;;
    *) echo "unknown model: $1" >&2; exit 2 ;;
  esac
  echo "==> bundling model: $1"
  fetch "$model_url_base/${upstream}.tar.bz2" "$cache/${upstream}.tar.bz2" "$model_sha256"
  tar -xjf "$cache/${upstream}.tar.bz2" -C "$2"
  test -f "$2/$upstream/tokens.txt"
}

# ASR models. Default split layout:
#   - the app bundle embeds NO ASR models (punctuation model stays in the app)
#   - the standalone models pack carries all four presets
# --models <list> embeds those models in the app bundle AND in the models pack;
# --no-models skips models entirely; --no-models-pack disables the models pack.
models_pack_list=""
if [ -z "$models_to_bundle" ]; then
  models_to_bundle="none"
  models_pack_list="zipformer,paraformer,zipformer-ctc,nemo,japanese,korean,vietnamese,multilingual"
elif [ "$models_to_bundle" = "none" ]; then
  models_pack_list="none"
else
  models_pack_list="$models_to_bundle"
fi
if [ "$bundle_models_pack" = "0" ]; then
  models_pack_list="none"
fi

if [ "$models_to_bundle" != "none" ]; then
  IFS=',' read -ra model_list <<< "$models_to_bundle"
  for model in "${model_list[@]}"; do
    bundle_model "$model" "$bundle_dir/data/models"
  done
fi

cat > "$bundle_dir/lszl" <<'LAUNCHER'
#!/bin/sh
# lszl portable launcher: relocatable, no system packages required.
# Works when invoked directly, through a symlink (e.g. ~/.local/bin/lszl)
# or through PATH lookup: the bundle is always located via the real path.
self="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
here="$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)"
export LSZL_DATA_HOME="$here/data"
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/bin/lszl" "$@"
LAUNCHER
chmod +x "$bundle_dir/lszl"

# Pre-select the flagship default so `transcribe` works right after unpacking.
# No trailing newline: this mirrors what `lszl model default` writes, and the
# CLI trims whitespace on load anyway.
printf 'paraformer' > "$bundle_dir/data/default-model"

cat > "$bundle_dir/install.sh" <<'INSTALLER'
#!/bin/sh
# Install lszl into the standard per-user layout:
#   $PREFIX/bin/lszl          (default $HOME/.local/bin)  -- thin launcher
#   $PREFIX/share/lszl/       (default $HOME/.local/share) -- program + data
# Run from inside the unpacked bundle:  ./install.sh
# Uninstall:  ./install.sh --uninstall
set -eu
prefix="${PREFIX:-$HOME/.local}"
bin_dir="${prefix}/bin"
share_dir="${prefix}/share/lszl"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$bin_dir/lszl"
  rm -rf "$share_dir"
  echo "removed: $bin_dir/lszl and $share_dir"
  exit 0
fi

self="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
here="$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)"

if [ "$here" = "$share_dir" ]; then
  echo "already installed at $share_dir"
else
  mkdir -p "$(dirname "$share_dir")"
  echo "installing bundle to $share_dir ..."
  cp -a "$here/." "$share_dir/"
fi

mkdir -p "$bin_dir"
cat > "$bin_dir/lszl" <<EOF
#!/bin/sh
# Generated by lszl install.sh -- do not edit.
exec "$share_dir/lszl" "\$@"
EOF
chmod +x "$bin_dir/lszl"

echo "installed: $bin_dir/lszl -> $share_dir"
echo "make sure $bin_dir is in your PATH (usually already the case)."
echo "uninstall: $share_dir/install.sh --uninstall"
INSTALLER
chmod +x "$bundle_dir/install.sh"

cat > "$bundle_dir/README.txt" <<EOF
lszl $version (portable, Linux x86_64)
======================================
Unpack anywhere and run; no system packages are needed. ASR models are shipped
as one tarball per model (dist/lszl-${version}-linux-x86_64-models-<name>.tar.gz)
to keep downloads small. Unpack the model(s) you want next to this bundle so
their lszl-portable/ directory merges into this one, then transcribe:

  tar -xzf lszl-${version}-linux-x86_64-models-paraformer.tar.gz  # or zipformer / zipformer-ctc / nemo

  ./lszl model list
  ./lszl transcribe "录音.m4a"
  ./lszl transcribe --model nemo "speech.wav"
  ./lszl doctor

Missing a model? Either unpack its tarball, or install on demand:

  ./lszl model install paraformer

GPU: if an NVIDIA driver with CUDA 13 libraries is installed, lszl
automatically uses the bundled CUDA runtime and cuDNN 9 (provider=cuda).

The bundle keeps its runtime, models and transcripts inside ./data, so the
whole folder stays self-contained and can be moved or copied as-is.

Reproducibility: every bundled tool is pinned by URL and SHA-256 in
scripts/portable-pack.sh; rebuilding the archive yields an identical bundle.
EOF

# --- Smoke test ---------------------------------------------------------------
echo "==> smoke test"
(cd "$bundle_dir" && ./lszl help >/dev/null && ./lszl model list >/dev/null && ./lszl doctor >/dev/null)

# --- Archive -------------------------------------------------------------------
mkdir -p "$dist_dir"
rm -f "$archive"
rm -f "$dist_dir"/lszl-${version}-linux-x86_64-models-*.tar.gz

# Standalone model packs: one tarball per model, each with the same
# lszl-portable/ top-level directory as the app bundle, so unpacking it next
# to the app bundle merges that model into data/models/.
if [ "$models_pack_list" != "none" ]; then
  IFS=',' read -ra model_list <<< "$models_pack_list"
  for model in "${model_list[@]}"; do
    echo "==> assembling standalone model pack: $model"
    rm -rf "$models_pack_root"
    mkdir -p "$models_pack_root/$bundle_name/data/models"
    bundle_model "$model" "$models_pack_root/$bundle_name/data/models"
    tar -czf "$dist_dir/${models_archive_prefix}${model}.tar.gz" -C "$models_pack_root" "$bundle_name"
  done
fi

tar -czf "$archive" -C "$staging" "$bundle_name"
cd "$dist_dir"
{
  sha256sum "lszl-${version}-linux-x86_64-portable.tar.gz"
  # Model packs are optional (--no-models-pack); glob may be empty.
  sha256sum lszl-${version}-linux-x86_64-models-*.tar.gz 2>/dev/null || true
} > SHA256SUMS
echo "==> produced:"
echo "  $archive"
for pack in "$dist_dir"/lszl-${version}-linux-x86_64-models-*.tar.gz; do
  [ -e "$pack" ] && echo "  $pack"
done
echo "  $dist_dir/SHA256SUMS"
echo "  $dist_dir/FFMPEG-SOURCE.txt"
du -h "$archive"
du -h lszl-${version}-linux-x86_64-models-*.tar.gz 2>/dev/null || true
