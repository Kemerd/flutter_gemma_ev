#!/bin/bash
#
# LiteRT-LM Native Desktop Setup Script for Flutter Gemma (Linux)
#
# Downloads prebuilt LiteRT-LM accelerator libraries from GitHub.
# No Java, no JRE, no JAR — pure native.
#
# Usage: ./setup_desktop.sh <plugin_dir> <output_dir>

set -e

PLUGIN_DIR="$1"
OUTPUT_DIR="$2"

if [ -z "$PLUGIN_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <plugin_dir> <output_dir>"
    exit 1
fi

echo "=== LiteRT-LM Native Desktop Setup (Linux) ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Output dir: $OUTPUT_DIR"

# ============================================================================
# Configuration
# ============================================================================

# GitHub base URL for raw LFS file downloads
GITHUB_BASE_URL="https://github.com/google-ai-edge/LiteRT-LM/raw/main/prebuilt"

# Architecture detection
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        NATIVE_ARCH="linux_x86_64"
        echo "Detected x86_64 architecture"
        ;;
    aarch64)
        NATIVE_ARCH="linux_arm64"
        echo "Detected ARM64 architecture"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

# Libraries we need for Linux:
#   - liblitert_lm_capi.so  — main C API library (built from source via native/build_litert_lm_dll.sh)
#   - Accelerator .so files  — from LiteRT-LM/prebuilt/
PREBUILT_LIBS=(
    "liblitert_lm_capi.so"
    "libGemmaModelConstraintProvider.so"
    "libLiteRt.so"
    "libLiteRtTopKWebGpuSampler.so"
    "libLiteRtWebGpuAccelerator.so"
)

PLUGIN_ROOT=$(dirname "$PLUGIN_DIR")
NATIVES_DIR="$OUTPUT_DIR/litertlm"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/flutter_gemma/prebuilt/$NATIVE_ARCH"

mkdir -p "$NATIVES_DIR"
mkdir -p "$CACHE_DIR"

# ============================================================================
# Helper: download a file if not cached
# ============================================================================
download_if_not_cached() {
    local filename="$1"
    local dest_dir="$2"

    local cached_file="$CACHE_DIR/$filename"
    local dest_file="$dest_dir/$filename"

    # Already in output? Skip.
    if [ -f "$dest_file" ]; then
        echo "  [cached]   $filename"
        return
    fi

    # Check local cache
    if [ -f "$cached_file" ]; then
        cp "$cached_file" "$dest_file"
        echo "  [cache]    $filename"
        return
    fi

    # Check local dev paths:
    #   1. native/prebuilt/ (built by native/build_litert_lm_dll.sh)
    #   2. LiteRT-LM-ref/prebuilt/ (cloned repo)
    for local_path in \
        "$PLUGIN_ROOT/native/prebuilt/$NATIVE_ARCH/$filename" \
        "$PLUGIN_ROOT/../LiteRT-LM-ref/prebuilt/$NATIVE_ARCH/$filename"; do
        if [ -f "$local_path" ]; then
            cp "$local_path" "$dest_file"
            cp "$local_path" "$cached_file"
            echo "  [local]    $filename"
            return
        fi
    done

    # Download from GitHub (raw URL handles LFS redirect)
    # Note: liblitert_lm_capi.so is NOT on GitHub — it must be built locally
    local url="$GITHUB_BASE_URL/$NATIVE_ARCH/$filename"
    echo "  [download] $filename from GitHub..."
    if curl -fSL --retry 3 -o "$cached_file" "$url"; then
        cp "$cached_file" "$dest_file"
        echo "  [ok]       $filename"
    else
        if [ "$filename" = "liblitert_lm_capi.so" ]; then
            echo "  [MISSING]  $filename — run native/build_litert_lm_dll.sh to build from source" >&2
        else
            echo "  [FAILED]   $filename (URL: $url)" >&2
        fi
        rm -f "$cached_file"
    fi
}

# ============================================================================
# Install prebuilt accelerator libraries
# ============================================================================
install_prebuilt_libs() {
    echo ""
    echo "=== Installing prebuilt LiteRT-LM libraries ==="

    for lib in "${PREBUILT_LIBS[@]}"; do
        download_if_not_cached "$lib" "$NATIVES_DIR"
    done
}

# ============================================================================
# Main
# ============================================================================
install_prebuilt_libs

# Summary
echo ""
echo "========================================"
echo "=== Setup complete ==="
echo "========================================"
echo "Natives dir: $NATIVES_DIR"
echo ""
echo "Bundled libraries:"
for f in "$NATIVES_DIR"/*.so; do
    [ -f "$f" ] || continue
    size=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") ($size)"
done
