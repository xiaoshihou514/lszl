set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

runtime_name := "sherpa-onnx-v1.13.5-linux-x64-shared-no-tts"
runtime_archive := ".zig-cache/sherpa-onnx-v1.13.5-linux-x64-shared-no-tts.tar.bz2"
runtime_url := "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-linux-x64-shared-no-tts.tar.bz2"
runtime_sha256 := "a39369615d610cb835f225b6b7fbff684aedf46557eab8a90e1ccc11fac84166"

cudnn_version := "9.25.0.15"
cudnn_archive := ".zig-cache/cudnn-linux-x86_64-9.25.0.15_cuda13-archive.tar.xz"
cudnn_url := "https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/linux-x86_64/cudnn-linux-x86_64-9.25.0.15_cuda13-archive.tar.xz"
cudnn_sha256 := "bdf8c65f92dd552141d011fd7e7a1bfbafdc6239667b15c44d604597fa927745"

# Install the pinned sherpa-onnx C API required to build lszl.
bootstrap-runtime:
    mkdir -p .zig-cache
    if test -e {{runtime_archive}}; then echo "{{runtime_sha256}}  {{runtime_archive}}" | sha256sum --check; tar -tjf {{runtime_archive}} >/dev/null; else curl -L --fail --retry 3 -o {{runtime_archive}}.part {{runtime_url}}; echo "{{runtime_sha256}}  {{runtime_archive}}.part" | sha256sum --check; tar -tjf {{runtime_archive}}.part >/dev/null; mv {{runtime_archive}}.part {{runtime_archive}}; fi
    data="${XDG_DATA_HOME:-$HOME/.local/share}/lszl"; if test ! -f "$data/runtime/{{runtime_name}}/lib/libsherpa-onnx-c-api.so"; then mkdir -p "$data/runtime"; tar -xjf {{runtime_archive}} -C "$data/runtime"; fi

# Build a debug executable.
build: bootstrap-runtime
    zig build

# Run the Zig test suite.
test: bootstrap-runtime
    zig build test

# Build an optimized executable and install it in the user's local bin directory.
install: bootstrap-runtime
    zig build -Doptimize=ReleaseSafe
    bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"; install -Dm755 zig-out/bin/lszl "$bin_dir/lszl"; echo "Installed: $bin_dir/lszl"

# Produce the self-contained portable tarball in dist/ (any Linux x86_64, no system packages).
portable:
    ./scripts/portable-pack.sh

# Download the CUDA 13 cuDNN archive atomically into the local build cache.
bootstrap-cudnn:
    mkdir -p .zig-cache
    if test -e {{cudnn_archive}}; then echo "{{cudnn_sha256}}  {{cudnn_archive}}" | sha256sum --check; tar -tJf {{cudnn_archive}} >/dev/null; else curl -L --fail --retry 3 -o {{cudnn_archive}}.part {{cudnn_url}}; echo "{{cudnn_sha256}}  {{cudnn_archive}}.part" | sha256sum --check; tar -tJf {{cudnn_archive}}.part >/dev/null; mv {{cudnn_archive}}.part {{cudnn_archive}}; fi

# Extract the cached archive to lszl's XDG-owned runtime directory.
install-cudnn: bootstrap-cudnn
    data="${XDG_DATA_HOME:-$HOME/.local/share}/lszl"; mkdir -p "$data/cudnn"; tar -xJf {{cudnn_archive}} -C "$data/cudnn" --strip-components=1; test -f "$data/cudnn/lib/libcudnn.so.9"
