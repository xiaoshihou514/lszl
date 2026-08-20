#!/usr/bin/env bash
# Pack a self-contained, relocatable lszl distribution.
#
# The result is a tarball that any Linux x86_64 user can unpack and run
# without installing any system packages (no zig, no ffmpeg, no jq, no
# sherpa-onnx). Every external artifact is pinned by URL and SHA-256, so the
# produced bundle is reproducible; the build environment itself is whatever
# machine you run this on (a zig 0.16.x toolchain is the only requirement).
#
# Usage:
#   scripts/portable-pack.sh [--with-models <name[,name...]>]
#
# --with-models additionally bundles the listed preset ASR models
# (zipformer, paraformer, zipformer-ctc, nemo) so transcription works fully
# offline after unpacking. Without it, users run `./lszl model install <name>`
# once (the models are hundreds of MB each, so they are not bundled by default).
set -euo pipefail

version="0.1.0"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$repo_root/.portable-cache"
staging="$repo_root/.portable-staging"
dist_dir="$repo_root/dist"
bundle_name="lszl-portable"
bundle_dir="$staging/$bundle_name"
archive="$dist_dir/lszl-${version}-linux-x86_64-portable.tar.gz"

with_models=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-models) with_models="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Pinned external artifacts (URL + SHA-256) -------------------------------
# sherpa-onnx CPU runtime, used by the embedded runtime script.
sherpa_runtime="sherpa-onnx-v1.13.5-linux-x64-shared-no-tts"
sherpa_runtime_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/${sherpa_runtime}.tar.bz2"
sherpa_runtime_sha256="a39369615d610cb835f225b6b7fbff684aedf46557eab8a90e1ccc11fac84166"

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

# ASR model archives (only fetched with --with-models).
model_url_base="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
model_sha256_zipformer="27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8"
model_sha256_paraformer="5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f"
model_sha256_zipformer_ctc="23f32059d502e87f4fe4b1a17dbedb65582bb0c42950b3d615f218bb25feafd5"
model_sha256_nemo="83dcb462aece5bef4e8072c267419389f0b8d1f91152d8851765f284ff664caa"

# --- Helpers -----------------------------------------------------------------
fetch() { # url dest sha256
  if [ -e "$2" ] && printf '%s  %s\n' "$3" "$2" | sha256sum -c --quiet 2>/dev/null; then
    echo "cached: $2"; return
  fi
  echo "fetching: $1"
  curl -L --fail --retry 3 -o "$2.part" "$1"
  printf '%s  %s\n' "$3" "$2.part" | sha256sum -c --quiet
  mv "$2.part" "$2"
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

echo "==> bundling sherpa-onnx runtime"
fetch "$sherpa_runtime_url" "$cache/sherpa-runtime.tar.bz2" "$sherpa_runtime_sha256"
tar -xjf "$cache/sherpa-runtime.tar.bz2" -C "$bundle_dir/data/runtime"
test -x "$bundle_dir/data/runtime/$sherpa_runtime/bin/sherpa-onnx"

echo "==> bundling punctuation model"
fetch "$punctuation_url" "$cache/punctuation.tar.bz2" "$punctuation_sha256"
tar -xjf "$cache/punctuation.tar.bz2" -C "$bundle_dir/data/models"
test -f "$bundle_dir/data/models/$punctuation_name/model.int8.onnx"

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

if [ -n "$with_models" ]; then
  echo "==> bundling models: $with_models"
  IFS=',' read -ra model_list <<< "$with_models"
  for model in "${model_list[@]}"; do
    case "$model" in
      zipformer)
        upstream="sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"; model_sha256="$model_sha256_zipformer" ;;
      paraformer)
        upstream="sherpa-onnx-streaming-paraformer-bilingual-zh-en"; model_sha256="$model_sha256_paraformer" ;;
      zipformer-ctc)
        upstream="sherpa-onnx-streaming-zipformer-ctc-zh-xlarge-int8-2025-06-30"; model_sha256="$model_sha256_zipformer_ctc" ;;
      nemo)
        upstream="sherpa-onnx-nemo-ctc-en-conformer-small"; model_sha256="$model_sha256_nemo" ;;
      *) echo "unknown model: $model" >&2; exit 2 ;;
    esac
    if [ -z "$model_sha256" ]; then
      echo "error: SHA-256 for model '$model' is not pinned in scripts/portable-pack.sh" >&2
      exit 2
    fi
    fetch "$model_url_base/${upstream}.tar.bz2" "$cache/${upstream}.tar.bz2" "$model_sha256"
    tar -xjf "$cache/${upstream}.tar.bz2" -C "$bundle_dir/data/models"
    test -f "$bundle_dir/data/models/$upstream/tokens.txt"
  done
fi

cat > "$bundle_dir/lszl" <<'LAUNCHER'
#!/bin/sh
# lszl portable launcher: relocatable, no system packages required.
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export LSZL_DATA_HOME="$here/data"
export PATH="$here/bin:$PATH"
exec "$here/bin/lszl" "$@"
LAUNCHER
chmod +x "$bundle_dir/lszl"

cat > "$bundle_dir/README.txt" <<EOF
lszl $version (portable, Linux x86_64)
======================================
Unpack anywhere and run; no system packages are needed.

Usage:
  ./lszl model list
  ./lszl model install paraformer    # one-time model download (~1 GB)
  ./lszl model default paraformer
  ./lszl transcribe "录音.m4a"
  ./lszl doctor

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
