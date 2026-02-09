#!/bin/bash
#
# LiteRT-LM Native Desktop Setup Script for Flutter Gemma (macOS)
#
# Downloads prebuilt LiteRT-LM accelerator libraries from GitHub and
# signs them for macOS sandbox/Gatekeeper.
# No Java, no JRE, no JAR — pure native.
#
# Usage: setup_desktop.sh <PODS_TARGET_SRCROOT> <APP_BUNDLE_PATH>

set -e

echo "=== LiteRT-LM Native Desktop Setup (macOS) ==="

# ============================================================================
# Configuration
# ============================================================================

# GitHub base URL for raw LFS file downloads
GITHUB_BASE_URL="https://github.com/google-ai-edge/LiteRT-LM/raw/main/prebuilt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODS_ROOT="${1:-$SCRIPT_DIR/..}"
APP_BUNDLE="${2:-}"

# Skip if not macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Skipping: not macOS"
    exit 0
fi

if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    echo "No valid app bundle path provided: $APP_BUNDLE"
    exit 0
fi

echo "App bundle: $APP_BUNDLE"

# Architecture detection — only Apple Silicon supported
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    NATIVE_ARCH="macos_arm64"
else
    echo "WARNING: Intel Mac (x86_64) is not supported by LiteRT-LM prebuilts"
    echo "  Desktop support requires Apple Silicon (M1/M2/M3/M4)"
    exit 0
fi

# Prebuilt libraries we need for macOS ARM64
PREBUILT_LIBS=(
    "libGemmaModelConstraintProvider.dylib"
    "libLiteRt.dylib"
    "libLiteRtMetalAccelerator.dylib"
    "libLiteRtTopKWebGpuSampler.dylib"
    "libLiteRtWebGpuAccelerator.dylib"
)

PLUGIN_ROOT="$(cd "$PODS_ROOT/.." && pwd)"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
NATIVES_DIR="$FRAMEWORKS_DIR/litertlm"
CACHE_DIR="$HOME/Library/Caches/flutter_gemma/prebuilt/$NATIVE_ARCH"

echo "Plugin root: $PLUGIN_ROOT"
echo "Frameworks:  $FRAMEWORKS_DIR"
echo "Architecture: $ARCH"

mkdir -p "$NATIVES_DIR"
mkdir -p "$CACHE_DIR"

# ============================================================================
# Helper: download a file if not cached, then codesign for macOS
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
        sign_lib "$dest_file"
        echo "  [cache]    $filename"
        return
    fi

    # Check local dev paths (cloned LiteRT-LM repo next to this project)
    for local_path in \
        "$PLUGIN_ROOT/../LiteRT-LM-ref/prebuilt/$NATIVE_ARCH/$filename" \
        "$PLUGIN_ROOT/native/prebuilt/$NATIVE_ARCH/$filename"; do
        if [ -f "$local_path" ]; then
            cp "$local_path" "$dest_file"
            cp "$local_path" "$cached_file"
            sign_lib "$dest_file"
            echo "  [local]    $filename"
            return
        fi
    done

    # Download from GitHub (raw URL handles LFS redirect)
    local url="$GITHUB_BASE_URL/$NATIVE_ARCH/$filename"
    echo "  [download] $filename from GitHub..."
    if curl -fSL --retry 3 -o "$cached_file" "$url"; then
        cp "$cached_file" "$dest_file"
        sign_lib "$dest_file"
        echo "  [ok]       $filename"
    else
        echo "  [FAILED]   $filename (URL: $url)" >&2
        rm -f "$cached_file"
    fi
}

# ============================================================================
# Helper: codesign a library for macOS sandbox / Gatekeeper
# ============================================================================
sign_lib() {
    local lib_path="$1"
    # Remove quarantine attribute (downloaded files get flagged)
    xattr -r -d com.apple.quarantine "$lib_path" 2>/dev/null || true
    # Ad-hoc sign so macOS doesn't reject unsigned binaries
    codesign --force --sign - "$lib_path" 2>/dev/null || true
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
for f in "$NATIVES_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    size=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") ($size)"
done
