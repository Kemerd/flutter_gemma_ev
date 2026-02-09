#!/bin/bash
#
# LiteRT-LM Resource Preparation Script (macOS)
#
# Called by CocoaPods prepare_command during pod install.
# Downloads prebuilt LiteRT-LM native libraries from GitHub and
# places them in Resources/ for bundling into the app.
#
# No Java, no JRE, no JAR — pure native FFI.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$PLUGIN_DIR/Resources"

echo "=== LiteRT-LM Resource Preparation ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Resources dir: $RESOURCES_DIR"

# ============================================================================
# Configuration
# ============================================================================

# GitHub base URL for raw LFS file downloads
GITHUB_BASE_URL="https://github.com/google-ai-edge/LiteRT-LM/raw/main/prebuilt"

# Architecture detection
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    NATIVE_ARCH="macos_arm64"
else
    echo "WARNING: Intel Mac (x86_64) is not supported by LiteRT-LM prebuilts"
    echo "Skipping native library download."
    exit 0
fi
echo "Architecture: $ARCH"

# Prebuilt libraries for macOS ARM64 (from LiteRT-LM/prebuilt/macos_arm64/)
PREBUILT_LIBS=(
    "libGemmaModelConstraintProvider.dylib"
    "libLiteRt.dylib"
    "libLiteRtMetalAccelerator.dylib"
    "libLiteRtTopKWebGpuSampler.dylib"
    "libLiteRtWebGpuAccelerator.dylib"
)

# Local cache directory so we don't re-download every pod install
CACHE_DIR="$HOME/Library/Caches/flutter_gemma/prebuilt/$NATIVE_ARCH"

# Natives subdirectory inside Resources
NATIVES_DIR="$RESOURCES_DIR/litertlm"

mkdir -p "$RESOURCES_DIR"
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
        echo "  [present]  $filename"
        return
    fi

    # Check local cache
    if [ -f "$cached_file" ]; then
        cp "$cached_file" "$dest_file"
        echo "  [cache]    $filename"
        return
    fi

    # Check local dev paths (cloned LiteRT-LM repo next to this project)
    local plugin_root
    plugin_root="$(cd "$PLUGIN_DIR/.." && pwd)"
    for local_path in \
        "$plugin_root/../LiteRT-LM-ref/prebuilt/$NATIVE_ARCH/$filename" \
        "$plugin_root/native/prebuilt/$NATIVE_ARCH/$filename"; do
        if [ -f "$local_path" ]; then
            cp "$local_path" "$dest_file"
            cp "$local_path" "$cached_file"
            echo "  [local]    $filename"
            return
        fi
    done

    # Download from GitHub (raw URL handles LFS redirect)
    local url="$GITHUB_BASE_URL/$NATIVE_ARCH/$filename"
    echo "  [download] $filename from GitHub..."
    if curl -fSL --retry 3 -o "$cached_file" "$url"; then
        cp "$cached_file" "$dest_file"
        echo "  [ok]       $filename"
    else
        echo "  [FAILED]   $filename (URL: $url)" >&2
        rm -f "$cached_file"
    fi
}

# ============================================================================
# Main: download prebuilt native libraries
# ============================================================================
echo ""
echo "=== Downloading prebuilt LiteRT-LM libraries ==="

for lib in "${PREBUILT_LIBS[@]}"; do
    download_if_not_cached "$lib" "$NATIVES_DIR"
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Resource preparation complete ==="
echo "Resources ready in: $RESOURCES_DIR"
echo ""
echo "Bundled libraries:"
for f in "$NATIVES_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    size=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") ($size)"
done
