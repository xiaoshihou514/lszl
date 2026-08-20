#!/usr/bin/env bash
# Pack a self-contained, relocatable lszl distribution.
#
# The result is a tarball that any Linux x86_64 user can unpack and run
# without installing any system packages (no zig, no ffmpeg, no jq, no
# sherpa-onnx, no cuDNN). It bundles:
#   - the static lszl executable, static FFmpeg 7.1.5 and static jq 1.7.1
#   - the sherpa-onnx CPU runtime, trimmed to the three binaries lszl uses
#   - the punctuation model
#   - all four ASR model presets by default (fully offline after unpacking)
#   - GPU support: the CUDA sherpa-onnx runtime and cuDNN 9 (auto-selected
#     when an NVIDIA driver with CUDA 13 libraries is present)
#
# Every external artifact is pinned by URL and SHA-256, so the produced
# bundle is reproducible; the build environment itself is whatever machine
# you run this on (a zig 0.16.x toolchain is the only requirement).
#
# Usage:
#   scripts/portable-pack.sh                 # full bundle (models + GPU)
#   scripts/portable-pack.sh --models zipformer,paraformer
#   scripts/portable-pack.sh --no-models --no-gpu   # minimal CPU bundle
set -euo pipefail

version="0.1.0"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$repo_root/.portable-cache"
staging="$repo_root/.portable-staging"
dist_dir="$repo_root/dist"
bundle_name="lszl-portable"
bundle_dir="$staging/$bundle_name"
archive="$dist_dir/lszl-${version}-linux-x86_64-portable.tar.gz"

models_to_bundle=""
bundle_gpu="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --models) models_to_bundle="${2:-}"; shift 2 ;;
    --no-models) models_to_bundle="none"; shift ;;
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

# Static FFmpeg 7.1.5 build from BtbN/FFmpeg-Builds (tag pins the exact build).
ffmpeg_release="autobuild-2026-08-15-13-02"
ffmpeg_archive="ffmpeg-n7.1.5-16-g9a4bb2c579-linux64-gpl-7.1.tar.xz"
ffmpeg_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/${ffmpeg_release}/${ffmpeg_archive}"
ffmpeg_sha256="198fafe897ad9d84bc776d895047ec2c0d21346977a53895b771fec9b01643fa"

# Statically linked jq 1.7.1.
jq_archive="jq-linux-amd64"
jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/${jq_archive}"
jq_sha256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"

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
model_upstream_zipformer="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
model_upstream_paraformer="sherpa-onnx-streaming-paraformer-bilingual-zh-en"
model_upstream_zipformer_ctc="sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30"
model_upstream_nemo="sherpa-onnx-nemo-ctc-en-conformer-small"

# --- Helpers -----------------------------------------------------------------
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
  for bin in "$dir"/bin/*; do
    case "$(basename "$bin")" in
      sherpa-onnx|sherpa-onnx-offline|sherpa-onnx-offline-punctuation) ;;
      *) rm -f "$bin" ;;
    esac
  done
  rm -f "$dir"/bin/sherpa-onnx-version
  test -x "$dir/bin/sherpa-onnx"
  test -x "$dir/bin/sherpa-onnx-offline"
  test -x "$dir/bin/sherpa-onnx-offline-punctuation"
  # Keep the whole lib/ directory: the trimmed binaries link against these.
  test -f "$dir/lib/libonnxruntime.so"
}

# --- Build the portable binary -----------------------------------------------
echo "==> building portable lszl binary"
mkdir -p "$cache/zig-global" "$cache/zig-local"
ZIG_GLOBAL_CACHE_DIR="$cache/zig-global" ZIG_LOCAL_CACHE_DIR="$cache/zig-local" \
  zig build -Dportable -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix "$staging/zig-out"
test -x "$staging/zig-out/bin/lszl"
"$staging/zig-out/bin/lszl" help >/dev/null

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

echo "==> bundling static ffmpeg and jq"
fetch "$ffmpeg_url" "$cache/ffmpeg.tar.xz" "$ffmpeg_sha256"
mkdir -p "$staging/ffmpeg"
tar -xJf "$cache/ffmpeg.tar.xz" -C "$staging/ffmpeg"
ffmpeg_dir="$(find "$staging/ffmpeg" -maxdepth 1 -type d -name 'ffmpeg-*' | head -1)"
install -m755 "$ffmpeg_dir/bin/ffmpeg" "$bundle_dir/bin/ffmpeg"
install -m755 "$ffmpeg_dir/bin/ffprobe" "$bundle_dir/bin/ffprobe"
"$bundle_dir/bin/ffmpeg" -version >/dev/null

fetch "$jq_url" "$cache/jq" "$jq_sha256"
install -m755 "$cache/jq" "$bundle_dir/bin/jq"
"$bundle_dir/bin/jq" --version >/dev/null

# ASR models: default = all presets; --models <list> selects; --no-models skips.
if [ -z "$models_to_bundle" ]; then
  models_to_bundle="zipformer,paraformer,zipformer-ctc,nemo"
fi
if [ "$models_to_bundle" != "none" ]; then
  IFS=',' read -ra model_list <<< "$models_to_bundle"
  for model in "${model_list[@]}"; do
    case "$model" in
      zipformer) upstream="$model_upstream_zipformer"; model_sha256="$model_sha256_zipformer" ;;
      paraformer) upstream="$model_upstream_paraformer"; model_sha256="$model_sha256_paraformer" ;;
      zipformer-ctc) upstream="$model_upstream_zipformer_ctc"; model_sha256="$model_sha256_zipformer_ctc" ;;
      nemo) upstream="$model_upstream_nemo"; model_sha256="$model_sha256_nemo" ;;
      *) echo "unknown model: $model" >&2; exit 2 ;;
    esac
    echo "==> bundling model: $model"
    fetch "$model_url_base/${upstream}.tar.bz2" "$cache/${upstream}.tar.bz2" "$model_sha256"
    tar -xjf "$cache/${upstream}.tar.bz2" -C "$bundle_dir/data/models"
    test -f "$bundle_dir/data/models/$upstream/tokens.txt"
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
export PATH="$here/bin:$PATH"
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
Unpack anywhere and run; no system packages are needed. All four ASR models
are already bundled, so transcription works fully offline:

  ./lszl model list
  ./lszl transcribe "录音.m4a"
  ./lszl transcribe --model nemo "speech.wav"
  ./lszl doctor

GPU: if an NVIDIA driver with CUDA 13 libraries is installed, lszl
automatically uses the bundled CUDA runtime and cuDNN 9 (provider=cuda).

The bundle keeps its runtime, models and transcripts inside ./data, so the
whole folder stays self-contained and can be moved or copied as-is.

Reproducibility: every bundled tool is pinned by URL and SHA-256 in
scripts/portable-pack.sh; rebuilding the archive yields an identical bundle.
EOF

# --- Smoke test ---------------------------------------------------------------
echo "==> smoke test"
(cd "$bundle_dir" && ./lszl help >/dev/null && ./lszl model list >/dev/null)

# --- Archive -------------------------------------------------------------------
mkdir -p "$dist_dir"
rm -f "$archive"
tar -czf "$archive" -C "$staging" "$bundle_name"
(cd "$dist_dir" && sha256sum "lszl-${version}-linux-x86_64-portable.tar.gz" > SHA256SUMS)
echo "==> produced:"
echo "  $archive"
echo "  $dist_dir/SHA256SUMS"
du -h "$archive"
